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

fn containsUnsafeRedirectByte(value: []const u8) bool {
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '\\' or byte == '%') return true;
    }
    return false;
}

fn hasBaseOrigin(value: []const u8, base_url: []const u8) bool {
    const uri = std.Uri.parse(value) catch return false;
    const base = std.Uri.parse(base_url) catch return false;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or
        !std.ascii.eqlIgnoreCase(uri.scheme, base.scheme) or uri.user != null or uri.password != null or
        base.user != null or base.password != null)
    {
        return false;
    }

    var uri_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    var base_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const uri_host = uri.getHost(&uri_buf) catch return false;
    const base_host = base.getHost(&base_buf) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri_host.bytes, base_host.bytes)) return false;

    const default_port: u16 = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) 443 else 80;
    return (uri.port orelse default_port) == (base.port orelse default_port);
}

fn safeRedirect(redirect_to: ?[]const u8, base_url: []const u8) []const u8 {
    const value = redirect_to orelse return "/";
    if (value.len == 0 or containsUnsafeRedirectByte(value)) return "/";
    if (value[0] == '/') {
        return if (value.len == 1 or value[1] != '/') value else "/";
    }
    return if (hasBaseOrigin(value, base_url)) value else "/";
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn decodeQueryComponent(alloc: std.mem.Allocator, value: []const u8) !?[]u8 {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(alloc);
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] != '%') {
            if (value[index] == '+') return null;
            try decoded.append(alloc, value[index]);
            index += 1;
            continue;
        }
        if (index + 2 >= value.len) return null;
        const high = hexNibble(value[index + 1]) orelse return null;
        const low = hexNibble(value[index + 2]) orelse return null;
        try decoded.append(alloc, (high << 4) | low);
        index += 3;
    }
    return try decoded.toOwnedSlice(alloc);
}

// ── send ───────────────────────────────────────────────────────────────────

pub fn send(ctx: *AuthContext) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    // 2. Parse body.
    const parsed = (mer.parseJson(SendMagicLinkBody, ctx.req) catch {
        return mer.badRequest("invalid request body");
    }) orelse return mer.badRequest("invalid request body");
    defer parsed.deinit();
    const body = parsed.value;

    const email_norm = try alloc.dupe(u8, body.email);
    _ = std.ascii.lowerString(email_norm, body.email);

    // 1. Rate limit by email hash (max 5/15min).
    const email_hash = try rate_limit.hashKey(email_norm, alloc);
    defer alloc.free(email_hash);
    rate_limit.check(ctx.db, email_hash, .{ .max_attempts = 5, .window_s = 900 }, alloc) catch |err| {
        if (err == error.RateLimited) return mer.Response.init(.too_many_requests, .json, "{\"error\":\"too many requests\"}");
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

    // 7. Validate the redirect before placing it in the emailed URL.
    const redirect_to = if (body.redirect_to != null) safeRedirect(body.redirect_to, ctx.config.base_url) else null;

    // 8. Send magic link email using the actual verification endpoint.
    if (ctx.config.send_email) |send_fn| {
        var msg = try email_mod.buildMagicLinkWithRedirect(alloc, ctx.config.base_url, raw_token, redirect_to);
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
            .content_type = .json,
            .cookies = &.{},
        };
    };
    const redirect_to_raw = ctx.req.queryParam("redirect_to");
    const redirect_to = if (redirect_to_raw) |value| try decodeQueryComponent(alloc, value) else null;

    // 2. Hash the token and perform all fallible session/ID generation before
    // the statement which claims it.
    const hash_bytes = token_mod.hashForStorage(raw_token);
    const hash_hex = token_mod.hashToHex(hash_bytes);
    const session_token = try crypto.generateToken(alloc);
    const session_id = try crypto.generateUuid(alloc);
    const session_expires = ctx.now_unix + @as(i64, ctx.config.session_ttl_s);
    const session_expires_str = try std.fmt.allocPrint(alloc, "{d}", .{session_expires});
    const csrf_token = try csrf.generateCsrfToken(session_id, ctx.config.secret, alloc);
    var session_cookie = try session.cookieSettings(
        session_id,
        ctx.config.secret,
        ctx.config.session_ttl_s,
        ctx.config.secure_cookies,
        alloc,
    );
    session_cookie.name = ctx.config.session_cookie;
    const csrf_cookie = csrf.csrfCookieSettings(csrf_token, ctx.config.secure_cookies);

    // 3. Consume the token, verify the email, and insert the session in one
    // statement so a failure cannot strand a consumed token.
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
        \\), inserted AS (
        \\  INSERT INTO mauth_sessions(id, user_id, token, expires_at, created_at, updated_at)
        \\  SELECT $3, user_id, $4, to_timestamp($5), NOW(), NOW() FROM verified
        \\  RETURNING user_id
        \\)
        \\SELECT user_id FROM inserted
    , &.{
        .{ .text = &hash_hex },
        .{ .text = "magic_link" },
        .{ .text = session_id },
        .{ .text = session_token },
        .{ .text = session_expires_str },
    });
    defer tok_result.deinit();

    // 4. Token invalid.
    if (tok_result.rows.len == 0) {
        return mer.Response{
            .status = .unauthorized,
            .body = "{\"error\":\"invalid or expired link\"}",
            .content_type = .json,
            .cookies = &.{},
        };
    }

    _ = db.rowText(tok_result.rows[0], "user_id") orelse return mer.internalError("db error");

    // 8. Redirect only to the exact configured origin or a local absolute path.
    const base_resp = mer.redirect(safeRedirect(redirect_to, ctx.config.base_url), .see_other);
    const cookies = try alloc.alloc(mer.SetCookie, 2);
    cookies[0] = session_cookie;
    cookies[1] = csrf_cookie;
    return mer.withCookies(base_resp, cookies);
}

test "magic-link redirects only to the exact base origin or a local path" {
    const base = "https://app.example.com";
    try std.testing.expectEqualStrings("/dashboard?tab=auth", safeRedirect("/dashboard?tab=auth", base));
    try std.testing.expectEqualStrings("https://app.example.com/welcome", safeRedirect("https://app.example.com/welcome", base));
    try std.testing.expectEqualStrings("https://APP.example.com:443/welcome", safeRedirect("https://APP.example.com:443/welcome", base));

    const rejected = [_][]const u8{
        "https://app.example.com.evil.test/",
        "https://app.example.com@evil.test/",
        "//evil.test/",
        "/\\evil.test/",
        "/%2f%2fevil.test/",
        "https:%2f%2fevil.test/",
        "/ok\r\nLocation: https://evil.test/",
    };
    for (rejected) |value| {
        try std.testing.expectEqualStrings("/", safeRedirect(value, base));
    }
}
