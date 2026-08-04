// tools/codegen.zig — scans app/ and api/, writes src/generated/routes.zig.
// Run via: zig build codegen

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const mercss_jit = @import("mercss_jit");

const max_css_source_bytes = 4 * 1024 * 1024;
const max_css_candidate_bytes = 16 * 1024 * 1024;
const max_css_candidate_count = 100_000;
const max_route_count = 10_000;
const max_route_path_bytes = 4 * 1024 * 1024;

const CssCandidateLimits = struct {
    bytes: usize = max_css_candidate_bytes,
    count: usize = max_css_candidate_count,
};

const RouteLimits = struct {
    count: usize = max_route_count,
    path_bytes: usize = max_route_path_bytes,
};

const RouteEntry = struct {
    path: []u8,
    url: []u8,
    ident: []u8,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Initialize std.Io runtime (Threaded on Zig 0.16-supported targets).
    try runtime.init(alloc);
    defer runtime.deinit();

    var args = try std.process.Args.Iterator.initAllocator(init.args, alloc);
    defer args.deinit();
    const executable = args.next() orelse "codegen";
    const app_arg = args.next();
    const api_arg = args.next();
    const output_arg = args.next();
    if ((app_arg == null) != (api_arg == null) or
        (app_arg == null) != (output_arg == null) or
        args.next() != null)
    {
        std.debug.print("usage: {s} [<app-dir> <api-dir> <output>]\n", .{executable});
        return error.InvalidArguments;
    }
    const app_dir = app_arg orelse "app";
    const api_dir = api_arg orelse "api";
    const output_path = output_arg orelse "src/generated/routes.zig";

    try generate(alloc, app_dir, api_dir, output_path);
}

fn generate(alloc: std.mem.Allocator, app_dir: []const u8, api_dir: []const u8, output_path: []const u8) !void {
    return generateWithCssCandidateLimits(alloc, app_dir, api_dir, output_path, .{});
}

fn generateWithCssCandidateLimits(
    alloc: std.mem.Allocator,
    app_dir: []const u8,
    api_dir: []const u8,
    output_path: []const u8,
    css_candidate_limits: CssCandidateLimits,
) !void {
    return generateWithLimits(alloc, app_dir, api_dir, output_path, .{}, css_candidate_limits);
}

