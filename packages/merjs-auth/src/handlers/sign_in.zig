//! POST /auth/sign-in/email
//!
//! Authenticate with email + password. Returns a session cookie on success.

const std = @import("std");
const mer = @import("mer");
const db = @import("../db/root.zig");
const crypto = @import("../crypto.zig");
const password = @import("../password.zig");
const session = @import("../session.zig");
const rate_limit = @import("../rate_limit.zig");
const csrf = @import("../csrf.zig");
const AuthContext = @import("../auth.zig").AuthContext;

const SignInBody = struct {
    email: []const u8,
    password: []const u8,
    remember_me: bool = false,
};

pub fn handle(ctx: *AuthContext) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    // 1. Rate limit by email hash (max 5/15min) + IP hash (max 20/15min).
    const parsed = mer.parseJson(SignInBody, ctx.req) catch {
        return mer.badRequest("invalid request body");
    };
    defer parsed.deinit();
    const body = parsed.value;

    const email_norm = try alloc.dupe(u8, body.email);
    std.ascii.lowerString(email_norm, body.email);

    const email_hash = try rate_limit.hashKey(email_norm, alloc);
    defer alloc.free(email_hash);
    rate_limit.check(ctx.db, email_hash, .{ .max_attempts = 5, .window_s = 900 }, alloc) catch |err| {
        if (err == error.RateLimited) return mer.json("{\"error\":\"too many requests\"}");
        return err;
    };

    const ip = ctx.req.queryParam("x-forwarded-for") orelse "unknown";
    const ip_hash = try rate_limit.hashKey(ip, alloc);
    defer alloc.free(ip_hash);
    rate_limit.check(ctx.db, ip_hash, .{ .max_attempts = 20, .window_s = 900 }, alloc) catch |err| {
        if (err == error.RateLimited) return mer.json("{\"error\":\"too many requests\"}");
        return err;
    };

    // 4. Find user + account.
    var result = try ctx.db.query(alloc,
        \\SELECT u.id, u.name, u.email, u.email_verified, a.password_hash
        \\FROM mauth_users u
        \\JOIN mauth_oauth_accounts a ON a.user_id = u.id
        \\WHERE u.email = $1 AND a.provider_id = 'email'
    , &.{.{ .text = email_norm }});
    defer result.deinit();

    // 5. Not found: constant-time delay to prevent enumeration, then 401.
    if (result.rows.len == 0) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        return mer.Response{
            .status = .unauthorized,
            .body = "{\"error\":\"invalid credentials\"}",
            .content_type = "application/json",
            .cookies = &.{},
        };
    }

    const row = result.rows[0];
    const pw_hash = db.rowText(row, "password_hash") orelse {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        return mer.Response{
            .status = .unauthorized,
            .body = "{\"error\":\"invalid credentials\"}",
            .content_type = "application/json",
            .cookies = &.{},
        };
    };

    // 6. Verify password.
    if (!password.verify(alloc, body.password, pw_hash)) {
        return mer.Response{
            .status = .unauthorized,
            .body = "{\"error\":\"invalid credentials\"}",
            .content_type = "application/json",
            .cookies = &.{},
        };
    }

    const user_id = db.rowText(row, "id") orelse return mer.internalError("db error");
    const user_name = db.rowText(row, "name") orelse "";
    const user_email = db.rowText(row, "email") orelse email_norm;
    const email_verified = db.rowBool(row, "email_verified") orelse false;

    // 7. Create session. TTL: remember_me → config TTL (7d), else 24h.
    const ttl_s: u32 = if (body.remember_me) ctx.config.session_ttl_s else 86400;
    const session_token = try crypto.generateToken(alloc);
    const session_id = try crypto.generateUuid(alloc);
    const session_expires = ctx.now_unix + @as(i64, ttl_s);
    const session_expires_str = try std.fmt.allocPrint(alloc, "{d}", .{session_expires});

    // 8. Insert session.
    try ctx.db.exec(alloc,
        \\INSERT INTO mauth_sessions(id, user_id, token, expires_at, created_at, updated_at)
        \\VALUES($1,$2,$3,to_timestamp($4),NOW(),NOW())
    , &.{
        .{ .text = session_id },
        .{ .text = user_id },
        .{ .text = session_token },
        .{ .text = session_expires_str },
    });

    // 9. Generate CSRF token.
    const csrf_token = try csrf.generateCsrfToken(session_id, ctx.config.secret, alloc);

    // 10. Return 200 with user + session data.
    const resp_body = try std.fmt.allocPrint(alloc,
        \\{{"user":{{"id":"{s}","email":"{s}","name":"{s}","email_verified":{s}}},"session":{{"expires_at":{d}}}}}
    , .{
        user_id,
        user_email,
        user_name,
        if (email_verified) "true" else "false",
        session_expires,
    });

    const session_cookie = try session.cookieSettings(
        session_id,
        ctx.config.secret,
        ttl_s,
        ctx.config.secure_cookies,
        alloc,
    );
    const csrf_cookie = csrf.csrfCookieSettings(csrf_token, ctx.config.secure_cookies);

    const base_resp = mer.Response{
        .status = .ok,
        .body = resp_body,
        .content_type = "application/json",
        .cookies = &.{},
    };
    return mer.withCookies(base_resp, &.{ session_cookie, csrf_cookie });
}
