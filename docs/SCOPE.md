# What zurl will and will not do

*Drawn 2026-08-24, against the consumer that exists rather than a feature list.*

[docs/DESIGN.md](DESIGN.md) is *what must be true*. This is *how far it goes* —
which client features zurl owns, which belong to a caller, and which are
refused outright. The forcing use case is the zoxy benchmark harness fetching
remote APIs it did not start; the second is a `curl`-mirroring binary.

**The test for whether something is in scope:** does its absence let a caller
misread bytes, or hang? Framing, encoding and bounds are the library's job
because getting them wrong is silent and the caller cannot detect it. Policy —
how many times to retry, whether a redirect is acceptable, what a 404 means —
is the caller's, because only the caller knows.

## The evidence

Every HTTP call the harness makes today, from `benchmark/bench/src`:

| Caller | Method | Body | Auth | Sink | Transport |
|---|---|---|---|---|---|
| `cadvisor.scrape` | GET | — | — | `LineSink`, ~1.5 MiB | http, loopback |
| `ycs.put/get/head/delete` | PUT/GET/HEAD/DELETE | `[]const u8` | Bearer IAM | collect / discard | https |
| `ycs.instances` | GET + query | — | Bearer IAM | collect | https |
| `discord.post` | POST | JSON slice | — | discard | https |

zurl's `FetchRequest` is already a superset of the harness's `Request`. The
swap is not blocked on features; it is blocked on the four gaps below, none of
which anyone had written down.

## The scoping principle: the library is mechanism, the binary is policy

Zero allocation binds `src/`. It does **not** bind an executable. A `cli/` that
allocates freely can load a trust store, hold a gzip window, buffer a redirect
chain and write to a file without costing the library any of its austerity.

So: convenience lives in the binary, and the binary is an ordinary consumer of
the library. If the CLI ever has to reach around the public API to do its job,
that is a defect report against the library, not a shortcut to take.

## Tier 1 — required before the harness swap is safe

**In this order**, and it is risk order rather than convenience order. An item
does not get promoted for being small: `content-encoding` is a live
silent-corruption path and only a few lines to close, which is an argument for
doing it *well*, not for doing it *first*.

The refusal item leads because it was **appended after this order was first
written**, so it had never actually been placed — and it is the only entry here
that is broken in `main` rather than merely missing. Risk order puts a live
header-injection hole ahead of four features. Nothing else moved.

### Refuse a target or host that cannot appear in a request line

**Landed** (`5444aef`), and wider than written here: `writeRequest` interpolates
`authorization`, `content_type` and every `extra` header too, so validation
covers every interpolated field rather than the two named below.

A security item, and the one thing on this list that was broken in `main`
rather than merely missing.

`writeRequest` composes the request line by interpolation:

```zig
try out.print("{s} {s} HTTP/1.1\r\nhost: {s}\r\n", .{ method, target, host });
```

Nothing validates `target` or `host` — there are two assertions that they are
non-empty, and assertions are gone in the ReleaseFast build a consumer is free
to choose. A target containing CR or LF therefore writes attacker-chosen bytes
into the request line, which is header injection: everything after the CRLF is
parsed by the origin as another header, or another request.

**It is reachable through `fetch`, not only through `Connection`.** `fetch`
runs the URL through `std.Uri.parse` first, which looks like validation and is
not: `parse` accepts CR and LF in a path and hands them back verbatim in
`Component.percent_encoded`, which `fetch` writes straight into the target.
Measured, Zig 0.16.0:

| input | `std.Uri.parse` | resulting path |
|---|---|---|
| `http://h/a b` | accepted | `/a b` — space, breaks the request line |
| `http://h/a\r\nX-Injected: 1` | accepted | injects a header |
| `http://h/a\nX: 1` | accepted | injects a header |

So a consumer that forwards a URL it was handed — which is exactly what a leaf
library invites — lets whoever chose that URL add headers to zurl's request.
It is the same reasoning `client.zig` already applies to a bad URL being an
error rather than an assertion: *a leaf library that panics on a bad URL panics
its consumer*, and one that injects headers on a bad URL compromises its
consumer.

