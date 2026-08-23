//! HTTP/1.x response parsing: a head, then framed body delivery to a sink.
//!
//! The parser owns framing entirely (docs/DESIGN.md rule 2). The caller never
//! sees an undecoded byte: content-length bodies, chunked bodies (including
//! trailers) and close-delimited bodies all arrive at the sink as the same
//! logical byte stream. This is the property whose absence cost the zoxy
//! benchmark months of silently corrupted cAdvisor scrapes.
//!
//! Zero allocation, by construction rather than effort: nothing here takes an
//! allocator. Head lines are parsed in place inside the reader's buffer;
//! bodies stream through `Io.Reader.streamExact64`/`streamRemaining` without
//! ever being held whole.
//!
//! Every assertion in this file states an INTERNAL invariant. Every byte it
//! reads was written by someone else, so a malformed status line is expected
//! input and returns an error: an assertion a remote server can trip is a
//! remote panic, and it would vanish from the ReleaseFast build a consumer is
//! free to choose. Errors survive every build mode; assertions do not.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

pub const Error = error{
    MalformedStatusLine,
    MalformedHeader,
    MalformedChunk,
    /// A head (or trailer) line exceeded the reader's buffer, or the head as a
    /// whole exceeded `max_head_bytes`. Never truncated (rule 7): the caller
    /// gets an error, not a clipped header.
    HeadTooLong,
    UnexpectedEof,
    ReadFailed,
    /// The SINK failed, not the transport. Distinct on purpose: a full collect
    /// buffer and a dead connection demand different reactions.
    WriteFailed,
};

pub const Head = struct {
    status: u16,
    /// The status line began "HTTP/1.1". Decides the keep-alive default.
    http11: bool,
    /// What the head SAID. The final verdict is `Body.keep_alive`, because a
    /// close-delimited body forces false regardless of any header.
    keep_alive: bool,
    content_length: ?u64 = null,
    chunked: bool = false,

    /// RFC 9112 §6.3: HEAD responses and 1xx/204/304 statuses never carry a
    /// body, whatever Content-Length or Transfer-Encoding claim. Consuming a
    /// body there eats into the next response and breaks framing — this is
    /// ziglang/zig#25181, open at `urgent` in std.http.Client today.
    pub fn bodyless(h: Head, method: std.http.Method) bool {
        // Only ever called on a head `parseHead` returned, which range-checked
        // the status; the class division below is meaningless without it.
        assert(h.status >= 100);
        assert(h.status <= 999);

        return method == .HEAD or h.status / 100 == 1 or h.status == 204 or h.status == 304;
    }
};

/// Slices are valid ONLY for the duration of the call — they point into the
/// reader's buffer, which the body stream will overwrite.
pub const HeaderFn = *const fn (ctx: ?*anyopaque, name: []const u8, value: []const u8) void;

pub const HeadOptions = struct {
    /// Called once per header line, and again for chunked trailers. Names are
    /// as sent; values are trimmed of leading/trailing space and tab.
    on_header: ?HeaderFn = null,
    ctx: ?*anyopaque = null,
    /// Budget for the status line plus all headers (and, separately reused,
    /// all trailers), counted in raw bytes including line endings.
    max_head_bytes: usize = 64 * 1024,
};

pub const Body = struct {
    len: u64,
    /// The connection's fate: the head's verdict, downgraded to false when the
    /// body ran to connection close (nothing further can be framed).
    keep_alive: bool,
};

