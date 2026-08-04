//! OAuth 2.0 + PKCE flow orchestration for merjs-auth.
//!
//! Two handler functions are exposed:
//!
//!   initiate(ctx, provider_id)  — redirects the user to the OAuth provider
//!   callback(ctx, provider_id)  — handles the provider callback
//!
//! Both accept an `AuthContext` (passed as anytype to avoid circular deps).
//! Expected fields on ctx:
//!
//!   ctx.req                     : mer.Request
//!   ctx.config.secret           : []const u8
//!   ctx.config.base_url         : []const u8
//!   ctx.config.session_ttl_s    : u32
//!   ctx.config.session_cookie   : []const u8
//!   ctx.config.oauth_providers  : []const providers.Provider
//!   ctx.config.http_fetch       : db.FetchFn  (required on Workers)
//!   ctx.db                      : db.Adapter
//!   ctx.now_unix                : i64
//!
//! Database tables used (schema/002_oauth.sql, schema/001_initial.sql):
//!   mauth_oauth_states, mauth_oauth_accounts, mauth_users, mauth_sessions

const std = @import("std");
const mer = @import("mer");
const db = @import("../db/root.zig");
const crypto = @import("../crypto.zig");
const session = @import("../session.zig");
const pkce = @import("pkce.zig");
const providers = @import("providers.zig");

// ── Provider userinfo wire types ───────────────────────────────────────────

const GoogleUserInfo = struct {
    sub: []const u8,
    email: []const u8,
    email_verified: bool = false,
    name: []const u8 = "",
    picture: ?[]const u8 = null,
};

const GitHubUserInfo = struct {
    id: i64,
    login: []const u8 = "",
    email: ?[]const u8 = null,
    name: ?[]const u8 = null,
    avatar_url: ?[]const u8 = null,
};

const GitHubEmail = struct {
    email: []const u8,
    primary: bool = false,
    verified: bool = false,
};

const DiscordUserInfo = struct {
    id: []const u8,
    username: []const u8 = "",
    email: ?[]const u8 = null,
    verified: bool = false,
    avatar: ?[]const u8 = null,
};

/// Normalised user info extracted from any provider.
const UserInfo = struct {
    provider_account_id: []const u8,
    email: []const u8,
    name: []const u8,
    avatar: ?[]const u8,
};

// ── Token exchange response ────────────────────────────────────────────────

const TokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8 = "Bearer",
    expires_in: ?i64 = null,
    refresh_token: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    id_token: ?[]const u8 = null,
};

// ── URL encoding ───────────────────────────────────────────────────────────

