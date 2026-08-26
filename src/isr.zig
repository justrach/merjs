// isr.zig — Incremental Static Regeneration cache (stale-while-revalidate).
//
// Pages opt in via `pub const revalidate: u32 = N;` (seconds). The rendered
// HTML for such a route is cached in-memory keyed by request path:
//
//   * First request  → render synchronously, store, serve.
//   * Within the TTL → serve the cached HTML instantly (0ms render).
//   * After the TTL  → serve the STALE cached copy immediately AND kick off a
//                      background re-render so the next request gets fresh HTML.
//
// This file is intentionally dependency-free (only `std`) so its TTL/staleness
// logic is trivially unit-testable in isolation. The server wires the actual
// background re-render (which needs the router/dispatch) in server.zig; here we
// only expose the thread-safe cache + the `tryBeginRevalidate` gate that
// prevents a thundering herd of concurrent re-renders for the same path.

const std = @import("std");

// --- Zig 0.17 shim: Thread.Mutex was removed (see src/static.zig) ---
const PthreadMutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    pub fn lock(m: *PthreadMutex) void {
        _ = std.c.pthread_mutex_lock(&m.inner);
    }
    pub fn unlock(m: *PthreadMutex) void {
        _ = std.c.pthread_mutex_unlock(&m.inner);
    }
};

/// Replacement for std.time.nanoTimestamp() which was removed in Zig 0.17.
pub fn nowNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

/// A cached, fully-rendered page (post-layout HTML). ISR only ever caches
/// successful HTML responses, so no content-type/status is stored.
const Entry = struct {
    body: []const u8,
    rendered_at_ns: i128,
    /// True while a background re-render is in flight for this path — used to
    /// coalesce concurrent stale requests into a single re-render.
    revalidating: bool = false,
};

/// Result of a cache lookup. `body` is owned by the caller's allocator (it is
/// duplicated out under the lock so a concurrent `store` can never free it
/// while it is being written to the socket).
pub const Lookup = struct {
    body: []const u8,
    /// True when the entry has exceeded its TTL and should be revalidated.
    stale: bool,
};

var cache: std.StringHashMapUnmanaged(Entry) = .{};
var cache_alloc: std.mem.Allocator = undefined;
var cache_mu: PthreadMutex = .{};
var init_done: bool = false;

/// Wire the long-lived allocator used to own cached bodies + keys. Called once
/// from Server.listen (mirrors static.initCache).
pub fn initCache(alloc: std.mem.Allocator) void {
    cache_alloc = alloc;
    init_done = true;
}

/// The long-lived allocator backing the cache. The server uses this as the
/// base for background re-render arenas so nothing outlives it unexpectedly.
pub fn allocator() std.mem.Allocator {
    return cache_alloc;
}

/// Pure TTL check — the heart of the stale-while-revalidate policy.
/// Returns true if an entry rendered at `rendered_at_ns` is stale given a
/// `revalidate_secs` TTL, evaluated at `now_ns`.
///   * revalidate_secs == 0 → caching disabled, always "stale".
///   * age >= TTL           → stale (serve stale, revalidate in background).
///   * age <  TTL           → fresh (serve cached, no work).
pub fn isStale(rendered_at_ns: i128, revalidate_secs: u32, now_ns: i128) bool {
    if (revalidate_secs == 0) return true;
    const ttl_ns: i128 = @as(i128, revalidate_secs) * 1_000_000_000;
    return (now_ns - rendered_at_ns) >= ttl_ns;
}

/// Look up a cached page for `path`. On a hit, the body is duplicated into
/// `alloc` (the request arena) under the lock and returned along with a
/// staleness flag. Returns null on a miss (or before initCache).
pub fn get(alloc: std.mem.Allocator, path: []const u8, revalidate_secs: u32, now_ns: i128) ?Lookup {
    if (!init_done) return null;
    cache_mu.lock();
    defer cache_mu.unlock();
    const e = cache.get(path) orelse return null;
    const body_copy = alloc.dupe(u8, e.body) catch return null;
    return .{
        .body = body_copy,
        .stale = isStale(e.rendered_at_ns, revalidate_secs, now_ns),
    };
}

/// Store (or replace) the cached HTML for `path`, stamping it with `now_ns`.
/// Clears the `revalidating` flag. Safe to call from any thread; the previous
/// body is freed under the lock so concurrent readers (which dup under the same
/// lock) never observe a freed pointer.
pub fn store(path: []const u8, body: []const u8, now_ns: i128) void {
    if (!init_done) return;
    cache_mu.lock();
    defer cache_mu.unlock();
    const owned_body = cache_alloc.dupe(u8, body) catch return;
    if (cache.getPtr(path)) |e| {
        cache_alloc.free(e.body);
        e.body = owned_body;
        e.rendered_at_ns = now_ns;
        e.revalidating = false;
        return;
    }
    const key = cache_alloc.dupe(u8, path) catch {
        cache_alloc.free(owned_body);
        return;
    };
    cache.put(cache_alloc, key, .{ .body = owned_body, .rendered_at_ns = now_ns }) catch {
        cache_alloc.free(key);
        cache_alloc.free(owned_body);
    };
}

