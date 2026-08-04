//! env.zig — cross-platform environment variable store.
//!
//! Native:  loadDotenv() parses `.env` at startup; get() checks the table
//!          then falls back to the process environment.
//!
//! wasm32:  worker.js calls __mer_set_env_status() for each Cloudflare secret
//!          binding before dispatching the first request; get() reads the table.

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn ferror(stream: *std.c.FILE) c_int;

const MAX_DOTENV_BYTES = 64 * 1024;
const injected_allocator = if (builtin.target.cpu.arch == .wasm32)
    std.heap.wasm_allocator
else
    std.heap.page_allocator;

const Source = enum { injected, dotenv };
const Entry = struct {
    key: []u8,
    val: []u8,
    source: Source,
    allocator: std.mem.Allocator,
    next: ?*Entry = null,
};

var entries: ?*Entry = null;
var retired: ?*Entry = null;
var list_lock = std.atomic.Value(bool).init(false);

fn lockList() void {
    while (list_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn unlockList() void {
    list_lock.store(false, .release);
}

fn findEntry(name: []const u8) ?*Entry {
    var current = entries;
    while (current) |entry| : (current = entry.next) {
        if (std.mem.eql(u8, entry.key, name)) return entry;
    }
    return null;
}

fn createEntry(
    allocator: std.mem.Allocator,
    key: []const u8,
    val: []const u8,
    source: Source,
) !*Entry {
    const entry = try allocator.create(Entry);
    errdefer allocator.destroy(entry);
    const key_copy = try allocator.dupe(u8, key);
    errdefer allocator.free(key_copy);
    const val_copy = try allocator.dupe(u8, val);
    entry.* = .{
        .key = key_copy,
        .val = val_copy,
        .source = source,
        .allocator = allocator,
    };
    return entry;
}

fn destroyEntry(entry: *Entry) void {
    const allocator = entry.allocator;
    allocator.free(entry.key);
    allocator.free(entry.val);
    allocator.destroy(entry);
}

fn destroyList(head: ?*Entry) void {
    var current = head;
    while (current) |entry| {
        current = entry.next;
        destroyEntry(entry);
    }
}

/// Keep previously published storage alive until the application-wide reset so
/// slices returned by get() remain immutable and valid across updates.
fn retireEntry(entry: *Entry) void {
    entry.next = retired;
    retired = entry;
}

// ── Public get / put ────────────────────────────────────────────────────────

/// Read an env var. Checks the in-memory table first, then the native process
/// environment. `name` need not have sentinel-terminated backing storage.
pub fn get(name: []const u8) ?[]const u8 {
    lockList();
    const stored = if (findEntry(name)) |entry| entry.val else null;
    unlockList();
    if (stored) |value| return value;
    if (builtin.target.cpu.arch != .wasm32) {
        if (name.len >= 4096 or std.mem.indexOfScalar(u8, name, 0) != null) return null;
        var name_buf: [4096:0]u8 = undefined;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;
        const terminated: [:0]u8 = name_buf[0..name.len :0];
        const ptr = std.c.getenv(terminated.ptr) orelse return null;
        return std.mem.sliceTo(ptr, 0);
    }
    return null;
}

/// Insert or replace an owned in-memory value. There is no fixed entry or byte
/// cap; allocation failure is returned to the caller.
pub fn put(key: []const u8, val: []const u8) error{OutOfMemory}!void {
    const replacement = try createEntry(injected_allocator, key, val, .injected);
    lockList();
    defer unlockList();
    if (findEntry(key)) |old| {
        var link = &entries;
        while (link.* != old) link = &link.*.?.next;
        replacement.next = old.next;
        link.* = replacement;
        retireEntry(old);
    } else {
        replacement.next = entries;
        entries = replacement;
    }
}

// ── Native: .env file loading ────────────────────────────────────────────────

pub const DotenvLoadStatus = enum {
    loaded,
    not_found,
};

/// Release all active and retired `.env` values. This is a shutdown boundary;
/// call only after request and telemetry readers have stopped.
pub fn deinitDotenv() void {
    lockList();
    var removed: ?*Entry = null;
    var link = &entries;
    while (link.*) |entry| {
        if (entry.source == .dotenv) {
            link.* = entry.next;
            entry.next = removed;
            removed = entry;
        } else {
            link = &entry.next;
        }
    }
    link = &retired;
    while (link.*) |entry| {
        if (entry.source == .dotenv) {
            link.* = entry.next;
            entry.next = removed;
            removed = entry;
        } else {
            link = &entry.next;
        }
    }
    unlockList();
    destroyList(removed);
}

fn appendDotenv(
    allocator: std.mem.Allocator,
    head: *?*Entry,
    key: []const u8,
    val: []const u8,
) !void {
    var link = head;
    while (link.*) |entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            const replacement = try createEntry(allocator, key, val, .dotenv);
            replacement.next = entry.next;
            link.* = replacement;
            destroyEntry(entry);
            return;
        }
        link = &entry.next;
    }
    link.* = try createEntry(allocator, key, val, .dotenv);
}

