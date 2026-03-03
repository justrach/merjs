const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── dhi dependency ──────────────────────────────────────────────────────
    const dhi_dep = b.dependency("dhi", .{});
    const dhi_model_mod = dhi_dep.module("model");
    const dhi_validator_mod = dhi_dep.module("validator");

    // ── "mer" module ────────────────────────────────────────────────────────
    const mer_mod = b.addModule("mer", .{
        .root_source_file = b.path("src/mer.zig"),
    });
    mer_mod.addImport("dhi_model", dhi_model_mod);
    mer_mod.addImport("dhi_validator", dhi_validator_mod);

    // ── Main module ─────────────────────────────────────────────────────────
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("mer", mer_mod);
    addDirModules(b, main_mod, mer_mod, "app");
    addDirModules(b, main_mod, mer_mod, "api");

    // ── Main executable ─────────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "merjs",
        .root_module = main_mod,
    });
    b.installArtifact(exe);

    // ── `zig build serve` ────────────────────────────────────────────────────
    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_exe.addArgs(args);
    const serve_step = b.step("serve", "Start the merjs dev server");
    serve_step.dependOn(&run_exe.step);

    // ── Codegen step ────────────────────────────────────────────────────────
    const codegen_exe = b.addExecutable(.{
        .name = "codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/codegen.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_codegen = b.addRunArtifact(codegen_exe);
    run_codegen.setCwd(b.path("."));
    const codegen_step = b.step("codegen", "Regenerate src/generated/routes.zig");
    codegen_step.dependOn(&run_codegen.step);

    // ── WASM: wasm/counter.zig → public/counter.wasm ────────────────────────
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const counter_wasm = b.addExecutable(.{
        .name = "counter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("wasm/counter.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    counter_wasm.rdynamic = true;
    counter_wasm.entry = .disabled;
    const install_wasm = b.addInstallFile(counter_wasm.getEmittedBin(), "../public/counter.wasm");
    const wasm_step = b.step("wasm", "Compile wasm/counter.zig → public/counter.wasm");
    wasm_step.dependOn(&install_wasm.step);

    // ── Worker WASM: src/worker.zig → worker/merjs.wasm ────────────────────
    const worker_mod = b.createModule(.{
        .root_source_file = b.path("src/worker.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    worker_mod.addImport("mer", mer_mod);
    addDirModules(b, worker_mod, mer_mod, "app");
    addDirModules(b, worker_mod, mer_mod, "api");
    const worker_wasm = b.addExecutable(.{
        .name = "merjs",
        .root_module = worker_mod,
    });
    worker_wasm.rdynamic = true;
    worker_wasm.entry = .disabled;
    const install_worker = b.addInstallFile(worker_wasm.getEmittedBin(), "../worker/merjs.wasm");
    const worker_step = b.step("worker", "Compile src/worker.zig → worker/merjs.wasm (Cloudflare Workers)");
    worker_step.dependOn(&install_worker.step);

    // ── CSS: Tailwind v4 → public/styles.css ────────────────────────────────
    const run_tw = b.addSystemCommand(&.{
        "tools/tailwindcss", "--input", "public/input.css",
        "--output", "public/styles.css", "--minify",
    });
    const css_step = b.step("css", "Compile Tailwind v4 → public/styles.css");
    css_step.dependOn(&run_tw.step);

    // ── `zig build test` ─────────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("mer", mer_mod);
    addDirModules(b, test_mod, mer_mod, "app");
    addDirModules(b, test_mod, mer_mod, "api");
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Scan dir/ and add each *.zig as a named module import.
/// "app" dir: app/index.zig  → import "app/index"
/// "api"   dir: api/hello.zig   → import "api/hello"
fn addDirModules(b: *std.Build, mod: *std.Build.Module, mer_mod: *std.Build.Module, dir: []const u8) void {
    // Check if a layout module exists in this directory.
    const layout_path = b.fmt("{s}/layout.zig", .{dir});
    const layout_mod: ?*std.Build.Module = blk: {
        std.fs.cwd().access(layout_path, .{}) catch break :blk null;
        const m = b.createModule(.{ .root_source_file = b.path(layout_path) });
        m.addImport("mer", mer_mod);
        const layout_import = b.fmt("{s}/layout", .{dir});
        mod.addImport(layout_import, m);
        break :blk m;
    };

    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return;
    defer d.close();
    var it = d.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "layout.zig")) continue;
        const file_path    = b.fmt("{s}/{s}", .{ dir, entry.name });
        const import_name  = b.fmt("{s}/{s}", .{ dir, entry.name[0 .. entry.name.len - 4] });
        const route_mod = b.createModule(.{ .root_source_file = b.path(file_path) });
        route_mod.addImport("mer", mer_mod);
        if (layout_mod) |lm| route_mod.addImport(b.fmt("{s}/layout", .{dir}), lm);
        mod.addImport(import_name, route_mod);
    }
}