The fix is refusal, not encoding: zurl cannot re-encode a target without
guessing whether a `?` the caller wrote is a query separator or a literal.
Rejecting CR, LF, space and control characters in the target and host is
unambiguous, cheap, and turns a silent request rewrite into an error.

**`std.http.Client` has the same hole**, so this is not a regression the swap
introduces — see docs/RESEARCH.md.

### Response headers must be reachable from `fetch`

**Landed.** `FetchRequest.on_header` and `ctx` pass straight through to the
parser, so headers and chunked trailers arrive on one callback, in order, with
values already trimmed.

`Response` was `{status, body_len}`. `parser.HeadOptions` has always had
`on_header`; `fetch` simply never passed it through, so from the top-level API
no response header is observable at all.

Everything API-shaped needs them: `Retry-After`, `Location`, `ETag`,
rate-limit headers, `Link` pagination. Today `discord.post` backs off on a 429
by *guessing* — a fixed `(attempt+1) * 2s` — because the header that says how
long to wait is unreachable.

Slices point into the reader's buffer and die when the body streams, so the
caller copies what it wants during the callback. That constraint is the API,
not a wart.

### Content-Encoding: decode or refuse, never pass through

**Landed, as refuse.** A `content-encoding` other than `identity` is
`UnsupportedContentEncoding` when a body would actually be delivered. Not when
it would not: a HEAD echoes the headers its GET would have sent, so refusing on
the header alone would break every HEAD against a gzip-serving origin.
`allow_encoded_body` is the conspicuous opt-out for a caller that genuinely
wants the raw bytes. Decoding remains unimplemented and optional.

This was a correctness hole, not a feature. `writeRequest` sends no
`accept-encoding`, so a compliant origin returns identity — but a server that
gzips anyway hands compressed bytes straight to `LineSink`, which parses them
as text.

That is the cAdvisor incident, precisely: bytes that parse as something else,
silently, for as long as nobody looks. Rule 2 says the caller never sees an
undecoded byte, and a `content-encoding` zurl does not understand is exactly
that. Refusing costs almost nothing and closes the hole; decoding is a separate
opt-in with a caller-supplied window.

### Redirects: implemented, default OFF, auth stripped structurally

**Landed.** `FetchRequest.redirects` is `{ max: u8 = 0, buf: []u8 }`. The
buffer bounds the whole CHAIN rather than one URL, because a hop's URL must
stay valid while the next is resolved against it; running out is
`TooManyRedirects`, never a truncated location. A 3xx whose body would have
been followed is left unread on the wire rather than delivered to the caller's
sink.

`std.http.Client.fetch` follows redirects by default, so the harness inherits
that today and cannot see it — `Response` carries only a status. Swap in a
client that does not follow, and an endpoint that 302s starts reporting a
benchmark failure that is not one.

**Decision: implement, `max_redirects = 0` by default.** A 3xx then surfaces as
a non-ok status — a loud failure discoverable in one run — rather than a silent
difference in behaviour. Callers turn it on where a run proves an endpoint
actually redirects. That is rule 8's measure-first stance applied to a
behaviour rather than a number.

Three things are structural, never flags:

* **Cross-origin redirects drop `authorization`.** `ycs` carries a live IAM
  bearer token. Re-sending it to whatever host a `Location` names is a
  credential-exfiltration primitive: point a redirect at your own server and
  collect tokens. curl strips it for this reason and so does zurl.
* **303 rewrites the method to GET**; 307/308 preserve method and replay the
  body. 301/302 follow 303's historical behaviour for non-GET.
* **The chain is bounded** by a caller-supplied URL buffer and a max count,
  like every other bound here.

### A default `user-agent`

**Landed.** `zurl/0.0.0` unless the caller sets `user_agent`, and null sends
none for a caller supplying its own through `extra`. Validated as a field
value like everything else, so an overridden one cannot inject.

