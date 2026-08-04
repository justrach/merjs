//! End-to-end flow tests for merjs-auth.
//!
//! These tests construct real mer.Request structs and call real auth handlers
//! through the MemAdapter in-memory database backend. They prove the full
//! sign-up → sign-in → session → sign-out flow works correctly.

const std = @import("std");
const testing = std.testing;
const mer = @import("mer");
const merjs_auth = @import("../root.zig");
const db = @import("../db/root.zig");
const mem = @import("../db/mem.zig");
const session_mod = @import("../session.zig");

const argon2 = std.crypto.pwhash.argon2;

// Fast params for testing — don't use WorkersParams (too slow in tests).
// ~1ms per hash instead of ~200ms.
const TEST_ARGON2 = argon2.Params{ .t = 1, .m = 8, .p = 1 };
const JSON_HEADERS = [_]std.http.Header{
    .{ .name = "Content-Type", .value = "application/json" },
    .{ .name = "Origin", .value = "http://localhost:3000" },
};

// ── Test helpers ──────────────────────────────────────────────────────────────

/// Build a Config suitable for fast unit tests.
fn testConfig(db_adapter: db.Adapter) merjs_auth.Config {
    return .{
        .secret = "test-secret-at-least-32-bytes-long!!",
        .base_url = "http://localhost:3000",
        .db = db_adapter,
        .secure_cookies = false, // no HTTPS in tests
        .argon2_params = TEST_ARGON2,
    };
}

/// Build a mer.Request for testing.
fn testReq(arena_alloc: std.mem.Allocator, method: mer.Method, path: []const u8) mer.Request {
    return .{
        .method = method,
        .path = path,
        .query_string = "",
        .body = "",
        .cookies_raw = "",
        .params = &.{},
        .allocator = arena_alloc,
    };
}

/// Build a mer.Request with a JSON body.
fn testReqWithBody(arena_alloc: std.mem.Allocator, method: mer.Method, path: []const u8, body: []const u8) mer.Request {
    return .{
        .method = method,
        .path = path,
        .query_string = "",
        .body = body,
        .cookies_raw = "",
        .headers = &JSON_HEADERS,
        .client_identity = "test-client",
        .params = &.{},
        .allocator = arena_alloc,
    };
}

/// Build a request with both body and cookies.
fn testReqWithBodyAndCookies(
    arena_alloc: std.mem.Allocator,
    method: mer.Method,
    path: []const u8,
    body: []const u8,
    cookies_raw: []const u8,
) mer.Request {
    return .{
        .method = method,
        .path = path,
        .query_string = "",
        .body = body,
        .cookies_raw = cookies_raw,
        .headers = &JSON_HEADERS,
        .params = &.{},
        .allocator = arena_alloc,
    };
}

/// Build a request with cookies.
fn testReqWithCookies(
    arena_alloc: std.mem.Allocator,
    method: mer.Method,
    path: []const u8,
    cookies_raw: []const u8,
) mer.Request {
    return .{
        .method = method,
        .path = path,
        .query_string = "",
        .body = "",
        .cookies_raw = cookies_raw,
        .headers = if (method == .POST) &JSON_HEADERS else &.{},
        .params = &.{},
        .allocator = arena_alloc,
    };
}

/// Extract the mauth_session cookie value from a response.
fn getSessionCookie(res: mer.Response) ?[]const u8 {
    for (res.cookies) |c| {
        if (std.mem.eql(u8, c.name, session_mod.COOKIE_SESSION)) {
            if (c.value.len > 0) return c.value;
        }
    }
    return null;
}

/// Find a cookie by name, regardless of value.
fn getCookieByName(res: mer.Response, name: []const u8) ?mer.SetCookie {
    for (res.cookies) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

/// Build a cookies_raw string like "mauth_session=VALUE".
fn buildSessionCookies(alloc: std.mem.Allocator, cookie_value: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}={s}", .{ session_mod.COOKIE_SESSION, cookie_value });
}

// ── Sign-up helper ─────────────────────────────────────────────────────────────

/// Sign up a test user. Returns the session cookie value (owned by arena).
/// Asserts sign-up succeeded (status == .created).
fn signUpAlice(arena_alloc: std.mem.Allocator, config: *const merjs_auth.Config) ![]const u8 {
    const req = testReqWithBody(
        arena_alloc,
        .POST,
        "/auth/sign-up/email",
        "{\"email\":\"alice@test.com\",\"password\":\"Password123!\",\"name\":\"Alice\"}",
    );
    const res = try merjs_auth.handle(config, req);
    try testing.expectEqual(std.http.Status.created, res.status);
    const cookie = getSessionCookie(res) orelse return error.NoCookie;
    return arena_alloc.dupe(u8, cookie);
}

