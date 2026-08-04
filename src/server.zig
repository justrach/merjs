// server.zig — HTTP server backbone (Zig 0.16).
// std.http.Server now takes *Io.Reader + *Io.Writer from a net.Stream (with Io param).

const std = @import("std");
const mer = @import("mer");
const Router = @import("router.zig").Router;
const dispatch_mod = @import("dispatch.zig");
const static = @import("static.zig");
const security = @import("security.zig");
const watcher_mod = @import("watcher.zig");
const runtime = @import("runtime");
const telemetry = mer.telemetry;
const dev_mod = mer.dev;

const log = std.log.scoped(.server);

/// Thread-local TTFB tracking: set before serveRequest, read after first response write.
threadlocal var _request_start_ns: i128 = 0;
threadlocal var _ttfb_ns: i128 = 0;
threadlocal var _response_status: ?u16 = null;
threadlocal var _body_deadline: ?*std.atomic.Value(u64) = null;

fn markCommitted(status: std.http.Status) void {
    if (_response_status == null) _response_status = @intFromEnum(status);
}

/// Called internally by sendResponse/streaming paths to mark first-byte time.
pub fn markTtfb() void {
    if (_ttfb_ns == 0 and _request_start_ns != 0) {
        if (monotonicTimestamp()) |now| {
            if (now >= _request_start_ns) _ttfb_ns = now - _request_start_ns;
        }
    }
}

pub const production_csp = security.production_csp;
pub const development_csp = security.development_csp;

const stream_resolver_script =
    "(()=>{for(const s of document.querySelectorAll('template[data-mer-resolve]')){" ++
    "for(const p of document.querySelectorAll('[data-mer-placeholder]')){" ++
    "if(p.getAttribute('data-mer-placeholder')===s.getAttribute('data-mer-resolve')){" ++
    "p.replaceWith(s.content);s.remove();break}}}})();";

fn selectedCsp(config: Config) []const u8 {
    return config.content_security_policy orelse if (config.dev) development_csp else production_csp;
}

/// Passed (optional) to Server.listen() so callers can wait for the server
/// to be ready and read back the actual bound port (useful when port=0).
/// Uses std.atomic.Value(bool) since std.Thread.ResetEvent was removed in 0.16.
pub const ServerStop = struct {
    requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn request(self: *ServerStop) void {
        self.requested.store(true, .release);
    }

    pub fn isRequested(self: *const ServerStop) bool {
        return self.requested.load(.acquire);
    }
};

pub const ServerReady = struct {
    event: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    port: u16 = 0,

    /// Block until the server signals readiness.
    pub fn wait(self: *ServerReady) void {
        while (!self.event.load(.acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    /// Signal that the server is ready.
    pub fn set(self: *ServerReady) void {
        self.event.store(true, .release);
    }
};

pub const TargetMetadata = struct {
    raw_target: []const u8,
    path: []const u8,
    query_string: []const u8,
};

pub fn splitRequestTarget(head_target: []const u8) TargetMetadata {
    const query_index = std.mem.indexOfScalar(u8, head_target, '?');
    return .{
        .raw_target = head_target,
        .path = if (query_index) |q| head_target[0..q] else head_target,
        .query_string = if (query_index) |q|
            if (q + 1 < head_target.len) head_target[q + 1 ..] else ""
        else
            "",
    };
}

pub fn copyRequestTarget(alloc: std.mem.Allocator, head_target: []const u8) !TargetMetadata {
    const parsed = splitRequestTarget(head_target);
    const raw_target = try alloc.dupe(u8, parsed.raw_target);
    errdefer alloc.free(raw_target);
    const path = try alloc.dupe(u8, parsed.path);
    errdefer alloc.free(path);
    const query_string = try alloc.dupe(u8, parsed.query_string);
    return .{ .raw_target = raw_target, .path = path, .query_string = query_string };
}

pub fn isStaticMethod(method: std.http.Method) bool {
    return method == .GET or method == .HEAD;
}

pub fn shouldTryStaticFiles(has_exact_route: bool, method: std.http.Method, has_framed_body: bool) bool {
    return !has_exact_route and isStaticMethod(method) and !has_framed_body;
}

pub fn shouldTrySpaFallback(static_dir: ?[]const u8, has_route: bool, method: std.http.Method, has_framed_body: bool) bool {
    return static_dir != null and shouldTryStaticFiles(has_route, method, has_framed_body);
}

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3000,
    dev: bool = false,
    /// Deprecated compatibility fields; retained for source compatibility and ignored.
    debug: bool = false,
    kuri_port: u16 = 9222,
    /// Overrides the strict production policy (or the hot-reload-only dev policy).
    content_security_policy: ?[]const u8 = null,
    /// Bounds the process-wide static file cache. Oversized files bypass it.
    static_cache_limits: static.CacheLimits = .{},
    /// Hard cap for detached connection workers; excess accepts are closed.
    max_active_connections: usize = 1024,
    /// Kernel accept queue depth.
    kernel_backlog: u31 = 256,
    /// Deadline for the first request head on a connection.
    header_deadline_ms: u32 = 10_000,
    /// Deadline for each framed request body.
    body_deadline_ms: u32 = 30_000,
    /// Deadline while waiting for the next keep-alive request.
    keepalive_deadline_ms: u32 = 15_000,
    /// Deadline for socket writes, including streaming responses.
    write_deadline_ms: u32 = 30_000,
    /// Absolute limits are enforced by a watchdog and cannot be renewed by
    /// byte-at-a-time traffic. Zero disables the corresponding absolute limit.
    absolute_header_deadline_ms: u32 = 15_000,
    absolute_body_deadline_ms: u32 = 45_000,
    absolute_connection_deadline_ms: u32 = 120_000,
    /// Bounds work retained by one keep-alive connection.
    max_requests_per_connection: usize = 100,
    verbose: bool = false,
    /// If non-null, listen() sets .port to the actual bound port then signals .event.
    ready: ?*ServerReady = null,
    /// Cooperative shutdown for owner-joined servers. Requesting stop wakes a
    /// blocked accept; the owner must still join the listen thread.
    stop: ?*ServerStop = null,
    /// Static-file root directory (default "public"). Set to "dist" to serve a
    /// Vite/SSG build. When set, index.html is served at "/" and unknown paths
    /// fall back to index.html (SPA history fallback).
    static_dir: ?[]const u8 = null,
    /// Optional raw-handler hook, checked before routing/static. Use this to
    /// register long-lived endpoints that must own the connection (e.g. SSE)
    /// which normal API routes (returning a single `mer.Response`) cannot do.
    /// Boolean callbacks remain supported; result callbacks can also report
    /// the exact committed status.
    raw_handler: ?*const RawHandler = null,
};

/// Raw request handler: receives the live `std.http.Server.Request` so it can
/// call `respondStreaming` and hold the connection open (SSE, websockets).
/// `alloc` is a per-request arena; `io` is the runtime I/O instance.
pub const RawHandlerResult = struct {
    handled: bool,
    /// Status already committed by the handler, when known.
    status: ?std.http.Status = null,
};

pub const RawHandler = struct {
    ctx: *anyopaque,
    /// Existing boolean callbacks remain source-compatible.
    callback: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator, std_req: *std.http.Server.Request, io: std.Io) bool = null,
    /// New callbacks can report the exact committed status for telemetry.
    callback_result: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator, std_req: *std.http.Server.Request, io: std.Io) RawHandlerResult = null,
};

