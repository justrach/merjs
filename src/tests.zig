//! Cross-module core API tests. This file is a dedicated `zig build test` root
//! so public API drift cannot silently leave the integration suite uncompiled.

const std = @import("std");
const mer = @import("mer");

test "core API: HTML builder renders nested and void elements" {
    var storage = mer.h.RenderStorage.init(std.testing.allocator);
    storage.activate();
    defer storage.deinit();

    const node = mer.h.div(.{ .class = "card" }, .{
        mer.h.h1(.{}, "Title"),
        mer.h.p(.{}, "Paragraph"),
        mer.h.input(.{ .type = "text" }),
    });
    const response = mer.render(std.testing.allocator, node);
    defer response.deinit();

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqual(mer.ContentType.html, response.content_type);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "<div class=\"card\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "<h1>Title</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "<input type=\"text\">") != null);
}

test "core API: response helpers expose status type and body" {
    const html_response = mer.html("<p>Hello</p>");
    try std.testing.expectEqual(std.http.Status.ok, html_response.status);
    try std.testing.expectEqual(mer.ContentType.html, html_response.content_type);
    try std.testing.expectEqualStrings("<p>Hello</p>", html_response.body);

    const redirect = mer.redirect("/new-path", .see_other);
    try std.testing.expectEqual(std.http.Status.see_other, redirect.status);
    try std.testing.expectEqual(mer.ContentType.redirect, redirect.content_type);
    try std.testing.expectEqualStrings("/new-path", redirect.body);

    try std.testing.expectEqual(std.http.Status.not_found, mer.notFound().status);
    try std.testing.expectEqual(std.http.Status.bad_request, mer.badRequest("bad").status);
    try std.testing.expectEqual(std.http.Status.internal_server_error, mer.internalError("failed").status);
}

test "core API: request query form and cookie parsing" {
    var req = mer.Request.init(std.testing.allocator, .POST, "/submit");
    req.query_string = "page=2&filter=active";
    req.body = "name=alice&empty=";
    req.cookies_raw = "session=abc123; theme=dark";

    try std.testing.expectEqualStrings("2", req.queryParam("page").?);
    try std.testing.expectEqualStrings("alice", mer.formParam(req.body, "name").?);
    try std.testing.expectEqualStrings("", mer.formParam(req.body, "empty").?);
    try std.testing.expectEqualStrings("abc123", req.cookie("session").?);
    try std.testing.expect(req.queryParam("missing") == null);
}

fn dummyRender(_: mer.Request) mer.Response {
    return mer.html("ok");
}

test "core API: router exact dynamic and missing routes" {
    const routes = [_]mer.Route{
        .{ .path = "/", .render = dummyRender },
        .{ .path = "/users/:id", .render = dummyRender },
    };
    var router = mer.Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    try std.testing.expectEqualStrings("/", router.findRoute("/").?.path);
    try std.testing.expectEqualStrings("/users/:id", router.findRoute("/users/42/").?.path);
    try std.testing.expect(router.findRoute("/missing/path") == null);
}

test "core API: typedJson returns caller-owned serialized body" {
    const Data = struct { name: []const u8, count: i32 };
    const response = mer.typedJson(std.testing.allocator, Data{ .name = "test", .count = 42 });
    defer response.deinit();

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqual(mer.ContentType.json, response.content_type);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"name\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"count\":42") != null);
}

test "core API: environment lifecycle owns values and resets them" {
    mer.resetEnv();
    defer mer.resetEnv();

    var value = [_]u8{ 'o', 'w', 'n', 'e', 'd' };
    try mer.putEnv("MERJS_PUBLIC_API_LIFECYCLE_TEST", &value);
    @memset(&value, 'x');
    try std.testing.expectEqualStrings("owned", mer.env("MERJS_PUBLIC_API_LIFECYCLE_TEST").?);

    mer.deinitDotenv();
    mer.resetEnv();
    try std.testing.expect(mer.env("MERJS_PUBLIC_API_LIFECYCLE_TEST") == null);
    _ = mer.loadDotenv;
    _ = mer.loadDotenvStatus;
}

test "core API: v0.2.5 mercss declarations remain source compatible" {
    inline for (.{
        "DesignSystem",
        "Button",
        "Card",
        "Alert",
        "getDemoHtml",
        "getAllCss",
        "ResponsiveContainer",
        "InteractiveButton",
        "ResponsiveInteractiveButton",
        "exampleUsage",
    }) |name| {
        try std.testing.expect(@hasDecl(mer.mercss, name));
        try std.testing.expect(@hasDecl(mer.mercss_compat, name));
    }
    try std.testing.expectEqualStrings("#3b82f6", mer.mercss.DesignSystem.colors.primary);
}

test "core API: shared exports retain their public type identity" {
    try std.testing.expect(mer.RenderFn == *const fn (mer.Request) mer.Response);
    try std.testing.expect(mer.Route == @TypeOf(mer.Route{
        .path = "/",
        .render = dummyRender,
    }));
    try std.testing.expect(mer.h.Node == @TypeOf(mer.h.raw("identity")));
}

