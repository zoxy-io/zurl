//! One-shot, deadline-bounded fetch: the control-plane convenience layer.
//!
//! `Connection` does not care where its transport came from; `fetch` is the
//! layer that dials for you. Its deadline is a WHOLE-REQUEST bound enforced by
//! Io cancellation (design rule 3): one number covers DNS, connect, request
//! and response, and it works identically on `Io.Threaded` (which panics on a
//! non-none connect timeout) and on zio. Measured against a server that
//! accepts and never answers: the cancel unwinds the task in ~1 ms.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const connection = @import("connection.zig");
const parser = @import("parser.zig");

pub const default_deadline_ns: u64 = 30 * std.time.ns_per_s;

pub const FetchRequest = struct {
    /// http:// only in v0. https:// returns error.TlsNotImplemented — TLS
    /// arrives as a transport (design rule 5), not as a client rewrite.
    url: []const u8,
    method: std.http.Method = .GET,
    authorization: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    extra: []const connection.Header = &.{},
    body: ?[]const u8 = null,
    sink: connection.Sink = .discard,
    deadline_ns: u64 = default_deadline_ns,
    /// Named in the timeout message. A key or a short label, never a URL — a
    /// URL can carry a token in its query, and logs are public.
    what: []const u8 = "request",
};

pub const Error = error{
    InvalidUrl,
    TlsNotImplemented,
    ConnectFailed,
    OutOfMemory,
} || connection.Error;

const Task = struct {
    io: Io,
    req: *const FetchRequest,
    host_buf: [253]u8 = undefined,
    result: ?(Error!connection.Response) = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(task: *Task) void {
        task.result = task.roundTrip();
        task.done.store(true, .release);
    }

    fn roundTrip(task: *Task) Error!connection.Response {
        const io = task.io;
        const req = task.req;

        const uri = std.Uri.parse(req.url) catch return error.InvalidUrl;
        if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.TlsNotImplemented;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidUrl;
        const port: u16 = uri.port orelse 80;

        const host_component = uri.host orelse return error.InvalidUrl;
        const host = switch (host_component) {
            .raw => |h| h,
            .percent_encoded => |h| h,
        };
        if (host.len == 0 or host.len > task.host_buf.len) return error.InvalidUrl;

        // One buffer serves the whole exchange: dial by IP literal when the
        // host is one, by name otherwise.
        var stream: net.Stream = blk: {
            if (net.IpAddress.parse(host, port)) |addr| {
                break :blk addr.connect(io, .{ .mode = .stream }) catch return error.ConnectFailed;
            } else |_| {
                const name = net.HostName.init(host) catch return error.InvalidUrl;
                break :blk name.connect(io, port, .{ .mode = .stream }) catch return error.ConnectFailed;
            }
        };
        defer stream.close(io);

        var rbuf: [16 * 1024]u8 = undefined;
        var wbuf: [4 * 1024]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        var w = stream.writer(io, &wbuf);

        // origin-form target: path, plus query when present.
        var target_buf: [2048]u8 = undefined;
        var tw: Io.Writer = .fixed(&target_buf);
        const path = uri.path.percent_encoded;
        tw.writeAll(if (path.len == 0) "/" else path) catch return error.InvalidUrl;
        if (uri.query) |q| tw.print("?{s}", .{q.percent_encoded}) catch return error.InvalidUrl;

        var conn = connection.Connection.init(&r.interface, &w.interface);
        return conn.roundTrip(.{
            .method = req.method,
            .target = tw.buffered(),
            .host = host,
            .authorization = req.authorization,
            .content_type = req.content_type,
            .extra = req.extra,
            .body = req.body,
            // One request per fetch: close is what gives a reply with no
            // discoverable body end somewhere to stop (a60a95c), and there is
            // no pool that reuse would feed.
            .keep_alive = false,
        }, req.sink, .{});
    }
};