zurl sent `host`, and optionally `authorization`, `content-type`,
`content-length`, `connection` — and nothing else. No `user-agent` at all.
Several APIs require one (GitHub rejects UA-less requests outright), so its
absence is a request that fails for a reason the caller cannot see in the
status.

## Tier 2 — for remote API work generally

* **Streaming request bodies.** **Landed.** `body` is a `RequestBody` union:
  `bytes` for something in memory, `stream` for a `*Io.Reader` sent as it is
  read -- with a `content-length` when the length is known and
  `transfer-encoding: chunked` when it is not. A stream cannot be replayed, so
  a 307 or 308 that would resend it is `BodyNotReplayable` rather than a
  request with a silently empty body.
* **`Retry-After` parsing and status classification.** **Landed.**
  `retry.parse` returns `RetryAfter{ .seconds | .at_unix_s }` -- a VALUE, not a
  delay, because turning a date into "how long from now" needs a clock and
  reaching for one would put an implicit time source inside the library.
  `Response.class()` gives RFC 9110's five classes and `Response.throttled()`
  answers the 429-or-503 question that spans two of them. Still no retry loop:
  the ingredients, not the retry.
* **A single-origin `Session` over one `Connection`.** **Landed.** `fetch`
  stays one-shot and keeps `connection: close`; `Session` resolves a URL,
  dials it, and stands up a transport whose buffers outlive one request -- the
  part `Connection` deliberately does not do. Buffers are the caller's, as
  everywhere else. It does NOT reconnect on its own: reconnecting means
  resending, which is the question retry asks and gets the same answer.
* **Refuse a framing header in `extra`.** **Landed** as
  `ReservedRequestHeader`: `content-length`, `transfer-encoding`, `host` and
  `connection` are refused in `extra`, because zurl decides each of them and a
  second copy is a disagreement rather than a header. `authorization`,
  `content-type` and `user-agent` are NOT reserved -- each has a nullable field,
  and supplying your own through `extra` is documented advice.

  Was: `validate` checked that every `extra` header name is a token, but not
  *which* token: a caller can pair
  `.extra = &.{.{ .name = "content-length", .value = "0" }}` with a real body
  and put two framing headers on the wire. That is the same disagreement the
  parser already refuses on the RESPONSE side as a smuggling primitive
  (rule 2), so refusing `content-length`, `transfer-encoding` and `host` in
  `extra` is the symmetric fix.

  Pre-existing — it was equally true when bodies were only `[]const u8` — and
  found while reviewing streaming bodies, which widened who would benefit from
  it. Scheduled rather than folded into that slice, because it is a change to
  what `extra` means rather than to how a body is sent.
* **Basic-auth helper.** **Landed** as `auth.basic`, base64 into a caller
  buffer with `basicLen` to size it. A colon in the user id is refused rather
  than encoded into an ambiguity -- `a:b`/`c` and `a`/`b:c` produce identical
  bytes, so an origin cannot tell which was meant.
* **Percent-encoding for URL building.** **Landed** as `url.encode`/
  `url.encodedLen`, with a `Component` saying which delimiters matter where: a
  `/` is escaped in a segment and kept in a path, `&` and `=` are escaped in a
  query. The ergonomic half of the refusal item in Tier 1: refusing a bad target tells a caller it built a wrong URL, and an
  encoder is how it builds a right one. Writes into a caller buffer.

  It sits here rather than in Tier 1 only because of *who* builds the URL.
  `ycs` interpolates bucket keys with `{s}` and no escaping, and those keys are
  URL-safe **today** — checked — so nothing is broken now. That safety is a
  property of the keys currently in use, not something anything enforces, so
  this is scheduled rather than dismissed: the day a key carries a space or a
  `#`, the Tier 1 refusal turns it into a loud error and this turns it back
  into a working request.

### Retry is the caller's, and zurl only supplies the ingredients

**Decision: no retry loop inside `fetch`.** zurl parses `Retry-After` and
classifies the status; the caller owns the loop.