fn urlEncode(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (input) |c| {
        if (isUnreserved(c)) {
            try out.append(alloc, c);
        } else {
            var tmp: [3]u8 = undefined;
            const enc = try std.fmt.bufPrint(&tmp, "%{X:0>2}", .{c});
            try out.appendSlice(alloc, enc);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
}

fn appendParam(
    alloc: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    key: []const u8,
    value: []const u8,
) !void {
    const ek = try urlEncode(alloc, key);
    defer alloc.free(ek);
    const ev = try urlEncode(alloc, value);
    defer alloc.free(ev);
    if (buf.items.len > 0) try buf.append(alloc, '&');
    try buf.appendSlice(alloc, ek);
    try buf.append(alloc, '=');
    try buf.appendSlice(alloc, ev);
}

fn buildFormBody(alloc: std.mem.Allocator, params: []const [2][]const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (params) |kv| try appendParam(alloc, &buf, kv[0], kv[1]);
    return buf.toOwnedSlice(alloc);
}

fn getQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOf(u8, pair, "=") orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn queryStringOf(url: []const u8) []const u8 {
    const q = std.mem.indexOf(u8, url, "?") orelse return "";
    return url[q + 1 ..];
}

fn findProvider(
    oauth_providers: []const providers.Provider,
    provider_id: []const u8,
) ?*const providers.Provider {
    for (oauth_providers) |*p| {
        if (std.mem.eql(u8, p.id, provider_id)) return p;
    }
    return null;
}

fn buildRedirectUri(
    alloc: std.mem.Allocator,
    base_url: []const u8,
    provider_id: []const u8,
    override: ?[]const u8,
) ![]u8 {
    if (override) |r| return alloc.dupe(u8, r);
    return std.fmt.allocPrint(alloc, "{s}/auth/oauth/{s}/callback", .{ base_url, provider_id });
}

// ── HTTP helper ────────────────────────────────────────────────────────────

/// Perform an HTTP request using the config's http_fetch function.
/// Returns the response body; caller owns the returned slice.
fn doHttpFetch(
    alloc: std.mem.Allocator,
    http_fetch: db.FetchFn,
    url: []const u8,
    method: []const u8,
    headers: []const [2][]const u8,
    body: []const u8,
) ![]u8 {
    var result = try http_fetch(alloc, url, method, headers, body);
    defer result.deinit();
    if (result.status < 200 or result.status >= 300) {
        std.debug.print("[oauth] HTTP {d} from {s}: {s}\n", .{ result.status, url, result.body });
        return error.OAuthHttpError;
    }
    return alloc.dupe(u8, result.body);
}

// ── initiate ───────────────────────────────────────────────────────────────

/// GET /auth/oauth/:provider/initiate
///
/// 1. Look up the provider config.
/// 2. Generate PKCE code_verifier + S256 challenge.
/// 3. Generate state nonce for CSRF protection.
/// 4. Persist state in mauth_oauth_states (TTL 10 min).
/// 5. Build authorization URL and redirect.
pub fn initiate(ctx: anytype, provider_id: []const u8) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    const provider = findProvider(ctx.config.oauth_providers, provider_id) orelse {
        std.debug.print("[oauth] initiate: unknown provider '{s}'\n", .{provider_id});
        return mer.badRequest("Unknown OAuth provider");
    };

    const verifier = try pkce.generateCodeVerifier(alloc);
    const challenge = try pkce.codeChallenge(alloc, verifier);
    const state = try pkce.generateState(alloc);
    const redirect_uri = try buildRedirectUri(alloc, ctx.config.base_url, provider_id, provider.redirect_uri);
    const state_id = try crypto.generateUuid(alloc);
    const expires_at = ctx.now_unix + 600; // 10 min

    try ctx.db.exec(alloc,
        \\INSERT INTO mauth_oauth_states
        \\  (id, state, provider_id, code_verifier, redirect_uri, expires_at)
        \\VALUES ($1, $2, $3, $4, $5, to_timestamp($6))
    , &[_]db.Value{
        .{ .text = state_id },
        .{ .text = state },
        .{ .text = provider_id },
        .{ .text = verifier },
        .{ .text = redirect_uri },
        .{ .int = expires_at },
    });

    const scope = try std.mem.join(alloc, " ", provider.scopes);

    var qbuf: std.ArrayList(u8) = .empty;
    defer qbuf.deinit(alloc);
    try appendParam(alloc, &qbuf, "response_type", "code");
    try appendParam(alloc, &qbuf, "client_id", provider.client_id);
    try appendParam(alloc, &qbuf, "redirect_uri", redirect_uri);
    try appendParam(alloc, &qbuf, "scope", scope);
    try appendParam(alloc, &qbuf, "state", state);
    try appendParam(alloc, &qbuf, "code_challenge", challenge);
    try appendParam(alloc, &qbuf, "code_challenge_method", "S256");

    const auth_url = try std.fmt.allocPrint(alloc, "{s}?{s}", .{ provider.auth_url, qbuf.items });
    const cookies = try alloc.alloc(mer.SetCookie, 1);
    cookies[0] = .{
        .name = ctx.config.oauth_state_cookie,
        .value = state,
        .path = "/",
        .max_age = 600,
        .http_only = true,
        .secure = ctx.config.secure_cookies,
        .same_site = .lax,
    };
    return mer.withCookies(mer.redirect(auth_url, .found), cookies);
}

// ── callback ───────────────────────────────────────────────────────────────

/// GET /auth/oauth/:provider/callback?code=...&state=...
///
/// 1. Read code + state from query params.
/// 2. Look up + validate state row; extract code_verifier; delete state.
/// 3. Exchange code for tokens (POST to token_url).
/// 4. Fetch user info from userinfo_url.
/// 5. Find-or-create mauth_users + mauth_oauth_accounts.
/// 6. Create session, set cookie, redirect to /.
pub fn callback(ctx: anytype, provider_id: []const u8) anyerror!mer.Response {
    const response = callbackInner(ctx, provider_id) catch |err| {
        std.debug.print("[oauth] callback failed: {s}\n", .{@errorName(err)});
        return withClearedStateCookie(ctx, mer.internalError("OAuth callback failed"));
    };
    return withClearedStateCookie(ctx, response);
}

fn withClearedStateCookie(ctx: anytype, response: mer.Response) !mer.Response {
    const cookies = try ctx.req.allocator.alloc(mer.SetCookie, response.cookies.len + 1);
    @memcpy(cookies[0..response.cookies.len], response.cookies);
    cookies[response.cookies.len] = .{
        .name = ctx.config.oauth_state_cookie,
        .value = "",
        .path = "/",
        .max_age = 0,
        .http_only = true,
        .secure = ctx.config.secure_cookies,
        .same_site = .lax,
    };
    return mer.withCookies(response, cookies);
}

fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    var a_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    var b_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(a, &a_hash, .{});
    std.crypto.hash.sha2.Sha256.hash(b, &b_hash, .{});
    return std.crypto.timing_safe.eql([a_hash.len]u8, a_hash, b_hash);
}

