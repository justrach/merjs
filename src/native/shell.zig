// shell.zig — platform-agnostic native shell entry point.
//
// Spawns the merjs HTTP server on a loopback ephemeral port (port=0), waits for
// the ServerReady handshake to read back the bound port, then hands the URL to
// the platform backend (macos.zig) which opens a WebView window.
//
// This is the generalized product form of examples/desktop/main.zig:
//   - manifest-driven (window size/title, host/port, dev mode)
//   - runtime.io is initialized (the desktop spike forgot this — runtime.io was
//     undefined at runtime, crashing Server.listen)
//   - dev mode optionally starts the file watcher so /_mer/events SSE hot
//     reload works inside the native window.

const std = @import("std");
const mer = @import("mer");
const runtime = @import("runtime");
const manifest_mod = @import("manifest.zig");
const bridge = @import("bridge.zig");
const update = @import("update.zig");
const builtin = @import("builtin");

const log = std.log.scoped(.native);

/// Per-connection server context handed to the server thread.
const ServerCtx = struct {
    allocator: std.mem.Allocator,
    router: *const mer.Router,
    manifest: manifest_mod.Manifest,
    ready: mer.ServerReady = .{},
    stop: mer.ServerStop = .{},
    watcher: ?*mer.Watcher = null,
    static_dir: ?[]const u8 = null,
    raw_handler: ?*const mer.RawHandler = null,
};

fn runServer(ctx: *ServerCtx) void {
    var srv = mer.Server.init(ctx.allocator, .{
        .host = ctx.manifest.host,
        .port = ctx.manifest.port,
        .dev = ctx.manifest.dev,
        .ready = &ctx.ready,
        .stop = &ctx.stop,
        .static_dir = ctx.static_dir,
        .raw_handler = ctx.raw_handler,
    }, ctx.router, if (ctx.manifest.dev) ctx.watcher else null);
    srv.listen() catch |err| {
        log.err("server listen failed: {}", .{err});
        ctx.ready.set(); // unblock the main thread even on failure
    };
}

fn wakeServer(host: []const u8, port: u16) void {
    if (port == 0) return;
    const address = std.Io.net.IpAddress.parse(host, port) catch return;
    const stream = address.connect(runtime.io, .{ .mode = .stream }) catch return;
    stream.close(runtime.io);
}

fn createBridgeToken(allocator: std.mem.Allocator) ![]u8 {
    var random: [32]u8 = undefined;
    try runtime.io.randomSecure(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    return try allocator.dupe(u8, &hex);
}

fn normalizeBindHost(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') return host[1 .. host.len - 1];
    return host;
}

fn formatUrlHost(buf: []u8, host: []const u8) ![]const u8 {
    const normalized = normalizeBindHost(host);
    if (std.mem.indexOfScalar(u8, normalized, ':') != null) {
        return try std.fmt.bufPrint(buf, "[{s}]", .{normalized});
    }
    return try std.fmt.bufPrint(buf, "{s}", .{normalized});
}

fn isSafeRelativeStaticDir(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '~') return false;
    var start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == ':' or c == '\\' or c <= 0x1f or c == 0x7f) return false;
        if (c == '/') {
            const part = path[start..i];
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
            start = i + 1;
        }
    }
    const last = path[start..];
    return last.len > 0 and !std.mem.eql(u8, last, ".") and !std.mem.eql(u8, last, "..");
}

fn packagedResourcesDirFromExePath(allocator: std.mem.Allocator, exe_path: []const u8) !?[]u8 {
    const macos_dir = std.fs.path.dirname(exe_path) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(macos_dir), "MacOS")) return null;
    const contents_dir = std.fs.path.dirname(macos_dir) orelse return null;
    const app_dir = std.fs.path.dirname(contents_dir) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(contents_dir), "Contents") or
        !std.mem.endsWith(u8, app_dir, ".app")) return null;
    return try std.fs.path.join(allocator, &.{ contents_dir, "Resources" });
}

fn resolvePackagedResourcesDir(allocator: std.mem.Allocator) !?[]u8 {
    if (builtin.os.tag != .macos) return null;
    const exe_path = std.process.executablePathAlloc(runtime.io, allocator) catch return null;
    defer allocator.free(exe_path);
    return try packagedResourcesDirFromExePath(allocator, exe_path);
}

