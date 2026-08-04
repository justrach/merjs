//! Route dispatcher for all auth endpoints.
//!
//! Matches on HTTP method + subpath (prefix-stripped) and delegates to the
//! appropriate handler. OAuth routes extract the provider_id segment before
//! delegating; SAML routes fail closed while XMLDSig is unsupported.

const std = @import("std");
const mer = @import("mer");
const AuthContext = @import("../auth.zig").AuthContext;

const sign_up = @import("sign_up.zig");
const sign_in = @import("sign_in.zig");
const sign_out = @import("sign_out.zig");
const get_session = @import("get_session.zig");
const change_password = @import("change_password.zig");
const send_reset = @import("send_reset.zig");
const reset_password = @import("reset_password.zig");
const send_verification = @import("send_verification.zig");
const verify_email = @import("verify_email.zig");
const magic_link = @import("magic_link.zig");
const oauth = @import("../oauth/root.zig");

fn errorResponse(status: std.http.Status, message: []const u8) mer.Response {
    return mer.Response.init(status, .json, message);
}

fn hasUniqueHeader(req: mer.Request, name: []const u8) ?[]const u8 {
    var value: ?[]const u8 = null;
    for (req.headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (value != null) return null;
        value = header.value;
    }
    return value;
}

fn isJsonRequest(req: mer.Request) bool {
    const value = hasUniqueHeader(req, "content-type") orelse return false;
    const semi = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..semi], " \t"), "application/json");
}

fn containsUnsafeUrlByte(value: []const u8) bool {
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '\\' or byte == '%') return true;
    }
    return false;
}

fn isEmptyOrSlash(component: std.Uri.Component) bool {
    return switch (component) {
        .raw, .percent_encoded => |value| value.len == 0 or std.mem.eql(u8, value, "/"),
    };
}

fn sameOrigin(left_raw: []const u8, right_raw: []const u8, strict_left: bool, strict_right: bool) bool {
    if (containsUnsafeUrlByte(left_raw) or containsUnsafeUrlByte(right_raw)) return false;
    const left = std.Uri.parse(left_raw) catch return false;
    const right = std.Uri.parse(right_raw) catch return false;
    if ((!std.ascii.eqlIgnoreCase(left.scheme, "http") and !std.ascii.eqlIgnoreCase(left.scheme, "https")) or
        !std.ascii.eqlIgnoreCase(left.scheme, right.scheme) or left.user != null or left.password != null or
        right.user != null or right.password != null)
    {
        return false;
    }
    if (strict_left and (!isEmptyOrSlash(left.path) or left.query != null or left.fragment != null)) return false;
    if (strict_right and (!isEmptyOrSlash(right.path) or right.query != null or right.fragment != null)) return false;

    var left_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    var right_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const left_host = left.getHost(&left_buf) catch return false;
    const right_host = right.getHost(&right_buf) catch return false;
    if (!std.ascii.eqlIgnoreCase(left_host.bytes, right_host.bytes)) return false;

    const default_port: u16 = if (std.ascii.eqlIgnoreCase(left.scheme, "https")) 443 else 80;
    return (left.port orelse default_port) == (right.port orelse default_port);
}

fn isTrustedOrigin(ctx: *AuthContext) bool {
    const origin = hasUniqueHeader(ctx.req, "origin") orelse return false;
    if (sameOrigin(origin, ctx.config.base_url, true, false)) return true;
    for (ctx.config.trusted_origins) |trusted| {
        if (sameOrigin(origin, trusted, true, true)) return true;
    }
    return false;
}

fn isJsonPostRoute(subpath: []const u8) bool {
    const routes = [_][]const u8{
        "/sign-up/email",
        "/sign-in/email",
        "/sign-out",
        "/change-password",
        "/forgot-password",
        "/reset-password",
        "/send-verification-email",
        "/magic-link/send",
    };
    for (routes) |route| {
        if (std.mem.eql(u8, subpath, route)) return true;
    }
    return false;
}

/// Dispatch a request to the appropriate handler based on method + path.
/// `subpath` is the path with the auth prefix stripped (e.g. "/sign-in/email").
pub fn dispatch(ctx: *AuthContext, subpath: []const u8) anyerror!mer.Response {
    const method = ctx.req.method;

    if (method == .POST and isJsonPostRoute(subpath)) {
        if (!isJsonRequest(ctx.req)) {
            return errorResponse(.unsupported_media_type, "{\"error\":\"content-type must be application/json\"}");
        }
        if (!isTrustedOrigin(ctx)) {
            return errorResponse(.forbidden, "{\"error\":\"untrusted origin\"}");
        }
    }

    // ── Email auth endpoints ──────────────────────────────────────────────

    if (method == .POST and std.mem.eql(u8, subpath, "/sign-up/email")) {
        return sign_up.handle(ctx);
    }

    if (method == .POST and std.mem.eql(u8, subpath, "/sign-in/email")) {
        return sign_in.handle(ctx);
    }

    if (method == .POST and std.mem.eql(u8, subpath, "/sign-out")) {
        return sign_out.handle(ctx);
    }

    if (method == .GET and std.mem.eql(u8, subpath, "/session")) {
        return get_session.handle(ctx);
    }

    if (method == .POST and std.mem.eql(u8, subpath, "/change-password")) {
        return change_password.handle(ctx);
    }

    if (method == .POST and std.mem.eql(u8, subpath, "/forgot-password")) {
        return send_reset.handle(ctx);
    }

    if (method == .POST and std.mem.eql(u8, subpath, "/reset-password")) {
        return reset_password.handle(ctx);
    }

    if (method == .POST and std.mem.eql(u8, subpath, "/send-verification-email")) {
        return send_verification.handle(ctx);
    }

    if (method == .GET and std.mem.eql(u8, subpath, "/verify-email")) {
        return verify_email.handle(ctx);
    }

    if (method == .POST and std.mem.eql(u8, subpath, "/magic-link/send")) {
        return magic_link.send(ctx);
    }

    if (method == .GET and std.mem.eql(u8, subpath, "/magic-link/verify")) {
        return magic_link.verify(ctx);
    }

    // ── OAuth endpoints ───────────────────────────────────────────────────
    // Pattern: /oauth/{provider_id}/initiate  or  /oauth/{provider_id}/callback

    if (std.mem.startsWith(u8, subpath, "/oauth/")) {
        // subpath after "/oauth/" → "{provider_id}/initiate" or "{provider_id}/callback"
        const rest = subpath["/oauth/".len..];
        const slash_pos = std.mem.indexOfScalar(u8, rest, '/') orelse {
            return mer.notFound();
        };
        const provider_id = rest[0..slash_pos];
        const action = rest[slash_pos + 1 ..];

        if (method == .GET and std.mem.eql(u8, action, "initiate")) {
            return oauth.initiate(ctx, provider_id);
        }
        if (method == .GET and std.mem.eql(u8, action, "callback")) {
            return oauth.callback(ctx, provider_id);
        }
        return mer.notFound();
    }

    // SAML is intentionally unavailable until XMLDSig verification is supported.
    if (std.mem.startsWith(u8, subpath, "/saml/")) {
        return errorResponse(.not_implemented, "{\"error\":\"SAML is unsupported: XMLDSig verification is unavailable\"}");
    }

    return mer.notFound();
}
