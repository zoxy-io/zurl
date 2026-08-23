# zurl

An **experimental** `std.Io`-native HTTP/1.1 client for Zig 0.16 — zero
allocation, one dependency, and a whole-request deadline that actually fires.

It grew out of the zoxy benchmark harness, where three separate HTTP
implementations produced, between them: a segfault only in the ReleaseFast musl
build, a 71-minute unbounded hang, a deliberate leak-on-timeout, a 204 that hung
forever, and a chunked body read as plain text for months. Every one of those is
a design rule here — [docs/DESIGN.md](docs/DESIGN.md) has the eight of them.

> Private while it is an experiment. The API moves.

## Requirements

Zig **0.16.0** exactly — `std.Io` moves, so 0.15 and master are both wrong.

One dependency, [zoxy-io/hparse](https://github.com/zoxy-io/hparse), for the
head scan. It is std-only and does no I/O, so zurl stays a leaf package: it
brings no runtime and no TLS stack that could collide with one you already pin.

```sh
zig fetch --save git+https://github.com/zoxy-io/zurl
```

```zig
const zurl = b.dependency("zurl", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zurl", zurl.module("zurl"));
```

## Use

Every request is bounded. `fetch` returns `null` when the deadline elapsed —
that is not an error case you may forget to handle, it is the return type.

```zig
var body: std.Io.Writer.Allocating = .init(gpa);
defer body.deinit();

const res = try zurl.fetch(io, .{
    .url = "http://127.0.0.1:8080/metrics",
    .sink = .{ .collect = &body },
    .deadline_ns = 5 * std.time.ns_per_s,
    .what = "metrics",           // named in the timeout message, never a URL
}) orelse return error.TimedOut;

if (!res.ok()) return error.BadStatus;
std.debug.print("{d} bytes\n", .{body.written().len});
```

**Bodies go to a sink; there is no way to forget one.** Pick how you want it:

```zig
.sink = .discard,                 // HEAD, DELETE, a webhook's 204
.sink = .{ .collect = &body },    // keep the whole thing
.sink = .{ .lines = &line_sink }, // parse a line at a time, keep none of it
.sink = .{ .stream = writer },    // any other Io.Writer
```

`lines` is what lets a 1.5 MiB Prometheus exposition be parsed without ever
holding more than one line. Lines too long for `carry` are dropped whole and
counted, never truncated — a truncated metric line still parses, and reports a
wrong number.

```zig
var buf: [64 * 1024]u8 = undefined;
var carry: [8 * 1024]u8 = undefined;
var sink = zurl.LineSink.init(&buf, &carry, &ctx, onLine);
```

### Reading response headers

One callback, fired per header and again per chunked trailer, in order, with
values already trimmed. `name` and `value` point into the reader's buffer and
the body is about to overwrite them — **copy what you want to keep.** A map
would have to allocate, and zurl does not.

```zig
fn onHeader(ctx: ?*anyopaque, name: []const u8, value: []const u8) void {
    const wait: *?u32 = @ptrCast(@alignCast(ctx.?));
    if (std.ascii.eqlIgnoreCase(name, "retry-after"))
        wait.* = std.fmt.parseInt(u32, value, 10) catch null;
}

var retry_after: ?u32 = null;
const res = try zurl.fetch(io, .{
    .url = url,
    .on_header = onHeader,
    .ctx = &retry_after,
}) orelse return error.TimedOut;
```

### https

Trust anchors are **yours**. There is no default, on purpose: loading a store
allocates and zurl does not, and a caller who silently got "verify nothing"
would hold an https URL that looks secure and is not. An https URL with no
`tls` config is `error.TlsNotConfigured`, refused before anything is dialled.

```zig
var certificates: std.crypto.Certificate.Bundle = .empty;
defer certificates.deinit(gpa);
try certificates.rescan(gpa, io, .now(io, .real));   // once, at startup
var lock: std.Io.RwLock = .init;

const res = try zurl.fetch(io, .{
    .url = "https://api.example.com/v1/things",
    .authorization = "Bearer …",
    .sink = .{ .collect = &body },
    .tls = .{ .ca = .{ .bundle = .{
        .gpa = gpa, .lock = &lock, .certificates = &certificates,
    } } },
}) orelse return error.TimedOut;
```

### Many requests, one connection

`fetch` dials, sends `connection: close`, and hangs up — right for a poll or a
one-shot, wasteful for a dozen calls to one origin. `Connection` is the layer
underneath: a `*Io.Reader` and a `*Io.Writer`, and it does not care where they
came from — plain TCP, std TLS, zrk's ztls, or two fixed buffers in a test.

```zig
var conn = zurl.Connection.init(transport.reader(), transport.writer());
const res = try conn.roundTrip(.{ .host = "example.com", .target = "/" }, sink, .{});
```

## What it does

Framing is the library's job, always: content-length, chunked (with trailers),
close-delimited, bodyless statuses, `Transfer-Encoding` beating
`Content-Length`, conflicting `Content-Length` refused. You never see an
undecoded byte and never choose whether a 204 has a body.

Works identically on `Io.Threaded` and zio — both are production backends for
its consumers, so a mechanism that only works on one is not a mechanism zurl
uses.

**Not yet:** redirects are not followed, a `content-encoding` zurl does not
understand is not yet refused, and no `user-agent` is sent.
[docs/SCOPE.md](docs/SCOPE.md) is the list, in the order it will be built, and
says what is deliberately refused (HTTP/2, cookies, connection pools, signing
schemes).

## Numbers

ReleaseFast, 8-core x86_64_v3 Linux, 2026-08-23. Reproduce with
`zig build bench-parse -Doptimize=ReleaseFast` and `bench-e2e`.

| shape | ns/resp | throughput |
|---|---|---|
| small-cl (8 headers, 128 B body) | 121 | 8.3 M resp/s |
| zrk-1k (proxy-bench shape, 1 KiB body) | **48** | 20.8 M resp/s, 22.9 GB/s |
| cadvisor (1.5 MiB chunked → `LineSink`) | 0.19 ms/scrape | 8.0 GB/s, 14.7 k lines |

End-to-end against `std.http.Client` on loopback: parity keep-alive
(syscall-bound), ~1.8× on a fresh connection per request. The parser is not the
story at the wire — 48 ns inside a ~10 µs round trip is 0.5%.

Methodology, the A/B bands behind those figures, and what assertions cost live
with [rule 8](docs/DESIGN.md); the comparison against std is in
[docs/RESEARCH.md](docs/RESEARCH.md).

## Docs

| | |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | the eight rules, each traceable to an incident — *what must be true* |
| [docs/SCOPE.md](docs/SCOPE.md) | what is in, what is the caller's, what is refused, and what is next |
| [docs/RESEARCH.md](docs/RESEARCH.md) | what exists in the ecosystem and why none of it fits |
| [docs/TIGER_STYLE.md](docs/TIGER_STYLE.md) | how it is written |
| [CLAUDE.md](CLAUDE.md) | how a change lands: slices, and the gates each one passes |
