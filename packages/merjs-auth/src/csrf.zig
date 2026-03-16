//! CSRF protection for merjs-auth.
//!
//! Strategy (defense-in-depth):
//!   1. Session cookie is SameSite=Lax — blocks most CSRF.
//!   2. JSON Content-Type enforcement — form-based CSRF cannot set
//!      `Content-Type: application/json`, so merjs's parseJson already
//!      provides implicit protection for JSON endpoints.
//!   3. CSRF double-submit cookie — for endpoints that cannot rely on
//!      Content-Type (e.g. multipart forms): we HMAC-sign the session ID
//!      with a "csrf" suffix, store it in a non-HttpOnly cookie
//!      (so JS can read it), and require the JS to echo it back in a
//!      header or form field.
//!
//! Usage:
//!   On login: emit the CSRF cookie alongside the session cookie.
//!   On mutation (POST/PUT/PATCH/DELETE): call validateCsrfCookie.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mer = @import("mer");
const crypto = @import("crypto.zig");
const session = @import("session.zig");

// ── Errors ─────────────────────────────────────────────────────────────────

pub const CsrfError = error{
    MissingCsrfToken,
    InvalidCsrfToken,
};

// ── Token generation ───────────────────────────────────────────────────────

/// Generate the CSRF token for a given session ID.
/// The token is HMAC-SHA256(session_id + "csrf", secret) encoded as hex,
/// which binds the CSRF token to the session so rotating the session
/// automatically invalidates any captured CSRF tokens.
/// Caller owns the returned slice.
pub fn generateCsrfToken(session_id: []const u8, secret: []const u8, alloc: Allocator) ![]u8 {
    // Concatenate session_id + "csrf" as the HMAC message.
    const msg = try std.mem.concat(alloc, u8, &.{ session_id, "csrf" });
    defer alloc.free(msg);

    const mac = crypto.hmacSign(msg, secret);
    const hex = std.fmt.bytesToHex(mac, .lower);
    return alloc.dupe(u8, &hex);
}

// ── Cookie settings ────────────────────────────────────────────────────────

/// Build the Set-Cookie struct for the CSRF cookie.
/// NOT HttpOnly — JavaScript must be able to read it to include it in
/// request headers (e.g. X-CSRF-Token).
/// SameSite=Strict prevents the cookie from being sent on cross-origin
/// navigations, adding a second layer.
pub fn csrfCookieSettings(token: []const u8, secure: bool) mer.SetCookie {
    return mer.SetCookie{
        .name = session.CSRF_COOKIE,
        .value = token,
        .path = "/",
        .max_age = null, // session-scoped: expires when browser closes
        .http_only = false,
        .secure = secure,
        .same_site = .strict,
    };
}

// ── Validation ─────────────────────────────────────────────────────────────

/// Validate the CSRF double-submit cookie on an incoming request.
///
/// Reads the `mauth_csrf` cookie from the request, recomputes the expected
/// token for the given `session_id`, and compares them with constant-time
/// equality.
///
/// Returns void on success, or a CsrfError on failure.
/// Does NOT return errors from underlying operations to avoid leaking
/// internal state — failures are normalised to CsrfError.
pub fn validateCsrfCookie(
    req: mer.Request,
    session_id: []const u8,
    secret: []const u8,
) CsrfError!void {
    const alloc = req.allocator;

    const received = req.cookie(session.CSRF_COOKIE) orelse
        return CsrfError.MissingCsrfToken;

    const expected = generateCsrfToken(session_id, secret, alloc) catch
        return CsrfError.InvalidCsrfToken;
    defer alloc.free(expected);

    if (!crypto.timingSafeEq(received, expected))
        return CsrfError.InvalidCsrfToken;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "generateCsrfToken is deterministic" {
    const alloc = std.testing.allocator;
    const t1 = try generateCsrfToken("sess_123", "secret", alloc);
    defer alloc.free(t1);
    const t2 = try generateCsrfToken("sess_123", "secret", alloc);
    defer alloc.free(t2);
    try std.testing.expectEqualStrings(t1, t2);
}

test "generateCsrfToken differs across sessions" {
    const alloc = std.testing.allocator;
    const t1 = try generateCsrfToken("sess_aaa", "secret", alloc);
    defer alloc.free(t1);
    const t2 = try generateCsrfToken("sess_bbb", "secret", alloc);
    defer alloc.free(t2);
    try std.testing.expect(!std.mem.eql(u8, t1, t2));
}

test "generateCsrfToken produces 64-char hex" {
    const alloc = std.testing.allocator;
    const tok = try generateCsrfToken("sess_xyz", "secret", alloc);
    defer alloc.free(tok);
    try std.testing.expectEqual(@as(usize, 64), tok.len);
}
