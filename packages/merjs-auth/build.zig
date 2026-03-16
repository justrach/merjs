const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module-only package. No executable is produced.
    // consumers must call: merjs_auth_mod.addImport("mer", mer_mod)
    const merjs_auth_mod = b.addModule("merjs-auth", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Expose module reference so consumers can reference it:
    // const merjs_auth = b.dependency("merjs-auth", .{});
    // const auth_mod = merjs_auth.module("merjs-auth");
    _ = merjs_auth_mod;

    // Test step — runs all tests in the src tree.
    const test_step = b.step("test", "Run merjs-auth unit tests");

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests that exercise mer-integrated code (session, csrf) need the
    // mer module injected here. For pure-Zig modules (crypto, token,
    // password, db) tests run standalone.
    const run_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_tests.step);
}
