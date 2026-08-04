//! GET /auth/verify-email?token=...
//!
//! Consumes an email-verification token and marks the user's email as verified.
//! Redirects to the app on completion (success or failure) so it works as a
//! click-through link inside an email.

const std = @import("std");
const mer = @import("mer");
const db = @import("../db/root.zig");
const token_mod = @import("../token.zig");
const AuthContext = @import("../auth.zig").AuthContext;

pub fn handle(ctx: *AuthContext) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    // 1. Read token from query params.
    const raw_token = ctx.req.queryParam("token") orelse {
        const url = try std.fmt.allocPrint(alloc, "{s}?error=missing_token", .{ctx.config.base_url});
        return mer.redirect(url, .see_other);
    };

    // 2. Hash token and query DB.
    const hash_bytes = token_mod.hashForStorage(raw_token);
    const hash_hex = token_mod.hashToHex(hash_bytes);

    var tok_result = try ctx.db.query(alloc,
        \\WITH consumed AS (
        \\  UPDATE mauth_tokens
        \\  SET used_at = NOW()
        \\  WHERE token_hash = $1
        \\    AND purpose = $2
        \\    AND used_at IS NULL
        \\    AND expires_at > NOW()
        \\  RETURNING user_id
        \\), verified AS (
        \\  UPDATE mauth_users AS users
        \\  SET email_verified = true, updated_at = NOW()
        \\  FROM consumed
        \\  WHERE users.id = consumed.user_id
        \\  RETURNING users.id AS user_id
        \\)
        \\SELECT user_id FROM verified
    , &.{
        .{ .text = &hash_hex },
        .{ .text = "email_verify" },
    });
    defer tok_result.deinit();

    // 3. Token invalid.
    if (tok_result.rows.len == 0) {
        const url = try std.fmt.allocPrint(alloc, "{s}?error=invalid_token", .{ctx.config.base_url});
        return mer.redirect(url, .see_other);
    }

    _ = db.rowText(tok_result.rows[0], "user_id") orelse return mer.internalError("db error");

    // 5. Redirect to success URL.
    const url = try std.fmt.allocPrint(alloc, "{s}?verified=true", .{ctx.config.base_url});
    return mer.redirect(url, .see_other);
}
