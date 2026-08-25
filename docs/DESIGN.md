# Design rules

Every rule below is traceable to an incident that cost a real run in the zoxy
benchmark harness. The commit hashes refer to zoxy-io/benchmark.

## 1. A sink, never an optional writer

`d4ad5fa`: omitting `response_writer` segfaulted inside std's own discard path
— only in the ReleaseFast static-musl build CI ships, in no build mode you
would develop in. It killed `bench wait` two seconds after the fleet came up.

So `Sink` is a union with no "none" variant: `discard`, `collect`, `stream`.
Forgetting to route the body is unrepresentable.

## 2. Framing is the library's job, and bodyless statuses are structural

Two incidents, one rule:

* `a60a95c` / ziglang/zig#25181: a reply with no discoverable body end (HEAD,
  204) hangs the read forever if the client tries to read a body RFC 9112
  §6.3 says must not exist. std.http.Client has this bug open at *urgent*
  today.
* benchmark `19e34a3`: a hand-rolled reader consumed a chunked body as plain
  text for months. Every 2 KiB boundary spliced a hex chunk-size line into a
  metric line; which series died depended on byte offset; a container was
  invisible for entire ramps while `docker` and `curl` both listed it.

The parser owns all three framings (content-length, chunked, close-delimited),
applies the bodyless rules unconditionally, and — RFC 9112 §6.3 again —
**ignores Content-Length when Transfer-Encoding is present** and rejects
conflicting duplicate Content-Length values, because that disagreement is the
request-smuggling primitive.

One strictness decision, one place. A trailer is a header field (RFC 9112
§7.1.2) and is held to the head's rule: the fuzzer found the trailer section
delivering a nameless field the head refuses, so the same bytes meant two
different things depending on where in the message they appeared. Validation
that lives in a callback branch is worse still — it makes the parse depend on
whether the caller happened to be listening.

## 3. The deadline is whole-request, and it comes from Io cancellation

Nightly run #9 burned 71 minutes inside one unbounded poll. The first fix
spawned an OS thread and **abandoned** it on deadline, deliberately leaking
everything the thread could still touch. The second fix (benchmark `51e9a8a`)
measured that cancelling an `Io.Group` unwinds a blocked request in 1 ms under
`Io.Threaded` and 0 ms under zio.

Corollaries:
* One number bounds connect + TLS + request + response. Per-syscall timeouts
  are backend-dependent (`Io.Threaded` *panics* on a non-none connect
  timeout); cancellation is not.
* Both backends are first-class: the control plane runs on Threaded, the load
  generator on zio, and neither is the "real" target.

## 4. Segmentation invariance

Whether a byte sequence is delivered must depend on the bytes, not on where
the transport happened to split the stream. The chunked bug was exactly a
violation of this; so was an early `LineSink` draft where a line's length
limit applied only when the line arrived fragmented.

The test that enforces it: parse the same canned responses at **every**
two-segment split position and byte-at-a-time, and require the identical
event sequence every time.

`zig build fuzz` makes that an oracle rather than a test case, over a seed
corpus plus 20 k deterministic mutations, in 0.15 s. "It did not crash" would
have been the wrong property — the incident this library exists for never
crashed. So the oracle compares every channel a caller can observe:

* the verdict, **and the bytes handed to the sink, on failure as well as
  success** — `streamExact64` delivers what it read before hitting EOF, so two
  segmentations can both return `UnexpectedEof` having written different bytes
  first, and `UnexpectedEof` is the largest single bucket in the search;
* the header and trailer callback sequence, whose slices point into the
  reader's buffer — the one piece of memory a whole-buffer fill and a
  byte-at-a-time fill lay out differently;
* the offset the parse left the stream at. Two parses can agree on every body
  byte and still frame the connection differently, which only surfaces on the
  *next* response — that is ziglang/zig#25181's shape.

