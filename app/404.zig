const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "404",
    .description = "Page not found",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html(html);
}

const html =
    \\<div class="not-found">
    \\  <div class="nf-code">404</div>
    \\  <div class="nf-divider"></div>
    \\  <h1>Page not found</h1>
    \\  <p class="nf-sub">The data you're looking for isn't here.</p>
    \\  <div class="nf-actions">
    \\    <a href="/" class="nf-btn primary">Dashboard</a>
    \\    <a href="/explore" class="nf-btn">Explore Datasets</a>
    \\  </div>
    \\</div>
;

const page_css =
    \\.not-found { text-align:center; padding:60px 0; }
    \\.nf-code { font-family:'DM Serif Display',Georgia,serif; font-size:96px; color:var(--red); letter-spacing:-0.04em; }
    \\.nf-divider { width:40px; height:3px; background:var(--red); margin:16px auto; border-radius:2px; }
    \\.not-found h1 { font-family:'DM Serif Display',Georgia,serif; font-size:24px; margin-bottom:8px; }
    \\.nf-sub { font-size:14px; color:var(--muted); margin-bottom:32px; }
    \\.nf-actions { display:flex; gap:10px; justify-content:center; }
    \\.nf-btn { padding:10px 24px; border-radius:8px; font-size:13px; font-weight:600; border:1px solid var(--border); transition:all 0.15s; }
    \\.nf-btn.primary { background:var(--red); color:#fff; border-color:var(--red); }
    \\.nf-btn.primary:hover { opacity:0.9; }
    \\.nf-btn:hover { background:var(--bg3); }
;
