//! Neon PostgreSQL HTTP adapter for merjs-auth.
//!
//! Implements `db.Adapter` by posting queries to the Neon serverless HTTP API:
//!   POST {database_url}/sql
//!   Authorization: Bearer {api_key}
//!   {"query": "SELECT ...", "params": ["v1", "v2"]}
//!
//! Response shape:
//!   {"command":"SELECT","rowCount":1,
//!    "rows":[{"id":"abc","email":"x@y.z"}],
//!    "fields":[{"name":"id","dataTypeID":25},{"name":"email","dataTypeID":25}]}
//!
//! On Cloudflare Workers `std.http.Client` is unavailable (freestanding target).
//! Callers MUST supply `NeonConfig.fetch_fn`.  The native dev-server path falls
//! back to `std.http.Client` when `fetch_fn` is null and the target is not
//! freestanding.

const std = @import("std");
const db = @import("root.zig");

// ── Config ─────────────────────────────────────────────────────────────────

pub const NeonConfig = struct {
    /// Neon database URL, e.g. "https://ep-cool-sound-123456.us-east-2.aws.neon.tech"
    /// The SQL endpoint will be {database_url}/sql
    database_url: []const u8,
    /// API key used in "Authorization: Bearer {api_key}"
    api_key: []const u8,
    /// HTTP fetch function required on Workers; set null for native dev only.
    fetch_fn: ?db.FetchFn = null,
};

// ── Neon JSON wire types ────────────────────────────────────────────────────

/// Minimal Neon field descriptor (from "fields" array in the response).
const NeonFieldDesc = struct {
    name: []const u8,
    dataTypeID: i64 = 0,
};

// ── Adapter ────────────────────────────────────────────────────────────────

pub const NeonAdapter = struct {
    config: NeonConfig,
    /// Backing allocator for the adapter itself (not for query results).
    alloc: std.mem.Allocator,

    const vtable = db.Adapter.VTable{
        .queryFn = queryImpl,
        .execFn = execImpl,
        .deinitFn = deinitImpl,
    };

    pub fn init(alloc: std.mem.Allocator, config: NeonConfig) NeonAdapter {
        return .{ .config = config, .alloc = alloc };
    }

    /// Returns a `db.Adapter` vtable wrapping this NeonAdapter.
    /// The NeonAdapter must outlive the returned Adapter.
    pub fn adapter(self: *NeonAdapter) db.Adapter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ── vtable implementations ──────────────────────────────────────────────

    fn queryImpl(
        ptr: *anyopaque,
        alloc: std.mem.Allocator,
        sql: []const u8,
        params: []const db.Value,
    ) anyerror!db.QueryResult {
        const self: *NeonAdapter = @ptrCast(@alignCast(ptr));
        const body_bytes = try self.buildRequestBody(alloc, sql, params);
        defer alloc.free(body_bytes);

        const resp_bytes = try self.doFetch(alloc, body_bytes);
        defer alloc.free(resp_bytes);

        return parseQueryResult(alloc, resp_bytes);
    }

    fn execImpl(
        ptr: *anyopaque,
        alloc: std.mem.Allocator,
        sql: []const u8,
        params: []const db.Value,
    ) anyerror!void {
        const self: *NeonAdapter = @ptrCast(@alignCast(ptr));
        const body_bytes = try self.buildRequestBody(alloc, sql, params);
        defer alloc.free(body_bytes);

        const resp_bytes = try self.doFetch(alloc, body_bytes);
        alloc.free(resp_bytes);
    }

    fn deinitImpl(_: *anyopaque) void {}

    // ── Helpers ────────────────────────────────────────────────────────────

    /// Build the JSON request body: {"query": sql, "params": [...]}
    fn buildRequestBody(
        self: *NeonAdapter,
        alloc: std.mem.Allocator,
        sql: []const u8,
        params: []const db.Value,
    ) ![]u8 {
        _ = self;

        // Build a JSON params array from db.Value slice.
        var json_params: std.ArrayList(std.json.Value) = .{};
        defer json_params.deinit(alloc);

        for (params) |p| {
            const jv: std.json.Value = switch (p) {
                .null_val => .null,
                .text => |s| .{ .string = s },
                .int => |n| .{ .integer = n },
                .float => |f| .{ .float = f },
                .bool_val => |b| .{ .bool = b },
                .bytes => |b| .{ .string = b }, // treat bytes as text for SQL params
            };
            try json_params.append(alloc, jv);
        }

        var obj = std.json.ObjectMap.init(alloc);
        defer obj.deinit();
        try obj.put("query", .{ .string = sql });
        try obj.put("params", .{ .array = json_params });

        return std.json.stringifyAlloc(alloc, std.json.Value{ .object = obj }, .{});
    }

    /// POST to the Neon SQL endpoint; returns the response body (caller owns).
    fn doFetch(self: *NeonAdapter, alloc: std.mem.Allocator, body: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(alloc, "{s}/sql", .{self.config.database_url});
        defer alloc.free(url);

        const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{self.config.api_key});
        defer alloc.free(auth_header);

        const headers = &[_][2][]const u8{
            .{ "Content-Type", "application/json" },
            .{ "Authorization", auth_header },
        };

        if (self.config.fetch_fn) |fetch| {
            var result = try fetch(alloc, url, "POST", headers, body);
            defer result.deinit();
            if (result.status < 200 or result.status >= 300) {
                std.debug.print("[neon] HTTP error {d}: {s}\n", .{ result.status, result.body });
                return error.NeonHttpError;
            }
            return alloc.dupe(u8, result.body);
        } else {
            return nativeFetch(alloc, url, body, auth_header);
        }
    }
};

