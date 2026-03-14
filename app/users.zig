const std = @import("std");
const mer = @import("mer");

const UserModel = mer.dhi.Model("User", .{
    .name = mer.dhi.Str(.{ .min_length = 1, .max_length = 100 }),
    .email = mer.dhi.EmailStr,
    .age = mer.dhi.Int(i32, .{ .gt = 0, .le = 150 }),
    .score = mer.dhi.Float(f64, .{ .ge = 0.0, .le = 100.0 }),
});

pub const meta: mer.Meta = .{
    .title = "Users",
    .description = "Type-safe user profiles validated with dhi. Comptime constraints, zero runtime overhead.",
    .og_title = "Users \u{2014} merjs",
    .og_description = "dhi-validated user profiles with comptime type safety.",
    .twitter_card = "summary",
    .twitter_title = "Users \u{2014} merjs",
    .twitter_description = "Type-safe user profiles validated with dhi.",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

const P0 =
    \\<h1>Users</h1>
    \\<div class="card">
    \\  <div class="card-label"><span class="dot-red"></span> Server-side rendered &middot; dhi validated</div>
    \\  <div class="profile">
    \\    <div class="avatar">
;

const P1 =
    \\    </div>
    \\    <div>
    \\      <div class="profile-name">
;

const P2 =
    \\        <span class="status">
;

const P3 =
    \\        </span>
    \\      </div>
    \\      <div class="profile-email">
;

const P4 =
    \\      </div>
    \\    </div>
    \\  </div>
    \\  <div class="stats">
    \\    <div class="stat">
    \\      <div class="stat-label">age</div>
    \\      <div class="stat-value">
;

const P5 =
    \\      </div>
    \\    </div>
    \\    <div class="stat">
    \\      <div class="stat-label">score</div>
    \\      <div class="stat-value red">
;

const P6 =
    \\      </div>
    \\    </div>
    \\    <div class="stat">
    \\      <div class="stat-label">model</div>
    \\      <div class="stat-value" style="font-size:12px">
;

const P7 =
    \\      </div>
    \\    </div>
    \\  </div>
    \\</div>
    \\<!-- dhi schema -->
    \\<div class="card">
    \\  <div class="card-label"><span class="dot-red"></span> dhi schema &middot; compile-time validation</div>
    \\  <pre><span class="k">const</span> UserModel = <span class="n">mer.dhi.Model</span>(<span class="s">"User"</span>, .{
    \\  .name  = <span class="n">dhi.Str</span>(.{ .min_length=<span class="v">1</span>, .max_length=<span class="v">100</span> }),
    \\  .email = <span class="n">dhi.EmailStr</span>,
    \\  .age   = <span class="n">dhi.Int</span>(i32, .{ .gt=<span class="v">0</span>, .le=<span class="v">150</span> }),
    \\  .score = <span class="n">dhi.Float</span>(f64, .{ .ge=<span class="v">0.0</span>, .le=<span class="v">100.0</span> }),
    \\});</pre>
    \\</div>
    \\<!-- live API -->
    \\<div class="card">
    \\  <div class="card-label"><span class="dot-pulse"></span> Live &mdash; /api/users</div>
    \\  <pre id="api-out">fetching&hellip;</pre>
    \\</div>
    \\<p class="footer-note">
    \\  Validated with <a href="https://github.com/justrach/dhi">dhi</a>
    \\  at compile time &middot; zero runtime schema overhead
    \\</p>
    \\<script>
    \\  fetch('/api/users')
    \\    .then(r => r.json())
    \\    .then(d => { document.getElementById('api-out').textContent = JSON.stringify(d, null, 2); })
    \\    .catch(e => { document.getElementById('api-out').textContent = 'error: ' + e; });
    \\</script>
;

fn initials(name: []const u8, buf: *[2]u8) []const u8 {
    var count: usize = 0;
    var next = true;
    for (name) |c| {
        if (c == ' ') {
            next = true;
            continue;
        }
        if (next and count < 2) {
            buf[count] = if (c >= 'a' and c <= 'z') c - 32 else c;
            count += 1;
            next = false;
        }
    }
    return buf[0..count];
}

pub fn render(req: mer.Request) mer.Response {
    const user = UserModel.parse(.{
        .name = "Alice Johnson",
        .email = "alice@example.com",
        .age = @as(i32, 28),
        .score = @as(f64, 95.5),
    }) catch return mer.internalError("dhi validation failed");

    var ini_buf: [2]u8 = undefined;
    const ini = initials(user.name, &ini_buf);

    const page = std.fmt.allocPrint(
        req.allocator,
        "{s}{s}{s}{s}{s}{s}{s}{s}{s}{d}{s}{d:.1}{s}{s}{s}",
        .{
            P0, ini,
            P1, user.name,
            P2, @as([]const u8, "active"),
            P3, user.email,
            P4, user.age,
            P5, user.score,
            P6, UserModel.Name,
            P7,
        },
    ) catch return mer.internalError("alloc failed");

    return mer.html(page);
}

const page_css =
    \\h1 { font-family:'DM Serif Display',Georgia,serif; font-size:32px; letter-spacing:-0.02em; margin-bottom:32px; }
    \\.card { background:var(--bg2); border:1px solid var(--border); border-radius:12px; padding:24px; margin-bottom:16px; }
    \\.card-label { display:flex; align-items:center; gap:8px; font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:0.08em; margin-bottom:20px; }
    \\.dot-red { width:7px; height:7px; border-radius:50%; background:var(--red); flex-shrink:0; }
    \\.dot-pulse { width:7px; height:7px; border-radius:50%; background:var(--red); flex-shrink:0; animation:pulse 2s infinite; }
    \\@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.35} }
    \\.profile { display:flex; align-items:center; gap:16px; margin-bottom:20px; }
    \\.avatar { width:52px; height:52px; border-radius:10px; background:var(--red); color:var(--bg); display:flex; align-items:center; justify-content:center; font-size:18px; font-weight:600; flex-shrink:0; user-select:none; }
    \\.profile-name { font-size:18px; font-weight:600; letter-spacing:-0.01em; }
    \\.status { display:inline-flex; font-size:11px; font-weight:600; letter-spacing:0.06em; text-transform:uppercase; background:rgba(232,37,31,0.1); color:var(--red); border:1px solid rgba(232,37,31,0.25); border-radius:100px; padding:3px 10px; margin-left:10px; }
    \\.profile-email { font-size:14px; color:var(--muted); margin-top:3px; }
    \\.stats { display:grid; grid-template-columns:repeat(3,1fr); gap:10px; }
    \\.stat { background:var(--bg3); border-radius:8px; padding:14px; }
    \\.stat-label { font-size:11px; color:var(--muted); margin-bottom:5px; }
    \\.stat-value { font-family:'SF Mono','Fira Code',monospace; font-size:15px; color:var(--text); }
    \\.stat-value.red { color:var(--red); }
    \\pre { background:var(--bg3); border:1px solid var(--border); border-radius:8px; padding:18px; font-family:'SF Mono','Fira Code',monospace; font-size:13px; line-height:1.7; overflow-x:auto; color:var(--text); }
    \\pre .k { color:var(--red); }
    \\pre .s { color:#7a6b5a; }
    \\pre .n { color:#5a5060; }
    \\pre .v { color:#252530; font-weight:500; }
    \\#api-out { color:var(--muted); }
    \\.footer-note { font-size:12px; color:var(--muted); text-align:center; margin-top:16px; }
    \\.footer-note a { border-bottom:1px solid var(--border); }
    \\.footer-note a:hover { color:var(--text); }
;
