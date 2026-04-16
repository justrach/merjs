const std = @import("std");
const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "Documentation",
    .description = "Complete API reference for merjs — the Zig-native web framework. Covers routing, streaming SSR, data fetching, sessions, meta tags, and deployment.",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html("<h1>Documentation</h1><p>Requires the dev server for streaming.</p>");
}

pub fn renderStream(req: mer.Request, stream: *mer.StreamWriter) void {
    _ = req;

    // ── Hero ────────────────────────────────────────────────────────────
    stream.write(
        \\<div class="docs">
        \\  <h1 class="docs-title">mer<span class="red">js</span> Documentation</h1>
        \\  <p class="docs-sub">Complete API reference for the Zig-native web framework.<br>One language, two targets. Zero node_modules.</p>
    );

    // ── Table of Contents ───────────────────────────────────────────────
    stream.write(
        \\  <nav class="toc">
        \\    <h3>Contents</h3>
        \\    <ol>
        \\      <li><a href="#routing">File-Based Routing</a></li>
        \\      <li><a href="#request">Request</a></li>
        \\      <li><a href="#response">Response Helpers</a></li>
        \\      <li><a href="#streaming">Streaming SSR</a></li>
        \\      <li><a href="#fetch">fetchAll &amp; fetch</a></li>
        \\      <li><a href="#layout">Layout &amp; streamWrap</a></li>
        \\      <li><a href="#meta">Meta / SEO</a></li>
        \\      <li><a href="#sessions">Sessions</a></li>
        \\      <li><a href="#dhi">Validation (dhi)</a></li>
        \\      <li><a href="#env">Environment Variables</a></li>
        \\      <li><a href="#cli">mer CLI</a></li>
        \\      <li><a href="#deploy">Deployment</a></li>
        \\    </ol>
        \\  </nav>
    );

    // ── 1. File-Based Routing ───────────────────────────────────────────
    stream.write(
        \\  <section id="routing">
        \\    <h2>1. File-Based Routing</h2>
        \\    <p>Drop a <code>.zig</code> file in <code>app/</code> or <code>api/</code> and it becomes a route. Run <code>zig build codegen</code> to regenerate the route table.</p>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code>app/index.zig       \u2192  /
        \\app/about.zig       \u2192  /about
        \\app/blog/post.zig   \u2192  /blog/post
        \\app/users/[id].zig  \u2192  /users/:id   (dynamic)
        \\api/hello.zig       \u2192  /api/hello</code></pre></div>
        \\    <p>Every <code>app/</code> page must export:</p>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code>const mer = @import("mer");
        \\
        \\pub const meta: mer.Meta = .{
        \\    .title = "My Page",
        \\    .description = "Page description for SEO.",
        \\};
        \\
        \\pub fn render(req: mer.Request) mer.Response {
        \\    _ = req;
        \\    return mer.html("&lt;h1&gt;Hello&lt;/h1&gt;");
        \\}</code></pre></div>
        \\  </section>
    );

    // ── 2. Request ──────────────────────────────────────────────────────
    stream.write(
        \\  <section id="request">
        \\    <h2>2. Request</h2>
        \\    <p>The <code>mer.Request</code> struct provides everything about the incoming HTTP request.</p>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code>pub fn render(req: mer.Request) mer.Response {
        \\    // Route params: /users/:id
        \\    const id = req.param("id") orelse return mer.notFound();
        \\
        \\    // Query params: /search?q=zig
        \\    const q = req.queryParam("q") orelse "default";
        \\
        \\    // Cookies
        \\    const session = req.cookie("session") orelse "";
        \\
        \\    // Method, path, body
        \\    _ = req.method;       // .GET, .POST, etc.
        \\    _ = req.path;         // "/users/42"
        \\    _ = req.body;         // raw request body bytes
        \\    _ = req.allocator;    // per-request arena allocator
        \\
        \\    _ = id; _ = q; _ = session;
        \\    return mer.html("&lt;p&gt;OK&lt;/p&gt;");
        \\}</code></pre></div>
        \\  </section>
    );

    // ── 3. Response Helpers ─────────────────────────────────────────────
    stream.write(
        \\  <section id="response">
        \\    <h2>3. Response Helpers</h2>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code>// HTML response (200 OK, text/html)
        \\return mer.html("&lt;h1&gt;Hello&lt;/h1&gt;");
        \\
        \\// JSON response (200 OK, application/json)
        \\return mer.json("{\"ok\": true}");
        \\
        \\// Type-safe JSON from a struct
        \\const Data = struct { count: u32, label: []const u8 };
        \\return mer.typedJson(req.allocator, Data{ .count = 42, .label = "items" });
        \\
        \\// Plain text with custom status
        \\return mer.text(.ok, "plain text body");
        \\
        \\// Error responses
        \\return mer.notFound();
        \\return mer.internalError("something broke");
        \\return mer.badRequest("invalid input");
        \\
        \\// Redirects
        \\return mer.redirect("/login", .found);           // 302
        \\return mer.redirect("/dashboard", .see_other);   // 303 after POST
        \\
        \\// Set cookies on any response
        \\return mer.withCookies(mer.redirect("/home", .see_other), &amp;.{
        \\    .{ .name = "session", .value = token, .max_age = 86400,
        \\       .http_only = true, .secure = true, .same_site = .lax },
        \\});</code></pre></div>
        \\  </section>
    );

    // ── 4. Streaming SSR ────────────────────────────────────────────────
    stream.write(
        \\  <section id="streaming">
        \\    <h2>4. Streaming SSR</h2>
        \\    <p>Export <code>renderStream</code> to opt into shell-first streaming. The browser receives the page shell immediately while data is being fetched. Placeholders resolve as each fetch completes.</p>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code>pub fn renderStream(req: mer.Request, stream: *mer.StreamWriter) void {
        \\    _ = req;
        \\
        \\    // 1. Write the shell \u2014 sent to browser instantly
        \\    stream.write("&lt;h1&gt;Dashboard&lt;/h1&gt;");
        \\
        \\    // 2. Register a placeholder with a skeleton fallback
        \\    stream.placeholder("weather",
        \\        "&lt;div class=\"skeleton\"&gt;Loading...&lt;/div&gt;");
        \\
        \\    // 3. Fetch data (runs server-side)
        \\    const results = mer.fetchAll(req.allocator, &amp;.{
        \\        .{ .url = "https://api.example.com/weather" },
        \\    });
        \\    defer for (results) |r| if (r) |ok| ok.deinit(req.allocator);
        \\
        \\    // 4. Resolve \u2014 swaps skeleton with real content via inline script
        \\    if (results[0]) |res| {
        \\        stream.resolve("weather", res.body);
        \\    } else {
        \\        stream.resolve("weather", "&lt;p&gt;Failed to load&lt;/p&gt;");
        \\    }
        \\
        \\    stream.flush();
        \\}</code></pre></div>
        \\    <p class="note">Pages with <code>renderStream</code> must also export a <code>render</code> fallback for non-streaming contexts (e.g. prerender).</p>
        \\  </section>
    );

    // ── 5. fetchAll & fetch ─────────────────────────────────────────────
    stream.write(
        \\  <section id="fetch">
        \\    <h2>5. fetchAll &amp; fetch</h2>
        \\    <p>Make HTTP requests during server-side rendering. <code>fetchAll</code> runs requests in parallel using OS threads on native, and uses a two-phase JS bridge on Cloudflare Workers.</p>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code>// Parallel fetch \u2014 works on both dev server and Workers
        \\const results = mer.fetchAll(req.allocator, &amp;.{
        \\    .{ .url = "https://api.example.com/users" },
        \\    .{ .url = "https://api.example.com/posts" },
        \\    .{ .url = "https://api.example.com/stats", .method = .POST,
        \\       .body = "{\"range\": \"7d\"}" },
        \\});
        \\defer for (results) |r| if (r) |ok| ok.deinit(req.allocator);
        \\
        \\// Each result is ?mer.FetchResponse
        \\if (results[0]) |users_res| {
        \\    // users_res.status : std.http.Status
        \\    // users_res.body   : []u8
        \\}
        \\
        \\// Single fetch
        \\const res = try mer.fetch(req.allocator, .{
        \\    .url = "https://api.example.com/health",
        \\});
        \\defer res.deinit(req.allocator);</code></pre></div>
        \\  </section>
    );

    // ── 6. Layout & streamWrap ──────────────────────────────────────────
    stream.write(
        \\  <section id="layout">
        \\    <h2>6. Layout &amp; streamWrap</h2>
        \\    <p>Create <code>app/layout.zig</code> to wrap all pages with a shared shell. Export <code>wrap</code> for static pages and <code>streamWrap</code> for streaming pages.</p>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code>// app/layout.zig
        \\const std = @import("std");
        \\const mer = @import("mer");
        \\
        \\/// Wraps non-streaming pages: receives full body, returns full HTML.
        \\pub fn wrap(alloc: std.mem.Allocator, path: []const u8,
        \\            body: []const u8, meta: mer.Meta) []const u8 {
        \\    _ = path;
        \\    var buf: std.ArrayList(u8) = .{};
        \\    const w = buf.writer(alloc);
        \\    w.print("&lt;!DOCTYPE html&gt;&lt;html&gt;&lt;head&gt;&lt;title&gt;{s}&lt;/title&gt;&lt;/head&gt;", .{meta.title}) catch {};
        \\    w.writeAll("&lt;body&gt;") catch {};
        \\    w.writeAll(body) catch {};
        \\    w.writeAll("&lt;/body&gt;&lt;/html&gt;") catch {};
        \\    return buf.items;
        \\}
        \\
        \\/// Streaming layout: returns head + tail separately.
        \\/// Server flushes head, then streams page body, then sends tail.
        \\pub fn streamWrap(alloc: std.mem.Allocator, path: []const u8,
        \\                  meta: mer.Meta) mer.StreamParts {
        \\    _ = path;
        \\    var head_buf: std.ArrayList(u8) = .{};
        \\    const hw = head_buf.writer(alloc);
        \\    hw.print("&lt;!DOCTYPE html&gt;&lt;html&gt;&lt;head&gt;&lt;title&gt;{s}&lt;/title&gt;&lt;/head&gt;&lt;body&gt;", .{meta.title}) catch {};
        \\    return .{ .head = head_buf.items, .tail = "&lt;/body&gt;&lt;/html&gt;" };
        \\}</code></pre></div>
        \\  </section>
    );

    // ── 7. Meta / SEO ───────────────────────────────────────────────────
    stream.write(
        \\  <section id="meta">
        \\    <h2>7. Meta / SEO</h2>
        \\    <p>Export <code>pub const meta: mer.Meta</code> from any page. The layout automatically injects Open Graph, Twitter Card, and standard meta tags.</p>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code>pub const meta: mer.Meta = .{
        \\    .title = "Dashboard",
        \\    .description = "Real-time analytics dashboard.",
        \\    // Open Graph
        \\    .og_title = "merjs Dashboard",
        \\    .og_description = "Live data from Singapore APIs.",
        \\    .og_image = "https://merjs.dev/og-dashboard.png",
        \\    .og_type = "website",
        \\    // Twitter Card
        \\    .twitter_card = "summary_large_image",
        \\    .twitter_site = "@meraborern",
        \\    // Other
        \\    .canonical = "https://merjs.dev/dashboard",
        \\    .robots = "index, follow",
        \\    .extra_head = "&lt;link rel=\"stylesheet\" href=\"/custom.css\"&gt;",
        \\};</code></pre></div>
        \\  </section>
    );

    // ── 8. Sessions ─────────────────────────────────────────────────────
    stream.write(
        \\  <section id="sessions">
        \\    <h2>8. Sessions</h2>
        \\    <p>HMAC-SHA256 signed session tokens. Set <code>MULTICLAW_SESSION_SECRET</code> in your <code>.env</code> file.</p>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code>// Sign a session (e.g. after login)
        \\const token = try mer.signSession(
        \\    req.allocator, user_id, mer.SESSION_DEFAULT_TTL,  // 7 days
        \\);
        \\return mer.withCookies(mer.redirect("/dashboard", .see_other), &amp;.{
        \\    .{ .name = "session", .value = token,
        \\       .http_only = true, .secure = true, .same_site = .lax,
        \\       .max_age = mer.SESSION_DEFAULT_TTL },
        \\});
        \\
        \\// Verify a session (in a protected route)
        \\const session = mer.verifySession(
        \\    req.cookie("session") orelse "",
        \\) orelse return mer.redirect("/login", .found);
        \\// session.user_id  : []const u8 (trusted)
        \\// session.expires_at : i64</code></pre></div>
        \\  </section>
    );

    // ── 9. Validation (dhi) ─────────────────────────────────────────────
    stream.write(
        \\  <section id="dhi">
        \\    <h2>9. Validation (dhi)</h2>
        \\    <p>Pydantic-style comptime validation. Define typed models and validate at runtime.</p>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code>const UserModel = mer.dhi.Model("User", .{
        \\    .name  = mer.dhi.Str(.{ .min_length = 1, .max_length = 100 }),
        \\    .email = mer.dhi.EmailStr,
        \\    .age   = mer.dhi.Int(i32, .{ .gt = 0, .le = 150 }),
        \\});
        \\
        \\// Parse and validate
        \\const user = try UserModel.parse(.{
        \\    .name = "Alice",
        \\    .email = "alice@example.com",
        \\    .age = @as(i32, 25),
        \\});
        \\
        \\// Also: mer.parseJson(T, req) for JSON body parsing
        \\// Also: mer.formParam(req.body, "field") for form data</code></pre></div>
        \\  </section>
    );

    // ── 10. Environment Variables ────────────────────────────────────────
    stream.write(
        \\  <section id="env">
        \\    <h2>10. Environment Variables</h2>
        \\    <p>Reads from <code>.env</code> on native, from Cloudflare secrets on Workers.</p>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code>// Read an env var (returns ?[]const u8)
        \\const api_key = mer.env("API_KEY") orelse return mer.badRequest("not configured");
        \\
        \\// .env file is loaded automatically at server startup
        \\// On Workers, secrets are injected via wrangler.toml bindings</code></pre></div>
        \\  </section>
    );

    // ── 11. mer CLI ─────────────────────────────────────────────────────
    stream.write(
        \\  <section id="cli">
        \\    <h2>11. mer CLI</h2>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code>mer init my-app        # scaffold a new project
        \\mer dev                # codegen + dev server with hot reload
        \\mer dev --port 8080    # custom port
        \\mer build              # production build (ReleaseSmall + prerender)
        \\mer --version          # print version
        \\
        \\# Or use zig build directly:
        \\zig build codegen      # regenerate src/generated/routes.zig
        \\zig build serve        # start dev server on :3000
        \\zig build wasm         # compile WASM modules
        \\zig build worker       # compile for Cloudflare Workers
        \\zig build prod         # full production build</code></pre></div>
        \\  </section>
    );

    // ── 12. Deployment ──────────────────────────────────────────────────
    stream.write(
        \\  <section id="deploy">
        \\    <h2>12. Deployment</h2>
        \\    <h3>Native binary</h3>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code>zig build -Doptimize=ReleaseSmall
        \\./zig-out/bin/merjs                  # single static binary
        \\# Runs on port 3000 by default</code></pre></div>
        \\    <h3>Cloudflare Workers</h3>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code># 1. Build WASM module
        \\zig build worker
        \\
        \\# 2. Deploy with wrangler
        \\cd worker &amp;&amp; npx wrangler deploy
        \\
        \\# fetchAll works on Workers via two-phase bridge:
        \\#   Phase 1: WASM collects URLs during renderStream
        \\#   Phase 2: JS fetches them, passes results back, re-renders</code></pre></div>
        \\    <h3>Static / SSG</h3>
        \\    <div class="code-block"><button class="copy-btn" onclick="copyCode(this)">copy</button><pre><code># Pages with `pub const prerender = true` are pre-rendered to dist/
        \\zig build prerender
        \\# Serve dist/ from any static host (Netlify, Vercel, S3, etc.)</code></pre></div>
        \\  </section>
    );

    // ── Copy-to-clipboard script ────────────────────────────────────────
    stream.write(
        \\  <script>
        \\  function copyCode(btn){
        \\    var code=btn.parentElement.querySelector("code");
        \\    var text=code.innerText||code.textContent;
        \\    navigator.clipboard.writeText(text).then(function(){
        \\      btn.textContent="\u2713";
        \\      setTimeout(function(){btn.textContent="copy"},1500);
        \\    });
        \\  }
        \\  </script>
        \\</div>
    );

    stream.flush();
}

