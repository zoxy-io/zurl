# Dev environment (https://devenv.sh): the pinned toolchain.
#
# zurl is a leaf package (rule 6) and its shell is nearly as small: Zig, and
# curl for the differential oracle. Everything else is developer tooling gated
# out of the CI closure, because CI runs `zig fmt --check`, `zig build check`,
# `zig build test` and `zig build fuzz` and nothing that needs an editor.
#
# curl is NOT dev-only. `zig build curl-diff` compares zurl against it, so a
# shell without curl cannot run one of the repository's gates. It is small and
# it is a gate, so it belongs in the closure.
#
# Activated automatically by `.envrc` via direnv, or manually with
# `devenv shell`.
{ pkgs, lib, ... }:
let
  # GitHub Actions sets CI=true; a CI checkout is always fresh, so this
  # re-evaluates every run and never serves a stale (dev-tool-included) shell.
  in_ci = (builtins.getEnv "CI") == "true";
in
{
  packages =
    [
      # Zig 0.16.0 exactly. `build.zig.zon`'s `minimum_zig_version` is the
      # other half of this pin, and CI reads that rather than restating it.
      pkgs.zig_0_16
      # The other half of `zig build curl-diff`.
      pkgs.curl
    ]
    ++ lib.optionals (!in_ci) [
      pkgs.zls
    ];

  # Named to avoid shadowing the `test` and `build` shell builtins, matching
  # the sibling hparse checkout so muscle memory carries across.
  scripts.zb.exec = "zig build \"$@\"";
  scripts.zt.exec = "zig build test --summary all \"$@\"";
  scripts.zf.exec = "zig build fuzz --summary all \"$@\"";
  scripts.zc.exec = ''
    zig fmt --check src bench smoke cli build.zig build.zig.zon \
      && zig build check --summary all \
      && zig build test --summary all \
      && zig build fuzz --summary all
  '';

  enterShell = ''
    echo "zurl dev shell — zig $(zig version), curl $(curl --version | head -1 | cut -d' ' -f2)"
    echo "  zb  → zig build"
    echo "  zt  → zig build test --summary all"
    echo "  zf  → zig build fuzz --summary all"
    echo "  zc  → every offline gate: fmt, check, test, fuzz"
    echo ""
    echo "  live gates (network): zig build tls-smoke | zig build curl-diff"
  '';

  # `devenv test` runs the offline gates — the same set CI runs, and
  # deliberately not the two that need a network.
  enterTest = ''
    zig fmt --check src bench smoke cli build.zig build.zig.zon
    zig build check --summary all
    zig build test --summary all
    zig build fuzz --summary all
  '';
}