fn generateWithLimits(
    alloc: std.mem.Allocator,
    app_dir: []const u8,
    api_dir: []const u8,
    output_path: []const u8,
    route_limits: RouteLimits,
    css_candidate_limits: CssCandidateLimits,
) !void {
    // Each entry stores its logical module path, URL, and identifier once.
    var entries: std.ArrayList(RouteEntry) = .empty;
    defer {
        for (entries.items) |entry| {
            alloc.free(entry.path);
            alloc.free(entry.url);
            alloc.free(entry.ident);
        }
        entries.deinit(alloc);
    }
    var route_path_bytes: usize = 0;

    scanDir(alloc, &entries, &route_path_bytes, route_limits, app_dir, "app") catch |err| {
        std.debug.print("codegen: cannot scan {s}: {s}\n", .{ app_dir, @errorName(err) });
        return err;
    };
    scanDir(alloc, &entries, &route_path_bytes, route_limits, api_dir, "api") catch |err| {
        if (!isOptionalApiDirError(err)) {
            std.debug.print("codegen: cannot scan {s}: {s}\n", .{ api_dir, @errorName(err) });
            return err;
        }
    };

    // Sort routes: static before dynamic, then alphabetically within each group.
    // This ensures /users/settings always matches before /users/:id.
    std.mem.sort(RouteEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: RouteEntry, b: RouteEntry) bool {
            const a_dynamic = hasDynamicSegment(a.path);
            const b_dynamic = hasDynamicSegment(b.path);
            if (a_dynamic != b_dynamic) return !a_dynamic; // static first
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    try validateUniqueRoutes(alloc, entries.items, true);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    // 0.16: ArrayList no longer has .writer() — use appendSlice/print directly.

    try buf.appendSlice(alloc,
        \\// GENERATED — do not edit by hand.
        \\// Re-run `zig build codegen` to regenerate.
        \\
        \\const Route = @import("mer").Route;
        \\
        \\
    );

    for (entries.items) |entry| {
        const import_name = entry.path[0 .. entry.path.len - 4];
        try buf.print(alloc, "const {s} = @import(\"{s}\");\n", .{ entry.ident, import_name });
    }

    try buf.appendSlice(alloc, "\npub const routes: []const Route = &.{\n");
    for (entries.items) |entry| {
        try buf.print(alloc, "    .{{ .path = \"{s}\", .render = {s}.render, .render_stream = if (@hasDecl({s}, \"renderStream\")) {s}.renderStream else null, .meta = if (@hasDecl({s}, \"meta\")) {s}.meta else .{{}}, .prerender = if (@hasDecl({s}, \"prerender\")) {s}.prerender else false }},\n", .{ entry.url, entry.ident, entry.ident, entry.ident, entry.ident, entry.ident, entry.ident, entry.ident });
    }
    try buf.appendSlice(alloc, "};\n\n");

    // Enforce: every app/ page must export `pub const meta: mer.Meta`.
    try buf.appendSlice(alloc, "comptime {\n");
    for (entries.items) |entry| {
        if (!std.mem.startsWith(u8, entry.path, "app/")) continue;
        try buf.print(alloc, "    if (!@hasDecl({s}, \"meta\")) @compileError(\"{s} must export pub const meta: mer.Meta\");\n", .{ entry.ident, entry.path });
    }
    try buf.appendSlice(alloc, "}\n\n");

    // --- Framework primitives (auto-detected) ---

    // Layout — if app/layout.zig exists, export its wrap function.
    // Also export streamWrap for streaming SSR if the layout provides it.
    const layout_path = try std.fs.path.join(alloc, &.{ app_dir, "layout.zig" });
    defer alloc.free(layout_path);
    if (fileExists(layout_path)) {
        try buf.appendSlice(alloc, "const app_layout = @import(\"app/layout\");\n");
        try buf.appendSlice(alloc, "pub const layout = app_layout.wrap;\n");
        try buf.appendSlice(alloc, "pub const streamLayout = if (@hasDecl(app_layout, \"streamWrap\")) app_layout.streamWrap else null;\n");
    }

    // Error handlers — if app/404.zig exists, export its render function.
    const not_found_path = try std.fs.path.join(alloc, &.{ app_dir, "404.zig" });
    defer alloc.free(not_found_path);
    if (fileExists(not_found_path)) {
        try buf.appendSlice(alloc, "const app_404 = @import(\"app/404\");\n");
        try buf.appendSlice(alloc, "pub const notFound = app_404.render;\n");
    }

    const generated_css = try generateCssWithLimits(alloc, app_dir, css_candidate_limits);
    defer alloc.free(generated_css.bytes);
    const css_output_path = try std.fs.path.join(alloc, &.{ app_dir, "_mercss.css" });
    defer alloc.free(css_output_path);

    try writeOutputs(alloc, output_path, buf.items, css_output_path, generated_css.bytes);

    std.debug.print("codegen: wrote {d} route(s) to {s}\n", .{ entries.items.len, output_path });
    std.debug.print(
        "mercss: wrote {d} bytes ({d} candidates, {d} sources) to {s}\n",
        .{ generated_css.bytes.len, generated_css.candidate_count, generated_css.source_count, css_output_path },
    );
}

const GeneratedCss = struct {
    bytes: []u8,
    candidate_count: usize,
    source_count: usize,
};

fn generateCss(alloc: std.mem.Allocator, app_dir: []const u8) !GeneratedCss {
    return generateCssWithLimits(alloc, app_dir, .{});
}

fn generateCssWithLimits(alloc: std.mem.Allocator, app_dir: []const u8, limits: CssCandidateLimits) !GeneratedCss {
    var ds = mercss_jit.DesignSystem.init(alloc);
    defer ds.deinit();
    try ds.loadDefaults();

    var candidates: std.ArrayList([]const u8) = .empty;
    defer {
        for (candidates.items) |candidate| alloc.free(candidate);
        candidates.deinit(alloc);
    }

    const source_count = try scanCssCandidates(alloc, app_dir, &candidates, limits);
    sortAndDeduplicateCandidates(&candidates);

    return .{
        .bytes = try mercss_jit.compile(alloc, &ds, candidates.items),
        .candidate_count = candidates.items.len,
        .source_count = source_count,
    };
}

fn rejectDestinationAlias(alloc: std.mem.Allocator, routes_path: []const u8, css_path: []const u8) !void {
    const routes_absolute = try lexicalAbsolutePath(alloc, routes_path);
    defer alloc.free(routes_absolute);
    const css_absolute = try lexicalAbsolutePath(alloc, css_path);
    defer alloc.free(css_absolute);
    const case_insensitive_paths = builtin.os.tag == .windows or builtin.os.tag == .macos;
    if (outputPathsEqual(routes_absolute, css_absolute, case_insensitive_paths)) {
        return destinationAlias(routes_path, css_path);
    }

    // Resolve existing parent directories as well as existing files. This
    // catches two not-yet-created leaves reached through symlinked parents.
    const routes_parent_resolved = try parentResolvedDestination(alloc, routes_path);
    defer if (routes_parent_resolved) |path| alloc.free(path);
    const css_parent_resolved = try parentResolvedDestination(alloc, css_path);
    defer if (css_parent_resolved) |path| alloc.free(path);
    if (routes_parent_resolved != null and css_parent_resolved != null) {
        if (outputPathsEqual(routes_parent_resolved.?, css_parent_resolved.?, case_insensitive_paths)) {
            return destinationAlias(routes_path, css_path);
        }
        const routes_parent = std.fs.path.dirname(routes_parent_resolved.?) orelse routes_parent_resolved.?;
        const css_parent = std.fs.path.dirname(css_parent_resolved.?) orelse css_parent_resolved.?;
        if ((outputPathsEqual(routes_parent, css_parent, true) or
            try parentDirectoriesShareIdentity(routes_path, css_path)) and
            caseFoldingBasenamesMayAlias(
                std.fs.path.basename(routes_parent_resolved.?),
                std.fs.path.basename(css_parent_resolved.?),
                true,
            ))
        {
            return destinationAlias(routes_path, css_path);
        }
    }

    // Existing paths are additionally resolved so symlink aliases are rejected.
    // A shared inode with multiple links catches hard-link aliases where supported.
    const cwd = std.Io.Dir.cwd();
    const routes_real = cwd.realPathFileAlloc(runtime.io, routes_path, alloc) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (routes_real) |path| alloc.free(path);
    const css_real = cwd.realPathFileAlloc(runtime.io, css_path, alloc) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (css_real) |path| alloc.free(path);
    if (routes_real != null and css_real != null and
        std.mem.eql(u8, routes_real.?, css_real.?))
    {
        return destinationAlias(routes_path, css_path);
    }

    const routes_stat = cwd.statFile(runtime.io, routes_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const css_stat = cwd.statFile(runtime.io, css_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (routes_stat != null and css_stat != null and
        routes_stat.?.nlink > 1 and css_stat.?.nlink > 1 and
        routes_stat.?.inode == css_stat.?.inode)
    {
        return destinationAlias(routes_path, css_path);
    }
}

fn parentDirectoriesShareIdentity(a: []const u8, b: []const u8) !bool {
    const cwd = std.Io.Dir.cwd();
    const a_parent = std.fs.path.dirname(a) orelse ".";
    const b_parent = std.fs.path.dirname(b) orelse ".";
    const a_stat = cwd.statFile(runtime.io, a_parent, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    const b_stat = cwd.statFile(runtime.io, b_parent, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return a_stat.inode == b_stat.inode;
}

fn parentResolvedDestination(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    const parent = std.fs.path.dirname(path) orelse ".";
    var dir = std.Io.Dir.cwd().openDir(runtime.io, parent, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(runtime.io);
    var resolved_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved_len = try dir.realPath(runtime.io, &resolved_buffer);
    return try std.fs.path.join(alloc, &.{ resolved_buffer[0..resolved_len], std.fs.path.basename(path) });
}

fn outputPathsEqual(a: []const u8, b: []const u8, case_insensitive: bool) bool {
    return if (case_insensitive) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn caseFoldingBasenamesMayAlias(a: []const u8, b: []const u8, windows: bool) bool {
    if (std.ascii.eqlIgnoreCase(a, b)) return true;
    if (!isAscii(a) or !isAscii(b)) return true;
    return windows and (isWindowsAmbiguousBasename(a) or isWindowsAmbiguousBasename(b));
}

fn isAscii(value: []const u8) bool {
    for (value) |byte| if (byte >= 0x80) return false;
    return true;
}

fn isWindowsAmbiguousBasename(value: []const u8) bool {
    if (value.len == 0 or value[value.len - 1] == ' ' or value[value.len - 1] == '.') return true;
    for (value) |byte| {
        if (byte < 0x20 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", byte) != null) return true;
    }
    return false;
}

fn lexicalAbsolutePath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(alloc, &.{path});

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try runtime.io.vtable.processCurrentPath(runtime.io.userdata, &cwd_buffer);
    return std.fs.path.resolve(alloc, &.{ cwd_buffer[0..cwd_len], path });
}

fn destinationAlias(routes_path: []const u8, css_path: []const u8) error{DestinationAlias} {
    std.debug.print("codegen: routes and CSS outputs refer to the same destination: {s} and {s}\n", .{ routes_path, css_path });
    return error.DestinationAlias;
}

fn writeOutputs(
    alloc: std.mem.Allocator,
    routes_path: []const u8,
    routes: []const u8,
    css_path: []const u8,
    css: []const u8,
) !void {
    try rejectDestinationAlias(alloc, routes_path, css_path);

    // Atomic files keep their temporary files beside each destination and clean
    // them up on error. Write both before renaming either into place.
    var routes_file = try std.Io.Dir.cwd().createFileAtomic(runtime.io, routes_path, .{
        .make_path = true,
        .replace = true,
    });
    defer routes_file.deinit(runtime.io);
    try routes_file.file.writePositionalAll(runtime.io, routes, 0);

    var css_file = try std.Io.Dir.cwd().createFileAtomic(runtime.io, css_path, .{
        .replace = true,
    });
    defer css_file.deinit(runtime.io);
    try css_file.file.writePositionalAll(runtime.io, css, 0);

    // Routes are the final commit marker: a reader that sees new routes also
    // sees the CSS they reference. A process crash between replaces can still
    // leave newly published CSS with old routes, but never the inverse.
    try css_file.replace(runtime.io);
    try routes_file.replace(runtime.io);
}

fn isComponentPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "components/") or
        std.mem.startsWith(u8, path, "components\\") or
        std.mem.indexOf(u8, path, "/components/") != null or
        std.mem.indexOf(u8, path, "\\components\\") != null;
}

fn isOptionalApiDirError(err: anyerror) bool {
    return err == error.FileNotFound;
}

fn routeLimitExceeded(source_dir: []const u8, limits: RouteLimits) !void {
    std.debug.print(
        "codegen: cannot scan {s}: aggregate routes exceed the limit of {d} routes or {d} route-path bytes; split the application or reduce route paths\n",
        .{ source_dir, limits.count, limits.path_bytes },
    );
    return error.RouteLimitExceeded;
}

/// Scan source_dir/ for *.zig files, appending precomputed route data.
fn scanDir(
    alloc: std.mem.Allocator,
    entries: *std.ArrayList(RouteEntry),
    route_path_bytes: *usize,
    limits: RouteLimits,
    source_dir: []const u8,
    logical_dir: []const u8,
) !void {
    var d = try std.Io.Dir.cwd().openDir(runtime.io, source_dir, .{ .iterate = true });
    defer d.close(runtime.io);
    var walker = try d.walk(alloc);
    defer walker.deinit();
    while (try walker.next(runtime.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        // Skip layout.zig — it's a shared layout module, not a route.
        if (std.mem.eql(u8, entry.path, "layout.zig")) continue;
        // Skip 404.zig — it's an error handler, not a regular route.
        if (std.mem.eql(u8, entry.path, "404.zig")) continue;
        // app/components contains reusable modules, not file-based pages.
        if (std.mem.eql(u8, logical_dir, "app") and isComponentPath(entry.path)) continue;
        const path_len = logical_dir.len + 1 + entry.path.len;
        if (entries.items.len >= limits.count or path_len > limits.path_bytes -| route_path_bytes.*) {
            return routeLimitExceeded(source_dir, limits);
        }
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ logical_dir, entry.path });
        errdefer alloc.free(path);
        const url = try toUrl(alloc, path);
        errdefer alloc.free(url);
        const ident = try toIdent(alloc, path);
        errdefer alloc.free(ident);
        try entries.append(alloc, .{ .path = path, .url = url, .ident = ident });
        route_path_bytes.* += path_len;
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
    const result_buffer = try alloc.alloc(u8, rel.len + 1);
    errdefer alloc.free(result_buffer);
    result_buffer[0] = '/';
    var i: usize = 0;
    var out: usize = 1;
    while (i < rel.len) : (i += 1) {
        const c = rel[i];
        if (c == '[') {
            // Replace '[name]' with ':name'.
            result_buffer[out] = ':';
            out += 1;
            i += 1; // skip '['
            while (i < rel.len and rel[i] != ']') : (i += 1) {
                result_buffer[out] = rel[i];
                out += 1;
            }
            // i now points at ']' — loop increment skips it.
        } else {
            result_buffer[out] = if (c == std.fs.path.sep) '/' else c;
            out += 1;
        }
    }
    const result = result_buffer[0..out];

    // Strip trailing "/index" → parent path.
    const index_suffix = "/index";
    const final = if (std.mem.endsWith(u8, result, index_suffix)) blk: {
        const trimmed = result[0 .. result.len - index_suffix.len];
        break :blk if (trimmed.len == 0) "/" else trimmed;
    } else result;
    const owned = try alloc.dupe(u8, final);
    alloc.free(result_buffer);
    return owned;
}

fn routePatternsCollide(a: []const u8, b: []const u8) bool {
    var a_segments = std.mem.splitScalar(u8, a, '/');
    var b_segments = std.mem.splitScalar(u8, b, '/');
    var a_has_dynamic = false;
    var b_has_dynamic = false;
    while (true) {
        const a_segment = a_segments.next();
        const b_segment = b_segments.next();
        if (a_segment == null or b_segment == null) {
            if (a_segment != null or b_segment != null) return false;
            // A fully static route has deterministic exact-map precedence over
            // a dynamic route. Two dynamic patterns must not intersect.
            return a_has_dynamic == b_has_dynamic;
        }
        const a_dynamic = a_segment.?.len > 0 and a_segment.?[0] == ':';
        const b_dynamic = b_segment.?.len > 0 and b_segment.?[0] == ':';
        a_has_dynamic = a_has_dynamic or a_dynamic;
        b_has_dynamic = b_has_dynamic or b_dynamic;
        if (!a_dynamic and !b_dynamic and !std.mem.eql(u8, a_segment.?, b_segment.?)) return false;
    }
}

fn validateUniqueRoutes(alloc: std.mem.Allocator, entries: []const RouteEntry, report_collision: bool) !void {
    var identifiers = std.StringHashMap(usize).init(alloc);
    defer identifiers.deinit();

    for (entries, 0..) |entry, i| {
        if (identifiers.get(entry.ident)) |previous_i| {
            const previous = entries[previous_i];
            if (report_collision) std.debug.print("codegen: identifier collision: {s} and {s} both emit {s}\n", .{ entry.path, previous.path, entry.ident });
            return error.DuplicateIdentifier;
        }
        try identifiers.put(entry.ident, i);

        // Pattern intersection remains quadratic, but route limits bound it.
        for (entries[0..i]) |previous| {
            if (routePatternsCollide(entry.url, previous.url)) {
                if (report_collision) std.debug.print("codegen: route collision: {s} ({s}) conflicts with {s} ({s})\n", .{ entry.path, entry.url, previous.path, previous.url });
                return error.DuplicateRoute;
            }
        }
    }
}

fn validateRoutePaths(alloc: std.mem.Allocator, paths: []const []const u8, report_collision: bool) !void {
    var entries: std.ArrayList(RouteEntry) = .empty;
    defer {
        for (entries.items) |entry| {
            alloc.free(entry.path);
            alloc.free(entry.url);
            alloc.free(entry.ident);
        }
        entries.deinit(alloc);
    }
    for (paths) |path| {
        const owned_path = try alloc.dupe(u8, path);
        errdefer alloc.free(owned_path);
        const url = try toUrl(alloc, owned_path);
        errdefer alloc.free(url);
        const ident = try toIdent(alloc, owned_path);
        errdefer alloc.free(ident);
        try entries.append(alloc, .{ .path = owned_path, .url = url, .ident = ident });
    }
    try validateUniqueRoutes(alloc, entries.items, report_collision);
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(runtime.io, path, .{}) catch return false;
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

fn cssSourcePath(alloc: std.mem.Allocator, dir_path: []const u8, entry_path: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ dir_path, entry_path });
}

fn cssSourceTooLarge(path: []const u8) !usize {
    std.debug.print(
        "mercss: cannot scan {s}: source exceeds the 4 MiB limit; split it into smaller source files\n",
        .{path},
    );
    return error.SourceTooLarge;
}

fn sortAndDeduplicateCandidates(candidates: *std.ArrayList([]const u8)) void {
    std.mem.sort([]const u8, candidates.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var len: usize = 0;
    for (candidates.items) |candidate| {
        if (len == 0 or !std.mem.eql(u8, candidate, candidates.items[len - 1])) {
            candidates.items[len] = candidate;
            len += 1;
        }
    }
    candidates.shrinkRetainingCapacity(len);
}

fn cssCandidateLimitExceeded(path: []const u8, limits: CssCandidateLimits) !usize {
    std.debug.print(
        "mercss: cannot scan {s}: unique CSS candidates exceed the aggregate limit of {d} candidates or {d} bytes\n",
        .{ path, limits.count, limits.bytes },
    );
    return error.CssCandidateLimitExceeded;
}

/// Recursively walk `dir` looking for .zig and .html files. Each source is
/// scanned and freed before the next one; unique candidates are copied into
/// owned storage because mercss_jit.scan returns slices into that source.
fn scanCssCandidates(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    candidates: *std.ArrayList([]const u8),
    limits: CssCandidateLimits,
) !usize {
    var candidate_bytes: usize = 0;
    var source_count: usize = 0;
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    var d = std.Io.Dir.cwd().openDir(runtime.io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("mercss: cannot scan {s}: {s}\n", .{ dir_path, @errorName(err) });
        return err;
    };
    defer d.close(runtime.io);
    var walker = try d.walk(alloc);
    defer walker.deinit();
    while (try walker.next(runtime.io)) |entry| {
        if (entry.kind != .file) continue;
        const is_zig = std.mem.endsWith(u8, entry.path, ".zig");
        const is_html = std.mem.endsWith(u8, entry.path, ".html");
        if (!is_zig and !is_html) continue;
        // Skip our own generated output.
        if (std.mem.eql(u8, entry.basename, "_mercss.css")) continue;

        const path = try cssSourcePath(alloc, dir_path, entry.path);
        defer alloc.free(path);
        const f = entry.dir.openFile(runtime.io, entry.basename, .{}) catch |err| {
            std.debug.print("mercss: cannot scan {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        defer f.close(runtime.io);
        var reader_buf: [4096]u8 = undefined;
        var fr = f.reader(runtime.io, &reader_buf);
        {
            const content = fr.interface.allocRemaining(alloc, .limited(max_css_source_bytes)) catch |err| switch (err) {
                error.StreamTooLong => return cssSourceTooLarge(path),
                else => {
                    std.debug.print("mercss: cannot scan {s}: {s}\n", .{ path, @errorName(err) });
                    return err;
                },
            };
            defer alloc.free(content);
            var source_candidates: std.ArrayList([]const u8) = .empty;
            defer source_candidates.deinit(alloc);
            try mercss_jit.scan(content, alloc, &source_candidates);
            for (source_candidates.items) |candidate| {
                if (seen.contains(candidate)) continue;
                if (candidates.items.len >= limits.count or candidate.len > limits.bytes -| candidate_bytes) {
                    return cssCandidateLimitExceeded(path, limits);
                }
                const owned = try alloc.dupe(u8, candidate);
                candidates.append(alloc, owned) catch |err| {
                    alloc.free(owned);
                    return err;
                };
                try seen.put(owned, {});
                candidate_bytes += owned.len;
            }
        }
        source_count += 1;
    }
    return source_count;
}

test "scan CSS candidates: >4 MiB source reports its full path" {
    const path = try cssSourcePath(std.testing.allocator, "test-app", "nested/oversized.zig");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("test-app/nested/oversized.zig", path);
    try std.testing.expectError(error.SourceTooLarge, cssSourceTooLarge(path));
}

test "codegen rejects CSS output destination aliases before writing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_css = "old css\n";
    try tmp.dir.createDir(std.testing.io, "app", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/_mercss.css", .data = old_css });

    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);
    const css_path = try std.fs.path.join(alloc, &.{ root, "app/_mercss.css" });
    defer alloc.free(css_path);
    const normalized_alias = try std.fs.path.join(alloc, &.{ root, "app/../app/_mercss.css" });
    defer alloc.free(normalized_alias);

    try runtime.init(alloc);
    defer runtime.deinit();
    try std.testing.expectError(error.DestinationAlias, writeOutputs(alloc, css_path, "new routes\n", css_path, "new css\n"));
    try std.testing.expectError(error.DestinationAlias, writeOutputs(alloc, normalized_alias, "new routes\n", css_path, "new css\n"));

    const css = try tmp.dir.readFileAlloc(std.testing.io, "app/_mercss.css", alloc, .unlimited);
    defer alloc.free(css);
    try std.testing.expectEqualSlices(u8, old_css, css);
}

test "case-insensitive output paths reject ambiguous aliases" {
    try std.testing.expect(outputPathsEqual("C:\\project\\app\\_mercss.css", "c:\\PROJECT\\APP\\_MERCSS.CSS", true));
    try std.testing.expect(!outputPathsEqual("/project/app/routes.zig", "/project/app/_mercss.css", true));
    try std.testing.expect(!outputPathsEqual("/project/app/Route.zig", "/project/app/route.zig", false));
    try std.testing.expect(caseFoldingBasenamesMayAlias("_mercſs.css", "_mercss.css", false));
    try std.testing.expect(caseFoldingBasenamesMayAlias("_mercss.css.", "_mercss.css", true));
    try std.testing.expect(!caseFoldingBasenamesMayAlias("routes.zig", "_mercss.css", true));
}

test "codegen rejects nonexistent outputs through symlinked parents" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "app", .default_dir);
    try tmp.dir.symLink(std.testing.io, "app", "app-link", .{});

    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);
    const css_path = try std.fs.path.join(alloc, &.{ root, "app/_mercss.css" });
    defer alloc.free(css_path);
    const routes_path = try std.fs.path.join(alloc, &.{ root, "app-link/_mercss.css" });
    defer alloc.free(routes_path);

    try runtime.init(alloc);
    defer runtime.deinit();
    try std.testing.expectError(error.DestinationAlias, writeOutputs(alloc, routes_path, "new routes\n", css_path, "new css\n"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "app/_mercss.css", .{}));
}

test "codegen rejects existing CSS symlink aliases before writing" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_css = "old css\n";
    try tmp.dir.createDir(std.testing.io, "app", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/_mercss.css", .data = old_css });
    try tmp.dir.symLink(std.testing.io, "app/_mercss.css", "routes-link.zig", .{});

    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);
    const css_path = try std.fs.path.join(alloc, &.{ root, "app/_mercss.css" });
    defer alloc.free(css_path);
    const routes_path = try std.fs.path.join(alloc, &.{ root, "routes-link.zig" });
    defer alloc.free(routes_path);

    try runtime.init(alloc);
    defer runtime.deinit();
    try std.testing.expectError(error.DestinationAlias, writeOutputs(alloc, routes_path, "new routes\n", css_path, "new css\n"));

    const css = try tmp.dir.readFileAlloc(std.testing.io, "app/_mercss.css", alloc, .unlimited);
    defer alloc.free(css);
    try std.testing.expectEqualSlices(u8, old_css, css);
}

test "codegen leaves both outputs unchanged when CSS scanning fails" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_routes = "old routes\n";
    const old_css = "old css\n";
    try tmp.dir.createDir(std.testing.io, "app", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "routes.zig", .data = old_routes });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/_mercss.css", .data = old_css });

    const oversized = try alloc.alloc(u8, max_css_source_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/oversized.zig", .data = oversized });

    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);
    const app_dir = try std.fs.path.join(alloc, &.{ root, "app" });
    defer alloc.free(app_dir);
    const routes_path = try std.fs.path.join(alloc, &.{ root, "routes.zig" });
    defer alloc.free(routes_path);

    try runtime.init(alloc);
    defer runtime.deinit();
    try std.testing.expectError(error.SourceTooLarge, generate(alloc, app_dir, "missing-api", routes_path));

    const routes = try tmp.dir.readFileAlloc(std.testing.io, "routes.zig", alloc, .unlimited);
    defer alloc.free(routes);
    const css = try tmp.dir.readFileAlloc(std.testing.io, "app/_mercss.css", alloc, .unlimited);
    defer alloc.free(css);
    try std.testing.expectEqualSlices(u8, old_routes, routes);
    try std.testing.expectEqualSlices(u8, old_css, css);
}

