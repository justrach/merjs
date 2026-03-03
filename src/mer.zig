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

// --- Response helpers -------------------------------------------------------
pub const html          = res_mod.html;
pub const json          = res_mod.json;
pub const text          = res_mod.text;
pub const notFound      = res_mod.notFound;
pub const internalError = res_mod.internalError;

/// Serialize any struct to a JSON response (type-safe alternative to `json()`).
///
///   const TimeResp = struct { timestamp: i64, unit: []const u8 };
///   return mer.typedJson(req.allocator, TimeResp{ .timestamp = ts, .unit = "s" });
pub fn typedJson(allocator: std.mem.Allocator, value: anytype) Response {
    var out: std.io.Writer.Allocating = .init(allocator);
    // No deinit needed — arena allocator owns the memory for the lifetime of the request.
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.write(value) catch return internalError("json write failed");
    return res_mod.Response.init(.ok, .json, out.written());
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

// --- Validation (dhi) -------------------------------------------------------
/// Pydantic-style validation types. Define typed models and validate them.
///
///   const User = mer.dhi.Model("User", .{
///       .name  = mer.dhi.Str(.{ .min_length = 1 }),
///       .email = mer.dhi.EmailStr,
///   });
///   const user = try User.parse(.{ .name = "Alice", .email = "a@b.com" });
pub const dhi = @import("dhi.zig");