fn runtimeNestedNode(title: []const u8) mer.h.Node {
    return mer.h.div(.{}, .{
        mer.h.h1(.{}, title),
        mer.h.div(.{}, &.{mer.h.span(.{}, "nested")}),
    });
}

test "core API: standalone runtime strings and tuples own their children" {
    try std.testing.expect(!mer.h.hasRenderAllocator());
    mer.h.resetStandaloneFallback();
    defer mer.h.resetStandaloneFallback();

    var runtime_text = [_]u8{ 'r', 'u', 'n', 't', 'i', 'm', 'e' };
    const string_node = mer.h.p(.{}, runtime_text[0..]);
    defer string_node.deinit();
    const string_body = try mer.h.render(std.testing.allocator, string_node);
    defer std.testing.allocator.free(string_body);
    try std.testing.expectEqualStrings("<p>runtime</p>", string_body);

    const tuple_node = mer.h.div(.{}, .{
        mer.h.span(.{}, runtime_text[0..]),
        mer.h.strong(.{}, " tuple"),
    });
    defer tuple_node.deinit();
    const tuple_body = try mer.h.render(std.testing.allocator, tuple_node);
    defer std.testing.allocator.free(tuple_body);
    try std.testing.expectEqualStrings(
        "<div><span>runtime</span><strong> tuple</strong></div>",
        tuple_body,
    );
}

test "core API: standalone Node copies can both be deinitialized harmlessly" {
    try std.testing.expect(!mer.h.hasRenderAllocator());
    mer.h.resetStandaloneFallback();
    defer mer.h.resetStandaloneFallback();

    const node = mer.h.div(.{}, .{mer.h.span(.{}, "copy")});
    const copy = node;
    node.deinit();
    copy.deinit();

    const body = try mer.h.render(std.testing.allocator, copy);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("<div><span>copy</span></div>", body);
}

test "core API: later standalone nodes do not invalidate earlier trees" {
    try std.testing.expect(!mer.h.hasRenderAllocator());
    mer.h.resetStandaloneFallback();
    defer mer.h.resetStandaloneFallback();

    const first = mer.h.p(.{}, "first");
    for (0..64) |_| {
        const node = mer.h.p(.{}, "later");
        node.deinit();
    }
    const body = try mer.h.render(std.testing.allocator, first);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("<p>first</p>", body);
}

test "core API: standalone nested runtime children survive constructor frames" {
    try std.testing.expect(!mer.h.hasRenderAllocator());
    mer.h.resetStandaloneFallback();
    defer mer.h.resetStandaloneFallback();

    const node = runtimeNestedNode("standalone");
    defer node.deinit();

    var clobber: [4096]u8 = undefined;
    @memset(&clobber, 0xaa);
    std.mem.doNotOptimizeAway(&clobber);

    const body = try mer.h.render(std.testing.allocator, node);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "<div><h1>standalone</h1><div><span>nested</span></div></div>",
        body,
    );
}

test "core API: copied runtime nodes render through separate roots" {
    var storage = mer.h.RenderStorage.init(std.testing.allocator);
    storage.activate();
    defer storage.deinit();

    const child = mer.h.div(.{}, .{mer.h.span(.{}, "shared")});
    const first = mer.render(std.testing.allocator, mer.h.section(.{}, .{child}));
    defer first.deinit();
    const copy = child;
    const second = mer.render(std.testing.allocator, mer.h.article(.{}, .{copy}));
    defer second.deinit();

    try std.testing.expectEqualStrings("<section><div><span>shared</span></div></section>", first.body);
    try std.testing.expectEqualStrings("<article><div><span>shared</span></div></article>", second.body);
}

test "core API: runtime nested children survive constructor stack frames" {
    var storage = mer.h.RenderStorage.init(std.testing.allocator);
    storage.activate();
    defer storage.deinit();

    const node = runtimeNestedNode("runtime");

    var clobber: [4096]u8 = undefined;
    @memset(&clobber, 0xaa);
    std.mem.doNotOptimizeAway(&clobber);

    const body = try mer.h.render(std.testing.allocator, node);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "<div><h1>runtime</h1><div><span>nested</span></div></div>",
        body,
    );
}

test "core API: repeated owned responses release their bodies" {
    var storage = mer.h.RenderStorage.init(std.testing.allocator);
    storage.activate();
    defer storage.deinit();

    for (0..100) |i| {
        const json_response = mer.typedJson(std.testing.allocator, .{ .request = i });
        json_response.deinit();
        const html_response = mer.render(std.testing.allocator, mer.h.div(.{}, "request"));
        html_response.deinit();
    }
}

test "core API: serialization failures release partial allocations" {
    var json_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const response = mer.typedJson(json_failing.allocator(), .{ .value = "allocation failure" });
    response.deinit();

    var html_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(
        error.OutOfMemory,
        mer.h.render(html_failing.allocator(), mer.h.raw("allocation failure")),
    );
}
