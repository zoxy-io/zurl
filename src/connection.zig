//! One HTTP/1.1 connection over an injected transport.
//!
//! A `Connection` is a `*Io.Reader` and a `*Io.Writer`, full stop (design
//! rule 5). Plain TCP, std TLS, zrk's ztls, an in-memory pipe in a test — all
//! the same type. Whoever owns the transport owns its lifetime and its close;
//! the connection only tracks whether HTTP framing permits reuse.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const parser = @import("parser.zig");
const LineSink = @import("sink.zig").LineSink;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Request = struct {
    method: std.http.Method = .GET,
    /// origin-form target: path plus optional query, e.g. "/metrics".
    target: []const u8 = "/",
    /// Sent as the Host header — mandatory in HTTP/1.1.
    host: []const u8,
    /// Convenience for the two headers every control-plane caller in the
    /// benchmark repo sets; anything else goes in `extra`.
    authorization: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    extra: []const Header = &.{},
    /// Body bytes, sent with an automatic Content-Length. No request-side
    /// chunked encoding in v0 (nothing in either repo needs it).
    body: ?[]const u8 = null,
    /// When false, sends `connection: close` — the reply then has somewhere
    /// to stop even if the server can't frame it (the benchmark's a60a95c).
    keep_alive: bool = true,
};

/// Where the response body goes. No "none" variant, on purpose: forgetting to
/// route the body is unrepresentable (design rule 1, born as d4ad5fa).
pub const Sink = union(enum) {
    discard,
    collect: *Io.Writer.Allocating,
    lines: *LineSink,
    /// Any other Io.Writer.
    stream: *Io.Writer,
};

pub const Response = struct {
    status: u16,
    body_len: u64,

    pub fn ok(r: Response) bool {
        // A Response only ever comes from a round trip, which range-checked
        // the status — the same precondition `Head.bodyless` states.
        assert(r.status >= 100);
        assert(r.status <= 999);

        return r.status == 200;
    }
};

pub const Error = parser.Error || Io.Writer.Error || RequestError || error{
    /// A previous response on this connection said close (or was
    /// close-delimited, or errored): HTTP framing forbids another request.
    ConnectionNotReusable,
};

/// Refusals raised before a single byte of the request is written.
///
/// Every one of these is a field the caller supplied that cannot appear where
/// it was going to be interpolated. They are errors and not assertions on
/// purpose: these values arrive from whatever string the caller was handed —
/// a URL from a config file, an upstream redirect, a bucket key — so a leaf
/// library that asserted on them would panic its consumer, and one that
/// asserted in Debug would simply do the wrong thing in ReleaseFast, where
/// `std.debug.assert` is compiled out.
pub const RequestError = error{
    /// The method, target or host cannot go in a request line. A space or a
    /// CR/LF in the target ends the line early, and everything after it is
    /// read by the origin as another header or another request — so this is
    /// request-header injection through a URL, not a cosmetic complaint.
    InvalidRequestTarget,
    /// A header name is not a token, or a value carries a byte that cannot
    /// appear in a field value. Same injection, one line further down.
    InvalidRequestHeader,
};