fn invokeRawHandler(rh: *const RawHandler, alloc: std.mem.Allocator, std_req: *std.http.Server.Request, io: std.Io) bool {
    mer.h.setRenderAllocator(alloc);
    if (rh.callback_result) |callback| {
        const result = callback(rh.ctx, alloc, std_req, io);
        if (result.status) |status| markCommitted(status);
        return result.handled;
    }
    if (rh.callback) |callback| return callback(rh.ctx, alloc, std_req, io);
    return false;
}

const OwnedConn = struct {
    thread: std.Thread,
    ctx: *ConnCtx,
};

fn shouldReapOwned(stopping: bool, completed: bool) bool {
    return stopping or completed;
}

const OwnedConnections = struct {
    mutex: std.atomic.Mutex = .unlocked,
    items: std.ArrayList(OwnedConn) = .empty,
    allocator: std.mem.Allocator,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn append(self: *OwnedConnections, conn: OwnedConn) !void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        try self.items.append(self.allocator, conn);
    }

    fn run(self: *OwnedConnections) void {
        while (true) {
            var reaped: ?OwnedConn = null;
            while (!self.mutex.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
            const stopping = self.stopping.load(.acquire);
            for (self.items.items, 0..) |conn, i| {
                if (stopping) conn.ctx.interrupt();
                if (shouldReapOwned(stopping, conn.ctx.completed.load(.acquire))) {
                    reaped = self.items.swapRemove(i);
                    break;
                }
            }
            const done = stopping and self.items.items.len == 0 and reaped == null;
            self.mutex.unlock();
            if (reaped) |conn| {
                conn.thread.join();
                self.allocator.destroy(conn.ctx);
            } else if (done) {
                return;
            } else {
                _ = std.Io.sleep(runtime.io, .fromMilliseconds(10), .awake) catch {};
            }
        }
    }

    fn deinit(self: *OwnedConnections) void {
        self.stopping.store(true, .release);
    }
};

const DeadlineRegistry = struct {
    mutex: std.atomic.Mutex = .unlocked,
    items: std.ArrayList(*ConnCtx) = .empty,
    allocator: std.mem.Allocator,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn register(self: *DeadlineRegistry, ctx: *ConnCtx) !void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        try self.items.append(self.allocator, ctx);
    }

    fn unregister(self: *DeadlineRegistry, ctx: *ConnCtx) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        for (self.items.items, 0..) |item, i| {
            if (item == ctx) {
                _ = self.items.swapRemove(i);
                return;
            }
        }
    }

    fn run(self: *DeadlineRegistry) void {
        while (!self.stopping.load(.acquire)) {
            const now = monotonicNanoseconds();
            while (!self.mutex.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
            for (self.items.items) |ctx| {
                if (absoluteDeadlineExpired(ctx.absolute_connection_deadline_ns, now) or
                    absoluteDeadlineExpired(ctx.absolute_phase_deadline_ns.load(.acquire), now))
                {
                    ctx.interrupt();
                }
            }
            self.mutex.unlock();
            _ = std.Io.sleep(runtime.io, .fromMilliseconds(10), .awake) catch {};
        }
    }

    fn deinit(self: *DeadlineRegistry) void {
        self.stopping.store(true, .release);
    }
};

fn serverThreadUpperBound(active_connections: usize, stoppable: bool) usize {
    return active_connections + 2 + @intFromBool(stoppable);
}

pub const Server = struct {
    config: Config,
    router: *const Router,
    watcher: ?*watcher_mod.Watcher,
    allocator: std.mem.Allocator,
    io: std.Io = undefined,
    active_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

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
        // Init static file cache.
        static.initCache(self.allocator, self.config.static_cache_limits);
        defer static.deinitCache();

        // Use shared runtime.io for all I/O (Threaded now, Evented for io_uring later)
        const io = runtime.io;
        self.io = io;
        const addr = try std.Io.net.IpAddress.parse(self.config.host, self.config.port);
        var net_server = try addr.listen(io, .{
            .reuse_address = true,
            .kernel_backlog = self.config.kernel_backlog,
        });
        defer net_server.deinit(io);

        // Signal readiness with actual bound port (supports port=0 for desktop/testing).
        if (self.config.ready) |r| {
            r.port = net_server.socket.address.getPort();
            r.set();
        }

        log.info("merjs dev server -> http://{s}:{d}", .{ self.config.host, net_server.socket.address.getPort() });

        var accept_done = std.atomic.Value(bool).init(false);
        const stop_monitor = if (self.config.stop) |stop|
            try std.Thread.spawn(.{}, monitorStop, .{ stop, net_server.socket, io, &accept_done })
        else
            null;
        defer {
            accept_done.store(true, .release);
            if (stop_monitor) |thread| thread.join();
        }

        var deadline_registry = DeadlineRegistry{ .allocator = self.allocator };
        const deadline_watchdog = try std.Thread.spawn(.{}, DeadlineRegistry.run, .{&deadline_registry});
        defer {
            deadline_registry.deinit();
            deadline_watchdog.join();
            deadline_registry.items.deinit(self.allocator);
        }

        var owned_connections = OwnedConnections{ .allocator = self.allocator };
        const reaper = try std.Thread.spawn(.{}, OwnedConnections.run, .{&owned_connections});
        defer {
            owned_connections.deinit();
            reaper.join();
            owned_connections.items.deinit(self.allocator);
        }

        while (true) {
            const stream = net_server.accept(io) catch |err| {
                if (self.config.stop) |stop| if (stop.isRequested()) break;
                log.debug("accept: {}", .{err});
                continue;
            };
            if (self.config.stop) |stop| {
                if (stop.isRequested()) {
                    stream.close(io);
                    break;
                }
            }
            if (!reserveConnection(&self.active_connections, self.config.max_active_connections)) {
                stream.close(io);
                continue;
            }
            const ctx = self.allocator.create(ConnCtx) catch {
                _ = self.active_connections.fetchSub(1, .release);
                stream.close(io);
                continue;
            };
            ctx.* = .{
                .stream = stream,
                .io = io,
                .router = self.router,
                .watcher = self.watcher,
                .allocator = self.allocator,
                .dev = self.config.dev,
                .csp = selectedCsp(self.config),
                .verbose = self.config.verbose,
                .static_dir = self.config.static_dir,
                .raw_handler = self.config.raw_handler,
                .deadline_registry = &deadline_registry,
                .active_connections = &self.active_connections,
                .header_deadline_ms = self.config.header_deadline_ms,
                .body_deadline_ms = self.config.body_deadline_ms,
                .keepalive_deadline_ms = self.config.keepalive_deadline_ms,
                .write_deadline_ms = self.config.write_deadline_ms,
                .absolute_header_deadline_ms = self.config.absolute_header_deadline_ms,
                .absolute_body_deadline_ms = self.config.absolute_body_deadline_ms,
                .absolute_connection_deadline_ns = deadlineAfter(monotonicNanoseconds(), self.config.absolute_connection_deadline_ms),
                .max_requests = self.config.max_requests_per_connection,
            };
            deadline_registry.register(ctx) catch {
                _ = self.active_connections.fetchSub(1, .release);
                ctx.allocator.destroy(ctx);
                stream.close(io);
                continue;
            };
            const t = std.Thread.spawn(.{}, handleConn, .{ctx}) catch |err| {
                deadline_registry.unregister(ctx);
                _ = self.active_connections.fetchSub(1, .release);
                ctx.allocator.destroy(ctx);
                stream.close(io);
                log.err("connection worker spawn failed at {d}/{d} active connections: {}", .{ self.active_connections.load(.acquire), self.config.max_active_connections, err });
                return err;
            };
            owned_connections.append(.{ .thread = t, .ctx = ctx }) catch |err| {
                // The worker already owns the stream: interrupt it, then join
                // before reclaiming its context. Only the worker closes the fd.
                ctx.interrupt();
                t.join();
                self.allocator.destroy(ctx);
                return err;
            };
        }
    }
};

