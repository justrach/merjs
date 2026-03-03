const std = @import("std");
const mer = @import("mer");

const UserModel = mer.dhi.Model("User", .{
    .name  = mer.dhi.Str(.{ .min_length = 1, .max_length = 100 }),
    .email = mer.dhi.EmailStr,
    .age   = mer.dhi.Int(i32, .{ .gt = 0, .le = 150 }),
    .score = mer.dhi.Float(f64, .{ .ge = 0.0, .le = 100.0 }),
});

// HTML segments — dynamic slots: initials · name · status · email · age · score · model
const P0 =
    \\<!DOCTYPE html><html lang="en"><head>
    \\  <meta charset="UTF-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <title>Users — merjs</title>
    \\  <link rel="preconnect" href="https://fonts.googleapis.com">
    \\  <link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet">
    \\  <style>
    \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    \\    :root { --bg:#f0ebe3; --bg2:#e8e2d9; --bg3:#ddd5cc; --text:#252530; --muted:#8a7f78; --border:#d5cdc4; --red:#e8251f; }
    \\    body { background:var(--bg); color:var(--text); font-family:'DM Sans',system-ui,sans-serif; min-height:100vh; }
    \\    a { color:inherit; text-decoration:none; }
    \\    .page { max-width:680px; margin:0 auto; padding:48px 32px 96px; }
    \\    .header { display:flex; align-items:center; justify-content:space-between; margin-bottom:48px; }
    \\    .wordmark { font-family:'DM Serif Display',Georgia,serif; font-size:18px; letter-spacing:-0.02em; }
    \\    .wordmark span { color:var(--red); }
    \\    .back { font-size:13px; color:var(--muted); transition:color 0.15s; }
    \\    .back:hover { color:var(--text); }
    \\    h1 { font-family:'DM Serif Display',Georgia,serif; font-size:32px; letter-spacing:-0.02em; margin-bottom:32px; }
    \\    .card { background:var(--bg2); border:1px solid var(--border); border-radius:12px; padding:24px; margin-bottom:16px; }
    \\    .card-label { display:flex; align-items:center; gap:8px; font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:0.08em; margin-bottom:20px; }
    \\    .dot-red { width:7px; height:7px; border-radius:50%; background:var(--red); flex-shrink:0; }
    \\    .dot-pulse { width:7px; height:7px; border-radius:50%; background:var(--red); flex-shrink:0; animation:pulse 2s infinite; }
    \\    @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.35} }
    \\    .profile { display:flex; align-items:center; gap:16px; margin-bottom:20px; }
    \\    .avatar { width:52px; height:52px; border-radius:10px; background:var(--red); color:var(--bg); display:flex; align-items:center; justify-content:center; font-size:18px; font-weight:600; flex-shrink:0; user-select:none; }
    \\    .profile-name { font-size:18px; font-weight:600; letter-spacing:-0.01em; }
    \\    .status { display:inline-flex; font-size:11px; font-weight:600; letter-spacing:0.06em; text-transform:uppercase; background:rgba(232,37,31,0.1); color:var(--red); border:1px solid rgba(232,37,31,0.25); border-radius:100px; padding:3px 10px; margin-left:10px; }
    \\    .profile-email { font-size:14px; color:var(--muted); margin-top:3px; }
    \\    .stats { display:grid; grid-template-columns:repeat(3,1fr); gap:10px; }
    \\    .stat { background:var(--bg3); border-radius:8px; padding:14px; }
    \\    .stat-label { font-size:11px; color:var(--muted); margin-bottom:5px; }
    \\    .stat-value { font-family:'SF Mono','Fira Code',monospace; font-size:15px; color:var(--text); }
    \\    .stat-value.red { color:var(--red); }
    \\    pre { background:var(--bg3); border:1px solid var(--border); border-radius:8px; padding:18px; font-family:'SF Mono','Fira Code',monospace; font-size:13px; line-height:1.7; overflow-x:auto; color:var(--text); }
    \\    pre .k { color:var(--red); }
    \\    pre .s { color:#7a6b5a; }
    \\    pre .n { color:#5a5060; }
    \\    pre .v { color:#252530; font-weight:500; }
    \\    #api-out { color:var(--muted); }
    \\    .footer-note { font-size:12px; color:var(--muted); text-align:center; margin-top:16px; }
    \\    .footer-note a { border-bottom:1px solid var(--border); }
    \\    .footer-note a:hover { color:var(--text); }
    \\  </style>
    \\</head>
    \\<body>
    \\<div class="page">
    \\  <header class="header">
    \\    <div class="wordmark">mer<span>js</span></div>
    \\    <a href="/" class="back">← home</a>
    \\  </header>
    \\  <h1>Users</h1>
    \\  <div class="card">
    \\    <div class="card-label"><span class="dot-red"></span> Server-side rendered &middot; dhi validated</div>
    \\    <div class="profile">
    \\      <div class="avatar">
; // initials

const P1 =
    \\      </div>
    \\      <div>
    \\        <div class="profile-name">
; // name

const P2 =
    \\          <span class="status">
; // status

const P3 =
    \\          </span>
    \\        </div>
    \\        <div class="profile-email">
; // email

const P4 =
    \\        </div>
    \\      </div>
    \\    </div>
    \\    <div class="stats">
    \\      <div class="stat">
    \\        <div class="stat-label">age</div>
    \\        <div class="stat-value">
; // age

const P5 =
    \\        </div>
    \\      </div>
    \\      <div class="stat">
    \\        <div class="stat-label">score</div>
    \\        <div class="stat-value red">
; // score

const P6 =
    \\        </div>
    \\      </div>
    \\      <div class="stat">
    \\        <div class="stat-label">model</div>
    \\        <div class="stat-value" style="font-size:12px">
; // model name

const P7 =
    \\        </div>
    \\      </div>
    \\    </div>
    \\  </div>
    \\  <!-- dhi schema -->
    \\  <div class="card">
    \\    <div class="card-label"><span class="dot-red"></span> dhi schema &middot; compile-time validation</div>
    \\    <pre><span class="k">const</span> UserModel = <span class="n">mer.dhi.Model</span>(<span class="s">"User"</span>, .{
    \\    .name  = <span class="n">dhi.Str</span>(.{ .min_length=<span class="v">1</span>, .max_length=<span class="v">100</span> }),
    \\    .email = <span class="n">dhi.EmailStr</span>,
    \\    .age   = <span class="n">dhi.Int</span>(i32, .{ .gt=<span class="v">0</span>, .le=<span class="v">150</span> }),
    \\    .score = <span class="n">dhi.Float</span>(f64, .{ .ge=<span class="v">0.0</span>, .le=<span class="v">100.0</span> }),
    \\});</pre>
    \\  </div>
    \\  <!-- live API -->
    \\  <div class="card">
    \\    <div class="card-label"><span class="dot-pulse"></span> Live &mdash; /api/users</div>
    \\    <pre id="api-out">fetching…</pre>
    \\  </div>
    \\  <p class="footer-note">
    \\    Validated with <a href="https://github.com/justrach/dhi">dhi</a>
    \\    at compile time &middot; zero runtime schema overhead
    \\  </p>
    \\</div>
    \\<script>
    \\  fetch('/api/users')
    \\    .then(r => r.json())
    \\    .then(d => { document.getElementById('api-out').textContent = JSON.stringify(d, null, 2); })
    \\    .catch(e => { document.getElementById('api-out').textContent = 'error: ' + e; });
    \\</script>
    \\</body></html>
;

fn initials(name: []const u8, buf: *[2]u8) []const u8 {
    var count: usize = 0;
    var next = true;
    for (name) |c| {
        if (c == ' ') { next = true; continue; }
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
        .name  = "Alice Johnson",
        .email = "alice@example.com",
        .age   = @as(i32, 28),
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