It has earned its keep twice. The first run with the header channel enabled
found the trailer section accepting a field the head refuses (`0\r\n: v\r\n\r\n`)
— the same bytes meaning two different things depending on where in the message
they appeared. The hparse adoption then tripped it immediately: a budget check
against `r.buffered().len`, which also holds body bytes, made a response that
fit when segmented fail when it arrived whole.

Zig 0.16.0's coverage-guided `--fuzz` does not build (a toolchain bug in its own
bundled `test_runner.zig:566`), so the mutator is in-tree, seeded and
deterministic — a failure replays from the iteration number printed beside it.
A new framing shape gets a seed, because the mutator can only reach what the
seeds spell.

## 5. Transport is injected, never owned

`suite.probeOnce` speaks over zrk's TLS specifically, so that a handshake the
probe accepts is one the measurement will accept. A client that insists on its
own TLS cannot express that property.

A `Connection` is a `*Io.Reader` + `*Io.Writer` pair, full stop. Plain TCP,
std TLS, zrk's ztls, an in-memory pipe in a test — all the same type. `fetch`
is the convenience layer that dials for you; `Connection` is the layer that
does not care.

TLS is the rule's own test case, and it passed: `src/tls.zig` is an adapter
that turns one reader/writer pair into another, `Connection` was not touched to
make https work, and a consumer who prefers zrk's ztls hands `Connection` its
own two pointers and never compiles the file.

Verified live rather than asserted, by `zig build tls-smoke`: example.com
matches `curl` byte for byte (200, 559 bytes), google.com moves 89 KB of chunked
body through it, and expired / wrong-host / self-signed / untrusted-root all
come back `TlsCertificateInvalid` with std's precise reason available through
`tls.Diagnostics`. It is a separate build step because std ships no TLS server,
so a real handshake needs a real origin — and a unit test that fails when DNS is
down is a gate people learn to ignore.

## 6. A leaf package: no runtime, no TLS stack, no third copy of anything

benchmark's `build.zig.zon` documents how two copies of zio fail to unify
("file exists in modules 'zio_options' and 'zio_options0'"), and every extra
pin makes a version bump an n-way agreement. That is the harm. zio enters
through `std.Io`; TLS enters through rule 5.

This rule read **"zero dependencies"** until zurl adopted `zoxy-io/hparse` as
its head scanner, and the rename is the honest version of what it always
protected. Zero was a proxy for leaf-ness, and a cheap one to check; it was
never the property that mattered. A pin earns its place only by clearing all
of:

- **std-only itself**, so it cannot drag a runtime or a TLS stack in behind it.
  hparse takes a byte slice and writes spans. It has no I/O, so there is
  nothing for a consumer's zio or ztls to collide with.
- **Version-locked with zurl, not with the consumer.** hparse and zurl are the
  same project under one owner and are bumped together, so a consumer never
  arbitrates between them. A pin a consumer might *also* pin independently is
  the n-way agreement this rule exists to prevent, and is still refused.
- **Not expressible through the transport seam.** Rule 5 carries anything that
  is I/O. A head scanner is not: it is pure computation on bytes the seam has
  already delivered.
- **Paid for in measurement, not taste** (rule 8). docs/RESEARCH.md carries the
  numbers both ways, including the one that first argued *against* adopting it.

Two dependencies is not automatically twice the harm, and one is not
automatically none. The count is not the test; the four bullets are.

## 7. Overlong input is dropped whole and counted, never truncated

A truncated metric line still parses as a metric and reports a *wrong* value,
which is strictly worse than a missing one. `LineSink` drops oversized lines
whole and counts them in `overlong`, so "no such series" and "series did not
fit" are distinguishable. The parser applies the same stance to oversized
header lines: `error.HeadTooLong`, never a clipped header.

## 8. Performance is measured, never assumed

benchmark `87ad523`: an HTTP-client swap silently cost every ramp 2 of its 28
cAdvisor samples because a poll period depended on scrape cost. The change was
correct; the *cost* was invisible until measured.

