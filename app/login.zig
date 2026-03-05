// login.zig — OAuth login page.
//
// GET  /login  → shows login form with Google / GitHub buttons
// POST /login  → initiates OAuth PKCE flow via multiclaw, redirects to provider
//
// Required env vars:
//   MULTICLAW_API_URL   default: http://localhost:8443
//   MULTICLAW_APP_ID    default: app_seed01
//   MULTICLAW_API_KEY   (required for POST)
//   GOOGLE_CLIENT_ID    (required for Google)
//   GITHUB_CLIENT_ID    (required for GitHub)
//   APP_PUBLIC_URL      default: http://localhost:3000

const std = @import("std");
const mer = @import("mer");
const h   = mer.h;

pub const meta: mer.Meta = .{
    .title       = "Login — Connect your accounts",
    .description = "Connect your Google or GitHub account via multiclaw OAuth.",
    .extra_head  = "<style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    return if (req.method == .POST) handlePost(req) else renderPage(req);
}

// ── GET handler ────────────────────────────────────────────────────────────

fn renderPage(req: mer.Request) mer.Response {
    // Show a flash if we came from a bad provider.
    const flash = req.queryParam("error");
    const node = h.div(.{ .class = "login-page" }, .{
        h.h1(.{}, "Connect an account"),
        h.p(.{ .class = "subtitle" }, "Pick a provider to connect via OAuth."),
        if (flash != null)
            h.div(.{ .class = "flash error" }, flash.?)
        else
            h.raw(""),
        h.form(.{ .action = "/login", .method = "post", .class = "login-form" }, .{
            h.div(.{ .class = "field" }, .{
                h.label(.{ .@"for" = "user_id" }, "User ID"),
                h.input(.{
                    .id          = "user_id",
                    .name        = "user_id",
                    .@"type"     = "text",
                    .placeholder = "alice",
                    .required    = true,
                }),
            }),
            h.div(.{ .class = "providers" }, .{
                h.button(.{ .name = "provider", .value = "google", .@"type" = "submit", .class = "btn google" }, .{
                    h.raw("&#x1F4E7;&nbsp; Connect Google"),
                }),
                h.button(.{ .name = "provider", .value = "github", .@"type" = "submit", .class = "btn github" }, .{
                    h.raw("&#x1F431;&nbsp; Connect GitHub"),
                }),
            }),
        }),
        h.p(.{ .class = "note" }, .{
            h.text("Tokens are stored encrypted by "),
            h.a(.{ .href = "https://github.com/justrach/multiclaw" }, "multiclaw"),
            h.text(". The frontend never sees them."),
        }),
    });
    return mer.render(req.allocator, node);
}

// ── POST handler ───────────────────────────────────────────────────────────