fn monitorStop(stop: *ServerStop, socket: std.Io.net.Socket, io: std.Io, done: *std.atomic.Value(bool)) void {
    while (!done.load(.acquire) and !stop.isRequested()) {
        _ = std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    if (stop.isRequested() and !done.load(.acquire)) {
        const listener = std.Io.net.Stream{ .socket = socket };
        listener.shutdown(io, .both) catch {};
    }
}

fn reserveConnection(active: *std.atomic.Value(usize), limit: usize) bool {
    if (limit == 0) return false;
    var current = active.load(.acquire);
    while (current < limit) {
        if (active.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |actual| {
            current = actual;
        } else return true;
    }
    return false;
}

const ConnCtx = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    router: *const Router,
    watcher: ?*watcher_mod.Watcher,
    allocator: std.mem.Allocator,
    dev: bool,
    csp: []const u8,
    verbose: bool,
    static_dir: ?[]const u8,
    raw_handler: ?*const RawHandler,
    deadline_registry: *DeadlineRegistry,
    active_connections: *std.atomic.Value(usize),
    header_deadline_ms: u32,
    body_deadline_ms: u32,
    keepalive_deadline_ms: u32,
    write_deadline_ms: u32,
    absolute_header_deadline_ms: u32,
    absolute_body_deadline_ms: u32,
    absolute_connection_deadline_ns: u64,
    max_requests: usize,
    absolute_phase_deadline_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    socket_mutex: std.atomic.Mutex = .unlocked,
    final_close_started: bool = false,

    /// Wake blocked worker I/O without releasing the descriptor. Serialization
    /// with finalClose prevents shutdown from targeting a subsequently reused fd.
    fn interrupt(self: *ConnCtx) void {
        while (!self.socket_mutex.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
        defer self.socket_mutex.unlock();
        if (!self.final_close_started) self.stream.shutdown(self.io, .both) catch {};
    }

    /// The spawned connection worker is the sole owner of final descriptor close.
    fn finalClose(self: *ConnCtx) void {
        while (!self.socket_mutex.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
        defer self.socket_mutex.unlock();
        self.final_close_started = true;
        self.stream.close(self.io);
    }
};

fn handleConn(ctx: *ConnCtx) void {
    defer ctx.completed.store(true, .release);
    defer ctx.deadline_registry.unregister(ctx);
    defer ctx.finalClose();
    defer _ = ctx.active_connections.fetchSub(1, .release);

    var read_buf: [16384]u8 = undefined;
    var write_buf: [65536]u8 = undefined;
    // 0.16: Stream.reader/writer now take (stream, io, buffer).
    var in = ctx.stream.reader(ctx.io, &read_buf);
    var out = ctx.stream.writer(ctx.io, &write_buf);
    var http_server = std.http.Server.init(&in.interface, &out.interface);
    setSocketDeadline(ctx.stream, false, ctx.write_deadline_ms);

    for (0..ctx.max_requests) |request_index| {
        setSocketDeadline(ctx.stream, true, if (request_index == 0) ctx.header_deadline_ms else ctx.keepalive_deadline_ms);
        ctx.absolute_phase_deadline_ns.store(deadlineAfter(monotonicNanoseconds(), ctx.absolute_header_deadline_ms), .release);
        var std_req = http_server.receiveHead() catch |err| {
            if (err != error.HttpConnectionClosing and err != error.ReadFailed) {
                log.debug("receiveHead: {}", .{err});
            }
            return;
        };
        _request_start_ns = monotonicTimestamp() orelse 0;
        _ttfb_ns = 0;
        _response_status = null;
        if (rejectUnsupportedExpectation(&std_req, ctx.csp, &ctx.absolute_phase_deadline_ns) catch |err| {
            log.debug("send expectation failed response: {}", .{err});
            return;
        }) {
            _body_deadline = null;
            const end = monotonicTimestamp() orelse _request_start_ns;
            const elapsed_ns = if (end >= _request_start_ns) end - _request_start_ns else 0;
            telemetry.ddTiming(std_req.head.target, @tagName(std_req.head.method), _response_status orelse 417, @intCast(@divFloor(elapsed_ns, 1000)));
            return;
        }

        // A fresh arena returns large body pages to the backing allocator after
        // every request instead of retaining them for the keep-alive lifetime.
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const error_target = alloc.dupe(u8, std_req.head.target) catch "<unknown>";

        const start = _request_start_ns;
        var terminal = false;
        setSocketDeadline(ctx.stream, true, ctx.body_deadline_ms);
        if (requestHasFramedBody(&std_req)) {
            ctx.absolute_phase_deadline_ns.store(deadlineAfter(monotonicNanoseconds(), ctx.absolute_body_deadline_ms), .release);
            _body_deadline = &ctx.absolute_phase_deadline_ns;
        } else {
            ctx.absolute_phase_deadline_ns.store(0, .release);
            _body_deadline = null;
        }
        serveRequest(alloc, &std_req, ctx.stream.socket.address, ctx.router, ctx.watcher, ctx.dev, ctx.csp, ctx.verbose, ctx.io, ctx.static_dir, ctx.raw_handler) catch |err| {
            log.err("serveRequest: {}", .{err});
            // A streaming/static response may already be committed. Never send
            // an overlay or 500 that would corrupt it or route a fallback.
            if (_response_status == null) {
                if (ctx.dev) {
                    dev_mod.sendErrorOverlay(&std_req, error_target, err, mer.version, ctx.csp) catch {};
                    markCommitted(.internal_server_error);
                } else {
                    sendResponse(&std_req, mer.internalError("<h1>500 Internal Server Error</h1>"), std_req.head.method == .HEAD, ctx.csp) catch {};
                }
            }
            telemetry.sentryCapture(@errorName(err), error_target, mer.version);
            telemetry.ddError(error_target, @tagName(std_req.head.method), @errorName(err));
            terminal = true;
        };
        _body_deadline = null;
        ctx.absolute_phase_deadline_ns.store(0, .release);

        const end = monotonicTimestamp() orelse start;
        const elapsed_ns = if (end >= start) end - start else 0;
        const elapsed_us: u64 = @intCast(@divFloor(elapsed_ns, 1000));
        const ttfb_us: u64 = if (_ttfb_ns > 0) @intCast(@divFloor(_ttfb_ns, 1000)) else elapsed_us;
        const status = _response_status orelse 200;
        telemetry.ddTiming(error_target, @tagName(std_req.head.method), status, elapsed_us);

        if (ctx.verbose) {
            const elapsed_f: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1000.0;
            if (elapsed_f < 1000.0) {
                log.info("{s} {s} {d} {d:.0}us (ttfb: {d}us)", .{ @tagName(std_req.head.method), error_target, status, elapsed_f, ttfb_us });
            } else {
                log.info("{s} {s} {d} {d:.1}ms (ttfb: {d}us)", .{ @tagName(std_req.head.method), error_target, status, elapsed_f / 1000.0, ttfb_us });
            }
        }
        if (terminal) return;
    }
}

fn setSocketDeadline(stream: std.Io.net.Stream, receive: bool, milliseconds: u32) void {
    if (comptime @import("builtin").os.tag == .windows) {
        const ws = std.os.windows.ws2_32;
        var timeout = milliseconds;
        const option: u32 = if (receive) ws.SO.RCVTIMEO else ws.SO.SNDTIMEO;
        _ = std.c.setsockopt(stream.socket.handle, ws.SOL.SOCKET, option, &timeout, @sizeOf(@TypeOf(timeout)));
    } else {
        const seconds = milliseconds / 1000;
        const microseconds = (milliseconds % 1000) * 1000;
        const timeout = std.posix.timeval{ .sec = @intCast(seconds), .usec = @intCast(microseconds) };
        const option: u32 = if (receive) std.posix.SO.RCVTIMEO else std.posix.SO.SNDTIMEO;
        std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, option, std.mem.asBytes(&timeout)) catch {};
    }
}

/// Cross-platform monotonic timestamp for request durations.
fn monotonicTimestamp() ?i128 {
    return @as(i128, std.Io.Clock.awake.now(runtime.io).nanoseconds);
}

fn monotonicNanoseconds() u64 {
    return @intCast(@max(0, monotonicTimestamp() orelse 0));
}

pub fn deadlineAfter(start_ns: u64, milliseconds: u32) u64 {
    if (milliseconds == 0) return 0;
    return start_ns +| @as(u64, milliseconds) *| std.time.ns_per_ms;
}

pub fn absoluteDeadlineExpired(deadline_ns: u64, now_ns: u64) bool {
    return deadline_ns != 0 and now_ns >= deadline_ns;
}

pub fn peerIdentity(alloc: std.mem.Allocator, address: std.Io.net.IpAddress) ![]u8 {
    var peer = address;
    peer.setPort(0);
    return std.fmt.allocPrint(alloc, "{f}", .{peer});
}

const max_request_header_count = 64;
const max_request_header_bytes = 32 * 1024;

const CopiedRequestHeaders = struct {
    headers: []const std.http.Header,
    cookies_raw: []const u8,
};

fn requiresUniqueRequestHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-type") or
        std.ascii.eqlIgnoreCase(name, "origin") or
        std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "cookie");
}

