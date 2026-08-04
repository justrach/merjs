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

const SESSION_SECRET = "MERJS_SESSION_SECRET";
const DEPRECATED_SESSION_SECRET = "MULTICLAW_SESSION_SECRET";
const SESSION_SECRET_MIN_LENGTH = 32;

/// Resolve the secret for newly issued cookies. A strong canonical environment
/// secret takes precedence; Config.secret remains the compatibility fallback.
/// A configured weak canonical secret fails closed instead of downgrading.
pub fn signingSecret(config_secret: []const u8) error{ NoSessionSecret, WeakSessionSecret }![]const u8 {
    if (mer.env(SESSION_SECRET)) |secret| {
        if (secret.len < SESSION_SECRET_MIN_LENGTH) return error.WeakSessionSecret;
        return secret;
    }
    if (config_secret.len < SESSION_SECRET_MIN_LENGTH) {
        return if (config_secret.len == 0) error.NoSessionSecret else error.WeakSessionSecret;
    }
    return config_secret;
}

/// Produce the signed cookie value for a session with an explicit secret.
/// Format: `"{session_id}.{hex(HMAC-SHA256(session_id, secret))}"`.
/// Caller owns the returned slice.
pub fn cookieValue(alloc: Allocator, session_id: []const u8, secret: []const u8) ![]u8 {
    return crypto.signedToken(alloc, session_id, secret);
}

/// Verify a cookie against the canonical secret and strong migration
/// fallbacks. A weak configured canonical secret invalidates all cookies.
/// Config.secret and the deprecated environment secret are verification-only.
/// No allocations — returns a sub-slice of `cookie`.
pub fn verifyCookie(cookie_val: []const u8, config_secret: []const u8) ?[]const u8 {
    if (mer.env(SESSION_SECRET)) |secret| {
        if (secret.len < SESSION_SECRET_MIN_LENGTH) return null;
        if (crypto.verifySignedToken(cookie_val, secret)) |id| return id;
    }
    if (config_secret.len >= SESSION_SECRET_MIN_LENGTH) {
        if (crypto.verifySignedToken(cookie_val, config_secret)) |id| return id;
    }
    if (mer.env(DEPRECATED_SESSION_SECRET)) |secret| {
        if (secret.len >= SESSION_SECRET_MIN_LENGTH) return crypto.verifySignedToken(cookie_val, secret);
    }
    return null;
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
    const value = try cookieValue(alloc, session_id, try signingSecret(secret));
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
    const secret = "test-secret-at-least-thirty-two-bytes";
    const sid = "sess_abcdef1234567890";
    const val = try cookieValue(alloc, sid, secret);
    defer alloc.free(val);
    const recovered = verifyCookie(val, secret);
    try std.testing.expect(recovered != null);
    try std.testing.expectEqualStrings(sid, recovered.?);
}

test "verifyCookie rejects wrong secret" {
    const alloc = std.testing.allocator;
    const val = try cookieValue(alloc, "sess_123", "secret-a-at-least-thirty-two-bytes");
    defer alloc.free(val);
    try std.testing.expect(verifyCookie(val, "secret-b-at-least-thirty-two-bytes") == null);
}

test "verifyCookie rejects tampered value" {
    const alloc = std.testing.allocator;
    const secret = "tamper-test-secret-at-least-32-bytes";
    const val = try cookieValue(alloc, "sess_123", secret);
    defer alloc.free(val);
    var tampered = try alloc.dupe(u8, val);
    defer alloc.free(tampered);
    tampered[0] ^= 0xff;
    try std.testing.expect(verifyCookie(tampered, secret) == null);
}

test "verifyCookie rejects weak active and migration secrets" {
    mer.resetEnv();
    defer mer.resetEnv();

    const weak = "guessable";
    const val = try cookieValue(std.testing.allocator, "sess_123", weak);
    defer std.testing.allocator.free(val);
    try std.testing.expect(verifyCookie(val, weak) == null);

    try mer.putEnv(DEPRECATED_SESSION_SECRET, weak);
    try std.testing.expect(verifyCookie(val, "") == null);
}
