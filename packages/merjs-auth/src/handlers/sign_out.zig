//! POST /auth/sign-out
//!
//! Destroys the server-side session and clears the session + CSRF cookies.

const std = @import("std");
const mer = @import("mer");
const session = @import("../session.zig");
const AuthContext = @import("../auth.zig").AuthContext;

pub fn handle(ctx: *AuthContext) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    // 1. Read session cookie. If missing, already logged out.
    const cookie_val = ctx.req.cookie(ctx.config.session_cookie) orelse {
        return mer.json("{\"ok\":true}");
    };

    // 2. Verify HMAC. If invalid, treat as already logged out.
    const session_id = session.verifyCookie(cookie_val, ctx.config.secret) orelse {
        return mer.json("{\"ok\":true}");
    };

    // 4. Delete session from DB.
    try ctx.db.exec(
        alloc,
        "DELETE FROM mauth_sessions WHERE id = $1",
        &.{.{ .text = session_id }},
    );

    // 5. Return 200 with expired session + CSRF cookies.
    const expired_session = mer.SetCookie{
        .name = ctx.config.session_cookie,
        .value = "",
        .path = "/",
        .max_age = 0,
        .http_only = true,
        .secure = ctx.config.secure_cookies,
        .same_site = .lax,
    };
    const expired_csrf = mer.SetCookie{
        .name = session.CSRF_COOKIE,
        .value = "",
        .path = "/",
        .max_age = 0,
        .http_only = false,
        .secure = ctx.config.secure_cookies,
        .same_site = .strict,
    };

    const base_resp = mer.Response{
        .status = .ok,
        .body = "{\"ok\":true}",
        .content_type = "application/json",
        .cookies = &.{},
    };
    return mer.withCookies(base_resp, &.{ expired_session, expired_csrf });
}
