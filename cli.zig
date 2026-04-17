// cli.zig -- standalone CLI entry point for the `mer` command.
//
//   mer init <name>      Scaffold a new merjs project
//   mer dev              Run codegen + start dev server
//   mer build            Production build (codegen + compile + prerender)
//   mer add <feature>    Add optional features (css, wasm, worker)
//   mer update           Update merjs dependency to latest
//   mer --version        Print version

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");

pub const version = "0.2.5";

const print = std.debug.print;

/// Resolve an executable name to full path using PATH environment variable.
/// Caller owns the returned memory.
fn resolveInPath(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(name)) return alloc.dupe(u8, name);

    // Get PATH from environment using POSIX API
    const path_ptr = std.c.getenv("PATH") orelse return alloc.dupe(u8, name);
    const path_env = std.mem.sliceTo(path_ptr, 0);
    if (path_env.len == 0) return alloc.dupe(u8, name);

    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full_path = try std.fs.path.join(alloc, &.{ dir, name });

        // Check if file exists using Io.Dir via runtime
        std.Io.Dir.cwd().access(runtime.io, full_path, .{}) catch {
            alloc.free(full_path);
            continue;
        };
        return full_path;
    }
    return alloc.dupe(u8, name);
}

/// Get current Unix timestamp in milliseconds (vanity metric helper).
fn currentMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Initialize std.Io runtime (Auto-selects Evented on Linux, Threaded elsewhere)
    try runtime.init(alloc);
    defer runtime.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

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
            print("mer: missing feature name\n\n  usage: mer add <feature>\n  features: css, wasm, worker, ui [component]\n\n", .{});
            std.process.exit(1);
        }
        try cmdAdd(alloc, args[2], args);
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
    .{ .path = "tools/codegen.zig", .content = @embedFile("tools/codegen.zig") },
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
    \\            .root_source_file = b.path("tools/codegen.zig"),
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
    \\
    \\    // zig build test
    \\    const test_mod = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\    test_mod.addImport("mer", mer_mod);
    \\    addDirModules(b, test_mod, mer_mod, "app");
    \\    addDirModules(b, test_mod, mer_mod, "api");
    \\    addRoutesModule(b, test_mod, mer_mod);
    \\    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_mod }));
    \\    run_tests.step.dependOn(&run_codegen.step);
    \\    b.step("test", "Compile the starter app").dependOn(&run_tests.step);
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
    \\    std.Io.Dir.cwd().access(b.graph.io, layout_path, .{}) catch break :blk null;
    \\        const m = b.createModule(.{ .root_source_file = b.path(layout_path) });
    \\        m.addImport("mer", mer_mod);
    \\        mod.addImport(b.fmt("{s}/layout", .{dir}), m);
    \\        break :blk m;
    \\    };
    \\    var d = std.Io.Dir.cwd().openDir(b.graph.io, dir, .{ .iterate = true }) catch return;
    \\    defer d.close(b.graph.io);
    \\    var walker = d.walk(b.allocator) catch return;
    \\    defer walker.deinit();
    \\    while (walker.next(b.graph.io) catch null) |entry| {
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
    \\// main.zig -- app entry point.
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
    \\pub fn main(init: std.process.Init.Minimal) !void {
    \\    var gpa: std.heap.DebugAllocator(.{}) = .init;
    \\    defer _ = gpa.deinit();
    \\    const alloc = gpa.allocator();
    \\
    \\    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    \\    defer arena_state.deinit();
    \\    const args = try init.args.toSlice(arena_state.allocator());
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
    \\        log.info("hot reload active -- watching app/", .{});
    \\    }
    \\
    \\    var server = mer.Server.init(alloc, config, &router, if (config.dev) &watcher else null);
    \\    try server.listen();
    \\}
    \\
;

const generated_routes_placeholder =
    \\// GENERATED -- do not edit by hand.
    \\// Re-run `zig build codegen` to regenerate.
    \\
    \\const Route = @import("mer").Route;
    \\
    \\pub const routes: []const Route = &.{};
    \\pub const layout = null;
    \\pub const streamLayout = null;
    \\pub const notFound = null;
    \\
;

fn writeScaffoldFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.createDirPath(runtime.io, parent) catch {};
    }
    const file = try dir.createFile(runtime.io, path, .{});
    defer file.close(runtime.io);
    try file.writeStreamingAll(runtime.io, content);
}

