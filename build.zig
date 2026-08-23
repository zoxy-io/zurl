const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zurl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The fuzz gate is the same sources filtered to the parser's oracles: the
    // seed corpus at every split position, 20k deterministic mutations of it,
    // and the tests that prove the oracle can fail. Cheap enough (~0.15s) to
    // run on every slice.
    //
    // `zig build fuzz --fuzz` would hand the same oracle to Zig's
    // coverage-guided fuzzer, and does not build on Zig 0.16.0: the bundled
    // compiler/test_runner.zig fails under -ffuzz with a StackTrace type
    // mismatch at test_runner.zig:566. That is why the mutator in
    // src/fuzz.zig is in-tree; its `mutation_iterations` records the whole
    // story.
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"fuzz"},
    });
    const fuzz_step = b.step("fuzz", "Run the parser fuzz oracles: corpus, mutations, vacuity");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // The live TLS gate. Deliberately its own step and not part of `test`:
    // std ships no TLS server, so a real handshake needs a real origin, and a
    // unit test that fails when DNS is down is a gate people learn to ignore.
    const tls_smoke = b.addExecutable(.{
        .name = "tls-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("smoke/tls.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zurl", .module = mod }},
        }),
    });
    const tls_smoke_step = b.step("tls-smoke", "Live TLS handshake against a real origin");
    const tls_smoke_run = b.addRunArtifact(tls_smoke);
    if (b.args) |args| tls_smoke_run.addArgs(args);
    tls_smoke_step.dependOn(&tls_smoke_run.step);

    // Benchmarks are executables, not tests: they print numbers and never
    // assert on them — a perf gate that fails on a loaded laptop teaches
    // people to delete perf gates. Run with -Doptimize=ReleaseFast.
    inline for (.{ "parse", "e2e" }) |name| {
        const exe = b.addExecutable(.{
            .name = "bench-" ++ name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zurl", .module = mod }},
            }),
        });
        const step = b.step("bench-" ++ name, "Run the " ++ name ++ " benchmark");
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        step.dependOn(&run.step);
    }
}