// ── Tests ──────────────────────────────────────────────────────────────────────

test "sign-up creates user and returns session cookie" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mem_adapter = mem.MemAdapter.init(testing.allocator);
    defer mem_adapter.deinit();
    const config = testConfig(mem_adapter.adapter());

    const req = testReqWithBody(
        alloc,
        .POST,
        "/auth/sign-up/email",
        "{\"email\":\"alice@test.com\",\"password\":\"Password123!\",\"name\":\"Alice\"}",
    );

    const res = try merjs_auth.handle(&config, req);

    // 1. Status must be 201 Created
    try testing.expectEqual(std.http.Status.created, res.status);

    // 2. Body must contain user.email and email_verified:false
    try testing.expect(std.mem.indexOf(u8, res.body, "alice@test.com") != null);
    try testing.expect(std.mem.indexOf(u8, res.body, "email_verified") != null);
    try testing.expect(std.mem.indexOf(u8, res.body, "false") != null);

    // 3. Session cookie must be set
    const cookie_val = getSessionCookie(res);
    try testing.expect(cookie_val != null);
    try testing.expect(cookie_val.?.len > 0);

    // 4. User must exist in the in-memory store
    const user = mem_adapter.findUserByEmail("alice@test.com");
    try testing.expect(user != null);
    try testing.expectEqualStrings("Alice", user.?.name);

    // 5. One session must exist
    try testing.expectEqual(@as(usize, 1), mem_adapter.sessionCount());
}

test "sign-up rejects duplicate email" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mem_adapter = mem.MemAdapter.init(testing.allocator);
    defer mem_adapter.deinit();
    const config = testConfig(mem_adapter.adapter());

    // First sign-up succeeds
    const req1 = testReqWithBody(
        alloc,
        .POST,
        "/auth/sign-up/email",
        "{\"email\":\"alice@test.com\",\"password\":\"Password123!\",\"name\":\"Alice\"}",
    );
    const res1 = try merjs_auth.handle(&config, req1);
    try testing.expectEqual(std.http.Status.created, res1.status);

    // Second sign-up with same email must fail
    const req2 = testReqWithBody(
        alloc,
        .POST,
        "/auth/sign-up/email",
        "{\"email\":\"alice@test.com\",\"password\":\"Password123!\",\"name\":\"Alice2\"}",
    );
    const res2 = try merjs_auth.handle(&config, req2);
    try testing.expectEqual(std.http.Status.conflict, res2.status);
}

test "sign-in returns session for valid credentials" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mem_adapter = mem.MemAdapter.init(testing.allocator);
    defer mem_adapter.deinit();
    const config = testConfig(mem_adapter.adapter());

    // Sign up first
    _ = try signUpAlice(alloc, &config);

    // Sign in
    const req = testReqWithBody(
        alloc,
        .POST,
        "/auth/sign-in/email",
        "{\"email\":\"alice@test.com\",\"password\":\"Password123!\"}",
    );
    const res = try merjs_auth.handle(&config, req);

    // Must return 200 OK
    try testing.expectEqual(std.http.Status.ok, res.status);

    // Session cookie must be set
    const cookie_val = getSessionCookie(res);
    try testing.expect(cookie_val != null);
    try testing.expect(cookie_val.?.len > 0);

    // Body must contain user data
    try testing.expect(std.mem.indexOf(u8, res.body, "alice@test.com") != null);
}

test "sign-in rejects wrong password" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mem_adapter = mem.MemAdapter.init(testing.allocator);
    defer mem_adapter.deinit();
    const config = testConfig(mem_adapter.adapter());

    // Sign up first
    _ = try signUpAlice(alloc, &config);

    // Sign in with wrong password
    const req = testReqWithBody(
        alloc,
        .POST,
        "/auth/sign-in/email",
        "{\"email\":\"alice@test.com\",\"password\":\"WrongPassword!\"}",
    );
    const res = try merjs_auth.handle(&config, req);
    try testing.expectEqual(std.http.Status.unauthorized, res.status);
}

test "sign-in rejects unknown email" {
    // NOTE: This test may take ~100ms due to timing-attack mitigation sleep
    // in the sign-in handler when no user is found.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mem_adapter = mem.MemAdapter.init(testing.allocator);
    defer mem_adapter.deinit();
    const config = testConfig(mem_adapter.adapter());

    const req = testReqWithBody(
        alloc,
        .POST,
        "/auth/sign-in/email",
        "{\"email\":\"nobody@test.com\",\"password\":\"Password123!\"}",
    );
    const res = try merjs_auth.handle(&config, req);
    try testing.expectEqual(std.http.Status.unauthorized, res.status);
}

