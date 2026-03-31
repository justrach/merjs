// cli.zig — standalone CLI entry point for the `mer` command.
//
//   mer init <name>      Scaffold a new merjs project
//   mer dev              Run codegen + start dev server
//   mer build            Production build (codegen + compile + prerender)
//   mer add <feature>    Add optional features (css, wasm, worker)
//   mer update           Update merjs dependency to latest
//   mer --version        Print version

const std = @import("std");
const builtin = @import("builtin");

pub const version = "0.2.1";

const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        print("mer {s}\n", .{version});
        return;
    }

    if (std.mem.eql(u8, cmd, "init")) {
        const name = if (args.len >= 3) args[2] else ".";
        try cmdInit(alloc, name);
        return;
    }

    if (std.mem.eql(u8, cmd, "dev")) {
        try cmdDev(alloc, args[2..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "build")) {
        try cmdBuild(alloc);
        return;
    }

    if (std.mem.eql(u8, cmd, "add")) {
        if (args.len < 3) {
            print("mer: missing feature name\n\n  usage: mer add <feature>\n  features: css, wasm, worker\n\n", .{});
            std.process.exit(1);
        }
        try cmdAdd(alloc, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "update")) {
        try cmdUpdate(alloc);
        return;
    }

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
        return;
    }

    print("mer: unknown command '{s}'\n\n", .{cmd});
    printUsage();
}

// ── init ────────────────────────────────────────────────────────────────────

const TemplateFile = struct {
    path: []const u8,
    content: []const u8,
};

const template_files = [_]TemplateFile{
    .{ .path = "app/index.zig", .content = @embedFile("examples/starter/app/index.zig") },
    .{ .path = "app/about.zig", .content = @embedFile("examples/starter/app/about.zig") },
    .{ .path = "app/layout.zig", .content = @embedFile("examples/starter/app/layout.zig") },
    .{ .path = "app/404.zig", .content = @embedFile("examples/starter/app/404.zig") },
    .{ .path = "api/hello.zig", .content = @embedFile("examples/starter/api/hello.zig") },
    .{ .path = "public/.gitkeep", .content = "" },
};

