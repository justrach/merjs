//! POST /auth/change-password
//!
//! Authenticated endpoint. Changes the user's password and revokes all
//! other sessions so devices with the old password are logged out.

const std = @import("std");
const mer = @import("mer");
const db = @import("../db/root.zig");
const password = @import("../password.zig");
const session = @import("../session.zig");
const csrf = @import("../csrf.zig");
const AuthContext = @import("../auth.zig").AuthContext;

const ChangePasswordBody = struct {
    current_password: []const u8,
    new_password: []const u8,
};

pub fn handle(ctx: *AuthContext) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    // 1. Require authenticated session.
    const cookie_val = ctx.req.cookie(ctx.config.session_cookie) orelse {
        return mer.Response{
            .status = .unauthorized,
            .body = "{\"error\":\"not authenticated\"}",
            .content_type = "application/json",
            .cookies = &.{},
        };
    };
    const session_id = session.verifyCookie(cookie_val, ctx.config.secret) orelse {
        return mer.Response{
            .status = .unauthorized,
            .body = "{\"error\":\"not authenticated\"}",
            .content_type = "application/json",
            .cookies = &.{},
        };
    };

    // 2. Validate CSRF.
    csrf.validateCsrfCookie(ctx.req, session_id, ctx.config.secret) catch {
        return mer.Response{
            .status = .forbidden,
            .body = "{\"error\":\"invalid csrf token\"}",
            .content_type = "application/json",
            .cookies = &.{},
        };
    };

    // Look up user_id from session.
    const now_str = try std.fmt.allocPrint(alloc, "{d}", .{ctx.now_unix});
    defer alloc.free(now_str);

    var sess_result = try ctx.db.query(
        alloc,
        "SELECT user_id FROM mauth_sessions WHERE id = $1 AND expires_at > to_timestamp($2)",
        &.{
            .{ .text = session_id },
            .{ .text = now_str },
        },
    );
    defer sess_result.deinit();

    if (sess_result.rows.len == 0) {
        return mer.Response{
            .status = .unauthorized,
            .body = "{\"error\":\"session expired\"}",
            .content_type = "application/json",
            .cookies = &.{},
        };
    }
    const user_id = db.rowText(sess_result.rows[0], "user_id") orelse return mer.internalError("db error");

    // 3. Parse body.
    const parsed = mer.parseJson(ChangePasswordBody, ctx.req) catch {
        return mer.badRequest("invalid request body");
    };
    defer parsed.deinit();
    const body = parsed.value;

    // 4. Validate new password strength.
    if (!password.isStrong(body.new_password)) {
        return mer.badRequest("new password must be 8–128 characters");
    }

    // 5. Get current password hash.
    var acc_result = try ctx.db.query(
        alloc,
        "SELECT password_hash FROM mauth_oauth_accounts WHERE user_id = $1 AND provider_id = 'email'",
        &.{.{ .text = user_id }},
    );
    defer acc_result.deinit();

    if (acc_result.rows.len == 0) {
        return mer.badRequest("no email account found");
    }
    const current_hash = db.rowText(acc_result.rows[0], "password_hash") orelse return mer.internalError("db error");

    // 6. Verify current password.
    if (!password.verify(alloc, body.current_password, current_hash)) {
        return mer.Response{
            .status = .unauthorized,
            .body = "{\"error\":\"current password is incorrect\"}",
            .content_type = "application/json",
            .cookies = &.{},
        };
    }

    // 7. Hash new password.
    const new_hash = try password.hash(alloc, body.new_password, ctx.config.argon2_params);

    // 8. Update password.
    try ctx.db.exec(
        alloc,
        "UPDATE mauth_oauth_accounts SET password_hash=$1, updated_at=NOW() WHERE user_id=$2 AND provider_id='email'",
        &.{
            .{ .text = new_hash },
            .{ .text = user_id },
        },
    );

    // 9. Revoke all sessions except current.
    try ctx.db.exec(
        alloc,
        "DELETE FROM mauth_sessions WHERE user_id=$1 AND id != $2",
        &.{
            .{ .text = user_id },
            .{ .text = session_id },
        },
    );

    return mer.json("{\"ok\":true}");
}
