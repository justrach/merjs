//! POST /auth/reset-password
//!
//! Consumes a password-reset token and sets a new password.
//! Revokes all existing sessions to force re-login everywhere.

const std = @import("std");
const mer = @import("mer");
const db = @import("../db/root.zig");
const password = @import("../password.zig");
const token_mod = @import("../token.zig");
const AuthContext = @import("../auth.zig").AuthContext;

const ResetPasswordBody = struct {
    token: []const u8,
    new_password: []const u8,
};

pub fn handle(ctx: *AuthContext) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    // 1. Parse body.
    const parsed = mer.parseJson(ResetPasswordBody, ctx.req) catch {
        return mer.badRequest("invalid request body");
    };
    defer parsed.deinit();
    const body = parsed.value;

    // 2. Validate new password strength.
    if (!password.isStrong(body.new_password)) {
        return mer.badRequest("password must be 8–128 characters");
    }

    // 3. Hash the submitted token.
    const hash_bytes = token_mod.hashForStorage(body.token);
    const hash_hex = token_mod.hashToHex(hash_bytes);
    const now_str = try std.fmt.allocPrint(alloc, "{d}", .{ctx.now_unix});
    defer alloc.free(now_str);

    // 4. Look up token in DB.
    var tok_result = try ctx.db.query(alloc,
        \\SELECT t.id, t.user_id, t.expires_at
        \\FROM mauth_tokens t
        \\WHERE t.token_hash = $1
        \\  AND t.purpose = 'password_reset'
        \\  AND t.used_at IS NULL
        \\  AND t.expires_at > to_timestamp($2)
    , &.{
        .{ .text = &hash_hex },
        .{ .text = now_str },
    });
    defer tok_result.deinit();

    // 5. Token not found or expired.
    if (tok_result.rows.len == 0) {
        return mer.Response{
            .status = .bad_request,
            .body = "{\"error\":\"invalid or expired reset token\"}",
            .content_type = "application/json",
            .cookies = &.{},
        };
    }

    const token_id = db.rowText(tok_result.rows[0], "id") orelse return mer.internalError("db error");
    const user_id = db.rowText(tok_result.rows[0], "user_id") orelse return mer.internalError("db error");

    // 6. Mark token used.
    try ctx.db.exec(
        alloc,
        "UPDATE mauth_tokens SET used_at=NOW() WHERE id=$1",
        &.{.{ .text = token_id }},
    );

    // 7. Hash new password.
    const new_hash = try password.hash(alloc, body.new_password, ctx.config.argon2_params);

    // 8. Update account password.
    try ctx.db.exec(
        alloc,
        "UPDATE mauth_oauth_accounts SET password_hash=$1, updated_at=NOW() WHERE user_id=$2 AND provider_id='email'",
        &.{
            .{ .text = new_hash },
            .{ .text = user_id },
        },
    );

    // 9. Revoke all sessions for this user.
    try ctx.db.exec(
        alloc,
        "DELETE FROM mauth_sessions WHERE user_id=$1",
        &.{.{ .text = user_id }},
    );

    return mer.json("{\"ok\":true}");
}
