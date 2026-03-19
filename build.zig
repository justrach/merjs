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

    // ── Main module (demo site) ─────────────────────────────────────────────
    const counter_config_mod = b.addModule("counter_config", .{
        .root_source_file = b.path("examples/site/wasm/counter_config.zig"),
    });
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (optimize != .Debug) true else null,
    });
    main_mod.addImport("mer", mer_mod);
    main_mod.addImport("counter_config", counter_config_mod);
    const site_extras: []const struct { []const u8, *std.Build.Module } = &.{.{ "counter_config", counter_config_mod }};
    addDirModules(b, main_mod, mer_mod, "examples/site/app", "app", site_extras);
    addDirModules(b, main_mod, mer_mod, "examples/site/api", "api", &.{});

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

    // ── Prerender step (SSG) ───────────────────────────────────────────────
    // Reuses the main exe with --prerender flag.
    const run_prerender = b.addRunArtifact(exe);
    run_prerender.addArg("--prerender");
    run_prerender.step.dependOn(b.getInstallStep());
    const prerender_step = b.step("prerender", "Pre-render pages with `pub const prerender = true` to dist/");
    prerender_step.dependOn(&run_prerender.step);

    // ── `zig build prod` — one-shot: codegen → build → prerender ────────────
    const prod_step = b.step("prod", "Full production build: codegen + compile + prerender to dist/");
    // 1. codegen first
    prod_step.dependOn(&run_codegen.step);
    // 2. then build + install the binary (depends on codegen via source file)
    prod_step.dependOn(b.getInstallStep());
    // 3. then prerender (depends on the installed binary)
    prod_step.dependOn(&run_prerender.step);

    // ── WASM: wasm/counter.zig → public/counter.wasm ────────────────────────
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const counter_wasm = b.addExecutable(.{
        .name = "counter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/site/wasm/counter.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    counter_wasm.rdynamic = true;
    counter_wasm.entry = .disabled;
    const install_wasm = b.addInstallFile(counter_wasm.getEmittedBin(), "../examples/site/public/counter.wasm");
    const wasm_step = b.step("wasm", "Compile wasm/counter.zig → public/counter.wasm");
    wasm_step.dependOn(&install_wasm.step);

    // ── WASM: wasm/synth.zig → public/synth.wasm ──────────────────────────────
    const synth_wasm = b.addExecutable(.{
        .name = "synth",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/site/wasm/synth.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    synth_wasm.rdynamic = true;
    synth_wasm.entry = .disabled;
    const install_synth = b.addInstallFile(synth_wasm.getEmittedBin(), "../examples/site/public/synth.wasm");
    wasm_step.dependOn(&install_synth.step);

    // ── WASM: wasm/grep.zig → worker/grep.wasm ────────────────────────────
    const grep_wasm = b.addExecutable(.{
        .name = "grep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/site/wasm/grep.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    grep_wasm.rdynamic = true;
    grep_wasm.entry = .disabled;
    const install_grep = b.addInstallFile(grep_wasm.getEmittedBin(), "../examples/site/worker/grep.wasm");
    const grep_step = b.step("grep", "Compile wasm/grep.zig → worker/grep.wasm");
    grep_step.dependOn(&install_grep.step);
    // Worker step dependency added below (after worker_step is defined)

    // ── Worker WASM: src/worker.zig → worker/merjs.wasm ────────────────────
    const worker_mod = b.createModule(.{
        .root_source_file = b.path("src/worker.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    worker_mod.addImport("mer", mer_mod);
    worker_mod.addImport("counter_config", counter_config_mod);
    addDirModules(b, worker_mod, mer_mod, "examples/site/app", "app", site_extras);
    addDirModules(b, worker_mod, mer_mod, "examples/site/api", "api", &.{});
    const worker_wasm = b.addExecutable(.{
        .name = "merjs",
        .root_module = worker_mod,
    });
    worker_wasm.rdynamic = true;
    worker_wasm.entry = .disabled;
    const install_worker = b.addInstallFile(worker_wasm.getEmittedBin(), "../examples/site/worker/merjs.wasm");
    const worker_step = b.step("worker", "Compile src/worker.zig → worker/merjs.wasm (Cloudflare Workers)");
    worker_step.dependOn(&install_worker.step);
    worker_step.dependOn(&install_grep.step);

    // ── sgdata Worker WASM: examples/singapore-data-dashboard → worker/merjs.wasm
    const sgdata_mod = b.createModule(.{
        .root_source_file = b.path("src/worker.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    sgdata_mod.addImport("mer", mer_mod);
    addDirModules(b, sgdata_mod, mer_mod, "examples/singapore-data-dashboard/app", "app", &.{});
    addDirModules(b, sgdata_mod, mer_mod, "examples/singapore-data-dashboard/api", "api", &.{});
    const sgdata_wasm = b.addExecutable(.{
        .name = "merjs",
        .root_module = sgdata_mod,
    });
    sgdata_wasm.rdynamic = true;
    sgdata_wasm.entry = .disabled;
    const install_sgdata = b.addInstallFile(sgdata_wasm.getEmittedBin(), "../examples/singapore-data-dashboard/worker/merjs.wasm");
    const sgdata_step = b.step("sgdata-worker", "Compile sgdata worker WASM");
    sgdata_step.dependOn(&install_sgdata.step);
    // ── Kanban example Worker WASM ──────────────────────────────────────────────
    const kanban_mod = b.createModule(.{
        .root_source_file = b.path("examples/kanban/worker_entry.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    kanban_mod.addImport("mer", mer_mod);
    kanban_mod.addImport("router.zig", b.createModule(.{
        .root_source_file = b.path("src/router.zig"),
        .imports = &.{.{ .name = "mer", .module = mer_mod }},
    }));
    addDirModules(b, kanban_mod, mer_mod, "examples/kanban/app", "app", &.{});
    const kanban_wasm = b.addExecutable(.{
        .name = "merjs",
        .root_module = kanban_mod,
    });
    kanban_wasm.rdynamic = true;
    kanban_wasm.entry = .disabled;
    const install_kanban = b.addInstallFile(kanban_wasm.getEmittedBin(), "../examples/kanban/worker/merjs.wasm");
    const kanban_step = b.step("worker-example-kanban", "Compile kanban example worker WASM");
    kanban_step.dependOn(&install_kanban.step);

    // ── CSS: Tailwind v4 → public/styles.css ────────────────────────────────
    // Auto-download the standalone Tailwind CLI if missing.
    const host_target = b.graph.host.result;
    const tw_os: []const u8 = switch (host_target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => "unsupported",
    };
    const tw_arch: []const u8 = switch (host_target.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => "unsupported",
    };
    const ensure_tw = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            "test -x tools/tailwindcss || " ++
                "(mkdir -p tools && echo 'Downloading Tailwind CSS standalone CLI...' && " ++
                "curl -sLo tools/tailwindcss " ++
                "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-{s}-{s} && " ++
                "chmod +x tools/tailwindcss && echo 'Done.')",
            .{ tw_os, tw_arch },
        ),
    });
    const run_tw = b.addSystemCommand(&.{
        "tools/tailwindcss", "--input",           "examples/site/public/input.css",
        "--output",          "examples/site/public/styles.css", "--minify",
    });
    run_tw.step.dependOn(&ensure_tw.step);
    const css_step = b.step("css", "Compile Tailwind v4 → public/styles.css");
    css_step.dependOn(&run_tw.step);

    // ── `zig build setup` — download toolchain dependencies ─────────────────
    const setup_step = b.step("setup", "Download toolchain dependencies (Tailwind CLI)");
    setup_step.dependOn(&ensure_tw.step);

    // ── `zig build cli` — standalone CLI binary ─────────────────────────────
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("cli.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (optimize != .Debug) true else null,
    });
    const cli_exe = b.addExecutable(.{ .name = "mer", .root_module = cli_mod });
    const install_cli = b.addInstallArtifact(cli_exe, .{});
    const cli_step = b.step("cli", "Build the `mer` CLI binary");
    cli_step.dependOn(&install_cli.step);
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("mer", mer_mod);
    addDirModules(b, test_mod, mer_mod, "examples/site/app", "app", site_extras);
    addDirModules(b, test_mod, mer_mod, "examples/site/api", "api", &.{});
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
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

/// Scan dir/ and add each *.zig as a named module import.
/// "app" dir: app/index.zig  → import "app/index"
/// "api"   dir: api/hello.zig   → import "api/hello"
/// Scan dir/ recursively and add each *.zig as a named module import.
/// "app" dir: app/index.zig       → import "app/index"
///            app/users/[id].zig  → import "app/users/[id]"
/// "api" dir: api/hello.zig       → import "api/hello"
fn addDirModules(
    b: *std.Build,
    mod: *std.Build.Module,
    mer_mod: *std.Build.Module,
    dir: []const u8,
    import_prefix: []const u8,
    extra_imports: []const struct { []const u8, *std.Build.Module },
) void {
    const layout_path = b.fmt("{s}/layout.zig", .{dir});
    const layout_mod: ?*std.Build.Module = blk: {
        std.fs.cwd().access(layout_path, .{}) catch break :blk null;
        const m = b.createModule(.{ .root_source_file = b.path(layout_path) });
        m.addImport("mer", mer_mod);
        for (extra_imports) |ei| m.addImport(ei[0], ei[1]);
        const layout_import = b.fmt("{s}/layout", .{import_prefix});
        mod.addImport(layout_import, m);
        break :blk m;
    };

    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return;
    defer d.close();
    var walker = d.walk(b.allocator) catch return;
    defer walker.deinit();
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, "layout.zig")) continue;
        const file_path = b.fmt("{s}/{s}", .{ dir, entry.path });
        const import_name = b.fmt("{s}/{s}", .{ import_prefix, entry.path[0 .. entry.path.len - 4] });
        const route_mod = b.createModule(.{ .root_source_file = b.path(file_path) });
        route_mod.addImport("mer", mer_mod);
        for (extra_imports) |ei| route_mod.addImport(ei[0], ei[1]);
        if (layout_mod) |lm| route_mod.addImport(b.fmt("{s}/layout", .{import_prefix}), lm);
        mod.addImport(import_name, route_mod);
    }
}