fn installDotenv(allocator: std.mem.Allocator, content: []const u8) !void {
    var next: ?*Entry = null;
    errdefer destroyList(next);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var rest = line;
        if (std.mem.startsWith(u8, rest, "export ")) rest = rest["export ".len..];
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
        const key = std.mem.trim(u8, rest[0..eq], " \t");
        var val = std.mem.trim(u8, rest[eq + 1 ..], " \t");
        if (val.len >= 2) {
            const quote = val[0];
            if ((quote == '"' or quote == '\'') and val[val.len - 1] == quote) {
                val = val[1 .. val.len - 1];
            }
        }
        if (key.len == 0) continue;
        try appendDotenv(allocator, &next, key, val);
    }

    lockList();
    defer unlockList();

    // Injected values always win, including values published while this file
    // was being parsed.
    var current = entries;
    while (current) |entry| : (current = entry.next) {
        if (entry.source != .injected) continue;
        var link = &next;
        while (link.*) |candidate| {
            if (std.mem.eql(u8, candidate.key, entry.key)) {
                link.* = candidate.next;
                destroyEntry(candidate);
                break;
            }
            link = &candidate.next;
        }
    }

    var link = &entries;
    while (link.*) |entry| {
        if (entry.source == .dotenv) {
            link.* = entry.next;
            retireEntry(entry);
        } else {
            link = &entry.next;
        }
    }
    if (next) |head| {
        var tail = head;
        while (tail.next) |entry| tail = entry;
        tail.next = entries;
        entries = head;
    }
}

/// Parse `.env` from cwd and populate the in-memory table. Missing files are
/// reported as `.not_found`; I/O, size, and allocation failures are returned.
/// Repeated successful loads atomically replace prior dotenv values. Published
/// storage remains valid until reset().
pub fn loadDotenvStatus(allocator: std.mem.Allocator) !DotenvLoadStatus {
    if (builtin.target.cpu.arch == .wasm32) return .not_found;

    // Zig 0.16: use C stdio since Dir methods need an Io runtime.
    const file = std.c.fopen(".env", "rb") orelse {
        if (std.posix.errno(@as(c_int, -1)) == .NOENT) return .not_found;
        return error.OpenFailed;
    };
    defer _ = std.c.fclose(file);

    const buf = try allocator.alloc(u8, MAX_DOTENV_BYTES + 1);
    defer allocator.free(buf);
    var total: usize = 0;
    while (total < buf.len) {
        const count = std.c.fread(buf[total..].ptr, 1, buf.len - total, file);
        if (count == 0) {
            if (ferror(file) != 0) return error.ReadFailed;
            break;
        }
        total += count;
    }
    if (total > MAX_DOTENV_BYTES) return error.FileTooLarge;

    try installDotenv(allocator, buf[0..total]);
    return .loaded;
}

/// Compatibility wrapper. New callers that need diagnostics should use
/// `loadDotenvStatus` and handle its status/error result.
pub fn loadDotenv(allocator: std.mem.Allocator) void {
    _ = loadDotenvStatus(allocator) catch return;
}

// ── wasm32: Cloudflare Workers injection ────────────────────────────────────

pub const EnvSetStatus = enum(u32) {
    ok = 0,
    table_full = 1, // retained for ABI compatibility; no fixed table remains
    string_storage_full = 2, // retained for ABI compatibility
    out_of_memory = 3,
};

/// Status-returning environment injection API. Hosts must treat any non-zero
/// result as startup failure and may free their input buffers after this call.
pub export fn __mer_set_env_status(
    key_ptr: [*]const u8,
    key_len: usize,
    val_ptr: [*]const u8,
    val_len: usize,
) u32 {
    put(key_ptr[0..key_len], val_ptr[0..val_len]) catch
        return @intFromEnum(EnvSetStatus.out_of_memory);
    return @intFromEnum(EnvSetStatus.ok);
}

/// Backward-compatible injection export. New hosts should call the observable
/// `__mer_set_env_status` export instead.
pub export fn __mer_set_env(
    key_ptr: [*]const u8,
    key_len: usize,
    val_ptr: [*]const u8,
    val_len: usize,
) void {
    _ = __mer_set_env_status(key_ptr, key_len, val_ptr, val_len);
}

/// Release every active and retired value. This is an application lifecycle
/// boundary: call only at startup before threads exist, or at shutdown after all
/// request and telemetry readers have stopped. Concurrent reset/get is invalid.
pub fn reset() void {
    lockList();
    const active = entries;
    const old = retired;
    entries = null;
    retired = null;
    unlockList();
    destroyList(active);
    destroyList(old);
}