fn writeTemplateFiles(dir: std.Io.Dir) !void {
    for (template_files) |tf| {
        try writeScaffoldFile(dir, tf.path, tf.content);
    }
}

fn projectNameForZon(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    const source = blk: {
        if (std.mem.eql(u8, name, ".")) {
            var cwd_buf: [4096]u8 = undefined;
            const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse ".";
            const cwd = std.mem.sliceTo(cwd_ptr, 0);
            break :blk try alloc.dupe(u8, std.fs.path.basename(cwd));
        }
        break :blk try alloc.dupe(u8, std.fs.path.basename(name));
    };
    defer alloc.free(source);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    for (source) |c| {
        if (out.items.len == 32) break;
        try out.append(alloc, if (std.ascii.isAlphanumeric(c) or c == '_') c else '_');
    }

    if (out.items.len == 0) {
        try out.appendSlice(alloc, "app");
    }

    if (!std.ascii.isAlphabetic(out.items[0]) and out.items[0] != '_') {
        if (out.items.len == 32) {
            out.items[0] = '_';
        } else {
            try out.insert(alloc, 0, '_');
        }
    }

    return out.toOwnedSlice(alloc);
}

fn writeBuildZigZon(dir: std.Io.Dir, alloc: std.mem.Allocator, name: []const u8) !void {
    const zig_name = try projectNameForZon(alloc, name);
    defer alloc.free(zig_name);

    const file = try dir.createFile(runtime.io, "build.zig.zon", .{});
    defer file.close(runtime.io);
    try file.writeStreamingAll(runtime.io, ".{\n    .name = .");
    try file.writeStreamingAll(runtime.io, zig_name);
    try file.writeStreamingAll(runtime.io, ",\n    .version = \"0.1.0\",\n");
    try file.writeStreamingAll(runtime.io, "    .minimum_zig_version = \"0.16.0\",\n");
    try file.writeStreamingAll(runtime.io, "    .dependencies = .{\n");
    try file.writeStreamingAll(runtime.io, "        .merjs = .{\n");
    try file.writeStreamingAll(runtime.io, "            .url = \"git+https://github.com/justrach/merjs.git\",\n");
    try file.writeStreamingAll(runtime.io, "        },\n");
    try file.writeStreamingAll(runtime.io, "    },\n");
    try file.writeStreamingAll(runtime.io, "    .paths = .{\n");
    try file.writeStreamingAll(runtime.io, "        \"build.zig\",\n");
    try file.writeStreamingAll(runtime.io, "        \"build.zig.zon\",\n");
    try file.writeStreamingAll(runtime.io, "        \"src\",\n");
    try file.writeStreamingAll(runtime.io, "        \"app\",\n");
    try file.writeStreamingAll(runtime.io, "        \"api\",\n");
    try file.writeStreamingAll(runtime.io, "        \"public\",\n");
    try file.writeStreamingAll(runtime.io, "    },\n");
    try file.writeStreamingAll(runtime.io, "}\n");
}

