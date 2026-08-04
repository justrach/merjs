const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const merjs = b.dependency("merjs", .{
        .target = target,
        .optimize = optimize,
    });

    // Module-only package. No executable is produced.
    const merjs_auth_mod = b.addModule("merjs-auth", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    merjs_auth_mod.addImport("mer", merjs.module("mer"));
    merjs_auth_mod.addImport("runtime", merjs.module("runtime"));

    // Test step — runs all tests in the src tree.
    const test_step = b.step("test", "Run merjs-auth unit tests");

    const unit_tests = b.addTest(.{
        .root_module = merjs_auth_mod,
    });

    const run_tests = b.addRunArtifact(unit_tests);

    const consumer_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/consumer_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    consumer_mod.addImport("mer", merjs.module("mer"));
    consumer_mod.addImport("runtime", merjs.module("runtime"));
    consumer_mod.addImport("merjs-auth", merjs_auth_mod);
    const run_consumer_tests = b.addRunArtifact(b.addTest(.{ .root_module = consumer_mod }));

    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_consumer_tests.step);
}
