const std = @import("std");
const helpers = @import("build/helpers.zig");
const examples = @import("build/examples.zig");
const tools = @import("build/tools.zig");
const packages = @import("build/packages.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── dhi dependency ──────────────────────────────────────────────────────
    const dhi_dep = b.dependency("dhi", .{});
    const dhi_model_mod = dhi_dep.module("model");
    const dhi_validator_mod = dhi_dep.module("validator");

    // ── kuri dependency (browser automation for debug mode) ─────────────────
    const kuri_dep = b.dependency("kuri", .{
        .target = target,
        .optimize = if (optimize != .Debug) optimize else .ReleaseFast,
    });

    // ── "mer" module (framework public API) ──────────────────────────────────
    const mer_mod = b.addModule("mer", .{
        .root_source_file = b.path("src/mer.zig"),
    });
    mer_mod.addImport("dhi_model", dhi_model_mod);
    mer_mod.addImport("dhi_validator", dhi_validator_mod);

    // ── Demo site (examples/site) ───────────────────────────────────────────
    const counter_config_mod = b.addModule("counter_config", .{
        .root_source_file = b.path("examples/site/wasm/counter_config.zig"),
    });
    const site_extras: []const struct { []const u8, *std.Build.Module } = &.{.{ "counter_config", counter_config_mod }};

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (optimize != .Debug) true else null,
    });
    main_mod.addImport("mer", mer_mod);
    main_mod.addImport("counter_config", counter_config_mod);
    helpers.addDirModules(b, main_mod, mer_mod, "examples/site/app", "app", site_extras);
    helpers.addDirModules(b, main_mod, mer_mod, "examples/site/api", "api", &.{});
    helpers.addRoutesModule(b, main_mod, mer_mod, "src/generated/routes.zig", "examples/site/app", "examples/site/api", site_extras);

    const exe = b.addExecutable(.{ .name = "merjs", .root_module = main_mod });
    b.installArtifact(exe);

    // Install kuri binary alongside merjs.
    const install_kuri = b.addInstallArtifact(kuri_dep.artifact("kuri"), .{});
    b.getInstallStep().dependOn(&install_kuri.step);

    // ── `zig build serve` ────────────────────────────────────────────────────
    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_exe.addArgs(args);
    b.step("serve", "Start the merjs dev server").dependOn(&run_exe.step);

    // ── Codegen ──────────────────────────────────────────────────────────────
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
    b.step("codegen", "Regenerate src/generated/routes.zig").dependOn(&run_codegen.step);

    // ── Prerender (SSG) ─────────────────────────────────────────────────────
    const run_prerender = b.addRunArtifact(exe);
    run_prerender.addArg("--prerender");
    run_prerender.step.dependOn(b.getInstallStep());
    b.step("prerender", "Pre-render pages to dist/").dependOn(&run_prerender.step);

    // ── `zig build prod` ────────────────────────────────────────────────────
    const prod_step = b.step("prod", "Full production build: codegen + compile + prerender to dist/");
    prod_step.dependOn(&run_codegen.step);
    prod_step.dependOn(b.getInstallStep());
    prod_step.dependOn(&run_prerender.step);

    // ── WASM targets ────────────────────────────────────────────────────────
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const counter_wasm = helpers.addWasmExe(b, "counter", "examples/site/wasm/counter.zig", wasm_target);
    const install_counter = b.addInstallFile(counter_wasm.getEmittedBin(), "../examples/site/public/counter.wasm");
    const wasm_step = b.step("wasm", "Compile WASM modules → public/*.wasm");
    wasm_step.dependOn(&install_counter.step);

    const synth_wasm = helpers.addWasmExe(b, "synth", "examples/site/wasm/synth.zig", wasm_target);
    const install_synth = b.addInstallFile(synth_wasm.getEmittedBin(), "../examples/site/public/synth.wasm");
    wasm_step.dependOn(&install_synth.step);

    const grep_wasm = helpers.addWasmExe(b, "grep", "examples/site/wasm/grep.zig", wasm_target);
    const install_grep = b.addInstallFile(grep_wasm.getEmittedBin(), "../examples/site/worker/grep.wasm");
    b.step("grep", "Compile grep WASM").dependOn(&install_grep.step);

    // ── Worker WASM ─────────────────────────────────────────────────────────
    const worker_mod = b.createModule(.{
        .root_source_file = b.path("src/worker.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    worker_mod.addImport("mer", mer_mod);
    worker_mod.addImport("counter_config", counter_config_mod);
    helpers.addDirModules(b, worker_mod, mer_mod, "examples/site/app", "app", site_extras);
    helpers.addDirModules(b, worker_mod, mer_mod, "examples/site/api", "api", &.{});
    helpers.addRoutesModule(b, worker_mod, mer_mod, "src/generated/routes.zig", "examples/site/app", "examples/site/api", site_extras);
    const worker_wasm = b.addExecutable(.{ .name = "merjs", .root_module = worker_mod });
    worker_wasm.rdynamic = true;
    worker_wasm.entry = .disabled;
    const install_worker = b.addInstallFile(worker_wasm.getEmittedBin(), "../examples/site/worker/merjs.wasm");
    const worker_step = b.step("worker", "Compile worker WASM for Cloudflare Workers");
    worker_step.dependOn(&install_worker.step);
    worker_step.dependOn(&install_grep.step);

    // ── Examples (sgdata, kanban) ────────────────────────────────────────────
    examples.addExamples(b, mer_mod, wasm_target);

    // ── Tools (CSS, setup) ──────────────────────────────────────────────────
    tools.addTools(b);

    // ── CLI ─────────────────────────────────────────────────────────────────
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("cli.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (optimize != .Debug) true else null,
    });
    const cli_exe = b.addExecutable(.{ .name = "mer", .root_module = cli_mod });
    b.step("cli", "Build the `mer` CLI binary").dependOn(&b.addInstallArtifact(cli_exe, .{}).step);

    // ── Tests ───────────────────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("mer", mer_mod);
    helpers.addDirModules(b, test_mod, mer_mod, "examples/site/app", "app", site_extras);
    helpers.addDirModules(b, test_mod, mer_mod, "examples/site/api", "api", &.{});
    helpers.addRoutesModule(b, test_mod, mer_mod, "src/generated/routes.zig", "examples/site/app", "examples/site/api", site_extras);
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_mod }));
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    // Run inline tests in individual framework source files.
    for ([_][]const u8{ "src/css.zig", "src/session.zig", "src/telemetry.zig" }) |src_path| {
        const file_test_mod = b.createModule(.{
            .root_source_file = b.path(src_path),
            .target = target,
            .optimize = optimize,
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = file_test_mod })).step);
    }
    // Run router inline tests.
    {
        const router_test_mod = b.createModule(.{
            .root_source_file = b.path("src/router.zig"),
            .target = target,
            .optimize = optimize,
        });
        router_test_mod.addImport("mer", mer_mod);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = router_test_mod })).step);
    }

    // ── Consumer integration test (issue #62) ──────────────────────────────
    // Simulates a consumer project with its own routes — proves the named
    // module override works and framework example routes don't leak in.
    {
        const consumer_test_mod = b.createModule(.{
            .root_source_file = b.path("tests/consumer/src/test_consumer_routes.zig"),
            .target = target,
            .optimize = optimize,
        });
        consumer_test_mod.addImport("mer", mer_mod);
        // Give the test access to ssr.zig (framework internals).
        consumer_test_mod.addImport("ssr.zig", b.createModule(.{
            .root_source_file = b.path("src/ssr.zig"),
        }));
        // Wire ssr.zig's dependencies.
        consumer_test_mod.import_table.get("ssr.zig").?.addImport("mer", mer_mod);
        consumer_test_mod.import_table.get("ssr.zig").?.addImport("router.zig", b.createModule(.{
            .root_source_file = b.path("src/router.zig"),
        }));
        consumer_test_mod.import_table.get("ssr.zig").?.import_table.get("router.zig").?.addImport("mer", mer_mod);
        // The key: wire "routes" to the CONSUMER's routes, not the framework's.
        const consumer_routes_mod = b.createModule(.{
            .root_source_file = b.path("tests/consumer/src/routes.zig"),
        });
        consumer_routes_mod.addImport("mer", mer_mod);
        // Add consumer page modules to both routes and test modules.
        const consumer_pages = [_]struct { []const u8, []const u8 }{
            .{ "app/index", "tests/consumer/app/index.zig" },
            .{ "app/dashboard", "tests/consumer/app/dashboard.zig" },
        };
        for (consumer_pages) |page| {
            const page_mod = b.createModule(.{ .root_source_file = b.path(page[1]) });
            page_mod.addImport("mer", mer_mod);
            consumer_routes_mod.addImport(page[0], page_mod);
            consumer_test_mod.addImport(page[0], page_mod);
        }
        consumer_test_mod.import_table.get("ssr.zig").?.addImport("routes", consumer_routes_mod);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = consumer_test_mod })).step);
    }

    // ── Packages ────────────────────────────────────────────────────────────
    packages.addPackages(b, target, optimize, mer_mod);

    // ── `zig build desktop-spike` — macOS native app research (#50) ─────────
    if (target.result.os.tag == .macos) {
        const spike_mod = b.createModule(.{
            .root_source_file = b.path("examples/desktop/spike.zig"),
            .target = target,
            .optimize = optimize,
        });
        const spike_exe = b.addExecutable(.{ .name = "desktop-spike", .root_module = spike_mod });
        spike_exe.linkFramework("AppKit");
        spike_exe.linkFramework("WebKit");
        spike_exe.linkFramework("Foundation");
        spike_exe.linkLibC();
        const spike_step = b.step("desktop-spike", "Research spike: Zig ObjC bridge for AppKit/WebKit (#50)");
        spike_step.dependOn(&b.addInstallArtifact(spike_exe, .{}).step);
    }
}
