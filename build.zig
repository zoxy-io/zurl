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