pub const Connection = struct {
    in: *Io.Reader,
    out: *Io.Writer,
    /// False once framing forbids another request on this transport. Errors
    /// also clear it: after a malformed response there is no knowing where in
    /// the stream the next one would begin.
    reusable: bool = true,

    pub fn init(in: *Io.Reader, out: *Io.Writer) Connection {
        // The reader's buffer is a real bound — it limits the longest head
        // line the parser can ever see, and a zero-length one fails every
        // response for a reason that has nothing to do with the response.
        assert(in.buffer.len > 0);
        // `out` gets no length assertion: zero means "unbuffered", which is a
        // legitimate choice, and the TLS transport's writer is exactly that.
        // An earlier assertion here forbade it — a claim about what had not
        // happened yet rather than about what cannot.
        //
        // What IS still an invariant is the thing that actually broke. std
        // documents a zero-length buffer as making the DEFAULT flush a no-op,
        // so an unbuffered writer that kept it would silently swallow
        // `writeRequest`'s closing flush and the request would never reach the
        // wire — which is precisely how the TLS transport first failed, as an
        // UnexpectedEof out of the parser.
        if (out.buffer.len == 0) assert(out.vtable.flush != Io.Writer.defaultFlush);

        return .{ .in = in, .out = out };
    }

    /// One request/response exchange. The head is parsed, the body is decoded
    /// and delivered to `sink`, and `reusable` is updated from what the
    /// exchange actually was — not from what the request asked for.
    pub fn roundTrip(c: *Connection, req: Request, sink: Sink, opts: parser.HeadOptions) Error!Response {
        // No assertion on `host` or `target` here. They are caller input, and
        // `writeRequest` returns InvalidRequestTarget for an empty one -- an
        // assert would panic a consumer in Debug for a case the API already
        // answers with an error, and would vanish in ReleaseFast.
        if (!c.reusable) return error.ConnectionNotReusable;
        // Any error leaves the stream at an offset nobody knows, so no further
        // request can be framed on this transport.
        errdefer c.reusable = false;

        try writeRequest(c.out, req);

        var discard_buf: [512]u8 = undefined;
        var discarding: Io.Writer.Discarding = .init(&discard_buf);
        const w: *Io.Writer = switch (sink) {
            .discard => &discarding.writer,
            .collect => |a| &a.writer,
            .lines => |l| &l.writer,
            .stream => |s| s,
        };

        const head = try parser.parseHead(c.in, opts);
        const body = try parser.streamBody(c.in, head, req.method, w, opts);
        if (sink == .lines) sink.lines.finish();

        // Reuse is the exchange's verdict, never the request's wish: asking for
        // keep-alive cannot make a close-delimited body reusable.
        c.reusable = body.keep_alive and req.keep_alive;
        // streamBody's postcondition, checked where it is relied on.
        if (head.bodyless(req.method)) assert(body.len == 0);

        return .{ .status = head.status, .body_len = body.len };
    }

    /// The probe shape: send, read the status line and headers, deliberately
    /// do NOT touch the body. The connection is never reusable afterwards —
    /// the unread body is still on the wire — which is exactly the contract a
    /// warm probe wants (it closes the transport regardless).
    pub fn roundTripHead(c: *Connection, req: Request, opts: parser.HeadOptions) Error!parser.Head {
        // Caller input, validated by `writeRequest` as an error -- see roundTrip.
        if (!c.reusable) return error.ConnectionNotReusable;
        // The body is deliberately left on the wire, so nothing downstream can
        // know where the next response would begin.
        c.reusable = false;
        try writeRequest(c.out, req);
        return parser.parseHead(c.in, opts);
    }
};

/// Whether `b` may appear in a header field value.
///
/// RFC 9110 §5.5 field-value: VCHAR, SP, HTAB, and obs-text (0x80-0xFF, which
/// is deprecated but still received). Everything excluded here is a control
/// character, and the two that matter are CR and LF — those are what end a
/// header line and let a value become a line of its own.
fn isFieldValueByte(b: u8) bool {
    return b == '\t' or (b >= 0x20 and b != 0x7F);
}

