//! In-memory database adapter for merjs-auth testing.
//!
//! Implements the `db.Adapter` vtable by storing typed rows in Zig ArrayLists.
//! SQL queries are dispatched by pattern-matching on keywords in the SQL string.
//! All stored strings are owned copies (duped into `alloc`).

const std = @import("std");
const db = @import("root.zig");

/// Get current Unix timestamp in seconds (Zig 0.16 compatible).
fn currentUnixSeconds() i64 {
    var ts: std.c.time.timespec = undefined;
    _ = std.c.clock_gettime(std.c.time.CLOCK.REALTIME, &ts);
    return ts.sec;
}

// ── Internal typed row types ───────────────────────────────────────────────

const UserRow = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
    email_verified: bool,
    image: ?[]const u8 = null,
};

const AccountRow = struct {
    id: []const u8,
    user_id: []const u8,
    provider_id: []const u8,
    account_id: []const u8,
    password_hash: ?[]const u8 = null,
};

const SessionRow = struct {
    id: []const u8,
    user_id: []const u8,
    token: []const u8,
    /// Unix seconds
    expires_at: i64,
};

const TokenRow = struct {
    id: []const u8,
    user_id: []const u8,
    token_hash: []const u8,
    purpose: []const u8,
    /// Unix seconds
    expires_at: i64,
    used_at: ?i64 = null,
};

const RateLimitRow = struct {
    key: []const u8,
    count: i64,
    window_start: i64,
};

// ── Query classification ────────────────────────────────────────────────────

const QueryClass = enum {
    // mauth_users
    users_select_id_by_email,
    users_insert,
    users_update_email_verified,

    // mauth_oauth_accounts
    accounts_insert,
    accounts_join_select_by_email,
    accounts_select_password_hash,
    accounts_update_password_hash,

    // mauth_sessions
    sessions_insert,
    sessions_join_select_by_id,
    sessions_delete_by_id,
    sessions_delete_others,
    sessions_delete_by_user,
    sessions_update_expires,

    // mauth_tokens
    tokens_insert,
    tokens_select_by_hash,
    tokens_mark_used,
    tokens_delete_by_user_purpose,

    // mauth_rate_limits
    rate_limits_any,

    // fallback
    unknown,
};

fn classify(sql: []const u8) QueryClass {
    const has = std.mem.indexOf;

    // Rate limits — check first (fast path for high-frequency calls)
    if (has(u8, sql, "mauth_rate_limits") != null) return .rate_limits_any;

    // Sessions
    if (has(u8, sql, "mauth_sessions") != null) {
        if (has(u8, sql, "INSERT") != null) return .sessions_insert;
        if (has(u8, sql, "DELETE") != null) {
            if (has(u8, sql, "id != ") != null) return .sessions_delete_others;
            if (has(u8, sql, "user_id=$1") != null or has(u8, sql, "user_id = $1") != null) return .sessions_delete_by_user;
            return .sessions_delete_by_id;
        }
        if (has(u8, sql, "UPDATE") != null) return .sessions_update_expires;
        if (has(u8, sql, "SELECT") != null) return .sessions_join_select_by_id;
    }

    // Tokens
    if (has(u8, sql, "mauth_tokens") != null) {
        if (has(u8, sql, "INSERT") != null) return .tokens_insert;
        if (has(u8, sql, "UPDATE") != null) return .tokens_mark_used;
        if (has(u8, sql, "DELETE") != null) return .tokens_delete_by_user_purpose;
        if (has(u8, sql, "SELECT") != null) return .tokens_select_by_hash;
    }

    // OAuth accounts + JOIN with users -> sign-in query
    if (has(u8, sql, "mauth_oauth_accounts") != null and has(u8, sql, "mauth_users") != null) {
        return .accounts_join_select_by_email;
    }

    // OAuth accounts alone
    if (has(u8, sql, "mauth_oauth_accounts") != null) {
        if (has(u8, sql, "INSERT") != null) return .accounts_insert;
        if (has(u8, sql, "UPDATE") != null) return .accounts_update_password_hash;
        if (has(u8, sql, "SELECT") != null) return .accounts_select_password_hash;
    }

    // Users
    if (has(u8, sql, "mauth_users") != null) {
        if (has(u8, sql, "INSERT") != null) return .users_insert;
        if (has(u8, sql, "UPDATE") != null) return .users_update_email_verified;
        if (has(u8, sql, "SELECT") != null) return .users_select_id_by_email;
    }

    return .unknown;
}