/// Read the status line and headers, through the blank line.
///
/// The reader's buffer bounds the longest single line; `max_head_bytes` bounds
/// the head as a whole, so a server spewing endless valid-sized header lines
/// still terminates.
pub fn parseHead(r: *Io.Reader, opts: HeadOptions) Error!Head {
    // Both are bounds the caller chose: the reader's buffer limits the longest
    // single line, `max_head_bytes` the head as a whole. A zero for either
    // means no head can ever parse, which is a caller bug, not a bad server.
    assert(opts.max_head_bytes > 0);
    assert(r.buffer.len > 0);

    var budget = opts.max_head_bytes;

    const status_line = try takeLine(r, &budget);
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.MalformedStatusLine;
    const http11 = std.mem.startsWith(u8, status_line, "HTTP/1.1");

    // "HTTP/1.1 200 OK" — the token after the first space, exactly three
    // digits (RFC 9112 §4), so every status lands in a 1xx..5xx class bucket.
    const first_space = std.mem.indexOfScalar(u8, status_line, ' ') orelse return error.MalformedStatusLine;
    const after = status_line[first_space + 1 ..];
    const code_end = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
    const status = std.fmt.parseInt(u16, after[0..code_end], 10) catch return error.MalformedStatusLine;
    if (status < 100 or status > 999) return error.MalformedStatusLine;

    var head: Head = .{
        .status = status,
        .http11 = http11,
        // HTTP/1.1 defaults to keep-alive; 1.0 defaults to close.
        .keep_alive = http11,
    };

    // lint:unbounded-ok — every pass charges at least one byte against
    // `budget` in takeLine, which returns error.HeadTooLong once it runs out.
    // That is what terminates a server sending valid-sized headers forever.
    while (true) {
        const line = try takeLine(r, &budget);
        assert(budget < opts.max_head_bytes);
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.MalformedHeader;
        const name = line[0..colon];
        if (name.len == 0) return error.MalformedHeader;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const n = std.fmt.parseInt(u64, value, 10) catch return error.MalformedHeader;
            if (head.content_length) |prev| {
                // Duplicate Content-Length: equal copies are tolerated (some
                // proxies stack them), a DISAGREEMENT is the request-smuggling
                // primitive and is refused outright.
                if (prev != n) return error.MalformedHeader;
            }
            head.content_length = n;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (containsTokenIgnoreCase(value, "chunked")) head.chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (containsTokenIgnoreCase(value, "close")) {
                head.keep_alive = false;
            } else if (containsTokenIgnoreCase(value, "keep-alive")) {
                head.keep_alive = true;
            }
        }

        if (opts.on_header) |f| f(opts.ctx, name, value);
    }

    // The status was range-checked before the loop and the loop only ever
    // narrows the head, so the range still holds at the exit.
    assert(head.status >= 100);
    assert(head.status <= 999);
    return head;
}

/// Deliver the body (decoded, if chunked) to `sink`, per the head's framing.
///
/// Precedence is RFC 9112 §6.3: Transfer-Encoding beats Content-Length —
/// when both are present the length header is a lie or an attack, and the
/// chunked framing is what the wire actually carries. Bodyless heads consume
/// nothing regardless of either header.
pub fn streamBody(
    r: *Io.Reader,
    head: Head,
    method: std.http.Method,
    sink: *Io.Writer,
    opts: HeadOptions,
) Error!Body {
    assert(opts.max_head_bytes > 0);

    if (head.bodyless(method)) return .{ .len = 0, .keep_alive = head.keep_alive };

    if (head.chunked) {
        const n = try streamChunked(r, sink, opts);
        return .{ .len = n, .keep_alive = head.keep_alive };
    }
    if (head.content_length) |len| {
        // Transfer-Encoding already won above, so a length that survives to
        // here is the whole framing: streamExact64 delivers exactly it, or
        // errors. There is no partial-body success to account for.
        assert(!head.chunked);
        r.streamExact64(sink, len) catch |err| return switch (err) {
            error.EndOfStream => error.UnexpectedEof,
            error.ReadFailed => error.ReadFailed,
            error.WriteFailed => error.WriteFailed,
        };
        return .{ .len = len, .keep_alive = head.keep_alive };
    }

    // No framing information: the body runs to connection close, which is
    // itself the reason the connection cannot be kept alive.
    assert(!head.chunked);
    assert(head.content_length == null);
    const n = r.streamRemaining(sink) catch |err| return switch (err) {
        error.ReadFailed => error.ReadFailed,
        error.WriteFailed => error.WriteFailed,
    };
    return .{ .len = n, .keep_alive = false };
}

