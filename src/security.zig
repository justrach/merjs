const std = @import("std");

/// Strict policy used unless development mode or an application override is selected.
pub const production_csp = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'";

/// Development policy permits only the inline hot-reload/error-overlay code.
pub const development_csp = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'";

pub const header_count = 7;

pub fn headers(csp: []const u8) [header_count]std.http.Header {
    return .{
        .{ .name = "strict-transport-security", .value = "max-age=63072000; includeSubDomains; preload" },
        .{ .name = "content-security-policy", .value = csp },
        .{ .name = "x-frame-options", .value = "DENY" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "referrer-policy", .value = "strict-origin-when-cross-origin" },
        .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
        .{ .name = "permissions-policy", .value = "camera=(), microphone=(), geolocation=()" },
    };
}

test "production and development policies expose only intended capabilities" {
    try std.testing.expect(std.mem.indexOf(u8, production_csp, "unsafe-inline") == null);
    try std.testing.expect(std.mem.indexOf(u8, production_csp, "unsafe-eval") == null);
    try std.testing.expect(std.mem.indexOf(u8, production_csp, "wasm-unsafe-eval") == null);
    try std.testing.expect(std.mem.indexOf(u8, production_csp, "cdn.jsdelivr.net") == null);
    try std.testing.expect(std.mem.indexOf(u8, production_csp, "upgrade-insecure-requests") == null);
    try std.testing.expect(std.mem.indexOf(u8, development_csp, "'unsafe-inline'") != null);
    try std.testing.expect(std.mem.indexOf(u8, development_csp, "unsafe-eval") == null);
    try std.testing.expectEqualStrings(development_csp, headers(development_csp)[1].value);
}