test "sign-in rejects browser-simple content types and untrusted origins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mem_adapter = mem.MemAdapter.init(testing.allocator);
    defer mem_adapter.deinit();
    var config = testConfig(mem_adapter.adapter());
    const body = "{\"email\":\"alice@test.com\",\"password\":\"Password123!\"}";

    const text_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "Origin", .value = "http://localhost:3000" },
    };
    var text_req = testReqWithBody(alloc, .POST, "/auth/sign-in/email", body);
    text_req.headers = &text_headers;
    try testing.expectEqual(std.http.Status.unsupported_media_type, (try merjs_auth.handle(&config, text_req)).status);

    const form_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "Origin", .value = "http://localhost:3000" },
    };
    var form_req = testReqWithBody(alloc, .POST, "/auth/sign-in/email", body);
    form_req.headers = &form_headers;
    try testing.expectEqual(std.http.Status.unsupported_media_type, (try merjs_auth.handle(&config, form_req)).status);

    const no_origin_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    var no_origin_req = testReqWithBody(alloc, .POST, "/auth/sign-in/email", body);
    no_origin_req.headers = &no_origin_headers;
    try testing.expectEqual(std.http.Status.forbidden, (try merjs_auth.handle(&config, no_origin_req)).status);

    const evil_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
        .{ .name = "Origin", .value = "http://localhost:3000.evil.test" },
    };
    var evil_req = testReqWithBody(alloc, .POST, "/auth/sign-in/email", body);
    evil_req.headers = &evil_headers;
    try testing.expectEqual(std.http.Status.forbidden, (try merjs_auth.handle(&config, evil_req)).status);

    config.trusted_origins = &.{"https://frontend.example"};
    const trusted_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Origin", .value = "https://frontend.example" },
    };
    var trusted_req = testReqWithBody(alloc, .POST, "/auth/sign-in/email", "{}");
    trusted_req.headers = &trusted_headers;
    try testing.expectEqual(std.http.Status.bad_request, (try merjs_auth.handle(&config, trusted_req)).status);
}

test "get-session returns user data with valid session" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mem_adapter = mem.MemAdapter.init(testing.allocator);
    defer mem_adapter.deinit();
    const config = testConfig(mem_adapter.adapter());

    // Sign up to get a session cookie
    const cookie_val = try signUpAlice(alloc, &config);
    const cookies_raw = try buildSessionCookies(alloc, cookie_val);

    // GET /auth/session with the cookie
    const req = testReqWithCookies(alloc, .GET, "/auth/session", cookies_raw);
    const res = try merjs_auth.handle(&config, req);

    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "alice@test.com") != null);
}

test "get-session returns null for missing cookie" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mem_adapter = mem.MemAdapter.init(testing.allocator);
    defer mem_adapter.deinit();
    const config = testConfig(mem_adapter.adapter());

    const req = testReq(alloc, .GET, "/auth/session");
    const res = try merjs_auth.handle(&config, req);

    try testing.expectEqual(std.http.Status.ok, res.status);
    // Body should contain session:null
    try testing.expect(std.mem.indexOf(u8, res.body, "null") != null);
}

test "sign-out clears session" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mem_adapter = mem.MemAdapter.init(testing.allocator);
    defer mem_adapter.deinit();
    const config = testConfig(mem_adapter.adapter());

    // Sign up to get a session cookie
    const cookie_val = try signUpAlice(alloc, &config);
    const cookies_raw = try buildSessionCookies(alloc, cookie_val);

    // POST /auth/sign-out
    const req = testReqWithCookies(alloc, .POST, "/auth/sign-out", cookies_raw);
    const res = try merjs_auth.handle(&config, req);

    // Status must be 200
    try testing.expectEqual(std.http.Status.ok, res.status);

    // Session cookie in response must have max_age == 0 (expired)
    const sc = getCookieByName(res, session_mod.COOKIE_SESSION);
    try testing.expect(sc != null);
    try testing.expectEqual(@as(?u32, 0), sc.?.max_age);

    // DB must have no sessions
    try testing.expectEqual(@as(usize, 0), mem_adapter.sessionCount());

    // Bonus: GET /auth/session after sign-out returns null session
    const req2 = testReqWithCookies(alloc, .GET, "/auth/session", cookies_raw);
    const res2 = try merjs_auth.handle(&config, req2);
    try testing.expectEqual(std.http.Status.ok, res2.status);
    try testing.expect(std.mem.indexOf(u8, res2.body, "null") != null);
}

