//! Session types and cookie helpers for merjs-auth.
//!
//! Session cookies are HMAC-signed so the session ID cannot be forged
//! without knowledge of the application secret.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mer = @import("mer");
const crypto = @import("crypto.zig");

// ── Cookie / CSRF names ────────────────────────────────────────────────────

pub const COOKIE_SESSION = "mauth_session";
pub const CSRF_COOKIE = "mauth_csrf";

// ── Default TTL ────────────────────────────────────────────────────────────

/// Default session lifetime: 7 days in seconds.
pub const DEFAULT_TTL_S: u32 = 7 * 24 * 60 * 60;

// ── Core types ─────────────────────────────────────────────────────────────

pub const Session = struct {
    id: []const u8,
    user_id: []const u8,
    /// The raw session token (64-char hex). Stored as a unique index in the DB.
    token: []const u8,
    /// Unix timestamp (seconds) when this session expires.
    expires_at: i64,
    ip_address: ?[]const u8,
    user_agent: ?[]const u8,
};

pub const User = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
    email_verified: bool,
    image: ?[]const u8,
    /// Unix timestamp (seconds) of account creation.
    created_at: i64,
    /// Unix timestamp (seconds) of last profile update.
    updated_at: i64,
};

pub const SessionWithUser = struct {
    session: Session,
    user: User,
};

// ── Cookie helpers ─────────────────────────────────────────────────────────

/// Produce the signed cookie value for a session.
/// Format: `"{session_id}.{hex(HMAC-SHA256(session_id, secret))}"`.
/// Caller owns the returned slice.
pub fn cookieValue(alloc: Allocator, session_id: []const u8, secret: []const u8) ![]u8 {
    return crypto.signedToken(alloc, session_id, secret);
}

/// Verify a cookie value and return the embedded session ID, or null if the
/// signature is missing or invalid.
/// No allocations — returns a sub-slice of `cookie`.
pub fn verifyCookie(cookie_val: []const u8, secret: []const u8) ?[]const u8 {
    return crypto.verifySignedToken(cookie_val, secret);
}

/// Build the full Set-Cookie struct for the session cookie.
/// The cookie is HttpOnly, SameSite=Lax, and optionally Secure.
/// Caller owns the `value` slice embedded in the returned struct
/// (it is the output of `cookieValue`).
pub fn cookieSettings(
    session_id: []const u8,
    secret: []const u8,
    ttl_s: u32,
    secure: bool,
    alloc: Allocator,
) !mer.SetCookie {
    const value = try cookieValue(alloc, session_id, secret);
    return mer.SetCookie{
        .name = COOKIE_SESSION,
        .value = value,
        .path = "/",
        .max_age = ttl_s,
        .http_only = true,
        .secure = secure,
        .same_site = .lax,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "cookieValue / verifyCookie round-trip" {
    const alloc = std.testing.allocator;
    const secret = "test-secret";
    const sid = "sess_abcdef1234567890";
    const val = try cookieValue(alloc, sid, secret);
    defer alloc.free(val);
    const recovered = verifyCookie(val, secret);
    try std.testing.expect(recovered != null);
    try std.testing.expectEqualStrings(sid, recovered.?);
}

test "verifyCookie rejects wrong secret" {
    const alloc = std.testing.allocator;
    const val = try cookieValue(alloc, "sess_123", "secret-a");
    defer alloc.free(val);
    try std.testing.expect(verifyCookie(val, "secret-b") == null);
}

test "verifyCookie rejects tampered value" {
    const alloc = std.testing.allocator;
    const val = try cookieValue(alloc, "sess_123", "secret");
    defer alloc.free(val);
    var tampered = try alloc.dupe(u8, val);
    defer alloc.free(tampered);
    tampered[0] ^= 0xff;
    try std.testing.expect(verifyCookie(tampered, "secret") == null);
}
