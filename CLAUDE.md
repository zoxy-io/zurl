# zurl

An experimental `std.Io`-native HTTP/1.1 client for Zig 0.16, zero
dependencies. Read before writing code:

- [docs/DESIGN.md](docs/DESIGN.md) — the eight rules, each traceable to an
  incident that cost the zoxy benchmark harness a real run. Bare *rule N*
  references in code, comments and commits point here. This is *what must be
  true*.
- [docs/TIGER_STYLE.md](docs/TIGER_STYLE.md) — enforced coding rules: zero
  allocation, ≤ 70-line functions, assertion density ≥ 2, bounded loops,
  explicitly-sized integers, naming, and the deltas from zoxy's version. This
  is *how it is written*.
- [docs/RESEARCH.md](docs/RESEARCH.md) — what exists in the ecosystem and why
  none of it fits. Do not re-litigate a verdict recorded here; add to it when
  a new one is reached.

## Workflow — how a change lands

Work in **slices**. A slice is one coherent change, small enough to review in
one sitting, that leaves the repo green. Do not batch several slices into one
commit, and do not commit a slice that skipped a gate.

For every slice, in order:

1. **Write it**, with its tests, under docs/TIGER_STYLE.md.
2. **`zig build test`** — must be green. New behaviour arrives with new tests;
   anything that reads the wire arrives with a segmentation-invariance test
   (rule 4). This includes the fuzz oracle; `zig build fuzz` runs that alone,
   in 0.15 s, when the parser is what you are editing.
   A new framing shape gets a line in `src/fuzz.zig`'s seed corpus — the
   mutator can only reach what the seeds spell.
3. **`zig fmt --check src bench smoke build.zig build.zig.zon`** — clean.
4. **`zig build tls-smoke`** when the change touches `src/tls.zig`,
   `src/client.zig`, or the transport seam. It is a live gate — a real
   handshake against a real origin — so it needs network and is deliberately
   not part of `zig build test`; run it by hand and say in the commit that you
   did. `-- <url> [bundle|self-signed|insecure]` aims it elsewhere.
5. **Benchmarks.** `zig build bench-parse -Doptimize=ReleaseFast` for anything
   touching `src/parser.zig` or `src/sink.zig`; `bench-e2e` as well for
   anything touching `src/connection.zig` or `src/client.zig`. Compare *bands*
   across runs, never single numbers, and re-run the baseline in the same
   session on the same box — a number from yesterday's README is not a
   control. If the band moved, say so in the commit message and update the
   README table; if a change is advertised as faster, the benchmark line that
   shows it is part of the slice (rule 8).
6. **Run the `tiger-style-reviewer` agent on the diff.** It is read-only and
   reviews `git diff HEAD`. Fix the violations; judgement calls are a
   conversation, not an order.
7. **Then commit** — one commit, descriptive message, *rule N* references
   welcome. Push and open PRs only when asked.

A slice that cannot pass a gate is not "done pending a follow-up"; either the
gate is wrong (change it deliberately, in its own slice) or the slice is.

## Toolchain

Zig **0.16.0** exactly. The repo has no dev shell of its own yet; if `zig` is
not on `PATH`, use the 0.16.0 toolchain the sibling `../zoxy` checkout pins
(`devenv shell` there, or the `zig-0.16.0` path in the nix store). Do not
build with 0.15 or with master — `std.Io` moves.

## Policies

- **Zero dependencies** (rule 6). zurl imports `std` and nothing else, so that
  it is a *leaf* package: a consumer that already pins zio or a TLS stack must
  never end up with two copies of one. A `.dependencies` entry in
  `build.zig.zon` needs a written argument that the transport seam cannot
  carry it instead.
- **Zero allocation.** No function under `src/` takes an `Allocator`. Memory
  that grows during a fetch belongs to a caller-supplied
  `Io.Writer.Allocating`; buffers are the caller's and each one is a stated
  bound.
- **The transport seam is the boundary.** Nothing under `src/` imports a
  socket, a TLS stack, or a runtime. `Connection` is a `*Io.Reader` +
  `*Io.Writer` (rule 5); `client.zig` is the only file allowed to dial. TLS
  arrives as a transport producing those two pointers, never as a branch in
  the parser.
- **Both `std.Io` backends are first class.** `Io.Threaded` and zio are both
  production backends for consumers of this library; neither is "the real
  one". A mechanism that only works on one (per-syscall connect timeouts —
  `Io.Threaded` *panics* on a non-none one) is not a mechanism zurl can use.
- Framing decisions live in `src/parser.zig` and nowhere else (rule 2).
  Consumers never see an undecoded byte, and never get to choose whether a 204
  has a body.
