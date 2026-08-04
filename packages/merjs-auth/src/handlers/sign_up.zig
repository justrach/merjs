//! POST /auth/sign-up/email
//!
//! Register a new user with email + password. Creates a session immediately
//! so the user is signed in right after registration.

const std = @import("std");
const mer = @import("mer");
const db = @import("../db/root.zig");
const crypto = @import("../crypto.zig");
const password = @import("../password.zig");
const session = @import("../session.zig");
const token_mod = @import("../token.zig");
const email_mod = @import("../email.zig");
const rate_limit = @import("../rate_limit.zig");
const csrf = @import("../csrf.zig");
const AuthContext = @import("../auth.zig").AuthContext;

const SignUpBody = struct {
    email: []const u8,
    password: []const u8,
    name: []const u8,
};

pub fn handle(ctx: *AuthContext) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    // 1. Rate limit by server-owned client identity (max 10 per 15 min).
    // Signup has no account key to fall back to, so fail closed if the hosting
    // platform cannot provide a trusted identity.
    const client_identity = ctx.req.clientIdentity() orelse return mer.Response.init(
        .service_unavailable,
        .json,
        "{\"error\":\"signup temporarily unavailable\"}",
    );
    const ip_hash = try rate_limit.hashKey(client_identity, alloc);
    defer alloc.free(ip_hash);
    rate_limit.check(ctx.db, ip_hash, .{ .max_attempts = 10, .window_s = 900 }, alloc) catch |err| {
        if (err == error.RateLimited) return mer.Response.init(.too_many_requests, .json, "{\"error\":\"too many requests\"}");
        return err;
    };

    // 2. Parse JSON body.
    const parsed = (mer.parseJson(SignUpBody, ctx.req) catch {
        return mer.badRequest("invalid request body");
    }) orelse return mer.badRequest("invalid request body");
    defer parsed.deinit();
    const body = parsed.value;

    // 3. Validate inputs.
    if (std.mem.indexOfScalar(u8, body.email, '@') == null) {
        return mer.badRequest("invalid email address");
    }
    if (!password.isStrong(body.password)) {
        return mer.badRequest("password must be 8–128 characters");
    }
    if (body.name.len < 1) {
        return mer.badRequest("name is required");
    }

    // 4. Normalize email to lowercase.
    const email_norm = try alloc.dupe(u8, body.email);
    _ = std.ascii.lowerString(email_norm, body.email);

    // 5. Check for existing user.
    var existing = try ctx.db.query(
        alloc,
        "SELECT id FROM mauth_users WHERE email = $1",
        &.{.{ .text = email_norm }},
    );
    defer existing.deinit();
    if (existing.rows.len > 0) {
        const body_json = "{\"error\":\"email already registered\"}";
        return mer.Response{
            .status = .conflict,
            .body = body_json,
            .content_type = .json,
            .cookies = &.{},
        };
    }

    // 7. Hash password.
    const pw_hash = password.hash(alloc, body.password, ctx.config.argon2_params) catch |err| {
        if (err == error.CapacityExhausted) return mer.Response.init(
            .service_unavailable,
            .json,
            "{\"error\":\"password service busy\"}",
        );
        return err;
    };

    // 8. Generate user_id.
    const user_id = try crypto.generateUuid(alloc);

    // 9. Generate account_id.
    const account_id = try crypto.generateUuid(alloc);

    // 10. Insert the user and email account atomically. PostgreSQL executes a
    // single statement atomically, so an account failure cannot strand a user.
    try ctx.db.exec(alloc,
        \\WITH inserted_user AS (
        \\  INSERT INTO mauth_users(id, name, email, email_verified, created_at, updated_at)
        \\  VALUES($1,$2,$3,false,NOW(),NOW())
        \\  RETURNING id
        \\)
        \\INSERT INTO mauth_oauth_accounts(id, user_id, provider_id, account_id, password_hash, created_at, updated_at)
        \\SELECT $4,id,'email',$3,$5,NOW(),NOW() FROM inserted_user
    , &.{
        .{ .text = user_id },
        .{ .text = body.name },
        .{ .text = email_norm },
        .{ .text = account_id },
        .{ .text = pw_hash },
    });

    // 12. If email hook set: send verification + welcome emails.
    if (ctx.config.send_email) |send_fn| {
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

        // Send welcome email.
        var welcome = try email_mod.buildWelcome(alloc, body.name, email_norm);
        welcome.to = email_norm;
        send_fn(welcome, alloc) catch {}; // non-fatal

        // Send verification email.
        var verify_msg = try email_mod.buildVerifyEmail(alloc, ctx.config.base_url, raw_token);
        verify_msg.to = email_norm;
        send_fn(verify_msg, alloc) catch {}; // non-fatal
    }

    // 13. Create session.
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

    // 15. Generate CSRF token.
    const csrf_token = try csrf.generateCsrfToken(session_id, ctx.config.secret, alloc);

    // 16. Build response.
    var base_resp = mer.typedJson(alloc, .{
        .user = .{
            .id = user_id,
            .email = email_norm,
            .name = body.name,
            .email_verified = false,
        },
    });
    base_resp.status = .created;

    var session_cookie = try session.cookieSettings(
        session_id,
        ctx.config.secret,
        ctx.config.session_ttl_s,
        ctx.config.secure_cookies,
        alloc,
    );
    session_cookie.name = ctx.config.session_cookie;
    const csrf_cookie = csrf.csrfCookieSettings(csrf_token, ctx.config.secure_cookies);
    const cookies = try alloc.alloc(mer.SetCookie, 2);
    cookies[0] = session_cookie;
    cookies[1] = csrf_cookie;

    return mer.withCookies(base_resp, cookies);
}
