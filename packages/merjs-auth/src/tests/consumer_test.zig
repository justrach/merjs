const std = @import("std");
const mer = @import("mer");
const merjs_auth = @import("merjs-auth");

const NoopAdapter = struct {
    fn query(_: *anyopaque, alloc: std.mem.Allocator, _: []const u8, _: []const merjs_auth.Value) anyerror!merjs_auth.QueryResult {
        return .{ .rows = &.{}, ._arena = std.heap.ArenaAllocator.init(alloc) };
    }
    fn exec(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const merjs_auth.Value) anyerror!void {}
    fn deinit(_: *anyopaque) void {}

    const vtable = merjs_auth.Adapter.VTable{
        .queryFn = query,
        .execFn = exec,
        .deinitFn = deinit,
    };
};

fn config(state: *u8) merjs_auth.Config {
    return .{
        .secret = "consumer-secret-at-least-32-bytes-long",
        .base_url = "https://app.example.com",
        .db = .{ .ptr = state, .vtable = &NoopAdapter.vtable },
    };
}

test "public handle instantiates and calls the complete dispatcher graph" {
    var state: u8 = 0;
    const auth_config = config(&state);
    const req = mer.Request.init(std.testing.allocator, .GET, "/auth/not-a-route");
    const response = try merjs_auth.handle(&auth_config, req);
    try std.testing.expectEqual(std.http.Status.not_found, response.status);
}

test "Microsoft OAuth is rejected before routing while verified built-ins remain supported" {
    var state: u8 = 0;
    var auth_config = config(&state);

    const supported = [_]merjs_auth.oauth.providers.Provider{
        merjs_auth.oauth.providers.google("client", "secret"),
        merjs_auth.oauth.providers.github("client", "secret"),
        merjs_auth.oauth.providers.discord("client", "secret"),
    };
    auth_config.oauth_providers = &supported;
    try merjs_auth.validateConfig(&auth_config);

    const microsoft = merjs_auth.oauth.providers.microsoft("client", "secret", "common");
    auth_config.oauth_providers = &.{microsoft};
    try std.testing.expectError(error.UnsupportedProvider, merjs_auth.validateConfig(&auth_config));

    const initiate = mer.Request.init(std.testing.allocator, .GET, "/auth/oauth/microsoft/initiate");
    try std.testing.expectError(error.UnsupportedProvider, merjs_auth.handle(&auth_config, initiate));

    const callback = mer.Request.init(std.testing.allocator, .GET, "/auth/oauth/microsoft/callback");
    try std.testing.expectError(error.UnsupportedProvider, merjs_auth.handle(&auth_config, callback));
}

test "generated magic-link email targets the routed verify endpoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const message = try merjs_auth.email.buildMagicLinkWithRedirect(
        alloc,
        "https://app.example.com",
        "invalid-token",
        "/dashboard?tab=auth",
    );
    const target_start = std.mem.indexOf(u8, message.text_body, "/auth/") orelse return error.MissingMagicLink;
    const target_end = std.mem.indexOfScalarPos(u8, message.text_body, target_start, '\n') orelse message.text_body.len;
    const target = message.text_body[target_start..target_end];
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return error.MissingMagicLinkQuery;

    var req = mer.Request.init(alloc, .GET, target[0..query_start]);
    req.query_string = target[query_start + 1 ..];
    var state: u8 = 0;
    const auth_config = config(&state);
    const response = try merjs_auth.handle(&auth_config, req);
    try std.testing.expectEqual(std.http.Status.unauthorized, response.status);
}

test "native-shaped auth headers admit valid JSON and reject hostile or missing headers" {
    var state: u8 = 0;
    const auth_config = config(&state);
    const body = "{\"email\":\"nobody@example.com\",\"password\":\"Password123!\",\"name\":\"Nobody\"}";

    var valid = mer.Request.init(std.testing.allocator, .POST, "/auth/sign-up/email");
    valid.body = body;
    valid.headers = &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Origin", .value = "https://app.example.com" },
        .{ .name = "Authorization", .value = "Bearer test" },
    };
    try std.testing.expectEqual(std.http.Status.service_unavailable, (try merjs_auth.handle(&auth_config, valid)).status);

    var missing_origin = valid;
    missing_origin.headers = &.{.{ .name = "Content-Type", .value = "application/json" }};
    try std.testing.expectEqual(std.http.Status.forbidden, (try merjs_auth.handle(&auth_config, missing_origin)).status);

    var hostile = valid;
    hostile.headers = &.{
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "Origin", .value = "https://evil.example" },
    };
    try std.testing.expectEqual(std.http.Status.unsupported_media_type, (try merjs_auth.handle(&auth_config, hostile)).status);
}

test "SAML configuration and endpoints fail closed explicitly" {
    var state: u8 = 0;
    var auth_config = config(&state);
    var req = mer.Request.init(std.testing.allocator, .GET, "/auth/saml/example/initiate");
    const response = try merjs_auth.handle(&auth_config, req);
    try std.testing.expectEqual(std.http.Status.not_implemented, response.status);

    auth_config.saml_providers = &.{.{
        .id = "example",
        .name = "Example",
        .idp_entity_id = "https://idp.example.com",
        .idp_sso_url = "https://idp.example.com/sso",
        .idp_cert_pem = "unused",
    }};
    req.path = "/auth/not-a-route";
    try std.testing.expectError(error.UnsupportedSaml, merjs_auth.handle(&auth_config, req));
}
