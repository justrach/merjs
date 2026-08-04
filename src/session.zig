// session.zig — HMAC-based session tokens.

const std = @import("std");
const builtin = @import("builtin");
const env = @import("env.zig").get;

extern "c" fn _time64(timer: ?*i64) i64;

const SessionHmac = std.crypto.auth.hmac.sha2.HmacSha256;
const SESSION_HMAC_HEX_LEN = SessionHmac.mac_length * 2;
pub const SESSION_SECRET = "MERJS_SESSION_SECRET";
pub const DEPRECATED_SESSION_SECRET = "MULTICLAW_SESSION_SECRET";
pub const SESSION_SECRET_MIN_LENGTH = 32;

/// Get the current Unix timestamp, reporting clock and representation failures.
fn currentTimestamp() !i64 {
    if (builtin.target.os.tag == .windows) {
        const seconds = _time64(null);
        if (seconds < 0) return error.ClockFailed;
        return seconds;
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return error.ClockFailed;
    const seconds = std.math.cast(i64, ts.sec) orelse return error.ClockFailed;
    if (seconds < 0) return error.ClockFailed;
    return seconds;
}

fn isStrongSecret(secret: []const u8) bool {
    return secret.len >= SESSION_SECRET_MIN_LENGTH;
}

/// Resolve the secret used for newly signed sessions. The canonical variable
/// takes precedence. A configured but weak canonical value fails closed rather
/// than silently downgrading to the deprecated variable.
pub fn sessionSigningSecret() error{ NoSessionSecret, WeakSessionSecret }![]const u8 {
    if (env(SESSION_SECRET)) |secret| {
        if (!isStrongSecret(secret)) return error.WeakSessionSecret;
        return secret;
    }
    if (env(DEPRECATED_SESSION_SECRET)) |secret| {
        if (!isStrongSecret(secret)) return error.WeakSessionSecret;
        return secret;
    }
    return error.NoSessionSecret;
}

pub const VerificationSecrets = struct {
    canonical: ?[]const u8,
    deprecated: ?[]const u8,
};

/// Require the current strength policy for every active verification key. A
/// configured weak canonical key invalidates the set rather than downgrading.
pub fn sessionVerificationSecrets() VerificationSecrets {
    const canonical = env(SESSION_SECRET);
    if (canonical) |secret| {
        if (!isStrongSecret(secret)) return .{ .canonical = null, .deprecated = null };
    }
    const deprecated = env(DEPRECATED_SESSION_SECRET);
    return .{
        .canonical = canonical,
        .deprecated = if (deprecated) |secret| if (isStrongSecret(secret)) secret else null else null,
    };
}

/// Default session lifetime: 7 days.
pub const SESSION_DEFAULT_TTL: u32 = 7 * 24 * 60 * 60;

/// Parsed session extracted from a verified token.
pub const Session = struct {
    user_id: []const u8,
    expires_at: i64,
};

fn signSessionWithClock(
    allocator: std.mem.Allocator,
    user_id: []const u8,
    ttl_secs: u32,
    clock: *const fn () anyerror!i64,
) ![]u8 {
    const secret = try sessionSigningSecret();
    const now = try clock();
    if (now < 0) return error.ClockFailed;
    const expires_at = std.math.add(i64, now, @as(i64, ttl_secs)) catch
        return error.TimestampOverflow;
    const msg = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ user_id, expires_at });
    defer allocator.free(msg);

    var mac: [SessionHmac.mac_length]u8 = undefined;
    SessionHmac.create(&mac, msg, secret);
    const hex = std.fmt.bytesToHex(mac, .lower);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ msg, &hex });
}

/// Sign a session token for `user_id` valid for `ttl_secs` seconds.
/// `MERJS_SESSION_SECRET` must contain at least 32 bytes. If it is absent, the
/// equally strong deprecated `MULTICLAW_SESSION_SECRET` is accepted temporarily.
/// Returns an allocated string owned by `allocator`.
pub fn signSession(
    allocator: std.mem.Allocator,
    user_id: []const u8,
    ttl_secs: u32,
) ![]u8 {
    return signSessionWithClock(allocator, user_id, ttl_secs, currentTimestamp);
}

