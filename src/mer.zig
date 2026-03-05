// mer.zig — public API for page authors and internal modules.
// Both app/ and src/ internal files import this as `@import("mer")`.

const std     = @import("std");
const req_mod = @import("request.zig");
const res_mod = @import("response.zig");

// --- HTTP types -------------------------------------------------------------
pub const Method      = req_mod.Method;
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

/// Read an environment variable. Returns null if not set.
///
///   const api_url = mer.env("MULTICLAW_API_URL") orelse "http://localhost:8443";
pub fn env(name: []const u8) ?[]const u8 {
    return std.posix.getenv(name);
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