const RequestHeaderAccumulator = struct {
    copied: std.ArrayList(std.http.Header) = .empty,
    cookies_raw: []const u8 = "",
    cookie_seen: bool = false,
    count: usize = 0,
    bytes: usize = 0,

    fn append(self: *RequestHeaderAccumulator, alloc: std.mem.Allocator, header: std.http.Header) !void {
        self.count += 1;
        if (self.count > max_request_header_count) return error.TooManyRequestHeaders;
        self.bytes = std.math.add(usize, self.bytes, header.name.len) catch return error.RequestHeadersTooLarge;
        self.bytes = std.math.add(usize, self.bytes, header.value.len) catch return error.RequestHeadersTooLarge;
        if (self.bytes > max_request_header_bytes) return error.RequestHeadersTooLarge;

        if (requiresUniqueRequestHeader(header.name)) {
            if (std.ascii.eqlIgnoreCase(header.name, "cookie")) {
                if (self.cookie_seen) return error.DuplicateRequestHeader;
            } else for (self.copied.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing.name, header.name)) return error.DuplicateRequestHeader;
            }
        }

        const value = try alloc.dupe(u8, header.value);
        if (std.ascii.eqlIgnoreCase(header.name, "cookie")) {
            self.cookies_raw = value;
            self.cookie_seen = true;
            return;
        }
        try self.copied.append(alloc, .{
            .name = try alloc.dupe(u8, header.name),
            .value = value,
        });
    }
};

fn copyRequestHeaders(alloc: std.mem.Allocator, std_req: *std.http.Server.Request) !CopiedRequestHeaders {
    var accumulator: RequestHeaderAccumulator = .{};
    var it = std_req.iterateHeaders();
    while (it.next()) |header| try accumulator.append(alloc, header);
    return .{
        .headers = try accumulator.copied.toOwnedSlice(alloc),
        .cookies_raw = accumulator.cookies_raw,
    };
}

