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
ecosystem and why none of it fits). How it is written and how a change
lands: [docs/TIGER_STYLE.md](docs/TIGER_STYLE.md) and [CLAUDE.md](CLAUDE.md).

Private while it is an experiment. Zig 0.16.0, zero dependencies.

## Shape

```
parser      head + framed body → sink; zero-allocation; owns ALL framing
            (content-length / chunked+trailers / close-delimited, bodyless
            statuses, TE-beats-CL, conflicting CL refused); fuzzed against
            segmentation invariance
Connection  request/response over an injected *Io.Reader + *Io.Writer —
            plain TCP, std TLS, zrk's ztls, or a fixed buffer in a test
fetch       URL in, deadline-bounded Response out; the deadline is a race
            (worker vs sleeper through an Io.Queue), never a poll
Sink        discard | collect | lines (LineSink) | stream — no "none"
tls         std.crypto.tls as a TRANSPORT: in a *Io.Reader + *Io.Writer,
            out a *Io.Reader + *Io.Writer. Trust anchors are the caller's,
            because loading them allocates and zurl does not
```

Works identically on `Io.Threaded` and zio, because both are production
backends for its consumers. https works through the same seam: `fetch` takes a
`tls` config carrying caller-owned trust anchors, splices a
`std.crypto.tls.Client` into the transport, and `Connection` cannot tell the
difference. There is no default trust store on purpose — building one
allocates, and a caller who silently got "verify nothing" would have an https
URL that looks secure and is not.

## Numbers

ReleaseFast, 8-core x86_64_v3 Linux box, 2026-08-23. Reproduce with
`zig build bench-parse -Doptimize=ReleaseFast` and `bench-e2e`.

State the power state alongside any number taken on a laptop: the same box
and the same commit measure 1.7x slower across every row on battery
(`powersave`, 1.2 GHz) than on AC (4.3 GHz boost). That is why the rule is
bands compared inside one session against a baseline re-run in that session,
never a number carried over from another day.

**Parser microbench** (`Reader.fixed`, transport removed):

| shape | ns/resp | throughput |
|---|---|---|
| small-cl (8 headers, 128 B body) | 116 | 8.6 M resp/s |
| zrk-1k (proxy-bench shape, 1 KiB body) | **61** | 16.5 M resp/s, 18.4 GB/s |
| cadvisor (1.5 MiB chunked → LineSink) | 0.18 ms/scrape | 8.2 GB/s, 14.7 k lines |

Assertions (docs/TIGER_STYLE.md) are `std.debug.assert`, so they are absent
from the table above *by construction* — ReleaseFast compiles them out.
Measured where they do run — ReleaseSafe, four A/B pairs interleaved against
the same code without them: small-cl 129–132 → 133–137 ns, zrk-1k 68–70 →
70–74 ns, cadvisor unmoved at 0.19–0.20 ms. Three to five percent on the
head-heavy shapes and nothing on the body-heavy one, which spends its time in
`streamExact64` and `LineSink.feed` rather than in the head.

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
- [x] TLS transport adapter over `std.crypto.tls` — `src/tls.zig`, one
      adapter and no branch anywhere above it. Verified live by
      `zig build tls-smoke`, which is a separate step because std ships no TLS
      server and a unit test that needs DNS is a gate people learn to ignore:
      example.com matches `curl` byte for byte (200, 559 bytes), google.com
      moves 89 KB of chunked body through it, and expired / wrong-host /
      self-signed / untrusted-root all come back `TlsCertificateInvalid` with
      std's precise reason available through `tls.Diagnostics`.
- [ ] point the zoxy benchmark's control plane at zurl and delete its std
      wrapper
- [ ] zio-backend run of bench-e2e (numbers above are `Io.Threaded`)
- [x] fuzz the parser — `zig build fuzz`, with design rule 4 as the oracle.
      The same bytes parsed whole, at a split, and one byte per read must give
      one answer on every channel a caller can observe: the verdict and body
      bytes, the header/trailer callback sequence (whose slices live in the
      reader's buffer — the memory segmentation actually changes), and the
      offset the parse left the stream at, because two parses can agree on
      every body byte and still frame the connection differently. Every seed
      shape at every split position plus 20 k mutations run per slice, in
      0.15 s. It earned its keep immediately: the first run with the header
      channel enabled found the trailer section accepting a field the head
      refuses (`0\r\n: v\r\n\r\n`) — the same bytes meaning two different
      things depending on where in the message they appeared. Fixed, with the
      shape now a seed; 3 M further mutations across six seeds found nothing.
      Zig 0.16.0's coverage-guided `--fuzz` does not build (a toolchain bug in
      its own bundled `test_runner.zig:566`), so the mutator is in-tree and
      seeded.
