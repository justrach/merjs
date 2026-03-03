// server.zig — HTTP server backbone (Zig 0.15).
// std.http.Server now takes *Io.Reader + *Io.Writer from a net.Stream.

const std = @import("std");
const mer = @import("mer");
const Router = @import("router.zig").Router;
const static = @import("static.zig");
const watcher_mod = @import("watcher.zig");

const log = std.log.scoped(.server);

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3000,
    dev: bool = false,
};

pub const Server = struct {
    config: Config,
    router: *const Router,
    watcher: ?*watcher_mod.Watcher,
    allocator: std.mem.Allocator,

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
        };
    }

    pub fn listen(self: *Server) !void {
        const addr = try std.net.Address.parseIp(self.config.host, self.config.port);
        var net_server = try addr.listen(.{ .reuse_address = true });
        defer net_server.deinit();

        log.info("merjs dev server -> http://{s}:{d}", .{ self.config.host, self.config.port });

        while (true) {
            const conn = try net_server.accept();
            const ctx = try self.allocator.create(ConnCtx);
            ctx.* = .{
                .conn = conn,
                .router = self.router,
                .watcher = self.watcher,
                .allocator = self.allocator,
                .dev = self.config.dev,
            };
            const thread = try std.Thread.spawn(.{}, handleConn, .{ctx});
            thread.detach();
        }
    }
};

const ConnCtx = struct {
    conn: std.net.Server.Connection,
    router: *const Router,
    watcher: ?*watcher_mod.Watcher,
    allocator: std.mem.Allocator,
    dev: bool,
};

fn handleConn(ctx: *ConnCtx) void {
    defer ctx.allocator.destroy(ctx);
    defer ctx.conn.stream.close();

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Zig 0.15: net.Stream.reader/writer return typed wrappers;
    // call .interface() to get the *Io.Reader / *Io.Writer http.Server needs.
    var read_buf: [8192]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var in = ctx.conn.stream.reader(&read_buf);
    var out = ctx.conn.stream.writer(&write_buf);
    var http_server = std.http.Server.init(in.interface(), &out.interface);

    while (true) {
        var std_req = http_server.receiveHead() catch |err| {
            if (err != error.HttpConnectionClosing) {
                log.debug("receiveHead: {}", .{err});
            }
            return;
        };

        serveRequest(alloc, &std_req, ctx.router, ctx.watcher, ctx.dev) catch |err| {
            log.err("serveRequest: {}", .{err});
            return;
        };
    }
}

fn serveRequest(
    alloc: std.mem.Allocator,
    std_req: *std.http.Server.Request,
    router: *const Router,
    watcher: ?*watcher_mod.Watcher,
    dev: bool,
) !void {
    const raw_path = std_req.head.target;
    const path = if (std.mem.indexOfScalar(u8, raw_path, '?')) |q|
        raw_path[0..q]
    else
        raw_path;

    // SSE hot-reload endpoint.
    if (dev and std.mem.eql(u8, path, "/_mer/events")) {
        if (watcher) |w| {
            watcher_mod.handleSse(w, alloc, std_req) catch |err| {
                log.err("SSE handler: {}", .{err});
            };
        }
        return;
    }

    // Static files from public/.
    if (static.tryServe(alloc, std_req, path)) |_| return;

    // Page router.
    const req = mer.Request.init(alloc, mer.Method.fromStd(std_req.head.method), path);
    var response = router.dispatch(req);

    // Dev mode: inject hot-reload script before </body>.
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

fn sendResponse(std_req: *std.http.Server.Request, response: anytype) !void {
    var header_buf: [512]u8 = undefined;
    var bw = try std_req.respondStreaming(&header_buf, .{
        .respond_options = .{
            .status = response.status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = response.content_type.mime() },
            },
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

fn injectHotReload(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    const marker = "</body>";
    const idx = std.mem.lastIndexOf(u8, body, marker) orelse return error.NoBodyTag;
    const before = body[0..idx];
    const after = body[idx + marker.len ..];
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ before, hot_reload_script, after });
}