const build_zig_template =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const merjs_dep = b.dependency("merjs", .{});
    \\    const mer_mod = merjs_dep.module("mer");
    \\
    \\    const main_mod = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .strip = if (optimize != .Debug) true else null,
    \\    });
    \\    main_mod.addImport("mer", mer_mod);
    \\    addDirModules(b, main_mod, mer_mod, "app");
    \\    addDirModules(b, main_mod, mer_mod, "api");
    \\    addRoutesModule(b, main_mod, mer_mod);
    \\
    \\    const exe = b.addExecutable(.{ .name = "app", .root_module = main_mod });
    \\    b.installArtifact(exe);
    \\
    \\    // zig build codegen
    \\    const codegen_exe = b.addExecutable(.{
    \\        .name = "codegen",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = merjs_dep.path("tools/codegen.zig"),
    \\            .target = b.graph.host,
    \\            .optimize = .Debug,
    \\        }),
    \\    });
    \\    const run_codegen = b.addRunArtifact(codegen_exe);
    \\    run_codegen.setCwd(b.path("."));
    \\    b.step("codegen", "Regenerate src/generated/routes.zig").dependOn(&run_codegen.step);
    \\
    \\    // Auto-run codegen before compiling (fresh clones just work).
    \\    exe.step.dependOn(&run_codegen.step);
    \\
    \\    // zig build serve
    \\    const run_exe = b.addRunArtifact(exe);
    \\    run_exe.step.dependOn(b.getInstallStep());
    \\    if (b.args) |args| run_exe.addArgs(args);
    \\    b.step("serve", "Start the dev server").dependOn(&run_exe.step);
    \\}
    \\
    \\fn addRoutesModule(b: *std.Build, mod: *std.Build.Module, mer_mod: *std.Build.Module) void {
    \\    const routes_mod = b.createModule(.{
    \\        .root_source_file = b.path("src/generated/routes.zig"),
    \\    });
    \\    routes_mod.addImport("mer", mer_mod);
    \\    addDirModules(b, routes_mod, mer_mod, "app");
    \\    addDirModules(b, routes_mod, mer_mod, "api");
    \\    mod.addImport("routes", routes_mod);
    \\}
    \\
    \\fn addDirModules(b: *std.Build, mod: *std.Build.Module, mer_mod: *std.Build.Module, dir: []const u8) void {
    \\    const layout_path = b.fmt("{s}/layout.zig", .{dir});
    \\    const layout_mod: ?*std.Build.Module = blk: {
    \\        std.fs.cwd().access(layout_path, .{}) catch break :blk null;
    \\        const m = b.createModule(.{ .root_source_file = b.path(layout_path) });
    \\        m.addImport("mer", mer_mod);
    \\        mod.addImport(b.fmt("{s}/layout", .{dir}), m);
    \\        break :blk m;
    \\    };
    \\    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return;
    \\    defer d.close();
    \\    var walker = d.walk(b.allocator) catch return;
    \\    defer walker.deinit();
    \\    while (walker.next() catch null) |entry| {
    \\        if (entry.kind != .file) continue;
    \\        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
    \\        if (std.mem.eql(u8, entry.path, "layout.zig")) continue;
    \\        const file_path = b.fmt("{s}/{s}", .{ dir, entry.path });
    \\        const import_name = b.fmt("{s}/{s}", .{ dir, entry.path[0 .. entry.path.len - 4] });
    \\        const route_mod = b.createModule(.{ .root_source_file = b.path(file_path) });
    \\        route_mod.addImport("mer", mer_mod);
    \\        if (layout_mod) |lm| route_mod.addImport(b.fmt("{s}/layout", .{dir}), lm);
    \\        mod.addImport(import_name, route_mod);
    \\    }
    \\}
    \\
;

const main_zig_template =
    \\// main.zig — app entry point.
    \\// Usage:
    \\//   zig build serve               (dev server on :3000, hot reload)
    \\//   zig build serve -- --port 8080
    \\//   zig build serve -- --no-dev   (disable hot reload)
    \\
    \\const std = @import("std");
    \\const mer = @import("mer");
    \\
    \\const log = std.log.scoped(.main);
    \\
    \\pub fn main() !void {
    \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    \\    defer _ = gpa.deinit();
    \\    const alloc = gpa.allocator();
    \\
    \\    const args = try std.process.argsAlloc(alloc);
    \\    defer std.process.argsFree(alloc, args);
    \\
    \\    // Load .env before threads start.
    \\    mer.loadDotenv(alloc);
    \\
    \\    var config = mer.Config{
    \\        .host = "127.0.0.1",
    \\        .port = 3000,
    \\        .dev = true,
    \\    };
    \\
    \\    var do_prerender = false;
    \\
    \\    var i: usize = 1;
    \\    while (i < args.len) : (i += 1) {
    \\        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
    \\            config.port = try std.fmt.parseInt(u16, args[i + 1], 10);
    \\            i += 1;
    \\        } else if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
    \\            config.host = args[i + 1];
    \\            i += 1;
    \\        } else if (std.mem.eql(u8, args[i], "--no-dev")) {
    \\            config.dev = false;
    \\        } else if (std.mem.eql(u8, args[i], "--debug")) {
    \\            config.debug = true;
    \\        } else if (std.mem.eql(u8, args[i], "--kuri-port") and i + 1 < args.len) {
    \\            config.kuri_port = try std.fmt.parseInt(u16, args[i + 1], 10);
    \\            i += 1;
    \\        } else if (std.mem.eql(u8, args[i], "--verbose") or std.mem.eql(u8, args[i], "-v")) {
    \\            config.verbose = true;
    \\        } else if (std.mem.eql(u8, args[i], "--prerender")) {
    \\            do_prerender = true;
    \\        }
    \\    }
    \\
    \\    // Build router from generated routes.
    \\    var router = mer.Router.fromGenerated(alloc, @import("routes"));
    \\    defer router.deinit();
    \\
    \\    // SSG mode: pre-render pages to dist/ and exit.
    \\    if (do_prerender) {
    \\        try mer.runPrerender(alloc, &router);
    \\        return;
    \\    }
    \\
    \\    // File watcher (dev mode only).
    \\    var watcher = mer.Watcher.init(alloc, "app");
    \\    defer watcher.deinit();
    \\
    \\    if (config.dev) {
    \\        const wt = try std.Thread.spawn(.{}, mer.Watcher.run, .{&watcher});
    \\        wt.detach();
    \\        log.info("hot reload active — watching app/", .{});
    \\    }
    \\
    \\    var server = mer.Server.init(alloc, config, &router, if (config.dev) &watcher else null);
    \\    try server.listen();
    \\}
    \\