/// Whether `b` may appear in a header field name.
///
/// RFC 9110 §5.6.2 token. Notably excludes the colon: a name carrying one
/// would produce a header whose name is not the name the caller asked for.
fn isTokenByte(b: u8) bool {
    return switch (b) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// Whether `b` may appear in an origin-form request target.
///
/// Deliberately stricter than the field-value rule: a target is delimited by
/// SPACE in the request line, so a space inside one ends it early and turns
/// the remainder into a bogus HTTP version. Non-ASCII must have been
/// percent-encoded by whoever built the URL — zurl cannot encode it here
/// without guessing whether a `?` the caller wrote is a separator or a
/// literal, which is why this refuses rather than repairs.
fn isTargetByte(b: u8) bool {
    return b > 0x20 and b != 0x7F and b < 0x80;
}

/// The request-line half of `validate`: everything that lands between the
/// method and the HTTP version, plus the host it routes on.
///
/// Public and separate because `client.zig` needs exactly this half before it
/// dials, so a URL that cannot become a request line costs no socket.
pub fn validateTarget(target: []const u8, host: []const u8) RequestError!void {
    if (target.len == 0 or host.len == 0) return error.InvalidRequestTarget;
    for (target) |b| if (!isTargetByte(b)) return error.InvalidRequestTarget;
    // The host lands in a header value, but a space or a control byte there is
    // never a real host name, and `host` is the one header an origin routes on.
    for (host) |b| if (!isTargetByte(b)) return error.InvalidRequestTarget;
}

/// Reject anything that cannot appear where it is about to be interpolated.
///
/// This is the whole of the request-injection defence, and it lives here
/// because `writeRequest` is the only place that composes a request — so a
/// caller reaching `Connection` directly is covered by exactly the same check
/// as one going through `fetch`.
fn validate(req: Request) RequestError!void {
    try validateTarget(req.target, req.host);

    if (req.authorization) |a| for (a) |b| {
        if (!isFieldValueByte(b)) return error.InvalidRequestHeader;
    };
    if (req.content_type) |ct| for (ct) |b| {
        if (!isFieldValueByte(b)) return error.InvalidRequestHeader;
    };

    for (req.extra) |h| {
        if (h.name.len == 0) return error.InvalidRequestHeader;
        for (h.name) |b| if (!isTokenByte(b)) return error.InvalidRequestHeader;
        for (h.value) |b| if (!isFieldValueByte(b)) return error.InvalidRequestHeader;
    }
}

pub fn writeRequest(out: *Io.Writer, req: Request) (Io.Writer.Error || RequestError)!void {
    // Checked BEFORE the first byte goes out, because half a request line on
    // the wire cannot be taken back: this transport would have to be dropped
    // even though nothing was wrong with it. Returning here also means every
    // field below is known interpolable, which is why nothing restates that
    // as an assertion — an assert on the line after the check that guarantees
    // it documents nothing and disappears in ReleaseFast anyway.
    try validate(req);

    try out.print("{s} {s} HTTP/1.1\r\nhost: {s}\r\n", .{
        @tagName(req.method), req.target, req.host,
    });
    if (req.authorization) |a| try out.print("authorization: {s}\r\n", .{a});
    if (req.content_type) |ct| try out.print("content-type: {s}\r\n", .{ct});
    if (req.body) |b| try out.print("content-length: {d}\r\n", .{b.len});
    if (!req.keep_alive) try out.writeAll("connection: close\r\n");
    for (req.extra) |h| try out.print("{s}: {s}\r\n", .{ h.name, h.value });
    try out.writeAll("\r\n");
    if (req.body) |b| try out.writeAll(b);
    try out.flush();
}

// ---------------------------------------------------------------------------
// tests

const t = std.testing;

test "round trips over an in-memory transport, keep-alive bookkeeping included" {
    // The transport is a pair of fixed buffers — rule 5's payoff: no socket,
    // no Io implementation, same code path as production.
    const wire = "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhi" ++
        "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: 2\r\n\r\nok";
    var in: Io.Reader = .fixed(wire);
    var out_buf: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);

    var conn = Connection.init(&in, &out);

    var body: Io.Writer.Allocating = .init(t.allocator);
    defer body.deinit();
    const r1 = try conn.roundTrip(.{ .host = "test" }, .{ .collect = &body }, .{});
    try t.expectEqual(@as(u16, 200), r1.status);
    try t.expectEqualStrings("hi", body.written());
    try t.expect(conn.reusable);

    const r2 = try conn.roundTrip(.{ .host = "test" }, .discard, .{});
    try t.expectEqual(@as(u64, 2), r2.body_len);
    try t.expect(!conn.reusable); // server said close

    try t.expectError(error.ConnectionNotReusable, conn.roundTrip(.{ .host = "test" }, .discard, .{}));

    // And the request side wrote well-formed HTTP.
    const sent = out.buffered();
    try t.expect(std.mem.startsWith(u8, sent, "GET / HTTP/1.1\r\nhost: test\r\n"));
}

