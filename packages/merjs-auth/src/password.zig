//! Argon2id password hashing for merjs-auth.
//!
//! Two parameter sets are provided:
//!   WorkersParams — tuned for Cloudflare Workers (32 MiB memory limit).
//!   ServerParams  — tuned for a dedicated server (64 MiB, 3 iterations).
//!
//! Never store raw passwords. Call `hash` on registration/password-change,
//! store the PHC string, and call `verify` on every login.
//!
//! Hashing and verification share a process-wide, fail-fast admission limit.
//! The default of four bounds concurrent ServerParams workspaces to about
//! 256 MiB (4 × 64 MiB); requests are never queued waiting for a permit.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const Allocator = std.mem.Allocator;
const argon2 = std.crypto.pwhash.argon2;

fn io() std.Io {
    return if (builtin.is_test) std.testing.io else runtime.io;
}

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

// ── Process-wide admission ─────────────────────────────────────────────────

pub const max_concurrent: u32 = 4;

var active_jobs = std.atomic.Value(u32).init(0);

const Permit = struct {
    fn release(_: Permit) void {
        const previous = active_jobs.fetchSub(1, .release);
        std.debug.assert(previous > 0);
    }
};

fn tryAcquire() ?Permit {
    var active = active_jobs.load(.acquire);
    while (active < max_concurrent) {
        if (active_jobs.cmpxchgWeak(active, active + 1, .acq_rel, .acquire)) |actual| {
            active = actual;
        } else return .{};
    }
    return null;
}

// ── Hashing ────────────────────────────────────────────────────────────────

/// Hash `password` using Argon2id with the provided `params`.
/// Returns an owned PHC-format string (e.g. `$argon2id$v=19$...`).
/// Caller must free the returned slice.
///
/// The output buffer is [128]u8 on the stack — Zig's argon2.strHash
/// requires exactly this size.
pub fn hash(alloc: Allocator, password: []const u8, params: argon2.Params) ![]u8 {
    const permit = tryAcquire() orelse return error.CapacityExhausted;
    defer permit.release();

    var buf: [128]u8 = undefined;
    const phc = try argon2.strHash(password, .{ .allocator = alloc, .params = params }, &buf, io());
    // phc is a slice into buf (stack); dupe it before returning.
    return alloc.dupe(u8, phc);
}

/// Verify with an explicit capacity error for request handlers. Internal
/// failures and malformed hashes remain indistinguishable from a non-match.
pub fn verifyStatus(alloc: Allocator, password: []const u8, phc_hash: []const u8) error{CapacityExhausted}!bool {
    const permit = tryAcquire() orelse return error.CapacityExhausted;
    defer permit.release();

    argon2.strVerify(phc_hash, password, .{ .allocator = alloc }, io()) catch return false;
    return true;
}

/// Compatibility wrapper: returns false on capacity exhaustion. Call
/// `verifyStatus` in request handlers so saturation can be reported separately.
pub fn verify(alloc: Allocator, password: []const u8, phc_hash: []const u8) bool {
    return verifyStatus(alloc, password, phc_hash) catch false;
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

test "hash and verify fail fast when admission is saturated" {
    var permits: [max_concurrent]Permit = undefined;
    for (&permits) |*permit| permit.* = tryAcquire().?;
    defer for (permits) |permit| permit.release();

    try std.testing.expectError(
        error.CapacityExhausted,
        verifyStatus(std.testing.allocator, "pw", "not-a-valid-phc-string"),
    );
    try std.testing.expect(!verify(std.testing.allocator, "pw", "not-a-valid-phc-string"));
    try std.testing.expectError(
        error.CapacityExhausted,
        hash(std.testing.allocator, "password", .{ .t = 1, .m = 8, .p = 1 }),
    );
}

const AdmissionThread = struct {
    attempts: *std.atomic.Value(u32),
    admitted: *std.atomic.Value(u32),
    release: *std.atomic.Value(bool),

    fn run(ctx: AdmissionThread) void {
        const permit = tryAcquire() orelse {
            _ = ctx.attempts.fetchAdd(1, .release);
            return;
        };
        defer permit.release();
        _ = ctx.admitted.fetchAdd(1, .monotonic);
        _ = ctx.attempts.fetchAdd(1, .release);
        while (!ctx.release.load(.acquire)) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }
};

test "concurrent admission never exceeds limit" {
    var attempts = std.atomic.Value(u32).init(0);
    var admitted = std.atomic.Value(u32).init(0);
    var release = std.atomic.Value(bool).init(false);
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, AdmissionThread.run, .{AdmissionThread{
            .attempts = &attempts,
            .admitted = &admitted,
            .release = &release,
        }});
    }

    while (attempts.load(.acquire) != @as(u32, @intCast(threads.len))) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    const admitted_count = admitted.load(.acquire);
    release.store(true, .release);
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(max_concurrent, admitted_count);
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