fn streamChunked(r: *Io.Reader, sink: *Io.Writer, opts: HeadOptions) Error!u64 {
    assert(opts.max_head_bytes > 0);

    var total: u64 = 0;
    // lint:unbounded-ok — every pass consumes a chunk-size line and returns on
    // the zero-size chunk, so it either advances the stream or ends. A server
    // that streams chunks forever is bounded by the caller's whole-request
    // deadline (rule 3), not by a byte cap: a 1.5 MiB cAdvisor scrape and a
    // malicious stream differ in duration, not in shape, and only the caller
    // knows which one it asked for.
    while (true) {
        var size_budget: usize = 1024; // a chunk-size line is a hex number and maybe extensions
        const size_line = takeLine(r, &size_budget) catch return error.MalformedChunk;
        // Size is hex, optionally followed by ";extensions" (ignored).
        const semi = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
        const size = std.fmt.parseInt(u64, std.mem.trim(u8, size_line[0..semi], " \t"), 16) catch
            return error.MalformedChunk;

        if (size == 0) {
            try streamTrailers(r, opts);
            return total;
        }

        // The zero-size chunk returned above, so every pass reaching here moves
        // the stream forward by at least one body byte — the loop's progress
        // guarantee, stated where it is made.
        assert(size > 0);
        r.streamExact64(sink, size) catch |err| return switch (err) {
            error.EndOfStream => error.MalformedChunk,
            error.ReadFailed => error.ReadFailed,
            error.WriteFailed => error.WriteFailed,
        };
        total += size;

        // Each chunk's data is followed by CRLF — and by exactly that. The
        // hand-rolled reader this replaces ignored the line's content, which
        // let a desynchronised stream limp on to a stranger error later.
        var crlf_budget: usize = 8;
        const crlf = takeLine(r, &crlf_budget) catch return error.MalformedChunk;
        if (crlf.len != 0) return error.MalformedChunk;
    }
}

/// The trailer section: header fields until the blank line, delivered through
/// the same callback as the head's, under a fresh head-sized budget.
///
/// A trailer IS a header field (RFC 9112 §7.1.2), so it is held to the head's
/// rule AND reports the head's errors — a nameless field is
/// `error.MalformedHeader` here exactly as it is there, an over-long line is
/// `error.HeadTooLong` (which is what that error's own doc has always
/// claimed), and a truncated section is `error.UnexpectedEof` rather than a
/// vaguer complaint about chunk framing. One position-independent answer.
///
/// The fuzzer found both halves of the old behaviour: this section delivered
/// a nameless field that `parseHead` refuses, so the same bytes meant two
/// different things depending on where in the message they appeared; and the
/// validation sat inside the `on_header` branch, so whether a line was
/// inspected at all depended on whether the caller had installed a listener.
fn streamTrailers(r: *Io.Reader, opts: HeadOptions) Error!void {
    assert(opts.max_head_bytes > 0);

    var budget = opts.max_head_bytes;
    // lint:unbounded-ok — the head's bound exactly: takeLine charges every
    // trailer line against `budget` and fails when it is spent.
    while (true) {
        const line = try takeLine(r, &budget);
        assert(budget < opts.max_head_bytes);
        if (line.len == 0) return;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.MalformedHeader;
        const name = line[0..colon];
        if (name.len == 0) return error.MalformedHeader;

        if (opts.on_header) |f| {
            f(opts.ctx, name, std.mem.trim(u8, line[colon + 1 ..], " \t"));
        }
    }
}

/// One head/trailer line: CRLF-terminated (bare LF tolerated), returned
/// without the terminator, charged against `budget` at its raw on-wire size.
fn takeLine(r: *Io.Reader, budget: *usize) Error![]const u8 {
    const budget_before = budget.*;

    const raw = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.HeadTooLong,
        error.EndOfStream => return error.UnexpectedEof,
        error.ReadFailed => return error.ReadFailed,
    };
    // takeDelimiterInclusive returns the delimiter with the line, so a
    // successful line is never empty and the budget therefore strictly
    // decreases. That is what bounds every loop in this file.
    assert(raw.len > 0);
    if (raw.len > budget.*) return error.HeadTooLong;
    budget.* -= raw.len;
    assert(budget.* < budget_before);

    var line = raw;
    if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    assert(line.len < raw.len); // the terminator is always stripped
    return line;
}