So `bench/` is part of the deliverable: parser microbenchmarks and an
end-to-end loopback comparison against std.http.Client, run in ReleaseFast.
The headline table is in the README; the method is here. The standing rule from
the parity discussion was that zrk adopts nothing from here until these
benchmarks say parity. They now do, for the parser and only the parser: it
measured 0.55–0.85× zrk's hand-rolled one on zrk's own shapes, while
`writeRequest` measured 36× the cost of replaying a prebuilt request, so the
load generator took the half that won and kept the half that did not. The rule
did its job in both directions, which is the point of having it.

### How to measure so the number means something

**Bands, not numbers, and always against a baseline re-run in the same session
on the same box.** A figure from yesterday's README is not a control. Interleave
A/B pairs rather than running all of A then all of B, so drift shows up in both
arms instead of only the second.

**State the power state alongside any number taken on a laptop.** The same box
and the same commit measure 1.7× slower across every row on battery
(`powersave`, 1.2 GHz) than on AC (4.3 GHz boost). Half a session was spent
chasing a regression that was a CPU governor.

**Say when a band is too wide to conclude from.** The `concurrent` slice
measured fresh-conn at 11.3–16.8k req/s against a 11.7–16.8k baseline, which
resolves nothing — and keep-alive, a path that change could not touch, swung
75–95k across the same six runs. That spread *is* the noise floor, and the
honest report is "no signal above it", not "no regression".

### What assertions cost

Assertions (docs/TIGER_STYLE.md) are `std.debug.assert`, so they are absent from
any ReleaseFast table *by construction* — the compiler removes them, and an
unchanged benchmark proves nothing about them either way.

Measured where they do run — ReleaseSafe, four interleaved A/B pairs against the
same code without them, **before the hparse adoption and not re-run since**:
small-cl 129–132 → 133–137 ns, zrk-1k 68–70 → 70–74 ns, cadvisor unmoved at
0.19–0.20 ms. Three to five percent on the head-heavy shapes and nothing on the
body-heavy one, which spends its time in `streamExact64` and `LineSink.feed`
rather than in the head.

### The rule has caught three things, unprompted

* The first `fetch` waited on its deadline by polling a flag every 20 ms — a
  166× latency floor, 50 req/s, that all 16 correctness tests passed over
  without blinking. `bench/e2e.zig` convicted it on its first run.
* Adopting hparse was justified by numbers and *rejected* by them first: the
  scanner is faster, but its one-shot API made segmented head parsing
  quadratic. Only the resume cursor changed the answer.
* Extracting a function to satisfy the 70-line limit cost 5× on small-cl and 10×
  on zrk-1k, because a 4 KiB array defaulted inside a `= .{}` struct literal
  makes the compiler materialise an initialiser on every parse. Caught in the
  same sitting as the refactor rather than in a profile months later.

## Non-goals (v0)

HTTP/2 (nothing in either repo speaks it as a client), cookies, connection
pools inside `fetch`, multipart, signing schemes.

Two things left this list once the consumer was actually surveyed, and
[docs/SCOPE.md](SCOPE.md) carries the reasoning and the tiers:

* **Redirects** are in scope, `max_redirects = 0` by default. `std.http.Client`
  follows them silently today, so a client that does not would turn a followed
  302 into a reported benchmark failure. Off by default makes that loud in one
  run instead of silent; cross-origin redirects drop `authorization`
  structurally, because the harness carries a live IAM bearer token.
* **Request-side chunked bodies** are in scope for uploads. The v0 argument was
  that nothing needed them, and artifact PUTs holding a whole file in memory
  are what changed it.

TLS is no longer among them, and the way it landed is the rule working:
`src/tls.zig` is an adapter that turns one `*Io.Reader`/`*Io.Writer` pair into
another, `Connection` is unchanged, and a consumer that prefers zrk's ztls
still hands `Connection` its own two pointers and never compiles the file.
The trust anchors stay the caller's — loading them allocates.
