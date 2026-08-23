# zurl

An **experimental** std.Io-native HTTP/1.1 client for Zig, grown out of the
zoxy benchmark harness — where three separate HTTP implementations at three
levels of completeness produced, between them: a segfault only in the
ReleaseFast musl build, a 71-minute unbounded hang, a deliberate
leak-on-timeout, a 204 that hung forever, and a chunked body read as plain
text for months.

Every one of those is a design rule here. **Start with
[docs/DESIGN.md](docs/DESIGN.md)** (the eight rules, each traceable to an
incident) and [docs/RESEARCH.md](docs/RESEARCH.md) (what exists in the
ecosystem and why none of it fits).

Private while it is an experiment. Zig 0.16.0, zero dependencies.

## Shape

```
parser      head + framed body → sink; zero-allocation; owns ALL framing
            (content-length / chunked+trailers / close-delimited, bodyless
            statuses, TE-beats-CL, conflicting CL refused)
Connection  request/response over an injected *Io.Reader + *Io.Writer —
            plain TCP, std TLS, zrk's ztls, or a fixed buffer in a test
fetch       URL in, deadline-bounded Response out; the deadline is a race
            (worker vs sleeper through an Io.Queue), never a poll
Sink        discard | collect | lines (LineSink) | stream — no "none"
```

Works identically on `Io.Threaded` and zio, because both are production
backends for its consumers. TLS is not in-tree yet: `fetch` refuses https
(`error.TlsNotImplemented`); a `std.crypto.tls` transport adapter is the v1
item, and the transport seam is already the API.

## Numbers

ReleaseFast, 8-core x86_64_v3 Linux box, 2026-08-23. Reproduce with
`zig build bench-parse -Doptimize=ReleaseFast` and `bench-e2e`.

**Parser microbench** (`Reader.fixed`, transport removed):

| shape | ns/resp | throughput |
|---|---|---|
| small-cl (8 headers, 128 B body) | 116 | 8.6 M resp/s |
| zrk-1k (proxy-bench shape, 1 KiB body) | **61** | 16.5 M resp/s, 18.4 GB/s |
| cadvisor (1.5 MiB chunked → LineSink) | 0.18 ms/scrape | 8.2 GB/s, 14.7 k lines |

**End-to-end loopback** vs `std.http.Client`, same server, same Io, 1 KiB
body, three runs:

| discipline | zurl | std.http.Client | |
|---|---|---|---|
| keep-alive, one connection | 91–101 k req/s | 88–107 k req/s | **parity** (syscall-bound) |
| fresh connection per request | 15.5–20.8 k req/s | 9.2–11.2 k req/s | **~1.8×** |

Two conclusions worth stating plainly:

* **The parser is not the story at the wire.** 61 ns of parse inside a ~10 µs
  loopback round trip is 0.6%. Any pitch to zrk rests on API and correctness,
  not speed — and per the standing rule, zrk adopts nothing without running
  these numbers itself in its own harness.
* **The benchmark caught a real API defect on its first run.** The first
  `fetch` waited on its deadline by polling a flag every 20 ms — a 166×
  latency floor (50 req/s) that all 16 correctness tests passed over without
  blinking. It is now a queue race and fetch does 18 k req/s. Design rule 8
  earned its place on day one.

## Status / next

- [x] parser + framing property tests (segmentation invariance at every split)
- [x] Connection over injected transports, keep-alive bookkeeping
- [x] deadline-bounded fetch (DNS via `HostName.connect`, plain HTTP)
- [x] parse + e2e benchmarks
- [ ] TLS transport adapter over `std.crypto.tls` (then: point the zoxy
      benchmark's control plane at zurl and delete its std wrapper)
- [ ] zio-backend run of bench-e2e (numbers above are `Io.Threaded`)
- [ ] fuzz the parser (the SegmentedReader harness is fuzz-shaped already)
