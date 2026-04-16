const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{});

    const merjs_dep = b.dependency("merjs", .{});
    const mer_mod = merjs_dep.module("mer");

    // Worker WASM module
    const worker_mod = b.createModule(.{
        .root_source_file = b.path("src/worker.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        }),
        .optimize = .ReleaseSmall,
    });
    worker_mod.addImport("mer", mer_mod);

    const worker_wasm = b.addExecutable(.{
        .name = "installer",
        .root_module = worker_mod,
    });
    worker_wasm.rdynamic = true;
    worker_wasm.entry = .disabled;

    const install_worker = b.addInstallFile(worker_wasm.getEmittedBin(), "worker/installer.wasm");
    const worker_step = b.step("worker", "Build Cloudflare Worker WASM");
    worker_step.dependOn(&install_worker.step);

    // Install install.sh and index.html to public
    b.installDirectory(.{
        .source_dir = b.path("public"),
        .install_dir = .prefix,
        .install_subdir = "public",
    });
}