fn callbackInner(ctx: anytype, provider_id: []const u8) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    const provider = findProvider(ctx.config.oauth_providers, provider_id) orelse {
        std.debug.print("[oauth] callback: unknown provider '{s}'\n", .{provider_id});
        return mer.badRequest("Unknown OAuth provider");
    };

    const qs = ctx.req.query_string;

    if (getQueryParam(qs, "error")) |err_code| {
        std.debug.print("[oauth] callback: provider error '{s}'\n", .{err_code});
        return mer.badRequest("OAuth provider returned an error");
    }

    const code = getQueryParam(qs, "code") orelse {
        std.debug.print("[oauth] callback: missing 'code' param\n", .{});
        return mer.badRequest("Missing code parameter");
    };
    const state_param = getQueryParam(qs, "state") orelse {
        std.debug.print("[oauth] callback: missing 'state' param\n", .{});
        return mer.badRequest("Missing state parameter");
    };

    const cookie_state = ctx.req.cookie(ctx.config.oauth_state_cookie) orelse {
        std.debug.print("[oauth] callback: missing browser correlation cookie\n", .{});
        return mer.badRequest("OAuth state expired or invalid");
    };
    if (!constantTimeEqual(cookie_state, state_param)) {
        std.debug.print("[oauth] callback: browser correlation mismatch\n", .{});
        return mer.badRequest("OAuth state expired or invalid");
    }

    // Atomically claim the single-use state. Concurrent or replayed callbacks
    // can never both exchange an authorization code.
    var state_result = try ctx.db.query(alloc,
        \\DELETE FROM mauth_oauth_states
        \\WHERE state = $1
        \\  AND provider_id = $2
        \\  AND expires_at > NOW()
        \\RETURNING state, code_verifier, redirect_uri
    , &[_]db.Value{
        .{ .text = state_param },
        .{ .text = provider_id },
    });
    defer state_result.deinit();

    if (state_result.rows.len != 1) {
        std.debug.print("[oauth] callback: state not found, expired, or consumed\n", .{});
        return mer.badRequest("OAuth state expired or invalid");
    }
    const state_row = state_result.rows[0];
    const state_db = db.rowText(state_row, "state") orelse return error.OAuthStateMissingId;
    if (!constantTimeEqual(cookie_state, state_db)) {
        std.debug.print("[oauth] callback: stored state mismatch\n", .{});
        return mer.badRequest("OAuth state expired or invalid");
    }
    const verifier = db.rowText(state_row, "code_verifier") orelse {
        std.debug.print("[oauth] callback: missing code_verifier\n", .{});
        return error.OAuthStateMissingVerifier;
    };
    const redirect_uri_db = db.rowText(state_row, "redirect_uri") orelse "";
    const redirect_uri = if (redirect_uri_db.len > 0)
        redirect_uri_db
    else
        try buildRedirectUri(alloc, ctx.config.base_url, provider_id, provider.redirect_uri);

    // Exchange code for tokens.
    const http_fetch = ctx.config.http_fetch orelse return mer.Response.init(
        .service_unavailable,
        .json,
        "{\"error\":\"OAuth HTTP fetch is not configured\"}",
    );
    const token_resp = try exchangeCode(alloc, http_fetch, provider, code, verifier, redirect_uri);

    // Fetch user info.
    const user_info = try fetchUserInfo(alloc, http_fetch, provider, token_resp.access_token);

    // Find or create user.
    const user_id = try findOrCreateUser(alloc, ctx.db, ctx.now_unix, provider_id, user_info, token_resp);

    // Create session.
    const session_token = try crypto.generateToken(alloc);
    const session_id = try crypto.generateUuid(alloc);
    const session_expires = ctx.now_unix + @as(i64, ctx.config.session_ttl_s);

    try ctx.db.exec(alloc,
        \\INSERT INTO mauth_sessions
        \\  (id, user_id, token, expires_at, created_at, updated_at)
        \\VALUES ($1, $2, $3, to_timestamp($4), NOW(), NOW())
    , &[_]db.Value{
        .{ .text = session_id },
        .{ .text = user_id },
        .{ .text = session_token },
        .{ .int = session_expires },
    });

    // Build Set-Cookie and redirect.
    var cookie = try session.cookieSettings(
        session_id,
        ctx.config.secret,
        ctx.config.session_ttl_s,
        ctx.config.secure_cookies,
        alloc,
    );
    cookie.name = ctx.config.session_cookie;
    const cookies = try alloc.alloc(mer.SetCookie, 1);
    cookies[0] = cookie;
    return mer.withCookies(mer.redirect("/", .see_other), cookies);
}

