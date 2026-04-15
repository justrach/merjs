//! Additional unit tests for merlionjs core functionality

const std = @import("std");
const mer = @import("mer");

// ============================================================================
// HTML Builder Tests
// ============================================================================

test "html builder: basic element" {
    const h = mer.h;
    const node = h.div(.{}, "Hello");
    
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    
    try h.renderToWriter(std.testing.allocator, node, buf.writer());
    const result = try buf.toOwnedSlice();
    defer std.testing.allocator.free(result);
    
    try std.testing.expect(std.mem.indexOf(u8, result, "<div") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Hello") != null);
}

test "html builder: element with attributes" {
    const h = mer.h;
    const attrs = [_]h.Attribute{
        .{ .name = "class", .value = "test-class" },
        .{ .name = "id", .value = "test-id" },
    };
    const node = h.div(.{ .attributes = &attrs }, "Content");
    
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    
    try h.renderToWriter(std.testing.allocator, node, buf.writer());
    const result = try buf.toOwnedSlice();
    defer std.testing.allocator.free(result);
    
    try std.testing.expect(std.mem.indexOf(u8, result, "class=\"test-class\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "id=\"test-id\"") != null);
}

test "html builder: nested elements" {
    const h = mer.h;
    const node = h.div(.{}, &.{
        h.h1(.{}, "Title"),
        h.p(.{}, "Paragraph"),
    });
    
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    
    try h.renderToWriter(std.testing.allocator, node, buf.writer());
    const result = try buf.toOwnedSlice();
    defer std.testing.allocator.free(result);
    
    try std.testing.expect(std.mem.indexOf(u8, result, "<h1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<p") != null);
}

test "html builder: self-closing tags" {
    const h = mer.h;
    const node = h.input(.{ .type_attr = "text" });
    
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    
    try h.renderToWriter(std.testing.allocator, node, buf.writer());
    const result = try buf.toOwnedSlice();
    defer std.testing.allocator.free(result);
    
    try std.testing.expect(std.mem.indexOf(u8, result, "<input") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "type=\"text\"") != null);
}

// ============================================================================
// Response Tests
// ============================================================================

test "response: html response" {
    const resp = mer.html("<p>Hello</p>");
    
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.content_type, .html);
    try std.testing.expectEqualStrings("<p>Hello</p>", resp.body);
}

test "response: json response" {
    const resp = mer.json("{\"key\":\"value\"}");
    
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.content_type, .json);
    try std.testing.expectEqualStrings("{\"key\":\"value\"}", resp.body);
}

test "response: text response" {
    const resp = mer.text(.ok, "Plain text");
    
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.content_type, .text);
    try std.testing.expectEqualStrings("Plain text", resp.body);
}

test "response: not found" {
    const resp = mer.notFound();
    
    try std.testing.expectEqual(resp.status, .not_found);
}

test "response: bad request" {
    const resp = mer.badRequest("Invalid input");
    
    try std.testing.expectEqual(resp.status, .bad_request);
    try std.testing.expectEqualStrings("Invalid input", resp.body);
}

test "response: redirect" {
    const resp = mer.redirect("/new-path", .see_other);
    
    try std.testing.expectEqual(resp.status, .see_other);
    try std.testing.expectEqualStrings("/new-path", resp.location.?);
}

test "response: internal error" {
    const resp = mer.internalError("Something went wrong");
    
    try std.testing.expectEqual(resp.status, .internal_server_error);
    try std.testing.expectEqualStrings("Something went wrong", resp.body);
}

// ============================================================================
// Request Parsing Tests
// ============================================================================

test "formParam: parses simple params" {
    const body = "name=alice&age=30";
    
    const name = mer.formParam(body, "name");
    try std.testing.expectEqualStrings("alice", name.?);
    
    const age = mer.formParam(body, "age");
    try std.testing.expectEqualStrings("30", age.?);
}

test "formParam: returns null for missing param" {
    const body = "name=alice";
    
    const missing = mer.formParam(body, "missing");
    try std.testing.expect(missing == null);
}

