// metrics.zig — bounded, thread-safe request metrics for the dev dashboard.
//
// Records the last `capacity` requests in a ring buffer and computes TTFB /
// duration aggregates (avg, p50/p95/p99) plus a per-route breakdown. Surfaced
// on /_mer/debug (see dev.zig). Recording is gated to dev mode by the caller so
// production pays zero overhead.
//
// Only imports std — safe to import from both server.zig and dev.zig without
// creating an import cycle.

const std = @import("std");

// Zig 0.16+ removed std.Thread.Mutex; use a pthread-backed shim (same pattern
// as static.zig / watcher.zig).
const PthreadMutex = struct {
    inner: std.c.pthread_mutex_t = .{},
    pub fn lock(m: *PthreadMutex) void {
        _ = std.c.pthread_mutex_lock(&m.inner);
    }
    pub fn unlock(m: *PthreadMutex) void {
        _ = std.c.pthread_mutex_unlock(&m.inner);
    }
};

/// Number of recent requests retained in the ring buffer.
pub const capacity = 256;

/// One recorded request. The path is copied into a fixed inline buffer so the
/// sample never dangles after the per-request arena is reset.
const Sample = struct {
    path_buf: [96]u8 = undefined,
    path_len: u8 = 0,
    ttfb_us: u32 = 0,
    duration_us: u32 = 0,
    status: u16 = 0,

    fn path(self: *const Sample) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

var mutex: PthreadMutex = .{};
var buffer: [capacity]Sample = undefined;
var head: usize = 0; // next write index
var count: usize = 0; // number of valid samples (<= capacity)
var total: u64 = 0; // lifetime request count

/// Record a completed request. Cheap: one mutex lock + a small memcpy.
pub fn record(path_str: []const u8, status: u16, ttfb_us: u64, duration_us: u64) void {
    mutex.lock();
    defer mutex.unlock();

    const s = &buffer[head];
    const n = @min(path_str.len, s.path_buf.len);
    @memcpy(s.path_buf[0..n], path_str[0..n]);
    s.path_len = @intCast(n);
    s.status = status;
    s.ttfb_us = std.math.cast(u32, ttfb_us) orelse std.math.maxInt(u32);
    s.duration_us = std.math.cast(u32, duration_us) orelse std.math.maxInt(u32);

    head = (head + 1) % capacity;
    if (count < capacity) count += 1;
    total += 1;
}

/// Aggregate stats for one measured quantity (all values in microseconds).
pub const Stat = struct {
    avg: u64 = 0,
    p50: u32 = 0,
    p95: u32 = 0,
    p99: u32 = 0,
    max: u32 = 0,
};

pub const RouteStat = struct {
    path: []const u8,
    count: usize,
    avg_ttfb_us: u64,
    avg_duration_us: u64,
};

pub const Report = struct {
    total_requests: u64,
    window: usize,
    ttfb: Stat,
    duration: Stat,
    routes: []RouteStat,
};

/// Snapshot the ring buffer and compute a full report. All returned memory is
/// allocated from `alloc` (typically the per-request arena).
pub fn collect(alloc: std.mem.Allocator) !Report {
    var samples: [capacity]Sample = undefined;
    var n: usize = 0;
    var total_snapshot: u64 = 0;
    {
        mutex.lock();
        defer mutex.unlock();
        n = count;
        total_snapshot = total;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            // Walk backwards from the most recent write.
            const idx = (head + capacity - 1 - i) % capacity;
            samples[i] = buffer[idx];
        }
    }

    if (n == 0) {
        return .{
            .total_requests = total_snapshot,
            .window = 0,
            .ttfb = .{},
            .duration = .{},
            .routes = &.{},
        };
    }

    const ttfbs = try alloc.alloc(u32, n);
    const durs = try alloc.alloc(u32, n);
    for (samples[0..n], 0..) |s, i| {
        ttfbs[i] = s.ttfb_us;
        durs[i] = s.duration_us;
    }

    // Per-route aggregation (recent window).
    var routes_map = std.StringHashMap(RouteAccum).init(alloc);
    defer routes_map.deinit();
    for (samples[0..n]) |s| {
        const gop = try routes_map.getOrPut(s.path());
        if (!gop.found_existing) {
            gop.key_ptr.* = try alloc.dupe(u8, s.path());
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.count += 1;
        gop.value_ptr.sum_ttfb += s.ttfb_us;
        gop.value_ptr.sum_dur += s.duration_us;
    }

    var routes = try alloc.alloc(RouteStat, routes_map.count());
    var it = routes_map.iterator();
    var ri: usize = 0;
    while (it.next()) |e| : (ri += 1) {
        const a = e.value_ptr.*;
        routes[ri] = .{
            .path = e.key_ptr.*,
            .count = a.count,
            .avg_ttfb_us = a.sum_ttfb / a.count,
            .avg_duration_us = a.sum_dur / a.count,
        };
    }
    // Most-hit routes first.
    std.mem.sort(RouteStat, routes, {}, struct {
        fn gt(_: void, x: RouteStat, y: RouteStat) bool {
            return x.count > y.count;
        }
    }.gt);

    return .{
        .total_requests = total_snapshot,
        .window = n,
        .ttfb = statOf(alloc, ttfbs) catch .{},
        .duration = statOf(alloc, durs) catch .{},
        .routes = routes,
    };
}

const RouteAccum = struct {
    count: usize = 0,
    sum_ttfb: u64 = 0,
    sum_dur: u64 = 0,
};

fn statOf(alloc: std.mem.Allocator, values: []const u32) !Stat {
    if (values.len == 0) return .{};
    const sorted = try alloc.dupe(u32, values);
    std.mem.sort(u32, sorted, {}, std.sort.asc(u32));

    var sum: u64 = 0;
    for (sorted) |v| sum += v;

    return .{
        .avg = sum / sorted.len,
        .p50 = percentile(sorted, 0.50),
        .p95 = percentile(sorted, 0.95),
        .p99 = percentile(sorted, 0.99),
        .max = sorted[sorted.len - 1],
    };
}

fn percentile(sorted: []const u32, p: f64) u32 {
    if (sorted.len == 0) return 0;
    const rank = p * @as(f64, @floatFromInt(sorted.len - 1));
    const idx: usize = @intFromFloat(@round(rank));
    return sorted[@min(idx, sorted.len - 1)];
}

test "empty report" {
    reset();
    // collect() allocates intermediates that live for the request arena's
    // lifetime, so drive it from an arena (mirrors real per-request usage).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try collect(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), r.window);
    try std.testing.expectEqual(@as(u64, 0), r.total_requests);
}

test "records and aggregates" {
    reset();
    record("/", 200, 100, 200);
    record("/", 200, 300, 400);
    record("/api/hello", 200, 50, 60);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try collect(arena.allocator());

    try std.testing.expectEqual(@as(u64, 3), r.total_requests);
    try std.testing.expectEqual(@as(usize, 3), r.window);
    // ttfb values: {100,300,50} -> avg 150
    try std.testing.expectEqual(@as(u64, 150), r.ttfb.avg);
    try std.testing.expectEqual(@as(u32, 300), r.ttfb.max);
    try std.testing.expectEqual(@as(usize, 2), r.routes.len);
    // "/" hit twice should sort first.
    try std.testing.expectEqualStrings("/", r.routes[0].path);
    try std.testing.expectEqual(@as(usize, 2), r.routes[0].count);
}

// Test-only helper.
fn reset() void {
    mutex.lock();
    defer mutex.unlock();
    head = 0;
    count = 0;
    total = 0;
}
