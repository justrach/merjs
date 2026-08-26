const std = @import("std");
const mer = @import("mer");

/// Incremental Static Regeneration: cache this page's HTML and serve it with a
/// stale-while-revalidate policy. Within 5 seconds every request gets the exact
/// same cached HTML (0ms render); after 5 seconds the next request is served the
/// stale copy instantly while the framework re-renders in the background, so the
/// request after that sees fresh content.
pub const revalidate: u32 = 5;

pub const meta: mer.Meta = .{
    .title = "ISR Demo",
    .description = "Incremental Static Regeneration in merjs — cached HTML served with a 5s stale-while-revalidate policy.",
    .og_title = "ISR Demo \u{2014} merjs",
    .og_description = "Cached HTML with a 5s stale-while-revalidate policy, rendered by a native Zig server.",
    .robots = "noindex, nofollow",
};

/// How many times render() has actually executed. Because ISR serves cached
/// HTML, this only ticks on the first request and once per background
/// revalidation — NOT on every request. Watching it stay flat within the TTL
/// (and bump after it) is the clearest signal the cache is working.
var render_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// std.time.timestamp() still exists, but nanoTimestamp() was removed in 0.17,
/// so we read the wall clock directly for a stable per-render second stamp.
fn unixSeconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

pub fn render(req: mer.Request) mer.Response {
    const n = render_count.fetchAdd(1, .monotonic) + 1;
    const secs = unixSeconds();

    const body = std.fmt.allocPrint(req.allocator, page_template, .{ n, secs, secs }) catch
        return mer.internalError("isr-demo render failed");
    return mer.html(body);
}

const page_template =
    \\<style>
    \\  .isr {{ max-width:640px; }}
    \\  .isr h1 {{ font-family:'DM Serif Display',Georgia,serif; font-size:36px; letter-spacing:-0.02em; margin-bottom:8px; }}
    \\  .isr .sub {{ color:var(--muted); font-size:15px; margin-bottom:32px; }}
    \\  .isr .card {{ background:var(--bg2); border:1px solid var(--border); border-radius:12px; padding:28px; margin-bottom:24px; }}
    \\  .isr .metric {{ display:flex; align-items:baseline; justify-content:space-between; padding:14px 0; border-bottom:1px solid var(--border); }}
    \\  .isr .metric:last-child {{ border-bottom:none; }}
    \\  .isr .label {{ font-size:13px; color:var(--muted); }}
    \\  .isr .value {{ font-family:'SF Mono','Fira Code',monospace; font-size:26px; color:var(--red); font-weight:600; }}
    \\  .isr .hint {{ font-size:13px; color:var(--muted); line-height:1.7; }}
    \\  .isr code {{ font-family:'SF Mono','Fira Code',monospace; font-size:12px; background:var(--bg3); border-radius:4px; padding:1px 6px; }}
    \\</style>
    \\<div class="isr">
    \\  <h1>Incremental Static Regeneration</h1>
    \\  <p class="sub">This page declares <code>pub const revalidate = 5;</code> — its HTML is cached and refreshed with a stale-while-revalidate policy.</p>
    \\  <div class="card">
    \\    <div class="metric">
    \\      <span class="label">render() invocations (server-side)</span>
    \\      <span class="value">#{d}</span>
    \\    </div>
    \\    <div class="metric">
    \\      <span class="label">rendered at (unix seconds)</span>
    \\      <span class="value">{d}</span>
    \\    </div>
    \\  </div>
    \\  <p class="hint">
    \\    Reload rapidly: both numbers stay <strong>frozen</strong> for 5 seconds because the
    \\    cached HTML is served without re-rendering. After 5 seconds, the first reload still
    \\    shows the stale values (served instantly) while a background re-render runs — the
    \\    reload after that shows the bumped counter and a newer timestamp.
    \\    <br><br>
    \\    Cache-generation timestamp: <code>{d}</code>
    \\  </p>
    \\</div>
;