The counter-argument is real and worth recording, because it is the argument
that pulled the deadline *into* this library: `benchmark/bench/src/http.zig`'s
own header complains that the bounded-fetch shape "used to be written out
twice, verbatim" and that every bug in it was fixed in exactly one copy. Retry
has the same smell.

It loses anyway, because retry needs something the library cannot know: whether
replaying this request is safe. A silent second POST is worse than any
duplication it would save. `fetch` means *one bounded request*, and a caller
that wants three writes three.

## Also outstanding, outside the tiers

* **Point the harness's control plane at zurl and delete its std wrapper.**
  Blocked on Tier 1 — chiefly redirects, because `std.http.Client` follows them
  silently today and a client that does not would turn a followed 302 into a
  reported benchmark failure.
* **Run `bench-e2e` on the zio backend.** Every number recorded so far is
  `Io.Threaded`, and rule 6's "both backends are first class" is untested at the
  wire until that happens.

## Non-goals

* **HTTP/2 and HTTP/3.** Nothing in either repo speaks them as a client.
* **Cookie jars.** No API here authenticates with cookies.
* **A general connection pool inside `fetch`.** Pooling across unrelated calls
  carries state between them for no benefit at a 30-second poll rate. Multiple
  requests to one origin are what `Session` is for.
* **Multipart bodies and a JSON codec.** Both are caller-side and both would
  need an allocator.
* **SigV4 or any signing scheme.** Yandex Object Storage takes a bearer token
  directly; there is no signature to compute anywhere in the harness.
* **Response caching, proxy support.** Revisit proxies only if CI needs them.

## The binary

**Landed**, in `cli/`, with the differential oracle it exists for.

Its real justification is not convenience. `zig build tls-smoke` already checks
zurl against curl byte-for-byte on one URL; a curl-compatible CLI generalises
that into a **differential oracle** over a corpus — the same discipline as the
rule 4 fuzz oracle, one level up. Same request, same answer as curl, or one of
them is wrong.

That also bounds its scope. It implements `-X -H -d -o -i -D -L -u -A
--max-time -k --cacert -I -f -s` and a `-w` subset of `http_code`,
`size_download` and `size_header`. Not the other two hundred.

**`--compressed` is not among them**, and its absence is this document keeping
itself honest — it was on the list above until the binary was written. zurl
decodes no content codings, so asking an origin to gzip would produce a body it
must then refuse. Accepting the flag and ignoring it would make a differential
run compare two different requests and call them equal, so unknown flags are a
usage error instead.

`zig build curl-diff` is the gate. It compares the body byte for byte, the
status, the exit code, and individual header values — but NOT the head's bytes,
because zurl reconstructs the head from parsed pairs and has no status line or
original casing to reproduce. Demanding byte identity there would test the
reconstruction rather than the client.

It earned its keep on the first run, finding two real defects in the binary:
`-s` was suppressing the response body, where curl's silent flag only silences
the progress meter; and `-f` exited before writing its `-w` output, which curl
writes. A third difference was in the harness rather than the client — stale
output files compared across cases — and a fourth was real but small: curl does
not CREATE the output file when `-f` matches, where zurl created an empty one.

Ordering was deliberate: the library gaps first, so the diff had headers,
redirects and encoding to compare rather than only a status and a body.

### One divergence the oracle cannot close, recorded rather than hidden

`curl -X get` sends `get` verbatim, and a strict origin answers 400. zurl
cannot reproduce that at all: `connection.Request.method` is
`std.http.Method`, an enum, so the library has no way to express a method it
does not know. The CLI refuses a non-canonical method with a usage error.

Upper-casing was tried first and the oracle caught it in one run -- `-X get`
became a 200 here against curl's 400, which is worse than refusing, because it
silently sends a DIFFERENT request than the caller typed.

If this ever matters, the fix belongs in the library: `method` would have to
admit an arbitrary token, and `validate` would then have to check it is one.
Until then the corpus does not carry a permanently-failing case, because a
gate that is expected to be red is a gate nobody reads.
