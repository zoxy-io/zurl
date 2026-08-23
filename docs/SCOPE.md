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

**In this order.** It is risk order, not convenience order, and it is settled:
an item is not promoted because it happens to be small. `content-encoding` in
particular is a live silent-corruption path and a few lines to close, which is
an argument for doing it *well*, not for doing it *first* — the header gap
above it is what makes the other three verifiable at all.

### Response headers must be reachable from `fetch`

`Response` is `{status, body_len}`. `parser.HeadOptions` has always had
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

This is a correctness hole, not a feature. `writeRequest` sends no
`accept-encoding`, so a compliant origin returns identity — but a server that
gzips anyway hands compressed bytes straight to `LineSink`, which parses them
as text.

That is the cAdvisor incident, precisely: bytes that parse as something else,
silently, for as long as nobody looks. Rule 2 says the caller never sees an
undecoded byte, and a `content-encoding` zurl does not understand is exactly
that. Refusing costs almost nothing and closes the hole; decoding is a separate
opt-in with a caller-supplied window.

### Redirects: implemented, default OFF, auth stripped structurally

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

zurl sends `host`, and optionally `authorization`, `content-type`,
`content-length`, `connection` — and nothing else. No `user-agent` at all.
Several APIs require one (GitHub rejects UA-less requests outright), so its
absence is a request that fails for a reason the caller cannot see in the
status.

## Tier 2 — for remote API work generally

* **Streaming request bodies.** `body` is `?[]const u8`, so `ycs.put` holds a
  whole artifact in memory. A `*Io.Reader` source plus request-side chunked
  encoding for unknown length. This was a v0 non-goal on the grounds that
  nothing needed it; uploads are what change that.
* **`Retry-After` parsing and status classification.** The ingredients for a
  retry, not the retry — see below.
* **A single-origin `Session` over one `Connection`.** `fetch` stays one-shot
  and keeps `connection: close`. Pagination over a dozen pages should not pay a
  dozen TLS handshakes: the measured gap is 88k req/s keep-alive against 14k
  fresh-connection. `Connection` already does this; what is missing is a
  documented, bounded way to hold one open for an origin.
* **Basic-auth helper** — base64 into a caller buffer, mostly for the CLI.
* **Percent-encoding for URL building.** `ycs` interpolates bucket keys into
  URLs with `{s}` and no escaping, which drafted as a Tier 1 latent bug — a key
  containing a space, `?` or `#` would silently change the request target.
  **Checked: those keys are URL-safe**, so nothing is broken today and this is
  defence against a future key rather than a fix. Demoted on that evidence,
  which is the only reason it moved.

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

A `curl`-mirroring `zurl` executable, in `cli/`, after Tier 1 lands.

Its real justification is not convenience. `zig build tls-smoke` already checks
zurl against curl byte-for-byte on one URL; a curl-compatible CLI generalises
that into a **differential oracle** over a corpus — the same discipline as the
rule 4 fuzz oracle, one level up. Same request, same answer as curl, or one of
them is wrong.

That also bounds its scope. It implements the flags that make the diff
meaningful and stops: `-X -H -d -o -i -D -L -u -A --max-time -k --cacert
--compressed -I -f -s`, and a small `-w` subset for status, size and time. Not
the other two hundred.

Ordering is deliberate: the library gaps first, so the diff has headers,
redirects and encoding to compare rather than only a status and a body.
