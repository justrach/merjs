//! POST /auth/reset-password
//!
//! Consumes a password-reset token and sets a new password.
//! Revokes all existing sessions to force re-login everywhere.

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
    const parsed = (mer.parseJson(ResetPasswordBody, ctx.req) catch {
        return mer.badRequest("invalid request body");
    }) orelse return mer.badRequest("invalid request body");
    defer parsed.deinit();
    const body = parsed.value;

    // 2. Validate new password strength.
    if (!password.isStrong(body.new_password)) {
        return mer.badRequest("password must be 8–128 characters");
    }

    // 3. Hash the submitted token.
    const hash_bytes = token_mod.hashForStorage(body.token);
    const hash_hex = token_mod.hashToHex(hash_bytes);

    // 4. Perform the fallible password hash before claiming the token.
    const new_hash = password.hash(alloc, body.new_password, ctx.config.argon2_params) catch |err| {
        if (err == error.CapacityExhausted) return mer.Response.init(
            .service_unavailable,
            .json,
            "{\"error\":\"password service busy\"}",
        );
        return err;
    };

    // 5. Consume the token, update the password, and revoke sessions in one
    // statement so every durable side effect commits or rolls back together.
    var tok_result = try ctx.db.query(alloc,
        \\WITH consumed AS (
        \\  UPDATE mauth_tokens
        \\  SET used_at = NOW()
        \\  WHERE token_hash = $1
        \\    AND purpose = $2
        \\    AND used_at IS NULL
        \\    AND expires_at > NOW()
        \\  RETURNING user_id
        \\), updated AS (
        \\  UPDATE mauth_oauth_accounts AS account
        \\  SET password_hash = $3, updated_at = NOW()
        \\  FROM consumed
        \\  WHERE account.user_id = consumed.user_id AND account.provider_id = 'email'
        \\  RETURNING account.user_id
        \\), revoked AS (
        \\  DELETE FROM mauth_sessions AS session
        \\  USING updated
        \\  WHERE session.user_id = updated.user_id
        \\)
        \\SELECT user_id FROM updated
    , &.{
        .{ .text = &hash_hex },
        .{ .text = "password_reset" },
        .{ .text = new_hash },
    });
    defer tok_result.deinit();

    // 6. Token not found or expired.
    if (tok_result.rows.len == 0) {
        return mer.Response{
            .status = .bad_request,
            .body = "{\"error\":\"invalid or expired reset token\"}",
            .content_type = .json,
            .cookies = &.{},
        };
    }

    _ = db.rowText(tok_result.rows[0], "user_id") orelse return mer.internalError("db error");

    return mer.json("{\"ok\":true}");
}
