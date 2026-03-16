//! DB-backed rate limiting for merjs-auth.
//!
//! Counts attempts per hashed key within a sliding window. Raw identifiers
//! (email addresses, IP addresses) are never stored in the database —
//! only their SHA-256 hash, so a breach of the rate-limit table does not
//! expose user data.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const db = @import("db/root.zig");

// ── Config ─────────────────────────────────────────────────────────────────

pub const RateLimitKey = enum {
    email,
    ip,
    none,
};

pub const RateLimitConfig = struct {
    max_attempts: u32 = 5,
    /// Window size in seconds. Default: 15 minutes.
    window_s: u32 = 15 * 60,
};

// ── Key hashing ────────────────────────────────────────────────────────────

/// Hash an identifier (email or IP) to a 64-char hex string for storage.
/// Using SHA-256 here is acceptable for rate-limit keys: we only need a
/// stable, opaque identifier — we never need to reverse it.
/// Caller owns the returned slice.
pub fn hashKey(value: []const u8, alloc: Allocator) ![]u8 {
    var raw: [32]u8 = undefined;
    Sha256.hash(value, &raw, .{});
    const hex = std.fmt.bytesToHex(raw, .lower);
    return alloc.dupe(u8, &hex);
}

// ── Rate limit check ───────────────────────────────────────────────────────

/// Check and increment the attempt counter for `key`.
///
/// Uses a PostgreSQL UPSERT that atomically:
///   - Inserts a new row with count=1 if the key is new.
///   - Resets count to 1 if the window has expired.
///   - Increments count by 1 if within the current window.
///
/// Returns `error.RateLimited` if the counter exceeds `config.max_attempts`.
pub fn check(
    adapter: db.Adapter,
    key: []const u8,
    config: RateLimitConfig,
    alloc: Allocator,
) !void {
    // Format the window duration as a Postgres interval literal, e.g. "900 seconds".
    const window_str = try std.fmt.allocPrint(alloc, "{d}", .{config.window_s});
    defer alloc.free(window_str);

    const sql =
        \\INSERT INTO mauth_rate_limits (key, count, window_start)
        \\VALUES ($1, 1, NOW())
        \\ON CONFLICT (key) DO UPDATE
        \\  SET count = CASE
        \\        WHEN mauth_rate_limits.window_start < NOW() - ($2 || ' seconds')::interval
        \\          THEN 1
        \\        ELSE mauth_rate_limits.count + 1
        \\      END,
        \\      window_start = CASE
        \\        WHEN mauth_rate_limits.window_start < NOW() - ($2 || ' seconds')::interval
        \\          THEN NOW()
        \\        ELSE mauth_rate_limits.window_start
        \\      END
        \\RETURNING count
    ;

    const params = [_]db.Value{
        .{ .text = key },
        .{ .text = window_str },
    };

    var result = try adapter.query(alloc, sql, &params);
    defer result.deinit();

    if (result.rows.len == 0) return; // should not happen, but safe fallback

    const count_val = db.rowInt(result.rows[0], "count") orelse return;
    if (count_val > @as(i64, config.max_attempts)) {
        return error.RateLimited;
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "hashKey produces 64-char hex" {
    const alloc = std.testing.allocator;
    const h = try hashKey("user@example.com", alloc);
    defer alloc.free(h);
    try std.testing.expectEqual(@as(usize, 64), h.len);
    for (h) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "hashKey is deterministic" {
    const alloc = std.testing.allocator;
    const h1 = try hashKey("192.168.1.1", alloc);
    defer alloc.free(h1);
    const h2 = try hashKey("192.168.1.1", alloc);
    defer alloc.free(h2);
    try std.testing.expectEqualStrings(h1, h2);
}

test "hashKey differs for different inputs" {
    const alloc = std.testing.allocator;
    const h1 = try hashKey("a@example.com", alloc);
    defer alloc.free(h1);
    const h2 = try hashKey("b@example.com", alloc);
    defer alloc.free(h2);
    try std.testing.expect(!std.mem.eql(u8, h1, h2));
}