;

fn cmdInit(alloc: std.mem.Allocator, name: []const u8) !void {
    const use_cwd = std.mem.eql(u8, name, ".");
    if (!use_cwd) {
        std.fs.cwd().makeDir(name) catch |err| {
            if (err == error.PathAlreadyExists) {
                print("mer: directory '{s}' already exists\n", .{name});
                std.process.exit(1);
            }
            return err;
        };
    }

    var dir = if (use_cwd)
        std.fs.cwd()
    else
        try std.fs.cwd().openDir(name, .{});

    // Write template files.
    for (template_files) |tf| {
        if (std.fs.path.dirname(tf.path)) |parent| {
            dir.makePath(parent) catch {};
        }
        const file = try dir.createFile(tf.path, .{});
        defer file.close();
        try file.writeAll(tf.content);
    }

    // Write build.zig.
    {
        const file = try dir.createFile("build.zig", .{});
        defer file.close();
        try file.writeAll(build_zig_template);
    }

    // Write build.zig.zon.
    // Sanitize project name to a valid Zig bare identifier (replace non-alnum with _).
    const zig_name = try alloc.dupe(u8, name);
    defer alloc.free(zig_name);
    for (zig_name) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '_') c.* = '_';
    }
    {
        const file = try dir.createFile("build.zig.zon", .{});
        defer file.close();
        try file.writeAll(".{\n    .name = .");
        try file.writeAll(zig_name);
        try file.writeAll(
            \\,
            \\    .version = "0.1.0",
            \\    .minimum_zig_version = "0.15.1",
            \\    .dependencies = .{
            \\        .merjs = .{
            \\            .url = "git+https://github.com/justrach/merjs.git",
            \\        },
            \\    },
            \\    .paths = .{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\        "app",
            \\        "api",
            \\        "public",
            \\    },
            \\}
            \\
        );
    }

    // Patch in the fingerprint: run zig build to get the suggested value.
    {
        const cwd_path = if (use_cwd) "." else name;
        const result = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "zig", "build" },
            .cwd = cwd_path,
        });
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        // Parse "suggested value: 0x..." from stderr.
        if (std.mem.indexOf(u8, result.stderr, "suggested value: ")) |idx| {
            const start = idx + "suggested value: ".len;
            const end = std.mem.indexOfPos(u8, result.stderr, start, "\n") orelse result.stderr.len;
            const fp_value = result.stderr[start..end];
            // Read the zon, insert fingerprint after the name line.
            const zon_file = if (use_cwd)
                try std.fs.cwd().openFile("build.zig.zon", .{ .mode = .read_only })
            else
                try (try std.fs.cwd().openDir(name, .{})).openFile("build.zig.zon", .{ .mode = .read_only });
            const zon_content = try zon_file.readToEndAlloc(alloc, 4096);
            zon_file.close();
            defer alloc.free(zon_content);
            // Insert ".fingerprint = 0x...,\n" after first ",\n"
            if (std.mem.indexOf(u8, zon_content, ",\n")) |comma_pos| {
                const insert_pos = comma_pos + 2; // after ",\n"
                const fp_line = try std.fmt.allocPrint(alloc, "    .fingerprint = {s},\n", .{fp_value});
                defer alloc.free(fp_line);
                const new_content = try std.mem.concat(alloc, u8, &.{
                    zon_content[0..insert_pos],
                    fp_line,
                    zon_content[insert_pos..],
                });
                defer alloc.free(new_content);
                const out_file = if (use_cwd)
                    try std.fs.cwd().createFile("build.zig.zon", .{})
                else
                    try (try std.fs.cwd().openDir(name, .{})).createFile("build.zig.zon", .{});
                defer out_file.close();
                try out_file.writeAll(new_content);
            }
        }
    }

    // Auto-fetch the merjs dependency so the project builds immediately (#61).
    // Step 1: `zig fetch` (no --save) prints the package hash to stdout.
    // Step 2: `zig fetch --save` pins the commit URL into build.zig.zon.
    // Step 3: patch the .hash field in after the .url line.
    {
        const cwd_path = if (use_cwd) "." else name;
        print("  fetching merjs dependency...\n", .{});

        // Get the package hash (printed to stdout by zig fetch without --save).
        const hash_result = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "zig", "fetch", "git+https://github.com/justrach/merjs.git" },
            .cwd = cwd_path,
        });
        defer alloc.free(hash_result.stdout);
        defer alloc.free(hash_result.stderr);

        if (hash_result.term.Exited != 0) {
            print("  warning: could not fetch merjs dependency (no network?)\n", .{});
            print("  run manually: zig fetch --save=merjs git+https://github.com/justrach/merjs.git\n", .{});
        } else {
            const pkg_hash = std.mem.trimRight(u8, hash_result.stdout, "\n\r ");

            // Pin the commit URL into build.zig.zon.
            const save_result = try std.process.Child.run(.{
                .allocator = alloc,
                .argv = &.{ "zig", "fetch", "--save=merjs", "git+https://github.com/justrach/merjs.git" },
                .cwd = cwd_path,
            });
            alloc.free(save_result.stdout);
            alloc.free(save_result.stderr);

            // Patch .hash into build.zig.zon after the .url line.
            if (pkg_hash.len > 0) {
                const zon_path_str = if (use_cwd) "build.zig.zon" else try std.fmt.allocPrint(alloc, "{s}/build.zig.zon", .{name});
                defer if (!use_cwd) alloc.free(zon_path_str);
                const zon_file = try std.fs.cwd().openFile(zon_path_str, .{ .mode = .read_only });
                const zon_content = try zon_file.readToEndAlloc(alloc, 8192);
                zon_file.close();
                defer alloc.free(zon_content);
                if (std.mem.indexOf(u8, zon_content, ".url = \"git+https://github.com/justrach/merjs.git")) |url_start| {
                    if (std.mem.indexOfPos(u8, zon_content, url_start, "\n")) |eol| {
                        const insert_pos = eol + 1;
                        const hash_line = try std.fmt.allocPrint(alloc, "            .hash = \"{s}\",\n", .{pkg_hash});
                        defer alloc.free(hash_line);
                        const new_content = try std.mem.concat(alloc, u8, &.{
                            zon_content[0..insert_pos],
                            hash_line,
                            zon_content[insert_pos..],
                        });
                        defer alloc.free(new_content);
                        const out_file = try std.fs.cwd().createFile(zon_path_str, .{});
                        defer out_file.close();
                        try out_file.writeAll(new_content);
                    }
                }
            }
        }
    }



    dir.makePath("src/generated") catch {};
    {
        const file = try dir.createFile("src/generated/.gitkeep", .{});
        file.close();
    }
    {
        const file = try dir.createFile("src/main.zig", .{});
        defer file.close();
        try file.writeAll(main_zig_template);
    }

    // Write .gitignore.
    {
        const file = try dir.createFile(".gitignore", .{});
        defer file.close();
        try file.writeAll(
            \\zig-out/
            \\.zig-cache/
            \\src/generated/*
            \\!src/generated/.gitkeep
            \\tools/
            \\dist/
            \\.env
            \\
        );
    }

    if (!use_cwd) dir.close();

    print("\n", .{});
    print("  mer project created", .{});
    if (!use_cwd) print(" in ./{s}", .{name});
    print("\n\n", .{});
    print("  next steps:\n\n", .{});
    if (!use_cwd) print("    cd {s}\n", .{name});
    print("    zig build serve       # start dev server on :3000\n", .{});
    print("\n  or just: mer dev\n", .{});
    print("\n  optional: mer add css | wasm | worker\n\n", .{});
}

// ── dev ─────────────────────────────────────────────────────────────────────

fn cmdDev(alloc: std.mem.Allocator, extra_args: []const []const u8) !void {
    std.fs.cwd().access("build.zig", .{}) catch {
        print("mer: no build.zig found — are you in a merjs project?\n", .{});
        std.process.exit(1);
    };

    print("mer: running codegen...\n", .{});
    {
        const result = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "zig", "build", "codegen" },
        });
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        const exited = result.term == .Exited;
        if (!exited or result.term.Exited != 0) {
            print("mer: codegen failed:\n{s}", .{result.stderr});
            std.process.exit(1);
        }
    }

    print("mer: starting dev server...\n", .{});
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "zig", "build", "serve" });
    if (extra_args.len > 0) {
        try argv.append(alloc, "--");
        for (extra_args) |arg| try argv.append(alloc, arg);
    }

    var child = std.process.Child.init(argv.items, alloc);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    _ = try child.wait();
}

// ── build ───────────────────────────────────────────────────────────────────

fn cmdBuild(alloc: std.mem.Allocator) !void {
    std.fs.cwd().access("build.zig", .{}) catch {
        print("mer: no build.zig found — are you in a merjs project?\n", .{});
        std.process.exit(1);
    };

    print("mer: production build...\n", .{});
    var child = std.process.Child.init(
        &.{ "zig", "build", "-Doptimize=ReleaseSmall", "prod" },
        alloc,
    );
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    const exited = term == .Exited;
    if (!exited or term.Exited != 0) {
        print("mer: build failed\n", .{});
        std.process.exit(1);
    }
    print("mer: build complete → zig-out/bin/ + dist/\n", .{});
}

// ── update ──────────────────────────────────────────────────────────────────

fn cmdUpdate(alloc: std.mem.Allocator) !void {
    std.fs.cwd().access("build.zig.zon", .{}) catch {
        print("mer: no build.zig.zon found — are you in a merjs project?\n", .{});
        std.process.exit(1);
    };

    print("mer: updating merjs to latest...\n", .{});
    var child = std.process.Child.init(
        &.{ "zig", "fetch", "--save=merjs", "git+https://github.com/justrach/merjs.git" },
        alloc,
    );
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    const exited = term == .Exited;
    if (!exited or term.Exited != 0) {
        print("mer: update failed\n", .{});
        std.process.exit(1);
    }
    print("mer: updated — run `zig build` to rebuild\n", .{});
}

// ── add ─────────────────────────────────────────────────────────────────────

const tailwind_url = "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-" ++
    (switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => "unsupported",
    }) ++ "-" ++
    (switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => "unsupported",
    });

fn cmdAdd(alloc: std.mem.Allocator, feature: []const u8) !void {
    if (std.mem.eql(u8, feature, "css")) {
        try cmdAddCss(alloc);
    } else if (std.mem.eql(u8, feature, "wasm")) {
        try cmdAddWasm();
    } else if (std.mem.eql(u8, feature, "worker")) {
        try cmdAddWorker();
    } else {
        print("mer: unknown feature '{s}'\n\n  available: css, wasm, worker\n\n", .{feature});
        std.process.exit(1);
    }
}

fn cmdAddCss(alloc: std.mem.Allocator) !void {
    const exists = if (std.fs.cwd().access("tools/tailwindcss", .{})) true else |_| false;
    if (exists) {
        print("  tools/tailwindcss already exists\n", .{});
    } else {
        print("  downloading Tailwind CSS standalone CLI...\n", .{});
        std.fs.cwd().makePath("tools") catch {};
        var child = std.process.Child.init(
            &.{ "sh", "-c", "curl -sLo tools/tailwindcss " ++ tailwind_url ++ " && chmod +x tools/tailwindcss" },
            alloc,
        );
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        const term = try child.wait();
        const exited = term == .Exited;
        if (!exited or term.Exited != 0) {
            print("  failed to download Tailwind CLI\n", .{});
            std.process.exit(1);
        }
        print("  saved to tools/tailwindcss\n", .{});
    }

    const input_exists = if (std.fs.cwd().access("public/input.css", .{})) true else |_| false;
    if (!input_exists) {
        std.fs.cwd().makePath("public") catch {};
        const file = try std.fs.cwd().createFile("public/input.css", .{});
        defer file.close();
        try file.writeAll("@import \"tailwindcss\";\n");
        print("  created public/input.css\n", .{});
    }

    print("\n  run `zig build css` to compile Tailwind → public/styles.css\n\n", .{});
}

fn cmdAddWasm() !void {
    std.fs.cwd().makePath("wasm") catch {};
    const exists = if (std.fs.cwd().access("wasm/counter.zig", .{})) true else |_| false;
    if (exists) {
        print("  wasm/counter.zig already exists\n", .{});
    } else {
        const file = try std.fs.cwd().createFile("wasm/counter.zig", .{});
        defer file.close();
        try file.writeAll(
            \\export fn increment(n: i32) i32 {
            \\    return n + 1;
            \\}
            \\
        );
        print("  created wasm/counter.zig\n", .{});
    }
    print("\n  add a wasm build step to build.zig, then run `zig build wasm`\n\n", .{});
}

fn cmdAddWorker() !void {
    std.fs.cwd().makePath("worker") catch {};
    const exists = if (std.fs.cwd().access("worker/wrangler.toml", .{})) true else |_| false;
    if (exists) {
        print("  worker/wrangler.toml already exists\n", .{});
    } else {
        {
            const file = try std.fs.cwd().createFile("worker/wrangler.toml", .{});
            defer file.close();
            try file.writeAll(
                \\name = "my-app"
                \\main = "worker.js"
                \\compatibility_date = "2024-12-01"
                \\
                \\[assets]
                \\directory = "../public"
                \\
                \\[build]
                \\command = "cd .. && zig build worker"
                \\
                \\[[rules]]
                \\type = "CompiledWasm"
                \\globs = ["**/*.wasm"]
                \\
            );
            print("  created worker/wrangler.toml\n", .{});
        }
        {
            const file = try std.fs.cwd().createFile("worker/worker.js", .{});
            defer file.close();
            try file.writeAll(
                \\import wasm from "./merjs.wasm";
                \\
                \\export default {
                \\  async fetch(request, env) {
                \\    // TODO: wire up WASM-based request handling
                \\    return new Response("Hello from merjs worker!", {
                \\      headers: { "content-type": "text/plain" },
                \\    });
                \\  },
                \\};
                \\
            );
            print("  created worker/worker.js\n", .{});
        }
    }
    print("\n  edit worker/wrangler.toml, then: zig build worker && cd worker && wrangler deploy\n\n", .{});
}

// ── help ────────────────────────────────────────────────────────────────────

fn printUsage() void {
    print(
        \\
        \\  mer — the merjs CLI (v{s})
        \\
        \\  usage:
        \\    mer init <name>      scaffold a new project
        \\    mer dev [--port N]   codegen + dev server with hot reload
        \\    mer build            production build (ReleaseSmall + prerender)
        \\    mer add <feature>    add optional features (css, wasm, worker)
        \\    mer update           update merjs to latest version
        \\    mer --version        print version
        \\
        \\  https://github.com/justrach/merjs
        \\
        \\
    , .{version});
}
