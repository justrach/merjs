//! GET /auth/session
//!
//! Returns the current session and user data. Implements a sliding window:
//! if the session expires within 24h it is extended automatically.

const std = @import("std");
const mer = @import("mer");
const db = @import("../db/root.zig");
const session = @import("../session.zig");
const csrf = @import("../csrf.zig");
const AuthContext = @import("../auth.zig").AuthContext;

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
    }

    // 5. Build JSON response.
    const image_json = if (user_image_raw) |img|
        try std.fmt.allocPrint(alloc, "\"{s}\"", .{img})
    else
        try alloc.dupe(u8, "null");

    const resp_body = try std.fmt.allocPrint(alloc,
        \\{{"session":{{"id":"{s}","expires_at":{d}}},"user":{{"id":"{s}","name":"{s}","email":"{s}","email_verified":{s},"image":{s}}}}}
    , .{
        session_id,
        new_expires,
        user_id,
        user_name,
        user_email,
        if (email_verified) "true" else "false",
        image_json,
    });

    const base_resp = mer.Response{
        .status = .ok,
        .body = resp_body,
        .content_type = "application/json",
        .cookies = &.{},
    };

    if (refreshed_cookie) |sc| {
        return mer.withCookies(base_resp, &.{sc});
    }
    return base_resp;
}
