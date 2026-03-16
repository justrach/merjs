//! Route dispatcher for all auth endpoints.
//!
//! Matches on HTTP method + subpath (prefix-stripped) and delegates to the
//! appropriate handler. OAuth and SAML routes extract the provider_id segment
//! from the URL before delegating.

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
const saml = @import("../saml/root.zig");

/// Dispatch a request to the appropriate handler based on method + path.
/// `subpath` is the path with the auth prefix stripped (e.g. "/sign-in/email").
pub fn dispatch(ctx: *AuthContext, subpath: []const u8) anyerror!mer.Response {
    const method = ctx.req.method;

    // ── Email auth endpoints ──────────────────────────────────────────────

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, subpath, "/sign-up/email")) {
        return sign_up.handle(ctx);
    }

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, subpath, "/sign-in/email")) {
        return sign_in.handle(ctx);
    }

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, subpath, "/sign-out")) {
        return sign_out.handle(ctx);
    }

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, subpath, "/session")) {
        return get_session.handle(ctx);
    }

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, subpath, "/change-password")) {
        return change_password.handle(ctx);
    }

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, subpath, "/forgot-password")) {
        return send_reset.handle(ctx);
    }

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, subpath, "/reset-password")) {
        return reset_password.handle(ctx);
    }

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, subpath, "/send-verification-email")) {
        return send_verification.handle(ctx);
    }

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, subpath, "/verify-email")) {
        return verify_email.handle(ctx);
    }

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, subpath, "/magic-link/send")) {
        return magic_link.send(ctx);
    }

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, subpath, "/magic-link/verify")) {
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

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, action, "initiate")) {
            return oauth.initiate(ctx, provider_id);
        }
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, action, "callback")) {
            return oauth.callback(ctx, provider_id);
        }
        return mer.notFound();
    }

    // ── SAML endpoints ────────────────────────────────────────────────────
    // Pattern: /saml/{provider_id}/{action}

    if (std.mem.startsWith(u8, subpath, "/saml/")) {
        const rest = subpath["/saml/".len..];
        const slash_pos = std.mem.indexOfScalar(u8, rest, '/') orelse {
            return mer.notFound();
        };
        const provider_id = rest[0..slash_pos];
        const action = rest[slash_pos + 1 ..];

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, action, "initiate")) {
            return saml.initiate(ctx, provider_id);
        }
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, action, "callback")) {
            return saml.callback(ctx, provider_id);
        }
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, action, "metadata")) {
            return saml.metadata(ctx, provider_id);
        }
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, action, "slo")) {
            return saml.slo(ctx, provider_id);
        }
        return mer.notFound();
    }

    return mer.notFound();
}