fn handlePost(req: mer.Request) mer.Response {
    // Parse URL-encoded form body.
    const user_id  = mer.formParam(req.body, "user_id")  orelse return mer.badRequest("missing user_id");
    const provider = mer.formParam(req.body, "provider") orelse return mer.badRequest("missing provider");

    if (user_id.len == 0)  return mer.redirect("/login?error=user_id+required", .see_other);
    if (provider.len == 0) return mer.redirect("/login?error=provider+required", .see_other);

    // Read config from environment.
    const api_url    = mer.env("MULTICLAW_API_URL") orelse "http://localhost:8443";
    const app_id     = mer.env("MULTICLAW_APP_ID")  orelse "app_seed01";
    const api_key    = mer.env("MULTICLAW_API_KEY")  orelse "";
    const public_url = mer.env("APP_PUBLIC_URL")     orelse "http://localhost:3000";

    const client_id: []const u8 = if (std.mem.eql(u8, provider, "google"))
        mer.env("GOOGLE_CLIENT_ID") orelse ""
    else if (std.mem.eql(u8, provider, "github"))
        mer.env("GITHUB_CLIENT_ID") orelse ""
    else
        return mer.redirect("/login?error=unknown+provider", .see_other);

    if (client_id.len == 0) return mer.redirect("/login?error=client_id+not+configured", .see_other);

    // Build multiclaw API URL and request body.
    const multiclaw_url = std.fmt.allocPrint(
        req.allocator,
        "{s}/v1/apps/{s}/users/{s}/connections/{s}",
        .{ api_url, app_id, user_id, provider },
    ) catch return mer.internalError("oom");

    const redirect_uri = std.fmt.allocPrint(
        req.allocator,
        "{s}/connected",
        .{public_url},
    ) catch return mer.internalError("oom");

    const scopes: []const u8 = if (std.mem.eql(u8, provider, "google"))
        "openid email profile"
    else
        "read:user user:email";

    const body_json = std.fmt.allocPrint(
        req.allocator,
        "{{\"redirect_uri\":\"{s}\",\"scopes\":\"{s}\",\"client_id\":\"{s}\"}}",
        .{ redirect_uri, scopes, client_id },
    ) catch return mer.internalError("oom");

    const auth_header = std.fmt.allocPrint(
        req.allocator,
        "Bearer {s}",
        .{api_key},
    ) catch return mer.internalError("oom");

    // Call multiclaw to initiate the PKCE flow.
    const result = mer.fetch(req.allocator, .{
        .url     = multiclaw_url,
        .method  = .POST,
        .body    = body_json,
        .headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_header },
        },
    }) catch return mer.redirect("/login?error=multiclaw+unreachable", .see_other);
    defer result.deinit(req.allocator);

    if (result.status != .ok) {
        return mer.redirect("/login?error=multiclaw+error", .see_other);
    }

    // Parse the authorization_url + state from the response.
    const OAuthInit = struct {
        authorization_url: []const u8,
        state:             []const u8,
    };
    const parsed = std.json.parseFromSlice(OAuthInit, req.allocator, result.body, .{}) catch
        return mer.redirect("/login?error=bad+response", .see_other);
    defer parsed.deinit();

    // Copy strings out of the parsed arena before it's freed.
    const auth_url    = req.allocator.dupe(u8, parsed.value.authorization_url) catch return mer.internalError("oom");
    const oauth_state = req.allocator.dupe(u8, parsed.value.state)             catch return mer.internalError("oom");
    const user_id_dup = req.allocator.dupe(u8, user_id)                        catch return mer.internalError("oom");

    // Set state + user_id cookies for CSRF protection, then redirect to provider.
    const cookies = req.allocator.alloc(mer.SetCookie, 2) catch return mer.internalError("oom");
    cookies[0] = .{ .name = "oauth_state", .value = oauth_state, .max_age = 600 };
    cookies[1] = .{ .name = "oauth_user",  .value = user_id_dup, .max_age = 600 };

    return mer.withCookies(mer.redirect(auth_url, .found), cookies);
}

// ── Styles ─────────────────────────────────────────────────────────────────

const page_css =
    \\.login-page { max-width: 440px; margin: 0 auto; padding-top: 24px; }
    \\.login-page h1 { font-family:'DM Serif Display',Georgia,serif; font-size: 28px; letter-spacing: -0.02em; margin-bottom: 8px; }
    \\.subtitle { font-size: 14px; color: var(--muted); margin-bottom: 24px; }
    \\.flash { padding: 10px 14px; border-radius: 6px; font-size: 13px; margin-bottom: 20px; }
    \\.flash.error { background: #fde8e8; color: #c0392b; border: 1px solid #f5c6cb; }
    \\.login-form { display: flex; flex-direction: column; gap: 16px; }
    \\.field { display: flex; flex-direction: column; gap: 6px; }
    \\.field label { font-size: 13px; font-weight: 600; color: var(--text); }
    \\.field input {
    \\  padding: 10px 12px; border: 1px solid var(--border);
    \\  border-radius: 6px; background: var(--bg2); color: var(--text);
    \\  font-size: 14px; outline: none; width: 100%;
    \\}
    \\.field input:focus { border-color: var(--red); }
    \\.providers { display: flex; flex-direction: column; gap: 10px; }
    \\.btn {
    \\  padding: 12px 20px; border: none; border-radius: 6px;
    \\  font-size: 14px; font-weight: 600; cursor: pointer;
    \\  transition: opacity 0.15s; text-align: left;
    \\}
    \\.btn:hover { opacity: 0.85; }
    \\.btn.google { background: var(--red); color: #fff; }
    \\.btn.github { background: #24292e; color: #fff; }
    \\.note { font-size: 12px; color: var(--muted); margin-top: 20px; line-height: 1.6; }
    \\.note a { border-bottom: 1px solid var(--border); }
;
