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

const package_manifest = @embedFile("build.zig.zon");
pub const version = version: {
    const marker = ".version = \"";
    const start = (std.mem.indexOf(u8, package_manifest, marker) orelse
        @compileError("build.zig.zon has no version")) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, package_manifest, start, '"') orelse
        @compileError("build.zig.zon has an invalid version");
    break :version package_manifest[start..end];
};

const print = std.debug.print;

var process_environ: std.process.Environ = std.process.Environ.empty;

fn childEnv(alloc: std.mem.Allocator) !std.process.Environ.Map {
    return try process_environ.createMap(alloc);
}

fn runInheritEnv(alloc: std.mem.Allocator, options: std.process.RunOptions) !std.process.RunResult {
    var env = try childEnv(alloc);
    defer env.deinit();
    var opts = options;
    opts.environ_map = &env;
    return try std.process.run(alloc, runtime.io, opts);
}

fn spawnWaitInheritEnv(alloc: std.mem.Allocator, options: std.process.SpawnOptions) !std.process.Child.Term {
    var env = try childEnv(alloc);
    defer env.deinit();
    var opts = options;
    opts.environ_map = &env;
    var child = try std.process.spawn(runtime.io, opts);
    return try child.wait(runtime.io);
}

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

/// Get a monotonic timestamp in milliseconds (vanity metric helper).
fn currentMs() i64 {
    return std.Io.Clock.awake.now(runtime.io).toMilliseconds();
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    process_environ = init.environ;

    // Initialize std.Io runtime (Threaded on Zig 0.16-supported targets).
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
        try cmdInit(alloc, args[2..]);
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

    if (std.mem.eql(u8, cmd, "native")) {
        // mer native          → dev: hot reload + WebView
        // mer native build    → production-gated binary (no run)
        if (args.len >= 3 and std.mem.eql(u8, args[2], "build")) {
            try cmdNativeBuild(alloc, args[3..]);
        } else if (args.len >= 3 and std.mem.eql(u8, args[2], "doctor")) {
            try cmdNativeDoctor(alloc, args[3..]);
        } else {
            try cmdNative(alloc, args[2..]);
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "package")) {
        try cmdPackage(alloc, args[2..]);
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
    \\    const codegen_mod = b.createModule(.{
    \\        .root_source_file = b.path("tools/codegen.zig"),
    \\        .target = b.graph.host,
    \\        .optimize = .Debug,
    \\    });
    \\    codegen_mod.addImport("runtime", merjs_dep.module("runtime"));
    \\    codegen_mod.addImport("mercss_jit", merjs_dep.module("mercss_jit"));
    \\    const codegen_exe = b.addExecutable(.{
    \\        .name = "codegen",
    \\        .root_module = codegen_mod,
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
    \\    const test_artifact = b.addTest(.{ .root_module = test_mod });
    \\    test_artifact.step.dependOn(&run_codegen.step);
    \\    const run_tests = b.addRunArtifact(test_artifact);
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
    \\    // Load .env before threads start. The compatibility branch keeps the
    \\    // scaffold buildable against the dependency revision fetched below.
    \\    if (@hasDecl(mer, "loadDotenvStatus")) {
    \\        _ = try mer.loadDotenvStatus(alloc);
    \\    } else {
    \\        mer.loadDotenv(alloc);
    \\    }
    \\    defer if (@hasDecl(mer, "deinitDotenv")) mer.deinitDotenv();
    \\    mer.telemetry.init();
    \\    defer mer.telemetry.deinit();
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
    \\        } else if (std.mem.eql(u8, args[i], "--debug") or std.mem.eql(u8, args[i], "--kuri-port")) {
    \\            log.err("{s} was removed with the disabled browser automation integration", .{args[i]});
    \\            return error.RemovedBrowserAutomationOption;
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

const default_merjs_url = "git+https://github.com/justrach/merjs.git";

const InitOptions = struct {
    name: []const u8 = ".",
    merjs_url: []const u8 = default_merjs_url,
    merjs_path: ?[]const u8 = null,
};

fn parseInitOptions(args: []const []const u8) !InitOptions {
    var options = InitOptions{};
    var have_name = false;
    var have_url = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--merjs-url")) {
            if (i + 1 >= args.len) return error.MissingMerjsUrl;
            i += 1;
            options.merjs_url = args[i];
            have_url = true;
        } else if (std.mem.eql(u8, args[i], "--merjs-path")) {
            if (i + 1 >= args.len) return error.MissingMerjsPath;
            i += 1;
            options.merjs_path = args[i];
        } else if (std.mem.startsWith(u8, args[i], "-")) {
            return error.UnknownInitOption;
        } else if (!have_name) {
            options.name = args[i];
            have_name = true;
        } else {
            return error.UnexpectedInitArgument;
        }
    }
    if (options.merjs_url.len == 0) return error.MissingMerjsUrl;
    if (have_url and options.merjs_path != null) return error.ConflictingMerjsDependency;
    for (options.merjs_url) |c| if (c == '"' or c == '\\' or c <= 0x1f or c == 0x7f) return error.InvalidMerjsUrl;
    if (options.merjs_path) |path| {
        if (path.len == 0) return error.MissingMerjsPath;
        if (std.fs.path.isAbsolute(path)) return error.AbsoluteMerjsPath;
        for (path) |c| if (c == '"' or c == '\\' or c <= 0x1f or c == 0x7f) return error.InvalidMerjsPath;
    }
    return options;
}

fn writeBuildZigZon(dir: std.Io.Dir, alloc: std.mem.Allocator, name: []const u8, options: InitOptions) !void {
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
    if (options.merjs_path) |path| {
        try file.writeStreamingAll(runtime.io, "            .path = \"");
        try file.writeStreamingAll(runtime.io, path);
    } else {
        try file.writeStreamingAll(runtime.io, "            .url = \"");
        try file.writeStreamingAll(runtime.io, options.merjs_url);
    }
    try file.writeStreamingAll(runtime.io, "\",\n");
    try file.writeStreamingAll(runtime.io, "        },\n");
    try file.writeStreamingAll(runtime.io, "    },\n");
    try file.writeStreamingAll(runtime.io, "    .paths = .{\n");
    try file.writeStreamingAll(runtime.io, "        \"build.zig\",\n");
    try file.writeStreamingAll(runtime.io, "        \"build.zig.zon\",\n");
    try file.writeStreamingAll(runtime.io, "        \"src\",\n");
    try file.writeStreamingAll(runtime.io, "        \"app\",\n");
    try file.writeStreamingAll(runtime.io, "        \"api\",\n");
    try file.writeStreamingAll(runtime.io, "        \"public\",\n");
    try file.writeStreamingAll(runtime.io, "        \"tools\",\n");
    try file.writeStreamingAll(runtime.io, "    },\n");
    try file.writeStreamingAll(runtime.io, "}\n");
}

fn cmdInit(alloc: std.mem.Allocator, args: []const []const u8) !void {
    const options = try parseInitOptions(args);
    const name = options.name;

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
    try writeBuildZigZon(dir, alloc, name, options);
    file_count += 1;

    // Patch in the fingerprint: run zig build to get the suggested value.
    print("🔨 Running initial build for fingerprint...\n", .{});
    const build_start_ms = currentMs();
    {
        const cwd_path = if (use_cwd) "." else name;
        const zig_exe = try resolveInPath(alloc, "zig");
        defer alloc.free(zig_exe);
        const result = try runInheritEnv(alloc, .{
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

    // Auto-fetch URL dependencies so the project builds immediately (#61).
    const fetch_start_ms = currentMs();
    if (options.merjs_path == null) {
        print("📦 Fetching merjs dependency...\n", .{});
        const cwd_path = if (use_cwd) "." else name;
        const zig_exe = try resolveInPath(alloc, "zig");
        defer alloc.free(zig_exe);

        // Get the package hash (printed to stdout by zig fetch without --save).
        const hash_result = try runInheritEnv(alloc, .{
            .argv = &.{ zig_exe, "fetch", options.merjs_url },
            .cwd = .{ .path = cwd_path },
        });
        defer alloc.free(hash_result.stdout);
        defer alloc.free(hash_result.stderr);

        if (hash_result.term.exited != 0) {
            print("   ⚠️  Could not fetch merjs dependency (no network?)\n", .{});
            print("      Run manually: zig fetch --save=merjs {s}\n", .{options.merjs_url});
        } else {
            const pkg_hash = std.mem.trimEnd(u8, hash_result.stdout, "\n\r ");

            // Pin the commit URL into build.zig.zon.
            const save_result = try runInheritEnv(alloc, .{
                .argv = &.{ zig_exe, "fetch", "--save=merjs", options.merjs_url },
                .cwd = .{ .path = cwd_path },
            });
            alloc.free(save_result.stderr);

            // Patch .hash into build.zig.zon after the .url line.
            if (pkg_hash.len > 0) {
                const zon_path_str = if (use_cwd) "build.zig.zon" else try std.fmt.allocPrint(alloc, "{s}/build.zig.zon", .{name});
                defer if (!use_cwd) alloc.free(zon_path_str);
                const zon_content = try std.Io.Dir.cwd().readFileAlloc(runtime.io, zon_path_str, alloc, .limited(8192));
                defer alloc.free(zon_content);
                if (std.mem.indexOf(u8, zon_content, ".url = \"")) |url_start| {
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
            \\app/_mercss.css
            \\tools/*
            \\!tools/codegen.zig
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

test "init accepts an explicit pinned merjs dependency URL" {
    const options = try parseInitOptions(&.{ "starter", "--merjs-url", "git+file:///checkout#0123456789abcdef" });
    try std.testing.expectEqualStrings("starter", options.name);
    try std.testing.expectEqualStrings("git+file:///checkout#0123456789abcdef", options.merjs_url);
    const local = try parseInitOptions(&.{ "starter", "--merjs-path", ".." });
    try std.testing.expectEqualStrings("..", local.merjs_path.?);
    try std.testing.expectError(error.MissingMerjsUrl, parseInitOptions(&.{"--merjs-url"}));
    try std.testing.expectError(error.ConflictingMerjsDependency, parseInitOptions(&.{ "--merjs-url", "https://example.com/repo", "--merjs-path", "/checkout" }));
    try std.testing.expectError(error.UnknownInitOption, parseInitOptions(&.{"--revision"}));
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
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "test_artifact.step.dependOn(&run_codegen.step);") != null);
}

test "build_zig_template uses local codegen entrypoint" {
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "b.path(\"tools/codegen.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "codegen_mod.addImport(\"runtime\", merjs_dep.module(\"runtime\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "codegen_mod.addImport(\"mercss_jit\", merjs_dep.module(\"mercss_jit\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "merjs_dep.path(\"tools/codegen.zig\")") == null);
}

test "build_zig_template matches production origin hardening" {
    const source = @embedFile("build.zig");
    inline for (.{
        .{ "fn parseIpv4NumberLiteral", "fn isValidPortLiteral" },
        .{ "fn isIpv4NumberForm", "fn zonHasBridgeArray" },
    }) |range| {
        const start = std.mem.indexOf(u8, source, range[0]) orelse unreachable;
        const end = std.mem.indexOfPos(u8, source, start, range[1]) orelse unreachable;
        var lines = std.mem.splitScalar(u8, source[start..end], '\n');
        while (lines.next()) |line| {
            const code = std.mem.trim(u8, line, " ");
            if (code.len > 0) try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, code) != null);
        }
    }
}

test "native build snippet exposes all CLI-required steps" {
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "b.step(\"native\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "b.step(\"native-dev-build\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "b.step(\"native-build\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "b.step(\"package\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "b.step(\"package-sign\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "b.step(\"package-notarize\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "b.step(\"native-prod-check\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "b.step(\"native-prod-release\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "Contents/Resources") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "static_dir must resolve inside the project") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "static_dir must not contain nested symlinks") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "fn zonServerMode(comptime zon: anytype) []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "std.mem.eql(u8, zonServerMode(zon), \"embedded\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "native_prod_install.step.dependOn(native_prod_check_step)") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "native_build_step.dependOn(&native_prod_install.step)") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "pkg_bin.step.dependOn(&package_clean.step)") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "pkg_plist.step.dependOn(&package_clean.step)") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "pkg_static.step.dependOn(&package_clean.step)") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "release_clean.step.dependOn(native_prod_check_step)") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "release_pkg_bin.step.dependOn(&release_clean.step)") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "release_codesign.step.dependOn(release_package_step)") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "zip.step.dependOn(&release_codesign.step)") != null);
}

test "ZON string field parser ignores commented stale values" {
    const content =
        \\// .display_name = "Old Name",
        \\  .display_name = "New Name",
    ;
    const value = (try zonStringFieldFromContent(std.testing.allocator, content, "display_name")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("New Name", value);
}

test "package mode selection is order independent and monotonic" {
    try std.testing.expectEqual(PackageMode.release, try selectPackageMode(&.{ "--release", "--sign" }));
    try std.testing.expectEqual(PackageMode.release, try selectPackageMode(&.{ "--sign", "--release" }));
    try std.testing.expectEqual(PackageMode.notarize, try selectPackageMode(&.{ "--notarize", "--sign" }));
    try std.testing.expectEqual(PackageMode.notarize, try selectPackageMode(&.{ "--sign", "--notarize" }));
    try std.testing.expectEqual(PackageMode.release, try selectPackageMode(&.{ "-Dmacos-signing-identity=test", "--release" }));
    try std.testing.expectError(error.UnknownPackageOption, selectPackageMode(&.{"--unknown"}));

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try appendPackageBuildArgv(std.testing.allocator, &argv, "/fake/zig", .release, &.{
        "-Dmacos-signing-identity=test",
        "-Dmacos-notarization-profile=profile",
    });
    const expected = [_][]const u8{
        "/fake/zig",
        "build",
        "native-prod-release",
        "-Doptimize=ReleaseSmall",
        "-Dmacos-signing-identity=test",
        "-Dmacos-notarization-profile=profile",
    };
    try std.testing.expectEqual(expected.len, argv.items.len);
    for (expected, argv.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "native build uses the production-gated step and forwards build options" {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try appendNativeBuildArgv(std.testing.allocator, &argv, "/fake/zig", &.{
        "-Dmacos-signing-identity=test",
        "-Dmacos-notarization-profile=profile",
    });
    const expected = [_][]const u8{
        "/fake/zig",
        "build",
        "native-build",
        "-Doptimize=ReleaseSmall",
        "-Dmacos-signing-identity=test",
        "-Dmacos-notarization-profile=profile",
    };
    try std.testing.expectEqual(expected.len, argv.items.len);
    for (expected, argv.items) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectError(error.UnknownNativeBuildOption, appendNativeBuildArgv(std.testing.allocator, &argv, "/fake/zig", &.{"--dev"}));
}

test "native doctor forwards credential build options" {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try appendNativeDoctorArgv(std.testing.allocator, &argv, "/fake/zig", &.{
        "-Dmacos-signing-identity=test",
        "-Dmacos-notarization-profile=profile",
    });
    const expected = [_][]const u8{
        "/fake/zig",
        "build",
        "native-prod-check",
        "-Dmacos-signing-identity=test",
        "-Dmacos-notarization-profile=profile",
    };
    try std.testing.expectEqual(expected.len, argv.items.len);
    for (expected, argv.items) |want, got| try std.testing.expectEqualStrings(want, got);

    var invalid: std.ArrayList([]const u8) = .empty;
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnknownDoctorOption, appendNativeDoctorArgv(std.testing.allocator, &invalid, "/fake/zig", &.{"--release"}));
}

test "CLI child processes inherit configured environment" {
    const alloc = std.testing.allocator;
    try runtime.init(alloc);
    defer runtime.deinit();

    var map = std.process.Environ.Map.init(alloc);
    defer map.deinit();
    try map.put("MERJS_ENV_SENTINEL", "ok");

    if (builtin.os.tag == .windows) {
        const WindowsEnv = struct {
            extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) std.os.windows.BOOL;
        };
        const key_w = comptime std.unicode.wtf8ToWtf16LeStringLiteral("MERJS_ENV_SENTINEL");
        const value_w = comptime std.unicode.wtf8ToWtf16LeStringLiteral("ok");
        const global_env: std.process.Environ = .{ .block = .global };
        const previous_value = std.process.Environ.getAlloc(global_env, alloc, "MERJS_ENV_SENTINEL") catch |err| switch (err) {
            error.EnvironmentVariableMissing => null,
            else => return err,
        };
        defer if (previous_value) |value| alloc.free(value);
        const previous_value_w = if (previous_value) |value| try std.unicode.wtf8ToWtf16LeAllocZ(alloc, value) else null;
        defer if (previous_value_w) |value| alloc.free(value);

        try std.testing.expect(WindowsEnv.SetEnvironmentVariableW(key_w, value_w).toBool());
        defer std.debug.assert(WindowsEnv.SetEnvironmentVariableW(key_w, if (previous_value_w) |value| value.ptr else null).toBool());

        const synthetic_env = global_env;

        const previous = process_environ;
        process_environ = synthetic_env;
        defer process_environ = previous;

        const result = try runInheritEnv(alloc, .{ .argv = &.{ "cmd.exe", "/C", "set MERJS_ENV_SENTINEL" }, .stdout_limit = .limited(64 * 1024) });
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        try std.testing.expect(result.term == .exited);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "MERJS_ENV_SENTINEL=ok") != null);

        const spawn_term = try spawnWaitInheritEnv(alloc, .{
            .argv = &.{ "cmd.exe", "/C", "if \"%MERJS_ENV_SENTINEL%\"==\"ok\" (exit 0) else (exit 1)" },
            .stdout = .ignore,
            .stderr = .ignore,
        });
        try std.testing.expectEqual(@as(u8, 0), spawn_term.exited);
    } else {
        const synthetic_env: std.process.Environ = .{ .block = try map.createPosixBlock(alloc, .{}) };
        defer synthetic_env.block.deinit(alloc);

        const previous = process_environ;
        process_environ = synthetic_env;
        defer process_environ = previous;

        const result = try runInheritEnv(alloc, .{ .argv = &.{"env"}, .stdout_limit = .limited(64 * 1024) });
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        try std.testing.expect(result.term == .exited);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "MERJS_ENV_SENTINEL=ok") != null);

        const spawn_term = try spawnWaitInheritEnv(alloc, .{
            .argv = &.{ "/bin/sh", "-c", "test \"$MERJS_ENV_SENTINEL\" = ok" },
            .stdout = .ignore,
            .stderr = .ignore,
        });
        try std.testing.expectEqual(@as(u8, 0), spawn_term.exited);
    }
}

test "native build snippet uses target OS and codegen dependency" {
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "target.result.os.tag == .macos") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "native_exe.step.dependOn(&run_codegen.step);") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "native_mod.addImport(\"runtime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_build_snippet, "@import(\"builtin\").os.tag") == null);
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
        const result = try runInheritEnv(alloc, .{
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

    _ = try spawnWaitInheritEnv(alloc, .{
        .argv = argv.items,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

// -- native ------------------------------------------------------------------
const starter_mer_app_zon = @embedFile("examples/starter/mer.app.zon");
const starter_native_main = @embedFile("examples/starter/native/main.zig");

const native_build_snippet =
    \\    // ── native shell (mer native / mer package) ─────────────────────
    \\    const native_mod = b.createModule(.{
    \\        .root_source_file = b.path("native/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\    native_mod.addImport("mer", mer_mod);
    \\    native_mod.addImport("runtime", merjs_dep.module("runtime"));
    \\    const manifest_mod = b.createModule(.{ .root_source_file = b.path("mer.app.zon") });
    \\    native_mod.addImport("manifest", manifest_mod);
    \\    addRoutesModule(b, native_mod, mer_mod);
    \\    if (target.result.os.tag == .macos) {
    \\        native_mod.linkFramework("AppKit", .{});
    \\        native_mod.linkFramework("WebKit", .{});
    \\        native_mod.linkFramework("Foundation", .{});
    \\        native_mod.link_libc = true;
    \\        const native_exe = b.addExecutable(.{ .name = "mernative", .root_module = native_mod });
    \\        native_exe.step.dependOn(&run_codegen.step);
    \\        const native_install = b.addInstallArtifact(native_exe, .{});
    \\        const run_native = b.addRunArtifact(native_exe);
    \\        run_native.step.dependOn(&native_install.step);
    \\        if (b.args) |args| run_native.addArgs(args);
    \\        b.step("native", "Run native shell (dev)").dependOn(&run_native.step);
    \\        b.step("native-dev-build", "Build native shell binary without production checks").dependOn(&native_install.step);
    \\        const native_build_step = b.step("native-build", "Build production-gated native shell binary");
    \\
    \\        const app_zon = @import("mer.app.zon");
    \\        const NativePackage = struct {
    \\            fn plistEscape(alloc: std.mem.Allocator, input: []const u8) []const u8 {
    \\                if (!std.unicode.utf8ValidateSlice(input)) @panic("mer.app.zon Info.plist metadata must be valid UTF-8");
    \\                var out: std.ArrayList(u8) = .empty;
    \\                errdefer out.deinit(alloc);
    \\                for (input) |c| switch (c) {
    \\                    '&' => out.appendSlice(alloc, "&amp;") catch @panic("escape Info.plist"),
    \\                    '<' => out.appendSlice(alloc, "&lt;") catch @panic("escape Info.plist"),
    \\                    '>' => out.appendSlice(alloc, "&gt;") catch @panic("escape Info.plist"),
    \\                    '"' => out.appendSlice(alloc, "&quot;") catch @panic("escape Info.plist"),
    \\                    '\'' => out.appendSlice(alloc, "&apos;") catch @panic("escape Info.plist"),
    \\                    0...8, 11, 12, 14...31 => @panic("mer.app.zon contains an XML-invalid control character"),
    \\                    else => out.append(alloc, c) catch @panic("escape Info.plist"),
    \\                };
    \\                return out.toOwnedSlice(alloc) catch @panic("escape Info.plist");
    \\            }
    \\            fn safeBundleComponent(alloc: std.mem.Allocator, input: []const u8) []const u8 {
    \\                var out: std.ArrayList(u8) = .empty;
    \\                errdefer out.deinit(alloc);
    \\                for (input) |c| out.append(alloc, switch (c) {
    \\                    '/', '\\', ':', 0...31 => '-',
    \\                    else => c,
    \\                }) catch @panic("sanitize app bundle name");
    \\                const trimmed = std.mem.trim(u8, out.items, " .\t\r\n");
    \\                if (trimmed.len == 0) {
    \\                    out.clearRetainingCapacity();
    \\                    out.appendSlice(alloc, "MerNative") catch @panic("sanitize app bundle name");
    \\                    return out.toOwnedSlice(alloc) catch @panic("sanitize app bundle name");
    \\                }
    \\                if (trimmed.ptr != out.items.ptr or trimmed.len != out.items.len) {
    \\                    const owned = alloc.dupe(u8, trimmed) catch @panic("sanitize app bundle name");
    \\                    out.deinit(alloc);
    \\                    return owned;
    \\                }
    \\                return out.toOwnedSlice(alloc) catch @panic("sanitize app bundle name");
    \\            }
    \\            fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    \\                const v = value orelse return null;
    \\                return if (v.len == 0) null else v;
    \\            }
    \\            fn firstNonEmpty(a: ?[]const u8, b_: ?[]const u8) ?[]const u8 {
    \\                return nonEmpty(a) orelse nonEmpty(b_);
    \\            }
    \\            fn zonMacosString(comptime zon: anytype, comptime field: []const u8) ?[]const u8 {
    \\                const T = @TypeOf(zon);
    \\                if (!@hasField(T, "macos")) return null;
    \\                const MacT = @TypeOf(zon.macos);
    \\                if (!@hasField(MacT, field)) return null;
    \\                return @field(zon.macos, field);
    \\            }
    \\            fn zonUpdateString(comptime zon: anytype, comptime field: []const u8) ?[]const u8 {
    \\                const T = @TypeOf(zon);
    \\                if (!@hasField(T, "update")) return null;
    \\                const UpdateT = @TypeOf(zon.update);
    \\                if (!@hasField(UpdateT, field)) return null;
    \\                return @field(zon.update, field);
    \\            }
    \\            fn zonServerMode(comptime zon: anytype) []const u8 {
    \\                const T = @TypeOf(zon);
    \\                if (!@hasField(T, "server")) return "";
    \\                const ServerT = @TypeOf(zon.server);
    \\                if (!@hasField(ServerT, "mode")) return "";
    \\                return zon.server.mode;
    \\            }
    \\            fn zonServerHost(comptime zon: anytype) []const u8 {
    \\                const T = @TypeOf(zon);
    \\                if (!@hasField(T, "server")) return "127.0.0.1";
    \\                const ServerT = @TypeOf(zon.server);
    \\                if (!@hasField(ServerT, "host")) return "127.0.0.1";
    \\                return zon.server.host;
    \\            }
    \\            fn isSafeRelativePathLiteral(comptime path: []const u8) bool {
    \\                if (path.len == 0 or path[0] == '/' or path[0] == '~') return false;
    \\                var start: usize = 0;
    \\                for (path, 0..) |c, i| {
    \\                    if (c == ':' or c == '\\' or c <= 0x1f or c == 0x7f) return false;
    \\                    if (c == '/') {
    \\                        const part = path[start..i];
    \\                        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    \\                        start = i + 1;
    \\                    }
    \\                }
    \\                const last = path[start..];
    \\                return last.len > 0 and !std.mem.eql(u8, last, ".") and !std.mem.eql(u8, last, "..");
    \\            }
    \\            fn zonServerStaticDir(comptime zon: anytype) []const u8 {
    \\                const T = @TypeOf(zon);
    \\                const value = if (!@hasField(T, "server")) "public" else blk: {
    \\                    const ServerT = @TypeOf(zon.server);
    \\                    if (!@hasField(ServerT, "static_dir")) break :blk "public";
    \\                    break :blk zon.server.static_dir;
    \\                };
    \\                if (!isSafeRelativePathLiteral(value)) @compileError("mer.app.zon server.static_dir must be a safe relative path inside the app bundle");
    \\                return value;
    \\            }
    \\            fn parseIpv4NumberLiteral(comptime part: []const u8) ?u32 {
    \\                if (part.len == 0) return null;
    \\
    \\                const base: u32 = if (part.len > 2 and part[0] == '0' and (part[1] == 'x' or part[1] == 'X')) 16 else if (part.len > 1 and part[0] == '0') 8 else 10;
    \\                const start: usize = if (base == 16) 2 else 0;
    \\                if (start == part.len) return null;
    \\
    \\                var value: u32 = 0;
    \\                for (part[start..]) |c| {
    \\                    const digit: u32 = switch (c) {
    \\                        '0'...'9' => c - '0',
    \\                        'a'...'f' => c - 'a' + 10,
    \\                        'A'...'F' => c - 'A' + 10,
    \\                        else => return null,
    \\                    };
    \\                    if (digit >= base or value > (std.math.maxInt(u32) - digit) / base) return null;
    \\                    value = value * base + digit;
    \\                }
    \\                return value;
    \\            }
    \\
    \\            fn isIpv4LoopbackLiteral(comptime host: []const u8) bool {
    \\                var parts: [4]u32 = undefined;
    \\                var count: usize = 0;
    \\                var it = std.mem.splitScalar(u8, host, '.');
    \\                while (it.next()) |part| {
    \\                    if (count == parts.len) return false;
    \\                    parts[count] = parseIpv4NumberLiteral(part) orelse return false;
    \\                    count += 1;
    \\                }
    \\
    \\                const address: u32 = switch (count) {
    \\                    1 => parts[0],
    \\                    2 => if (parts[0] <= 0xff and parts[1] <= 0x00ffffff) (parts[0] << 24) | parts[1] else return false,
    \\                    3 => if (parts[0] <= 0xff and parts[1] <= 0xff and parts[2] <= 0xffff) (parts[0] << 24) | (parts[1] << 16) | parts[2] else return false,
    \\                    4 => if (parts[0] <= 0xff and parts[1] <= 0xff and parts[2] <= 0xff and parts[3] <= 0xff) (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3] else return false,
    \\                    else => return false,
    \\                };
    \\                return address >> 24 == 127;
    \\            }
    \\
    \\            fn isCanonicalIpv4Literal(comptime host: []const u8) bool {
    \\                var it = std.mem.splitScalar(u8, host, '.');
    \\                var count: usize = 0;
    \\                while (it.next()) |part| {
    \\                    if (count == 4 or part.len == 0 or (part.len > 1 and part[0] == '0')) return false;
    \\                    var value: u16 = 0;
    \\                    for (part) |c| {
    \\                        if (!std.ascii.isDigit(c)) return false;
    \\                        value = value * 10 + c - '0';
    \\                        if (value > 255) return false;
    \\                    }
    \\                    count += 1;
    \\                }
    \\                return count == 4;
    \\            }
    \\
    \\            fn isIpv6LoopbackLiteral(comptime host: []const u8) bool {
    \\                const address = std.Io.net.Ip6Address.parse(host, 0) catch return false;
    \\                if (std.mem.eql(u8, &address.bytes, &std.Io.net.Ip6Address.loopback(0).bytes)) return true;
    \\
    \\                const compatible = std.mem.allEqual(u8, address.bytes[0..12], 0);
    \\                const mapped = std.mem.allEqual(u8, address.bytes[0..10], 0) and address.bytes[10] == 0xff and address.bytes[11] == 0xff;
    \\                return (compatible or mapped) and address.bytes[12] == 127;
    \\            }
    \\
    \\            fn isLoopbackHostLiteral(comptime host: []const u8) bool {
    \\                return isCanonicalIpv4Literal(host) and host[0] == '1' and host[1] == '2' and host[2] == '7' and host[3] == '.' or
    \\                    std.mem.eql(u8, host, "::1") or
    \\                    std.mem.eql(u8, host, "[::1]");
    \\            }
    \\
    \\            fn isValidPortLiteral(comptime port: []const u8) bool {
    \\                if (port.len == 0 or port.len > 5) return false;
    \\                for (port) |c| if (!std.ascii.isDigit(c)) return false;
    \\                const value = std.fmt.parseInt(u16, port, 10) catch return false;
    \\                return value > 0;
    \\            }
    \\            fn isStrictHttpsUrlLiteral(comptime url: []const u8) bool {
    \\                if (url.len == 0) return false;
    \\                for (url) |c| if (c <= 0x20 or c == 0x7f or c == '\\') return false;
    \\                const scheme_end = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    \\                if (!std.ascii.eqlIgnoreCase(url[0..scheme_end], "https")) return false;
    \\                if (url.len < scheme_end + 3 or !std.mem.eql(u8, url[scheme_end + 1 .. scheme_end + 3], "//")) return false;
    \\                const authority_start = scheme_end + 3;
    \\                const authority_end = blk: {
    \\                    var i: usize = authority_start;
    \\                    while (i < url.len) : (i += 1) switch (url[i]) { '/', '?', '#' => break :blk i, else => {} };
    \\                    break :blk url.len;
    \\                };
    \\                const authority = url[authority_start..authority_end];
    \\                if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return false;
    \\                if (authority[0] == '[') {
    \\                    const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
    \\                    if (close == 1) return false;
    \\                    const rest = authority[close + 1 ..];
    \\                    return rest.len == 0 or (rest[0] == ':' and isValidPortLiteral(rest[1..]));
    \\                }
    \\                const colon = std.mem.indexOfScalar(u8, authority, ':');
    \\                const host = if (colon) |c| authority[0..c] else authority;
    \\                if (host.len == 0) return false;
    \\                if (std.mem.indexOfScalar(u8, host, '.') == null and !std.ascii.eqlIgnoreCase(host, "localhost")) return false;
    \\                if (colon) |c| if (!isValidPortLiteral(authority[c + 1 ..])) return false;
    \\                return true;
    \\            }
    \\            fn isEd25519TokenLiteral(comptime value: []const u8) bool {
    \\                const prefix = "ed25519:";
    \\                if (!std.mem.startsWith(u8, value, prefix) or value.len == prefix.len) return false;
    \\                const encoded = value[prefix.len..];
    \\                for (encoded) |c| if (c <= 0x20 or c == 0x7f or c == '\\') return false;
    \\                const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return false;
    \\                if (decoded_len != 32) return false;
    \\                var decoded: [32]u8 = undefined;
    \\                _ = std.base64.standard.Decoder.decode(&decoded, encoded) catch return false;
    \\                _ = std.crypto.sign.Ed25519.PublicKey.fromBytes(decoded) catch return false;
    \\                return true;
    \\            }
    \\            fn zonUpdateProviderValid(comptime zon: anytype) bool {
    \\                const provider = nonEmpty(zonUpdateString(zon, "provider")) orelse return false;
    \\                return std.mem.eql(u8, provider, "github-releases") or std.mem.eql(u8, provider, "custom-http");
    \\            }
    \\            fn zonUpdateFeedUrlValid(comptime zon: anytype) bool {
    \\                const feed_url = nonEmpty(zonUpdateString(zon, "feed_url")) orelse return false;
    \\                return isStrictHttpsUrlLiteral(feed_url);
    \\            }
    \\            fn zonUpdatePublicKeyValid(comptime zon: anytype) bool {
    \\                const public_key = nonEmpty(zonUpdateString(zon, "public_key")) orelse return false;
    \\                return isEd25519TokenLiteral(public_key);
    \\            }
    \\            fn zonHasNavigationOrigins(comptime zon: anytype) bool {
    \\                const T = @TypeOf(zon);
    \\                if (!@hasField(T, "security")) return false;
    \\                const SecurityT = @TypeOf(zon.security);
    \\                if (!@hasField(SecurityT, "navigation")) return false;
    \\                const NavigationT = @TypeOf(zon.security.navigation);
    \\                if (!@hasField(NavigationT, "allowed_origins")) return false;
    \\                return zon.security.navigation.allowed_origins.len > 0;
    \\            }
    \\
    \\            fn originHost(comptime origin: []const u8) ?[]const u8 {
    \\                const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return null;
    \\                const authority_start = scheme_end + 3;
    \\                const authority_end = blk: {
    \\                    var i: usize = authority_start;
    \\                    while (i < origin.len) : (i += 1) {
    \\                        switch (origin[i]) {
    \\                            '/', '?', '#' => break :blk i,
    \\                            else => {},
    \\                        }
    \\                    }
    \\                    break :blk origin.len;
    \\                };
    \\                var authority = origin[authority_start..authority_end];
    \\                if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    \\                if (authority.len == 0) return null;
    \\                if (authority[0] == '[') {
    \\                    const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
    \\                    return authority[0 .. close + 1];
    \\                }
    \\                const colon = std.mem.indexOfScalar(u8, authority, ':');
    \\                return if (colon) |c| authority[0..c] else authority;
    \\            }
    \\
    \\            fn isIpv4NumberForm(comptime host: []const u8) bool {
    \\                var it = std.mem.splitScalar(u8, host, '.');
    \\                var count: usize = 0;
    \\                while (it.next()) |part| {
    \\                    if (count == 4 or parseIpv4NumberLiteral(part) == null) return false;
    \\                    count += 1;
    \\                }
    \\                return count > 0;
    \\            }
    \\n    \\            fn isCanonicalDnsHost(comptime host: []const u8) bool {
    \\                var it = std.mem.splitScalar(u8, host, '.');
    \\                while (it.next()) |label| {
    \\                    if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
    \\                    for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    \\                }
    \\                return host.len <= 253;
    \\            }
    \\n    \\            fn isCanonicalOriginHost(comptime host: []const u8) bool {
    \\                if (isCanonicalIpv4Literal(host)) return true;
    \\                if (isIpv4NumberForm(host)) return false;
    \\                if (host.len >= 4 and host[0] == '[' and host[host.len - 1] == ']') {
    \\                    _ = std.Io.net.Ip6Address.parse(host[1 .. host.len - 1], 0) catch return false;
    \\                    return true;
    \\                }
    \\                return isCanonicalDnsHost(host);
    \\            }
    \\n    \\            fn isForbiddenProductionLoopbackHost(comptime host: []const u8) bool {
    \\                const normalized = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
    \\                return std.ascii.eqlIgnoreCase(host, "localhost") or
    \\                    isIpv4LoopbackLiteral(host) or
    \\                    isIpv6LoopbackLiteral(normalized);
    \\            }
    \\n    \\            fn zonNavigationHasForbiddenLoopback(comptime zon: anytype) bool {
    \\                if (!zonHasNavigationOrigins(zon)) return false;
    \\                for (zon.security.navigation.allowed_origins) |origin| {
    \\                    const host = originHost(origin) orelse return true;
    \\                    if (!isCanonicalOriginHost(host) or isForbiddenProductionLoopbackHost(host)) return true;
    \\                }
    \\                return false;
    \\            }
    \\n    \\            fn zonHasBridgeArray(comptime zon: anytype, comptime field: []const u8) bool {
    \\                const T = @TypeOf(zon);
    \\                if (!@hasField(T, "security")) return false;
    \\                const SecurityT = @TypeOf(zon.security);
    \\                if (!@hasField(SecurityT, "bridge")) return false;
    \\                const BridgeT = @TypeOf(zon.security.bridge);
    \\                if (!@hasField(BridgeT, field)) return false;
    \\                return @field(zon.security.bridge, field).len > 0;
    \\            }
    \\            fn zonHasOpenArray(comptime zon: anytype, comptime field: []const u8) bool {
    \\                const T = @TypeOf(zon);
    \\                if (!@hasField(T, "security")) return false;
    \\                const SecurityT = @TypeOf(zon.security);
    \\                if (!@hasField(SecurityT, "open")) return false;
    \\                const OpenT = @TypeOf(zon.security.open);
    \\                if (!@hasField(OpenT, field)) return false;
    \\                return @field(zon.security.open, field).len > 0;
    \\            }
    \\            fn macProdCheckMessage(comptime zon: anytype) []const u8 {
    \\                comptime var msg: []const u8 = "";
    \\                if (!std.mem.eql(u8, zonServerMode(zon), "embedded")) msg = msg ++ "native production server.mode must be embedded\\n";
    \\                if (!isLoopbackHostLiteral(zonServerHost(zon))) msg = msg ++ "native production server.host must be loopback (use 127.0.0.1)\\n";
    \\                if (zonNavigationHasForbiddenLoopback(zon)) msg = msg ++ "production extra navigation origins must not include loopback/localhost; rely on the exact runtime origin injected by the shell\\n";
    \\                if (!zonHasBridgeArray(zon, "allowed_commands")) msg = msg ++ "missing non-empty .security.bridge.allowed_commands\\n";
    \\                if (!zonHasBridgeArray(zon, "command_origins")) msg = msg ++ "missing non-empty .security.bridge.command_origins\\n";
    \\                if (!zonHasOpenArray(zon, "external_schemes")) msg = msg ++ "missing non-empty .security.open.external_schemes\\n";
    \\                if (!zonHasOpenArray(zon, "path_roots")) msg = msg ++ "missing non-empty .security.open.path_roots\\n";
    \\                if (nonEmpty(zonUpdateString(zon, "provider")) == null) msg = msg ++ "missing .update.provider\\n" else if (!zonUpdateProviderValid(zon)) msg = msg ++ "invalid .update.provider (expected github-releases or custom-http)\\n";
    \\                if (nonEmpty(zonUpdateString(zon, "feed_url")) == null) msg = msg ++ "missing .update.feed_url\\n" else if (!zonUpdateFeedUrlValid(zon)) msg = msg ++ "invalid .update.feed_url (expected strict https URL)\\n";
    \\                if (nonEmpty(zonUpdateString(zon, "public_key")) == null) msg = msg ++ "missing .update.public_key\\n" else if (!zonUpdatePublicKeyValid(zon)) msg = msg ++ "invalid .update.public_key (expected ed25519:<base64 raw 32-byte public key>)\\n";
    \\                return msg;
    \\            }
    \\        };
    \\        const pkg_component = NativePackage.safeBundleComponent(b.allocator, app_zon.display_name);
    \\        const pkg_name = b.fmt("{s}.app", .{pkg_component});
    \\        const bundle_id_xml = NativePackage.plistEscape(b.allocator, app_zon.id);
    \\        const display_name_xml = NativePackage.plistEscape(b.allocator, app_zon.display_name);
    \\        const version_xml = NativePackage.plistEscape(b.allocator, app_zon.version);
    \\        const plist_xml = b.fmt(
    \\            \\<?xml version="1.0" encoding="UTF-8"?>
    \\            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\            \\<plist version="1.0"><dict>
    \\            \\  <key>CFBundleExecutable</key><string>mernative</string>
    \\            \\  <key>CFBundleIdentifier</key><string>{s}</string>
    \\            \\  <key>CFBundleName</key><string>{s}</string>
    \\            \\  <key>CFBundleVersion</key><string>{s}</string>
    \\            \\  <key>NSHighResolutionCapable</key><true/>
    \\            \\  <key>NSPrincipalClass</key><string>NSApplication</string>
    \\            \\</dict></plist>
    \\        , .{ bundle_id_xml, display_name_xml, version_xml });
    \\        const plist = b.addWriteFile(b.fmt("{s}/Contents/Info.plist", .{pkg_name}), plist_xml);
    \\        const app_path = b.getInstallPath(.prefix, pkg_name);
    \\        // Always empty the destination bundle before copying package contents.
    \\        const package_clean = b.addSystemCommand(&.{ "rm", "-rf", app_path });
    \\        const pkg_bin = b.addInstallFile(native_exe.getEmittedBin(), b.fmt("{s}/Contents/MacOS/mernative", .{pkg_name}));
    \\        pkg_bin.step.dependOn(&native_install.step);
    \\        pkg_bin.step.dependOn(&package_clean.step);
    \\        const pkg_plist = b.addInstallDirectory(.{
    \\            .source_dir = plist.getDirectory(),
    \\            .install_dir = .prefix,
    \\            .install_subdir = "",
    \\        });
    \\        pkg_plist.step.dependOn(&package_clean.step);
    \\        const static_assets_dir = comptime NativePackage.zonServerStaticDir(app_zon);
    \\        const pkg_static = b.addInstallDirectory(.{
    \\            .source_dir = b.path(static_assets_dir),
    \\            .install_dir = .prefix,
    \\            .install_subdir = b.fmt("{s}/Contents/Resources/{s}", .{ pkg_name, static_assets_dir }),
    \\        });
    \\        const project_root_path = b.path(".").getPath(b);
    \\        const static_assets_path = b.path(static_assets_dir).getPath(b);
    \\        const check_static_links = b.addSystemCommand(&.{ "sh", "-c", "root=$(cd \"$1\" && pwd -P) || exit 1; assets=$(cd \"$2\" && pwd -P) || exit 1; case \"$assets\" in \"$root\"|\"$root\"/*) ;; *) echo 'mer native: static_dir must resolve inside the project' >&2; exit 1;; esac; if find \"$2\"/ -type l -print -quit | grep -q .; then echo 'mer native: static_dir must not contain nested symlinks' >&2; exit 1; fi", "sh", project_root_path, static_assets_path });
    \\        pkg_static.step.dependOn(&check_static_links.step);
    \\        pkg_static.step.dependOn(&package_clean.step);
    \\        const package_step = b.step("package", "Package native app as a .app bundle");
    \\        package_step.dependOn(&pkg_bin.step);
    \\        package_step.dependOn(&pkg_plist.step);
    \\        package_step.dependOn(&pkg_static.step);
    \\
    \\        const signing_identity = NativePackage.firstNonEmpty(
    \\            b.option([]const u8, "macos-signing-identity", "macOS codesign identity for package-sign"),
    \\            NativePackage.zonMacosString(app_zon, "signing_identity"),
    \\        );
    \\        const entitlements = NativePackage.firstNonEmpty(
    \\            b.option([]const u8, "macos-entitlements", "macOS entitlements plist for package-sign"),
    \\            NativePackage.zonMacosString(app_zon, "entitlements"),
    \\        );
    \\        const notarization_profile = NativePackage.firstNonEmpty(
    \\            b.option([]const u8, "macos-notarization-profile", "xcrun notarytool keychain profile for package-notarize"),
    \\            NativePackage.zonMacosString(app_zon, "notarization_profile"),
    \\        );
    \\        const prod_check_message = comptime NativePackage.macProdCheckMessage(app_zon);
    \\        const native_prod_check_step = b.step("native-prod-check", "Validate macOS native production-release manifest hardening");
    \\        const native_prod_install = b.addInstallArtifact(native_exe, .{});
    \\        native_prod_install.step.dependOn(native_prod_check_step);
    \\        native_build_step.dependOn(&native_prod_install.step);
    \\        if (prod_check_message.len == 0 and signing_identity != null and notarization_profile != null) {
    \\            const ok = b.addSystemCommand(&.{ "sh", "-c", "echo 'mer native: macOS production manifest checks passed'" });
    \\            native_prod_check_step.dependOn(&ok.step);
    \\        } else {
    \\            var message: []const u8 = prod_check_message;
    \\            if (signing_identity == null) message = b.fmt("{s}missing macOS signing identity (-Dmacos-signing-identity or .macos.signing_identity)\\n", .{message});
    \\            if (notarization_profile == null) message = b.fmt("{s}missing macOS notarization profile (-Dmacos-notarization-profile or .macos.notarization_profile)\\n", .{message});
    \\            const fail = b.addSystemCommand(&.{ "sh", "-c", b.fmt("printf 'mer native: macOS production manifest is incomplete:\\n{s}' >&2; exit 1", .{message}) });
    \\            native_prod_check_step.dependOn(&fail.step);
    \\        }
    \\
    \\        const release_clean = b.addSystemCommand(&.{ "rm", "-rf", app_path });
    \\        release_clean.step.dependOn(native_prod_check_step);
    \\        const release_pkg_bin = b.addInstallFile(native_exe.getEmittedBin(), b.fmt("{s}/Contents/MacOS/mernative", .{pkg_name}));
    \\        release_pkg_bin.step.dependOn(&release_clean.step);
    \\        const release_pkg_plist = b.addInstallDirectory(.{ .source_dir = plist.getDirectory(), .install_dir = .prefix, .install_subdir = "" });
    \\        release_pkg_plist.step.dependOn(&release_clean.step);
    \\        const release_pkg_static = b.addInstallDirectory(.{
    \\            .source_dir = b.path(static_assets_dir),
    \\            .install_dir = .prefix,
    \\            .install_subdir = b.fmt("{s}/Contents/Resources/{s}", .{ pkg_name, static_assets_dir }),
    \\        });
    \\        release_pkg_static.step.dependOn(&release_clean.step);
    \\        release_pkg_static.step.dependOn(&check_static_links.step);
    \\        const release_package_step = b.step("package-release-gated", "Package native app after production checks");
    \\        release_package_step.dependOn(&release_pkg_bin.step);
    \\        release_package_step.dependOn(&release_pkg_plist.step);
    \\        release_package_step.dependOn(&release_pkg_static.step);
    \\
    \\        const package_sign_step = b.step("package-sign", "Package and codesign native app");
    \\        if (signing_identity) |identity| {
    \\            const codesign = b.addSystemCommand(&.{ "codesign", "--deep", "--force", "--options", "runtime", "--timestamp", "--sign", identity });
    \\            if (entitlements) |path| codesign.addArgs(&.{ "--entitlements", path });
    \\            codesign.addArg(app_path);
    \\            codesign.step.dependOn(package_step);
    \\            package_sign_step.dependOn(&codesign.step);
    \\        } else {
    \\            const fail = b.addSystemCommand(&.{ "sh", "-c", "echo 'mer native: package-sign needs -Dmacos-signing-identity or .macos.signing_identity in mer.app.zon' >&2; exit 1" });
    \\            fail.step.dependOn(package_step);
    \\            package_sign_step.dependOn(&fail.step);
    \\        }
    \\
    \\        const package_notarize_step = b.step("package-notarize", "Codesign, notarize, and staple native app");
    \\        if (signing_identity != null and notarization_profile != null) {
    \\            const release_codesign = b.addSystemCommand(&.{ "codesign", "--deep", "--force", "--options", "runtime", "--timestamp", "--sign", signing_identity.? });
    \\            if (entitlements) |path| release_codesign.addArgs(&.{ "--entitlements", path });
    \\            release_codesign.addArg(app_path);
    \\            release_codesign.step.dependOn(release_package_step);
    \\            const zip_path = b.getInstallPath(.prefix, b.fmt("{s}.zip", .{pkg_name}));
    \\            const zip = b.addSystemCommand(&.{ "ditto", "-c", "-k", "--keepParent", app_path, zip_path });
    \\            zip.step.dependOn(&release_codesign.step);
    \\            const submit = b.addSystemCommand(&.{ "xcrun", "notarytool", "submit", zip_path, "--keychain-profile", notarization_profile.?, "--wait" });
    \\            submit.step.dependOn(&zip.step);
    \\            const staple = b.addSystemCommand(&.{ "xcrun", "stapler", "staple", app_path });
    \\            staple.step.dependOn(&submit.step);
    \\            package_notarize_step.dependOn(&staple.step);
    \\        } else {
    \\            const fail = b.addSystemCommand(&.{ "sh", "-c", "exit 1" });
    \\            fail.step.dependOn(native_prod_check_step);
    \\            package_notarize_step.dependOn(&fail.step);
    \\        }
    \\        const native_prod_release_step = b.step("native-prod-release", "Validate, sign, notarize, and staple macOS native app");
    \\        native_prod_release_step.dependOn(package_notarize_step);
    \\    }
;

fn zonStringFieldFromContent(alloc: std.mem.Allocator, content: []const u8, field: []const u8) !?[]u8 {
    const needle = try std.fmt.allocPrint(alloc, ".{s}", .{field});
    defer alloc.free(needle);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, needle)) continue;
        const after_field = std.mem.trim(u8, trimmed[needle.len..], " \t\r");
        if (after_field.len == 0 or after_field[0] != '=') continue;
        const after_eq = std.mem.trim(u8, after_field[1..], " \t\r");
        if (after_eq.len == 0 or after_eq[0] != '"') return null;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        var i: usize = 1;
        while (i < after_eq.len) : (i += 1) {
            const c = after_eq[i];
            if (c == '"') return try out.toOwnedSlice(alloc);
            if (c != '\\') {
                try out.append(alloc, c);
                continue;
            }

            i += 1;
            if (i >= after_eq.len) return null;
            try out.append(alloc, switch (after_eq[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '"' => '"',
                '\'' => '\'',
                else => after_eq[i],
            });
        }
        return null;
    }
    return null;
}

fn readZonStringField(alloc: std.mem.Allocator, field: []const u8) !?[]u8 {
    const content = std.Io.Dir.cwd().readFileAlloc(runtime.io, "mer.app.zon", alloc, .limited(64 * 1024)) catch return null;
    defer alloc.free(content);
    return zonStringFieldFromContent(alloc, content, field);
}

fn safeBundleComponent(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    for (input) |c| {
        try out.append(alloc, switch (c) {
            '/', '\\', ':', 0...31 => '-',
            else => c,
        });
    }

    const trimmed = std.mem.trim(u8, out.items, " .\t\r\n");
    if (trimmed.len == 0) {
        out.clearRetainingCapacity();
        try out.appendSlice(alloc, "MerNative");
        return out.toOwnedSlice(alloc);
    }

    if (trimmed.ptr != out.items.ptr or trimmed.len != out.items.len) {
        const owned = try alloc.dupe(u8, trimmed);
        out.deinit(alloc);
        return owned;
    }

    return out.toOwnedSlice(alloc);
}

fn cmdNative(alloc: std.mem.Allocator, extra_args: []const []const u8) !void {
    if (builtin.os.tag != .macos) {
        print("mer: native currently supports macOS only; Linux WebKitGTK and Windows WebView2 backends are planned\n", .{});
        std.process.exit(1);
    }
    std.Io.Dir.cwd().access(runtime.io, "build.zig", .{}) catch {
        print("mer: no build.zig found — are you in a merjs project?\n", .{});
        std.process.exit(1);
    };
    std.Io.Dir.cwd().access(runtime.io, "mer.app.zon", .{}) catch {
        print("mer: no mer.app.zon found — run `mer add native` first.\n", .{});
        std.process.exit(1);
    };

    const zig_exe = try resolveInPath(alloc, "zig");
    defer alloc.free(zig_exe);

    print("mer: running codegen...\n", .{});
    {
        const result = try runInheritEnv(alloc, .{
            .argv = &.{ zig_exe, "build", "codegen" },
        });
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        const exited = result.term == .exited;
        if (!exited or result.term.exited != 0) {
            print("mer: codegen failed:\n{s}", .{result.stderr});
            std.process.exit(1);
        }
    }

    print("mer: launching native window (dev)...\n", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ zig_exe, "build", "native", "--", "--dev" });
    for (extra_args) |arg| try argv.append(alloc, arg);

    const term = try spawnWaitInheritEnv(alloc, .{
        .argv = argv.items,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const exited = term == .exited;
    if (!exited or term.exited != 0) {
        print("mer: native run failed\n", .{});
        std.process.exit(1);
    }
}

fn appendNativeBuildArgv(
    alloc: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    zig_exe: []const u8,
    extra_args: []const []const u8,
) error{ UnknownNativeBuildOption, OutOfMemory }!void {
    try argv.appendSlice(alloc, &.{ zig_exe, "build", "native-build", "-Doptimize=ReleaseSmall" });
    for (extra_args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-D")) return error.UnknownNativeBuildOption;
        try argv.append(alloc, arg);
    }
}

fn cmdNativeBuild(alloc: std.mem.Allocator, extra_args: []const []const u8) !void {
    std.Io.Dir.cwd().access(runtime.io, "build.zig", .{}) catch {
        print("mer: no build.zig found — are you in a merjs project?\n", .{});
        std.process.exit(1);
    };
    if (builtin.os.tag != .macos) {
        print("mer: native build currently supports macOS only; Linux WebKitGTK and Windows WebView2 backends are planned\n", .{});
        std.process.exit(1);
    }
    const zig_exe = try resolveInPath(alloc, "zig");
    defer alloc.free(zig_exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    appendNativeBuildArgv(alloc, &argv, zig_exe, extra_args) catch |err| switch (err) {
        error.UnknownNativeBuildOption => {
            print("mer: native build accepts only -D build options\n", .{});
            std.process.exit(1);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    print("mer: building production-gated native shell...\n", .{});
    const term = try spawnWaitInheritEnv(alloc, .{
        .argv = argv.items,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const exited = term == .exited;
    if (!exited or term.exited != 0) {
        print("mer: native build failed\n", .{});
        std.process.exit(1);
    }
    print("mer: native binary built → zig-out/bin/mernative\n", .{});
}

fn appendNativeDoctorArgv(
    alloc: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    zig_exe: []const u8,
    extra_args: []const []const u8,
) error{ UnknownDoctorOption, OutOfMemory }!void {
    try argv.appendSlice(alloc, &.{ zig_exe, "build", "native-prod-check" });
    for (extra_args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-D")) return error.UnknownDoctorOption;
        try argv.append(alloc, arg);
    }
}

fn cmdNativeDoctor(alloc: std.mem.Allocator, extra_args: []const []const u8) !void {
    std.Io.Dir.cwd().access(runtime.io, "build.zig", .{}) catch {
        print("mer: no build.zig found — are you in a merjs project?\n", .{});
        std.process.exit(1);
    };
    if (builtin.os.tag != .macos) {
        print("mer: native doctor currently checks macOS production readiness only\n", .{});
        std.process.exit(1);
    }
    const zig_exe = try resolveInPath(alloc, "zig");
    defer alloc.free(zig_exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    appendNativeDoctorArgv(alloc, &argv, zig_exe, extra_args) catch |err| switch (err) {
        error.UnknownDoctorOption => {
            print("mer: native doctor accepts only -D build options\n", .{});
            std.process.exit(1);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    print("mer: checking macOS native production manifest...\n", .{});
    const term = try spawnWaitInheritEnv(alloc, .{
        .argv = argv.items,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const exited = term == .exited;
    if (!exited or term.exited != 0) {
        print("mer: native production check failed\n", .{});
        std.process.exit(1);
    }
}

const PackageMode = enum {
    package,
    sign,
    notarize,
    release,

    fn buildStep(self: PackageMode) []const u8 {
        return switch (self) {
            .package => "package",
            .sign => "package-sign",
            .notarize => "package-notarize",
            .release => "native-prod-release",
        };
    }
};

fn selectPackageMode(args: []const []const u8) error{UnknownPackageOption}!PackageMode {
    var selected: PackageMode = .package;
    for (args) |arg| {
        const candidate: PackageMode = if (std.mem.eql(u8, arg, "--sign"))
            .sign
        else if (std.mem.eql(u8, arg, "--notarize"))
            .notarize
        else if (std.mem.eql(u8, arg, "--release"))
            .release
        else if (std.mem.startsWith(u8, arg, "-D"))
            continue
        else
            return error.UnknownPackageOption;
        if (@intFromEnum(candidate) > @intFromEnum(selected)) selected = candidate;
    }
    return selected;
}

fn appendPackageBuildArgv(
    alloc: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    zig_exe: []const u8,
    mode: PackageMode,
    build_opts: []const []const u8,
) !void {
    try argv.appendSlice(alloc, &.{ zig_exe, "build", mode.buildStep(), "-Doptimize=ReleaseSmall" });
    try argv.appendSlice(alloc, build_opts);
}

fn cmdPackage(alloc: std.mem.Allocator, extra_args: []const []const u8) !void {
    std.Io.Dir.cwd().access(runtime.io, "build.zig", .{}) catch {
        print("mer: no build.zig found — are you in a merjs project?\n", .{});
        std.process.exit(1);
    };
    if (builtin.os.tag != .macos) {
        print("mer: package currently produces macOS .app bundles only; Linux/Windows packaging will be platform-specific\n", .{});
        std.process.exit(1);
    }
    const zig_exe = try resolveInPath(alloc, "zig");
    defer alloc.free(zig_exe);

    var package_mode: PackageMode = .package;
    var build_opts: std.ArrayList([]const u8) = .empty;
    defer build_opts.deinit(alloc);
    for (extra_args) |arg| {
        if (std.mem.startsWith(u8, arg, "-D")) {
            try build_opts.append(alloc, arg);
            continue;
        }
        const candidate = selectPackageMode(&.{arg}) catch {
            print("mer: unknown package option '{s}'\n  usage: mer package [--sign|--notarize|--release] [-Dmacos-signing-identity=...] [-Dmacos-notarization-profile=...]\n", .{arg});
            std.process.exit(1);
        };
        if (@intFromEnum(candidate) > @intFromEnum(package_mode)) package_mode = candidate;
    }
    const build_step = package_mode.buildStep();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try appendPackageBuildArgv(alloc, &argv, zig_exe, package_mode, build_opts.items);

    print("mer: running zig build {s}...\n", .{build_step});
    const term = try spawnWaitInheritEnv(alloc, .{
        .argv = argv.items,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const exited = term == .exited;
    if (!exited or term.exited != 0) {
        print("mer: package failed\n", .{});
        std.process.exit(1);
    }
    if (try readZonStringField(alloc, "display_name")) |display_name| {
        defer alloc.free(display_name);
        const bundle_component = try safeBundleComponent(alloc, display_name);
        defer alloc.free(bundle_component);
        print("mer: packaged → zig-out/{s}.app\n", .{bundle_component});
        if (std.mem.eql(u8, build_step, "package-sign")) {
            print("    codesign --verify --deep --strict zig-out/{s}.app\n", .{bundle_component});
        } else if (std.mem.eql(u8, build_step, "package-notarize") or std.mem.eql(u8, build_step, "native-prod-release")) {
            print("    spctl --assess --type execute --verbose zig-out/{s}.app\n", .{bundle_component});
        } else {
            print("    open zig-out/{s}.app\n", .{bundle_component});
        }
    } else {
        print("mer: packaged → zig-out/<Display>.app\n", .{});
        if (std.mem.eql(u8, build_step, "package-sign")) {
            print("    codesign --verify --deep --strict zig-out/<Display>.app\n", .{});
        } else if (std.mem.eql(u8, build_step, "package-notarize") or std.mem.eql(u8, build_step, "native-prod-release")) {
            print("    spctl --assess --type execute --verbose zig-out/<Display>.app\n", .{});
        } else {
            print("    open zig-out/<Display>.app\n", .{});
        }
    }
}

fn cmdAddNative(_: std.mem.Allocator) !void {
    print("\n🪟 mer add native — scaffolding native shell\n\n", .{});

    // mer.app.zon
    const has_zon = if (std.Io.Dir.cwd().access(runtime.io, "mer.app.zon", .{})) true else |_| false;
    if (has_zon) {
        print("  mer.app.zon already exists — skipping\n", .{});
    } else {
        try writeScaffoldFile(std.Io.Dir.cwd(), "mer.app.zon", starter_mer_app_zon);
        print("  ✓ mer.app.zon\n", .{});
    }

    // native/main.zig
    const has_main = if (std.Io.Dir.cwd().access(runtime.io, "native/main.zig", .{})) true else |_| false;
    if (has_main) {
        print("  native/main.zig already exists — skipping\n", .{});
    } else {
        _ = std.Io.Dir.cwd().createDirPathOpen(runtime.io, "native", .{}) catch {};
        try writeScaffoldFile(std.Io.Dir.cwd(), "native/main.zig", starter_native_main);
        print("  ✓ native/main.zig\n", .{});
    }

    print("\n  Next: add this to build.zig (inside pub fn build):\n\n{s}\n", .{native_build_snippet});
    print("  Then: mer native          # launch the native window\n", .{});
    print("        mer native build    # production-gated binary\n", .{});
    print("        mer package         # .app bundle\n\n", .{});
}

// -- build -------------------------------------------------------------------
fn cmdBuild(_: std.mem.Allocator) !void {
    std.Io.Dir.cwd().access(runtime.io, "build.zig", .{}) catch {
        print("mer: no build.zig found — are you in a merjs project?\n", .{});
        std.process.exit(1);
    };

    print("mer: production build...\n", .{});
    const term = try spawnWaitInheritEnv(std.heap.page_allocator, .{
        .argv = &.{ "zig", "build", "-Doptimize=ReleaseSmall", "prod" },
        .stdout = .inherit,
        .stderr = .inherit,
    });
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
    const term = try spawnWaitInheritEnv(std.heap.page_allocator, .{
        .argv = &.{ "zig", "fetch", "--save=merjs", "git+https://github.com/justrach/merjs.git" },
        .stdout = .inherit,
        .stderr = .inherit,
    });
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
    } else if (std.mem.eql(u8, feature, "native")) {
        try cmdAddNative(alloc);
    } else {
        print("mer: unknown feature '{s}'\n\n  available: css, wasm, worker, ui, native\n\n", .{feature});
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
        const term = try spawnWaitInheritEnv(std.heap.page_allocator, .{
            .argv = &.{ "sh", "-c", "curl -sLo tools/tailwindcss " ++ tailwind_url ++ " && chmod +x tools/tailwindcss" },
            .stdout = .inherit,
            .stderr = .inherit,
        });
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
    print("    mer init <name> [--merjs-url URL | --merjs-path PATH] scaffold with an explicit dependency\n", .{});
    print("    mer dev [--port N]   codegen + dev server with hot reload\n", .{});
    print("    mer build            production build (ReleaseSmall + prerender)\n", .{});
    print("    mer add <feature>    add optional features (css, wasm, worker, ui, native)\n", .{});
    print("    mer native           launch a native window against the dev server\n", .{});
    print("    mer native build     build the native shell binary (prod)\n", .{});
    print("    mer native doctor    check macOS native production manifest\n", .{});
    print("    mer package          bundle the native app as a .app (macOS)\n", .{});
    print("    mer package --sign   package + codesign (Developer ID)\n", .{});
    print("    mer package --notarize package + codesign + notarize + staple\n", .{});
    print("    mer package --release validate + codesign + notarize + staple\n", .{});
    print("    mer update           update merjs to latest version\n", .{});
    print("    mer --version        print version\n", .{});
    print("\n  https://github.com/justrach/merjs\n\n", .{});
}