pub const deinit = reset;

const ConcurrencyContext = struct {
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn replaceValues(ctx: *ConcurrencyContext) void {
    var value_buf: [32]u8 = undefined;
    for (0..2000) |i| {
        const value = std.fmt.bufPrint(&value_buf, "value-{d}", .{i}) catch {
            ctx.failed.store(true, .release);
            return;
        };
        put("MERJS_CONCURRENT", value) catch {
            ctx.failed.store(true, .release);
            return;
        };
    }
}

fn readValues(ctx: *ConcurrencyContext) void {
    for (0..4000) |_| {
        const value = get("MERJS_CONCURRENT") orelse continue;
        if (!std.mem.startsWith(u8, value, "value-")) {
            ctx.failed.store(true, .release);
            return;
        }
    }
}

fn reloadValues(ctx: *ConcurrencyContext) void {
    for (0..1000) |i| {
        const content = if (i % 2 == 0) "DOTENV_CONCURRENT=first\n" else "DOTENV_CONCURRENT=second\n";
        installDotenv(std.heap.page_allocator, content) catch {
            ctx.failed.store(true, .release);
            return;
        };
    }
}

fn readDotenvValues(ctx: *ConcurrencyContext) void {
    for (0..2000) |_| {
        const value = get("DOTENV_CONCURRENT") orelse continue;
        if (!std.mem.eql(u8, value, "first") and !std.mem.eql(u8, value, "second")) {
            ctx.failed.store(true, .release);
            return;
        }
    }
}

test "env: native lookup uses the exact slice" {
    if (builtin.target.cpu.arch == .wasm32) return;
    reset();
    defer reset();

    const backing = "PATH_suffix-that-must-not-be-read";
    const expected = std.c.getenv("PATH") orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings(std.mem.sliceTo(expected, 0), get(backing[0..4]) orelse return error.TestUnexpectedNull);
    try std.testing.expect(get(backing[0..5]) == null);
    try std.testing.expect(get("PATH\x00suffix") == null);
}

test "env: dynamically owns more than 64 injected values" {
    reset();
    defer reset();

    var key_buf: [32]u8 = undefined;
    for (0..128) |i| {
        const key = try std.fmt.bufPrint(&key_buf, "MERJS_ENV_{d}", .{i});
        try put(key, "value");
    }
    try std.testing.expectEqualStrings("value", get("MERJS_ENV_127").?);
}

test "env: dotenv reload owns and replaces storage" {
    reset();
    defer reset();

    try installDotenv(std.testing.allocator, "A=first\nB=removed\n");
    try std.testing.expectEqualStrings("first", get("A").?);
    try installDotenv(std.testing.allocator, "A=second\n");
    try std.testing.expectEqualStrings("second", get("A").?);
    try std.testing.expect(get("B") == null);

    try put("A", "injected");
    try installDotenv(std.testing.allocator, "A=dotenv\nC=third\n");
    try std.testing.expectEqualStrings("injected", get("A").?);
    deinitDotenv();
    try std.testing.expect(get("C") == null);
    try std.testing.expectEqualStrings("injected", get("A").?);
}

test "env: failed dotenv parse allocation preserves current values" {
    reset();
    defer reset();
    try installDotenv(std.testing.allocator, "A=current\n");

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, installDotenv(failing.allocator(), "A=replacement\n"));
    try std.testing.expectEqualStrings("current", get("A").?);
}

test "env: published values survive replacement and reload" {
    reset();
    defer reset();

    try put("A", "injected-old");
    const injected_old = get("A").?;
    try put("A", "injected-new");
    try std.testing.expectEqualStrings("injected-old", injected_old);

    try installDotenv(std.testing.allocator, "B=dotenv-old\n");
    const dotenv_old = get("B").?;
    try installDotenv(std.testing.allocator, "B=dotenv-new\n");
    try std.testing.expectEqualStrings("dotenv-old", dotenv_old);
}

test "env: concurrent get and put synchronize list access" {
    if (builtin.target.cpu.arch == .wasm32) return;
    reset();
    defer reset();

    var ctx: ConcurrencyContext = .{};
    const writer = try std.Thread.spawn(.{}, replaceValues, .{&ctx});
    const reader = try std.Thread.spawn(.{}, readValues, .{&ctx});
    writer.join();
    reader.join();
    try std.testing.expect(!ctx.failed.load(.acquire));
}

test "env: concurrent get and dotenv reload synchronize list access" {
    if (builtin.target.cpu.arch == .wasm32) return;
    reset();
    defer reset();

    var ctx: ConcurrencyContext = .{};
    const writer = try std.Thread.spawn(.{}, reloadValues, .{&ctx});
    const reader = try std.Thread.spawn(.{}, readDotenvValues, .{&ctx});
    writer.join();
    reader.join();
    try std.testing.expect(!ctx.failed.load(.acquire));
}