fn serveRequest(
    alloc: std.mem.Allocator,
    std_req: *std.http.Server.Request,
    peer_address: std.Io.net.IpAddress,
    router: *const Router,
    watcher: ?*watcher_mod.Watcher,
    dev: bool,
    csp: []const u8,
    verbose: bool,
    io: std.Io,
    static_dir: ?[]const u8,
    raw_handler: ?*const RawHandler,
) !void {
    _ = verbose;
    // `std_req.head.target` is borrowed from std.http's head buffer. Zig 0.16
    // invalidates that string memory when the body reader is initialized, so
    // copy target-derived slices before any framed body is read.
    const target_meta = try copyRequestTarget(alloc, std_req.head.target);
    const path = target_meta.path;
    const query_string = target_meta.query_string;
    const std_method = std_req.head.method;
    const request_method = mer.Method.fromStd(std_method);
    const has_framed_body = requestHasFramedBody(std_req);

    // Raw handlers may render with h.* and therefore receive the current
    // request allocator before either compatible callback form is invoked.
    mer.h.setRenderAllocator(alloc);
    if (raw_handler) |rh| if (invokeRawHandler(rh, alloc, std_req, io)) return;

    // Same-origin external resolver keeps production streaming compatible with
    // the strict script-src policy without allowing inline scripts.
    if (std.mem.eql(u8, path, "/_mer/resolve.js") and isStaticMethod(std_method)) {
        if (has_framed_body) _ = try readRequestBody(alloc, std_req, csp);
        try sendResponse(std_req, mer.Response.init(.ok, .js, stream_resolver_script), std_method == .HEAD, csp);
        return;
    }

    // SSE hot-reload endpoint.
    if (dev and std.mem.eql(u8, path, "/_mer/events")) {
        if (has_framed_body) _ = try readRequestBody(alloc, std_req, csp);
        if (eventsEndpointStatus(std_method, has_framed_body, watcher != null)) |status| {
            if (status == .method_not_allowed) {
                try sendEventsMethodNotAllowed(std_req, std_method == .HEAD, csp);
            } else {
                try sendResponse(std_req, mer.text(status, switch (status) {
                    .bad_request => "request body not allowed",
                    .service_unavailable => "hot reload unavailable",
                    else => unreachable,
                }), std_method == .HEAD, csp);
            }
            return;
        }
        watcher_mod.handleSse(watcher.?, alloc, std_req, csp) catch |err| {
            log.err("SSE handler: {}", .{err});
        };
        return;
    }

    // Debug endpoint — shows registered routes, config, hints.
    if (dev and std.mem.eql(u8, path, "/_mer/debug")) {
        if (has_framed_body) _ = try readRequestBody(alloc, std_req, csp);
        const route_infos = alloc.alloc(dev_mod.RouteDebugInfo, router.routes.len) catch return error.OutOfMemory;
        for (router.routes, 0..) |route, i| route_infos[i] = .{ .path = route.path };
        const response = try dev_mod.serveDebug(alloc, route_infos, router.exact_map.count(), router.dynamic_routes.len, query_string, mer.version);
        try sendResponse(std_req, response, std_method == .HEAD, csp);
        return;
    }

    const has_exact_route = router.hasExactRoute(path);
    const has_route = router.findRoute(path) != null;

    // Exact routes win over static files, while physical assets still win over
    // broad dynamic routes such as /:slug. SPA fallback remains behind every
    // route match below, including dynamic routes.
    if (shouldTryStaticFiles(has_exact_route, std_method, has_framed_body)) {
        if (static_dir) |d| {
            if (std.mem.eql(u8, path, "/")) {
                switch (static.tryServe(alloc, std_req, path, io, .{ .dir = d, .spa = true, .dev = dev, .csp = csp, .on_commit = markCommitted })) {
                    .served => return,
                    .not_found => {},
                    .send_error => return error.StaticSendFailed,
                }
            } else switch (static.tryServe(alloc, std_req, path, io, .{ .dir = d, .spa = false, .dev = dev, .csp = csp, .on_commit = markCommitted })) {
                .served => return,
                .not_found => {},
                .send_error => return error.StaticSendFailed,
            }
        } else switch (static.tryServe(alloc, std_req, path, io, .{ .dev = dev, .csp = csp, .on_commit = markCommitted })) {
            .served => return,
            .not_found => {},
            .send_error => return error.StaticSendFailed,
        }
    }

    // Pre-rendered pages from dist/ (SSG) should win in production even when a
    // registered route exists for the path.
    if (!dev and isStaticMethod(std_method) and !has_framed_body) {
        switch (tryServePrerendered(alloc, std_req, path, io, csp)) {
            .served => return,
            .not_found => {},
            .send_error => return error.StaticSendFailed,
        }
    }

    // SPA history fallback only after proving no backend route matches.
    if (shouldTrySpaFallback(static_dir, has_route, std_method, has_framed_body)) {
        if (static_dir) |d| {
            switch (static.tryServe(alloc, std_req, path, io, .{ .dir = d, .spa = true, .dev = dev, .csp = csp, .on_commit = markCommitted })) {
                .served => return,
                .not_found => {},
                .send_error => return error.StaticSendFailed,
            }
        }
    }

    // ── Build Request ──────────────────────────────────────────────────────

    const copied_headers = copyRequestHeaders(alloc, std_req) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            if (has_framed_body) _ = try readRequestBody(alloc, std_req, csp);
            try sendResponse(std_req, mer.Response.init(
                .bad_request,
                .json,
                "{\"error\":\"invalid request headers\"}",
            ), std_method == .HEAD, csp);
            return;
        },
    };

    const body_bytes: []const u8 = try readRequestBody(alloc, std_req, csp);

    var req = mer.Request.init(alloc, request_method, path);
    req.query_string = query_string;
    req.body = body_bytes;
    req.cookies_raw = copied_headers.cookies_raw;
    req.headers = copied_headers.headers;
    req.client_identity = try peerIdentity(alloc, peer_address);

    mer.h.setRenderAllocator(alloc);

    // ── Check for true streaming render (renderStream) ─────────────────────
    // If the matched route exports renderStream and we have a stream_layout,
    // use the Marko-style placeholder/resolve pattern.
    if (router.stream_layout) |stream_wrap| {
        var matched_route = router.match(req) catch {
            try sendResponse(std_req, mer.internalError("<h1>500 Internal Server Error</h1>"), std_method == .HEAD, csp);
            return;
        };
        if (matched_route) |*matched| {
            defer matched.deinit();
            if (matched.route.render_stream) |stream_fn| {
                const parts = stream_wrap(alloc, req.path, matched.route.meta);
                defer parts.deinit();

                var fixed: [1 + security.header_count]std.http.Header = undefined;
                fixed[0] = .{ .name = "content-type", .value = "text/html; charset=utf-8" };
                const security_headers = security.headers(csp);
                @memcpy(fixed[1..], &security_headers);

                var header_buf: [4096]u8 = undefined;
                var bw = try std_req.respondStreaming(&header_buf, .{
                    .respond_options = .{
                        .status = .ok,
                        .extra_headers = &fixed,
                    },
                });
                markCommitted(.ok);
                if (std_method == .HEAD) {
                    markTtfb();
                    try bw.end();
                    return;
                }

                // Flush layout head immediately — browser starts rendering shell.
                // Flush layout head immediately — browser starts rendering shell.
                try bw.writer.writeAll(parts.head);
                markTtfb();
                try bw.flush();

                // Create StreamWriter backed by the HTTP body writer.
                var stream_ctx = NativeStreamCtx{ .body_writer = &bw };
                var stream_writer = mer.StreamWriter{
                    .allocator = alloc,
                    .ctx = &stream_ctx,
                    .writeFn = &streamWriteImpl,
                    .flushFn = &streamFlushImpl,
                    .failedFn = &streamFailedImpl,
                };

                // Call the page's streaming render — it writes placeholders,
                // fetches data, and resolves slots progressively.
                stream_fn(matched.request, &stream_writer);
                if (stream_writer.failed()) return error.StreamWriteFailed;

                // Flush tail + hot reload.
                if (dev) try bw.writer.writeAll(dev_mod.hot_reload_script);
                try bw.writer.writeAll(parts.tail);
                try bw.end();
                return;
            }
        }
    }

    // ── Shell-first streaming (non-Suspense) ───────────────────────────────
    const result = dispatch_mod.dispatchStreaming(router.*, req);
    defer result.deinitParts();
    var response = result.response;
    defer response.deinit();

    if (result.is_streaming) {
        var hot_reload_tail: []const u8 = "";
        if (dev) {
            hot_reload_tail = dev_mod.hot_reload_script;
        }

        var fixed: [1 + security.header_count]std.http.Header = undefined;
        fixed[0] = .{ .name = "content-type", .value = "text/html; charset=utf-8" };
        const security_headers = security.headers(csp);
        @memcpy(fixed[1..], &security_headers);

        var header_buf: [4096]u8 = undefined;
        var bw = try std_req.respondStreaming(&header_buf, .{
            .respond_options = .{
                .status = response.status,
                .extra_headers = &fixed,
            },
        });
        markCommitted(response.status);
        if (std_method == .HEAD) {
            markTtfb();
            try bw.end();
            return;
        }
        try bw.writer.writeAll(result.head);
        markTtfb();
        try bw.flush();
        try bw.writer.writeAll(result.body);
        try bw.flush();
        try bw.writer.writeAll(hot_reload_tail);
        try bw.writer.writeAll(result.tail);
        try bw.end();
        return;
    }

    // ── Non-streaming path ─────────────────────────────────────────────────
    if (dev and response.content_type == .html) injectHotReloadResponse(alloc, &response);

    try sendResponse(std_req, response, std_method == .HEAD, csp);
}

fn injectHotReloadResponse(alloc: std.mem.Allocator, response: *mer.Response) void {
    const injected = dev_mod.injectHotReload(alloc, response.body) catch return;
    response.replaceBodyOwned(alloc, injected);
}

fn eventsEndpointStatus(method: std.http.Method, has_framed_body: bool, has_watcher: bool) ?std.http.Status {
    if (method != .GET) return .method_not_allowed;
    if (has_framed_body) return .bad_request;
    if (!has_watcher) return .service_unavailable;
    return null;
}

fn requestHasFramedBody(std_req: *const std.http.Server.Request) bool {
    return switch (std_req.head.transfer_encoding) {
        .chunked => true,
        .none => if (std_req.head.content_length) |len| len > 0 else false,
    };
}

const max_request_body_bytes = 4 * 1024 * 1024;

