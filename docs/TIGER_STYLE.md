# zurl style — adopted from TigerStyle

zurl adopts [TigerBeetle's TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
by way of [zoxy's](https://github.com/zoxy-io/zoxy) `docs/TIGER_STYLE.md`.
Those documents are the source of truth; this file records **the rules we
enforce here** and the **library-specific deltas** — because zurl is a leaf
library consumed by a proxy, not the proxy, and two of zoxy's non-negotiables
do not survive that change of shape.

> Another word for style is design. Design goals, in priority order:
> **safety, performance, developer experience.** All three matter; simplicity
> serves all three and is "not the first attempt but the hardest revision."

Bare *rule N* references point at [DESIGN.md](DESIGN.md), whose eight rules are
each traceable to an incident. Style rules say *how* to write it; design rules
say *what must be true*. Neither overrides the other.

---

## Deltas from zoxy — read these first

- **We do not have a startup phase, so "static allocation only" is replaced by
  something stronger: zurl allocates nothing, ever.** No function in `src/`
  takes an `Allocator`. Head lines are parsed in place inside the reader's
  buffer; bodies stream through without being held whole. The only memory that
  grows during a fetch belongs to a caller-supplied
  `Io.Writer.Allocating` — the caller's allocator, chosen at the caller's call
  site, freed by the caller's `deinit`. A new `Allocator` parameter anywhere
  under `src/` is a design change, not a refactor.
  **The one that has been made**, so it is not re-litigated: `tls.Ca.Bundle`
  carries a `gpa` through `src/tls.zig` to std's certificate verifier, which
  allocates during the handshake. It is the caller's allocator, on the
  caller's bundle, for the caller's trust store — the alternative was zurl
  loading a trust store itself, which is strictly more allocation and takes
  the decision away from the process that should own it. The rule still binds
  everywhere else, and nothing else in `src/` names an `Allocator`.
  Corollary: **every buffer is the caller's, and every buffer is a bound.**
  A `[]u8` parameter is the limit on whatever it holds, and its doc comment
  says what it bounds (`carry` bounds the longest deliverable line).
- **Assertions state internal invariants; wire input gets errors.** zurl reads
  bytes written by someone else, so a malformed status line is *expected
  input*, not a broken invariant — it returns `error.MalformedStatusLine`. An
  assertion that a caller could trip from the network is a remote panic.
  Assert what *this code* must have established: post-parse relationships,
  cursor monotonicity, that a length consumed equals a length promised.
- **No `zig build lint`.** zoxy's boundary lints have no analogue in a
  five-file library, so the loop-bound and import rules below are enforced by
  the `tiger-style-reviewer` agent and by review, not by a tool. The
  `lint:unbounded-ok — <why>` marker convention is kept anyway: it is for the
  reader.
- **The transport seam replaces zoxy's boundary lints.** Nothing under `src/`
  may import a socket, a TLS stack, or a runtime, with exactly two named
  exceptions: `client.zig` is the only file allowed to dial, and `tls.zig` is
  the only file allowed to import `std.crypto.tls`. Both are *adapters at the
  seam* rather than users of it — nothing else in `src/` imports either, and
  `Connection` cannot tell a TLS transport from a socket or from a pair of
  fixed buffers in a test. A TLS implementation arrives as a transport that
  produces those two pointers, never as a branch inside the parser; a
  consumer that prefers zrk's ztls hands `Connection` its own two pointers and
  never compiles `tls.zig` at all. Adding a third exception needs the same
  argument these two made.

## Non-negotiables

- **Zero allocation** — see the delta above. Any allocation is the caller's.
- **Zero dependencies beyond the Zig toolchain** (rule 6). zurl is a *leaf*
  package on purpose: a second copy of a runtime or TLS pin in a consumer's
  graph turns every version bump into an n-way agreement. zio enters through
  `std.Io`; TLS enters through the transport parameter. Adding a `.dependencies`
  entry requires a written argument that the seam cannot carry it.
- **Put a limit on everything.** Every loop and every buffer has a fixed upper
  bound the reader can see. `max_head_bytes` exists because a server can send
  valid-sized header lines forever; anything with the same shape gets the same
  treatment.
- **No unbounded `while (true)`.** A loop with no syntactic bound states one
  where a reviewer can see it — either a budget it decrements
  (`takeLine(r, &budget)`) or an asserted counter at the top of the body:

  ```zig
  while (true) : (passes += 1) {
      assert(passes <= chunks_max);
  ```

  A loop whose bound is structural — a chunked body that terminates on its own
  zero-size chunk, with every iteration consuming from a finite stream — says
  so at the site with `lint:unbounded-ok — <why>` on the header line or the
  comment directly above it. Both forms turn "this always eventually
  terminates" from an assumption into a claim someone can check.
- **A retry loop retries transient errors only.** Classify before you retry: a
  terminal error (a closed transport, a malformed frame, a full sink) must
  propagate on the first occurrence. Never `catch continue` over a whole error
  set — name the retryable members. zoxy
  [#222](https://github.com/zoxy-io/zoxy/issues/222) is what the other way
  costs: a `while (true) … catch continue` met a persistently full heap and
  spun at 100% CPU forever.
- **No recursion.** All bounded executions stay bounded; no unbounded stack.
- **Assertion density ≥ 2 per function** on average, subject to the delta
  above. Assert arguments, return values, pre/postconditions, and invariants —
  positive space (what you expect) **and** negative space (what you don't).
  Split `assert(a and b)` into `assert(a); assert(b);`. Use `if (a) assert(b);`
  for implications. Assert relationships between comptime constants.
  Assertions are `std.debug.assert`: live in Debug and ReleaseSafe, compiled
  out of ReleaseFast — a mode the *consumer* chooses, not us. That is the
  second reason wire input is validated with errors rather than assertions.
  An error survives every build mode; an assertion does not.
- **All errors handled.** No `catch unreachable` on a reachable error; no
  swallowed errors. A bare `catch {}` needs a comment proving it benign.
  (92% of catastrophic failures come from mishandled non-fatal errors —
  OSDI'14.) Error sets are named per layer and distinguish causes the caller
  reacts to differently: `error.WriteFailed` (the sink) is not
  `error.ReadFailed` (the transport), because a full collect buffer and a dead
  connection demand different reactions.
- **Errors are never silently truncated into success** (rule 7). Overlong
  input is dropped whole and counted; a clipped header or a truncated line is
  worse than a missing one, because it still parses.
- **Explicitly-sized integers** (`u16`, `u64`, …) for anything that is a
  protocol quantity: a status is `u16`, a body length is `u64` (a body is not
  bounded by the machine word). `usize` stays for genuine machine-word
  index/length quantities — buffer offsets, slice lengths, what `std.Io`
  already speaks.
- **Functions ≤ 70 lines.** Hard limit.
- **4-space indentation.** `zig fmt` clean; trailing comma on wrapped
  signatures.
- **Braces on every `if`** unless it fits on one line (defense against
  `goto fail;`-class bugs).

## Control flow

- Simple, explicit control flow only. Centralize it: **push `if`s up and `for`s
  down** — branch in the parent, keep leaf functions straight-line and pure.
  `streamBody` chooses the framing; `streamChunked` never re-asks which framing
  it is in.
- Split compound conditions into nested `if/else`; split `else if` chains into
  `else { if { } }` trees. Consider whether each `if` needs an `else` (negative
  space).
- State invariants **positively**: `if (index < length) { holds } else { … }`.
  Negations are error-prone.
- **A function completes its I/O or returns an error; it does not leave the
  stream half-consumed.** A partially-read body is a desynchronised
  connection, so any path that abandons mid-body must also mark the connection
  unusable (`Connection.reusable = false`, which `errdefer` does for the whole
  round trip). This is the client-side form of zoxy's "functions run to
  completion": *there* it protects precondition assertions, *here* it protects
  framing.
- Prefer simpler return types: `void > bool > u64 > ?u64 > !u64`.
- Pass options explicitly at the call site; don't rely on library defaults —
  including our own. A `HeadOptions{}` literal at a call site is a decision;
  an omitted parameter is an accident waiting to be reinterpreted.

## Naming

- **Follow the [Zig reference naming conventions](https://ziglang.org/documentation/master/#Names)**
  — case encodes what a name *is*:
  - `TitleCase` for types and for any function that returns a type
    (`Connection`, `LineSink`, `Head`).
  - `camelCase` for every other function (`parseHead`, `streamBody`,
    `roundTrip`).
  - `snake_case` for variables, non-type constants, and struct fields
    (`max_head_bytes`, `deadline_ns`, `keep_alive`).
  - A field-less struct used purely as a namespace is `snake_case`.
  - **File names follow the same type/namespace split:** a file whose
    top-level struct has fields is a type → `TitleCase.zig`; a file that is
    just a namespace of declarations → `snake_case.zig` (`parser.zig`,
    `client.zig`, `sink.zig`). Directories are `snake_case`.
  - Acronyms and initialisms are ordinary words under these rules, even
    two-letter ones: `HttpReader`/`IpAddress` (not `HTTPReader`/`IPAddress`),
    `Tcp`, `Io`, `Tls`.
- **No abbreviations** (except primitive indices in tight math).
  `source`/`target` over `src`/`dest` so `source_offset`/`target_offset` align.
- **Units/qualifiers last, most-significant word first:** `deadline_ns`,
  `max_head_bytes`, `body_bytes_max` — so related names column-align.
- **Callbacks are the last parameter**, and a callback's doc comment says how
  long its slices live. `HeaderFn`'s do: the bytes point into the reader's
  buffer and die when the body starts streaming. A borrowed-slice callback
  without that sentence is an unreported use-after-free.
- File order top-down, important first. Struct order: **fields, then types
  (decls), then methods.** When unsure, sort alphabetically.
- Comments are complete sentences (capital, full stop) — say **why** and
  **how**, not just what. Where a rule exists because something broke, the
  comment cites the incident: `d4ad5fa`, `ziglang/zig#25181`, "nightly run #9".
  Write descriptive commit messages; they outlive PR text.

## Off-by-one & correctness hygiene

- Treat `index` (0-based), `count` (1-based), `size` (count × unit) as
  distinct; cast explicitly. Show division intent: `@divExact` / `@divFloor` /
  `divCeil`.
- Pass args > 16 bytes as `*const` to catch accidental stack copies.
- Declare variables at the smallest scope, close to use (avoid
  place-of-check to place-of-use gaps). Don't alias or duplicate state:
  `Connection.reusable` is the single record of whether framing permits
  another request, derived from what the exchange *was*, never from what the
  request *asked for*.
- Group an acquire with its `defer` release, separated by blank lines, so a
  missing release is visible.

## Testing

The gates are in [CLAUDE.md](../CLAUDE.md); these are the rules about what a
test must be.

- **Anything that reads the wire ships a segmentation-invariance test**
  (rule 4). Parse the same bytes at **every** two-segment split position and
  byte-at-a-time, and require the identical event sequence every time.
  `src/SegmentedReader.zig` is the harness and `src/fuzz.zig` is the oracle
  that drives it over a seed corpus and a mutation loop; a new framing shape
  gets a corpus seed there. A feature that only
  has a happy-path test where the whole response arrives at once is not
  tested; that is precisely the bug that read chunked bodies as plain text for
  months.
- **Prefer an in-memory transport to a socket.** Rule 5's payoff is that a
  `Io.Reader.fixed` pair exercises the production code path with no listener,
  no port, and no flake. Reach for a real loopback server only when the thing
  under test *is* the dialing (`client.zig`).
- **A test asserts on behaviour, never on timing** — except where the
  behaviour *is* a deadline, in which case it asserts the deadline fired, not
  how fast.
- **Benchmarks are executables, not tests.** They print numbers and never
  assert on them: a perf gate that fails on a loaded laptop teaches people to
  delete perf gates. Regressions are caught by comparing bands across runs.

## Performance

- **Back-of-the-envelope first.** Sketch every hot path against the four
  resources (network, disk, memory, CPU) × two characteristics (bandwidth,
  latency). The big 1000× wins are won in *design*, before you can profile.
- **Optimize the slowest resource first, weighted by frequency.** For zurl
  that ordering is already measured and it is not the parser: 61 ns of parse
  inside a ~10 µs loopback round trip is 0.6%. Syscalls and the round trip
  dominate; a change that makes the parser 2× faster and adds one syscall is a
  regression. State which resource a "fast" change is buying before making it.
- **Performance is measured, never assumed** (rule 8). A change advertised as
  faster arrives with the benchmark line that shows it, and a change to a hot
  path arrives with the benchmark line that shows it did no harm. The first
  `fetch` polled a done-flag every 20 ms — a 166× latency floor that all 16
  correctness tests passed over without blinking, and that `bench/e2e.zig`
  convicted on its first run.
- **Batch** to amortize syscall/network/memory costs. Let the CPU sprint in
  straight lines — give it big chunks, don't zig-zag on every event.
- Extract hot loops into standalone functions with primitive args (no `self`)
  so the compiler can keep values in registers and humans can see redundant
  work.

## Project policy

- **Zero technical debt** — solve it in design, right the first time.
- **Small slices, one commit per slice**, each one green on the gates.
- Tooling in Zig (`build.zig` steps), not shell scripts, where practical.
- A design decision that was considered and rejected gets written down with
  its reasoning, so it is not re-litigated from scratch six months later.
