// mer.zig — public API for page authors and internal modules.
// Both app/ and src/ internal files import this as `@import("mer")`.

const std     = @import("std");
const req_mod = @import("request.zig");
const res_mod = @import("response.zig");

/// Framework version — kept in sync with build.zig.zon.
pub const version = "0.1.0";

// --- HTTP types -------------------------------------------------------------
pub const Method      = req_mod.Method;
pub const Param       = req_mod.Param;
pub const Request     = req_mod.Request;
pub const ContentType = res_mod.ContentType;
pub const Response    = res_mod.Response;
pub const SameSite    = res_mod.SameSite;
pub const SetCookie   = res_mod.SetCookie;

// --- Response helpers -------------------------------------------------------
pub const html          = res_mod.html;
pub const json          = res_mod.json;
pub const text          = res_mod.text;
pub const notFound      = res_mod.notFound;
pub const internalError = res_mod.internalError;

/// HTTP redirect.
///
///   return mer.redirect("/login", .found);          // 302
///   return mer.redirect("/dashboard", .see_other);  // 303 after POST
pub const redirect = res_mod.redirect;

/// Return a copy of `res` with Set-Cookie headers added.
///
///   return mer.withCookies(mer.redirect("/dashboard", .see_other), &.{
///       .{ .name = "session", .value = token, .max_age = 86400 },
///   });
pub const withCookies = res_mod.withCookies;

/// Serialize any struct to a JSON response (type-safe alternative to `json()`).
///
///   const TimeResp = struct { timestamp: i64, unit: []const u8 };
///   return mer.typedJson(req.allocator, TimeResp{ .timestamp = ts, .unit = "s" });
pub fn typedJson(allocator: std.mem.Allocator, value: anytype) Response {
    var out: std.io.Writer.Allocating = .init(allocator);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.write(value) catch return internalError("json write failed");
    return res_mod.Response.init(.ok, .json, out.written());
}

/// Parse a JSON request body into type T.
///
///   const Body = struct { name: []const u8, age: u32 };
///   const body = try mer.parseJson(Body, req) orelse return mer.badRequest("empty body");
///
/// Returns null for an empty body. Caller owns the parsed value (call `.deinit()`).
pub fn parseJson(comptime T: type, req: Request) !?std.json.Parsed(T) {
    if (req.body.len == 0) return null;
    return std.json.parseFromSlice(T, req.allocator, req.body, .{ .ignore_unknown_fields = true });
}

/// Parse a `application/x-www-form-urlencoded` body for a named parameter.
/// Returns the raw (not URL-decoded) value, or null if not found.
///
///   const user_id = mer.formParam(req.body, "user_id") orelse return mer.badRequest("missing user_id");
pub fn formParam(body: []const u8, name: []const u8) ?[]const u8 {
    var params = body;
    while (params.len > 0) {
        const amp = std.mem.indexOfScalar(u8, params, '&') orelse params.len;
        const kv  = params[0..amp];
        if (std.mem.indexOfScalar(u8, kv, '=')) |eq| {
            if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
        }
        params = if (amp < params.len) params[amp + 1 ..] else "";
    }
    return null;
}

/// 400 Bad Request response with a plain-text message.
pub fn badRequest(msg: []const u8) Response {
    return res_mod.Response.init(.bad_request, .text, msg);
}

// --- Environment ------------------------------------------------------------

const env_mod = @import("env.zig");

/// Read an environment variable. Returns null if not set.
/// On native: checks .env table first, then the process environment.
/// On Workers (wasm32): reads from secrets injected via __mer_set_env.
///
///   const key = mer.env("OPENAI_API_KEY") orelse return mer.badRequest("not configured");
pub fn env(name: []const u8) ?[]const u8 {
    return env_mod.get(name);
}

/// Load a .env file from cwd into the env table. Call once at startup before threads.
/// Re-exported here so main.zig (root module) can reach env.zig via the mer module.
pub const loadDotenv = env_mod.loadDotenv;

// --- Session management -----------------------------------------------------

/// Decoded session payload returned by `verifySession`.
pub const Session = struct {
    /// The authenticated user ID.
    user_id: []const u8,
    /// Unix timestamp when the session expires.
    expires_at: i64,
};

const SessionHmac = std.crypto.auth.hmac.sha2.HmacSha256;
/// Length of the HMAC hex string appended to session tokens (64 chars).
const SESSION_HMAC_HEX_LEN = SessionHmac.mac_length * 2;
/// Default session lifetime: 7 days.
pub const SESSION_DEFAULT_TTL: u32 = 7 * 24 * 60 * 60;

/// Sign a session token for `user_id` valid for `ttl_secs` seconds.
/// Reads the signing secret from `MULTICLAW_SESSION_SECRET`.
/// Returns an allocated string owned by `allocator`.
///
///   const token = try mer.signSession(req.allocator, user_id, mer.SESSION_DEFAULT_TTL);
///   return mer.withCookies(res, &.{
///       .{ .name = "session", .value = token, .http_only = true, .secure = true,
///          .same_site = .lax, .max_age = mer.SESSION_DEFAULT_TTL },
///   });
pub fn signSession(
    allocator: std.mem.Allocator,
    user_id: []const u8,
    ttl_secs: u32,
) ![]u8 {
    const secret = env("MULTICLAW_SESSION_SECRET") orelse return error.NoSessionSecret;
    const expires_at = std.time.timestamp() + @as(i64, ttl_secs);
    // msg = "{user_id}.{expires_unix}"
    const msg = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ user_id, expires_at });
    defer allocator.free(msg);

    var mac: [SessionHmac.mac_length]u8 = undefined;
    SessionHmac.create(&mac, msg, secret);
    const hex = std.fmt.bytesToHex(mac, .lower);

    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ msg, &hex });
}

