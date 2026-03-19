// server.zig — HTTP server backbone (Zig 0.15).
// std.http.Server now takes *Io.Reader + *Io.Writer from a net.Stream.

const std = @import("std");
const mer = @import("mer");
const Router = @import("router.zig").Router;
const static = @import("static.zig");
const watcher_mod = @import("watcher.zig");

const log = std.log.scoped(.server);

/// Security headers applied to every page/API response.
pub const security_headers = [_]std.http.Header{
    .{ .name = "strict-transport-security", .value = "max-age=63072000; includeSubDomains; preload" },
    .{ .name = "content-security-policy", .value = "default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval' blob: https://cdn.jsdelivr.net https://unpkg.com https://static.cloudflareinsights.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://unpkg.com; font-src https://fonts.gstatic.com; img-src 'self' data: https://*.tile.openstreetmap.org https://*.basemaps.cartocdn.com https://unpkg.com; connect-src 'self' https://api.open-meteo.com https://cloudflareinsights.com https://api-open.data.gov.sg https://api-production.data.gov.sg https://cdn.jsdelivr.net https://unpkg.com https://nominatim.openstreetmap.org; frame-ancestors 'none'; base-uri 'self'; form-action 'self'" },
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "referrer-policy", .value = "strict-origin-when-cross-origin" },
    .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
    .{ .name = "permissions-policy", .value = "camera=(), microphone=(), geolocation=()" },
};

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3000,
    dev: bool = false,
    verbose: bool = false,
};

pub const Server = struct {
    config: Config,
    router: *const Router,
    watcher: ?*watcher_mod.Watcher,
    allocator: std.mem.Allocator,
    pool: std.Thread.Pool,

    pub fn init(
        allocator: std.mem.Allocator,
        config: Config,
        router: *const Router,
        watcher: ?*watcher_mod.Watcher,
    ) Server {
        return .{
            .allocator = allocator,
            .config = config,
            .router = router,
            .watcher = watcher,
            .pool = undefined,
        };
    }

    pub fn listen(self: *Server) !void {
        // Use CPU count * 2 for I/O-bound workloads (capped at reasonable max).
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const n_threads = @min(cpu_count * 2, 64);
        try self.pool.init(.{ .allocator = self.allocator, .n_jobs = @intCast(n_threads) });
        defer self.pool.deinit();

        // Init static file cache.
        static.initCache(self.allocator);

        const addr = try std.net.Address.parseIp(self.config.host, self.config.port);
        var net_server = try addr.listen(.{ .reuse_address = true, .kernel_backlog = 512 });
        defer net_server.deinit();

        log.info("merjs dev server -> http://{s}:{d} ({d} threads)", .{ self.config.host, self.config.port, n_threads });

        while (true) {
            const conn = net_server.accept() catch |err| {
                log.debug("accept: {}", .{err});
                continue;
            };
            const ctx = self.allocator.create(ConnCtx) catch {
                conn.stream.close();
                continue;
            };
            ctx.* = .{
                .conn = conn,
                .router = self.router,
                .watcher = self.watcher,
                .allocator = self.allocator,
                .dev = self.config.dev,
                .verbose = self.config.verbose,
            };
            self.pool.spawn(handleConn, .{ctx}) catch {
                ctx.allocator.destroy(ctx);
                conn.stream.close();
            };
        }
    }
};

const ConnCtx = struct {
    conn: std.net.Server.Connection,
    router: *const Router,
    watcher: ?*watcher_mod.Watcher,
    allocator: std.mem.Allocator,
    dev: bool,
    verbose: bool,
};

