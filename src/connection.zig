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

pub const Error = parser.Error || Io.Writer.Error || error{
    /// A previous response on this connection said close (or was
    /// close-delimited, or errored): HTTP framing forbids another request.
    ConnectionNotReusable,
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
        assert(req.host.len > 0);
        assert(req.target.len > 0);

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
        assert(req.host.len > 0);
        assert(req.target.len > 0);

        if (!c.reusable) return error.ConnectionNotReusable;
        // The body is deliberately left on the wire, so nothing downstream can
        // know where the next response would begin.
        c.reusable = false;
        try writeRequest(c.out, req);
        return parser.parseHead(c.in, opts);
    }
};

pub fn writeRequest(out: *Io.Writer, req: Request) Io.Writer.Error!void {
    // HTTP/1.1 makes Host mandatory, and an empty origin-form target is not a
    // request line any origin will answer. Both are ours to get right, so both
    // are assertions rather than errors.
    assert(req.host.len > 0);
    assert(req.target.len > 0);

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