/// Attempt to claim the right to revalidate `path` in the background. Returns
/// true only if an entry exists and no revalidation is already in flight — the
/// caller must then perform the re-render and call `store` (which clears the
/// flag) or `clearRevalidating` on failure. This coalesces concurrent stale
/// requests so only one background re-render runs per path at a time.
pub fn tryBeginRevalidate(path: []const u8) bool {
    if (!init_done) return false;
    cache_mu.lock();
    defer cache_mu.unlock();
    if (cache.getPtr(path)) |e| {
        if (e.revalidating) return false;
        e.revalidating = true;
        return true;
    }
    return false;
}

/// Release a revalidation claim without updating the entry (used when a
/// background re-render fails so a future request can retry).
pub fn clearRevalidating(path: []const u8) void {
    if (!init_done) return;
    cache_mu.lock();
    defer cache_mu.unlock();
    if (cache.getPtr(path)) |e| e.revalidating = false;
}

/// Test-only: wipe the cache between tests. Frees all owned keys/bodies.
fn resetForTest() void {
    cache_mu.lock();
    defer cache_mu.unlock();
    var it = cache.iterator();
    while (it.next()) |kv| {
        cache_alloc.free(kv.key_ptr.*);
        cache_alloc.free(kv.value_ptr.body);
    }
    cache.clearAndFree(cache_alloc);
    init_done = false;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const ns_per_s: i128 = 1_000_000_000;

test "isStale: caching disabled (revalidate == 0) is always stale" {
    // A 0 TTL means "don't cache" — every check reports stale.
    try std.testing.expect(isStale(0, 0, 0));
    try std.testing.expect(isStale(1000, 0, 1000));
}

test "isStale: fresh within TTL" {
    const rendered: i128 = 100 * ns_per_s;
    // 4 seconds later, TTL 5s → still fresh.
    try std.testing.expect(!isStale(rendered, 5, rendered + 4 * ns_per_s));
    // Exactly at render time → fresh.
    try std.testing.expect(!isStale(rendered, 5, rendered));
}

test "isStale: stale at and beyond TTL boundary" {
    const rendered: i128 = 100 * ns_per_s;
    // Exactly 5s later, TTL 5s → stale (>= boundary).
    try std.testing.expect(isStale(rendered, 5, rendered + 5 * ns_per_s));
    // Well past TTL → stale.
    try std.testing.expect(isStale(rendered, 5, rendered + 60 * ns_per_s));
}

test "isStale: sub-second granularity does not prematurely expire" {
    const rendered: i128 = 0;
    // 999ms into a 1s TTL → fresh.
    try std.testing.expect(!isStale(rendered, 1, 999_000_000));
    // 1000ms into a 1s TTL → stale.
    try std.testing.expect(isStale(rendered, 1, ns_per_s));
}

test "cache: miss then store then fresh hit" {
    initCache(std.testing.allocator);
    defer resetForTest();

    // Miss before anything is stored.
    try std.testing.expect(get(std.testing.allocator, "/isr", 5, 0) == null);

    // Store at t=0.
    store("/isr", "<html>v1</html>", 0);

    // Hit at t=1s with TTL 5s → fresh, body matches.
    const hit = get(std.testing.allocator, "/isr", 5, 1 * ns_per_s).?;
    defer std.testing.allocator.free(hit.body);
    try std.testing.expectEqualStrings("<html>v1</html>", hit.body);
    try std.testing.expect(!hit.stale);
}

test "cache: hit reports stale after TTL, store refreshes it" {
    initCache(std.testing.allocator);
    defer resetForTest();

    store("/isr", "<html>v1</html>", 0);

    // 6s later with TTL 5s → served but flagged stale.
    const stale_hit = get(std.testing.allocator, "/isr", 5, 6 * ns_per_s).?;
    defer std.testing.allocator.free(stale_hit.body);
    try std.testing.expectEqualStrings("<html>v1</html>", stale_hit.body);
    try std.testing.expect(stale_hit.stale);

    // Background re-render stores fresh content at t=6s.
    store("/isr", "<html>v2</html>", 6 * ns_per_s);

    // Next request at t=7s → fresh v2.
    const fresh_hit = get(std.testing.allocator, "/isr", 5, 7 * ns_per_s).?;
    defer std.testing.allocator.free(fresh_hit.body);
    try std.testing.expectEqualStrings("<html>v2</html>", fresh_hit.body);
    try std.testing.expect(!fresh_hit.stale);
}

test "cache: revalidation claim coalesces concurrent stale requests" {
    initCache(std.testing.allocator);
    defer resetForTest();

    store("/isr", "<html>v1</html>", 0);

    // First stale request claims the revalidation slot.
    try std.testing.expect(tryBeginRevalidate("/isr"));
    // Concurrent stale requests are denied while one is in flight.
    try std.testing.expect(!tryBeginRevalidate("/isr"));

    // A completed re-render (store) clears the flag, re-enabling future claims.
    store("/isr", "<html>v2</html>", 6 * ns_per_s);
    try std.testing.expect(tryBeginRevalidate("/isr"));

    // clearRevalidating also releases the slot (failure path).
    clearRevalidating("/isr");
    try std.testing.expect(tryBeginRevalidate("/isr"));
}

test "cache: tryBeginRevalidate on unknown path returns false" {
    initCache(std.testing.allocator);
    defer resetForTest();
    try std.testing.expect(!tryBeginRevalidate("/never-stored"));
}
