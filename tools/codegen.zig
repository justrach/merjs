// tools/codegen.zig — scans app/ and api/, writes src/generated/routes.zig.
// Run via: zig build codegen

const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Each entry stores the full relative path from the project root.
    // e.g. "app/about.zig", "api/hello.zig"
    var entries: std.ArrayList([]u8) = .{};
    defer {
        for (entries.items) |e| alloc.free(e);
        entries.deinit(alloc);
    }

    try scanDir(alloc, &entries, "app");
    try scanDir(alloc, &entries, "api");

    // Sort routes: static before dynamic, then alphabetically within each group.
    // This ensures /users/settings always matches before /users/:id.
    std.mem.sort([]u8, entries.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            const a_dynamic = hasDynamicSegment(a);
            const b_dynamic = hasDynamicSegment(b);
            if (a_dynamic != b_dynamic) return !a_dynamic; // static first
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeAll(
        \\// GENERATED — do not edit by hand.
        \\// Re-run `zig build codegen` to regenerate.
        \\
        \\const Route = @import("mer").Route;
        \\
        \\
    );

    for (entries.items) |path| {
        const ident = try toIdent(alloc, path);
        defer alloc.free(ident);
        const import_name = try toImportName(alloc, path);
        defer alloc.free(import_name);
        try w.print("const {s} = @import(\"{s}\");\n", .{ ident, import_name });
    }

    try w.writeAll("\npub const routes: []const Route = &.{\n");
    for (entries.items) |path| {
        const ident = try toIdent(alloc, path);
        defer alloc.free(ident);
        const url = try toUrl(alloc, path);
        defer alloc.free(url);
        try w.print("    .{{ .path = \"{s}\", .render = {s}.render, .render_stream = if (@hasDecl({s}, \"renderStream\")) {s}.renderStream else null, .meta = if (@hasDecl({s}, \"meta\")) {s}.meta else .{{}}, .prerender = if (@hasDecl({s}, \"prerender\")) {s}.prerender else false }},\n", .{ url, ident, ident, ident, ident, ident, ident, ident });
    }
    try w.writeAll("};\n\n");

    // Enforce: every app/ page must export `pub const meta: mer.Meta`.
    try w.writeAll("comptime {\n");
    for (entries.items) |path| {
        if (!std.mem.startsWith(u8, path, "app/")) continue;
        const ident = try toIdent(alloc, path);
        defer alloc.free(ident);
        try w.print("    if (!@hasDecl({s}, \"meta\")) @compileError(\"{s} must export pub const meta: mer.Meta\");\n", .{ ident, path });
    }
    try w.writeAll("}\n\n");

    // --- Framework primitives (auto-detected) ---

    // Layout — if app/layout.zig exists, export its wrap function.
    // Also export streamWrap for streaming SSR if the layout provides it.
    if (fileExists("app/layout.zig")) {
        try w.writeAll("const app_layout = @import(\"app/layout\");\n");
        try w.writeAll("pub const layout = app_layout.wrap;\n");
        try w.writeAll("pub const streamLayout = if (@hasDecl(app_layout, \"streamWrap\")) app_layout.streamWrap else null;\n");
    }

    // Error handlers — if app/404.zig exists, export its render function.
    if (fileExists("app/404.zig")) {
        try w.writeAll("const app_404 = @import(\"app/404\");\n");
        try w.writeAll("pub const notFound = app_404.render;\n");
    }

    try std.fs.cwd().makePath("src/generated");
    const out = try std.fs.cwd().createFile("src/generated/routes.zig", .{});
    defer out.close();
    try out.writeAll(buf.items);

    std.debug.print("codegen: wrote {d} route(s) to src/generated/routes.zig\n", .{entries.items.len});
}