fn readRequestBody(alloc: std.mem.Allocator, std_req: *std.http.Server.Request, csp: []const u8) ![]const u8 {
    defer if (_body_deadline) |deadline| {
        deadline.store(0, .release);
        _body_deadline = null;
    };
    // In Zig 0.16, receiveHead() only consumes headers. If the request is
    // framed with Content-Length or Transfer-Encoding: chunked, enter the
    // std.http body reader exactly once so payload bytes are consumed before
    // routing returns to the keep-alive receive loop. Reading the body consumes
    // the head buffer storage, so callers must copy any needed header/target
    // slices first.
    if (std_req.head.transfer_encoding == .none) {
        const len = std_req.head.content_length orelse return "";
        if (len == 0) return "";
        if (len > max_request_body_bytes) {
            try sendResponse(std_req, mer.text(.payload_too_large, "request body exceeds 4 MiB"), std_req.head.method == .HEAD, csp);
            return error.RequestBodyTooLarge;
        }
    }

    const should_flush_continue = std_req.head.expect != null;
    try std_req.writeExpectContinue();
    if (should_flush_continue) try std_req.server.out.flush();

    var transfer_buf: [4096]u8 = undefined;
    const reader = std_req.server.reader.bodyReader(
        &transfer_buf,
        std_req.head.transfer_encoding,
        std_req.head.content_length,
    );
    return reader.allocRemaining(alloc, .limited(max_request_body_bytes)) catch |err| switch (err) {
        error.StreamTooLong => {
            try sendResponse(std_req, mer.text(.payload_too_large, "request body exceeds 4 MiB"), std_req.head.method == .HEAD, csp);
            return error.RequestBodyTooLarge;
        },
        else => return err,
    };
}

const NativeStreamCtx = struct {
    body_writer: *std.http.BodyWriter,
    failed: bool = false,
};

fn streamWriteImpl(ctx: *anyopaque, data: []const u8) void {
    const stream: *NativeStreamCtx = @ptrCast(@alignCast(ctx));
    if (stream.failed) return;
    stream.body_writer.writer.writeAll(data) catch {
        stream.failed = true;
    };
}

fn streamFlushImpl(ctx: *anyopaque) void {
    const stream: *NativeStreamCtx = @ptrCast(@alignCast(ctx));
    if (stream.failed) return;
    stream.body_writer.flush() catch {
        stream.failed = true;
    };
}

fn streamFailedImpl(ctx: *anyopaque) bool {
    const stream: *NativeStreamCtx = @ptrCast(@alignCast(ctx));
    return stream.failed;
}

/// Maximum number of Set-Cookie headers we emit per response.
const MAX_COOKIES = 8;

fn eventsMethodNotAllowedHeaders(csp: []const u8) [2 + security.header_count]std.http.Header {
    var headers: [2 + security.header_count]std.http.Header = undefined;
    headers[0] = .{ .name = "content-type", .value = mer.ContentType.text.mime() };
    headers[1] = .{ .name = "allow", .value = "GET" };
    const security_headers = security.headers(csp);
    @memcpy(headers[2..], &security_headers);
    return headers;
}

fn sendEventsMethodNotAllowed(std_req: *std.http.Server.Request, is_head: bool, csp: []const u8) !void {
    const body = "GET required";
    const headers = eventsMethodNotAllowedHeaders(csp);
    var header_buf: [4096]u8 = undefined;
    var bw = try std_req.respondStreaming(&header_buf, .{
        .content_length = body.len,
        .respond_options = .{
            .status = .method_not_allowed,
            .extra_headers = &headers,
        },
    });
    markCommitted(.method_not_allowed);
    markTtfb();
    if (!is_head) try bw.writer.writeAll(body);
    try bw.end();
}

fn rejectUnsupportedExpectation(std_req: *std.http.Server.Request, csp: []const u8, absolute_phase_deadline_ns: *std.atomic.Value(u64)) !bool {
    const expect = std_req.head.expect orelse return false;
    if (std.ascii.eqlIgnoreCase(expect, "100-continue")) {
        std_req.head.expect = "100-continue";
        return false;
    }
    absolute_phase_deadline_ns.store(0, .release);
    try sendExpectationFailed(std_req, csp);
    return true;
}

fn sendExpectationFailed(std_req: *std.http.Server.Request, csp: []const u8) !void {
    // Do not read the body: a client waiting for 100 Continue may not send it.
    // Closing the connection makes the unconsumed body safe.
    std_req.head.expect = null;
    const body = "Expectation Failed";
    var headers: [1 + security.header_count]std.http.Header = undefined;
    headers[0] = .{ .name = "content-type", .value = "text/plain; charset=utf-8" };
    const security_headers = security.headers(csp);
    @memcpy(headers[1..], &security_headers);
    var header_buf: [4096]u8 = undefined;
    var bw = try std_req.respondStreaming(&header_buf, .{
        .content_length = body.len,
        .respond_options = .{
            .status = .expectation_failed,
            .keep_alive = false,
            .extra_headers = &headers,
        },
    });
    markCommitted(.expectation_failed);
    markTtfb();
    if (std_req.head.method != .HEAD) try bw.writer.writeAll(body);
    try bw.end();
}

fn sendResponse(std_req: *std.http.Server.Request, response: mer.Response, is_head: bool, csp: []const u8) !void {
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
        // Redirect: Location + security headers + optional Set-Cookie, no body.
        var extra: [1 + security.header_count + MAX_COOKIES]std.http.Header = undefined;
        extra[0] = .{ .name = "location", .value = response.body };
        const security_headers = security.headers(csp);
        @memcpy(extra[1 .. 1 + security.header_count], &security_headers);
        @memcpy(extra[1 + security.header_count .. 1 + security.header_count + n_cookies], cookie_headers[0..n_cookies]);

        var header_buf: [2048]u8 = undefined;
        var bw = try std_req.respondStreaming(&header_buf, .{
            .respond_options = .{
                .status = response.status,
                .extra_headers = extra[0 .. 1 + security.header_count + n_cookies],
            },
        });
        markCommitted(response.status);
        markTtfb();
        try bw.end();
        return;
    }

    // Normal response: content-type + security headers + optional Set-Cookie.
    var fixed: [1 + security.header_count]std.http.Header = undefined;
    fixed[0] = .{ .name = "content-type", .value = response.content_type.mime() };
    const security_headers = security.headers(csp);
    @memcpy(fixed[1..], &security_headers);

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
    markCommitted(response.status);
    markTtfb();
    if (!is_head) try bw.writer.writeAll(response.body);
    try bw.end();
}

/// Serve a pre-rendered HTML file from dist/ if it exists.
fn tryServePrerendered(
    alloc: std.mem.Allocator,
    std_req: *std.http.Server.Request,
    url_path: []const u8,
    io: std.Io,
    csp: []const u8,
) static.ServeResult {
    const file_name = if (std.mem.eql(u8, url_path, "/"))
        alloc.dupe(u8, "index.html") catch return .send_error
    else blk: {
        const rel = if (url_path.len > 0 and url_path[0] == '/') url_path[1..] else url_path;
        break :blk std.fmt.allocPrint(alloc, "{s}.html", .{rel}) catch return .send_error;
    };
    defer alloc.free(file_name);

    const file = switch (static.readContainedFileInFlight(alloc, io, "dist", file_name)) {
        .file => |file| file,
        .not_found => return .not_found,
        .send_error => return .send_error,
    };
    defer file.release();
    defer alloc.free(file.body);
    const body = file.body;

    var fixed: [2 + security.header_count]std.http.Header = undefined;
    fixed[0] = .{ .name = "content-type", .value = "text/html; charset=utf-8" };
    fixed[1] = .{ .name = "cache-control", .value = "no-cache" };
    const security_headers = security.headers(csp);
    @memcpy(fixed[2..], &security_headers);

    var header_buf: [2048]u8 = undefined;
    var bw = std_req.respondStreaming(&header_buf, .{
        .content_length = body.len,
        .respond_options = .{
            .status = .ok,
            .extra_headers = &fixed,
        },
    }) catch return .send_error;
    markCommitted(.ok);
    if (std_req.head.method != .HEAD) bw.writer.writeAll(body) catch return .send_error;
    bw.end() catch return .send_error;

    return .served;
}

