// main.zig — app entry point.
// Usage:
//   zig build serve               (dev server on :3000, hot reload)
//   zig build serve -- --port 8080
//   zig build serve -- --no-dev   (disable hot reload)

const std = @import("std");
const mer = @import("mer");
const runtime = @import("runtime");

const log = std.log.scoped(.main);

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

    // Load .env before threads start.
    mer.loadDotenv(alloc);

    var config = mer.Config{
        .host = "127.0.0.1",
        .port = 3000,
        .dev = true,
    };

    var do_prerender = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            config.port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
            config.host = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--no-dev")) {
            config.dev = false;
        } else if (std.mem.eql(u8, args[i], "--debug")) {
            config.debug = true;
        } else if (std.mem.eql(u8, args[i], "--kuri-port") and i + 1 < args.len) {
            config.kuri_port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--verbose") or std.mem.eql(u8, args[i], "-v")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, args[i], "--prerender")) {
            do_prerender = true;
        }
    }

    // Build router from generated routes.
    var router = mer.Router.fromGenerated(alloc, @import("routes"));
    defer router.deinit();

    // SSG mode: pre-render pages to dist/ and exit.
    if (do_prerender) {
        try mer.runPrerender(alloc, &router);
        return;
    }

    // File watcher (dev mode only).
    var watcher = mer.Watcher.init(alloc, "app");
    defer watcher.deinit();

    if (config.dev) {
        const wt = try std.Thread.spawn(.{}, mer.Watcher.run, .{&watcher});
        wt.detach();
        log.info("hot reload active — watching app/", .{});
    }

    var server = mer.Server.init(alloc, config, &router, if (config.dev) &watcher else null);
    try server.listen();
}