fn hmacMatches(prefix: []const u8, hmac_hex: []const u8, secret: []const u8) bool {
    var mac: [SessionHmac.mac_length]u8 = undefined;
    SessionHmac.create(&mac, prefix, secret);
    const expected = std.fmt.bytesToHex(mac, .lower);
    return std.crypto.timing_safe.eql(
        [SESSION_HMAC_HEX_LEN]u8,
        expected,
        hmac_hex[0..SESSION_HMAC_HEX_LEN].*,
    );
}

fn verifySessionAt(token: []const u8, now: i64) ?Session {
    if (now < 0) return null;
    const secrets = sessionVerificationSecrets();
    if (secrets.canonical == null and secrets.deprecated == null) return null;
    if (token.len < SESSION_HMAC_HEX_LEN + 3) return null;

    const last_dot = std.mem.lastIndexOfScalar(u8, token, '.') orelse return null;
    const hmac_hex = token[last_dot + 1 ..];
    if (hmac_hex.len != SESSION_HMAC_HEX_LEN) return null;

    const prefix = token[0..last_dot];
    const mid_dot = std.mem.lastIndexOfScalar(u8, prefix, '.') orelse return null;
    const expires_at = std.fmt.parseInt(i64, prefix[mid_dot + 1 ..], 10) catch return null;
    if (now >= expires_at) return null;

    const canonical_match = if (secrets.canonical) |secret| hmacMatches(prefix, hmac_hex, secret) else false;
    const deprecated_match = if (secrets.deprecated) |secret| hmacMatches(prefix, hmac_hex, secret) else false;
    if (!canonical_match and !deprecated_match) return null;

    return .{ .user_id = prefix[0..mid_dot], .expires_at = expires_at };
}

fn verifySessionWithClock(token: []const u8, clock: *const fn () anyerror!i64) ?Session {
    const now = clock() catch return null;
    return verifySessionAt(token, now);
}

/// Verify a session token produced by `signSession`. Returns null for malformed,
/// expired, or unverifiable tokens and when the clock fails. Every active
/// verification secret must contain at least 32 bytes.
pub fn verifySession(token: []const u8) ?Session {
    return verifySessionWithClock(token, currentTimestamp);
}

fn inject(key: []const u8, value: []const u8) !void {
    try @import("env.zig").put(key, value);
}

fn tokenWithSecret(buffer: []u8, user_id: []const u8, expires_at: i64, secret: []const u8) ![]u8 {
    var prefix_buf: [256]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "{s}.{d}", .{ user_id, expires_at });
    var mac: [SessionHmac.mac_length]u8 = undefined;
    SessionHmac.create(&mac, prefix, secret);
    const hex = std.fmt.bytesToHex(mac, .lower);
    return std.fmt.bufPrint(buffer, "{s}.{s}", .{ prefix, &hex });
}

const canonical_secret = "canonical-test-secret-at-least-32-bytes";
const deprecated_secret = "deprecated-test-secret-at-least-32-bytes";
const short_deprecated_secret = "old-short-secret";

fn fixedClock() !i64 {
    return 1_700_000_000;
}

fn failedClock() !i64 {
    return error.ClockFailed;
}

fn overflowClock() !i64 {
    return std.math.maxInt(i64);
}

test "session: canonical secret signs and verifies" {
    const env_mod = @import("env.zig");
    env_mod.reset();
    defer env_mod.reset();
    try inject(SESSION_SECRET, canonical_secret);

    const token = try signSessionWithClock(std.testing.allocator, "alice", 3600, fixedClock);
    defer std.testing.allocator.free(token);
    const session = verifySessionAt(token, 1_700_000_001) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("alice", session.user_id);
}

test "session: deprecated secret remains a signing fallback" {
    const env_mod = @import("env.zig");
    env_mod.reset();
    defer env_mod.reset();
    try inject(DEPRECATED_SESSION_SECRET, deprecated_secret);

    const token = try signSessionWithClock(std.testing.allocator, "alice", 3600, fixedClock);
    defer std.testing.allocator.free(token);
    try std.testing.expect(verifySessionAt(token, 1_700_000_001) != null);
}