fn cmdInit(alloc: std.mem.Allocator, name: []const u8) !void {
    // Start timing for vanity metrics
    const start_ms = currentMs();
    var file_count: usize = 0;

    print("\n🚀 mer init — scaffolding new project\n\n", .{});

    const use_cwd = std.mem.eql(u8, name, ".");
    if (!use_cwd) {
        std.Io.Dir.cwd().createDir(runtime.io, name, .default_dir) catch |err| {
            if (err == error.PathAlreadyExists) {
                print("❌ Directory '{s}' already exists\n", .{name});
                std.process.exit(1);
            }
            return err;
        };
    }

    var dir = if (use_cwd)
        std.Io.Dir.cwd()
    else
        try std.Io.Dir.cwd().openDir(runtime.io, name, .{});

    print("📁 Creating project structure...\n", .{});

    // Write template files.
    try writeTemplateFiles(dir);
    file_count += 7; // 7 template files

    // Write build.zig.
    {
        const file = try dir.createFile(runtime.io, "build.zig", .{});
        defer file.close(runtime.io);
        try file.writeStreamingAll(runtime.io, build_zig_template);
        file_count += 1;
    }

    // Write build.zig.zon.
    try writeBuildZigZon(dir, alloc, name);
    file_count += 1;

    // Patch in the fingerprint: run zig build to get the suggested value.
    print("🔨 Running initial build for fingerprint...\n", .{});
    const build_start_ms = currentMs();
    {
        const cwd_path = if (use_cwd) "." else name;
        const zig_exe = try resolveInPath(alloc, "zig");
        defer alloc.free(zig_exe);
        const result = try std.process.run(alloc, runtime.io, .{
            .argv = &.{ zig_exe, "build" },
            .cwd = .{ .path = cwd_path },
        });
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        // Parse "suggested value: 0x..." from stderr.
        if (std.mem.indexOf(u8, result.stderr, "suggested value: ")) |idx| {
            const start = idx + "suggested value: ".len;
            const end = std.mem.indexOfPos(u8, result.stderr, start, "\n") orelse result.stderr.len;
            const fp_value = result.stderr[start..end];
            // Read the zon, insert fingerprint after the name line.
            const zon_content = try dir.readFileAlloc(runtime.io, "build.zig.zon", alloc, .limited(4096));
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
                const out_file = try dir.createFile(runtime.io, "build.zig.zon", .{});
                defer out_file.close(runtime.io);
                try out_file.writeStreamingAll(runtime.io, new_content);
            }
        }
    }

    // Auto-fetch the merjs dependency so the project builds immediately (#61).
    print("📦 Fetching merjs dependency...\n", .{});
    const fetch_start_ms = currentMs();
    {
        const cwd_path = if (use_cwd) "." else name;
        const zig_exe = try resolveInPath(alloc, "zig");
        defer alloc.free(zig_exe);

        // Get the package hash (printed to stdout by zig fetch without --save).
        const hash_result = try std.process.run(alloc, runtime.io, .{
            .argv = &.{ zig_exe, "fetch", "git+https://github.com/justrach/merjs.git" },
            .cwd = .{ .path = cwd_path },
        });
        defer alloc.free(hash_result.stdout);
        defer alloc.free(hash_result.stderr);

        if (hash_result.term.exited != 0) {
            print("   ⚠️  Could not fetch merjs dependency (no network?)\n", .{});
            print("      Run manually: zig fetch --save=merjs git+https://github.com/justrach/merjs.git\n", .{});
        } else {
            const pkg_hash = std.mem.trimEnd(u8, hash_result.stdout, "\n\r ");

            // Pin the commit URL into build.zig.zon.
            const save_result = try std.process.run(alloc, runtime.io, .{
                .argv = &.{ zig_exe, "fetch", "--save=merjs", "git+https://github.com/justrach/merjs.git" },
                .cwd = .{ .path = cwd_path },
            });
            alloc.free(save_result.stderr);

            // Patch .hash into build.zig.zon after the .url line.
            if (pkg_hash.len > 0) {
                const zon_path_str = if (use_cwd) "build.zig.zon" else try std.fmt.allocPrint(alloc, "{s}/build.zig.zon", .{name});
                defer if (!use_cwd) alloc.free(zon_path_str);
                const zon_content = try std.Io.Dir.cwd().readFileAlloc(runtime.io, zon_path_str, alloc, .limited(8192));
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
                        const out_file = try std.Io.Dir.cwd().createFile(runtime.io, zon_path_str, .{});
                        defer out_file.close(runtime.io);
                        try out_file.writeStreamingAll(runtime.io, new_content);
                    }
                }
            }
        }
    }

    dir.createDirPath(runtime.io, "src/generated") catch {};
    {
        const file = try dir.createFile(runtime.io, "src/generated/.gitkeep", .{});
        file.close(runtime.io);
    }
    {
        const file = try dir.createFile(runtime.io, "src/generated/routes.zig", .{});
        defer file.close(runtime.io);
        try file.writeStreamingAll(runtime.io, generated_routes_placeholder);
    }
    {
        const file = try dir.createFile(runtime.io, "src/main.zig", .{});
        defer file.close(runtime.io);
        try file.writeStreamingAll(runtime.io, main_zig_template);
    }

    // Write .gitignore.
    {
        const file = try dir.createFile(runtime.io, ".gitignore", .{});
        defer file.close(runtime.io);
        try file.writeStreamingAll(runtime.io,
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

    if (!use_cwd) dir.close(runtime.io);

    // Calculate vanity metrics
    const total_ms = currentMs() - start_ms;
    const build_ms = currentMs() - build_start_ms;
    const fetch_ms = currentMs() - fetch_start_ms;
    file_count += 5; // src/generated/*, .gitignore, src/main.zig

    // Print vanity summary
    print("\n", .{});
    print("✨ Success! Created {s}", .{name});
    if (!use_cwd) {
        if (std.fs.path.isAbsolute(name)) {
            print(" at {s}\n", .{name});
        } else {
            print(" at ./{s}\n", .{name});
        }
    } else {
        print("\n", .{});
    }
    print("   {d} files in {d}ms\n", .{ file_count, total_ms });
    print("   🔨 Build: {d}ms | 📦 Fetch: {d}ms\n\n", .{ build_ms, fetch_ms });

    print("Next steps:\n\n", .{});
    if (!use_cwd) print("  cd {s}\n", .{name});
    print("  mer dev               # start dev server with hot reload\n", .{});
    print("  # or:\n", .{});
    print("  zig build serve       # start dev server on :3000\n", .{});
    print("\nOptional:\n", .{});
    print("  mer add css           # add Tailwind CSS support\n", .{});
    print("  mer add wasm          # add WebAssembly module\n", .{});
    print("  mer add worker        # add Cloudflare Worker output\n\n", .{});
}

test "projectNameForZon uses basename for absolute paths" {
    const alloc = std.testing.allocator;
    const got = try projectNameForZon(alloc, "/tmp/nested/my-app");
    defer alloc.free(got);
    try std.testing.expectEqualStrings("my_app", got);
}

test "projectNameForZon prefixes numeric names" {
    const alloc = std.testing.allocator;
    const got = try projectNameForZon(alloc, "123site");
    defer alloc.free(got);
    try std.testing.expectEqualStrings("_123site", got);
}

test "projectNameForZon clamps long names to 32 chars" {
    const alloc = std.testing.allocator;
    const got = try projectNameForZon(alloc, "abcdefghijklmnopqrstuvwxyz0123456789");
    defer alloc.free(got);
    try std.testing.expectEqual(@as(usize, 32), got.len);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz012345", got);
}

test "build_zig_template exposes a starter test step" {
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "b.step(\"test\", \"Compile the starter app\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "run_tests.step.dependOn(&run_codegen.step);") != null);
}

test "build_zig_template uses local codegen entrypoint" {
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "b.path(\"tools/codegen.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "merjs_dep.path(\"tools/codegen.zig\")") == null);
}