test "duplicate CSS candidates across sources use one aggregate budget entry" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "app", .default_dir);
    for (0..8) |i| {
        const path = try std.fmt.allocPrint(alloc, "app/source-{d}.html", .{i});
        defer alloc.free(path);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "<div class=\"flex\"></div>" });
    }

    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);
    const app_dir = try std.fs.path.join(alloc, &.{ root, "app" });
    defer alloc.free(app_dir);

    try runtime.init(alloc);
    defer runtime.deinit();
    const css = try generateCssWithLimits(alloc, app_dir, .{ .bytes = "flex".len, .count = 1 });
    defer alloc.free(css.bytes);
    try std.testing.expectEqual(@as(usize, 1), css.candidate_count);
    try std.testing.expectEqual(@as(usize, 8), css.source_count);
}

test "aggregate CSS candidate limit leaves both outputs unchanged" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_routes = "old routes\n";
    const old_css = "old css\n";
    try tmp.dir.createDir(std.testing.io, "app", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "routes.zig", .data = old_routes });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/_mercss.css", .data = old_css });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/classes.html", .data = "<div class=\"flex p-4\"></div>" });

    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);
    const app_dir = try std.fs.path.join(alloc, &.{ root, "app" });
    defer alloc.free(app_dir);
    const routes_path = try std.fs.path.join(alloc, &.{ root, "routes.zig" });
    defer alloc.free(routes_path);

    try runtime.init(alloc);
    defer runtime.deinit();
    try std.testing.expectError(error.CssCandidateLimitExceeded, generateWithCssCandidateLimits(alloc, app_dir, "missing-api", routes_path, .{ .bytes = 1024, .count = 1 }));

    const routes = try tmp.dir.readFileAlloc(std.testing.io, "routes.zig", alloc, .unlimited);
    defer alloc.free(routes);
    const css = try tmp.dir.readFileAlloc(std.testing.io, "app/_mercss.css", alloc, .unlimited);
    defer alloc.free(css);
    try std.testing.expectEqualSlices(u8, old_routes, routes);
    try std.testing.expectEqualSlices(u8, old_css, css);
}