// ── Token exchange ─────────────────────────────────────────────────────────

fn exchangeCode(
    alloc: std.mem.Allocator,
    http_fetch: db.FetchFn,
    provider: *const providers.Provider,
    code: []const u8,
    verifier: []const u8,
    redirect_uri: []const u8,
) !TokenResponse {
    const body = try buildFormBody(alloc, &[_][2][]const u8{
        .{ "grant_type", "authorization_code" },
        .{ "code", code },
        .{ "code_verifier", verifier },
        .{ "redirect_uri", redirect_uri },
        .{ "client_id", provider.client_id },
        .{ "client_secret", provider.client_secret },
    });
    defer alloc.free(body);

    const raw = try doHttpFetch(alloc, http_fetch, provider.token_url, "POST", &[_][2][]const u8{
        .{ "Content-Type", "application/x-www-form-urlencoded" },
        .{ "Accept", "application/json" },
    }, body);
    defer alloc.free(raw);

    const parsed = try std.json.parseFromSlice(
        TokenResponse,
        alloc,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    // Dupe all strings out of the Parsed arena so they survive past deinit.
    return TokenResponse{
        .access_token = try alloc.dupe(u8, parsed.value.access_token),
        .token_type = try alloc.dupe(u8, parsed.value.token_type),
        .expires_in = parsed.value.expires_in,
        .refresh_token = if (parsed.value.refresh_token) |r| try alloc.dupe(u8, r) else null,
        .scope = if (parsed.value.scope) |s| try alloc.dupe(u8, s) else null,
        .id_token = if (parsed.value.id_token) |t| try alloc.dupe(u8, t) else null,
    };
}

// ── User info fetching ─────────────────────────────────────────────────────

fn fetchUserInfo(
    alloc: std.mem.Allocator,
    http_fetch: db.FetchFn,
    provider: *const providers.Provider,
    access_token: []const u8,
) !UserInfo {
    const auth_val = try std.fmt.allocPrint(alloc, "Bearer {s}", .{access_token});
    defer alloc.free(auth_val);

    const raw = try doHttpFetch(alloc, http_fetch, provider.userinfo_url, "GET", &[_][2][]const u8{
        .{ "Authorization", auth_val },
        .{ "Accept", "application/json" },
        .{ "User-Agent", "merjs-auth/1.0" },
    }, "");
    defer alloc.free(raw);

    return switch (provider.email_verification) {
        .oidc => parseGoogleUserInfo(alloc, raw),
        .github => parseGitHubUserInfo(alloc, http_fetch, raw, access_token),
        .discord => parseDiscordUserInfo(alloc, raw),
        .microsoft => error.UnsupportedProvider,
        .none => if (provider.verified_email_mapping) |mapping|
            parseMappedUserInfo(alloc, raw, mapping)
        else
            error.OAuthUntrustedEmailClaim,
    };
}

fn parseGoogleUserInfo(alloc: std.mem.Allocator, raw: []const u8) !UserInfo {
    const parsed = try std.json.parseFromSlice(GoogleUserInfo, alloc, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const v = parsed.value;
    if (!v.email_verified) return error.OAuthEmailNotVerified;
    return UserInfo{
        .provider_account_id = try alloc.dupe(u8, v.sub),
        .email = try alloc.dupe(u8, v.email),
        .name = try alloc.dupe(u8, if (v.name.len > 0) v.name else v.email),
        .avatar = if (v.picture) |p| try alloc.dupe(u8, p) else null,
    };
}

fn parseGitHubUserInfo(
    alloc: std.mem.Allocator,
    http_fetch: db.FetchFn,
    raw: []const u8,
    access_token: []const u8,
) !UserInfo {
    const parsed = try std.json.parseFromSlice(GitHubUserInfo, alloc, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const v = parsed.value;

    const account_id = try std.fmt.allocPrint(alloc, "{d}", .{v.id});
    const name = if (v.name != null and v.name.?.len > 0)
        try alloc.dupe(u8, v.name.?)
    else
        try alloc.dupe(u8, v.login);
    const avatar = if (v.avatar_url) |a| try alloc.dupe(u8, a) else null;

    // `/user.email` does not carry its verification assertion. Always use the
    // scoped email endpoint and accept only an entry marked verified.
    const email = try fetchGitHubPrimaryEmail(alloc, http_fetch, access_token);

    return UserInfo{
        .provider_account_id = account_id,
        .email = email,
        .name = name,
        .avatar = avatar,
    };
}

fn fetchGitHubPrimaryEmail(
    alloc: std.mem.Allocator,
    http_fetch: db.FetchFn,
    access_token: []const u8,
) ![]u8 {
    const auth_val = try std.fmt.allocPrint(alloc, "Bearer {s}", .{access_token});
    defer alloc.free(auth_val);

    const raw = try doHttpFetch(alloc, http_fetch, "https://api.github.com/user/emails", "GET", &[_][2][]const u8{
        .{ "Authorization", auth_val },
        .{ "Accept", "application/json" },
        .{ "User-Agent", "merjs-auth/1.0" },
    }, "");
    defer alloc.free(raw);

    const parsed = try std.json.parseFromSlice([]const GitHubEmail, alloc, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    for (parsed.value) |e| {
        if (e.primary and e.verified) return alloc.dupe(u8, e.email);
    }
    for (parsed.value) |e| {
        if (e.verified) return alloc.dupe(u8, e.email);
    }
    return error.GitHubNoVerifiedEmail;
}

fn parseDiscordUserInfo(alloc: std.mem.Allocator, raw: []const u8) !UserInfo {
    const parsed = try std.json.parseFromSlice(DiscordUserInfo, alloc, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const v = parsed.value;

    const email = v.email orelse {
        std.debug.print("[oauth] Discord: no email — ensure 'email' scope is included\n", .{});
        return error.DiscordNoEmail;
    };
    if (!v.verified) return error.OAuthEmailNotVerified;
    const avatar: ?[]u8 = if (v.avatar) |hash|
        try std.fmt.allocPrint(alloc, "https://cdn.discordapp.com/avatars/{s}/{s}.png", .{ v.id, hash })
    else
        null;

    return UserInfo{
        .provider_account_id = try alloc.dupe(u8, v.id),
        .email = try alloc.dupe(u8, email),
        .name = try alloc.dupe(u8, if (v.username.len > 0) v.username else email),
        .avatar = avatar,
    };
}

fn mappedString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn parseMappedUserInfo(
    alloc: std.mem.Allocator,
    raw: []const u8,
    mapping: providers.VerifiedEmailMapping,
) !UserInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return error.OAuthInvalidUserInfo,
    };
    const verified = object.get(mapping.email_verified) orelse return error.OAuthEmailNotVerified;
    const is_verified = switch (verified) {
        .bool => |value| value,
        else => false,
    };
    if (!is_verified) return error.OAuthEmailNotVerified;

    const account_id = mappedString(object, mapping.account_id) orelse return error.OAuthMissingAccountId;
    const email = mappedString(object, mapping.email) orelse return error.OAuthMissingEmail;
    const name = if (mapping.name) |field| mappedString(object, field) orelse email else email;
    const avatar = if (mapping.avatar) |field| mappedString(object, field) else null;
    return .{
        .provider_account_id = try alloc.dupe(u8, account_id),
        .email = try alloc.dupe(u8, email),
        .name = try alloc.dupe(u8, name),
        .avatar = if (avatar) |value| try alloc.dupe(u8, value) else null,
    };
}

// ── User find-or-create ────────────────────────────────────────────────────

/// Look up an existing OAuth account or create a new user + account.
/// Returns the user_id string (arena-owned).
fn findOrCreateUser(
    alloc: std.mem.Allocator,
    db_adapter: db.Adapter,
    now_unix: i64,
    provider_id: []const u8,
    user_info: UserInfo,
    token_resp: TokenResponse,
) ![]const u8 {
    const access_expires: i64 = if (token_resp.expires_in) |e| now_unix + e else now_unix + 3600;

    // 1. Look up existing OAuth account.
    var account_result = try db_adapter.query(alloc,
        \\SELECT user_id FROM mauth_oauth_accounts
        \\WHERE provider_id = $1 AND account_id = $2
        \\LIMIT 1
    , &[_]db.Value{
        .{ .text = provider_id },
        .{ .text = user_info.provider_account_id },
    });
    defer account_result.deinit();

    if (account_result.rows.len > 0) {
        const user_id = db.rowText(account_result.rows[0], "user_id") orelse
            return error.OAuthMissingUserId;

        // Update tokens.
        try db_adapter.exec(alloc,
            \\UPDATE mauth_oauth_accounts
            \\SET access_token = $1,
            \\    refresh_token = COALESCE($2, refresh_token),
            \\    access_token_expires_at = to_timestamp($3),
            \\    scope = COALESCE($4, scope),
            \\    updated_at = NOW()
            \\WHERE provider_id = $5 AND account_id = $6
        , &[_]db.Value{
            .{ .text = token_resp.access_token },
            if (token_resp.refresh_token) |r| .{ .text = r } else .{ .null_val = {} },
            .{ .int = access_expires },
            if (token_resp.scope) |s| .{ .text = s } else .{ .null_val = {} },
            .{ .text = provider_id },
            .{ .text = user_info.provider_account_id },
        });

        return alloc.dupe(u8, user_id);
    }

    // 2. Look for existing user by email (prior password signup, etc.).
    var user_result = try db_adapter.query(
        alloc,
        "SELECT id FROM mauth_users WHERE email = $1 LIMIT 1",
        &[_]db.Value{.{ .text = user_info.email }},
    );
    defer user_result.deinit();

    const user_id: []const u8 = if (user_result.rows.len > 0)
        try alloc.dupe(u8, db.rowText(user_result.rows[0], "id") orelse return error.OAuthMissingUserId)
    else blk: {
        const new_id = try crypto.generateUuid(alloc);
        const image_val: db.Value = if (user_info.avatar) |a| .{ .text = a } else .{ .null_val = {} };
        try db_adapter.exec(alloc,
            \\INSERT INTO mauth_users
            \\  (id, name, email, email_verified, image, created_at, updated_at)
            \\VALUES ($1, $2, $3, true, $4, NOW(), NOW())
        , &[_]db.Value{
            .{ .text = new_id },
            .{ .text = user_info.name },
            .{ .text = user_info.email },
            image_val,
        });
        break :blk new_id;
    };

    // 3. Create OAuth account record.
    const account_id = try crypto.generateUuid(alloc);
    try db_adapter.exec(alloc,
        \\INSERT INTO mauth_oauth_accounts
        \\  (id, user_id, provider_id, account_id, access_token,
        \\   refresh_token, access_token_expires_at, scope,
        \\   created_at, updated_at)
        \\VALUES ($1, $2, $3, $4, $5, $6, to_timestamp($7), $8, NOW(), NOW())
    , &[_]db.Value{
        .{ .text = account_id },
        .{ .text = user_id },
        .{ .text = provider_id },
        .{ .text = user_info.provider_account_id },
        .{ .text = token_resp.access_token },
        if (token_resp.refresh_token) |r| .{ .text = r } else .{ .null_val = {} },
        .{ .int = access_expires },
        if (token_resp.scope) |s| .{ .text = s } else .{ .null_val = {} },
    });

    return user_id;
}

const LifetimeTestAdapter = struct {
    fn query(_: *anyopaque, alloc: std.mem.Allocator, sql: []const u8, _: []const db.Value) anyerror!db.QueryResult {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const aa = arena.allocator();
        const fields = if (std.mem.indexOf(u8, sql, "mauth_oauth_states") != null) blk: {
            const result = try aa.alloc(db.Field, 3);
            result[0] = .{ .name = "state", .value = .{ .text = "state" } };
            result[1] = .{ .name = "code_verifier", .value = .{ .text = "verifier" } };
            result[2] = .{ .name = "redirect_uri", .value = .{ .text = "https://app.test/auth/oauth/google/callback" } };
            break :blk result;
        } else if (std.mem.indexOf(u8, sql, "mauth_oauth_accounts") != null) blk: {
            const result = try aa.alloc(db.Field, 1);
            result[0] = .{ .name = "user_id", .value = .{ .text = "user-id" } };
            break :blk result;
        } else try aa.alloc(db.Field, 0);
        const rows = try aa.alloc(db.Row, if (fields.len == 0) 0 else 1);
        if (rows.len == 1) rows[0] = fields;
        return .{ .rows = rows, ._arena = arena };
    }

    fn exec(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const db.Value) anyerror!void {}
    fn deinit(_: *anyopaque) void {}

    const vtable = db.Adapter.VTable{ .queryFn = query, .execFn = exec, .deinitFn = deinit };
};

fn lifetimeTestFetch(
    alloc: std.mem.Allocator,
    url: []const u8,
    _: []const u8,
    _: []const [2][]const u8,
    _: []const u8,
) anyerror!db.FetchResult {
    const body = if (std.mem.indexOf(u8, url, "token") != null)
        "{\"access_token\":\"access-token\",\"expires_in\":3600}"
    else
        "{\"sub\":\"provider-user\",\"email\":\"alice@test.com\",\"email_verified\":true,\"name\":\"Alice\"}";
    return .{ .status = 200, .body = try alloc.dupe(u8, body), ._alloc = alloc };
}

fn clobberStack() void {
    var bytes: [16 * 1024]u8 = undefined;
    @memset(&bytes, 0xa5);
    std.mem.doNotOptimizeAway(&bytes);
}

const lifetime_test_provider = providers.Provider{
    .id = "google",
    .client_id = "client-id",
    .client_secret = "client-secret",
    .auth_url = "https://provider.test/authorize",
    .token_url = "https://provider.test/token",
    .userinfo_url = "https://provider.test/userinfo",
    .scopes = &.{ "openid", "email" },
    .email_verification = .oidc,
};

test "OAuth initiate Location survives handler return and stack clobber" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var adapter_state: u8 = 0;
    const adapter = db.Adapter{ .ptr = &adapter_state, .vtable = &LifetimeTestAdapter.vtable };
    const config = .{
        .oauth_providers = @as([]const providers.Provider, &.{lifetime_test_provider}),
        .base_url = @as([]const u8, "https://app.test"),
        .oauth_state_cookie = @as([]const u8, "mauth_oauth_state"),
        .secure_cookies = false,
    };
    const req = mer.Request.init(arena.allocator(), .GET, "/auth/oauth/google/initiate");
    const ctx = .{ .req = req, .config = &config, .db = adapter, .now_unix = @as(i64, 1) };

    const response = try initiate(&ctx, "google");
    clobberStack();
    const serialized = try std.fmt.allocPrint(std.testing.allocator, "Location: {s}\r\n", .{response.body});
    defer std.testing.allocator.free(serialized);
    try std.testing.expect(std.mem.startsWith(u8, serialized, "Location: https://provider.test/authorize?"));
    try std.testing.expect(std.mem.indexOf(u8, serialized, "code_challenge=") != null);
    try std.testing.expectEqual(@as(usize, 1), response.cookies.len);
    try std.testing.expectEqualStrings("mauth_oauth_state", response.cookies[0].name);
    try std.testing.expectEqual(@as(?u32, 600), response.cookies[0].max_age);
    try std.testing.expect(response.cookies[0].http_only);
    try std.testing.expectEqual(mer.SameSite.lax, response.cookies[0].same_site);
}

test "OAuth callback Set-Cookie survives handler return and stack clobber" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var adapter_state: u8 = 0;
    const adapter = db.Adapter{ .ptr = &adapter_state, .vtable = &LifetimeTestAdapter.vtable };
    const config = .{
        .oauth_providers = @as([]const providers.Provider, &.{lifetime_test_provider}),
        .base_url = @as([]const u8, "https://app.test"),
        .http_fetch = @as(?db.FetchFn, lifetimeTestFetch),
        .session_ttl_s = @as(u32, 3600),
        .secure_cookies = false,
        .session_cookie = @as([]const u8, "mauth_session"),
        .oauth_state_cookie = @as([]const u8, "mauth_oauth_state"),
        .secret = @as([]const u8, "test-secret-at-least-32-bytes-long!!"),
    };
    var req = mer.Request.init(arena.allocator(), .GET, "/auth/oauth/google/callback");
    req.query_string = "code=code&state=state";
    req.cookies_raw = "mauth_oauth_state=state";
    const ctx = .{ .req = req, .config = &config, .db = adapter, .now_unix = @as(i64, 1) };

    const response = try callback(&ctx, "google");
    clobberStack();
    try std.testing.expectEqual(@as(usize, 2), response.cookies.len);
    var cookie_buf: [512]u8 = undefined;
    const serialized = response.cookies[0].headerValue(&cookie_buf);
    try std.testing.expect(std.mem.startsWith(u8, serialized, "mauth_session="));
    try std.testing.expect(std.mem.indexOf(u8, serialized, "; Max-Age=3600") != null);
    try std.testing.expectEqualStrings("mauth_oauth_state", response.cookies[1].name);
    try std.testing.expectEqual(@as(?u32, 0), response.cookies[1].max_age);
}

test "OAuth callback cannot be shared with another browser" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var adapter_state: u8 = 0;
    const adapter = db.Adapter{ .ptr = &adapter_state, .vtable = &LifetimeTestAdapter.vtable };
    const config = .{
        .oauth_providers = @as([]const providers.Provider, &.{lifetime_test_provider}),
        .base_url = @as([]const u8, "https://app.test"),
        .http_fetch = @as(?db.FetchFn, lifetimeTestFetch),
        .session_ttl_s = @as(u32, 3600),
        .secure_cookies = true,
        .session_cookie = @as([]const u8, "mauth_session"),
        .oauth_state_cookie = @as([]const u8, "mauth_oauth_state"),
        .secret = @as([]const u8, "test-secret-at-least-32-bytes-long!!"),
    };
    var req = mer.Request.init(arena.allocator(), .GET, "/auth/oauth/google/callback");
    req.query_string = "code=code&state=state";
    const ctx = .{ .req = req, .config = &config, .db = adapter, .now_unix = @as(i64, 1) };

    const response = try callback(&ctx, "google");
    try std.testing.expectEqual(std.http.Status.bad_request, response.status);
    try std.testing.expectEqual(@as(usize, 1), response.cookies.len);
    try std.testing.expectEqual(@as(?u32, 0), response.cookies[0].max_age);
    try std.testing.expect(response.cookies[0].secure);
}

