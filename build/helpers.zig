// build/helpers.zig — shared build helpers.

const std = @import("std");

/// Scan dir/ recursively and add each *.zig as a named module import.
/// `dir` is the filesystem path; `import_prefix` is the module name prefix.
/// Example: dir="examples/site/app", prefix="app" → "app/index", "app/about", etc.
pub fn addDirModules(
    b: *std.Build,
    mod: *std.Build.Module,
    mer_mod: *std.Build.Module,
    dir: []const u8,
    import_prefix: []const u8,
    extra_imports: []const struct { []const u8, *std.Build.Module },
) void {
    const layout_path = b.fmt("{s}/layout.zig", .{dir});
    const layout_mod: ?*std.Build.Module = blk: {
        std.Io.Dir.cwd().access(b.graph.io, layout_path, .{}) catch break :blk null;
        const m = b.createModule(.{ .root_source_file = b.path(layout_path) });
        m.addImport("mer", mer_mod);
        for (extra_imports) |ei| m.addImport(ei[0], ei[1]);
        const layout_import = b.fmt("{s}/layout", .{import_prefix});
        mod.addImport(layout_import, m);
        break :blk m;
    };

    var d = std.Io.Dir.cwd().openDir(b.graph.io, dir, .{ .iterate = true }) catch return;
    defer d.close(b.graph.io);
    var walker = d.walk(b.allocator) catch return;
    defer walker.deinit();
    while (walker.next(b.graph.io) catch null) |entry| {
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

/// Create a "routes" named module and add it to `mod`.
/// The routes module gets "mer" plus all app/ and api/ page imports
/// so that consumer projects can override it in their own build.zig.
/// `routes_source` is the path to the routes.zig file (e.g. "src/generated/routes.zig").
pub fn addRoutesModule(
    b: *std.Build,
    mod: *std.Build.Module,
    mer_mod: *std.Build.Module,
    routes_source: []const u8,
    app_dir: []const u8,
    api_dir: []const u8,
    extra_imports: []const struct { []const u8, *std.Build.Module },
) void {
    const routes_mod = b.createModule(.{
        .root_source_file = b.path(routes_source),
    });
    routes_mod.addImport("mer", mer_mod);

    // Give routes.zig access to app/* and api/* page modules + layout/404.
    addDirModules(b, routes_mod, mer_mod, app_dir, "app", extra_imports);
    addDirModules(b, routes_mod, mer_mod, api_dir, "api", &.{});

    mod.addImport("routes", routes_mod);
}

/// Scan a public directory and generate a static_assets module for the Fastly target.
/// Each file is embedded via a WriteFile step, avoiding @embedFile path-escape issues.
pub fn addStaticAssets(
    b: *std.Build,
    mod: *std.Build.Module,
    public_dir: []const u8,
) void {
    const wf = b.addWriteFiles();
    var buf: std.ArrayList(u8) = .empty;

    buf.appendSlice(b.allocator,
        \\pub const Asset = struct { data: []const u8, content_type: []const u8 };
        \\pub fn get(path: []const u8) ?Asset {
        \\    for (assets) |a| {
        \\        if (eql(path, a.path)) return .{ .data = a.data, .content_type = a.ct };
        \\    }
        \\    return null;
        \\}
        \\fn eql(a: []const u8, c: []const u8) bool {
        \\    return a.len == c.len and for (a, c) |x, y| { if (x != y) break false; } else true;
        \\}
        \\const E = struct { path: []const u8, data: []const u8, ct: []const u8 };
        \\const assets = [_]E{
        \\
    ) catch @panic("OOM");

    var d = std.Io.Dir.cwd().openDir(b.graph.io, public_dir, .{ .iterate = true }) catch return;
    defer d.close(b.graph.io);
    var walker = d.walk(b.allocator) catch return;
    defer walker.deinit();
    var count: usize = 0;
    while (walker.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (entry.path[0] == '.') continue;
        const rel = entry.path;
        const file_path = b.fmt("{s}/{s}", .{ public_dir, rel });
        const copy_name = b.fmt("__asset_{d}", .{count});
        const ct = mimeForExt(rel);

        _ = wf.addCopyFile(b.path(file_path), copy_name);

        buf.print(b.allocator, "    .{{ .path = \"/{s}\", .data = @embedFile(\"{s}\"), .ct = \"{s}\" }},\n", .{ rel, copy_name, ct }) catch @panic("OOM");
        count += 1;
    }

    buf.appendSlice(b.allocator, "};\n") catch @panic("OOM");

    const source = wf.add("static_assets.zig", buf.items);

    const assets_mod = b.createModule(.{
        .root_source_file = source,
    });
    mod.addImport("static_assets", assets_mod);
}

fn mimeForExt(path: []const u8) []const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "application/javascript" },
        .{ ".json", "application/json" },
        .{ ".wasm", "application/wasm" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".svg", "image/svg+xml" },
        .{ ".ico", "image/x-icon" },
        .{ ".webp", "image/webp" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".ttf", "font/ttf" },
        .{ ".map", "application/json" },
    };
    for (table) |entry| {
        if (std.mem.endsWith(u8, path, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

/// Create a WASM executable target with standard settings.
pub fn addWasmExe(b: *std.Build, name: []const u8, source: []const u8, wasm_target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = wasm_target,
            .optimize = .small,
        }),
    });
    exe.rdynamic = true;
    exe.entry = .disabled;
    return exe;
}
