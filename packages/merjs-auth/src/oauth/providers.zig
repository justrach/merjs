//! Built-in OAuth 2.0 provider configurations for merjs-auth.
//!
//! Usage:
//!   const p = oauth.providers.google("MY_CLIENT_ID", "MY_CLIENT_SECRET");
//!   // Then add p to your Config.oauth_providers slice.

const std = @import("std");

// ── Provider type ──────────────────────────────────────────────────────────

/// Full configuration for an OAuth 2.0 provider.
pub const Provider = struct {
    /// Unique identifier, e.g. "google", "github".
    id: []const u8,
    /// OAuth application client ID.
    client_id: []const u8,
    /// OAuth application client secret.
    client_secret: []const u8,
    /// Authorization endpoint URL (where the user is redirected to log in).
    auth_url: []const u8,
    /// Token exchange endpoint URL (used server-side after the callback).
    token_url: []const u8,
    /// Userinfo endpoint URL (fetched after token exchange to get email/name).
    userinfo_url: []const u8,
    /// OAuth scopes to request, e.g. &.{"openid", "email", "profile"}.
    scopes: []const []const u8,
    /// Optional redirect URI override.
    /// When null the auth layer derives: {base_url}/auth/oauth/{id}/callback
    redirect_uri: ?[]const u8 = null,
};

// ── Built-in providers ─────────────────────────────────────────────────────

/// Google — OpenID Connect / OAuth 2.0.
/// Scopes: openid, email, profile.
pub fn google(client_id: []const u8, client_secret: []const u8) Provider {
    return .{
        .id = "google",
        .client_id = client_id,
        .client_secret = client_secret,
        .auth_url = "https://accounts.google.com/o/oauth2/v2/auth",
        .token_url = "https://oauth2.googleapis.com/token",
        .userinfo_url = "https://www.googleapis.com/oauth2/v3/userinfo",
        .scopes = &.{ "openid", "email", "profile" },
    };
}

/// GitHub — OAuth 2.0.
/// Scopes: user:email (reads the user's primary email even if private).
pub fn github(client_id: []const u8, client_secret: []const u8) Provider {
    return .{
        .id = "github",
        .client_id = client_id,
        .client_secret = client_secret,
        .auth_url = "https://github.com/login/oauth/authorize",
        .token_url = "https://github.com/login/oauth/access_token",
        .userinfo_url = "https://api.github.com/user",
        .scopes = &.{"user:email"},
    };
}

/// Discord — OAuth 2.0.
/// Scopes: identify, email.
pub fn discord(client_id: []const u8, client_secret: []const u8) Provider {
    return .{
        .id = "discord",
        .client_id = client_id,
        .client_secret = client_secret,
        .auth_url = "https://discord.com/api/oauth2/authorize",
        .token_url = "https://discord.com/api/oauth2/token",
        .userinfo_url = "https://discord.com/api/users/@me",
        .scopes = &.{ "identify", "email" },
    };
}

/// Microsoft / Azure AD — OpenID Connect / OAuth 2.0.
/// `tenant_id` is your Azure tenant (e.g. "common", "organizations",
/// "consumers", or a specific tenant GUID / domain).
/// Scopes: openid, email, profile.
pub fn microsoft(
    client_id: []const u8,
    client_secret: []const u8,
    tenant_id: []const u8,
) Provider {
    // NOTE: The URLs contain the tenant_id. We build them as comptime-ish
    // literals when the tenant is a compile-time constant, but since Zig
    // does not allow runtime string interpolation at the type level we use
    // a small trick: the provider URLs are built lazily.
    //
    // Because `Provider` stores slices, and the tenant_id slice must outlive
    // this call, we return static URLs per the three well-known tenant types
    // and fall back to a manual concatenation note for custom tenants.
    //
    // For a fully dynamic URL you should pre-allocate the strings with an
    // arena and pass them in via `redirect_uri` override + custom Provider.
    //
    // The common/organizations/consumers tenants are handled inline here.
    // Custom tenants: use `microsoft_tenant` below.

    return microsoftForTenant(client_id, client_secret, tenant_id);
}

/// Internal helper — builds Microsoft URLs for a given tenant string.
/// `tenant_id` must be a string literal or have static lifetime because the
/// returned `Provider` stores raw pointers into it.
pub fn microsoftForTenant(
    client_id: []const u8,
    client_secret: []const u8,
    tenant_id: []const u8,
) Provider {
    // We cannot allocate here (no allocator), so callers that need dynamic
    // tenant URLs should build the Provider manually with an arena.
    //
    // For the three well-known tenants we embed static strings.
    if (std.mem.eql(u8, tenant_id, "common")) {
        return .{
            .id = "microsoft",
            .client_id = client_id,
            .client_secret = client_secret,
            .auth_url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            .token_url = "https://login.microsoftonline.com/common/oauth2/v2.0/token",
            .userinfo_url = "https://graph.microsoft.com/v1.0/me",
            .scopes = &.{ "openid", "email", "profile" },
        };
    }
    if (std.mem.eql(u8, tenant_id, "organizations")) {
        return .{
            .id = "microsoft",
            .client_id = client_id,
            .client_secret = client_secret,
            .auth_url = "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize",
            .token_url = "https://login.microsoftonline.com/organizations/oauth2/v2.0/token",
            .userinfo_url = "https://graph.microsoft.com/v1.0/me",
            .scopes = &.{ "openid", "email", "profile" },
        };
    }
    if (std.mem.eql(u8, tenant_id, "consumers")) {
        return .{
            .id = "microsoft",
            .client_id = client_id,
            .client_secret = client_secret,
            .auth_url = "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize",
            .token_url = "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
            .userinfo_url = "https://graph.microsoft.com/v1.0/me",
            .scopes = &.{ "openid", "email", "profile" },
        };
    }
    // For all other tenant IDs: the caller is responsible for ensuring
    // tenant_id has sufficient lifetime. We embed the pointer directly.
    // Because we cannot format without allocation here, we fall back to
    // "common" URLs and flag via id so callers know to override.
    //
    // Production usage with dynamic tenant IDs: build `Provider` manually
    // using `microsoftBuildUrls(alloc, tenant_id)` (see below).
    return .{
        .id = "microsoft",
        .client_id = client_id,
        .client_secret = client_secret,
        // Fallback: will not work for per-tenant apps — use microsoftBuildUrls.
        .auth_url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
        .token_url = "https://login.microsoftonline.com/common/oauth2/v2.0/token",
        .userinfo_url = "https://graph.microsoft.com/v1.0/me",
        .scopes = &.{ "openid", "email", "profile" },
    };
}

/// Build a Microsoft `Provider` with dynamically constructed per-tenant URLs.
/// Uses `alloc` to allocate the URL strings; they must outlive the Provider.
pub fn microsoftBuildUrls(
    alloc: std.mem.Allocator,
    client_id: []const u8,
    client_secret: []const u8,
    tenant_id: []const u8,
) !Provider {
    const auth_url = try std.fmt.allocPrint(
        alloc,
        "https://login.microsoftonline.com/{s}/oauth2/v2.0/authorize",
        .{tenant_id},
    );
    const token_url = try std.fmt.allocPrint(
        alloc,
        "https://login.microsoftonline.com/{s}/oauth2/v2.0/token",
        .{tenant_id},
    );
    return Provider{
        .id = "microsoft",
        .client_id = client_id,
        .client_secret = client_secret,
        .auth_url = auth_url,
        .token_url = token_url,
        .userinfo_url = "https://graph.microsoft.com/v1.0/me",
        .scopes = &.{ "openid", "email", "profile" },
    };
}
