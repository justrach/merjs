//! In-memory database adapter for merjs-auth testing.
//!
//! Implements the `db.Adapter` vtable by storing typed rows in Zig ArrayLists.
//! SQL queries are dispatched by pattern-matching on keywords in the SQL string.
//! All stored strings are owned copies (duped into `alloc`).

const std = @import("std");
const db = @import("root.zig");

/// Get current Unix timestamp in seconds, reporting clock errors.
fn currentUnixSeconds() !i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return error.ClockFailed;
    const seconds = std.math.cast(i64, ts.sec) orelse return error.ClockFailed;
    if (seconds < 0) return error.ClockFailed;
    return seconds;
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
    // Atomic signup and token consumption + protected durable side effect
    signup_user_and_account,
    consume_reset_password,
    consume_verify_email,
    consume_magic_link,

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

    // Data-modifying CTEs must be classified before their component tables.
    if (has(u8, sql, "WITH inserted_user AS") != null and
        has(u8, sql, "INSERT INTO mauth_oauth_accounts") != null)
    {
        return .signup_user_and_account;
    }
    if (has(u8, sql, "WITH consumed AS") != null) {
        if (has(u8, sql, "UPDATE mauth_oauth_accounts") != null) return .consume_reset_password;
        if (has(u8, sql, "INSERT INTO mauth_sessions") != null) return .consume_magic_link;
        if (has(u8, sql, "UPDATE mauth_users") != null) return .consume_verify_email;
    }

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

fn tokenPurpose(sql: []const u8) []const u8 {
    if (std.mem.indexOf(u8, sql, "email_verify") != null) return "email_verify";
    if (std.mem.indexOf(u8, sql, "password_reset") != null) return "password_reset";
    if (std.mem.indexOf(u8, sql, "magic_link") != null) return "magic_link";
    return "";
}

// ── MemAdapter ─────────────────────────────────────────────────────────────