test "OAuth callback rejects session-swapped correlation state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var adapter_state: u8 = 0;
    const adapter = db.Adapter{ .ptr = &adapter_state, .vtable = &LifetimeTestAdapter.vtable };
    const config = .{
        .oauth_providers = @as([]const providers.Provider, &.{lifetime_test_provider}),
        .base_url = @as([]const u8, "https://app.test"),
        .http_fetch = @as(?db.FetchFn, lifetimeTestFetch),
        .session_ttl_s = @as(u32, 3600),
        .secure_cookies = false,
        .session_cookie = @as([]const u8, "mauth_session"),
        .oauth_state_cookie = @as([]const u8, "mauth_oauth_state"),
        .secret = @as([]const u8, "test-secret-at-least-32-bytes-long!!"),
    };
    var req = mer.Request.init(arena.allocator(), .GET, "/auth/oauth/google/callback");
    req.query_string = "code=attacker-code&state=attacker-state";
    req.cookies_raw = "mauth_oauth_state=victim-state";
    const ctx = .{ .req = req, .config = &config, .db = adapter, .now_unix = @as(i64, 1) };

    const response = try callback(&ctx, "google");
    try std.testing.expectEqual(std.http.Status.bad_request, response.status);
    try std.testing.expectEqual(@as(usize, 1), response.cookies.len);
    try std.testing.expectEqual(@as(?u32, 0), response.cookies[0].max_age);
}

fn unverifiedGitHubEmailFetch(
    alloc: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const [2][]const u8,
    _: []const u8,
) anyerror!db.FetchResult {
    const body = "[{\"email\":\"victim@example.com\",\"primary\":true,\"verified\":false}]";
    return .{ .status = 200, .body = try alloc.dupe(u8, body), ._alloc = alloc };
}

test "OAuth rejects unverified provider email claims" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectError(
        error.OAuthEmailNotVerified,
        parseGoogleUserInfo(alloc, "{\"sub\":\"attacker\",\"email\":\"victim@example.com\",\"email_verified\":false}"),
    );
    try std.testing.expectError(
        error.GitHubNoVerifiedEmail,
        parseGitHubUserInfo(
            alloc,
            unverifiedGitHubEmailFetch,
            "{\"id\":1,\"login\":\"attacker\",\"email\":\"victim@example.com\"}",
            "token",
        ),
    );
    try std.testing.expectError(
        error.OAuthEmailNotVerified,
        parseMappedUserInfo(
            alloc,
            "{\"sub\":\"attacker\",\"email\":\"victim@example.com\",\"email_verified\":false}",
            .{},
        ),
    );
}
