//! POST /auth/send-verification-email
//!
//! (Re)sends a verification email to the authenticated user.

const std = @import("std");
const mer = @import("mer");
const db = @import("../db/root.zig");
const crypto = @import("../crypto.zig");
const token_mod = @import("../token.zig");
const email_mod = @import("../email.zig");
const rate_limit = @import("../rate_limit.zig");
const session = @import("../session.zig");
const AuthContext = @import("../auth.zig").AuthContext;

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

    // Resolve user_id + email from session.
    const now_str = try std.fmt.allocPrint(alloc, "{d}", .{ctx.now_unix});
    defer alloc.free(now_str);

    var sess_result = try ctx.db.query(alloc,
        \\SELECT s.user_id, u.email, u.email_verified
        \\FROM mauth_sessions s
        \\JOIN mauth_users u ON s.user_id = u.id
        \\WHERE s.id = $1 AND s.expires_at > to_timestamp($2)
    , &.{
        .{ .text = session_id },
        .{ .text = now_str },
    });
    defer sess_result.deinit();

    if (sess_result.rows.len == 0) {
        return mer.Response{
            .status = .unauthorized,
            .body = "{\"error\":\"session expired\"}",
            .content_type = "application/json",
            .cookies = &.{},
        };
    }

    const row = sess_result.rows[0];
    const user_id = db.rowText(row, "user_id") orelse return mer.internalError("db error");
    const user_email = db.rowText(row, "email") orelse return mer.internalError("db error");
    const verified = db.rowBool(row, "email_verified") orelse false;

    // 2. Rate limit by user_id (max 3 per hour).
    const uid_hash = try rate_limit.hashKey(user_id, alloc);
    defer alloc.free(uid_hash);
    rate_limit.check(ctx.db, uid_hash, .{ .max_attempts = 3, .window_s = 3600 }, alloc) catch |err| {
        if (err == error.RateLimited) return mer.json("{\"error\":\"too many requests\"}");
        return err;
    };

    // 3. Already verified?
    if (verified) {
        return mer.json("{\"ok\":true,\"already_verified\":true}");
    }

    // 4. Delete existing email_verify tokens for this user.
    try ctx.db.exec(
        alloc,
        "DELETE FROM mauth_tokens WHERE user_id=$1 AND purpose='email_verify'",
        &.{.{ .text = user_id }},
    );

    // 5. Generate + hash token, insert.
    const raw_token = try token_mod.generate(alloc);
    const hash_bytes = token_mod.hashForStorage(raw_token);
    const hash_hex = token_mod.hashToHex(hash_bytes);
    const token_id = try crypto.generateUuid(alloc);
    const ttl = token_mod.ttlForPurpose(.email_verify);
    const expires_at = ctx.now_unix + @as(i64, ttl);
    const expires_str = try std.fmt.allocPrint(alloc, "{d}", .{expires_at});

    try ctx.db.exec(alloc,
        \\INSERT INTO mauth_tokens(id, user_id, token_hash, purpose, expires_at, created_at)
        \\VALUES($1,$2,$3,'email_verify',to_timestamp($4),NOW())
    , &.{
        .{ .text = token_id },
        .{ .text = user_id },
        .{ .text = &hash_hex },
        .{ .text = expires_str },
    });

    // 6. Send verification email.
    if (ctx.config.send_email) |send_fn| {
        var msg = try email_mod.buildVerifyEmail(alloc, ctx.config.base_url, raw_token);
        msg.to = user_email;
        send_fn(msg, alloc) catch {}; // non-fatal
    }

    return mer.json("{\"ok\":true}");
}
