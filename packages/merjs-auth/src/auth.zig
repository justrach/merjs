//! Main Auth configuration and request dispatcher for merjs-auth.
//!
//! Create a `Config` once at startup, then call `handle(config, req)` from
//! your catch-all merjs route to process all auth endpoints.

const std = @import("std");
const mer = @import("mer");
const db = @import("db/root.zig");
const password = @import("password.zig");
const session = @import("session.zig");
const crypto = @import("crypto.zig");
const email = @import("email.zig");
const oauth_providers = @import("oauth/providers.zig");
const saml_schema = @import("saml/schema.zig");
const handlers = @import("handlers/dispatch.zig");

const argon2 = std.crypto.pwhash.argon2;

/// Get current Unix timestamp in seconds, failing closed on clock errors.
fn currentUnixSeconds() !i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return error.ClockFailed;
    const seconds = std.math.cast(i64, ts.sec) orelse return error.ClockFailed;
    if (seconds < 0) return error.ClockFailed;
    return seconds;
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
    /// Short-lived HttpOnly cookie binding an OAuth callback to its browser.
    oauth_state_cookie: []const u8 = "mauth_oauth_state",
    /// Session TTL in seconds. Default 7 days.
    session_ttl_s: u32 = session.DEFAULT_TTL_S,
    /// Argon2id parameters. Use WorkersParams (32MiB) on Cloudflare, ServerParams (64MiB) native.
    argon2_params: argon2.Params = password.WorkersParams,
    /// Set to true in production to enable Secure cookie flag.
    secure_cookies: bool = true,
    /// Email send hook. Required for email verification, password reset, magic links.
    send_email: ?email.SendEmailFn = null,
    /// Additional exact HTTP(S) origins allowed to call browser-facing POST routes.
    /// The origin of `base_url` is always trusted. Values must not contain paths.
    trusted_origins: []const []const u8 = &.{},
    /// OAuth provider configurations.
    oauth_providers: []const oauth_providers.Provider = &.{},
    /// Deprecated compatibility field. Non-empty configuration is rejected
    /// until XMLDSig verification is implemented.
    saml_providers: []const saml_schema.Provider = &.{},
};

pub const ConfigError = error{ UnsupportedProvider, UnsupportedSaml };

/// Reject configuration for deliberately unsupported, fail-closed features.
pub fn validateConfig(config: *const Config) ConfigError!void {
    for (config.oauth_providers) |provider| {
        if (provider.email_verification == .microsoft) return error.UnsupportedProvider;
    }
    if (config.saml_providers.len != 0) return error.UnsupportedSaml;
}

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
    try validateConfig(config);

    // Strip auth prefix from path.
    if (!std.mem.startsWith(u8, req.path, config.auth_prefix)) {
        return mer.notFound();
    }
    const subpath = req.path[config.auth_prefix.len..];

    var ctx = AuthContext{
        .req = req,
        .config = config,
        .db = config.db,
        .now_unix = try currentUnixSeconds(),
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
    const now_str = try std.fmt.allocPrint(alloc, "{d}", .{try currentUnixSeconds()});
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

const TestSessionAdapter = struct {
    fn query(_: *anyopaque, alloc: std.mem.Allocator, _: []const u8, _: []const db.Value) anyerror!db.QueryResult {
        var arena = std.heap.ArenaAllocator.init(alloc);
        const aa = arena.allocator();
        const fields = try aa.alloc(db.Field, 11);
        fields[0] = .{ .name = "id", .value = .{ .text = "session-1" } };
        fields[1] = .{ .name = "user_id", .value = .{ .text = "user-1" } };
        fields[2] = .{ .name = "token", .value = .{ .text = "token-1" } };
        fields[3] = .{ .name = "expires_at", .value = .{ .int = std.math.maxInt(i64) } };
        fields[4] = .{ .name = "uid", .value = .{ .text = "user-1" } };
        fields[5] = .{ .name = "name", .value = .{ .text = "Alice" } };
        fields[6] = .{ .name = "email", .value = .{ .text = "alice@example.com" } };
        fields[7] = .{ .name = "email_verified", .value = .{ .bool_val = true } };
        fields[8] = .{ .name = "image", .value = .{ .null_val = {} } };
        fields[9] = .{ .name = "created_at", .value = .{ .int = 1 } };
        fields[10] = .{ .name = "updated_at", .value = .{ .int = 1 } };
        const rows = try aa.alloc(db.Row, 1);
        rows[0] = fields;
        return .{ .rows = rows, ._arena = arena };
    }

    fn exec(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const db.Value) anyerror!void {}
    fn deinit(_: *anyopaque) void {}

    const vtable = db.Adapter.VTable{ .queryFn = query, .execFn = exec, .deinitFn = deinit };
};

test "session producers to getSession support canonical, Config.secret, and deprecated migration" {
    mer.resetEnv();
    defer mer.resetEnv();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var adapter_state: u8 = 0;
    const adapter = db.Adapter{ .ptr = &adapter_state, .vtable = &TestSessionAdapter.vtable };
    const config = Config{
        .secret = "legacy-config-secret-at-least-32-bytes",
        .base_url = "http://localhost",
        .db = adapter,
        .secure_cookies = false,
    };

    const legacy_cookie = try session.cookieSettings("session-1", config.secret, 3600, false, alloc);
    const canonical_secret = "canonical-session-secret-at-least-32-bytes";
    const deprecated_secret = "deprecated-session-secret-at-least-32-bytes";
    try mer.putEnv("MERJS_SESSION_SECRET", canonical_secret);
    try mer.putEnv("MULTICLAW_SESSION_SECRET", deprecated_secret);

    const legacy_cookies = try std.fmt.allocPrint(alloc, "{s}={s}", .{ config.session_cookie, legacy_cookie.value });
    var legacy_req = mer.Request.init(alloc, .GET, "/");
    legacy_req.cookies_raw = legacy_cookies;
    try std.testing.expect((try getSession(&config, legacy_req)) != null);

    const deprecated_cookie = try session.cookieValue(alloc, "session-1", deprecated_secret);
    const deprecated_cookies = try std.fmt.allocPrint(alloc, "{s}={s}", .{ config.session_cookie, deprecated_cookie });
    var deprecated_req = mer.Request.init(alloc, .GET, "/");
    deprecated_req.cookies_raw = deprecated_cookies;
    try std.testing.expect((try getSession(&config, deprecated_req)) != null);

    const canonical_cookie = try session.cookieSettings("session-1", config.secret, 3600, false, alloc);
    try std.testing.expect(crypto.verifySignedToken(canonical_cookie.value, canonical_secret) != null);
    try std.testing.expect(crypto.verifySignedToken(canonical_cookie.value, config.secret) == null);
    const canonical_cookies = try std.fmt.allocPrint(alloc, "{s}={s}", .{ config.session_cookie, canonical_cookie.value });
    var canonical_req = mer.Request.init(alloc, .GET, "/");
    canonical_req.cookies_raw = canonical_cookies;
    try std.testing.expect((try getSession(&config, canonical_req)) != null);
}