const page_css =
    \\.docs { max-width:720px; margin:0 auto; }
    \\.docs-title { font-family:"DM Serif Display",Georgia,serif; font-size:clamp(28px,4vw,40px); letter-spacing:-0.02em; margin-bottom:8px; }
    \\.docs-title .red { color:var(--red); }
    \\.docs-sub { color:var(--muted); font-size:15px; line-height:1.6; margin-bottom:32px; }
    \\.toc { background:var(--bg2); border-radius:10px; padding:20px 28px; margin-bottom:36px; }
    \\.toc h3 { font-family:"DM Serif Display",Georgia,serif; font-size:15px; margin-bottom:10px; }
    \\.toc ol { padding-left:20px; columns:2; column-gap:24px; }
    \\.toc li { font-size:13px; color:var(--muted); margin-bottom:4px; break-inside:avoid; }
    \\.toc a { color:var(--text); text-decoration:none; border-bottom:1px solid var(--border); transition:border-color 0.15s; }
    \\.toc a:hover { border-color:var(--red); color:var(--red); }
    \\section { margin-bottom:40px; }
    \\section h2 { font-family:"DM Serif Display",Georgia,serif; font-size:22px; letter-spacing:-0.01em; margin-bottom:12px; padding-top:20px; border-top:1px solid var(--border); }
    \\section h3 { font-family:"DM Serif Display",Georgia,serif; font-size:16px; margin:20px 0 8px; }
    \\section p { font-size:14px; color:var(--muted); line-height:1.7; margin-bottom:12px; }
    \\section p code, .note code { font-family:"SF Mono","Fira Code",monospace; font-size:12px; background:var(--bg3); padding:1px 5px; border-radius:3px; }
    \\.code-block { position:relative; background:var(--bg2); border:1px solid var(--border); border-radius:8px; margin-bottom:16px; overflow:hidden; }
    \\.code-block pre { margin:0; padding:16px 18px; overflow-x:auto; }
    \\.code-block code { font-family:"SF Mono","Fira Code",monospace; font-size:12.5px; line-height:1.65; color:var(--text); display:block; white-space:pre; }
    \\.copy-btn { position:absolute; top:8px; right:8px; background:var(--bg3); border:1px solid var(--border); border-radius:4px; padding:3px 10px; font-size:11px; color:var(--muted); cursor:pointer; transition:color 0.15s,border-color 0.15s; z-index:1; }
    \\.copy-btn:hover { color:var(--text); border-color:var(--text); }
    \\.note { font-size:13px!important; color:var(--muted); font-style:italic; padding:10px 14px; background:var(--bg2); border-left:3px solid var(--red); border-radius:0 6px 6px 0; margin-top:8px; }
    \\@media(max-width:600px) { .toc ol { columns:1; } }
;