test "session: canonical signing and old-secret verification migrate together" {
    const env_mod = @import("env.zig");
    env_mod.reset();
    defer env_mod.reset();
    try inject(SESSION_SECRET, canonical_secret);
    try inject(DEPRECATED_SESSION_SECRET, deprecated_secret);

    var token_buf: [512]u8 = undefined;
    const old_token = try tokenWithSecret(&token_buf, "alice", 1_800_000_000, deprecated_secret);
    try std.testing.expect(verifySessionAt(old_token, 1_700_000_000) != null);

    const new_token = try signSessionWithClock(std.testing.allocator, "alice", 3600, fixedClock);
    defer std.testing.allocator.free(new_token);
    const last_dot = std.mem.lastIndexOfScalar(u8, new_token, '.').?;
    try std.testing.expect(hmacMatches(new_token[0..last_dot], new_token[last_dot + 1 ..], canonical_secret));
    try std.testing.expect(!hmacMatches(new_token[0..last_dot], new_token[last_dot + 1 ..], deprecated_secret));
}

test "session: missing, empty, and weak secrets fail closed" {
    const env_mod = @import("env.zig");
    env_mod.reset();
    defer env_mod.reset();
    try std.testing.expectError(error.NoSessionSecret, signSessionWithClock(std.testing.allocator, "alice", 1, fixedClock));

    try inject(SESSION_SECRET, "");
    try inject(DEPRECATED_SESSION_SECRET, deprecated_secret);
    try std.testing.expectError(error.WeakSessionSecret, signSessionWithClock(std.testing.allocator, "alice", 1, fixedClock));
    var token_buf: [256]u8 = undefined;
    const old_token = try tokenWithSecret(&token_buf, "alice", 1_800_000_000, deprecated_secret);
    try std.testing.expect(verifySessionAt(old_token, 1_700_000_000) == null);
}

test "session: weak verification secrets fail closed" {
    const env_mod = @import("env.zig");
    env_mod.reset();
    defer env_mod.reset();
    try inject(DEPRECATED_SESSION_SECRET, short_deprecated_secret);

    try std.testing.expectError(error.WeakSessionSecret, signSessionWithClock(std.testing.allocator, "alice", 1, fixedClock));
    var token_buf: [256]u8 = undefined;
    const old_token = try tokenWithSecret(&token_buf, "alice", 1_800_000_000, short_deprecated_secret);
    try std.testing.expect(verifySessionAt(old_token, 1_700_000_000) == null);

    try inject(SESSION_SECRET, "weak");
    try std.testing.expectError(error.WeakSessionSecret, signSessionWithClock(std.testing.allocator, "alice", 1, fixedClock));
    try std.testing.expect(verifySessionAt(old_token, 1_700_000_000) == null);
}

test "session: empty deprecated secret never verifies" {
    const env_mod = @import("env.zig");
    env_mod.reset();
    defer env_mod.reset();
    try inject(DEPRECATED_SESSION_SECRET, "");

    var token_buf: [256]u8 = undefined;
    const token = try tokenWithSecret(&token_buf, "alice", 1_800_000_000, "");
    try std.testing.expect(verifySessionAt(token, 1_700_000_000) == null);
}

test "session: clock failure and timestamp overflow are checked" {
    const env_mod = @import("env.zig");
    env_mod.reset();
    defer env_mod.reset();
    try inject(SESSION_SECRET, canonical_secret);

    try std.testing.expectError(error.ClockFailed, signSessionWithClock(std.testing.allocator, "alice", 1, failedClock));
    try std.testing.expectError(error.TimestampOverflow, signSessionWithClock(std.testing.allocator, "alice", 1, overflowClock));

    var token_buf: [256]u8 = undefined;
    const token = try tokenWithSecret(&token_buf, "alice", 1_800_000_000, canonical_secret);
    try std.testing.expect(verifySessionWithClock(token, failedClock) == null);
}

test "session: expired, tampered, and malformed tokens return null" {
    const env_mod = @import("env.zig");
    env_mod.reset();
    defer env_mod.reset();
    try inject(SESSION_SECRET, canonical_secret);

    var token_buf: [256]u8 = undefined;
    const expired = try tokenWithSecret(&token_buf, "alice", 1, canonical_secret);
    try std.testing.expect(verifySessionAt(expired, 1) == null);
    try std.testing.expect(verifySessionAt(expired, 2) == null);

    const token = try signSessionWithClock(std.testing.allocator, "alice", 3600, fixedClock);
    defer std.testing.allocator.free(token);
    token[token.len - 1] ^= 1;
    try std.testing.expect(verifySessionAt(token, 1_700_000_001) == null);
    try std.testing.expect(verifySessionAt("alice.not-a-time.not-a-mac", 1_700_000_001) == null);
}