pub const MemAdapter = struct {
    alloc: std.mem.Allocator,
    mutex: std.atomic.Mutex,
    users: std.ArrayList(UserRow),
    accounts: std.ArrayList(AccountRow),
    sessions: std.ArrayList(SessionRow),
    tokens: std.ArrayList(TokenRow),
    rate_limits: std.ArrayList(RateLimitRow),
    fail_next_atomic: bool,

    pub fn init(alloc: std.mem.Allocator) MemAdapter {
        return .{
            .alloc = alloc,
            .mutex = .unlocked,
            .users = .empty,
            .accounts = .empty,
            .sessions = .empty,
            .tokens = .empty,
            .rate_limits = .empty,
            .fail_next_atomic = false,
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

    /// Inject a transient failure into the next atomic operation.
    pub fn failNextAtomic(self: *MemAdapter) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        self.fail_next_atomic = true;
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
        errdefer arena.deinit();
        const aa = arena.allocator();

        switch (class) {
            // ── Atomic reset token + password update + session revocation ────
            .consume_reset_password => {
                if (self.fail_next_atomic) {
                    self.fail_next_atomic = false;
                    return error.InjectedFailure;
                }
                const token_hash = paramText(params, 0);
                const purpose = paramText(params, 1);
                const new_hash = paramText(params, 2);
                const now_unix = try currentUnixSeconds();
                var token: ?*TokenRow = null;
                for (self.tokens.items) |*t| {
                    if (std.mem.eql(u8, t.token_hash, token_hash) and
                        std.mem.eql(u8, t.purpose, purpose) and t.used_at == null and t.expires_at > now_unix)
                    {
                        token = t;
                        break;
                    }
                }
                const claimed = token orelse return db.QueryResult{ .rows = &.{}, ._arena = arena };
                var account: ?*AccountRow = null;
                for (self.accounts.items) |*a| {
                    if (std.mem.eql(u8, a.user_id, claimed.user_id) and std.mem.eql(u8, a.provider_id, "email")) {
                        account = a;
                        break;
                    }
                }
                const updated = account orelse return db.QueryResult{ .rows = &.{}, ._arena = arena };

                const stored_hash = try self.alloc.dupe(u8, new_hash);
                errdefer self.alloc.free(stored_hash);
                const fields = try aa.alloc(db.Field, 1);
                fields[0] = .{ .name = "user_id", .value = .{ .text = try aa.dupe(u8, claimed.user_id) } };
                const rows = try aa.alloc(db.Row, 1);
                rows[0] = fields;

                if (updated.password_hash) |old_hash| self.alloc.free(old_hash);
                updated.password_hash = stored_hash;
                claimed.used_at = now_unix;
                var i: usize = 0;
                while (i < self.sessions.items.len) {
                    const s = self.sessions.items[i];
                    if (std.mem.eql(u8, s.user_id, claimed.user_id)) {
                        self.alloc.free(s.id);
                        self.alloc.free(s.user_id);
                        self.alloc.free(s.token);
                        _ = self.sessions.swapRemove(i);
                    } else i += 1;
                }
                return db.QueryResult{ .rows = rows, ._arena = arena };
            },

            // ── Atomic verification token + user update ──────────────────────
            .consume_verify_email => {
                if (self.fail_next_atomic) {
                    self.fail_next_atomic = false;
                    return error.InjectedFailure;
                }
                const token_hash = paramText(params, 0);
                const purpose = paramText(params, 1);
                const now_unix = try currentUnixSeconds();
                var token: ?*TokenRow = null;
                for (self.tokens.items) |*t| {
                    if (std.mem.eql(u8, t.token_hash, token_hash) and
                        std.mem.eql(u8, t.purpose, purpose) and t.used_at == null and t.expires_at > now_unix)
                    {
                        token = t;
                        break;
                    }
                }
                const claimed = token orelse return db.QueryResult{ .rows = &.{}, ._arena = arena };
                var user: ?*UserRow = null;
                for (self.users.items) |*u| {
                    if (std.mem.eql(u8, u.id, claimed.user_id)) {
                        user = u;
                        break;
                    }
                }
                const verified = user orelse return db.QueryResult{ .rows = &.{}, ._arena = arena };
                const fields = try aa.alloc(db.Field, 1);
                fields[0] = .{ .name = "user_id", .value = .{ .text = try aa.dupe(u8, claimed.user_id) } };
                const rows = try aa.alloc(db.Row, 1);
                rows[0] = fields;

                claimed.used_at = now_unix;
                verified.email_verified = true;
                return db.QueryResult{ .rows = rows, ._arena = arena };
            },

            // ── Atomic magic-link token + verification + session insert ──────
            .consume_magic_link => {
                if (self.fail_next_atomic) {
                    self.fail_next_atomic = false;
                    return error.InjectedFailure;
                }
                const token_hash = paramText(params, 0);
                const purpose = paramText(params, 1);
                const now_unix = try currentUnixSeconds();
                var token: ?*TokenRow = null;
                for (self.tokens.items) |*t| {
                    if (std.mem.eql(u8, t.token_hash, token_hash) and
                        std.mem.eql(u8, t.purpose, purpose) and t.used_at == null and t.expires_at > now_unix)
                    {
                        token = t;
                        break;
                    }
                }
                const claimed = token orelse return db.QueryResult{ .rows = &.{}, ._arena = arena };
                var user: ?*UserRow = null;
                for (self.users.items) |*u| {
                    if (std.mem.eql(u8, u.id, claimed.user_id)) {
                        user = u;
                        break;
                    }
                }
                const verified = user orelse return db.QueryResult{ .rows = &.{}, ._arena = arena };

                const session_id = try self.alloc.dupe(u8, paramText(params, 2));
                errdefer self.alloc.free(session_id);
                const session_user_id = try self.alloc.dupe(u8, claimed.user_id);
                errdefer self.alloc.free(session_user_id);
                const session_token = try self.alloc.dupe(u8, paramText(params, 3));
                errdefer self.alloc.free(session_token);
                const fields = try aa.alloc(db.Field, 1);
                fields[0] = .{ .name = "user_id", .value = .{ .text = try aa.dupe(u8, claimed.user_id) } };
                const rows = try aa.alloc(db.Row, 1);
                rows[0] = fields;
                try self.sessions.ensureUnusedCapacity(self.alloc, 1);

                self.sessions.appendAssumeCapacity(.{
                    .id = session_id,
                    .user_id = session_user_id,
                    .token = session_token,
                    .expires_at = paramInt(params, 4),
                });
                claimed.used_at = now_unix;
                verified.email_verified = true;
                return db.QueryResult{ .rows = rows, ._arena = arena };
            },

            // ── SELECT id FROM mauth_users WHERE email = $1 ──────────────────
            .users_select_id_by_email => {
                const email = paramText(params, 0);
                var rows: std.ArrayList(db.Row) = .empty;
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
                var rows: std.ArrayList(db.Row) = .empty;
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
                var rows: std.ArrayList(db.Row) = .empty;
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
                var rows: std.ArrayList(db.Row) = .empty;
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

            // ── Atomically consume a token with UPDATE ... RETURNING ──────────
            .tokens_mark_used => {
                const token_hash = paramText(params, 0);
                const purpose = paramText(params, 1);
                const now_unix = try currentUnixSeconds();
                var rows: std.ArrayList(db.Row) = .empty;
                for (self.tokens.items) |*t| {
                    if (!std.mem.eql(u8, t.token_hash, token_hash)) continue;
                    if (!std.mem.eql(u8, t.purpose, purpose)) continue;
                    if (t.used_at != null or t.expires_at <= now_unix) continue;
                    t.used_at = now_unix;
                    const fields = try aa.alloc(db.Field, 1);
                    fields[0] = .{ .name = "user_id", .value = .{ .text = try aa.dupe(u8, t.user_id) } };
                    try rows.append(aa, fields);
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
                var rows: std.ArrayList(db.Row) = .empty;
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
            // ── Atomic signup user + email account insert ────────────────────
            .signup_user_and_account => {
                if (self.fail_next_atomic) {
                    self.fail_next_atomic = false;
                    return error.InjectedFailure;
                }

                const user_id = paramText(params, 0);
                const name = paramText(params, 1);
                const email = paramText(params, 2);
                const account_id = paramText(params, 3);
                const pw_hash = paramText(params, 4);
                for (self.users.items) |user| {
                    if (std.mem.eql(u8, user.id, user_id) or std.mem.eql(u8, user.email, email))
                        return error.UniqueConstraint;
                }
                for (self.accounts.items) |account| {
                    if (std.mem.eql(u8, account.id, account_id) or
                        (std.mem.eql(u8, account.provider_id, "email") and std.mem.eql(u8, account.account_id, email)))
                    {
                        return error.UniqueConstraint;
                    }
                }

                const stored_user_id = try self.alloc.dupe(u8, user_id);
                errdefer self.alloc.free(stored_user_id);
                const stored_name = try self.alloc.dupe(u8, name);
                errdefer self.alloc.free(stored_name);
                const stored_email = try self.alloc.dupe(u8, email);
                errdefer self.alloc.free(stored_email);
                const stored_account_id = try self.alloc.dupe(u8, account_id);
                errdefer self.alloc.free(stored_account_id);
                const account_user_id = try self.alloc.dupe(u8, user_id);
                errdefer self.alloc.free(account_user_id);
                const provider_id = try self.alloc.dupe(u8, "email");
                errdefer self.alloc.free(provider_id);
                const provider_account_id = try self.alloc.dupe(u8, email);
                errdefer self.alloc.free(provider_account_id);
                const stored_hash = try self.alloc.dupe(u8, pw_hash);
                errdefer self.alloc.free(stored_hash);
                try self.users.ensureUnusedCapacity(self.alloc, 1);
                try self.accounts.ensureUnusedCapacity(self.alloc, 1);

                self.users.appendAssumeCapacity(.{
                    .id = stored_user_id,
                    .name = stored_name,
                    .email = stored_email,
                    .email_verified = false,
                });
                self.accounts.appendAssumeCapacity(.{
                    .id = stored_account_id,
                    .user_id = account_user_id,
                    .provider_id = provider_id,
                    .account_id = provider_account_id,
                    .password_hash = stored_hash,
                });
            },

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
            // Handlers use a purpose literal and params [id, user_id, hash, expiry].
            .tokens_insert => {
                const id = paramText(params, 0);
                const user_id = paramText(params, 1);
                const token_hash = paramText(params, 2);
                const purpose = tokenPurpose(sql);
                const expires_at = paramInt(params, 3);
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
                const now_unix = try currentUnixSeconds();
                for (self.tokens.items) |*t| {
                    if (std.mem.eql(u8, t.id, token_id)) {
                        t.used_at = now_unix;
                        break;
                    }
                }
            },

            // ── DELETE FROM mauth_tokens WHERE user_id=$1 AND purpose='...' ───
            .tokens_delete_by_user_purpose => {
                const user_id = paramText(params, 0);
                const purpose = tokenPurpose(sql);
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
        while (!self.mutex.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return self.queryImpl(alloc, sql, params);
    }

    fn execFn(ptr: *anyopaque, alloc: std.mem.Allocator, sql: []const u8, params: []const db.Value) anyerror!void {
        const self: *MemAdapter = @ptrCast(@alignCast(ptr));
        while (!self.mutex.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
        defer self.mutex.unlock();
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

    try a.exec(
        std.testing.allocator,
        "INSERT INTO mauth_users(id, name, email, email_verified, created_at, updated_at) VALUES($1,$2,$3,false,NOW(),NOW())",
        &.{ .{ .text = "uid-1" }, .{ .text = "Alice" }, .{ .text = "alice@test.com" } },
    );

    var result = try a.query(
        std.testing.allocator,
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

    try a.exec(
        std.testing.allocator,
        "INSERT INTO mauth_sessions(id, user_id, token, expires_at, created_at, updated_at) VALUES($1,$2,$3,to_timestamp($4),NOW(),NOW())",
        &.{ .{ .text = "sess-1" }, .{ .text = "uid-1" }, .{ .text = "tok-1" }, .{ .text = "9999999999" } },
    );
    try std.testing.expectEqual(@as(usize, 1), mem_adapter.sessionCount());
}

test "MemAdapter rate_limits always returns count=1" {
    var mem_adapter = MemAdapter.init(std.testing.allocator);
    defer mem_adapter.deinit();
    const a = mem_adapter.adapter();

    var result = try a.query(
        std.testing.allocator,
        \\INSERT INTO mauth_rate_limits (key, count, window_start) VALUES ($1, 1, NOW())
        \\ON CONFLICT (key) DO UPDATE SET count = 1 RETURNING count
    ,
        &.{ .{ .text = "some-hash" }, .{ .text = "900" } },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(@as(i64, 1), db.rowInt(result.rows[0], "count").?);
}

const ConsumeThread = struct {
    adapter: db.Adapter,
    token_hash: []const u8,
    purpose: []const u8,
    succeeded: *bool,

    fn run(args: ConsumeThread) void {
        var result = args.adapter.query(std.heap.page_allocator,
            \\UPDATE mauth_tokens
            \\SET used_at = NOW()
            \\WHERE token_hash = $1
            \\  AND purpose = $2
            \\  AND used_at IS NULL
            \\  AND expires_at > NOW()
            \\RETURNING user_id
        , &.{
            .{ .text = args.token_hash },
            .{ .text = args.purpose },
        }) catch return;
        defer result.deinit();
        args.succeeded.* = result.rows.len == 1;
    }
};

fn expectOnlyOneConcurrentConsumer(purpose: []const u8) !void {
    var mem_adapter = MemAdapter.init(std.testing.allocator);
    defer mem_adapter.deinit();
    const adapter = mem_adapter.adapter();
    const expires_at = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{try currentUnixSeconds() + 3600});
    defer std.testing.allocator.free(expires_at);
    const insert_sql = try std.fmt.allocPrint(
        std.testing.allocator,
        "INSERT INTO mauth_tokens(id,user_id,token_hash,purpose,expires_at) VALUES($1,$2,$3,'{s}',to_timestamp($4))",
        .{purpose},
    );
    defer std.testing.allocator.free(insert_sql);
    try adapter.exec(std.testing.allocator, insert_sql, &.{
        .{ .text = "token-id" },
        .{ .text = "user-id" },
        .{ .text = "token-hash" },
        .{ .text = expires_at },
    });

    var succeeded = [_]bool{ false, false };
    const first = try std.Thread.spawn(.{}, ConsumeThread.run, .{ConsumeThread{
        .adapter = adapter,
        .token_hash = "token-hash",
        .purpose = purpose,
        .succeeded = &succeeded[0],
    }});
    const second = try std.Thread.spawn(.{}, ConsumeThread.run, .{ConsumeThread{
        .adapter = adapter,
        .token_hash = "token-hash",
        .purpose = purpose,
        .succeeded = &succeeded[1],
    }});
    first.join();
    second.join();

    try std.testing.expect(succeeded[0] != succeeded[1]);
}

test "email verification token has only one concurrent consumer" {
    try expectOnlyOneConcurrentConsumer("email_verify");
}

test "password reset token has only one concurrent consumer" {
    try expectOnlyOneConcurrentConsumer("password_reset");
}

test "magic-link token has only one concurrent consumer" {
    try expectOnlyOneConcurrentConsumer("magic_link");
}

const SIGNUP_ATOMIC_SQL =
    \\WITH inserted_user AS (
    \\  INSERT INTO mauth_users(id,name,email,email_verified) VALUES($1,$2,$3,false) RETURNING id
    \\)
    \\INSERT INTO mauth_oauth_accounts(id,user_id,provider_id,account_id,password_hash)
    \\SELECT $4,id,'email',$3,$5 FROM inserted_user
;

fn insertSignup(adapter: db.Adapter, user_id: []const u8, account_id: []const u8) !void {
    try adapter.exec(std.testing.allocator, SIGNUP_ATOMIC_SQL, &.{
        .{ .text = user_id },
        .{ .text = "Alice" },
        .{ .text = "alice@test.com" },
        .{ .text = account_id },
        .{ .text = "password-hash" },
    });
}

test "atomic signup failure leaves no user and can be retried" {
    var mem_adapter = MemAdapter.init(std.testing.allocator);
    defer mem_adapter.deinit();
    const adapter = mem_adapter.adapter();

    mem_adapter.failNextAtomic();
    try std.testing.expectError(error.InjectedFailure, insertSignup(adapter, "user-1", "account-1"));
    try std.testing.expectEqual(@as(usize, 0), mem_adapter.users.items.len);
    try std.testing.expectEqual(@as(usize, 0), mem_adapter.accounts.items.len);

    try insertSignup(adapter, "user-1", "account-1");
    try std.testing.expectEqual(@as(usize, 1), mem_adapter.users.items.len);
    try std.testing.expectEqual(@as(usize, 1), mem_adapter.accounts.items.len);
}

const AtomicSignupThread = struct {
    adapter: db.Adapter,
    user_id: []const u8,
    account_id: []const u8,
    succeeded: *bool,

    fn run(args: AtomicSignupThread) void {
        insertSignup(args.adapter, args.user_id, args.account_id) catch return;
        args.succeeded.* = true;
    }
};

test "atomic signup has one concurrent email owner without a stranded user" {
    var mem_adapter = MemAdapter.init(std.testing.allocator);
    defer mem_adapter.deinit();
    const adapter = mem_adapter.adapter();

    var succeeded = [_]bool{ false, false };
    const first = try std.Thread.spawn(.{}, AtomicSignupThread.run, .{AtomicSignupThread{
        .adapter = adapter,
        .user_id = "user-1",
        .account_id = "account-1",
        .succeeded = &succeeded[0],
    }});
    const second = try std.Thread.spawn(.{}, AtomicSignupThread.run, .{AtomicSignupThread{
        .adapter = adapter,
        .user_id = "user-2",
        .account_id = "account-2",
        .succeeded = &succeeded[1],
    }});
    first.join();
    second.join();

    try std.testing.expect(succeeded[0] != succeeded[1]);
    try std.testing.expectEqual(@as(usize, 1), mem_adapter.users.items.len);
    try std.testing.expectEqual(@as(usize, 1), mem_adapter.accounts.items.len);
    try std.testing.expectEqualStrings(mem_adapter.users.items[0].id, mem_adapter.accounts.items[0].user_id);
}

const MAGIC_LINK_ATOMIC_SQL =
    \\WITH consumed AS (UPDATE mauth_tokens SET used_at=NOW() RETURNING user_id),
    \\verified AS (UPDATE mauth_users SET email_verified=true RETURNING id),
    \\inserted AS (INSERT INTO mauth_sessions(id,user_id,token,expires_at) SELECT $3,user_id,$4,$5 FROM verified)
    \\SELECT user_id FROM inserted
;

fn seedMagicLink(adapter: db.Adapter) !void {
    try adapter.exec(
        std.testing.allocator,
        "INSERT INTO mauth_users(id,name,email,email_verified) VALUES($1,$2,$3,false)",
        &.{ .{ .text = "user-id" }, .{ .text = "Alice" }, .{ .text = "alice@test.com" } },
    );
    const expires_at = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{try currentUnixSeconds() + 3600});
    defer std.testing.allocator.free(expires_at);
    try adapter.exec(
        std.testing.allocator,
        "INSERT INTO mauth_tokens(id,user_id,token_hash,purpose,expires_at) VALUES($1,$2,$3,'magic_link',to_timestamp($4))",
        &.{ .{ .text = "token-id" }, .{ .text = "user-id" }, .{ .text = "token-hash" }, .{ .text = expires_at } },
    );
}

fn consumeMagicLink(adapter: db.Adapter, session_id: []const u8) !db.QueryResult {
    return adapter.query(std.testing.allocator, MAGIC_LINK_ATOMIC_SQL, &.{
        .{ .text = "token-hash" },
        .{ .text = "magic_link" },
        .{ .text = session_id },
        .{ .text = "session-token" },
        .{ .text = "9999999999" },
    });
}

test "atomic magic-link failure rolls back and token can be retried" {
    var mem_adapter = MemAdapter.init(std.testing.allocator);
    defer mem_adapter.deinit();
    const adapter = mem_adapter.adapter();
    try seedMagicLink(adapter);

    mem_adapter.failNextAtomic();
    try std.testing.expectError(error.InjectedFailure, consumeMagicLink(adapter, "session-1"));
    try std.testing.expect(mem_adapter.tokens.items[0].used_at == null);
    try std.testing.expect(!mem_adapter.users.items[0].email_verified);
    try std.testing.expectEqual(@as(usize, 0), mem_adapter.sessionCount());

    var retried = try consumeMagicLink(adapter, "session-1");
    defer retried.deinit();
    try std.testing.expectEqual(@as(usize, 1), retried.rows.len);
    try std.testing.expect(mem_adapter.tokens.items[0].used_at != null);
    try std.testing.expect(mem_adapter.users.items[0].email_verified);
    try std.testing.expectEqual(@as(usize, 1), mem_adapter.sessionCount());
}

const AtomicMagicLinkThread = struct {
    adapter: db.Adapter,
    session_id: []const u8,
    succeeded: *bool,

    fn run(args: AtomicMagicLinkThread) void {
        var result = consumeMagicLink(args.adapter, args.session_id) catch return;
        defer result.deinit();
        args.succeeded.* = result.rows.len == 1;
    }
};

test "atomic magic-link has one concurrent session-creating consumer" {
    var mem_adapter = MemAdapter.init(std.testing.allocator);
    defer mem_adapter.deinit();
    const adapter = mem_adapter.adapter();
    try seedMagicLink(adapter);

    var succeeded = [_]bool{ false, false };
    const first = try std.Thread.spawn(.{}, AtomicMagicLinkThread.run, .{AtomicMagicLinkThread{
        .adapter = adapter,
        .session_id = "session-1",
        .succeeded = &succeeded[0],
    }});
    const second = try std.Thread.spawn(.{}, AtomicMagicLinkThread.run, .{AtomicMagicLinkThread{
        .adapter = adapter,
        .session_id = "session-2",
        .succeeded = &succeeded[1],
    }});
    first.join();
    second.join();

    try std.testing.expect(succeeded[0] != succeeded[1]);
    try std.testing.expectEqual(@as(usize, 1), mem_adapter.sessionCount());
}
