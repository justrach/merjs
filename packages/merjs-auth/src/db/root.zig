//! Database abstraction layer for merjs-auth.
//!
//! Provides a vtable-based `Adapter` interface so the same auth logic works
//! with any backing store (Postgres via Hyperdrive, D1, a test double, etc.).
//! Adapters are provided by the application, not by this library.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Value ──────────────────────────────────────────────────────────────────

/// A typed SQL column value. Maps loosely to PostgreSQL / SQLite wire types.
pub const Value = union(enum) {
    null_val: void,
    text: []const u8,
    int: i64,
    float: f64,
    bool_val: bool,
    bytes: []const u8,

    /// Return the text payload, or null if this is not a .text value.
    pub fn asText(self: Value) ?[]const u8 {
        return switch (self) {
            .text => |v| v,
            else => null,
        };
    }

    /// Return the int payload, or null if this is not an .int value.
    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int => |v| v,
            else => null,
        };
    }

    /// Return the bool payload, or null if this is not a .bool_val value.
    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .bool_val => |v| v,
            else => null,
        };
    }

    /// Return the bytes payload, or null if this is not a .bytes value.
    pub fn asBytes(self: Value) ?[]const u8 {
        return switch (self) {
            .bytes => |v| v,
            else => null,
        };
    }
};

// ── Row helpers ────────────────────────────────────────────────────────────

/// A named field in a result row.
pub const Field = struct {
    name: []const u8,
    value: Value,
};

/// A result row: a slice of named fields.
pub const Row = []const Field;

/// Look up a field by name in a row. Returns null if not found.
pub fn rowGet(row: Row, name: []const u8) ?Value {
    for (row) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.value;
    }
    return null;
}

/// Shorthand: get a text value by column name.
pub fn rowText(row: Row, name: []const u8) ?[]const u8 {
    const v = rowGet(row, name) orelse return null;
    return v.asText();
}

/// Shorthand: get an integer value by column name.
pub fn rowInt(row: Row, name: []const u8) ?i64 {
    const v = rowGet(row, name) orelse return null;
    return v.asInt();
}

/// Shorthand: get a boolean value by column name.
pub fn rowBool(row: Row, name: []const u8) ?bool {
    const v = rowGet(row, name) orelse return null;
    return v.asBool();
}

// ── QueryResult ────────────────────────────────────────────────────────────

/// Owns all row data via an arena allocator. Call `deinit` when done.
pub const QueryResult = struct {
    rows: []const Row,
    _arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *QueryResult) void {
        self._arena.deinit();
    }
};

// ── FetchResult ────────────────────────────────────────────────────────────

/// Result of an HTTP fetch performed by an adapter (e.g. Hyperdrive REST).
pub const FetchResult = struct {
    status: u16,
    body: []u8,
    _alloc: Allocator,

    pub fn deinit(self: *FetchResult) void {
        self._alloc.free(self.body);
    }
};

/// Function type for performing HTTP requests inside a Worker environment.
/// Adapters that need to call external services (Hyperdrive, D1 REST, etc.)
/// accept an injected FetchFn rather than using std.http directly, since
/// Cloudflare Workers do not expose raw TCP sockets.
pub const FetchFn = *const fn (
    alloc: Allocator,
    url: []const u8,
    method: []const u8,
    headers: []const [2][]const u8,
    body: []const u8,
) anyerror!FetchResult;

// ── Adapter vtable ─────────────────────────────────────────────────────────

/// A vtable-dispatched database adapter.
///
/// Implement this interface for your backing store:
///   - Hyperdrive (Cloudflare Workers): send parameterised SQL over HTTP.
///   - Postgres direct: use a Zig Postgres client.
///   - D1 (SQLite): use the D1 bindings API.
///   - Test double: return pre-canned QueryResults.
pub const Adapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Execute a SELECT (or INSERT RETURNING). Returns a QueryResult.
        queryFn: *const fn (*anyopaque, Allocator, []const u8, []const Value) anyerror!QueryResult,
        /// Execute a non-returning statement (INSERT, UPDATE, DELETE).
        execFn: *const fn (*anyopaque, Allocator, []const u8, []const Value) anyerror!void,
        /// Release any resources held by the adapter (connections, etc.).
        deinitFn: *const fn (*anyopaque) void,
    };

    /// Execute a query and return rows.
    pub fn query(self: Adapter, alloc: Allocator, sql: []const u8, params: []const Value) !QueryResult {
        return self.vtable.queryFn(self.ptr, alloc, sql, params);
    }

    /// Execute a non-returning statement.
    pub fn exec(self: Adapter, alloc: Allocator, sql: []const u8, params: []const Value) !void {
        return self.vtable.execFn(self.ptr, alloc, sql, params);
    }

    /// Release adapter resources.
    pub fn deinit(self: Adapter) void {
        self.vtable.deinitFn(self.ptr);
    }
};

// ── Convenience: no-op deinit ──────────────────────────────────────────────

/// A do-nothing deinit function for adapters that hold no resources
/// (e.g. stateless HTTP adapters, test doubles using arena allocators).
pub fn noop_deinit(_: *anyopaque) void {}

// ── Tests ──────────────────────────────────────────────────────────────────

test "rowGet returns null for missing field" {
    const row: Row = &.{
        .{ .name = "id", .value = .{ .text = "abc" } },
    };
    try std.testing.expect(rowGet(row, "missing") == null);
}

test "rowText extracts text value" {
    const row: Row = &.{
        .{ .name = "email", .value = .{ .text = "user@example.com" } },
    };
    try std.testing.expectEqualStrings("user@example.com", rowText(row, "email").?);
}

test "rowInt extracts int value" {
    const row: Row = &.{
        .{ .name = "count", .value = .{ .int = 42 } },
    };
    try std.testing.expectEqual(@as(i64, 42), rowInt(row, "count").?);
}

test "rowBool extracts bool value" {
    const row: Row = &.{
        .{ .name = "verified", .value = .{ .bool_val = true } },
    };
    try std.testing.expect(rowBool(row, "verified").?);
}

test "Value helper methods" {
    const v_text = Value{ .text = "hello" };
    try std.testing.expectEqualStrings("hello", v_text.asText().?);
    try std.testing.expect(v_text.asInt() == null);

    const v_int = Value{ .int = 7 };
    try std.testing.expectEqual(@as(i64, 7), v_int.asInt().?);
    try std.testing.expect(v_int.asBool() == null);

    const v_bool = Value{ .bool_val = false };
    try std.testing.expectEqual(false, v_bool.asBool().?);

    const v_null = Value{ .null_val = {} };
    try std.testing.expect(v_null.asText() == null);
    try std.testing.expect(v_null.asInt() == null);
}
