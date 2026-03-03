// tools/codegen.zig — scans pages/ and api/, writes src/generated/routes.zig.
// Run via: zig build codegen

const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Each entry stores the full relative path from the project root.
    // e.g. "pages/about.zig", "api/hello.zig"
    var entries: std.ArrayList([]u8) = .{};
    defer {
        for (entries.items) |e| alloc.free(e);
        entries.deinit(alloc);
    }

    try scanDir(alloc, &entries, "pages");
    try scanDir(alloc, &entries, "api");

    std.mem.sort([]u8, entries.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
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
        \\const Route = @import("../router.zig").Route;
        \\
        \\
    );

    for (entries.items) |path| {
        const ident       = try toIdent(alloc, path);
        defer alloc.free(ident);
        const import_name = try toImportName(alloc, path);
        defer alloc.free(import_name);
        try w.print("const {s} = @import(\"{s}\");\n", .{ ident, import_name });
    }

    try w.writeAll("\npub const routes: []const Route = &.{\n");
    for (entries.items) |path| {
        const ident = try toIdent(alloc, path);
        defer alloc.free(ident);
        const url   = try toUrl(alloc, path);
        defer alloc.free(url);
        try w.print("    .{{ .path = \"{s}\", .render = {s}.render }},\n", .{ url, ident });
    }
    try w.writeAll("};\n");

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
        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, entry.path });
        try entries.append(alloc, full);
    }
}

/// "pages/about.zig" → "pages_about"
/// "api/hello.zig"   → "api_hello"
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

/// "pages/about.zig" → "pages/about"   (module import name)
/// "api/hello.zig"   → "api/hello"
fn toImportName(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return alloc.dupe(u8,
        if (std.mem.endsWith(u8, path, ".zig")) path[0 .. path.len - 4] else path
    );
}

/// URL mapping:
///   pages/index.zig      → "/"
///   pages/about.zig      → "/about"
///   pages/blog/post.zig  → "/blog/post"
///   api/hello.zig        → "/api/hello"
///   api/v1/users.zig     → "/api/v1/users"
fn toUrl(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const without_ext = if (std.mem.endsWith(u8, path, ".zig")) path[0 .. path.len - 4] else path;

    // Strip "pages/" prefix, keep "api/" as part of the URL.
    const rel = if (std.mem.startsWith(u8, without_ext, "pages/"))
        without_ext["pages/".len..]
    else
        without_ext; // "api/hello" — stays as-is

    // "index" at pages root → "/"
    if (std.mem.eql(u8, rel, "index")) return alloc.dupe(u8, "/");

    // Build URL: "/" + rel, replacing OS separators with '/'.
    var result = try alloc.alloc(u8, rel.len + 1);
    result[0] = '/';
    for (rel, 0..) |c, i| {
        result[i + 1] = if (c == std.fs.path.sep) '/' else c;
    }

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