test "full flow: sign-up -> sign-in -> session -> sign-out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mem_adapter = mem.MemAdapter.init(testing.allocator);
    defer mem_adapter.deinit();
    const config = testConfig(mem_adapter.adapter());

    // ── Step 1: Sign up ──────────────────────────────────────────────────────
    const signup_req = testReqWithBody(
        alloc,
        .POST,
        "/auth/sign-up/email",
        "{\"email\":\"alice@test.com\",\"password\":\"Password123!\",\"name\":\"Alice\"}",
    );
    const signup_res = try merjs_auth.handle(&config, signup_req);
    try testing.expectEqual(std.http.Status.created, signup_res.status);

    const signup_cookie = getSessionCookie(signup_res) orelse return error.NoCookieAfterSignup;
    const signup_cookies_raw = try buildSessionCookies(alloc, signup_cookie);

    // User exists in DB
    try testing.expect(mem_adapter.findUserByEmail("alice@test.com") != null);
    try testing.expectEqual(@as(usize, 1), mem_adapter.sessionCount());

    // ── Step 2: Get session using sign-up cookie ──────────────────────────────
    const session_req1 = testReqWithCookies(alloc, .GET, "/auth/session", signup_cookies_raw);
    const session_res1 = try merjs_auth.handle(&config, session_req1);
    try testing.expectEqual(std.http.Status.ok, session_res1.status);
    try testing.expect(std.mem.indexOf(u8, session_res1.body, "alice@test.com") != null);

    // ── Step 3: Sign out ──────────────────────────────────────────────────────
    const signout_req = testReqWithCookies(alloc, .POST, "/auth/sign-out", signup_cookies_raw);
    const signout_res = try merjs_auth.handle(&config, signout_req);
    try testing.expectEqual(std.http.Status.ok, signout_res.status);
    try testing.expectEqual(@as(usize, 0), mem_adapter.sessionCount());

    // ── Step 4: Sign in again ─────────────────────────────────────────────────
    const signin_req = testReqWithBody(
        alloc,
        .POST,
        "/auth/sign-in/email",
        "{\"email\":\"alice@test.com\",\"password\":\"Password123!\"}",
    );
    const signin_res = try merjs_auth.handle(&config, signin_req);
    try testing.expectEqual(std.http.Status.ok, signin_res.status);

    const signin_cookie = getSessionCookie(signin_res) orelse return error.NoCookieAfterSignin;
    const signin_cookies_raw = try buildSessionCookies(alloc, signin_cookie);

    // New session created
    try testing.expectEqual(@as(usize, 1), mem_adapter.sessionCount());

    // ── Step 5: Get session using sign-in cookie ──────────────────────────────
    const session_req2 = testReqWithCookies(alloc, .GET, "/auth/session", signin_cookies_raw);
    const session_res2 = try merjs_auth.handle(&config, session_req2);
    try testing.expectEqual(std.http.Status.ok, session_res2.status);
    try testing.expect(std.mem.indexOf(u8, session_res2.body, "alice@test.com") != null);

    // ── Step 6: Old sign-up cookie is now invalid ─────────────────────────────
    // (old session was deleted; sign-out does a DB-level delete by session ID)
    // The old cookie's session no longer exists in DB, so session endpoint returns null.
    // Note: we can't use the old cookie here since the sign-up session was deleted.
    // The new sign-in session is active.
    try testing.expectEqual(@as(usize, 1), mem_adapter.sessionCount());

    // ── Step 7: Sign out again ────────────────────────────────────────────────
    const signout_req2 = testReqWithCookies(alloc, .POST, "/auth/sign-out", signin_cookies_raw);
    _ = try merjs_auth.handle(&config, signout_req2);
    try testing.expectEqual(@as(usize, 0), mem_adapter.sessionCount());
}

