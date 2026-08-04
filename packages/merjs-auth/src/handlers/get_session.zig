//! GET /auth/session
//!
//! Returns the current session and user data. Implements a sliding window:
//! if the session expires within 24h it is extended automatically.

const std = @import("std");
const mer = @import("mer");
const db = @import("../db/root.zig");
const session = @import("../session.zig");
const csrf = @import("../csrf.zig");
const auth = @import("../auth.zig");
const AuthContext = auth.AuthContext;

const TWENTY_FOUR_HOURS_S: i64 = 86400;

pub fn handle(ctx: *AuthContext) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    // 1. Read + verify session cookie.
    const cookie_val = ctx.req.cookie(ctx.config.session_cookie) orelse {
        return mer.json("{\"session\":null}");
    };
    const session_id = session.verifyCookie(cookie_val, ctx.config.secret) orelse {
        return mer.json("{\"session\":null}");
    };

    // 2. Query DB with expiry check.
    const now_str = try std.fmt.allocPrint(alloc, "{d}", .{ctx.now_unix});
    defer alloc.free(now_str);

    var result = try ctx.db.query(alloc,
        \\SELECT s.id, s.expires_at,
        \\       u.id AS user_id, u.name, u.email, u.email_verified, u.image
        \\FROM mauth_sessions s
        \\JOIN mauth_users u ON s.user_id = u.id
        \\WHERE s.id = $1
        \\  AND s.expires_at > to_timestamp($2)
    , &.{
        .{ .text = session_id },
        .{ .text = now_str },
    });
    defer result.deinit();

    // 3. Not found → 200 null.
    if (result.rows.len == 0) {
        return mer.json("{\"session\":null}");
    }

    const row = result.rows[0];
    const expires_at = db.rowInt(row, "expires_at") orelse return mer.json("{\"session\":null}");
    const user_id = db.rowText(row, "user_id") orelse return mer.internalError("db error");
    const user_name = db.rowText(row, "name") orelse "";
    const user_email = db.rowText(row, "email") orelse "";
    const email_verified = db.rowBool(row, "email_verified") orelse false;
    const user_image_raw = db.rowText(row, "image");

    // 4. Sliding window: extend session if it expires within 24h.
    var new_expires = expires_at;
    var refreshed_cookie: ?mer.SetCookie = null;

    if (expires_at - ctx.now_unix < TWENTY_FOUR_HOURS_S) {
        new_expires = ctx.now_unix + @as(i64, ctx.config.session_ttl_s);
        const new_exp_str = try std.fmt.allocPrint(alloc, "{d}", .{new_expires});
        defer alloc.free(new_exp_str);

        try ctx.db.exec(
            alloc,
            "UPDATE mauth_sessions SET expires_at=to_timestamp($1), updated_at=NOW() WHERE id=$2",
            &.{
                .{ .text = new_exp_str },
                .{ .text = session_id },
            },
        );
        refreshed_cookie = try session.cookieSettings(
            session_id,
            ctx.config.secret,
            ctx.config.session_ttl_s,
            ctx.config.secure_cookies,
            alloc,
        );
        refreshed_cookie.?.name = ctx.config.session_cookie;
    }

    // 5. Build JSON response.
    const base_resp = mer.typedJson(alloc, .{
        .session = .{ .id = session_id, .expires_at = new_expires },
        .user = .{
            .id = user_id,
            .name = user_name,
            .email = user_email,
            .email_verified = email_verified,
            .image = user_image_raw,
        },
    });

    if (refreshed_cookie) |sc| {
        const cookies = try alloc.alloc(mer.SetCookie, 1);
        cookies[0] = sc;
        return mer.withCookies(base_resp, cookies);
    }
    return base_resp;
}

fn testRequest(alloc: std.mem.Allocator, cookie: []const u8) !mer.Request {
    return .{
        .method = .GET,
        .path = "/auth/session",
        .query_string = "",
        .body = "",
        .cookies_raw = try std.fmt.allocPrint(alloc, "{s}={s}", .{ session.COOKIE_SESSION, cookie }),
        .params = &.{},
        .allocator = alloc,
    };
}

test "session producer to getSession supports canonical and Config.secret migration" {
    mer.resetEnv();
    defer mer.resetEnv();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const mem = @import("../db/mem.zig");
    var mem_adapter = mem.MemAdapter.init(std.testing.allocator);
    defer mem_adapter.deinit();
    const adapter = mem_adapter.adapter();
    const config = auth.Config{
        .secret = "legacy-config-secret-at-least-32-bytes",
        .base_url = "http://localhost",
        .db = adapter,
        .secure_cookies = false,
    };

    try adapter.exec(std.testing.allocator, "INSERT INTO mauth_users", &.{
        .{ .text = "user-1" },
        .{ .text = "Alice" },
        .{ .text = "alice@example.com" },
    });
    try adapter.exec(std.testing.allocator, "INSERT INTO mauth_sessions", &.{
        .{ .text = "session-1" },
        .{ .text = "user-1" },
        .{ .text = "token-1" },
        .{ .int = 1_800_000_000 },
    });

    const legacy_cookie = try session.cookieSettings("session-1", config.secret, 3600, false, alloc);

    const canonical_secret = "canonical-session-secret-at-least-32-bytes";
    try mer.putEnv("MERJS_SESSION_SECRET", canonical_secret);

    const legacy_req = try testRequest(alloc, legacy_cookie.value);
    var legacy_ctx = AuthContext{ .req = legacy_req, .config = &config, .db = adapter, .now_unix = 1_700_000_000 };
    const legacy_res = try handle(&legacy_ctx);
    try std.testing.expect(std.mem.indexOf(u8, legacy_res.body, "alice@example.com") != null);

    const canonical_cookie = try session.cookieSettings("session-1", config.secret, 3600, false, alloc);
    try std.testing.expect(@import("../crypto.zig").verifySignedToken(canonical_cookie.value, canonical_secret) != null);
    try std.testing.expect(@import("../crypto.zig").verifySignedToken(canonical_cookie.value, config.secret) == null);

    const canonical_req = try testRequest(alloc, canonical_cookie.value);
    var canonical_ctx = AuthContext{ .req = canonical_req, .config = &config, .db = adapter, .now_unix = 1_700_000_000 };
    const canonical_res = try handle(&canonical_ctx);
    try std.testing.expect(std.mem.indexOf(u8, canonical_res.body, "alice@example.com") != null);
}
