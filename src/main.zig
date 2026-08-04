// main.zig — CLI entry point.
// Usage:
//   zig build serve               (dev server on :3000, hot reload)
//   zig build serve -- --port 8080
//   zig build serve -- --no-dev   (disable hot reload)

const std = @import("std");
const mer = @import("mer");
const runtime = @import("runtime");

const log = std.log.scoped(.main);

// The repository demo intentionally embeds inline examples, browser WASM, fonts,
// maps, and public APIs. Applications should grant only the origins they use.
const demo_csp = "default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval' blob: https://cdn.jsdelivr.net https://unpkg.com https://static.cloudflareinsights.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://unpkg.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: https://*.tile.openstreetmap.org https://*.basemaps.cartocdn.com https://unpkg.com; connect-src 'self' https://api.open-meteo.com https://cloudflareinsights.com https://api-open.data.gov.sg https://api-production.data.gov.sg https://cdn.jsdelivr.net https://unpkg.com https://nominatim.openstreetmap.org; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'";

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Initialize std.Io runtime (Threaded on Zig 0.16-supported targets).
    try runtime.init(alloc);
    defer runtime.deinit();

    // 0.16: args come through init parameter.
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    // Load .env before threads start.
    _ = try mer.loadDotenvStatus(alloc);
    defer mer.deinitDotenv();
    mer.telemetry.init();
    defer mer.telemetry.deinit();

    var config = mer.Config{
        .host = "127.0.0.1",
        .port = 3000,
        .dev = true,
        .content_security_policy = demo_csp,
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
        } else if (std.mem.eql(u8, args[i], "--debug") or std.mem.eql(u8, args[i], "--kuri-port")) {
            log.err("{s} was removed with the disabled browser automation integration", .{args[i]});
            return error.RemovedBrowserAutomationOption;
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

    var watcher_thread: ?std.Thread = null;
    if (config.dev) {
        watcher_thread = try std.Thread.spawn(.{}, mer.Watcher.run, .{&watcher});
        log.info("hot reload active — watching app/", .{});
    }
    defer if (watcher_thread) |thread| {
        watcher.stop();
        thread.join();
    };

    var server = mer.Server.init(alloc, config, &router, if (config.dev) &watcher else null);
    try server.listen();
}