test "dev hot reload replacement transfers response body ownership" {
    const alloc = std.testing.allocator;
    var response = mer.Response.init(.ok, .html, "");
    response.replaceBodyOwned(alloc, try alloc.dupe(u8, "<body>hello</body>"));
    defer response.deinit();

    injectHotReloadResponse(alloc, &response);
    try std.testing.expect(std.mem.indexOf(u8, response.body, dev_mod.hot_reload_script) != null);
}

test "dev events only streams bodyless GET requests with a watcher" {
    try std.testing.expectEqual(@as(?std.http.Status, null), eventsEndpointStatus(.GET, false, true));
    try std.testing.expectEqual(std.http.Status.method_not_allowed, eventsEndpointStatus(.POST, false, true).?);
    try std.testing.expectEqual(std.http.Status.method_not_allowed, eventsEndpointStatus(.HEAD, false, true).?);
    try std.testing.expectEqual(std.http.Status.bad_request, eventsEndpointStatus(.GET, true, true).?);
    try std.testing.expectEqual(std.http.Status.service_unavailable, eventsEndpointStatus(.GET, false, false).?);
}

test "dev events 405 advertises GET" {
    const headers = eventsMethodNotAllowedHeaders(development_csp);
    try std.testing.expectEqualStrings("allow", headers[1].name);
    try std.testing.expectEqualStrings("GET", headers[1].value);
}

test "absolute deadlines do not renew with activity" {
    const deadline = deadlineAfter(1_000, 25);
    try std.testing.expect(!absoluteDeadlineExpired(deadline, deadline - 1));
    try std.testing.expect(absoluteDeadlineExpired(deadline, deadline));
    try std.testing.expectEqual(@as(u64, 0), deadlineAfter(1_000, 0));
}

test "completed owned connections are selected for continuous reaping" {
    try std.testing.expect(!shouldReapOwned(false, false));
    try std.testing.expect(shouldReapOwned(false, true));
    try std.testing.expect(shouldReapOwned(true, false));
}

test "raw result callbacks receive render allocator and report committed status" {
    const Probe = struct {
        alloc: ?std.mem.Allocator = null,
        fn callback(ctx: *anyopaque, alloc: std.mem.Allocator, _: *std.http.Server.Request, _: std.Io) RawHandlerResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.alloc = alloc;
            return .{ .handled = true, .status = .accepted };
        }
    };
    var probe = Probe{};
    const handler = RawHandler{ .ctx = &probe, .callback_result = Probe.callback };
    var request: std.http.Server.Request = undefined;
    _response_status = null;
    try std.testing.expect(invokeRawHandler(&handler, std.testing.allocator, &request, runtime.io));
    try std.testing.expect(probe.alloc != null);
    try std.testing.expectEqual(@as(?u16, @intFromEnum(std.http.Status.accepted)), _response_status);
}

test "native HTTP head extraction preserves auth headers before body reads" {
    const wire =
        "POST /auth/sign-up/email HTTP/1.1\r\n" ++
        "Host: app.example.com\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Origin: https://app.example.com\r\n" ++
        "Authorization: Bearer test\r\n" ++
        "Cookie: session=abc\r\n" ++
        "Content-Length: 2\r\n\r\n{}";
    var input = std.Io.Reader.fixed(wire);
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var http_server = std.http.Server.init(&input, &output);
    var std_req = try http_server.receiveHead();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const copied = try copyRequestHeaders(arena.allocator(), &std_req);
    var req = mer.Request.init(arena.allocator(), .POST, "/auth/sign-up/email");
    req.headers = copied.headers;
    req.cookies_raw = copied.cookies_raw;
    try std.testing.expectEqualStrings("application/json", req.header("content-type").?);
    try std.testing.expectEqualStrings("https://app.example.com", req.header("origin").?);
    try std.testing.expectEqualStrings("Bearer test", req.header("authorization").?);
    try std.testing.expectEqualStrings("abc", req.cookie("session").?);
}

test "unsupported Expect rejects a body route before reading its body" {
    const wire =
        "POST /upload HTTP/1.1\r\n" ++
        "Host: app.example.com\r\n" ++
        "Expect: unsupported\r\n" ++
        "Content-Length: 4\r\n\r\n";
    var input = std.Io.Reader.fixed(wire);
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var http_server = std.http.Server.init(&input, &output);
    var std_req = try http_server.receiveHead();
    try std.testing.expect(requestHasFramedBody(&std_req));

    var absolute_phase_deadline_ns = std.atomic.Value(u64).init(1);
    try std.testing.expect(try rejectUnsupportedExpectation(&std_req, production_csp, &absolute_phase_deadline_ns));
    try std.testing.expectEqual(@as(u64, 0), absolute_phase_deadline_ns.load(.acquire));
    const response = output_buffer[0..output.end];
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 417 Expectation Failed\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, response, "100 Continue") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "connection: close\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, response, "Expectation Failed"));
}

test "conventional Expect 100-Continue is accepted" {
    const wire =
        "POST /upload HTTP/1.1\r\n" ++
        "Host: app.example.com\r\n" ++
        "Expect: 100-Continue\r\n" ++
        "Content-Length: 4\r\n\r\n";
    var input = std.Io.Reader.fixed(wire);
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var http_server = std.http.Server.init(&input, &output);
    var std_req = try http_server.receiveHead();
    var absolute_phase_deadline_ns = std.atomic.Value(u64).init(1);

    try std.testing.expect(!(try rejectUnsupportedExpectation(&std_req, production_csp, &absolute_phase_deadline_ns)));
    try std.testing.expectEqualStrings("100-continue", std_req.head.expect.?);
    try std_req.writeExpectContinue();
    try std.testing.expectEqual(@as(u64, 1), absolute_phase_deadline_ns.load(.acquire));
    try std.testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", output_buffer[0..output.end]);
}

test "unsupported Expect rejects a static GET with no framed body" {
    const wire =
        "GET /app.js HTTP/1.1\r\n" ++
        "Host: app.example.com\r\n" ++
        "Expect: unsupported\r\n\r\n";
    var input = std.Io.Reader.fixed(wire);
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var http_server = std.http.Server.init(&input, &output);
    var std_req = try http_server.receiveHead();
    try std.testing.expect(!requestHasFramedBody(&std_req));

    var absolute_phase_deadline_ns = std.atomic.Value(u64).init(1);
    try std.testing.expect(try rejectUnsupportedExpectation(&std_req, production_csp, &absolute_phase_deadline_ns));
    try std.testing.expectEqual(@as(u64, 0), absolute_phase_deadline_ns.load(.acquire));
    const response = output_buffer[0..output.end];
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 417 Expectation Failed\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, response, "100 Continue") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "connection: close\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, response, "Expectation Failed"));
}