/// One bounded request. `null` means the deadline elapsed and the request was
/// cancelled — `Io.Group.cancel` joins before returning, so by the time this
/// returns nothing holds a reference to any borrowed field of `req`.
///
/// The wait is a RACE, not a poll: the worker and a deadline sleeper both push
/// into a queue and the first event wins. The first draft polled a done-flag
/// every 20 ms, and bench/e2e.zig convicted it on its first run — a 120 us
/// loopback request cost 20 ms of wall clock, a 166x latency floor that a
/// correctness test can never see. Design rule 8 is not decorative.
pub fn fetch(io: Io, req: FetchRequest) Error!?connection.Response {
    var task: Task = .{ .io = io, .req = &req };

    const Event = enum { done, deadline };
    var q_buf: [2]Event = undefined;
    var queue: Io.Queue(Event) = .init(&q_buf);

    const Race = struct {
        fn work(tk: *Task, q: *Io.Queue(Event), rio: Io) void {
            tk.run();
            q.putOne(rio, .done) catch {};
        }
        fn sleeper(ns: u64, q: *Io.Queue(Event), rio: Io) void {
            rio.sleep(.fromNanoseconds(ns), .awake) catch return;
            q.putOne(rio, .deadline) catch {};
        }
    };

    var group: Io.Group = .init;
    group.async(io, Race.work, .{ &task, &queue, io });
    group.async(io, Race.sleeper, .{ req.deadline_ns, &queue, io });

    const event = queue.getOneUncancelable(io) catch Event.deadline;
    group.cancel(io);

    switch (event) {
        .done => {
            // The worker finished at the wire; its result stands, error or not.
            return try task.result.?;
        },
        .deadline => {
            // The cancel above unwound the worker mid-request. Whatever
            // partial error that unwinding produced is noise; the story is
            // the deadline.
            std.debug.print("zurl: {s} timed out after {d}ms\n", .{
                req.what, req.deadline_ns / std.time.ns_per_ms,
            });
            return null;
        },
    }
}

// ---------------------------------------------------------------------------
// tests
const t = std.testing;

test "https and garbage schemes are refused before any dial" {
    var threaded: Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try t.expectError(error.TlsNotImplemented, fetch(io, .{ .url = "https://example.com/" }));
    try t.expectError(error.InvalidUrl, fetch(io, .{ .url = "gopher://example.com/" }));
    try t.expectError(error.InvalidUrl, fetch(io, .{ .url = "not a url" }));
}

test "fetch against a live loopback server, deadline against a black hole" {
    var threaded: Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const Serve = struct {
        fn run(srv: *net.Server, sio: Io) void {
            // Two connections: answer the first, black-hole the second.
            {
                var s = srv.accept(sio) catch return;
                defer s.close(sio);
                var rb: [2048]u8 = undefined;
                var rr = s.reader(sio, &rb);
                // Read until the blank line, then respond.
                while (true) {
                    const line = rr.interface.takeDelimiterInclusive('\n') catch return;
                    if (line.len <= 2) break;
                }
                var wb: [512]u8 = undefined;
                var ww = s.writer(sio, &wb);
                ww.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 4\r\n\r\nzurl") catch return;
                ww.interface.flush() catch return;
            }
            {
                var s = srv.accept(sio) catch return;
                defer s.close(sio);
                sio.sleep(.fromNanoseconds(30 * std.time.ns_per_s), .awake) catch {};
            }
        }
    };
    var group: Io.Group = .init;
    defer group.cancel(io);
    group.async(io, Serve.run, .{ &server, io });

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/hello", .{port});

    var body: Io.Writer.Allocating = .init(t.allocator);
    defer body.deinit();
    const res = (try fetch(io, .{ .url = url, .sink = .{ .collect = &body } })).?;
    try t.expectEqual(@as(u16, 200), res.status);
    try t.expectEqualStrings("zurl", body.written());

    // Second request hits the black hole; the deadline must hand back null
    // rather than hanging — nightly run #9's 71 minutes, in miniature.
    const timed_out = try fetch(io, .{
        .url = url,
        .deadline_ns = 300 * std.time.ns_per_ms,
        .what = "black hole",
    });
    try t.expectEqual(@as(?connection.Response, null), timed_out);
}