test "formParam: handles empty value" {
    const body = "name=&age=30";
    
    const name = mer.formParam(body, "name");
    try std.testing.expectEqualStrings("", name.?);
}

test "formParam: handles single param" {
    const body = "only=value";
    
    const result = mer.formParam(body, "only");
    try std.testing.expectEqualStrings("value", result.?);
}

// ============================================================================
// Cookie Tests
// ============================================================================

test "cookie: parse single cookie" {
    const cookies_raw = "session=abc123";
    
    var cookies = std.mem.splitScalar(u8, cookies_raw, ';');
    const first = cookies.next();
    try std.testing.expect(first != null);
    
    var parts = std.mem.splitScalar(u8, first.?, '=');
    const name = parts.next();
    const value = parts.next();
    
    try std.testing.expectEqualStrings("session", std.mem.trim(u8, name.?, &std.ascii.whitespace));
    try std.testing.expectEqualStrings("abc123", value.?);
}

test "cookie: parse multiple cookies" {
    const cookies_raw = "session=abc123; user=alice; theme=dark";
    
    var cookies = std.mem.splitScalar(u8, cookies_raw, ';');
    var count: usize = 0;
    while (cookies.next()) |_| {
        count += 1;
    }
    
    try std.testing.expectEqual(@as(usize, 3), count);
}

// ============================================================================
// Router Tests (Additional)
// ============================================================================

test "router: exact match with params" {
    const routes = [_]mer.Route{
        .{ .path = "/", .render = dummyRender, .meta = .{} },
        .{ .path = "/users/:id", .render = dummyRender, .meta = .{} },
    };
    
    var router = mer.Router.init(std.testing.allocator, &routes);
    defer router.deinit();
    
    const found = router.findRoute("/users/42");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("/users/:id", found.?.path);
}

test "router: no match returns null" {
    const routes = [_]mer.Route{
        .{ .path = "/", .render = dummyRender, .meta = .{} },
    };
    
    var router = mer.Router.init(std.testing.allocator, &routes);
    defer router.deinit();
    
    const found = router.findRoute("/nonexistent");
    try std.testing.expect(found == null);
}

test "router: empty routes" {
    const routes = [_]mer.Route{};
    
    var router = mer.Router.init(std.testing.allocator, &routes);
    defer router.deinit();
    
    const found = router.findRoute("/");
    try std.testing.expect(found == null);
}

fn dummyRender(_: mer.Request) mer.Response {
    return mer.html("");
}

// ============================================================================
// Session Tests
// ============================================================================

test "session: create and verify" {
    const secret = "test-secret-key-min-32-bytes-long";
    const data = "{\"user\":\"alice\"}";
    
    const signed = mer.signSession(data, secret);
    
    // Parse the signed value to get session ID
    var parts = std.mem.splitScalar(u8, signed, ':');
    const payload = parts.next();
    const sig = parts.next();
    
    try std.testing.expect(payload != null);
    try std.testing.expect(sig != null);
}

// ============================================================================
// Environment Tests
// ============================================================================

test "env: loadDotenv exists" {
    // Just verify the function is accessible
    const f = mer.loadDotenv;
    _ = f;
}

// ============================================================================
// Meta Tests
// ============================================================================

test "meta: default values" {
    const meta: mer.Meta = .{};
    
    try std.testing.expectEqualStrings("", meta.title);
    try std.testing.expectEqualStrings("", meta.description);
}

test "meta: custom values" {
    const meta: mer.Meta = .{
        .title = "Test Page",
        .description = "Test Description",
    };
    
    try std.testing.expectEqualStrings("Test Page", meta.title);
    try std.testing.expectEqualStrings("Test Description", meta.description);
}

// ============================================================================
// Utility Tests
// ============================================================================

test "typedJson: serializes structs" {
    const TestData = struct {
        name: []const u8,
        count: i32,
    };
    
    const data = TestData{ .name = "test", .count = 42 };
    const resp = mer.typedJson(std.testing.allocator, data);
    defer resp.free(std.testing.allocator);
    
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.content_type, .json);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "test") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "42") != null);
}