/// Whether a comma-separated header value contains `token`, ASCII
/// case-insensitively, as a whole token rather than a substring — "close"
/// must not match a hypothetical "not-close".
fn containsTokenIgnoreCase(value: []const u8, token: []const u8) bool {
    // Every call site passes a comptime literal; an empty token would match
    // every empty list element and quietly turn a header into a verdict.
    assert(token.len > 0);

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// tests

const t = std.testing;
const SegmentedReader = @import("SegmentedReader.zig");

fn parseAll(reader: *Io.Reader, method: std.http.Method, out: *Io.Writer.Allocating) !struct { Head, Body } {
    const head = try parseHead(reader, .{});
    const body = try streamBody(reader, head, method, &out.writer, .{});
    return .{ head, body };
}

test "content-length body, plain" {
    const wire = "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhello";
    var buf: [256]u8 = undefined;
    var sr = SegmentedReader.init(wire, wire.len, null, &buf);
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    const head, const body = try parseAll(&sr.interface, .GET, &out);
    try t.expectEqual(@as(u16, 200), head.status);
    try t.expect(head.keep_alive and body.keep_alive);
    try t.expectEqual(@as(u64, 5), body.len);
    try t.expectEqualStrings("hello", out.written());
}

test "chunked body reassembles across chunk boundaries, with trailers" {
    const wire = "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n" ++
        "4\r\nWiki\r\n5\r\npedia\r\n0\r\nx-trailer: yes\r\n\r\n";
    var buf: [256]u8 = undefined;
    var sr = SegmentedReader.init(wire, wire.len, null, &buf);
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    const head, const body = try parseAll(&sr.interface, .GET, &out);
    try t.expect(head.chunked);
    try t.expectEqual(@as(u64, 9), body.len);
    try t.expectEqualStrings("Wikipedia", out.written());
}

test "segmentation invariance: every split point and byte-at-a-time" {
    // The property the cAdvisor bug violated: the parse result is a function
    // of the bytes, never of where the transport split them. Chunk framing is
    // deliberately positioned so splits land inside the size line, inside the
    // CRLFs, and inside chunk data.
    const wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-A: b\r\n\r\n" ++
        "6\r\nmetric\r\nb;ext=1\r\n_total 42.5\r\n0\r\n\r\n";
    const want = "metric_total 42.5";

    // Every two-segment split.
    var split: usize = 1;
    while (split < wire.len) : (split += 1) {
        var buf: [256]u8 = undefined;
        var sr = SegmentedReader.init(wire, wire.len, split, &buf);
        var out: Io.Writer.Allocating = .init(t.allocator);
        defer out.deinit();
        _, const body = try parseAll(&sr.interface, .GET, &out);
        try t.expectEqual(@as(u64, want.len), body.len);
        try t.expectEqualStrings(want, out.written());
    }

    // One byte per read — every boundary at once.
    var buf: [256]u8 = undefined;
    var sr = SegmentedReader.init(wire, 1, null, &buf);
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    _, const body = try parseAll(&sr.interface, .GET, &out);
    try t.expectEqualStrings(want, out.written());
    try t.expectEqual(@as(u64, want.len), body.len);
}

test "bodyless: 204 with keep-alive does not hang, and HEAD ignores content-length" {
    // ziglang/zig#25181 is exactly this shape hanging in std.http.Client.
    const wire204 = "HTTP/1.1 204 No Content\r\n\r\n" ++ "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok";
    var buf: [256]u8 = undefined;
    var sr = SegmentedReader.init(wire204, wire204.len, null, &buf);
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();

    _, const b1 = try parseAll(&sr.interface, .GET, &out);
    try t.expectEqual(@as(u64, 0), b1.len);
    try t.expect(b1.keep_alive);
    // The very next bytes must parse as the next response — proof nothing of
    // the 204 "body" was consumed.
    const h2, const b2 = try parseAll(&sr.interface, .GET, &out);
    try t.expectEqual(@as(u16, 200), h2.status);
    try t.expectEqual(@as(u64, 2), b2.len);

    const head_wire = "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n";
    var sr2 = SegmentedReader.init(head_wire, head_wire.len, null, &buf);
    var out2: Io.Writer.Allocating = .init(t.allocator);
    defer out2.deinit();
    _, const hb = try parseAll(&sr2.interface, .HEAD, &out2);
    try t.expectEqual(@as(u64, 0), hb.len);
}

test "transfer-encoding beats content-length; conflicting lengths are refused" {
    const smuggle = "HTTP/1.1 200 OK\r\ncontent-length: 4\r\ntransfer-encoding: chunked\r\n\r\n" ++
        "2\r\nab\r\n0\r\n\r\n";
    var buf: [256]u8 = undefined;
    var sr = SegmentedReader.init(smuggle, smuggle.len, null, &buf);
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    _, const body = try parseAll(&sr.interface, .GET, &out);
    try t.expectEqualStrings("ab", out.written()); // chunked won; CL ignored

    const conflict = "HTTP/1.1 200 OK\r\ncontent-length: 4\r\ncontent-length: 5\r\n\r\n";
    var sr2 = SegmentedReader.init(conflict, conflict.len, null, &buf);
    try t.expectError(error.MalformedHeader, parseHead(&sr2.interface, .{}));
    _ = body;
}

test "close-delimited body forces keep_alive false" {
    const wire = "HTTP/1.0 200 OK\r\n\r\nrest of stream";
    var buf: [256]u8 = undefined;
    var sr = SegmentedReader.init(wire, wire.len, null, &buf);
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    const head, const body = try parseAll(&sr.interface, .GET, &out);
    try t.expect(!head.http11);
    try t.expect(!body.keep_alive);
    try t.expectEqualStrings("rest of stream", out.written());
}

test "a trailer is held to the head's rule, listener or no listener" {
    // Found by src/fuzz.zig: the head refuses a nameless field, and the
    // trailer section used to deliver one. The same bytes must not mean two
    // different things depending on where in the message they appear.
    const nameless = "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n2\r\nab\r\n0\r\n: v\r\n\r\n";
    const colonless = "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n2\r\nab\r\n0\r\ngarbage\r\n\r\n";
    const head_nameless = "HTTP/1.1 200 OK\r\n: v\r\n\r\n";

    var buf: [256]u8 = undefined;
    var head_reader = SegmentedReader.init(head_nameless, head_nameless.len, null, &buf);
    try t.expectError(error.MalformedHeader, parseHead(&head_reader.interface, .{}));

    // And the verdict does not depend on whether anyone is listening: the
    // callback used to be where the check lived.
    const Sink = struct {
        fn ignore(_: ?*anyopaque, _: []const u8, _: []const u8) void {}
    };
    for ([_][]const u8{ nameless, colonless }) |wire| {
        for ([_]?HeaderFn{ null, Sink.ignore }) |listener| {
            var sr = SegmentedReader.init(wire, wire.len, null, &buf);
            var out: Io.Writer.Allocating = .init(t.allocator);
            defer out.deinit();
            const opts: HeadOptions = .{ .on_header = listener };
            const head = try parseHead(&sr.interface, opts);
            // The head's error, not a vaguer one about chunk framing: the
            // whole point is that position does not change the answer.
            try t.expectError(
                error.MalformedHeader,
                streamBody(&sr.interface, head, .GET, &out.writer, opts),
            );
        }
    }
}

test "connection tokens match whole tokens, not substrings" {
    try t.expect(containsTokenIgnoreCase("Keep-Alive, Upgrade", "keep-alive"));
    try t.expect(!containsTokenIgnoreCase("not-close", "close"));
    try t.expect(containsTokenIgnoreCase("close", "CLOSE"));
}

test "head budget terminates an endless-header server" {
    // Valid-sized lines forever: the line length never trips the reader
    // buffer, so only max_head_bytes stands between us and spinning forever.
    var wire: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&wire);
    w.writeAll("HTTP/1.1 200 OK\r\n") catch unreachable;
    for (0..100) |_| w.writeAll("x-h: aaaaaaaaaaaaaaaaaaaaaaaaaa\r\n") catch unreachable;
    var buf: [256]u8 = undefined;
    var sr = SegmentedReader.init(w.buffered(), wire.len, null, &buf);
    try t.expectError(error.HeadTooLong, parseHead(&sr.interface, .{ .max_head_bytes = 512 }));
}

test "headers are delivered through the callback with trimmed values" {
    const Ctx = struct {
        seen: usize = 0,
        fn on(ctx: ?*anyopaque, name: []const u8, value: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (std.ascii.eqlIgnoreCase(name, "x-spaced")) {
                std.testing.expectEqualStrings("v", value) catch unreachable;
                self.seen += 1;
            }
        }
    };
    const wire = "HTTP/1.1 200 OK\r\nx-spaced:   v  \r\ncontent-length: 0\r\n\r\n";
    var buf: [256]u8 = undefined;
    var sr = SegmentedReader.init(wire, wire.len, null, &buf);
    var ctx: Ctx = .{};
    _ = try parseHead(&sr.interface, .{ .on_header = Ctx.on, .ctx = &ctx });
    try t.expectEqual(@as(usize, 1), ctx.seen);
}
