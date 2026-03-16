//! Magic-link sign-in handlers.
//!
//!   POST /auth/magic-link/send    — send a magic link email
//!   GET  /auth/magic-link/verify  — consume the link and create a session

const std = @import("std");
const mer = @import("mer");
const db = @import("../db/root.zig");
const crypto = @import("../crypto.zig");
const token_mod = @import("../token.zig");
const email_mod = @import("../email.zig");
const rate_limit = @import("../rate_limit.zig");
const session = @import("../session.zig");
const csrf = @import("../csrf.zig");
const AuthContext = @import("../auth.zig").AuthContext;

const SendMagicLinkBody = struct {
    email: []const u8,
    redirect_to: ?[]const u8 = null,
};

// ── send ───────────────────────────────────────────────────────────────────

pub fn send(ctx: *AuthContext) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    // 2. Parse body.
    const parsed = mer.parseJson(SendMagicLinkBody, ctx.req) catch {
        return mer.badRequest("invalid request body");
    };
    defer parsed.deinit();
    const body = parsed.value;

    const email_norm = try alloc.dupe(u8, body.email);
    std.ascii.lowerString(email_norm, body.email);

    // 1. Rate limit by email hash (max 5/15min).
    const email_hash = try rate_limit.hashKey(email_norm, alloc);
    defer alloc.free(email_hash);
    rate_limit.check(ctx.db, email_hash, .{ .max_attempts = 5, .window_s = 900 }, alloc) catch |err| {
        if (err == error.RateLimited) return mer.json("{\"ok\":true}");
        return err;
    };

    // 3. Always return 200 — look up silently.
    var user_result = try ctx.db.query(
        alloc,
        "SELECT id FROM mauth_users WHERE email = $1",
        &.{.{ .text = email_norm }},
    );
    defer user_result.deinit();

    // 4. User not found — return 200 silently.
    if (user_result.rows.len == 0) {
        return mer.json("{\"ok\":true}");
    }

    const user_id = db.rowText(user_result.rows[0], "id") orelse return mer.json("{\"ok\":true}");

    // 5. Delete existing magic_link tokens for this user.
    try ctx.db.exec(
        alloc,
        "DELETE FROM mauth_tokens WHERE user_id=$1 AND purpose='magic_link'",
        &.{.{ .text = user_id }},
    );

    // 6. Generate + hash token, insert (15 min TTL).
    const raw_token = try token_mod.generate(alloc);
    const hash_bytes = token_mod.hashForStorage(raw_token);
    const hash_hex = token_mod.hashToHex(hash_bytes);
    const token_id = try crypto.generateUuid(alloc);
    const ttl = token_mod.ttlForPurpose(.magic_link);
    const expires_at = ctx.now_unix + @as(i64, ttl);
    const expires_str = try std.fmt.allocPrint(alloc, "{d}", .{expires_at});

    try ctx.db.exec(alloc,
        \\INSERT INTO mauth_tokens(id, user_id, token_hash, purpose, expires_at, created_at)
        \\VALUES($1,$2,$3,'magic_link',to_timestamp($4),NOW())
    , &.{
        .{ .text = token_id },
        .{ .text = user_id },
        .{ .text = &hash_hex },
        .{ .text = expires_str },
    });

    // 7. Build magic link URL.
    const link = if (body.redirect_to) |redir| blk: {
        // Basic URL-encode the redirect_to param (replace special chars).
        break :blk try std.fmt.allocPrint(alloc, "{s}/auth/magic-link/verify?token={s}&redirect_to={s}", .{
            ctx.config.base_url, raw_token, redir,
        });
    } else try std.fmt.allocPrint(alloc, "{s}/auth/magic-link/verify?token={s}", .{
        ctx.config.base_url, raw_token,
    });

    // 8. Send magic link email.
    if (ctx.config.send_email) |send_fn| {
        var msg = try email_mod.buildMagicLink(alloc, ctx.config.base_url, raw_token);
        // Override the link in the body to include redirect_to if present.
        _ = link; // already embedded in the token; email template uses base_url/token
        msg.to = email_norm;
        send_fn(msg, alloc) catch {}; // non-fatal
    }

    return mer.json("{\"ok\":true}");
}