test "rate limits ignore query spoofing and do not share an unknown-client bucket" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mem_adapter = mem.MemAdapter.init(testing.allocator);
    defer mem_adapter.deinit();
    const config = testConfig(mem_adapter.adapter());

    for (0..10) |i| {
        var req = testReqWithBody(alloc, .POST, "/auth/sign-up/email", "{}");
        req.query_string = try std.fmt.allocPrint(alloc, "x-forwarded-for=198.51.100.{d}", .{i});
        try testing.expectEqual(std.http.Status.bad_request, (try merjs_auth.handle(&config, req)).status);
    }
    var blocked = testReqWithBody(alloc, .POST, "/auth/sign-up/email", "{}");
    blocked.query_string = "x-forwarded-for=203.0.113.1";
    try testing.expectEqualStrings("{\"error\":\"too many requests\"}", (try merjs_auth.handle(&config, blocked)).body);

    var unavailable = testReqWithBody(
        alloc,
        .POST,
        "/auth/sign-up/email",
        "{\"email\":\"nobody@test.com\",\"password\":\"Password123!\",\"name\":\"Nobody\"}",
    );
    unavailable.client_identity = null;
    unavailable.query_string = "x-forwarded-for=192.0.2.1";
    try testing.expectEqual(std.http.Status.service_unavailable, (try merjs_auth.handle(&config, unavailable)).status);

    var other_client = testReqWithBody(alloc, .POST, "/auth/sign-up/email", "{}");
    other_client.client_identity = "other-client";
    try testing.expectEqual(std.http.Status.bad_request, (try merjs_auth.handle(&config, other_client)).status);
}

test "sign-in retains account limits without a client identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mem_adapter = mem.MemAdapter.init(testing.allocator);
    defer mem_adapter.deinit();
    const config = testConfig(mem_adapter.adapter());
    _ = try signUpAlice(alloc, &config);

    for (0..5) |i| {
        var req = testReqWithBody(
            alloc,
            .POST,
            "/auth/sign-in/email",
            "{\"email\":\"alice@test.com\",\"password\":\"WrongPassword!\"}",
        );
        req.client_identity = null;
        req.query_string = try std.fmt.allocPrint(alloc, "x-forwarded-for=192.0.2.{d}", .{i});
        try testing.expectEqual(std.http.Status.unauthorized, (try merjs_auth.handle(&config, req)).status);
    }
    var blocked = testReqWithBody(
        alloc,
        .POST,
        "/auth/sign-in/email",
        "{\"email\":\"alice@test.com\",\"password\":\"WrongPassword!\"}",
    );
    blocked.client_identity = null;
    blocked.query_string = "x-forwarded-for=203.0.113.2";
    try testing.expectEqualStrings("{\"error\":\"too many requests\"}", (try merjs_auth.handle(&config, blocked)).body);
}

test "auth user JSON escapes quotes backslashes and control characters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mem_adapter = mem.MemAdapter.init(testing.allocator);
    defer mem_adapter.deinit();
    const config = testConfig(mem_adapter.adapter());
    const expected_name = "A\"lice\\Admin\nTab\t";
    const req = testReqWithBody(
        alloc,
        .POST,
        "/auth/sign-up/email",
        "{\"email\":\"alice@test.com\",\"password\":\"Password123!\",\"name\":\"A\\\"lice\\\\Admin\\nTab\\t\"}",
    );
    const res = try merjs_auth.handle(&config, req);
    try testing.expectEqual(std.http.Status.created, res.status);

    const SignupPayload = struct {
        user: struct { id: []const u8, email: []const u8, name: []const u8, email_verified: bool },
    };
    const parsed_signup = try std.json.parseFromSlice(SignupPayload, alloc, res.body, .{});
    defer parsed_signup.deinit();
    try testing.expectEqualStrings(expected_name, parsed_signup.value.user.name);

    const cookie = getSessionCookie(res) orelse return error.NoCookie;
    const cookies_raw = try buildSessionCookies(alloc, cookie);
    const session_res = try merjs_auth.handle(&config, testReqWithCookies(alloc, .GET, "/auth/session", cookies_raw));
    const SessionPayload = struct {
        session: struct { id: []const u8, expires_at: i64 },
        user: struct { id: []const u8, name: []const u8, email: []const u8, email_verified: bool, image: ?[]const u8 },
    };
    const parsed_session = try std.json.parseFromSlice(SessionPayload, alloc, session_res.body, .{});
    defer parsed_session.deinit();
    try testing.expectEqualStrings(expected_name, parsed_session.value.user.name);
}

test "sign-up validates password strength" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mem_adapter = mem.MemAdapter.init(testing.allocator);
    defer mem_adapter.deinit();
    const config = testConfig(mem_adapter.adapter());

    // Password "short" is only 5 chars — below the 8-char minimum
    const req = testReqWithBody(
        alloc,
        .POST,
        "/auth/sign-up/email",
        "{\"password\":\"short\",\"email\":\"x@y.com\",\"name\":\"X\"}",
    );
    const res = try merjs_auth.handle(&config, req);
    try testing.expectEqual(std.http.Status.bad_request, res.status);

    // No user was created
    try testing.expectEqual(@as(usize, 0), mem_adapter.sessionCount());
}
