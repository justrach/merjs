//! POST /auth/forgot-password
//!
//! Sends a password reset email. Always returns 200 to prevent email enumeration.

const std = @import("std");
const mer = @import("mer");
const db = @import("../db/root.zig");
const crypto = @import("../crypto.zig");
const token_mod = @import("../token.zig");
const email_mod = @import("../email.zig");
const rate_limit = @import("../rate_limit.zig");
const AuthContext = @import("../auth.zig").AuthContext;

const SendResetBody = struct { email: []const u8 };

const OK_RESPONSE = "{\"ok\":true,\"message\":\"If that email is registered, you'll receive a reset link.\"}";

pub fn handle(ctx: *AuthContext) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    // 2. Parse body.
    const parsed = mer.parseJson(SendResetBody, ctx.req) catch {
        return mer.badRequest("invalid request body");
    };
    defer parsed.deinit();
    const body = parsed.value;

    const email_norm = try alloc.dupe(u8, body.email);
    std.ascii.lowerString(email_norm, body.email);

    // 1. Rate limit by email hash (max 3 per hour). Always return 200 regardless.
    const email_hash = try rate_limit.hashKey(email_norm, alloc);
    defer alloc.free(email_hash);
    rate_limit.check(ctx.db, email_hash, .{ .max_attempts = 3, .window_s = 3600 }, alloc) catch |err| {
        if (err == error.RateLimited) return mer.json(OK_RESPONSE);
        return err;
    };

    // 3. Always return 200 — look up silently.
    var user_result = try ctx.db.query(
        alloc,
        "SELECT id FROM mauth_users WHERE email = $1",
        &.{.{ .text = email_norm }},
    );
    defer user_result.deinit();

    // 4. If user not found, return 200 with no email sent.
    if (user_result.rows.len == 0) {
        return mer.json(OK_RESPONSE);
    }

    const user_id = db.rowText(user_result.rows[0], "id") orelse return mer.json(OK_RESPONSE);

    // 6. Delete any existing password_reset tokens for this user.
    try ctx.db.exec(
        alloc,
        "DELETE FROM mauth_tokens WHERE user_id=$1 AND purpose='password_reset'",
        &.{.{ .text = user_id }},
    );

    // 5. Generate reset token + hash.
    const raw_token = try token_mod.generate(alloc);
    const hash_bytes = token_mod.hashForStorage(raw_token);
    const hash_hex = token_mod.hashToHex(hash_bytes);
    const token_id = try crypto.generateUuid(alloc);
    const ttl = token_mod.ttlForPurpose(.password_reset);
    const expires_at = ctx.now_unix + @as(i64, ttl);
    const expires_str = try std.fmt.allocPrint(alloc, "{d}", .{expires_at});

    // 7. Insert new token.
    try ctx.db.exec(alloc,
        \\INSERT INTO mauth_tokens(id, user_id, token_hash, purpose, expires_at, created_at)
        \\VALUES($1,$2,$3,'password_reset',to_timestamp($4),NOW())
    , &.{
        .{ .text = token_id },
        .{ .text = user_id },
        .{ .text = &hash_hex },
        .{ .text = expires_str },
    });

    // 8. Send email if hook is set.
    if (ctx.config.send_email) |send_fn| {
        var msg = try email_mod.buildPasswordReset(alloc, ctx.config.base_url, raw_token);
        msg.to = email_norm;
        send_fn(msg, alloc) catch {}; // non-fatal
    }

    return mer.json(OK_RESPONSE);
}
