// connected.zig — shown after a successful OAuth connection.
//
// multiclaw redirects here after exchanging the OAuth code for tokens.
// The user_id is read from the oauth_user cookie set during login.

const mer = @import("mer");
const h   = mer.h;

pub const meta: mer.Meta = .{
    .title       = "Connected — multiclaw",
    .description = "Your account has been connected successfully.",
    .extra_head  = "<style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    const user_id  = req.cookie("oauth_user")  orelse "unknown";
    const provider = req.cookie("oauth_state"); // we read state as proof of initiation

    const provider_label: []const u8 = if (provider != null) "your account" else "your account";
    _ = provider_label;

    const node = h.div(.{ .class = "connected-page" }, .{
        h.div(.{ .class = "icon" }, .{h.raw("&#x2705;")}),
        h.h1(.{}, "Connected!"),
        h.p(.{ .class = "msg" }, .{
            h.strong(.{}, user_id),
            h.text(" — your account has been linked and tokens stored securely via multiclaw."),
        }),
        h.div(.{ .class = "actions" }, .{
            h.a(.{ .href = "/dashboard", .class = "btn-primary" }, "Go to Dashboard"),
            h.a(.{ .href = "/login",     .class = "btn-ghost" }, "Connect another"),
        }),
        h.details(.{ .class = "tech-note" }, .{
            h.summary(.{}, "What just happened?"),
            h.p(.{}, .{
                h.text("Your OAuth tokens were exchanged by "),
                h.a(.{ .href = "https://github.com/justrach/multiclaw" }, "multiclaw"),
                h.text(", encrypted with XChaCha20-Poly1305 using a key derived from your app + user ID, and stored on R2. The frontend never touched the tokens."),
            }),
        }),
    });

    // Clear the oauth_state and oauth_user cookies.
    const clear_cookies = req.allocator.alloc(mer.SetCookie, 2) catch
        return mer.render(req.allocator, node);
    clear_cookies[0] = .{ .name = "oauth_state", .value = "", .max_age = 0 };
    clear_cookies[1] = .{ .name = "oauth_user",  .value = "", .max_age = 0 };

    return mer.withCookies(mer.render(req.allocator, node), clear_cookies);
}

const page_css =
    \\.connected-page { max-width: 480px; margin: 0 auto; padding-top: 24px; text-align: center; }
    \\.icon { font-size: 48px; margin-bottom: 16px; }
    \\.connected-page h1 { font-family:'DM Serif Display',Georgia,serif; font-size:32px; letter-spacing:-0.02em; margin-bottom:12px; }
    \\.msg { font-size:15px; color:var(--muted); margin-bottom:32px; line-height:1.7; }
    \\.msg strong { color:var(--text); }
    \\.actions { display:flex; gap:12px; justify-content:center; flex-wrap:wrap; margin-bottom:32px; }
    \\.btn-primary { display:inline-flex; align-items:center; background:var(--red); color:#fff; font-size:14px; font-weight:600; padding:11px 24px; border-radius:6px; transition:opacity 0.15s; }
    \\.btn-primary:hover { opacity:0.88; }
    \\.btn-ghost { display:inline-flex; align-items:center; color:var(--muted); font-size:14px; border:1px solid var(--border); padding:11px 24px; border-radius:6px; transition:color 0.15s,border-color 0.15s; }
    \\.btn-ghost:hover { color:var(--text); border-color:var(--text); }
    \\.tech-note { margin-top:24px; text-align:left; background:var(--bg2); border:1px solid var(--border); border-radius:8px; padding:14px 16px; font-size:13px; }
    \\.tech-note summary { cursor:pointer; font-weight:600; color:var(--muted); user-select:none; }
    \\.tech-note p { margin-top:10px; color:var(--muted); line-height:1.7; }
    \\.tech-note a { border-bottom:1px solid var(--border); }
;