// NOTE: These tests are disabled in Zig 0.16 because std.testing.tmpDir
// uses the old std.testing.io API which is incompatible with std.Io.
// The functionality is tested via integration tests in build.zig.

test "writeBuildZigZon uses sanitized basename for absolute paths" {
    // Skip when running inline tests (runtime.io not initialized)
    if (@import("builtin").is_test) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeBuildZigZon(tmp.dir, std.testing.allocator, "/tmp/nested/my-app");
    const content = try tmp.dir.readFileAlloc(runtime.io, "build.zig.zon", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, ".name = .my_app") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"public\"") != null);
}

test "writeTemplateFiles emits starter scaffold files" {
    // Skip when running inline tests (runtime.io not initialized)
    if (@import("builtin").is_test) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplateFiles(tmp.dir);

    try tmp.dir.access(runtime.io, "app/index.zig", .{});
    try tmp.dir.access(runtime.io, "app/about.zig", .{});
    try tmp.dir.access(runtime.io, "app/layout.zig", .{});
    try tmp.dir.access(runtime.io, "app/404.zig", .{});
    try tmp.dir.access(runtime.io, "api/hello.zig", .{});
    try tmp.dir.access(runtime.io, "public/.gitkeep", .{});
    try tmp.dir.access(runtime.io, "tools/codegen.zig", .{});
}

test "generated routes placeholder is valid scaffold output" {
    try std.testing.expect(std.mem.indexOf(u8, generated_routes_placeholder, "pub const routes: []const Route = &.{};") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_routes_placeholder, "pub const notFound = null;") != null);
}

// ── dev ─────────────────────────────────────────────────────────────────────

