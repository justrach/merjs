const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const merjs_dep = b.dependency("merjs", .{});
    const mer_mod = merjs_dep.module("mer");

    // Create page modules — each consumer page imports "mer".
    const index_mod = b.createModule(.{ .root_source_file = b.path("app/index.zig") });
    index_mod.addImport("mer", mer_mod);

    const about_mod = b.createModule(.{ .root_source_file = b.path("app/about.zig") });
    about_mod.addImport("mer", mer_mod);

    // Create routes module — imports "mer" and the page modules.
    const routes_mod = b.createModule(.{
        .root_source_file = b.path("src/routes.zig"),
    });
    routes_mod.addImport("mer", mer_mod);
    routes_mod.addImport("app/index", index_mod);
    routes_mod.addImport("app/about", about_mod);

    // Test module — imports "mer" and "routes".
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_standalone.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("mer", mer_mod);
    test_mod.addImport("routes", routes_mod);

    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_mod }));
    const test_step = b.step("test", "Run standalone consumer tests");
    test_step.dependOn(&run_tests.step);
}
