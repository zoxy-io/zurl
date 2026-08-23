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

## 5. Transport is injected, never owned

`suite.probeOnce` speaks over zrk's TLS specifically, so that a handshake the
probe accepts is one the measurement will accept. A client that insists on its
own TLS cannot express that property.

A `Connection` is a `*Io.Reader` + `*Io.Writer` pair, full stop. Plain TCP,
std TLS, zrk's ztls, an in-memory pipe in a test — all the same type. `fetch`
is the convenience layer that dials for you; `Connection` is the layer that
does not care.

## 6. Zero dependencies

benchmark's `build.zig.zon` documents how two copies of zio fail to unify
("file exists in modules 'zio_options' and 'zio_options0'"), and every extra
pin makes a version bump an n-way agreement. zurl imports `std` and nothing
else. zio enters through `std.Io`; TLS enters through rule 5.

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
end-to-end loopback comparison against std.http.Client, run in ReleaseFast,
numbers in the README. The standing rule from the parity discussion: zrk
adopts nothing from here until these benchmarks say parity — and the inner
loop of a load generator may simply never be the right consumer.

## Non-goals (v0)

HTTP/2 (nothing in either repo speaks it as a client), redirects, cookies,
connection pools, request-side chunked bodies.

TLS is no longer among them, and the way it landed is the rule working:
`src/tls.zig` is an adapter that turns one `*Io.Reader`/`*Io.Writer` pair into
another, `Connection` is unchanged, and a consumer that prefers zrk's ztls
still hands `Connection` its own two pointers and never compiles the file.
The trust anchors stay the caller's — loading them allocates.