fn resolvePackagedStaticDir(allocator: std.mem.Allocator, configured_static_dir: ?[]const u8, resources_dir: ?[]const u8) !?[]u8 {
    const base = resources_dir orelse return if (configured_static_dir) |dir| try allocator.dupe(u8, dir) else null;
    const relative = configured_static_dir orelse "public";
    if (!isSafeRelativeStaticDir(relative)) return try allocator.dupe(u8, "__mer_invalid_static_dir__");
    const candidate = try std.fs.path.join(allocator, &.{ base, relative });
    std.Io.Dir.cwd().access(runtime.io, candidate, .{}) catch {
        allocator.free(candidate);
        return try allocator.dupe(u8, "__mer_missing_packaged_static_dir__");
    };
    return candidate;
}

fn resolveOpenPathRoots(allocator: std.mem.Allocator, roots: []const []const u8, resources_dir: ?[]const u8) ![][]const u8 {
    const resolved = try allocator.alloc([]const u8, roots.len);
    errdefer allocator.free(resolved);
    var initialized: usize = 0;
    errdefer for (resolved[0..initialized]) |root| allocator.free(root);

    for (roots, 0..) |root, i| {
        resolved[i] = if (resources_dir) |base|
            if (root.len == 0 or std.fs.path.isAbsolute(root)) try allocator.dupe(u8, root) else try std.fs.path.join(allocator, &.{ base, root })
        else
            try allocator.dupe(u8, root);
        initialized += 1;
    }
    return resolved;
}

fn freeOpenPathRoots(allocator: std.mem.Allocator, roots: []const []const u8) void {
    for (roots) |root| allocator.free(root);
    allocator.free(roots);
}

/// Options for `run`. Pass `.{}` for defaults (no raw handler and no custom commands).
pub const RunOpts = struct {
    /// Optional raw-request handler (e.g. SSE /events). Receives the live
    /// request so it can hold the connection open. See mer.RawHandler.
    raw_handler: ?*const mer.RawHandler = null,
    /// Optional app-provided static native bridge commands. These are validated
    /// by bridge.dispatch before any built-in or custom handler runs.
    commands: []const bridge.Command = &.{},
};

