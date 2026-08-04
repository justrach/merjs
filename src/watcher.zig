// watcher.zig — file-change detection + SSE hot-reload.
// Polls file mtimes every 300ms. Notifies SSE clients on any change.

const std = @import("std");
const runtime = @import("runtime");
const security = @import("security.zig");

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

const sse_heartbeat_interval_ns = std.time.ns_per_s;
const sse_max_heartbeats = 120;

pub const Client = struct {
    notified: std.atomic.Value(bool),

    pub fn init() Client {
        return .{ .notified = std.atomic.Value(bool).init(false) };
    }

    pub fn notify(self: *Client) void {
        self.notified.store(true, .release);
    }

    /// Wait until notified or the bounded interval elapses.
    pub fn wait(self: *Client, timeout_ns: u64) bool {
        var remaining = timeout_ns;
        while (!self.notified.load(.acquire)) {
            if (remaining == 0) return false;
            const sleep_ns = @min(remaining, 50 * std.time.ns_per_ms);
            threadSleep(sleep_ns);
            remaining -= sleep_ns;
        }
        return true;
    }
};

fn awaitClient(client: *Client, interval_ns: u64, max_heartbeats: usize, heartbeat: anytype) !bool {
    for (0..max_heartbeats) |_| {
        if (client.wait(interval_ns)) return true;
        try heartbeat.send();
    }
    return client.notified.load(.acquire);
}

fn awaitRegisteredClient(watcher: *Watcher, client: *Client, interval_ns: u64, max_heartbeats: usize, heartbeat: anytype) !bool {
    defer watcher.removeClient(client);
    return awaitClient(client, interval_ns, max_heartbeats, heartbeat);
}

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    watch_dir: []const u8,
    clients: std.ArrayList(*Client),
    mutex: PthreadMutex,
    mtimes: std.StringHashMap(std.Io.Timestamp),
    io: std.Io,
    stopping: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, watch_dir: []const u8) Watcher {
        return .{
            .allocator = allocator,
            .watch_dir = watch_dir,
            .clients = .empty,
            .mutex = .{},
            .mtimes = std.StringHashMap(std.Io.Timestamp).init(allocator),
            .io = runtime.io, // Use shared runtime.io instead of creating new Threaded
            .stopping = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Watcher) void {
        self.clients.deinit(self.allocator);
        var it = self.mtimes.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.mtimes.deinit();
    }

    pub fn addClient(self: *Watcher, client: *Client) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping.load(.acquire)) {
            client.notify();
            return;
        }
        try self.clients.append(self.allocator, client);
    }

    fn removeClient(self: *Watcher, client: *Client) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.clients.items, 0..) |registered, i| {
            if (registered == client) {
                _ = self.clients.swapRemove(i);
                return;
            }
        }
    }

    fn broadcast(self: *Watcher) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.clients.items) |c| c.notify();
        self.clients.clearRetainingCapacity();
    }

    /// Wake clients and ask the poll loop to return. The owner must then join
    /// the thread before deinitializing the watcher or runtime.
    pub fn stop(self: *Watcher) void {
        self.stopping.store(true, .release);
        self.broadcast();
    }

    /// Poll loop — run in an owner-joined background thread.
    pub fn run(self: *Watcher) void {
        while (!self.stopping.load(.acquire)) {
            threadSleep(300 * std.time.ns_per_ms);
            if (self.stopping.load(.acquire)) break;
            if (self.pollOnce()) {
                log.info("change detected — reloading", .{});
                self.broadcast();
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
    csp: []const u8,
) !void {
    var extra: [3 + security.header_count]std.http.Header = undefined;
    extra[0] = .{ .name = "content-type", .value = "text/event-stream" };
    extra[1] = .{ .name = "cache-control", .value = "no-cache" };
    extra[2] = .{ .name = "connection", .value = "keep-alive" };
    const security_headers = security.headers(csp);
    @memcpy(extra[3..], &security_headers);

    var header_buf: [2048]u8 = undefined;
    var bw = try std_req.respondStreaming(&header_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &extra,
        },
    });

    // Ping so the browser knows the stream is live.
    try bw.writer.writeAll(": connected\n\n");
    try bw.flush();

    const client = try alloc.create(Client);
    defer alloc.destroy(client);
    client.* = Client.init();
    try watcher.addClient(client);

    const Heartbeat = struct {
        body_writer: *std.http.BodyWriter,

        fn send(self: *@This()) !void {
            try self.body_writer.writer.writeAll(": heartbeat\n\n");
            try self.body_writer.flush();
        }
    };
    var heartbeat = Heartbeat{ .body_writer = &bw };

    // Periodic writes discover peer/watchdog closure without a file change.
    if (try awaitRegisteredClient(watcher, client, sse_heartbeat_interval_ns, sse_max_heartbeats, &heartbeat)) {
        try bw.writer.writeAll("data: reload\n\n");
    }
    try bw.end();
}

fn threadSleep(ns: u64) void {
    // Use Io.sleep with awake clock (monotonic, excludes system suspend time)
    _ = std.Io.sleep(runtime.io, .fromNanoseconds(ns), .awake) catch {};
}

test "disconnected SSE client is removed without a watcher event" {
    const Disconnected = struct {
        calls: usize = 0,

        fn send(self: *@This()) !void {
            self.calls += 1;
            return error.Disconnected;
        }
    };

    var watcher = Watcher.init(std.testing.allocator, ".");
    defer watcher.deinit();
    var client = Client.init();
    try watcher.addClient(&client);
    var disconnected = Disconnected{};

    try std.testing.expectError(
        error.Disconnected,
        awaitRegisteredClient(&watcher, &client, 0, 1, &disconnected),
    );
    try std.testing.expectEqual(@as(usize, 1), disconnected.calls);
    try std.testing.expectEqual(@as(usize, 0), watcher.clients.items.len);
}

test "SSE client lifetime is bounded without a watcher event" {
    const Heartbeat = struct {
        calls: usize = 0,

        fn send(self: *@This()) !void {
            self.calls += 1;
        }
    };

    var watcher = Watcher.init(std.testing.allocator, ".");
    defer watcher.deinit();
    var client = Client.init();
    try watcher.addClient(&client);
    var heartbeat = Heartbeat{};

    try std.testing.expect(!try awaitRegisteredClient(&watcher, &client, 0, 2, &heartbeat));
    try std.testing.expectEqual(@as(usize, 2), heartbeat.calls);
    try std.testing.expectEqual(@as(usize, 0), watcher.clients.items.len);
}
