//! Argon2id password hashing for merjs-auth.
//!
//! Two parameter sets are provided:
//!   WorkersParams — tuned for Cloudflare Workers (32 MiB memory limit).
//!   ServerParams  — tuned for a dedicated server (64 MiB, 3 iterations).
//!
//! Never store raw passwords. Call `hash` on registration/password-change,
//! store the PHC string, and call `verify` on every login.

const std = @import("std");
const Allocator = std.mem.Allocator;
const argon2 = std.crypto.pwhash.argon2;

// ── Parameter sets ─────────────────────────────────────────────────────────

/// Params for Cloudflare Workers: 32 MiB RAM, 2 iterations, 1 lane.
/// Chosen to stay within the 128 MiB Workers memory limit while still
/// providing meaningful work factor.
pub const WorkersParams = argon2.Params{
    .t = 2,
    .m = 32768, // 32 MiB (in KiB)
    .p = 1, // p is u24 in Zig 0.15
};

/// Params for a dedicated server: 64 MiB RAM, 3 iterations, 2 lanes.
pub const ServerParams = argon2.Params{
    .t = 3,
    .m = 65536, // 64 MiB (in KiB)
    .p = 2,
};

// ── Hashing ────────────────────────────────────────────────────────────────

/// Hash `password` using Argon2id with the provided `params`.
/// Returns an owned PHC-format string (e.g. `$argon2id$v=19$...`).
/// Caller must free the returned slice.
///
/// The output buffer is [128]u8 on the stack — Zig's argon2.strHash
/// requires exactly this size.
pub fn hash(alloc: Allocator, password: []const u8, params: argon2.Params) ![]u8 {
    var buf: [128]u8 = undefined;
    const phc = try argon2.strHash(password, .{ .allocator = alloc, .params = params }, &buf);
    // phc is a slice into buf (stack); dupe it before returning.
    return alloc.dupe(u8, phc);
}

/// Verify `password` against a PHC-format `phc_hash` produced by `hash`.
/// Returns true if the password matches, false otherwise.
/// Never propagates errors — any failure (corrupt hash, OOM, etc.) is
/// treated as a non-match to avoid leaking internal state.
pub fn verify(alloc: Allocator, password: []const u8, phc_hash: []const u8) bool {
    argon2.strVerify(phc_hash, password, .{ .allocator = alloc }) catch return false;
    return true;
}

// ── Strength check ─────────────────────────────────────────────────────────

/// Basic strength gate: at least 8 characters, at most 128.
/// Callers should layer additional UI-side checks (entropy meters, etc.)
/// on top of this server-side floor.
pub fn isStrong(password: []const u8) bool {
    return password.len >= 8 and password.len <= 128;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "hash and verify round-trip (WorkersParams)" {
    const alloc = std.testing.allocator;
    const pw = "correct-horse-battery-staple";
    const phc = try hash(alloc, pw, WorkersParams);
    defer alloc.free(phc);
    try std.testing.expect(verify(alloc, pw, phc));
    try std.testing.expect(!verify(alloc, "wrong-password", phc));
}

test "verify with corrupt hash returns false (no panic)" {
    try std.testing.expect(!verify(std.testing.allocator, "pw", "not-a-valid-phc-string"));
}

test "isStrong: rejects short passwords" {
    try std.testing.expect(!isStrong("short"));
    try std.testing.expect(!isStrong("1234567"));
}

test "isStrong: rejects passwords over 128 chars" {
    const long = "a" ** 129;
    try std.testing.expect(!isStrong(long));
}

test "isStrong: accepts valid passwords" {
    try std.testing.expect(isStrong("12345678"));
    try std.testing.expect(isStrong("correct-horse-battery-staple"));
    try std.testing.expect(isStrong("a" ** 128));
}
