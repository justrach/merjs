//! Short-lived verification tokens (email verify, password reset, magic link).
//!
//! Tokens are generated as random hex strings, then stored as their SHA-256
//! hash so a database breach does not expose usable tokens.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

fn io() std.Io {
    return if (builtin.is_test) std.testing.io else runtime.io;
}

// ── Token purpose ──────────────────────────────────────────────────────────

pub const TokenPurpose = enum {
    email_verify,
    password_reset,
    magic_link,
};

/// TTL (seconds) for each token purpose.
///   email_verify  — 24 h   (users might check email hours later)
///   password_reset — 1 h   (short window reduces attack surface)
///   magic_link     — 15 min (single-use, short-lived by design)
pub fn ttlForPurpose(purpose: TokenPurpose) u32 {
    return switch (purpose) {
        .email_verify => 86400,
        .password_reset => 3600,
        .magic_link => 900,
    };
}

// ── Generation ─────────────────────────────────────────────────────────────

/// Generate a cryptographically-random 64-character lowercase hex token.
/// Internally: 32 random bytes → hex-encoded → 64 chars.
/// Caller must free the returned slice.
pub fn generate(alloc: Allocator) ![]u8 {
    var raw: [32]u8 = undefined;
    try io().randomSecure(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    return alloc.dupe(u8, &hex);
}

// ── Storage hash ───────────────────────────────────────────────────────────

/// Hash a raw token for safe database storage using SHA-256.
/// Store the hash, send the raw token to the user via email/link.
/// On verification: re-hash the submitted token and compare to the stored hash.
pub fn hashForStorage(token: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Sha256.hash(token, &out, .{});
    return out;
}

/// Encode a 32-byte hash as a 64-character lowercase hex string.
pub fn hashToHex(hash_bytes: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(hash_bytes, .lower);
}

/// Get current Unix timestamp in seconds, reporting clock errors.
fn currentUnixSeconds() !i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return error.ClockFailed;
    const seconds = std.math.cast(i64, ts.sec) orelse return error.ClockFailed;
    if (seconds < 0) return error.ClockFailed;
    return seconds;
}

// ── Expiry helper ──────────────────────────────────────────────────────────

fn isExpiredWithClock(expires_at_unix: i64, clock: *const fn () anyerror!i64) bool {
    const now = clock() catch return true;
    return expires_at_unix < now;
}

/// Returns true if the given Unix-seconds timestamp is in the past.
/// Clock failures fail closed and treat the token as expired.
pub fn isExpired(expires_at_unix: i64) bool {
    return isExpiredWithClock(expires_at_unix, currentUnixSeconds);
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "generate returns 64 hex chars" {
    const alloc = std.testing.allocator;
    const tok = try generate(alloc);
    defer alloc.free(tok);
    try std.testing.expectEqual(@as(usize, 64), tok.len);
    for (tok) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "hashForStorage is deterministic" {
    const raw = "deadbeef" ** 8; // 64 chars
    const h1 = hashForStorage(raw);
    const h2 = hashForStorage(raw);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "hashForStorage differs for different tokens" {
    const h1 = hashForStorage("token-a" ++ ("x" ** 57));
    const h2 = hashForStorage("token-b" ++ ("x" ** 57));
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "ttlForPurpose" {
    try std.testing.expectEqual(@as(u32, 86400), ttlForPurpose(.email_verify));
    try std.testing.expectEqual(@as(u32, 3600), ttlForPurpose(.password_reset));
    try std.testing.expectEqual(@as(u32, 900), ttlForPurpose(.magic_link));
}

test "isExpired fails closed when the clock fails" {
    const failedClock = struct {
        fn now() !i64 {
            return error.ClockFailed;
        }
    }.now;
    try std.testing.expect(isExpiredWithClock(9_999_999_999, failedClock));
}

test "isExpired: past timestamp is expired" {
    try std.testing.expect(isExpired(0)); // Unix epoch is definitely expired
}

test "isExpired: far-future timestamp is not expired" {
    const far_future: i64 = 9_999_999_999;
    try std.testing.expect(!isExpired(far_future));
}