test "request serialization: auth, content-type, body, close" {
    var out_buf: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    try writeRequest(&out, .{
        .method = .PUT,
        .target = "/bucket/key",
        .host = "storage",
        .authorization = "Bearer tok",
        .content_type = "application/json",
        .body = "{}",
        .keep_alive = false,
    });
    const sent = out.buffered();
    try t.expect(std.mem.startsWith(u8, sent, "PUT /bucket/key HTTP/1.1\r\n"));
    try t.expect(std.mem.indexOf(u8, sent, "authorization: Bearer tok\r\n") != null);
    try t.expect(std.mem.indexOf(u8, sent, "content-length: 2\r\n") != null);
    try t.expect(std.mem.indexOf(u8, sent, "connection: close\r\n") != null);
    try t.expect(std.mem.endsWith(u8, sent, "\r\n\r\n{}"));
}

test "a request field that cannot be interpolated is refused, and nothing is written" {
    // Header injection through a URL. Every one of these would otherwise be
    // written verbatim into a request line or a header line, and everything
    // after an embedded CRLF is read by the origin as another header — or,
    // with a second CRLF, as another request entirely.
    const cases = [_]struct { Request, anyerror }{
        // Request line.
        .{ .{ .host = "h", .target = "/a\r\nX-Injected: 1" }, error.InvalidRequestTarget },
        .{ .{ .host = "h", .target = "/a\nX: 1" }, error.InvalidRequestTarget },
        .{ .{ .host = "h", .target = "/a b" }, error.InvalidRequestTarget },
        .{ .{ .host = "h", .target = "" }, error.InvalidRequestTarget },
        // The host is what an origin routes on, so it gets the same rule.
        .{ .{ .host = "h\r\nX: 1", .target = "/" }, error.InvalidRequestTarget },
        .{ .{ .host = "", .target = "/" }, error.InvalidRequestTarget },
        // Header lines. `authorization` is the dangerous one: it is the field
        // most likely to be built from something a caller was handed.
        .{ .{ .host = "h", .authorization = "Bearer x\r\nX: 1" }, error.InvalidRequestHeader },
        .{ .{ .host = "h", .content_type = "text/plain\r\nX: 1" }, error.InvalidRequestHeader },
        .{ .{ .host = "h", .extra = &.{.{ .name = "x", .value = "a\r\nY: 2" }} }, error.InvalidRequestHeader },
        // A name that is not a token: the colon would rename the header, the
        // space would produce a line no origin parses as the caller intended.
        .{ .{ .host = "h", .extra = &.{.{ .name = "x:y", .value = "1" }} }, error.InvalidRequestHeader },
        .{ .{ .host = "h", .extra = &.{.{ .name = "x y", .value = "1" }} }, error.InvalidRequestHeader },
        .{ .{ .host = "h", .extra = &.{.{ .name = "", .value = "1" }} }, error.InvalidRequestHeader },
    };

    for (cases) |case| {
        const req, const want = case;
        var out_buf: [512]u8 = undefined;
        var out: Io.Writer = .fixed(&out_buf);
        try t.expectError(want, writeRequest(&out, req));
        // The refusal has to come before any output. Half a request line on
        // the wire would force the caller to drop a transport that was fine.
        try t.expectEqual(@as(usize, 0), out.end);
    }
}

test "the bytes a valid request is allowed to carry" {
    // The complement of the test above: obs-text and a tab are legal in a
    // field value and must NOT be refused, or the check breaks real requests
    // to make a point. A `?` and a `%` are ordinary target bytes.
    var out_buf: [512]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    try writeRequest(&out, .{
        .host = "example.com",
        .target = "/p%20ath?q=1&r=%C3%A9",
        .content_type = "text/plain;\tcharset=utf-8",
        .extra = &.{.{ .name = "x-note", .value = "caf\xc3\xa9" }},
    });
    try t.expect(std.mem.startsWith(u8, out.buffered(), "GET /p%20ath?q=1&r=%C3%A9 HTTP/1.1\r\n"));
    try t.expect(std.mem.indexOf(u8, out.buffered(), "x-note: caf\xc3\xa9\r\n") != null);
}