test "native request headers are owned, bounded, and singleton auth headers stay unique" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var accumulator: RequestHeaderAccumulator = .{};
    var content_type = "application/json".*;
    try accumulator.append(alloc, .{ .name = "Content-Type", .value = &content_type });
    try accumulator.append(alloc, .{ .name = "Origin", .value = "https://app.example.com" });
    try accumulator.append(alloc, .{ .name = "Authorization", .value = "Bearer test" });
    try accumulator.append(alloc, .{ .name = "X-Request-ID", .value = "request-1" });
    try accumulator.append(alloc, .{ .name = "Cookie", .value = "session=abc" });
    @memset(&content_type, 'x');

    try std.testing.expectEqualStrings("application/json", accumulator.copied.items[0].value);
    try std.testing.expectEqualStrings("session=abc", accumulator.cookies_raw);
    try std.testing.expectError(error.DuplicateRequestHeader, accumulator.append(alloc, .{ .name = "origin", .value = "https://evil.example" }));
    try std.testing.expectError(error.DuplicateRequestHeader, accumulator.append(alloc, .{ .name = "authorization", .value = "Bearer other" }));
    try std.testing.expectError(error.DuplicateRequestHeader, accumulator.append(alloc, .{ .name = "cookie", .value = "other=1" }));

    var count_limited: RequestHeaderAccumulator = .{};
    for (0..max_request_header_count) |_| try count_limited.append(alloc, .{ .name = "X-Test", .value = "1" });
    try std.testing.expectError(error.TooManyRequestHeaders, count_limited.append(alloc, .{ .name = "X-Test", .value = "1" }));

    var byte_limited: RequestHeaderAccumulator = .{};
    const oversized = try alloc.alloc(u8, max_request_header_bytes + 1);
    try std.testing.expectError(error.RequestHeadersTooLarge, byte_limited.append(alloc, .{ .name = "X-Test", .value = oversized }));
}

test "native peer identity comes from the accepted socket address and ignores its port" {
    const first = try peerIdentity(std.testing.allocator, try std.Io.net.IpAddress.parse("203.0.113.7", 1234));
    defer std.testing.allocator.free(first);
    const second = try peerIdentity(std.testing.allocator, try std.Io.net.IpAddress.parse("203.0.113.7", 5678));
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "203.0.113.7") != null);
}

test "active connection reservations shed at the configured bound" {
    var active = std.atomic.Value(usize).init(0);
    try std.testing.expect(reserveConnection(&active, 2));
    try std.testing.expect(reserveConnection(&active, 2));
    try std.testing.expect(!reserveConnection(&active, 2));
    try std.testing.expectEqual(@as(usize, 2), active.load(.acquire));
    _ = active.fetchSub(1, .release);
    try std.testing.expect(reserveConnection(&active, 2));
    try std.testing.expect(!reserveConnection(&active, 0));
}

test "watchdog thread growth is N plus a constant and admits 1000 connections" {
    var active = std.atomic.Value(usize).init(0);
    for (0..1000) |_| try std.testing.expect(reserveConnection(&active, 1000));
    try std.testing.expect(!reserveConnection(&active, 1000));
    try std.testing.expectEqual(@as(usize, 1000), active.load(.acquire));

    // Workers are one-per-connection. The only server-level auxiliaries are
    // the deadline watchdog, reaper, and optional ServerStop monitor.
    try std.testing.expectEqual(@as(usize, 1002), serverThreadUpperBound(1000, false));
    try std.testing.expectEqual(@as(usize, 1003), serverThreadUpperBound(1000, true));
    try std.testing.expect(serverThreadUpperBound(1000, true) < 1024);
}

test "response status is recorded exactly once" {
    _response_status = null;
    markCommitted(.not_found);
    markCommitted(.internal_server_error);
    try std.testing.expectEqual(@as(?u16, 404), _response_status);
    _response_status = null;
}

test "per-request arenas release large bodies instead of retaining connection capacity" {
    for (0..3) |_| {
        var request_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const body = try request_arena.allocator().alloc(u8, 4 * 1024 * 1024);
        body[0] = 1;
        body[body.len - 1] = 1;
        request_arena.deinit();
    }
}

test "server limits have finite production defaults" {
    const config: Config = .{};
    try std.testing.expect(!config.debug);
    try std.testing.expectEqual(@as(u16, 9222), config.kuri_port);
    try std.testing.expect(config.max_active_connections >= 1000);
    try std.testing.expect(config.kernel_backlog > 0);
    try std.testing.expect(config.header_deadline_ms > 0);
    try std.testing.expect(config.body_deadline_ms > 0);
    try std.testing.expect(config.keepalive_deadline_ms > 0);
    try std.testing.expect(config.write_deadline_ms > 0);
    try std.testing.expect(config.absolute_header_deadline_ms > 0);
    try std.testing.expect(config.absolute_body_deadline_ms > 0);
    try std.testing.expect(config.absolute_connection_deadline_ms > 0);
    try std.testing.expect(config.max_requests_per_connection > 0);
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), max_request_body_bytes);
}

test "CSP selection uses strict production, explicit development, and override policies" {
    try std.testing.expectEqualStrings(production_csp, selectedCsp(.{}));
    try std.testing.expectEqualStrings(development_csp, selectedCsp(.{ .dev = true }));
    try std.testing.expectEqualStrings("default-src 'none'", selectedCsp(.{
        .dev = true,
        .content_security_policy = "default-src 'none'",
    }));
    try std.testing.expect(std.mem.indexOf(u8, production_csp, "script-src 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream_resolver_script, "data-mer-resolve") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream_resolver_script, "eval") == null);
}

test "copied request target survives source invalidation during body reads" {
    const alloc = std.testing.allocator;
    var head_buffer = "/api/echo?name=mer&debug=1".*;
    const meta = try copyRequestTarget(alloc, &head_buffer);
    defer alloc.free(meta.raw_target);
    defer alloc.free(meta.path);
    defer alloc.free(meta.query_string);

    // Initializing std.http's body reader reuses its head buffer. Overwriting
    // this stand-in proves all target-derived request metadata is independently
    // owned before that body read occurs.
    @memset(&head_buffer, 'x');
    try std.testing.expectEqualStrings("/api/echo?name=mer&debug=1", meta.raw_target);
    try std.testing.expectEqualStrings("/api/echo", meta.path);
    try std.testing.expectEqualStrings("name=mer&debug=1", meta.query_string);

    const empty_query = splitRequestTarget("/submit?");
    try std.testing.expectEqualStrings("/submit", empty_query.path);
    try std.testing.expectEqualStrings("", empty_query.query_string);
}

test "static files and SPA fallback do not shadow routes, methods, or request bodies" {
    try std.testing.expect(!shouldTryStaticFiles(true, .GET, false));
    try std.testing.expect(!shouldTryStaticFiles(false, .POST, false));
    try std.testing.expect(!shouldTryStaticFiles(false, .DELETE, false));
    try std.testing.expect(!shouldTryStaticFiles(false, .GET, true));
    try std.testing.expect(shouldTryStaticFiles(false, .GET, false));
    try std.testing.expect(shouldTryStaticFiles(false, .HEAD, false));
    try std.testing.expect(!shouldTrySpaFallback("dist", true, .GET, false));
    try std.testing.expect(!shouldTrySpaFallback("dist", false, .POST, false));
    try std.testing.expect(!shouldTrySpaFallback("dist", false, .DELETE, false));
    try std.testing.expect(!shouldTrySpaFallback("dist", false, .GET, true));
    try std.testing.expect(!shouldTrySpaFallback(null, false, .GET, false));
    try std.testing.expect(shouldTrySpaFallback("dist", false, .GET, false));
    try std.testing.expect(shouldTrySpaFallback("dist", false, .HEAD, false));
}