fn handleConn(ctx: *ConnCtx) void {
    defer ctx.allocator.destroy(ctx);
    defer ctx.conn.stream.close();

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var read_buf: [16384]u8 = undefined;
    var write_buf: [65536]u8 = undefined;
    var in = ctx.conn.stream.reader(&read_buf);
    var out = ctx.conn.stream.writer(&write_buf);
    var http_server = std.http.Server.init(in.interface(), &out.interface);

    while (true) {
        var std_req = http_server.receiveHead() catch |err| {
            if (err != error.HttpConnectionClosing and err != error.ReadFailed) {
                log.debug("receiveHead: {}", .{err});
            }
            return;
        };

        const start = std.time.nanoTimestamp();
        serveRequest(alloc, &std_req, ctx.router, ctx.watcher, ctx.dev, ctx.verbose) catch |err| {
            log.err("serveRequest: {}", .{err});
            return;
        };

        if (ctx.verbose) {
            const elapsed_ns = std.time.nanoTimestamp() - start;
            const elapsed_us: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1000.0;
            if (elapsed_us < 1000.0) {
                log.info("{s} {s} {d:.0}µs", .{ @tagName(std_req.head.method), std_req.head.target, elapsed_us });
            } else {
                log.info("{s} {s} {d:.1}ms", .{ @tagName(std_req.head.method), std_req.head.target, elapsed_us / 1000.0 });
            }
        }

        // Reset arena between requests on the same connection (keep-alive).
        _ = arena.reset(.retain_capacity);
    }
}