test "shared app and api route limit leaves both outputs unchanged" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_routes = "old routes\n";
    const old_css = "old css\n";
    try tmp.dir.createDir(std.testing.io, "app", .default_dir);
    try tmp.dir.createDir(std.testing.io, "api", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/page.zig", .data = "pub const meta = undefined;" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "api/hello.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "routes.zig", .data = old_routes });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/_mercss.css", .data = old_css });

    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(root);
    const app_dir = try std.fs.path.join(alloc, &.{ root, "app" });
    defer alloc.free(app_dir);
    const api_dir = try std.fs.path.join(alloc, &.{ root, "api" });
    defer alloc.free(api_dir);
    const routes_path = try std.fs.path.join(alloc, &.{ root, "routes.zig" });
    defer alloc.free(routes_path);

    try runtime.init(alloc);
    defer runtime.deinit();
    try std.testing.expectError(error.RouteLimitExceeded, generateWithLimits(alloc, app_dir, api_dir, routes_path, .{ .count = 1, .path_bytes = 1024 }, .{}));

    const routes = try tmp.dir.readFileAlloc(std.testing.io, "routes.zig", alloc, .unlimited);
    defer alloc.free(routes);
    const css = try tmp.dir.readFileAlloc(std.testing.io, "app/_mercss.css", alloc, .unlimited);
    defer alloc.free(css);
    try std.testing.expectEqualSlices(u8, old_routes, routes);
    try std.testing.expectEqualSlices(u8, old_css, css);
}

