// build/packages.zig — first-party package build targets.

const std = @import("std");

pub fn addPackages(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mer_mod: *std.Build.Module,
) void {
    // ── merjs-auth: wire + test ──────────────────────────────────────────────
    const merjs_auth_mod = b.createModule(.{
        .root_source_file = b.path("packages/merjs-auth/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    merjs_auth_mod.addImport("mer", mer_mod);
    const merjs_auth_tests = b.addTest(.{ .root_module = merjs_auth_mod });
    const run_auth_tests = b.addRunArtifact(merjs_auth_tests);
    const auth_test_step = b.step("test-auth", "Run merjs-auth unit tests");
    auth_test_step.dependOn(&run_auth_tests.step);
}
