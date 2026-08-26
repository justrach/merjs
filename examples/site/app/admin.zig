const mer = @import("mer");
const h = mer.h;

pub const meta: mer.Meta = .{
    .title = "Admin",
    .description = "Protected admin page — guarded by mer.requireSession. Without a `session` cookie you are redirected to /login.",
    .robots = "noindex, nofollow",
};

// Per-route guard (#23). Runs before render(): redirects to /login (303) unless
// a `session` cookie is present. Wire your own guard the same way:
//   pub const middleware = myGuardFn;   // *const fn (mer.Request) ?mer.Response
pub const middleware = mer.requireSession;

const page_node = page();
comptime {
    mer.lint.check(page_node);
}

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, page_node);
}

fn page() h.Node {
    return h.div(.{ .class = "wrap", .style = "max-width:640px;margin:0 auto;padding:48px 24px" }, .{
        h.a(.{ .href = "/", .class = "wordmark" }, .{h.raw("mer<span>js</span>")}),
        h.h1(.{ .style = "margin-top:24px" }, "Admin"),
        h.p(.{ .class = "sub" }, "You reached a protected route, so a `session` cookie was present."),
        h.p(.{ .class = "sub" }, .{
            h.raw("This page exports "),
            h.code(.{}, "pub const middleware = mer.requireSession;"),
            h.raw(" — remove the cookie and you'll be redirected to /login."),
        }),
        h.a(.{ .href = "/", .class = "back" }, .{h.raw("&larr; home")}),
    });
}