// ── Native HTTP fallback (non-freestanding only) ────────────────────────────

fn nativeFetch(
    alloc: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    auth_header: []const u8,
) ![]u8 {
    if (comptime @import("builtin").target.isWasm()) {
        unreachable; // Workers must supply fetch_fn
    }

    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var header_buf: [8192]u8 = undefined;
    var req = try client.open(.POST, uri, .{ .server_header_buffer = &header_buf });
    defer req.deinit();

    try req.headers.append("Content-Type", "application/json");
    try req.headers.append("Authorization", auth_header);

    req.transfer_encoding = .{ .content_length = body.len };
    try req.send();
    try req.writeAll(body);
    try req.finish();
    try req.wait();

    const status: u16 = @intFromEnum(req.response.status);
    const resp_body = try req.reader().readAllAlloc(alloc, 16 * 1024 * 1024);
    if (status < 200 or status >= 300) {
        alloc.free(resp_body);
        std.debug.print("[neon] HTTP error {d}\n", .{status});
        return error.NeonHttpError;
    }
    return resp_body;
}

// ── Response parsing ───────────────────────────────────────────────────────

/// Parse the Neon JSON response into a `db.QueryResult`.
/// All row memory lives in an arena; call `result.deinit()` to free.
fn parseQueryResult(backing_alloc: std.mem.Allocator, json_bytes: []const u8) !db.QueryResult {
    var arena = std.heap.ArenaAllocator.init(backing_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    // Parse raw JSON.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        json_bytes,
        .{ .ignore_unknown_fields = true },
    );
    // parsed.value lives in arena — no separate deinit needed after arena takeover.

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NeonBadResponse,
    };

    // Build ordered column name list from "fields".
    const fields_json = root_obj.get("fields") orelse std.json.Value{ .array = .{} };
    const fields_arr = switch (fields_json) {
        .array => |a| a,
        else => return error.NeonBadResponse,
    };

    var col_names: std.ArrayList([]const u8) = .{};
    defer col_names.deinit(alloc);
    for (fields_arr.items) |fv| {
        const fobj = switch (fv) {
            .object => |o| o,
            else => return error.NeonBadResponse,
        };
        const name_val = fobj.get("name") orelse return error.NeonBadResponse;
        const name = switch (name_val) {
            .string => |s| s,
            else => return error.NeonBadResponse,
        };
        try col_names.append(alloc, name);
    }

    // Extract rows.
    const rows_json = root_obj.get("rows") orelse std.json.Value{ .array = .{} };
    const rows_arr = switch (rows_json) {
        .array => |a| a,
        else => return error.NeonBadResponse,
    };

    // Build db.Row slice.  Each db.Row = []const db.Field where
    // db.Field = struct { name: []const u8, value: db.Value }.
    const db_rows = try alloc.alloc(db.Row, rows_arr.items.len);
    for (rows_arr.items, 0..) |row_val, ri| {
        const row_obj = switch (row_val) {
            .object => |o| o,
            else => return error.NeonBadResponse,
        };

        const db_fields = try alloc.alloc(db.Field, col_names.items.len);
        for (col_names.items, 0..) |col, ci| {
            const cell = row_obj.get(col) orelse std.json.Value.null;
            db_fields[ci] = .{
                .name = col,
                .value = jsonValueToDb(cell),
            };
        }
        db_rows[ri] = db_fields;
    }

    return db.QueryResult{
        .rows = db_rows,
        ._arena = arena,
    };
}

