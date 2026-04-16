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
    // TODO: re-enable once kuri is updated for Zig 0.16
    // const kuri_dep = b.dependency("kuri", .{
    //     .target = target,
    //     .optimize = if (optimize != .Debug) optimize else .ReleaseFast,
    // });

    // ── "mer" module (framework public API) ──────────────────────────────────
    const mer_mod = b.addModule("mer", .{
        .root_source_file = b.path("src/mer.zig"),
        .link_libc = true,
    });
    mer_mod.addImport("dhi_model", dhi_model_mod);
    mer_mod.addImport("dhi_validator", dhi_validator_mod);

    // ── turboapi-core (shared router + HTTP utilities) ──
    const core_dep = b.dependency("turboapi_core", .{});
    const core_mod = core_dep.module("turboapi-core");
    mer_mod.addImport("turboapi-core", core_mod);

    // Self-referential import: internal files (server.zig, router.zig, …)
    // file-imported from mer.zig still resolve their `@import("mer")` calls.
    mer_mod.addImport("mer", mer_mod);

    // ── Expose framework internals as named modules for consumer projects ────
    // Consumers do: `merjs_dep.module("server")` in their build.zig.
    // Each module has "mer" wired so transitive file-imports just work.
    const server_mod = b.addModule("server", .{ .root_source_file = b.path("src/server.zig") });
    server_mod.addImport("mer", mer_mod);
    const watcher_named = b.addModule("watcher", .{ .root_source_file = b.path("src/watcher.zig") });
    _ = watcher_named;
    const prerender_mod = b.addModule("prerender", .{ .root_source_file = b.path("src/prerender.zig") });
    prerender_mod.addImport("mer", mer_mod);

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
        .link_libc = true, // 0.16: std.c.* (pthread, clock_gettime, etc.) needs explicit libc
    });
    main_mod.addImport("mer", mer_mod);
    main_mod.addImport("counter_config", counter_config_mod);
    helpers.addDirModules(b, main_mod, mer_mod, "examples/site/app", "app", site_extras);
    helpers.addDirModules(b, main_mod, mer_mod, "examples/site/api", "api", &.{});
    helpers.addRoutesModule(b, main_mod, mer_mod, "src/generated/routes.zig", "examples/site/app", "examples/site/api", site_extras);

    const exe = b.addExecutable(.{ .name = "merjs", .root_module = main_mod });
    b.installArtifact(exe);

    // Install kuri binary alongside merjs.
    // TODO: re-enable once kuri is updated for Zig 0.16
    // const install_kuri = b.addInstallArtifact(kuri_dep.artifact("kuri"), .{});
    // b.getInstallStep().dependOn(&install_kuri.step);

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

    // ── Auto-run codegen before compiling (fresh clones just work) ───────────
    exe.step.dependOn(&run_codegen.step);

    // ── `zig build serve` ────────────────────────────────────────────────────
    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_exe.addArgs(args);
    b.step("serve", "Start the merjs dev server").dependOn(&run_exe.step);

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
    const worker_named = b.addModule("worker", .{
        .root_source_file = b.path("src/worker.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    worker_named.addImport("mer", mer_mod);
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
    // Auto-run codegen before worker compilation too.
    worker_wasm.step.dependOn(&run_codegen.step);
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
        .link_libc = true,
    });
    const cli_exe = b.addExecutable(.{ .name = "mer", .root_module = cli_mod });
    b.step("cli", "Build the `mer` CLI binary").dependOn(&b.addInstallArtifact(cli_exe, .{}).step);

    // ── Tests ───────────────────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("mer", mer_mod);
    helpers.addDirModules(b, test_mod, mer_mod, "examples/site/app", "app", site_extras);
    helpers.addDirModules(b, test_mod, mer_mod, "examples/site/api", "api", &.{});
    helpers.addRoutesModule(b, test_mod, mer_mod, "src/generated/routes.zig", "examples/site/app", "examples/site/api", site_extras);
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_mod }));
    // Auto-run codegen before tests too.
    run_tests.step.dependOn(&run_codegen.step);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    // Run inline tests in individual framework source files.
    for ([_][]const u8{ "src/css.zig", "src/session.zig", "src/telemetry.zig" }) |src_path| {
        const file_test_mod = b.createModule(.{
            .root_source_file = b.path(src_path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = file_test_mod })).step);
    }
    {
        const cli_test_mod = b.createModule(.{
            .root_source_file = b.path("cli.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli_test_mod })).step);
    }
    // Run router + runtime inline tests (through mer.zig as root to avoid
    // file-ownership conflict: mer.zig file-imports router.zig/server.zig/etc.,
    // so those files belong to the mer module and can't also be test roots).
    {
        const mer_test_mod = b.createModule(.{
            .root_source_file = b.path("src/mer.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mer_test_mod.addImport("dhi_model", dhi_model_mod);
        mer_test_mod.addImport("dhi_validator", dhi_validator_mod);
        mer_test_mod.addImport("turboapi-core", core_mod);
        mer_test_mod.addImport("mer", mer_test_mod);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mer_test_mod })).step);
    }

    // ── Consumer integration test (issue #62, #69) ────────────────────────
    // Simulates a consumer project with its own routes — proves that
    // `mer.Router.fromGenerated` works and framework example routes don't leak in.
    // With the self-referential mer import, no manual wiring of ssr.zig/router.zig
    // transitive deps is needed — consumers just use `@import("mer")`.
    {
        const consumer_test_mod = b.createModule(.{
            .root_source_file = b.path("tests/consumer/src/test_consumer_routes.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        consumer_test_mod.addImport("mer", mer_mod);
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
        consumer_test_mod.addImport("routes", consumer_routes_mod);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = consumer_test_mod })).step);
    }

    // ── Starter scaffold smoke test ──────────────────────────────────────────
    // Compiles the embedded starter templates that `mer init` writes so
    // scaffold regressions fail in CI before they ship.
    {
        const starter_test_mod = b.createModule(.{
            .root_source_file = b.path("tests/starter/src/test_starter_scaffold.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        starter_test_mod.addImport("mer", mer_mod);

        const starter_layout_mod = b.createModule(.{
            .root_source_file = b.path("examples/starter/app/layout.zig"),
        });
        starter_layout_mod.addImport("mer", mer_mod);

        const starter_page_specs = [_]struct { []const u8, []const u8 }{
            .{ "app/index", "examples/starter/app/index.zig" },
            .{ "app/about", "examples/starter/app/about.zig" },
            .{ "app/404", "examples/starter/app/404.zig" },
        };
        const starter_routes_mod = b.createModule(.{
            .root_source_file = b.path("tests/starter/src/routes.zig"),
        });
        starter_routes_mod.addImport("mer", mer_mod);
        starter_routes_mod.addImport("app/layout", starter_layout_mod);

        for (starter_page_specs) |page| {
            const page_mod = b.createModule(.{ .root_source_file = b.path(page[1]) });
            page_mod.addImport("mer", mer_mod);
            page_mod.addImport("app/layout", starter_layout_mod);
            starter_routes_mod.addImport(page[0], page_mod);
            starter_test_mod.addImport(page[0], page_mod);
        }

        const starter_api_mod = b.createModule(.{
            .root_source_file = b.path("examples/starter/api/hello.zig"),
        });
        starter_api_mod.addImport("mer", mer_mod);
        starter_routes_mod.addImport("api/hello", starter_api_mod);
        starter_test_mod.addImport("api/hello", starter_api_mod);
        starter_test_mod.addImport("app/layout", starter_layout_mod);
        starter_test_mod.addImport("routes", starter_routes_mod);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = starter_test_mod })).step);
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
        spike_mod.linkFramework("AppKit", .{});
        spike_mod.linkFramework("WebKit", .{});
        spike_mod.linkFramework("Foundation", .{});
        spike_mod.link_libc = true;
        const spike_step = b.step("desktop-spike", "Research spike: Zig ObjC bridge for AppKit/WebKit (#50)");
        spike_step.dependOn(&b.addInstallArtifact(spike_exe, .{}).step);
    }

    // ── `zig build desktop` — native macOS desktop app ──────────────────────
    if (target.result.os.tag == .macos) {
        const desktop_mod = b.createModule(.{
            .root_source_file = b.path("examples/desktop/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        desktop_mod.addImport("mer", mer_mod);
        helpers.addDirModules(b, desktop_mod, mer_mod, "examples/site/app", "app", site_extras);
        helpers.addDirModules(b, desktop_mod, mer_mod, "examples/site/api", "api", &.{});
        helpers.addRoutesModule(b, desktop_mod, mer_mod, "src/generated/routes.zig", "examples/site/app", "examples/site/api", site_extras);
        const desktop_exe = b.addExecutable(.{ .name = "merapp", .root_module = desktop_mod });
        desktop_mod.linkFramework("AppKit", .{});
        desktop_mod.linkFramework("WebKit", .{});
        desktop_mod.linkFramework("Foundation", .{});
        desktop_mod.link_libc = true;
        const desktop_install = b.addInstallArtifact(desktop_exe, .{});
        const desktop_step = b.step("desktop", "Build native macOS desktop app (also produces MerApp.app bundle)");
        desktop_step.dependOn(&desktop_install.step);

        // ── .app bundle — MerApp.app/Contents/MacOS/merapp + Info.plist ──────
        const plist = b.addWriteFile("MerApp.app/Contents/Info.plist",
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\  <key>CFBundleExecutable</key>    <string>merapp</string>
            \\  <key>CFBundleIdentifier</key>    <string>com.merjs.desktop</string>
            \\  <key>CFBundleName</key>          <string>MerApp</string>
            \\  <key>CFBundleVersion</key>       <string>0.2.2</string>
            \\  <key>NSHighResolutionCapable</key><true/>
            \\  <key>NSPrincipalClass</key>      <string>NSApplication</string>
            \\</dict>
            \\</plist>
        );
        const bundle_bin = b.addInstallFile(
            desktop_exe.getEmittedBin(),
            "MerApp.app/Contents/MacOS/merapp",
        );
        bundle_bin.step.dependOn(&desktop_install.step);
        const bundle_plist = b.addInstallDirectory(.{
            .source_dir = plist.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "",
        });
        desktop_step.dependOn(&bundle_bin.step);
        desktop_step.dependOn(&bundle_plist.step);
    }
}