/// Scan dir/ for *.zig files, appending "dir/file.zig" to entries.
fn scanDir(alloc: std.mem.Allocator, entries: *std.ArrayList([]u8), dir: []const u8) !void {
    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return;
    defer d.close();
    var walker = try d.walk(alloc);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        // Skip layout.zig — it's a shared layout module, not a route.
        if (std.mem.eql(u8, entry.path, "layout.zig")) continue;
        // Skip 404.zig — it's an error handler, not a regular route.
        if (std.mem.eql(u8, entry.path, "404.zig")) continue;
        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, entry.path });
        try entries.append(alloc, full);
    }
}

/// "app/about.zig" → "app_about"
/// "api/hello.zig" → "api_hello"
fn toIdent(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const without_ext = if (std.mem.endsWith(u8, path, ".zig")) path[0 .. path.len - 4] else path;
    const buf = try alloc.dupe(u8, without_ext);
    for (buf) |*c| {
        if (c.* != '_' and (c.* < 'a' or c.* > 'z') and (c.* < 'A' or c.* > 'Z') and (c.* < '0' or c.* > '9')) {
            c.* = '_';
        }
    }
    return buf;
}

/// "app/about.zig" → "app/about"   (module import name)
/// "api/hello.zig" → "api/hello"
/// "app/about.zig" → "../../app/about.zig"  (file-path import from src/generated/)
/// "api/hello.zig" → "../../api/hello.zig"
/// "app/about.zig" → "app/about"   (module import name)
/// "api/hello.zig" → "api/hello"
fn toImportName(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return alloc.dupe(u8, if (std.mem.endsWith(u8, path, ".zig")) path[0 .. path.len - 4] else path);
}

/// URL mapping:
///   app/index.zig      → "/"
///   app/about.zig      → "/about"
///   app/blog/post.zig  → "/blog/post"
///   api/hello.zig        → "/api/hello"
///   api/v1/users.zig     → "/api/v1/users"
/// URL mapping:
///   app/index.zig          → "/"
///   app/about.zig          → "/about"
///   app/blog/post.zig      → "/blog/post"
///   app/users/[id].zig     → "/users/:id"   (dynamic segment)
///   api/hello.zig          → "/api/hello"
///   api/v1/users.zig       → "/api/v1/users"
fn toUrl(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const without_ext = if (std.mem.endsWith(u8, path, ".zig")) path[0 .. path.len - 4] else path;

    // Strip "app/" prefix, keep "api/" as part of the URL.
    const rel = if (std.mem.startsWith(u8, without_ext, "app/"))
        without_ext["app/".len..]
    else
        without_ext; // "api/hello" — stays as-is

    // "index" at app root → "/"
    if (std.mem.eql(u8, rel, "index")) return alloc.dupe(u8, "/");

    // Build URL: "/" + rel, replacing OS separators with '/' and [name] → :name.
    var result = try alloc.alloc(u8, rel.len + 1);
    result[0] = '/';
    var i: usize = 0;
    var out: usize = 1;
    while (i < rel.len) : (i += 1) {
        const c = rel[i];
        if (c == '[') {
            // Replace '[name]' with ':name'.
            result[out] = ':';
            out += 1;
            i += 1; // skip '['
            while (i < rel.len and rel[i] != ']') : (i += 1) {
                result[out] = rel[i];
                out += 1;
            }
            // i now points at ']' — loop increment skips it.
        } else {
            result[out] = if (c == std.fs.path.sep) '/' else c;
            out += 1;
        }
    }
    result = result[0..out];

    // Strip trailing "/index" → parent path.
    const index_suffix = "/index";
    if (std.mem.endsWith(u8, result, index_suffix)) {
        const trimmed = result[0 .. result.len - index_suffix.len];
        if (trimmed.len == 0) {
            alloc.free(result);
            return alloc.dupe(u8, "/");
        }
        const r = try alloc.dupe(u8, trimmed);
        alloc.free(result);
        return r;
    }

    return result;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Returns true if the path contains a `[name]` dynamic segment.
fn hasDynamicSegment(path: []const u8) bool {
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '[') {
            while (i < path.len and path[i] != ']') : (i += 1) {}
            return true;
        }
    }
    return false;
}