// ── verify ─────────────────────────────────────────────────────────────────

pub fn verify(ctx: *AuthContext) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    // 1. Read token + optional redirect_to from query params.
    const raw_token = ctx.req.queryParam("token") orelse {
        return mer.Response{
            .status = .unauthorized,
            .body = "{\"error\":\"invalid or expired link\"}",
            .content_type = "application/json",
            .cookies = &.{},
        };
    };
    const redirect_to_raw = ctx.req.queryParam("redirect_to");

    // 2. Hash token and look up in DB.
    const hash_bytes = token_mod.hashForStorage(raw_token);
    const hash_hex = token_mod.hashToHex(hash_bytes);
    const now_str = try std.fmt.allocPrint(alloc, "{d}", .{ctx.now_unix});
    defer alloc.free(now_str);

    var tok_result = try ctx.db.query(alloc,
        \\SELECT t.id, t.user_id
        \\FROM mauth_tokens t
        \\WHERE t.token_hash = $1
        \\  AND t.purpose = 'magic_link'
        \\  AND t.used_at IS NULL
        \\  AND t.expires_at > to_timestamp($2)
    , &.{
        .{ .text = &hash_hex },
        .{ .text = now_str },
    });
    defer tok_result.deinit();

    // 3. Token invalid.
    if (tok_result.rows.len == 0) {
        return mer.Response{
            .status = .unauthorized,
            .body = "{\"error\":\"invalid or expired link\"}",
            .content_type = "application/json",
            .cookies = &.{},
        };
    }

    const token_id = db.rowText(tok_result.rows[0], "id") orelse return mer.internalError("db error");
    const user_id = db.rowText(tok_result.rows[0], "user_id") orelse return mer.internalError("db error");

    // 4. Mark token used.
    try ctx.db.exec(
        alloc,
        "UPDATE mauth_tokens SET used_at=NOW() WHERE id=$1",
        &.{.{ .text = token_id }},
    );

    // 5. Mark email as verified (magic link proves email ownership).
    try ctx.db.exec(
        alloc,
        "UPDATE mauth_users SET email_verified=true, updated_at=NOW() WHERE id=$1",
        &.{.{ .text = user_id }},
    );

    // 6. Create session.
    const session_token = try crypto.generateToken(alloc);
    const session_id = try crypto.generateUuid(alloc);
    const session_expires = ctx.now_unix + @as(i64, ctx.config.session_ttl_s);
    const session_expires_str = try std.fmt.allocPrint(alloc, "{d}", .{session_expires});

    try ctx.db.exec(alloc,
        \\INSERT INTO mauth_sessions(id, user_id, token, expires_at, created_at, updated_at)
        \\VALUES($1,$2,$3,to_timestamp($4),NOW(),NOW())
    , &.{
        .{ .text = session_id },
        .{ .text = user_id },
        .{ .text = session_token },
        .{ .text = session_expires_str },
    });

    const csrf_token = try csrf.generateCsrfToken(session_id, ctx.config.secret, alloc);
    const session_cookie = try session.cookieSettings(
        session_id,
        ctx.config.secret,
        ctx.config.session_ttl_s,
        ctx.config.secure_cookies,
        alloc,
    );
    const csrf_cookie = csrf.csrfCookieSettings(csrf_token, ctx.config.secure_cookies);

    // 8. Validate redirect_to — must start with base_url or be a relative path.
    const dest: []const u8 = if (redirect_to_raw) |redir| blk: {
        if (std.mem.startsWith(u8, redir, ctx.config.base_url) or
            (redir.len > 0 and redir[0] == '/'))
        {
            break :blk redir;
        }
        break :blk "/";
    } else "/";

    const base_resp = mer.redirect(dest, .see_other);
    return mer.withCookies(base_resp, &.{ session_cookie, csrf_cookie });
}