fn serveRequest(
    alloc: std.mem.Allocator,
    std_req: *std.http.Server.Request,
    router: *const Router,
    watcher: ?*watcher_mod.Watcher,
    dev: bool,
    verbose: bool,
) !void {
    _ = verbose;
    const raw_target = std_req.head.target;

    const path: []const u8 = if (std.mem.indexOfScalar(u8, raw_target, '?')) |q|
        raw_target[0..q]
    else
        raw_target;

    const query_string: []const u8 = if (std.mem.indexOfScalar(u8, raw_target, '?')) |q|
        if (q + 1 < raw_target.len) raw_target[q + 1 ..] else ""
    else
        "";

    // SSE hot-reload endpoint.
    if (dev and std.mem.eql(u8, path, "/_mer/events")) {
        if (watcher) |w| {
            watcher_mod.handleSse(w, alloc, std_req) catch |err| {
                log.err("SSE handler: {}", .{err});
            };
        }
        return;
    }

    // Debug endpoint — shows registered routes, config, memory.
    if (dev and std.mem.eql(u8, path, "/_mer/debug")) {
        var body: std.ArrayListUnmanaged(u8) = .{};
        const w = body.writer(alloc);
        try w.writeAll("<html><head><title>merjs debug</title><style>");
        try w.writeAll("body{font-family:monospace;max-width:720px;margin:2em auto;background:#1a1a2e;color:#e0e0e0}");
        try w.writeAll("h1{color:#64ffda}h2{color:#82b1ff;margin-top:1.5em}table{border-collapse:collapse;width:100%}");
        try w.writeAll("td,th{text-align:left;padding:4px 12px;border-bottom:1px solid #333}th{color:#aaa}");
        try w.writeAll("</style></head><body>");
        try w.writeAll("<h1>merjs debug</h1>");

        // Routes
        try w.writeAll("<h2>Routes</h2><table><tr><th>Path</th><th>Type</th></tr>");
        for (router.routes) |route| {
            const rtype: []const u8 = if (std.mem.startsWith(u8, route.path, "/api/")) "API" else "Page";
            try w.print("<tr><td>{s}</td><td>{s}</td></tr>", .{ route.path, rtype });
        }
        try w.writeAll("</table>");

        // Config
        try w.writeAll("<h2>Config</h2><table>");
        try w.print("<tr><td>Version</td><td>{s}</td></tr>", .{mer.version});
        try w.print("<tr><td>Zig</td><td>{s}</td></tr>", .{@import("builtin").zig_version_string});
        try w.print("<tr><td>Routes</td><td>{d} exact + {d} dynamic</td></tr>", .{ router.exact_map.count(), router.dynamic_routes.len });
        try w.writeAll("</table>");

        // Memory (GPA stats not available here, but we can show arena-level info)
        try w.writeAll("<h2>Hints</h2><ul>");
        try w.writeAll("<li>Run with <code>--verbose</code> to log per-request timing</li>");
        try w.writeAll("<li>Use <code>std.log.scoped(.mypage)</code> in page handlers for route-level logs</li>");
        try w.writeAll("<li><code>/_mer/events</code> — SSE hot reload stream</li>");
        try w.writeAll("</ul>");

        try w.writeAll("</body></html>");

        try sendResponse(std_req, mer.Response{
            .status = .ok,
            .body = body.items,
            .content_type = .html,
        });
        return;
    }

    // Static files from public/.
    if (static.tryServe(alloc, std_req, path)) |_| return;

    // Pre-rendered pages from dist/ (SSG).
    if (!dev) {
        if (tryServePrerendered(alloc, std_req, path)) |_| return;
    }

    // ── Build Request ──────────────────────────────────────────────────────

    const cookies_raw: []const u8 = blk: {
        var it = std_req.iterateHeaders();
        while (it.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "cookie")) break :blk hdr.value;
        }
        break :blk "";
    };

    const body_bytes: []const u8 = blk: {
        const cl = std_req.head.content_length orelse break :blk "";
        if (cl == 0) break :blk "";
        var transfer_buf: [4096]u8 = undefined;
        var br = std_req.server.reader.bodyReader(
            &transfer_buf,
            std_req.head.transfer_encoding,
            std_req.head.content_length,
        );
        break :blk br.allocRemaining(alloc, .limited(4 * 1024 * 1024)) catch "";
    };

    var req = mer.Request.init(alloc, mer.Method.fromStd(std_req.head.method), path);
    req.query_string = query_string;
    req.body = body_bytes;
    req.cookies_raw = cookies_raw;

    mer.h.setRenderAllocator(alloc);

    // ── Check for true streaming render (renderStream) ─────────────────────
    // If the matched route exports renderStream and we have a stream_layout,
    // use the Marko-style placeholder/resolve pattern.
    if (router.stream_layout) |stream_wrap| {
        const matched_route = router.findRoute(req.path);
        if (matched_route) |route| {
            if (route.render_stream) |stream_fn| {
                const parts = stream_wrap(alloc, req.path, route.meta);

                const fixed = [1]std.http.Header{
                    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                } ++ security_headers;

                var header_buf: [4096]u8 = undefined;
                var bw = try std_req.respondStreaming(&header_buf, .{
                    .respond_options = .{
                        .status = .ok,
                        .extra_headers = &fixed,
                    },
                });

                // Flush layout head immediately — browser starts rendering shell.
                try bw.writer.writeAll(parts.head);
                try bw.flush();

                // Create StreamWriter backed by the HTTP body writer.
                var stream_writer = mer.StreamWriter{
                    .allocator = alloc,
                    .ctx = @ptrCast(&bw),
                    .writeFn = &streamWriteImpl,
                    .flushFn = &streamFlushImpl,
                };

                // Call the page's streaming render — it writes placeholders,
                // fetches data, and resolves slots progressively.
                stream_fn(req, &stream_writer);

                // Flush tail + hot reload.
                if (dev) try bw.writer.writeAll(hot_reload_script);
                try bw.writer.writeAll(parts.tail);
                try bw.end();
                return;
            }
        }
    }

    // ── Shell-first streaming (non-Suspense) ───────────────────────────────
    const result = router.dispatchStreaming(req);
    var response = result.response;

    if (result.is_streaming) {
        var hot_reload_tail: []const u8 = "";
        if (dev) {
            hot_reload_tail = hot_reload_script;
        }

        const fixed = [1]std.http.Header{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        } ++ security_headers;

        var header_buf: [4096]u8 = undefined;
        var bw = try std_req.respondStreaming(&header_buf, .{
            .respond_options = .{
                .status = response.status,
                .extra_headers = &fixed,
            },
        });
        try bw.writer.writeAll(result.head);
        try bw.flush();
        try bw.writer.writeAll(result.body);
        try bw.flush();
        try bw.writer.writeAll(hot_reload_tail);
        try bw.writer.writeAll(result.tail);
        try bw.end();
        return;
    }

    // ── Non-streaming path ─────────────────────────────────────────────────
    var owned_body: ?[]u8 = null;
    if (dev and response.content_type == .html) {
        if (injectHotReload(alloc, response.body)) |injected| {
            owned_body = injected;
            response.body = injected;
        } else |_| {}
    }
    defer if (owned_body) |b| alloc.free(b);

    try sendResponse(std_req, response);
}