fn cmdDev(alloc: std.mem.Allocator, extra_args: []const []const u8) !void {
    std.Io.Dir.cwd().access(runtime.io, "build.zig", .{}) catch {
        print("mer: no build.zig found -- are you in a merjs project?\n", .{});
        std.process.exit(1);
    };

    print("mer: running codegen...\n", .{});
    {
        const result = try std.process.run(alloc, runtime.io, .{
            .argv = &.{ "zig", "build", "codegen" },
        });
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        const exited = result.term == .exited;
        if (!exited or result.term.exited != 0) {
            print("mer: codegen failed:\n{s}", .{result.stderr});
            std.process.exit(1);
        }
    }

    print("mer: starting dev server...\n", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "zig", "build", "serve" });
    if (extra_args.len > 0) {
        try argv.append(alloc, "--");
        for (extra_args) |arg| try argv.append(alloc, arg);
    }

    var child = try std.process.spawn(runtime.io, .{
        .argv = argv.items,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    _ = try child.wait(runtime.io);
}

// -- build -------------------------------------------------------------------
fn cmdBuild(_: std.mem.Allocator) !void {
    std.Io.Dir.cwd().access(runtime.io, "build.zig", .{}) catch {
        print("mer: no build.zig found — are you in a merjs project?\n", .{});
        std.process.exit(1);
    };

    print("mer: production build...\n", .{});
    var child = try std.process.spawn(runtime.io, .{
        .argv = &.{ "zig", "build", "-Doptimize=ReleaseSmall", "prod" },
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(runtime.io);
    const exited = term == .exited;
    if (!exited or term.exited != 0) {
        print("mer: build failed\n", .{});
        std.process.exit(1);
    }
    print("mer: build complete — zig-out/bin/ + dist/\n", .{});
}

// ── update ──────────────────────────────────────────────────────────────────

fn cmdUpdate(_: std.mem.Allocator) !void {
    std.Io.Dir.cwd().access(runtime.io, "build.zig.zon", .{}) catch {
        print("mer: no build.zig.zon found -- are you in a merjs project?\n", .{});
        std.process.exit(1);
    };

    print("mer: updating merjs to latest...\n", .{});
    var child = try std.process.spawn(runtime.io, .{
        .argv = &.{ "zig", "fetch", "--save=merjs", "git+https://github.com/justrach/merjs.git" },
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(runtime.io);
    const exited = term == .exited;
    if (!exited or term.exited != 0) {
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

fn cmdAdd(alloc: std.mem.Allocator, feature: []const u8, args: []const []const u8) !void {
    if (std.mem.eql(u8, feature, "css")) {
        try cmdAddCss(alloc);
    } else if (std.mem.eql(u8, feature, "wasm")) {
        try cmdAddWasm();
    } else if (std.mem.eql(u8, feature, "worker")) {
        try cmdAddWorker();
    } else if (std.mem.eql(u8, feature, "ui")) {
        if (args.len >= 4) {
            try cmdAddUiComponent(args[3]);
        } else {
            try cmdAddUiAll();
        }
    } else {
        print("mer: unknown feature '{s}'\n\n  available: css, wasm, worker, ui\n\n", .{feature});
        std.process.exit(1);
    }
}

fn cmdAddCss(_: std.mem.Allocator) !void {
    const exists = if (std.Io.Dir.cwd().access(runtime.io, "tools/tailwindcss", .{})) true else |_| false;
    if (exists) {
        print("  tools/tailwindcss already exists\n", .{});
    } else {
        print("  downloading Tailwind CSS standalone CLI...\n", .{});
        _ = std.Io.Dir.cwd().createDirPathOpen(runtime.io, "tools", .{}) catch {};
        var child = try std.process.spawn(runtime.io, .{
            .argv = &.{ "sh", "-c", "curl -sLo tools/tailwindcss " ++ tailwind_url ++ " && chmod +x tools/tailwindcss" },
            .stdout = .inherit,
            .stderr = .inherit,
        });
        const term = try child.wait(runtime.io);
        const exited = term == .exited;
        if (!exited or term.exited != 0) {
            print("  failed to download Tailwind CLI\n", .{});
            std.process.exit(1);
        }
        print("  saved to tools/tailwindcss\n", .{});
    }

    const input_exists = if (std.Io.Dir.cwd().access(runtime.io, "public/input.css", .{})) true else |_| false;
    if (!input_exists) {
        _ = std.Io.Dir.cwd().createDirPathOpen(runtime.io, "public", .{}) catch {};
        const file = try std.Io.Dir.cwd().createFile(runtime.io, "public/input.css", .{});
        defer file.close(runtime.io);
        try file.writeStreamingAll(runtime.io, "@import \"tailwindcss\";\n");
        print("  created public/input.css\n", .{});
    }

    print("\n  run `zig build css` to compile Tailwind -> public/styles.css\n\n", .{});
}

fn cmdAddWasm() !void {
    _ = std.Io.Dir.cwd().createDirPathOpen(runtime.io, "wasm", .{}) catch {};
    const exists = if (std.Io.Dir.cwd().access(runtime.io, "wasm/counter.zig", .{})) true else |_| false;
    if (exists) {
        print("  wasm/counter.zig already exists\n", .{});
    } else {
        const file = try std.Io.Dir.cwd().createFile(runtime.io, "wasm/counter.zig", .{});
        defer file.close(runtime.io);
        try file.writeStreamingAll(runtime.io,
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
    _ = std.Io.Dir.cwd().createDirPathOpen(runtime.io, "worker", .{}) catch {};
    const exists = if (std.Io.Dir.cwd().access(runtime.io, "worker/wrangler.toml", .{})) true else |_| false;
    if (exists) {
        print("  worker/wrangler.toml already exists\n", .{});
    } else {
        {
            const file = try std.Io.Dir.cwd().createFile(runtime.io, "worker/wrangler.toml", .{});
            defer file.close(runtime.io);
            try file.writeStreamingAll(runtime.io,
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
            const file = try std.Io.Dir.cwd().createFile(runtime.io, "worker/worker.js", .{});
            defer file.close(runtime.io);
            try file.writeStreamingAll(runtime.io,
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

// ── add ui ─────────────────────────────────────────────────────────────────

const ui_components = &[_][]const u8{
    "button",
    "card",
    "input",
    "badge",
    "alert",
};

const component_button = @embedFile("packages/merlion-ui/templates/button.zig");
const component_card = @embedFile("packages/merlion-ui/templates/card.zig");
const component_input = @embedFile("packages/merlion-ui/templates/input.zig");
const component_badge = @embedFile("packages/merlion-ui/templates/badge.zig");
const component_alert = @embedFile("packages/merlion-ui/templates/alert.zig");

fn cmdAddUiComponent(name: []const u8) !void {
    _ = std.Io.Dir.cwd().createDirPathOpen(runtime.io, "app/components", .{}) catch {};

    const content = if (std.mem.eql(u8, name, "button"))
        component_button
    else if (std.mem.eql(u8, name, "card"))
        component_card
    else if (std.mem.eql(u8, name, "input"))
        component_input
    else if (std.mem.eql(u8, name, "badge"))
        component_badge
    else if (std.mem.eql(u8, name, "alert"))
        component_alert
    else {
        print("mer: unknown component '{s}'\n\n  available: ", .{name});
        for (ui_components) |c| {
            print("{s}, ", .{c});
        }
        print("\n\n", .{});
        std.process.exit(1);
    };

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "app/components/{s}.zig", .{name}) catch {
        print("mer: component name too long\n", .{});
        return;
    };

    const exists = if (std.Io.Dir.cwd().access(runtime.io, path, .{})) true else |_| false;
    if (exists) {
        print("  {s} already exists (use --force to overwrite)\n", .{path});
        return;
    }

    const file = try std.Io.Dir.cwd().createFile(runtime.io, path, .{});
    defer file.close(runtime.io);
    try file.writeStreamingAll(runtime.io, content);

    print("  created {s}\n", .{path});
    print("\n  usage: const {s} = @import(\"components/{s}.zig\");\n\n", .{ name, name });
}

fn cmdAddUiAll() !void {
    print("  adding all merlion-ui components...\n\n", .{});
    for (ui_components) |name| {
        cmdAddUiComponent(name) catch |err| {
            print("  warning: failed to add {s}: {s}\n", .{ name, @errorName(err) });
        };
    }
    print("\n  run `mer add css` to add Tailwind CSS styling\n\n", .{});
}

// ── help ────────────────────────────────────────────────────────────────────

fn printUsage() void {
    print("\n  mer -- the merjs CLI (v{s})\n", .{version});
    print("\n  usage:\n", .{});
    print("    mer init <name>      scaffold a new project\n", .{});
    print("    mer dev [--port N]   codegen + dev server with hot reload\n", .{});
    print("    mer build            production build (ReleaseSmall + prerender)\n", .{});
    print("    mer add <feature>    add optional features (css, wasm, worker, ui [component])\n", .{});
    print("    mer update           update merjs to latest version\n", .{});
    print("    mer --version        print version\n", .{});
    print("\n  https://github.com/justrach/merjs\n\n", .{});
}