/// Map a `std.json.Value` to a `db.Value`.
fn jsonValueToDb(v: std.json.Value) db.Value {
    return switch (v) {
        .null => .{ .null_val = {} },
        .bool => |b| .{ .bool_val = b },
        .integer => |n| .{ .int = n },
        .float => |f| .{ .float = f },
        .string => |s| .{ .text = s },
        .array, .object => .{ .null_val = {} },
        .number_string => |s| blk: {
            if (std.fmt.parseInt(i64, s, 10)) |n| break :blk .{ .int = n } else |_| {}
            if (std.fmt.parseFloat(f64, s)) |f| break :blk .{ .float = f } else |_| {}
            break :blk .{ .text = s };
        },
    };
}

// ── Connection-string parser ───────────────────────────────────────────────

/// Parse a PostgreSQL connection string and return a `NeonAdapter`.
///
///   postgresql://user:password@host/dbname?sslmode=require
///
/// The Neon HTTP URL is built as `https://{host}`.
/// `api_key` is taken from the password field of the connection string.
pub fn fromConnectionString(
    alloc: std.mem.Allocator,
    conn_str: []const u8,
    fetch_fn: ?db.FetchFn,
) !NeonAdapter {
    const without_scheme = blk: {
        const prefix = "postgresql://";
        const prefix2 = "postgres://";
        if (std.mem.startsWith(u8, conn_str, prefix)) break :blk conn_str[prefix.len..];
        if (std.mem.startsWith(u8, conn_str, prefix2)) break :blk conn_str[prefix2.len..];
        return error.InvalidConnectionString;
    };

    const at_pos = std.mem.indexOf(u8, without_scheme, "@") orelse
        return error.InvalidConnectionString;
    const userinfo = without_scheme[0..at_pos];
    const after_at = without_scheme[at_pos + 1 ..];

    const colon_pos = std.mem.indexOf(u8, userinfo, ":") orelse
        return error.InvalidConnectionString;
    const api_key_raw = userinfo[colon_pos + 1 ..];

    const slash_pos = std.mem.indexOf(u8, after_at, "/") orelse after_at.len;
    var host = after_at[0..slash_pos];
    if (std.mem.indexOf(u8, host, "?")) |q| host = host[0..q];

    const database_url = try std.fmt.allocPrint(alloc, "https://{s}", .{host});
    errdefer alloc.free(database_url);
    const api_key = try alloc.dupe(u8, api_key_raw);
    errdefer alloc.free(api_key);

    return NeonAdapter.init(alloc, .{
        .database_url = database_url,
        .api_key = api_key,
        .fetch_fn = fetch_fn,
    });
}