/// Run the native shell. Blocks until the window is closed.
///
/// `router` must outlive this call (it is borrowed by the server thread).
pub fn run(
    allocator: std.mem.Allocator,
    app_manifest: manifest_mod.Manifest,
    router: *const mer.Router,
    opts: RunOpts,
) !void {
    if (builtin.os.tag != .macos) {
        log.err("native shell currently supports macOS only; {s} backend is planned", .{@tagName(builtin.os.tag)});
        return error.UnsupportedPlatform;
    }

    // std.Io runtime must be initialized before Server.listen touches runtime.io.
    try runtime.init(allocator);
    defer runtime.deinit();
    mer.telemetry.init();
    defer mer.telemetry.deinit();

    if (!std.mem.eql(u8, app_manifest.web_engine, "system")) {
        log.err("web_engine='{s}' is not supported in this release (use \"system\")", .{app_manifest.web_engine});
        return error.UnsupportedWebEngine;
    }

    if (!manifest_mod.isLoopbackHost(app_manifest.host)) {
        log.err("native server host '{s}' is not loopback; use 127.0.0.1 for the hardened native shell", .{app_manifest.host});
        return error.UnsafeNativeHost;
    }
    const bind_host = normalizeBindHost(app_manifest.host);

    try update.validateFeedConfig(app_manifest.update);

    // Dev mode: start the file watcher so hot-reload SSE works in the window.
    var watcher: ?mer.Watcher = null;
    defer if (watcher) |*w| w.deinit();
    var watcher_thread: ?std.Thread = null;
    var watcher_joined = false;
    defer if (!watcher_joined) {
        if (watcher) |*w| w.stop();
        if (watcher_thread) |thread| thread.join();
    };
    if (app_manifest.dev) {
        watcher = mer.Watcher.init(allocator, app_manifest.watch_dir);
        watcher_thread = try std.Thread.spawn(.{}, mer.Watcher.run, .{&watcher.?});
        log.info("hot reload active — watching {s}/", .{app_manifest.watch_dir});
    }

    // AppKit requires the main thread. The shell retains ownership of both
    // background threads and joins them before any borrowed state is released.
    const resources_dir = try resolvePackagedResourcesDir(allocator);
    defer if (resources_dir) |dir| allocator.free(dir);
    const effective_static_dir = try resolvePackagedStaticDir(allocator, app_manifest.static_dir, resources_dir);
    defer if (effective_static_dir) |dir| allocator.free(dir);
    var ctx = ServerCtx{
        .allocator = allocator,
        .router = router,
        .manifest = app_manifest,
        .watcher = if (watcher) |*w| w else null,
        .static_dir = effective_static_dir,
        .raw_handler = opts.raw_handler,
    };
    ctx.manifest.host = bind_host;
    const server_thread = try std.Thread.spawn(.{}, runServer, .{&ctx});
    defer {
        if (watcher) |*w| w.stop();
        if (watcher_thread) |thread| thread.join();
        watcher_joined = true;
        ctx.stop.request();
        wakeServer(ctx.manifest.host, ctx.ready.port);
        server_thread.join();
    }

    // Block until the server is bound and ready.
    ctx.ready.wait();
    const port = ctx.ready.port;
    if (port == 0) return error.ServerFailed;
    log.info("merjs server ready on port {d}", .{port});

    // Build the loopback URL the WebView will load.
    var host_buf: [128]u8 = undefined;
    const url_host = try formatUrlHost(&host_buf, bind_host);
    var url_buf: [160]u8 = undefined;
    const url_z = try std.fmt.bufPrintZ(&url_buf, "http://{s}:{d}/", .{ url_host, port });

    const runtime_origin = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ url_host, port });
    defer allocator.free(runtime_origin);
    const allowed_origins = try allocator.alloc([]const u8, app_manifest.security.allowed_origins.len + 1);
    defer allocator.free(allowed_origins);
    allowed_origins[0] = runtime_origin;
    @memcpy(allowed_origins[1..], app_manifest.security.allowed_origins);

    // Bridge context (heap-allocated; outlives the blocking event loop). The
    // ObjC IMP reaches it via the macos backend's g_bridge_ctx global.
    const token = try createBridgeToken(allocator);
    defer allocator.free(token);
    if (!bridge.isValidBridgeToken(token)) return error.InvalidBridgeToken;
    const open_path_roots = try resolveOpenPathRoots(allocator, app_manifest.security.open.path_roots, resources_dir);
    defer freeOpenPathRoots(allocator, open_path_roots);
    const bctx = try allocator.create(bridge.Ctx);
    defer allocator.destroy(bctx);
    bctx.* = .{
        .allocator = allocator,
        .permissions = app_manifest.permissions,
        .allowed_origins = allowed_origins,
        .allowed_commands = app_manifest.security.bridge.allowed_commands,
        .command_origins = app_manifest.security.bridge.command_origins,
        .extra_commands = opts.commands,
        .bridge_token = token,
        .external_url_schemes = app_manifest.security.open.external_schemes,
        .open_path_roots = open_path_roots,
    };

    // Hand off to the platform backend (blocks on the event loop).
    switch (builtin.os.tag) {
        .macos => return @import("macos.zig").openWindow(url_z.ptr, app_manifest.window, bctx),
        else => unreachable, // guarded before any side effects above
    }
}

test "native loopback bind and URL hosts normalize IPv6 brackets" {
    try std.testing.expectEqualStrings("::1", normalizeBindHost("::1"));
    try std.testing.expectEqualStrings("::1", normalizeBindHost("[::1]"));
    try std.testing.expectEqualStrings("127.0.0.1", normalizeBindHost("127.0.0.1"));

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("[::1]", try formatUrlHost(&buf, "::1"));
    try std.testing.expectEqualStrings("[::1]", try formatUrlHost(&buf, "[::1]"));
    try std.testing.expectEqualStrings("127.0.0.1", try formatUrlHost(&buf, "127.0.0.1"));
}

test "packaged resource detection and open roots use Contents Resources" {
    const resources = (try packagedResourcesDirFromExePath(std.testing.allocator, "/Applications/Test.app/Contents/MacOS/test")).?;
    defer std.testing.allocator.free(resources);
    try std.testing.expectEqualStrings("/Applications/Test.app/Contents/Resources", resources);
    try std.testing.expectEqual(@as(?[]u8, null), try packagedResourcesDirFromExePath(std.testing.allocator, "/tmp/test"));

    const roots = try resolveOpenPathRoots(std.testing.allocator, &.{ "exports", "/tmp/shared" }, resources);
    defer freeOpenPathRoots(std.testing.allocator, roots);
    try std.testing.expectEqualStrings("/Applications/Test.app/Contents/Resources/exports", roots[0]);
    try std.testing.expectEqualStrings("/tmp/shared", roots[1]);
}

test "development open roots remain cwd relative" {
    const roots = try resolveOpenPathRoots(std.testing.allocator, &.{"exports"}, null);
    defer freeOpenPathRoots(std.testing.allocator, roots);
    try std.testing.expectEqualStrings("exports", roots[0]);
}
