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
const assert = std.debug.assert;
const net = std.Io.net;
const connection = @import("connection.zig");
const tls_transport = @import("tls.zig");

pub const default_deadline_ns: u64 = 30 * std.time.ns_per_s;

pub const FetchRequest = struct {
    /// http:// or https://. TLS arrives as a transport (design rule 5), so
    /// https needs `tls` set and changes nothing above the transport seam.
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
    /// Required for https, and unused for http.
    ///
    /// There is no default, and that is deliberate: the only default worth
    /// having is the system trust store, loading it allocates, and zurl
    /// allocates nothing. A caller that silently got `no_verification`
    /// instead would have an https URL that looks secure and is not.
    tls: ?tls_transport.Config = null,
};

pub const Error = error{
    InvalidUrl,
    /// An https URL arrived with no `tls` config. Distinct from a TLS
    /// failure: nothing was dialed and nothing was wrong with the peer.
    TlsNotConfigured,
    ConnectFailed,
    OutOfMemory,
} || connection.Error || tls_transport.Error;

/// The longest legal DNS name, and so the longest host `fetch` will dial. It
/// is a bound, not storage: the host is a slice of the caller's URL and is
/// never copied anywhere.
const host_bytes_max: usize = 253;

const Task = struct {
    io: Io,
    req: *const FetchRequest,
    result: ?(Error!connection.Response) = null,

    fn run(task: *Task) void {
        // One Task serves one request; a second run would overwrite a result
        // the racing `fetch` may already be about to read.
        assert(task.result == null);

        task.result = task.roundTrip();
    }

    fn roundTrip(task: *Task) Error!connection.Response {
        const io = task.io;
        const req = task.req;

        // The URL is whatever string the caller was handed — from a config
        // file, or from a request one hop upstream. Every rejection of it is
        // an error, never an assertion: a consumer that forwards someone
        // else's URL must not be able to panic this library from off-box.
        if (req.url.len == 0) return error.InvalidUrl;
        const uri = std.Uri.parse(req.url) catch return error.InvalidUrl;
        const secure = scheme: {
            if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) break :scheme true;
            if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) break :scheme false;
            return error.InvalidUrl;
        };
        // Refused before the dial, not after: an https URL with no trust
        // configuration is a caller mistake, and finding that out only once a
        // connection is open wastes a round trip and a socket.
        if (secure and req.tls == null) return error.TlsNotConfigured;

        // Port 0 means "let the kernel choose" to a listener and nothing at all
        // to a dialer, so it is a bad URL rather than an assertion: it reaches
        // us from whatever string the caller was handed.
        const port: u16 = uri.port orelse if (secure) 443 else 80;
        if (port == 0) return error.InvalidUrl;

        const host_component = uri.host orelse return error.InvalidUrl;
        const host = switch (host_component) {
            .raw => |h| h,
            .percent_encoded => |h| h,
        };
        if (host.len == 0 or host.len > host_bytes_max) return error.InvalidUrl;

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

        // origin-form target: path, plus query when present.
        var target_buf: [2048]u8 = undefined;
        var tw: Io.Writer = .fixed(&target_buf);
        const path = uri.path.percent_encoded;
        tw.writeAll(if (path.len == 0) "/" else path) catch return error.InvalidUrl;
        if (uri.query) |q| tw.print("?{s}", .{q.percent_encoded}) catch return error.InvalidUrl;
        // A URI with an authority has an empty path or one that begins with a
        // slash, and the empty case was just replaced — so origin-form holds.
        assert(tw.buffered().len > 0);
        assert(tw.buffered()[0] == '/');

        // The two transports get their own frames on purpose. TLS needs four
        // buffers and two of them must each hold a whole ciphertext record, so
        // its frame is ~66 KiB; a plain-HTTP fetch has no business reserving
        // that. Zig sizes a frame for all of its own locals, not for the
        // branch taken, so the split is what keeps the http path at 20 KiB.
        if (secure) return task.exchangeTls(&stream, host, tw.buffered());
        return task.exchangePlain(&stream, host, tw.buffered());
    }

    /// The request every exchange sends, built once so the two transports
    /// cannot drift apart in what they ask for.
    fn request(task: *Task, host: []const u8, target: []const u8) connection.Request {
        assert(host.len > 0);
        assert(target.len > 0);

        return .{
            .method = task.req.method,
            .target = target,
            .host = host,
            .authorization = task.req.authorization,
            .content_type = task.req.content_type,
            .extra = task.req.extra,
            .body = task.req.body,
            // One request per fetch: close is what gives a reply with no
            // discoverable body end somewhere to stop (a60a95c), and there is
            // no pool that reuse would feed.
            .keep_alive = false,
        };
    }

    fn exchangePlain(
        task: *Task,
        stream: *net.Stream,
        host: []const u8,
        target: []const u8,
    ) Error!connection.Response {
        assert(host.len > 0);
        assert(target.len > 0);

        const io = task.io;

        var read_buffer: [16 * 1024]u8 = undefined;
        var write_buffer: [4 * 1024]u8 = undefined;
        var r = stream.reader(io, &read_buffer);
        var w = stream.writer(io, &write_buffer);

        var conn = connection.Connection.init(&r.interface, &w.interface);
        return conn.roundTrip(task.request(host, target), task.req.sink, .{});
    }

    /// The same exchange with a TLS session spliced into the transport, which
    /// is the entire difference (design rule 5). `Connection` is handed two
    /// pointers and cannot tell which kind it got.
    fn exchangeTls(
        task: *Task,
        stream: *net.Stream,
        host: []const u8,
        target: []const u8,
    ) Error!connection.Response {
        const io = task.io;
        // Checked before the dial; re-read here rather than threaded through.
        const config = task.req.tls.?;

        // The encrypted side must hold one whole record in each direction —
        // std asserts it for the reader and demands it of the writer.
        var ciphertext_in: [tls_transport.buffer_bytes_min]u8 = undefined;
        var ciphertext_out: [tls_transport.buffer_bytes_min]u8 = undefined;
        // The plaintext side is sized like the http path: the read buffer is
        // what bounds the longest response head line the parser can see.
        var plaintext_in: [16 * 1024]u8 = undefined;
        var plaintext_out: [4 * 1024]u8 = undefined;

        var r = stream.reader(io, &ciphertext_in);
        var w = stream.writer(io, &ciphertext_out);
        // The buffers above are sized from `buffer_bytes_min`, so a
        // TlsBufferTooSmall from here would mean the stream kept part of what
        // it was handed — a failure no caller could fix, wearing an error that
        // says "caller bug".
        assert(r.interface.buffer.len >= tls_transport.buffer_bytes_min);
        assert(w.interface.buffer.len >= tls_transport.buffer_bytes_min);

        var transport: tls_transport.Transport = undefined;
        try transport.init(.{
            .io = io,
            .input = &r.interface,
            .output = &w.interface,
            .host = host,
            .read_buffer = &plaintext_in,
            .write_buffer = &plaintext_out,
            .config = config,
        });
        // close_notify before the socket goes, so the peer can tell a finished
        // session from a truncation. Ordered ahead of `stream.close` by being
        // deferred later than it.
        defer transport.close();

        var conn = connection.Connection.init(transport.reader(), transport.writer());
        return conn.roundTrip(task.request(host, target), task.req.sink, .{});
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
    // A zero deadline would race the sleeper against a request that has not
    // started; `what` is what the timeout message names, so an empty one turns
    // the only diagnostic this function emits into noise.
    assert(req.deadline_ns > 0);
    assert(req.what.len > 0);

    var task: Task = .{ .io = io, .req = &req };

    const Event = enum { done, deadline };
    var q_buf: [2]Event = undefined;
    var queue: Io.Queue(Event) = .init(&q_buf);

    const Race = struct {
        fn work(tk: *Task, q: *Io.Queue(Event), rio: Io) void {
            tk.run();
            // A failed put means the deadline already won and `fetch` has
            // stopped listening. The result is still in the Task; nobody will
            // read it, and there is nothing here that could react instead.
            q.putOne(rio, .done) catch {};
        }
        fn sleeper(ns: u64, q: *Io.Queue(Event), rio: Io) void {
            // A cancelled sleep is the ordinary outcome — the request finished
            // first — and it means the deadline never elapsed, so returning
            // without posting anything is exactly right.
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
            // `group.cancel` above joined it, so the write is complete and
            // visible without further synchronisation.
            assert(task.result != null);
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

test "an https url without trust configuration is refused before any dial" {
    var threaded: Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // No `tls` field: there is no default trust store, because building one
    // allocates and zurl does not. Refused up front, before a socket exists —
    // if this ever dialed first, a typo'd https URL would cost a round trip
    // and the failure would look like the peer's fault.
    try t.expectError(error.TlsNotConfigured, fetch(io, .{ .url = "https://example.com/" }));
    // ...and with a config it gets past the scheme check, so the refusal is
    // about the missing configuration and not about https itself.
    try t.expectError(error.InvalidUrl, fetch(io, .{
        .url = "https://",
        .tls = .{ .ca = .insecure_no_verification },
    }));
    try t.expectError(error.InvalidUrl, fetch(io, .{ .url = "gopher://example.com/" }));
    try t.expectError(error.InvalidUrl, fetch(io, .{ .url = "not a url" }));
    // Every one of these is a string the caller was handed, so every one is an
    // error. A leaf library that panics on a bad URL panics its consumer.
    try t.expectError(error.InvalidUrl, fetch(io, .{ .url = "" }));
    try t.expectError(error.InvalidUrl, fetch(io, .{ .url = "http://example.com:0/" }));
    try t.expectError(error.InvalidUrl, fetch(io, .{ .url = "http:///nohost" }));
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