fn streamWriteImpl(ctx: *anyopaque, data: []const u8) void {
    const bw: *std.http.BodyWriter = @ptrCast(@alignCast(ctx));
    bw.writer.writeAll(data) catch {};
}

fn streamFlushImpl(ctx: *anyopaque) void {
    const bw: *std.http.BodyWriter = @ptrCast(@alignCast(ctx));
    bw.flush() catch {};
}

/// Maximum number of Set-Cookie headers we emit per response.
const MAX_COOKIES = 8;

fn sendResponse(std_req: *std.http.Server.Request, response: mer.Response) !void {
    // Format Set-Cookie header values on the stack.
    var cookie_val_bufs: [MAX_COOKIES][512]u8 = undefined;
    var cookie_headers: [MAX_COOKIES]std.http.Header = undefined;
    const n_cookies = @min(response.cookies.len, MAX_COOKIES);
    for (response.cookies[0..n_cookies], 0..) |ck, i| {
        cookie_headers[i] = .{
            .name = "set-cookie",
            .value = ck.headerValue(&cookie_val_bufs[i]),
        };
    }

    if (response.content_type == .redirect) {
        // Redirect: Location + optional Set-Cookie, no body, no security headers.
        var extra: [1 + MAX_COOKIES]std.http.Header = undefined;
        extra[0] = .{ .name = "location", .value = response.body };
        @memcpy(extra[1 .. 1 + n_cookies], cookie_headers[0..n_cookies]);

        var header_buf: [2048]u8 = undefined;
        var bw = try std_req.respondStreaming(&header_buf, .{
            .respond_options = .{
                .status = response.status,
                .extra_headers = extra[0 .. 1 + n_cookies],
            },
        });
        try bw.end();
        return;
    }

    // Normal response: content-type + security headers + optional Set-Cookie.
    const fixed = [1]std.http.Header{
        .{ .name = "content-type", .value = response.content_type.mime() },
    } ++ security_headers;

    var extra: [fixed.len + MAX_COOKIES]std.http.Header = undefined;
    @memcpy(extra[0..fixed.len], &fixed);
    @memcpy(extra[fixed.len .. fixed.len + n_cookies], cookie_headers[0..n_cookies]);

    var header_buf: [4096]u8 = undefined;
    var bw = try std_req.respondStreaming(&header_buf, .{
        .content_length = response.body.len,
        .respond_options = .{
            .status = response.status,
            .extra_headers = extra[0 .. fixed.len + n_cookies],
        },
    });
    try bw.writer.writeAll(response.body);
    try bw.end();
}

const hot_reload_script =
    \\<script>
    \\(function(){
    \\  const es = new EventSource('/_mer/events');
    \\  es.onmessage = () => location.reload();
    \\})();
    \\</script>
    \\</body>
;

/// Serve a pre-rendered HTML file from dist/ if it exists.
fn tryServePrerendered(
    alloc: std.mem.Allocator,
    std_req: *std.http.Server.Request,
    url_path: []const u8,
) ?void {
    const fs_path = if (std.mem.eql(u8, url_path, "/"))
        std.fmt.allocPrint(alloc, "dist/index.html", .{}) catch return null
    else blk: {
        const rel = if (url_path.len > 0 and url_path[0] == '/') url_path[1..] else url_path;
        break :blk std.fmt.allocPrint(alloc, "dist/{s}.html", .{rel}) catch return null;
    };
    defer alloc.free(fs_path);

    const file = std.fs.cwd().openFile(fs_path, .{}) catch return null;
    defer file.close();

    const body = file.readToEndAlloc(alloc, 10 * 1024 * 1024) catch return null;
    defer alloc.free(body);

    var header_buf: [512]u8 = undefined;
    var bw = std_req.respondStreaming(&header_buf, .{
        .content_length = body.len,
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        },
    }) catch return null;
    bw.writer.writeAll(body) catch return null;
    bw.end() catch return null;

    return {};
}

fn injectHotReload(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    const marker = "</body>";
    const idx = std.mem.lastIndexOf(u8, body, marker) orelse return error.NoBodyTag;
    const before = body[0..idx];
    const after = body[idx + marker.len ..];
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ before, hot_reload_script, after });
}