test "only a missing API directory is optional" {
    try std.testing.expect(isOptionalApiDirError(error.FileNotFound));
    try std.testing.expect(!isOptionalApiDirError(error.AccessDenied));
}

test "CSS candidates are sorted and deduplicated at the codegen boundary" {
    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(std.testing.allocator);
    try candidates.appendSlice(std.testing.allocator, &.{ "p-4", "flex", "p-4", "bg-red-500" });

    sortAndDeduplicateCandidates(&candidates);
    try std.testing.expectEqualStrings("bg-red-500", candidates.items[0]);
    try std.testing.expectEqualStrings("flex", candidates.items[1]);
    try std.testing.expectEqualStrings("p-4", candidates.items[2]);
    try std.testing.expectEqual(@as(usize, 3), candidates.items.len);
}

test "component directories are excluded from app routes" {
    try std.testing.expect(isComponentPath("components/button.zig"));
    try std.testing.expect(isComponentPath("admin/components/card.zig"));
    try std.testing.expect(isComponentPath("components\\button.zig"));
    try std.testing.expect(!isComponentPath("component-library.zig"));
}

test "route collision detection rejects index aliases and renamed parameters" {
    try std.testing.expect(routePatternsCollide("/foo", "/foo"));
    try std.testing.expect(routePatternsCollide("/users/:id", "/users/:slug"));
    try std.testing.expect(!routePatternsCollide("/users/settings", "/users/:id"));
    try std.testing.expect(routePatternsCollide("/users/:id/edit", "/users/new/:tab"));
    try std.testing.expect(!routePatternsCollide("/users/:id/edit", "/accounts/new/:tab"));
    try std.testing.expect(!routePatternsCollide("/users/:id/profile", "/users/:id"));

    try std.testing.expectError(error.DuplicateRoute, validateRoutePaths(std.testing.allocator, &.{
        "app/foo.zig",
        "app/foo/index.zig",
    }, false));
    try std.testing.expectError(error.DuplicateRoute, validateRoutePaths(std.testing.allocator, &.{
        "app/users/[id].zig",
        "app/users/[slug].zig",
    }, false));
    try std.testing.expectError(error.DuplicateIdentifier, validateRoutePaths(std.testing.allocator, &.{
        "app/foo-bar.zig",
        "app/foo_bar.zig",
    }, false));
    try std.testing.expectError(error.DuplicateRoute, validateRoutePaths(std.testing.allocator, &.{
        "app/users/[id]/edit.zig",
        "app/users/new/[tab].zig",
    }, false));
    try validateRoutePaths(std.testing.allocator, &.{
        "app/users/settings.zig",
        "app/users/[id].zig",
    }, false);
}
