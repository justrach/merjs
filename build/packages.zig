// build/packages.zig — first-party package build targets.

const std = @import("std");

pub fn addPackages(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mer_mod: *std.Build.Module,
    default_test_step: *std.Build.Step,
) void {
    // ── merjs-auth: wire + test ──────────────────────────────────────────────
    const merjs_auth_mod = b.createModule(.{
        .root_source_file = b.path("packages/merjs-auth/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    merjs_auth_mod.addImport("mer", mer_mod);
    merjs_auth_mod.addImport("runtime", mer_mod.import_table.get("runtime").?);
    const merjs_auth_tests = b.addTest(.{ .root_module = merjs_auth_mod });
    const run_auth_tests = b.addRunArtifact(merjs_auth_tests);

    const consumer_mod = b.createModule(.{
        .root_source_file = b.path("packages/merjs-auth/src/tests/consumer_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    consumer_mod.addImport("mer", mer_mod);
    consumer_mod.addImport("runtime", mer_mod.import_table.get("runtime").?);
    consumer_mod.addImport("merjs-auth", merjs_auth_mod);
    const run_consumer_tests = b.addRunArtifact(b.addTest(.{ .root_module = consumer_mod }));

    const auth_test_step = b.step("test-auth", "Run merjs-auth unit, flow, and consumer tests");
    auth_test_step.dependOn(&run_auth_tests.step);
    auth_test_step.dependOn(&run_consumer_tests.step);
    default_test_step.dependOn(auth_test_step);
}
