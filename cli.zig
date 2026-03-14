// cli.zig — standalone CLI entry point for the `mer` command.
//
//   mer init <name>      Scaffold a new merjs project
//   mer dev              Run codegen + start dev server
//   mer build            Production build (codegen + compile + prerender)
//   mer --version        Print version

const std = @import("std");

pub const version = "0.1.0";

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
    \\
    \\    const exe = b.addExecutable(.{ .name = "app", .root_module = main_mod });
    \\    b.installArtifact(exe);
    \\
    \\    // zig build serve
    \\    const run_exe = b.addRunArtifact(exe);
    \\    run_exe.step.dependOn(b.getInstallStep());
    \\    if (b.args) |args| run_exe.addArgs(args);
    \\    b.step("serve", "Start the dev server").dependOn(&run_exe.step);
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

const main_zig_template = @embedFile("src/main.zig");

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
    {
        const zon = try std.fmt.allocPrint(alloc,
            \\.{{
            \\    .name = .@"{s}",
            \\    .version = "0.1.0",
            \\    .minimum_zig_version = "0.15.0",
            \\    .dependencies = .{{
            \\        .merjs = .{{
            \\            .url = "git+https://github.com/justrach/merjs.git",
            \\        }},
            \\    }},
            \\    .paths = .{{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\        "app",
            \\        "api",
            \\        "public",
            \\    }},
            \\}}
            \\
        , .{name});
        defer alloc.free(zon);
        const file = try dir.createFile("build.zig.zon", .{});
        defer file.close();
        try file.writeAll(zon);
    }

    // Write src/generated/.gitkeep + src/main.zig.
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
    print("    zig build codegen     # generate routes\n", .{});
    print("    zig build serve       # start dev server on :3000\n", .{});
    print("\n  or just: mer dev\n\n", .{});
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
        \\    mer --version        print version
        \\
        \\  https://github.com/justrach/merjs
        \\
        \\
    , .{version});
}
