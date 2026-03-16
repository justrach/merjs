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
    const now_str = try std.fmt.allocPrint(alloc, "{d}", .{ctx.now_unix});
    defer alloc.free(now_str);

    var tok_result = try ctx.db.query(alloc,
        \\SELECT t.id, t.user_id
        \\FROM mauth_tokens t
        \\WHERE t.token_hash = $1
        \\  AND t.purpose = 'email_verify'
        \\  AND t.used_at IS NULL
        \\  AND t.expires_at > to_timestamp($2)
    , &.{
        .{ .text = &hash_hex },
        .{ .text = now_str },
    });
    defer tok_result.deinit();

    // 3. Token invalid.
    if (tok_result.rows.len == 0) {
        const url = try std.fmt.allocPrint(alloc, "{s}?error=invalid_token", .{ctx.config.base_url});
        return mer.redirect(url, .see_other);
    }

    const token_id = db.rowText(tok_result.rows[0], "id") orelse return mer.internalError("db error");
    const user_id = db.rowText(tok_result.rows[0], "user_id") orelse return mer.internalError("db error");

    // 4. Mark token used.
    try ctx.db.exec(
        alloc,
        "UPDATE mauth_tokens SET used_at=NOW() WHERE id=$1",
        &.{.{ .text = token_id }},
    );

    // 5. Mark user email as verified.
    try ctx.db.exec(
        alloc,
        "UPDATE mauth_users SET email_verified=true, updated_at=NOW() WHERE id=$1",
        &.{.{ .text = user_id }},
    );

    // 6. Redirect to success URL.
    const url = try std.fmt.allocPrint(alloc, "{s}?verified=true", .{ctx.config.base_url});
    return mer.redirect(url, .see_other);
}
