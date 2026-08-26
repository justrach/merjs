// main.zig — CLI entry point.
// Usage:
//   zig build serve               (dev server on :3000, hot reload)
//   zig build serve -- --port 8080
//   zig build serve -- --no-dev   (disable hot reload)
//
// Environment variables (read after .env load, overridden by explicit flags):
//   PORT     — port to listen on (PaaS standard: Fly, Render, Railway, Heroku, Cloud Run).
//   HOST     — interface to bind. Defaults to 0.0.0.0 in non-dev, 127.0.0.1 in dev.
//   MERJS_DEV=0 — disable hot reload (equivalent to --no-dev).

const std = @import("std");
const mer = @import("mer");
const runtime = @import("runtime");

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try runtime.init(alloc, init.environ);
    defer runtime.deinit();
    runtime.logBackend();

    // 0.16: args come through init parameter.
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    // Load .env before threads start — safe to read without mutex after this.
    mer.loadDotenv(alloc);

    var config = mer.Config{
        .host = "127.0.0.1",
        .port = 3000,
        .dev = true,
    };

    // Env-var defaults (PaaS-friendly). Flags override these below.
    if (mer.env("MERJS_DEV")) |v| {
        if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false")) config.dev = false;
    }
    if (mer.env("PORT")) |v| {
        config.port = std.fmt.parseInt(u16, v, 10) catch |err| {
            log.err("invalid PORT={s}: {s}", .{ v, @errorName(err) });
            return err;
        };
    }
    if (mer.env("HOST")) |v| {
        config.host = v;
    }

    var do_prerender = false;
    var host_explicit = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            config.port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
            config.host = args[i + 1];
            host_explicit = true;
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
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            try printUsage();
            return;
        }
    }

    // In production (--no-dev) default to 0.0.0.0 so containers/PaaS work
    // out of the box. Dev mode keeps 127.0.0.1 to avoid LAN exposure.
    if (!config.dev and !host_explicit and mer.env("HOST") == null) {
        config.host = "0.0.0.0";
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

fn printUsage() !void {
    const out = std.Io.File.stdout();
    try out.writeStreamingAll(runtime.io,
        \\merjs — Next.js-style web framework written in Zig.
        \\
        \\Usage:
        \\  merjs [flags]
        \\
        \\Flags:
        \\  --host <addr>     Interface to bind. Default: 127.0.0.1 (dev), 0.0.0.0 (--no-dev).
        \\  --port <num>      Port to listen on. Default: 3000.
        \\  --no-dev          Disable hot reload + dev endpoints (production mode).
        \\  --verbose, -v     Log every request with timing.
        \\  --debug           Spawn kuri sidecar for browser automation.
        \\  --prerender       SSG: render pages to dist/ and exit.
        \\  --help, -h        Show this message.
        \\
        \\Environment variables (read from .env or process env):
        \\  PORT              Same as --port. Auto-injected by Fly, Render, Railway, Heroku, Cloud Run.
        \\  HOST              Same as --host.
        \\  MERJS_DEV=0       Same as --no-dev.
        \\
        \\Health endpoints (always available, prod-safe):
        \\  GET /_mer/health  Liveness probe — returns {"status":"ok"} JSON.
        \\  GET /_mer/ready   Readiness probe — same payload.
        \\
    );
}
