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

### zoxy-io/hparse — measured, and the measurement changed the question

Reproduce: `zig build bench-head -Dhparse -Doptimize=ReleaseFast`.

hparse is a zero-allocation SIMD head parser we already own and already ship
inside zoxy. The question was whether zurl should take it as a dependency; the
measurement answered a more useful one.

**hparse's scanner is genuinely faster than ours.** Decomposed by header count
(ns/head, contiguous input, ReleaseFast; `raw` is `parseResponse` alone,
`full` adds the framing pass over the array it fills):

| headers | zurl | hparse raw | hparse full |
|---|---|---|---|
| 0 (status line only) | 16–17 | **2** | **2** |
| 1 | 31–32 | **4** | **11** |
| 8 | 116–119 | **73–79** | **93–97** |
| 16 | 194–196 | 175–176 | 204 |
| 64 | **656–698** | 688–692 | 758–763 |

Fitted: zurl ≈ 35 ns + 10.0 ns/header; hparse+framing ≈ 18 ns + 11.6 ns/header.
So hparse wins on fixed cost — a bare status line is **8× cheaper**, 2 ns
against 17, because it is pointer arithmetic and magic-integer compares on a
contiguous slice rather than `Io.Reader` vtable calls — and loses slightly on
slope, crossing over around ten headers. Its higher per-header cost is not
inefficiency: it validates every byte against RFC token tables (`key_map`,
`value_map`), which **our parser does not do at all**. See the open question
below.

**The problem is the API, and it is not zurl's problem.** hparse parses a
CONTIGUOUS slice and returns `error.Incomplete`, so a streaming caller must
re-parse from byte zero every time more bytes arrive. Head parsing becomes
O(N²) in the number of segments:

| delivery | small-cl | many-hdr (30 headers) |
|---|---|---|
| whole buffered | zurl 171 / hparse 124 | zurl 361 / hparse 399 |
| 64-byte segments | zurl 161 / hparse 250 | zurl 590 / hparse **4176** |
| 1-byte segments | zurl 1354 / hparse 8990 | zurl 7844 / hparse **250702** |

Scanning for `\r\n\r\n` first and parsing once (`hparse+scan`) removes the
blowup and lands at a tie or worse, because that scan is a second linear pass
over the head — and finding the line ends IS zurl's parse, so we never pay it.

**This matters far more to zoxy than to zurl.** zoxy's `src/http/parser.zig`
documents the same pattern in its own words: *"a partial head returns
`error.Incomplete` and the caller re-parses from byte 0 once more bytes
arrive"*. Measured against zoxy's own limits, one request head, with the
attacker choosing the segmentation:

| head | segment | parses | bytes scanned | CPU/head | amplification |
|---|---|---|---|---|---|
| 8 KiB (default) | 1 B | 8,858 | 39 MB | **8.4 ms** | 4,430× |
| 8 KiB | 64 B | 139 | 623 KB | 131 µs | 70× |
| 64 KiB | 1 B | 66,218 | **2.19 GB** | **371 ms** | 33,110× |

Because zoxy is single-writer-per-loop-thread, that burn happens *inside the
event loop* and stalls every connection on that thread. Slow-loris normally
costs a socket, which the shed ladder is built for; this costs CPU, which no
rung catches. It is the family of zoxy#222 — burn instead of shed.

The fix is in hparse, not in its callers: a resume cursor (offset + headers
already filled + whether the request line is done) so an incomplete parse
continues where it stopped instead of restarting. `parseHeaders` already fails
at clean line boundaries, so the resume point exists; it just is not reported.

**Verdict for zurl: not yet, and for reasons that are now secondary.** Even at
its best hparse saves ~15–30 ns of fixed cost, which is 0.2–0.3% of a 10 µs
round trip; it needs a caller-supplied `[]Header` array with a
`TooManyHeaders` failure zurl's callback API does not have; it cannot express
`HeadTooLong` for a head larger than the buffer, because a contiguous-slice
parser has no equivalent of `takeDelimiterInclusive`'s `StreamTooLong`; and it
is strictly CRLF-only, so a bare-LF head that zurl parses today becomes
`MalformedHeader`. That strictness is *right for an intermediary* — two
parsers disagreeing about where a line ends is request smuggling — and wrong
for a client, where it turns a lenient origin into an outage. Revisit if the
resume cursor lands.

**Open question against ourselves:** hparse validates header name and value
bytes; `src/parser.zig` does not. A header name containing a control
character or a space parses fine here today. RFC 9110 says field names are
tokens, and rule 2 is otherwise strict about exactly this class of thing. Part
of our per-header advantage above is bought by that omission.

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
