//! Main Auth configuration and request dispatcher for merjs-auth.
//!
//! Create a `Config` once at startup, then call `handle(config, req)` from
//! your catch-all merjs route to process all auth endpoints.

const std = @import("std");
const mer = @import("mer");
const db = @import("db/root.zig");
const password = @import("password.zig");
const session = @import("session.zig");
const email = @import("email.zig");
const oauth_providers = @import("oauth/providers.zig");
const saml_schema = @import("saml/schema.zig");
const handlers = @import("handlers/dispatch.zig");

const argon2 = std.crypto.pwhash.argon2;

/// Get current Unix timestamp in seconds (Zig 0.16 compatible).
fn currentUnixSeconds() i64 {
    var ts: std.c.time.timespec = undefined;
    _ = std.c.clock_gettime(std.c.time.CLOCK.REALTIME, &ts);
    return ts.sec;
}

// ── Config ─────────────────────────────────────────────────────────────────

/// Auth library configuration. Create once at startup, pass to handle().
pub const Config = struct {
    /// 32+ byte secret for HMAC signing (session tokens, CSRF). Required.
    secret: []const u8,
    /// Base URL of the app e.g. "https://myapp.com". Used for redirect URIs and email links.
    base_url: []const u8,
    /// Database adapter. Required.
    db: db.Adapter,
    /// HTTP fetch function for making outbound HTTP requests (token exchange, userinfo, etc.)
    /// Required on Cloudflare Workers (no TCP). Optional on native server.
    http_fetch: ?db.FetchFn = null,
    /// URL prefix for all auth routes. Default "/auth".
    auth_prefix: []const u8 = "/auth",
    /// Session cookie name.
    session_cookie: []const u8 = "mauth_session",
    /// Session TTL in seconds. Default 7 days.
    session_ttl_s: u32 = session.DEFAULT_TTL_S,
    /// Argon2id parameters. Use WorkersParams (32MiB) on Cloudflare, ServerParams (64MiB) native.
    argon2_params: argon2.Params = password.WorkersParams,
    /// Set to true in production to enable Secure cookie flag.
    secure_cookies: bool = true,
    /// Email send hook. Required for email verification, password reset, magic links.
    send_email: ?email.SendEmailFn = null,
    /// Additional trusted origins for CORS/CSRF checks.
    trusted_origins: []const []const u8 = &.{},
    /// OAuth provider configurations.
    oauth_providers: []const oauth_providers.Provider = &.{},
    /// SAML provider configurations.
    saml_providers: []const saml_schema.Provider = &.{},
};

// ── AuthContext ─────────────────────────────────────────────────────────────

/// Per-request context passed to all handlers.
pub const AuthContext = struct {
    req: mer.Request,
    config: *const Config,
    db: db.Adapter,
    now_unix: i64,
};

// ── handle ──────────────────────────────────────────────────────────────────

/// Main Auth handler. Mount this in your merjs app.
///
/// Example:
///   var auth_config = merjs_auth.Config{ .secret = "...", .db = adapter, ... };
///   // In your catch-all route:
///   pub fn render(req: mer.Request) mer.Response {
///       return merjs_auth.handle(&auth_config, req) catch mer.internalError("auth error");
///   }
pub fn handle(config: *const Config, req: mer.Request) anyerror!mer.Response {
    // Strip auth prefix from path.
    if (!std.mem.startsWith(u8, req.path, config.auth_prefix)) {
        return mer.notFound();
    }
    const subpath = req.path[config.auth_prefix.len..];

    var ctx = AuthContext{
        .req = req,
        .config = config,
        .db = config.db,
        .now_unix = currentUnixSeconds(),
    };

    return handlers.dispatch(&ctx, subpath);
}

// ── getSession ──────────────────────────────────────────────────────────────

/// Verify the current session from request cookies.
/// Returns SessionWithUser if valid, null if not authenticated.
///
/// Steps:
///   1. Read the session cookie.
///   2. Verify the HMAC signature via session.verifyCookie.
///   3. Query DB for session + user joined record, checking expiry server-side.
///   4. Return SessionWithUser or null.
pub fn getSession(config: *const Config, req: mer.Request) !?session.SessionWithUser {
    const alloc = req.allocator;

    // 1. Read session cookie.
    const cookie_val = req.cookie(config.session_cookie) orelse return null;

    // 2. Verify HMAC — returns the session_id payload or null.
    const session_id = session.verifyCookie(cookie_val, config.secret) orelse return null;

    // 3. Query DB.
    const sql =
        \\SELECT s.id, s.user_id, s.token, s.expires_at,
        \\       u.id AS uid, u.name, u.email, u.email_verified, u.image,
        \\       u.created_at, u.updated_at
        \\FROM mauth_sessions s
        \\JOIN mauth_users u ON s.user_id = u.id
        \\WHERE s.id = $1
        \\  AND s.expires_at > to_timestamp($2)
    ;
    const now_str = try std.fmt.allocPrint(alloc, "{d}", .{currentUnixSeconds()});
    defer alloc.free(now_str);

    var result = try config.db.query(alloc, sql, &.{
        .{ .text = session_id },
        .{ .text = now_str },
    });
    defer result.deinit();

    if (result.rows.len == 0) return null;

    const row = result.rows[0];

    // 4. Build SessionWithUser from the joined row.
    const sess = session.Session{
        .id = try alloc.dupe(u8, db.rowText(row, "id") orelse return null),
        .user_id = try alloc.dupe(u8, db.rowText(row, "user_id") orelse return null),
        .token = try alloc.dupe(u8, db.rowText(row, "token") orelse return null),
        .expires_at = db.rowInt(row, "expires_at") orelse return null,
        .ip_address = null,
        .user_agent = null,
    };

    const user_image: ?[]const u8 = if (db.rowText(row, "image")) |img|
        try alloc.dupe(u8, img)
    else
        null;

    const usr = session.User{
        .id = try alloc.dupe(u8, db.rowText(row, "uid") orelse return null),
        .name = try alloc.dupe(u8, db.rowText(row, "name") orelse ""),
        .email = try alloc.dupe(u8, db.rowText(row, "email") orelse return null),
        .email_verified = db.rowBool(row, "email_verified") orelse false,
        .image = user_image,
        .created_at = db.rowInt(row, "created_at") orelse 0,
        .updated_at = db.rowInt(row, "updated_at") orelse 0,
    };

    return session.SessionWithUser{ .session = sess, .user = usr };
}