// ── Helpers to parse param values ──────────────────────────────────────────

fn paramText(params: []const db.Value, idx: usize) []const u8 {
    if (idx >= params.len) return "";
    return switch (params[idx]) {
        .text => |v| v,
        else => "",
    };
}

fn paramInt(params: []const db.Value, idx: usize) i64 {
    if (idx >= params.len) return 0;
    return switch (params[idx]) {
        .int => |v| v,
        .text => |v| std.fmt.parseInt(i64, v, 10) catch 0,
        else => 0,
    };
}

// ── MemAdapter ─────────────────────────────────────────────────────────────

pub const MemAdapter = struct {
    alloc: std.mem.Allocator,
    users: std.ArrayList(UserRow),
    accounts: std.ArrayList(AccountRow),
    sessions: std.ArrayList(SessionRow),
    tokens: std.ArrayList(TokenRow),
    rate_limits: std.ArrayList(RateLimitRow),

    pub fn init(alloc: std.mem.Allocator) MemAdapter {
        return .{
            .alloc = alloc,
            .users = .{},
            .accounts = .{},
            .sessions = .{},
            .tokens = .{},
            .rate_limits = .{},
        };
    }

    pub fn deinit(self: *MemAdapter) void {
        for (self.users.items) |r| {
            self.alloc.free(r.id);
            self.alloc.free(r.name);
            self.alloc.free(r.email);
            if (r.image) |img| self.alloc.free(img);
        }
        for (self.accounts.items) |r| {
            self.alloc.free(r.id);
            self.alloc.free(r.user_id);
            self.alloc.free(r.provider_id);
            self.alloc.free(r.account_id);
            if (r.password_hash) |h| self.alloc.free(h);
        }
        for (self.sessions.items) |r| {
            self.alloc.free(r.id);
            self.alloc.free(r.user_id);
            self.alloc.free(r.token);
        }
        for (self.tokens.items) |r| {
            self.alloc.free(r.id);
            self.alloc.free(r.user_id);
            self.alloc.free(r.token_hash);
            self.alloc.free(r.purpose);
        }
        for (self.rate_limits.items) |r| {
            self.alloc.free(r.key);
        }
        self.users.deinit(self.alloc);
        self.accounts.deinit(self.alloc);
        self.sessions.deinit(self.alloc);
        self.tokens.deinit(self.alloc);
        self.rate_limits.deinit(self.alloc);
    }

    pub fn adapter(self: *MemAdapter) db.Adapter {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    // ── Test helpers ─────────────────────────────────────────────────────────

    pub fn findUserByEmail(self: *MemAdapter, email: []const u8) ?UserRow {
        for (self.users.items) |u| {
            if (std.mem.eql(u8, u.email, email)) return u;
        }
        return null;
    }

    pub fn findSessionById(self: *MemAdapter, id: []const u8) ?SessionRow {
        for (self.sessions.items) |s| {
            if (std.mem.eql(u8, s.id, id)) return s;
        }
        return null;
    }

    pub fn sessionCount(self: *MemAdapter) usize {
        return self.sessions.items.len;
    }

    pub fn tokenCount(self: *MemAdapter) usize {
        return self.tokens.items.len;
    }

    // ── query dispatch ─────────────────────────────────────────────────────────

    fn queryImpl(
        self: *MemAdapter,
        alloc: std.mem.Allocator,
        sql: []const u8,
        params: []const db.Value,
    ) !db.QueryResult {
        const class = classify(sql);

        var arena = std.heap.ArenaAllocator.init(alloc);
        const aa = arena.allocator();

        switch (class) {
            // ── SELECT id FROM mauth_users WHERE email = $1 ──────────────────
            .users_select_id_by_email => {
                const email = paramText(params, 0);
                var rows: std.ArrayList(db.Row) = .{};
                for (self.users.items) |u| {
                    if (std.mem.eql(u8, u.email, email)) {
                        const fields = try aa.alloc(db.Field, 1);
                        fields[0] = .{ .name = "id", .value = .{ .text = try aa.dupe(u8, u.id) } };
                        try rows.append(aa, fields);
                    }
                }
                return db.QueryResult{
                    .rows = try rows.toOwnedSlice(aa),
                    ._arena = arena,
                };
            },

            // ── SELECT u.id, u.name, u.email, u.email_verified, a.password_hash (JOIN sign-in) ──
            .accounts_join_select_by_email => {
                const email = paramText(params, 0);
                var rows: std.ArrayList(db.Row) = .{};
                // Find user by email
                for (self.users.items) |u| {
                    if (!std.mem.eql(u8, u.email, email)) continue;
                    // Find matching email account
                    for (self.accounts.items) |a| {
                        if (!std.mem.eql(u8, a.user_id, u.id)) continue;
                        if (!std.mem.eql(u8, a.provider_id, "email")) continue;
                        const fields = try aa.alloc(db.Field, 5);
                        fields[0] = .{ .name = "id", .value = .{ .text = try aa.dupe(u8, u.id) } };
                        fields[1] = .{ .name = "name", .value = .{ .text = try aa.dupe(u8, u.name) } };
                        fields[2] = .{ .name = "email", .value = .{ .text = try aa.dupe(u8, u.email) } };
                        fields[3] = .{ .name = "email_verified", .value = .{ .bool_val = u.email_verified } };
                        if (a.password_hash) |h| {
                            fields[4] = .{ .name = "password_hash", .value = .{ .text = try aa.dupe(u8, h) } };
                        } else {
                            fields[4] = .{ .name = "password_hash", .value = .{ .null_val = {} } };
                        }
                        try rows.append(aa, fields);
                        break;
                    }
                    break;
                }
                return db.QueryResult{
                    .rows = try rows.toOwnedSlice(aa),
                    ._arena = arena,
                };
            },

            // ── SELECT a.password_hash FROM mauth_oauth_accounts ─────────────
            .accounts_select_password_hash => {
                const user_id = paramText(params, 0);
                var rows: std.ArrayList(db.Row) = .{};
                for (self.accounts.items) |a| {
                    if (!std.mem.eql(u8, a.user_id, user_id)) continue;
                    if (!std.mem.eql(u8, a.provider_id, "email")) continue;
                    const fields = try aa.alloc(db.Field, 1);
                    if (a.password_hash) |h| {
                        fields[0] = .{ .name = "password_hash", .value = .{ .text = try aa.dupe(u8, h) } };
                    } else {
                        fields[0] = .{ .name = "password_hash", .value = .{ .null_val = {} } };
                    }
                    try rows.append(aa, fields);
                    break;
                }
                return db.QueryResult{
                    .rows = try rows.toOwnedSlice(aa),
                    ._arena = arena,
                };
            },

            // ── SELECT s.id, s.expires_at, u.id as user_id, ... (JOIN get-session) ──
            .sessions_join_select_by_id => {
                const session_id = paramText(params, 0);
                const now_unix = paramInt(params, 1);
                var rows: std.ArrayList(db.Row) = .{};
                for (self.sessions.items) |s| {
                    if (!std.mem.eql(u8, s.id, session_id)) continue;
                    if (s.expires_at <= now_unix) break;
                    // Find user
                    for (self.users.items) |u| {
                        if (!std.mem.eql(u8, u.id, s.user_id)) continue;
                        const fields = try aa.alloc(db.Field, 7);
                        fields[0] = .{ .name = "id", .value = .{ .text = try aa.dupe(u8, s.id) } };
                        fields[1] = .{ .name = "expires_at", .value = .{ .int = s.expires_at } };
                        fields[2] = .{ .name = "user_id", .value = .{ .text = try aa.dupe(u8, u.id) } };
                        fields[3] = .{ .name = "name", .value = .{ .text = try aa.dupe(u8, u.name) } };
                        fields[4] = .{ .name = "email", .value = .{ .text = try aa.dupe(u8, u.email) } };
                        fields[5] = .{ .name = "email_verified", .value = .{ .bool_val = u.email_verified } };
                        if (u.image) |img| {
                            fields[6] = .{ .name = "image", .value = .{ .text = try aa.dupe(u8, img) } };
                        } else {
                            fields[6] = .{ .name = "image", .value = .{ .null_val = {} } };
                        }
                        try rows.append(aa, fields);
                        break;
                    }
                    break;
                }
                return db.QueryResult{
                    .rows = try rows.toOwnedSlice(aa),
                    ._arena = arena,
                };
            },

            // ── SELECT from mauth_tokens ───────────────────────────────────────
            .tokens_select_by_hash => {
                const token_hash = paramText(params, 0);
                const purpose = paramText(params, 1);
                const now_unix = paramInt(params, 2);
                var rows: std.ArrayList(db.Row) = .{};
                for (self.tokens.items) |t| {
                    if (!std.mem.eql(u8, t.token_hash, token_hash)) continue;
                    if (!std.mem.eql(u8, t.purpose, purpose)) continue;
                    if (t.used_at != null) continue;
                    if (t.expires_at <= now_unix) continue;
                    const fields = try aa.alloc(db.Field, 3);
                    fields[0] = .{ .name = "id", .value = .{ .text = try aa.dupe(u8, t.id) } };
                    fields[1] = .{ .name = "user_id", .value = .{ .text = try aa.dupe(u8, t.user_id) } };
                    fields[2] = .{ .name = "expires_at", .value = .{ .int = t.expires_at } };
                    try rows.append(aa, fields);
                    break;
                }
                return db.QueryResult{
                    .rows = try rows.toOwnedSlice(aa),
                    ._arena = arena,
                };
            },

            // ── Rate limits: always return count=1 (never limited in tests) ───
            .rate_limits_any => {
                const fields = try aa.alloc(db.Field, 1);
                fields[0] = .{ .name = "count", .value = .{ .int = 1 } };
                const rows = try aa.alloc(db.Row, 1);
                rows[0] = fields;
                return db.QueryResult{
                    .rows = rows,
                    ._arena = arena,
                };
            },

            // ── Unknown / non-returning queries used via query() by mistake ───
            else => {
                std.debug.print("[mem.zig] query: unhandled class={s} sql={s}\n", .{ @tagName(class), sql });
                return db.QueryResult{
                    .rows = &.{},
                    ._arena = arena,
                };
            },
        }
    }

    // ── exec dispatch ──────────────────────────────────────────────────────────

    fn execImpl(
        self: *MemAdapter,
        _: std.mem.Allocator,
        sql: []const u8,
        params: []const db.Value,
    ) !void {
        const class = classify(sql);

        switch (class) {
            // ── INSERT INTO mauth_users ───────────────────────────────────────
            .users_insert => {
                const id = paramText(params, 0);
                const name = paramText(params, 1);
                const email = paramText(params, 2);
                const row = UserRow{
                    .id = try self.alloc.dupe(u8, id),
                    .name = try self.alloc.dupe(u8, name),
                    .email = try self.alloc.dupe(u8, email),
                    .email_verified = false,
                };
                try self.users.append(self.alloc, row);
            },

            // ── UPDATE mauth_users SET email_verified=true ────────────────────
            .users_update_email_verified => {
                const user_id = paramText(params, 0);
                for (self.users.items) |*u| {
                    if (std.mem.eql(u8, u.id, user_id)) {
                        u.email_verified = true;
                        break;
                    }
                }
            },

            // ── INSERT INTO mauth_oauth_accounts ──────────────────────────────
            // SQL: INSERT INTO mauth_oauth_accounts(id, user_id, provider_id, account_id, password_hash, ...)
            // VALUES($1,$2,'email',$3,$4,NOW(),NOW())
            // params: [id, user_id, account_id, password_hash]
            .accounts_insert => {
                const id = paramText(params, 0);
                const user_id = paramText(params, 1);
                const account_id = paramText(params, 2);
                const pw_hash = paramText(params, 3);
                const row = AccountRow{
                    .id = try self.alloc.dupe(u8, id),
                    .user_id = try self.alloc.dupe(u8, user_id),
                    .provider_id = try self.alloc.dupe(u8, "email"),
                    .account_id = try self.alloc.dupe(u8, account_id),
                    .password_hash = if (pw_hash.len > 0) try self.alloc.dupe(u8, pw_hash) else null,
                };
                try self.accounts.append(self.alloc, row);
            },

            // ── UPDATE mauth_oauth_accounts SET password_hash ─────────────────
            .accounts_update_password_hash => {
                const new_hash = paramText(params, 0);
                const user_id = paramText(params, 1);
                for (self.accounts.items) |*a| {
                    if (!std.mem.eql(u8, a.user_id, user_id)) continue;
                    if (!std.mem.eql(u8, a.provider_id, "email")) continue;
                    if (a.password_hash) |h| self.alloc.free(h);
                    a.password_hash = try self.alloc.dupe(u8, new_hash);
                    break;
                }
            },

            // ── INSERT INTO mauth_sessions ────────────────────────────────────
            // params: [id, user_id, token, expires_at_str_or_int]
            .sessions_insert => {
                const id = paramText(params, 0);
                const user_id = paramText(params, 1);
                const token = paramText(params, 2);
                const expires_at = paramInt(params, 3);
                const row = SessionRow{
                    .id = try self.alloc.dupe(u8, id),
                    .user_id = try self.alloc.dupe(u8, user_id),
                    .token = try self.alloc.dupe(u8, token),
                    .expires_at = expires_at,
                };
                try self.sessions.append(self.alloc, row);
            },

            // ── DELETE FROM mauth_sessions WHERE id = $1 ──────────────────────
            .sessions_delete_by_id => {
                const session_id = paramText(params, 0);
                var i: usize = 0;
                while (i < self.sessions.items.len) {
                    const s = self.sessions.items[i];
                    if (std.mem.eql(u8, s.id, session_id)) {
                        self.alloc.free(s.id);
                        self.alloc.free(s.user_id);
                        self.alloc.free(s.token);
                        _ = self.sessions.swapRemove(i);
                    } else {
                        i += 1;
                    }
                }
            },

            // ── DELETE FROM mauth_sessions WHERE user_id=$1 AND id != $2 ──────
            .sessions_delete_others => {
                const user_id = paramText(params, 0);
                const keep_id = paramText(params, 1);
                var i: usize = 0;
                while (i < self.sessions.items.len) {
                    const s = self.sessions.items[i];
                    if (std.mem.eql(u8, s.user_id, user_id) and !std.mem.eql(u8, s.id, keep_id)) {
                        self.alloc.free(s.id);
                        self.alloc.free(s.user_id);
                        self.alloc.free(s.token);
                        _ = self.sessions.swapRemove(i);
                    } else {
                        i += 1;
                    }
                }
            },

            // ── DELETE FROM mauth_sessions WHERE user_id=$1 ───────────────────
            .sessions_delete_by_user => {
                const user_id = paramText(params, 0);
                var i: usize = 0;
                while (i < self.sessions.items.len) {
                    const s = self.sessions.items[i];
                    if (std.mem.eql(u8, s.user_id, user_id)) {
                        self.alloc.free(s.id);
                        self.alloc.free(s.user_id);
                        self.alloc.free(s.token);
                        _ = self.sessions.swapRemove(i);
                    } else {
                        i += 1;
                    }
                }
            },

            // ── UPDATE mauth_sessions SET expires_at ──────────────────────────
            // params: [new_expires_str_or_int, session_id]
            .sessions_update_expires => {
                const new_expires = paramInt(params, 0);
                const session_id = paramText(params, 1);
                for (self.sessions.items) |*s| {
                    if (std.mem.eql(u8, s.id, session_id)) {
                        s.expires_at = new_expires;
                        break;
                    }
                }
            },

            // ── INSERT INTO mauth_tokens ──────────────────────────────────────
            // params: [id, user_id, token_hash_hex, purpose, expires_at_unix]
            .tokens_insert => {
                const id = paramText(params, 0);
                const user_id = paramText(params, 1);
                const token_hash = paramText(params, 2);
                const purpose = paramText(params, 3);
                const expires_at = paramInt(params, 4);
                const row = TokenRow{
                    .id = try self.alloc.dupe(u8, id),
                    .user_id = try self.alloc.dupe(u8, user_id),
                    .token_hash = try self.alloc.dupe(u8, token_hash),
                    .purpose = try self.alloc.dupe(u8, purpose),
                    .expires_at = expires_at,
                };
                try self.tokens.append(self.alloc, row);
            },

            // ── UPDATE mauth_tokens SET used_at=NOW() WHERE id=$1 ────────────
            .tokens_mark_used => {
                const token_id = paramText(params, 0);
                const now_unix = currentUnixSeconds();
                for (self.tokens.items) |*t| {
                    if (std.mem.eql(u8, t.id, token_id)) {
                        t.used_at = now_unix;
                        break;
                    }
                }
            },

            // ── DELETE FROM mauth_tokens WHERE user_id=$1 AND purpose=$2 ──────
            .tokens_delete_by_user_purpose => {
                const user_id = paramText(params, 0);
                const purpose = paramText(params, 1);
                var i: usize = 0;
                while (i < self.tokens.items.len) {
                    const t = self.tokens.items[i];
                    if (std.mem.eql(u8, t.user_id, user_id) and std.mem.eql(u8, t.purpose, purpose)) {
                        self.alloc.free(t.id);
                        self.alloc.free(t.user_id);
                        self.alloc.free(t.token_hash);
                        self.alloc.free(t.purpose);
                        _ = self.tokens.swapRemove(i);
                    } else {
                        i += 1;
                    }
                }
            },

            // ── Rate limits: no-op ────────────────────────────────────────────
            .rate_limits_any => {},

            else => {
                std.debug.print("[mem.zig] exec: unhandled class={s} sql={s}\n", .{ @tagName(class), sql });
            },
        }
    }

    // ── VTable ─────────────────────────────────────────────────────────────────

    fn queryFn(ptr: *anyopaque, alloc: std.mem.Allocator, sql: []const u8, params: []const db.Value) anyerror!db.QueryResult {
        const self: *MemAdapter = @ptrCast(@alignCast(ptr));
        return self.queryImpl(alloc, sql, params);
    }

    fn execFn(ptr: *anyopaque, alloc: std.mem.Allocator, sql: []const u8, params: []const db.Value) anyerror!void {
        const self: *MemAdapter = @ptrCast(@alignCast(ptr));
        return self.execImpl(alloc, sql, params);
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *MemAdapter = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = db.Adapter.VTable{
        .queryFn = queryFn,
        .execFn = execFn,
        .deinitFn = deinitFn,
    };
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "MemAdapter init/deinit" {
    var mem_adapter = MemAdapter.init(std.testing.allocator);
    defer mem_adapter.deinit();
    try std.testing.expectEqual(@as(usize, 0), mem_adapter.sessionCount());
    try std.testing.expectEqual(@as(usize, 0), mem_adapter.tokenCount());
}

test "MemAdapter users_insert then select by email" {
    var mem_adapter = MemAdapter.init(std.testing.allocator);
    defer mem_adapter.deinit();
    const a = mem_adapter.adapter();

    try a.exec(std.testing.allocator,
        "INSERT INTO mauth_users(id, name, email, email_verified, created_at, updated_at) VALUES($1,$2,$3,false,NOW(),NOW())",
        &.{ .{ .text = "uid-1" }, .{ .text = "Alice" }, .{ .text = "alice@test.com" } },
    );

    var result = try a.query(std.testing.allocator,
        "SELECT id FROM mauth_users WHERE email = $1",
        &.{.{ .text = "alice@test.com" }},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqualStrings("uid-1", db.rowText(result.rows[0], "id").?);
}

test "MemAdapter sessions_insert then sessionCount" {
    var mem_adapter = MemAdapter.init(std.testing.allocator);
    defer mem_adapter.deinit();
    const a = mem_adapter.adapter();

    try a.exec(std.testing.allocator,
        "INSERT INTO mauth_sessions(id, user_id, token, expires_at, created_at, updated_at) VALUES($1,$2,$3,to_timestamp($4),NOW(),NOW())",
        &.{ .{ .text = "sess-1" }, .{ .text = "uid-1" }, .{ .text = "tok-1" }, .{ .text = "9999999999" } },
    );
    try std.testing.expectEqual(@as(usize, 1), mem_adapter.sessionCount());
}

test "MemAdapter rate_limits always returns count=1" {
    var mem_adapter = MemAdapter.init(std.testing.allocator);
    defer mem_adapter.deinit();
    const a = mem_adapter.adapter();

    var result = try a.query(std.testing.allocator,
        \\INSERT INTO mauth_rate_limits (key, count, window_start) VALUES ($1, 1, NOW())
        \\ON CONFLICT (key) DO UPDATE SET count = 1 RETURNING count
    ,
        &.{ .{ .text = "some-hash" }, .{ .text = "900" } },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(@as(i64, 1), db.rowInt(result.rows[0], "count").?);
}
