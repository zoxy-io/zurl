# Why zurl, and what already exists

*Survey date: 2026-08-23. Private experiment; revisit before anything ships.*

## The problem this repo exists to study

The zoxy benchmark harness ended up with **three HTTP/1.1 implementations at
three levels of completeness**, and the least complete one had the subtlest
job:

| Where | What | Fate |
|---|---|---|
| `bench/src/http.zig` | bounded fetch for the cloud control plane | rewritten twice; the first version deliberately leaked on timeout because it could not cancel a thread |
| `bench/src/cadvisor.zig` | hand-rolled GET + streaming parse | read a chunked body as plain text for months — every 2 KiB a hex chunk-size line was spliced into whatever metric line straddled the boundary, and which series died depended on byte offset |
| `zrk/src/http.zig` | hot-path response parser in the load generator | correct and fast, but *discards* bodies by design — it cannot serve a client |

Every bug in the first two was a bug a shared, correct client would have made
structurally impossible. That is the experiment: can one API serve all these
shapes without giving up what each one needs?

## Ecosystem survey

### std.http.Client (Zig 0.16)

The incumbent, and what `bench/src/http.zig` v2 wraps today.

* **Io-aware end to end** — holds an `Io`, threads it through connect/read/
  write. We measured that cancelling its `Io.Group` unwinds a blocked `fetch`
  in **1 ms under `Io.Threaded` and 0 ms under zio** against a server that
  accepts and never answers.
* **No deadline of any kind** — the bound has to be built around it (that is
  what bench does).
* **[#25181](https://github.com/ziglang/zig/issues/25181)** (open, milestone
  *urgent*): hangs on a 204 with `keep_alive` — it tries to read a body that
  RFC 9112 says must not exist. The benchmark repo hit this exact class
  independently (`a60a95c`) and works around it by never using keep-alive.
* **[#25015](https://github.com/ziglang/zig/issues/25015)** (open): blocks
  forever on larger HTTPS payloads unless `write_buffer_size` is raised.
* Ships TLS + certificate verification, redirects, a connection pool — the
  batteries a control plane wants and a parser bench does not.

### dusty — github.com/lalinsky/dusty

The closest neighbor, by the **author of zio** (the runtime both zoxy repos
already pin). Client + server on `std.Io`, HTTP/1.0/1.1, WebSocket, SSE,
connection pooling, Unix sockets.

* Parser is **llhttp** — NodeJS's parser, i.e. a C dependency.
* TLS via **tls.zig**, optional.
* **No timeout/deadline story** in the docs at all.
* No benchmarks published.

Adopting it would mean a C parser dependency and building the deadline layer
anyway — the deadline layer being most of what our incidents were about. Worth
watching; not worth adopting today. If zurl's parser benches poorly, dusty's
llhttp numbers are the thing to compare against before writing a SIMD parser.

### The rest

* **zio** — not a client; the runtime everything must run on unmodified.
  zurl's rule: zio enters through `std.Io`, never through `build.zig.zon`.
* **httpx.zig, zig-http-concurrent** — retry engines, circuit breakers,
  HTTP/2/3 claims. Different altitude: they are frameworks above a client;
  zurl is the layer below them.
* **libcurl bindings (zig-curl class)** — own event loop, C everything, no
  `std.Io`. Non-starters for the "runs on zio unmodified" requirement.
* **`std.Io.Evented`** — the io_uring/kqueue std backend is still WIP and does
  not compile as of 0.16; Threaded and zio are the two real backends, and both
  must work.

## Our usage catalog — the API's requirements, from real call sites

| Consumer | Shape | Needs |
|---|---|---|
| `ycs.zig` (Object Storage) | PUT/GET/HEAD/DELETE, Bearer auth | collect + discard sinks, deadline, TLS, DNS |
| `discord.zig` (webhook) | POST multipart, retry loop above it | discard sink, deadline, TLS; 204 must not hang |
| `cadvisor.zig` (metrics scrape) | GET ~2 MB exposition at 1 Hz **inside the load generator's process** | streaming sink, zero accumulation, decoded framing, whole-request deadline |
| `suite.probeOnce` (warm probe) | status line only, over **zrk's TLS specifically** — a handshake the probe accepts must be one the measurement accepts | transport injection, head-only parse |
| `zrk/connection.zig` (hot path) | 67k req/s across 4 threads, keep-alive, byte counting | parser at sub-µs/response; body discard fast path; **adoption gated on measured parity, never assumed** |

The last row is the bar for the benchmarks in `bench/`: zrk's hand-rolled
parser is the number to match before anyone proposes swapping it — and the
line we drew stands regardless: *zurl for control planes; a load generator's
inner loop only ever on measured parity.*

## Conclusion — the niche is real

Nothing surveyed offers: **std-only leaf package + whole-request deadline as a
first-class primitive + injected transport + sink-based bodies + a benchmark
suite in-repo**. std.http.Client has the batteries but two open hang bugs and
no deadline; dusty has the protocol surface but a C parser and no deadline;
everything else is a different layer. That intersection is exactly the set of
properties the benchmark repo had to build ad hoc, twice.

Sources:
- [Async I/O in Zig 0.16, today — Lukáš Lalinský](https://lalinsky.com/2026/05/11/async-io-in-zig-016-today.html)
- [Zig's New Async I/O — Loris Cro](https://kristoff.it/blog/zig-new-async-io/)
- [dusty](https://github.com/lalinsky/dusty) · [zio](https://github.com/lalinsky/zio)
- [ziglang/zig#25181](https://github.com/ziglang/zig/issues/25181) · [ziglang/zig#25015](https://github.com/ziglang/zig/issues/25015)
- [httpx.zig](https://muhammad-fiaz.github.io/httpx.zig/) · [zig-http-concurrent](https://github.com/quantum-encoding/zig-http-concurrent)
