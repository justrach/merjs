// watcher.zig — file-change detection + SSE hot-reload.
// Polls file mtimes every 300ms. Notifies SSE clients on any change.

const std = @import("std");
const runtime = @import("runtime");

const PthreadMutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    pub fn lock(m: *PthreadMutex) void {
        _ = std.c.pthread_mutex_lock(&m.inner);
    }
    pub fn unlock(m: *PthreadMutex) void {
        _ = std.c.pthread_mutex_unlock(&m.inner);
    }
};
const log = std.log.scoped(.watcher);

pub const Client = struct {
    notified: std.atomic.Value(bool),

    pub fn init() Client {
        return .{ .notified = std.atomic.Value(bool).init(false) };
    }

    pub fn notify(self: *Client) void {
        self.notified.store(true, .release);
    }

    /// Spin-wait until notified (checks every 50ms).
    pub fn wait(self: *Client) void {
        while (!self.notified.load(.acquire)) {
            threadSleep(50 * std.time.ns_per_ms);
        }
    }
};

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    watch_dir: []const u8,
    clients: std.ArrayList(*Client),
    mutex: PthreadMutex,
    mtimes: std.StringHashMap(std.Io.Timestamp),
    io: std.Io,
    /// When true, a `zig build` is spawned on every change so compile errors
    /// can be surfaced in the browser (issue #44). Disabled automatically when
    /// there is no build.zig in the cwd (e.g. a deployed app without a toolchain).
    rebuild_on_change: bool,
    /// Captured stderr of the last failed `zig build`, or null on success.
    /// Guarded by `mutex`; owned by the watcher.
    build_error: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, watch_dir: []const u8) Watcher {
        return .{
            .allocator = allocator,
            .watch_dir = watch_dir,
            .clients = .empty,
            .mutex = .{},
            .mtimes = std.StringHashMap(std.Io.Timestamp).init(allocator),
            .io = runtime.io, // Use shared runtime.io instead of creating new Threaded
            .rebuild_on_change = true,
        };
    }

    pub fn deinit(self: *Watcher) void {
        self.clients.deinit(self.allocator);
        var it = self.mtimes.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.mtimes.deinit();
        if (self.build_error) |e| self.allocator.free(e);
    }

    pub fn addClient(self: *Watcher, client: *Client) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.clients.append(self.allocator, client);
    }

    /// Store the latest build result and wake all waiting SSE clients.
    /// Takes ownership of `err_log` (may be null on success).
    fn broadcast(self: *Watcher, err_log: ?[]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.build_error) |old| self.allocator.free(old);
        self.build_error = err_log;
        for (self.clients.items) |c| c.notify();
        self.clients.clearRetainingCapacity();
    }

    /// Spawn `zig build` and capture its stderr. Returns null when the build
    /// succeeds (or when rebuilding is not applicable), or an owned error log
    /// when the compile fails (issue #44).
    fn rebuild(self: *Watcher) ?[]u8 {
        if (!self.rebuild_on_change) return null;
        // Only rebuild inside a project root that has a build.zig.
        std.Io.Dir.cwd().access(self.io, "build.zig", .{}) catch return null;

        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "zig", "build", "--color", "off" },
        }) catch |err| {
            return std.fmt.allocPrint(
                self.allocator,
                "merjs: could not run `zig build`: {s}",
                .{@errorName(err)},
            ) catch null;
        };
        defer self.allocator.free(result.stdout);

        const failed = switch (result.term) {
            .exited => |code| code != 0,
            else => true,
        };
        if (failed) {
            log.err("rebuild failed — sending error overlay", .{});
            if (result.stderr.len == 0) {
                self.allocator.free(result.stderr);
                return self.allocator.dupe(u8, "zig build failed (no diagnostics captured)") catch null;
            }
            return result.stderr; // ownership transferred to caller
        }
        self.allocator.free(result.stderr);
        return null;
    }

    /// Poll loop — run in a background thread.
    pub fn run(self: *Watcher) void {
        while (true) {
            threadSleep(300 * std.time.ns_per_ms);
            if (self.pollOnce()) {
                log.info("change detected — rebuilding", .{});
                const err_log = self.rebuild();
                if (err_log == null) log.info("rebuild ok — reloading", .{});
                self.broadcast(err_log);
            }
        }
    }

    fn pollOnce(self: *Watcher) bool {
        var changed = false;
        var dir = std.Io.Dir.cwd().openDir(self.io, self.watch_dir, .{ .iterate = true }) catch return false;
        defer dir.close(self.io);

        var walker = dir.walk(self.allocator) catch return false;
        defer walker.deinit();

        while (walker.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const stat = dir.statFile(self.io, entry.path, .{}) catch continue;
            const mtime = stat.mtime;

            if (self.mtimes.get(entry.path)) |prev| {
                if (!std.meta.eql(mtime, prev)) {
                    self.mtimes.put(entry.path, mtime) catch {};
                    changed = true;
                }
            } else {
                const key = self.allocator.dupe(u8, entry.path) catch continue;
                self.mtimes.put(key, mtime) catch {};
            }
        }
        return changed;
    }
};

/// Handle GET /_mer/events — blocks until a file changes, then sends SSE reload.
pub fn handleSse(
    watcher: *Watcher,
    alloc: std.mem.Allocator,
    std_req: *std.http.Server.Request,
) !void {
    var header_buf: [512]u8 = undefined;
    var bw = try std_req.respondStreaming(&header_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "connection", .value = "keep-alive" },
            },
        },
    });

    // Ping so the browser knows the stream is live.
    try bw.writer.writeAll(": connected\n\n");
    try bw.flush();

    const client = try alloc.create(Client);
    defer alloc.destroy(client);
    client.* = Client.init();
    try watcher.addClient(client);

    // Block until the watcher fires.
    client.wait();

    // Copy the build result under the lock so we can release it before writing
    // to the (potentially slow) socket.
    watcher.mutex.lock();
    const err_copy: ?[]u8 = if (watcher.build_error) |e| (alloc.dupe(u8, e) catch null) else null;
    watcher.mutex.unlock();
    defer if (err_copy) |e| alloc.free(e);

    if (err_copy) |elog| {
        // Distinct SSE event type — the client renders a styled compile-error
        // overlay instead of patching the DOM (issue #44). Each log line is
        // emitted as its own `data:` field; EventSource rejoins them with "\n".
        try bw.writer.writeAll("event: builderror\n");
        var it = std.mem.splitScalar(u8, elog, '\n');
        while (it.next()) |line| {
            const clean = std.mem.trimEnd(u8, line, "\r");
            try bw.writer.writeAll("data: ");
            try bw.writer.writeAll(clean);
            try bw.writer.writeAll("\n");
        }
        try bw.writer.writeAll("\n");
    } else {
        try bw.writer.writeAll("data: reload\n\n");
    }
    try bw.end();
}

fn threadSleep(ns: u64) void {
    // Use Io.sleep with awake clock (monotonic, excludes system suspend time)
    _ = std.Io.sleep(runtime.io, .fromNanoseconds(ns), .awake) catch {};
}