/// Verify a session token produced by `signSession`.
/// Returns null if the token is malformed, tampered with, or expired.
/// Reads the signing secret from `MULTICLAW_SESSION_SECRET`.
///
///   const session = mer.verifySession(req.cookie("session") orelse "") orelse {
///       return mer.redirect("/login", .found);
///   };
///   // session.user_id is now trusted
pub fn verifySession(token: []const u8) ?Session {
    const secret = env("MULTICLAW_SESSION_SECRET") orelse return null;

    // Token format: "{user_id}.{expires_unix}.{64-char hmac hex}"
    // Find the last two dots from the right.
    if (token.len < SESSION_HMAC_HEX_LEN + 3) return null; // "x.0.<hex>"

    const last_dot = std.mem.lastIndexOfScalar(u8, token, '.') orelse return null;
    const hmac_hex = token[last_dot + 1 ..];
    if (hmac_hex.len != SESSION_HMAC_HEX_LEN) return null;

    const prefix = token[0..last_dot]; // "{user_id}.{expires_unix}"
    const mid_dot = std.mem.lastIndexOfScalar(u8, prefix, '.') orelse return null;
    const expires_str = prefix[mid_dot + 1 ..];
    const user_id = prefix[0..mid_dot];

    // Parse and check expiry.
    const expires_at = std.fmt.parseInt(i64, expires_str, 10) catch return null;
    if (std.time.timestamp() > expires_at) return null;

    // Recompute HMAC over the prefix.
    var mac: [SessionHmac.mac_length]u8 = undefined;
    SessionHmac.create(&mac, prefix, secret);
    const expected = std.fmt.bytesToHex(mac, .lower);

    // Constant-time comparison to prevent timing attacks.
    if (!std.crypto.timing_safe.eql(
        [SESSION_HMAC_HEX_LEN]u8,
        expected,
        hmac_hex[0..SESSION_HMAC_HEX_LEN].*,
    )) return null;

    return .{ .user_id = user_id, .expires_at = expires_at };
}

// --- SSR HTTP client --------------------------------------------------------

pub const FetchRequest = struct {
    url:     []const u8,
    method:  std.http.Method = .GET,
    /// Raw request body (optional).
    body:    ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
};

pub const FetchResponse = struct {
    status: std.http.Status,
    /// Response body. Owned by the caller's allocator — call `deinit()` when done.
    body:   []u8,

    pub fn deinit(self: FetchResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

/// Make an HTTP request from a server-side page handler.
///
///   const res = try mer.fetch(req.allocator, .{
///       .url    = "http://localhost:8443/health",
///       .method = .GET,
///   });
///   defer res.deinit(req.allocator);
///   if (res.status != .ok) return mer.internalError("upstream error");
pub fn fetch(allocator: std.mem.Allocator, opts: FetchRequest) !FetchResponse {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var collecting: std.io.Writer.Allocating = .init(allocator);
    defer collecting.deinit();

    const result = try client.fetch(.{
        .location        = .{ .url = opts.url },
        .method          = opts.method,
        .payload         = opts.body,
        .extra_headers   = opts.headers,
        .response_writer = &collecting.writer,
    });

    const raw = collecting.writer.buffer[0..collecting.writer.end];
    const owned = try allocator.dupe(u8, raw);
    return .{ .status = result.status, .body = owned };
}

// --- SEO / Meta tags --------------------------------------------------------
/// Typed metadata for pages. Export `pub const meta: mer.Meta = .{ ... }` from
/// any page and the framework injects the correct <meta> / OG / Twitter tags.
pub const Meta = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    // Open Graph
    og_title: ?[]const u8 = null,
    og_description: ?[]const u8 = null,
    og_image: ?[]const u8 = null,
    og_url: ?[]const u8 = null,
    og_type: []const u8 = "website",
    og_site_name: []const u8 = "merjs",
    // Twitter Card
    twitter_card: []const u8 = "summary_large_image",
    twitter_title: ?[]const u8 = null,
    twitter_description: ?[]const u8 = null,
    twitter_image: ?[]const u8 = null,
    twitter_site: ?[]const u8 = null,
    // Other
    canonical: ?[]const u8 = null,
    robots: ?[]const u8 = null,
    // Extra head HTML (custom <link>, <script>, etc.)
    extra_head: ?[]const u8 = null,
};

// --- HTML builder -----------------------------------------------------------
/// Type-safe HTML DSL. Build pages with `mer.h.div(...)`, `mer.h.document(...)`, etc.
pub const h = @import("html.zig");

// --- HTML linter ------------------------------------------------------------
/// Comptime HTML linter. Use `mer.lint.check(node)` to enforce structural rules.
pub const lint = @import("html_lint.zig");

/// Render an HTML node tree to a Response.
pub fn render(allocator: std.mem.Allocator, node: h.Node) Response {
    const body = h.render(allocator, node) catch return internalError("html render failed");
    return Response.init(.ok, .html, body);
}

// --- Validation (dhi) -------------------------------------------------------
/// Pydantic-style validation types. Define typed models and validate them.
pub const dhi = @import("dhi.zig");

// --- Counter config (shared with WASM module) --------------------------------
pub const counter_config = @import("counter_config");
