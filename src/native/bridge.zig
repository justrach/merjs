// bridge.zig — `window.mer.invoke` JS↔Zig bridge dispatch.
//
// Client side (injected JS shim, see macos.zig):
//   const path = await window.mer.invoke("dialog.openFile", { filters: ["*.md"] });
//
// The shim postMessages a JSON envelope to a WKScriptMessageHandler named
// "merInvoke". The ObjC IMP (macos.zig) pulls the body string and calls
// dispatch() here, which:
//   1. size limit  — reject payloads > max_payload_bytes
//   2. parse       — { cmd, args, id }
//   3. permission  — command.permission ∈ manifest.permissions (deny-default)
//   4. dispatch    — command name → handler via comptime registry
//                    (same shape as Router.exact_map in src/dispatch.zig)
//   5. resolve     — returns a `window.mer._resolve(<id>, ok, <json>)` JS
//                    string the IMP evaluates on the webview
//
// Origin note: the native shell only ever loads http://127.0.0.1:<port>, so the
// origin is trusted loopback by construction. Dynamic origin extraction from
// the WKScriptMessage frame is checked by the macOS backend before dispatch.

const std = @import("std");
const builtin = @import("builtin");
const platform_commands = @import("platform_commands.zig");
const commands = platform_commands.commands;

/// Maximum inbound bridge payload size (keeps the ObjC string bridge bounded).
pub const max_payload_bytes: usize = 64 * 1024;

/// Bridge call context handed to registered handlers.
pub const Ctx = struct {
    allocator: std.mem.Allocator,
    permissions: []const []const u8,
    allowed_origins: []const []const u8 = &.{},
};

/// A JSON value returned by a bridge handler (an owned string of JSON).
pub const Json = []const u8;

/// Error set for bridge dispatch.
pub const BridgeError = error{
    UnknownCommand,
    PermissionDenied,
    OriginNotAllowed,
    PayloadTooLarge,
    ParseError,
    HandlerError,
    OutOfMemory,
};

/// Result of a handler invocation.
pub const HandlerResult = union(enum) {
    /// Borrowed/static JSON payload; dispatch does not free it.
    ok: Json,
    /// Owned JSON payload allocated with ctx.allocator; dispatch frees it after
    /// copying it into the JS resolve string.
    ok_owned: []u8,
    err: BridgeError,
};

/// A handler takes the parsed `args` value and returns a JSON result or error.
pub const HandlerFn = *const fn (ctx: *Ctx, args: std.json.Value) HandlerResult;

/// A registered command: name, required permission, handler.
pub const Command = struct {
    name: []const u8,
    permission: []const u8,
    handler: HandlerFn,
};

/// The comptime command registry. Add commands here; matched by name in
/// dispatch(). Mirrors the static route table in src/dispatch.zig.
pub const registry = [_]Command{
    .{ .name = "mer.ping", .permission = "", .handler = ping },
    .{ .name = "mer.echo", .permission = "", .handler = echo },
    .{ .name = "dialog.openFile", .permission = "dialog", .handler = dialogOpenFile },
    .{ .name = "dialog.pickDirectory", .permission = "dialog", .handler = dialogPickDirectory },
    .{ .name = "dialog.openDirectory", .permission = "dialog", .handler = dialogPickDirectory },
    .{ .name = "clipboard.read", .permission = "clipboard", .handler = clipboardRead },
    .{ .name = "clipboard.write", .permission = "clipboard", .handler = clipboardWrite },
    .{ .name = "open.external", .permission = "open", .handler = openExternal },
    .{ .name = "open.path", .permission = "open", .handler = openPath },
    .{ .name = "window.setTitle", .permission = "window", .handler = windowSetTitle },
};

fn ping(_: *Ctx, _: std.json.Value) HandlerResult {
    return .{ .ok = "{\"pong\":true}" };
}

fn echo(_: *Ctx, _: std.json.Value) HandlerResult {
    // This release: static ack. Dynamic arg reflection (re-stringify args) needs a
    // JSON writer; the round-trip itself is proven by mer.ping.
    return .{ .ok = "{\"echo\":true}" };
}

fn dialogOpenFile(ctx: *Ctx, args: std.json.Value) HandlerResult {
    if (builtin.os.tag != .macos) return .{ .err = error.HandlerError };
    const title = argString(args, "title") orelse "Choose a file";
    const result = commands.openPanel(ctx.allocator, .{
        .title = title,
        .can_choose_files = true,
        .can_choose_directories = false,
    }) catch return .{ .err = error.HandlerError };
    const json = if (result) |path| blk: {
        defer ctx.allocator.free(path);
        break :blk jsonString(ctx.allocator, path) catch return .{ .err = error.OutOfMemory };
    } else return .{ .ok = "null" };
    return .{ .ok_owned = json };
}

fn dialogPickDirectory(ctx: *Ctx, args: std.json.Value) HandlerResult {
    if (builtin.os.tag != .macos) return .{ .err = error.HandlerError };
    const title = argString(args, "title") orelse "Choose a folder";
    const result = commands.openPanel(ctx.allocator, .{
        .title = title,
        .can_choose_files = false,
        .can_choose_directories = true,
    }) catch return .{ .err = error.HandlerError };
    const json = if (result) |path| blk: {
        defer ctx.allocator.free(path);
        break :blk jsonString(ctx.allocator, path) catch return .{ .err = error.OutOfMemory };
    } else return .{ .ok = "null" };
    return .{ .ok_owned = json };
}

fn clipboardRead(ctx: *Ctx, _: std.json.Value) HandlerResult {
    if (builtin.os.tag != .macos) return .{ .err = error.HandlerError };
    const text = commands.clipboardRead() catch return .{ .err = error.HandlerError };
    const json = jsonString(ctx.allocator, text) catch return .{ .err = error.OutOfMemory };
    return .{ .ok_owned = json };
}

fn clipboardWrite(_: *Ctx, args: std.json.Value) HandlerResult {
    if (builtin.os.tag != .macos) return .{ .err = error.HandlerError };
    const text = switch (args) {
        .string => |value| value,
        .object => |object| blk: {
            const value = object.get("text") orelse return .{ .err = error.HandlerError };
            break :blk if (value == .string) value.string else return .{ .err = error.HandlerError };
        },
        else => return .{ .err = error.HandlerError },
    };
    commands.clipboardWrite(text) catch return .{ .err = error.HandlerError };
    return .{ .ok = "null" };
}

fn openExternal(_: *Ctx, args: std.json.Value) HandlerResult {
    if (builtin.os.tag != .macos) return .{ .err = error.HandlerError };
    const url = argString(args, "url") orelse if (args == .string) args.string else return .{ .err = error.HandlerError };
    commands.openUrl(url) catch return .{ .err = error.HandlerError };
    return .{ .ok = "null" };
}

fn openPath(_: *Ctx, args: std.json.Value) HandlerResult {
    if (builtin.os.tag != .macos) return .{ .err = error.HandlerError };
    const path = argString(args, "path") orelse if (args == .string) args.string else return .{ .err = error.HandlerError };
    commands.openPath(path) catch return .{ .err = error.HandlerError };
    return .{ .ok = "null" };
}

fn windowSetTitle(_: *Ctx, args: std.json.Value) HandlerResult {
    if (builtin.os.tag != .macos) return .{ .err = error.HandlerError };
    const title = argString(args, "title") orelse if (args == .string) args.string else return .{ .err = error.HandlerError };
    commands.setWindowTitle(title) catch return .{ .err = error.HandlerError };
    return .{ .ok = "null" };
}

fn argString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn jsonString(alloc: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(value);
    return out.written();
}

/// True if `perm` is granted by the manifest's permissions list. Empty perm
/// means the command is always allowed (e.g. mer.ping).
pub fn hasPermission(ctx: *Ctx, perm: []const u8) bool {
    if (perm.len == 0) return true;
    for (ctx.permissions) |p| {
        if (std.mem.eql(u8, p, perm)) return true;
    }
    return false;
}

const ParsedOrigin = struct {
    scheme: []const u8,
    host: []const u8,
    port: ?[]const u8,
};

fn parseOrigin(value: []const u8) ?ParsedOrigin {
    const scheme_end = std.mem.indexOf(u8, value, "://") orelse return null;
    const scheme = value[0..scheme_end];
    if (scheme.len == 0) return null;

    const authority_start = scheme_end + 3;
    const authority_end = blk: {
        var i: usize = authority_start;
        while (i < value.len) : (i += 1) {
            switch (value[i]) {
                '/', '?', '#' => break :blk i,
                else => {},
            }
        }
        break :blk value.len;
    };
    var authority = value[authority_start..authority_end];
    if (authority.len == 0) return null;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];

    if (authority.len > 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        const host = authority[0 .. close + 1];
        const rest = authority[close + 1 ..];
        const port = if (rest.len == 0) null else if (rest[0] == ':' and rest.len > 1) rest[1..] else return null;
        return .{ .scheme = scheme, .host = host, .port = port };
    }

    const colon = std.mem.indexOfScalar(u8, authority, ':');
    const host = if (colon) |c| authority[0..c] else authority;
    if (host.len == 0) return null;
    const port = if (colon) |c| if (c + 1 < authority.len) authority[c + 1 ..] else return null else null;
    return .{ .scheme = scheme, .host = host, .port = port };
}

pub fn isOriginAllowed(ctx: *Ctx, url: []const u8) bool {
    const actual = parseOrigin(url) orelse return false;
    for (ctx.allowed_origins) |origin| {
        const allowed = parseOrigin(origin) orelse continue;
        if (!std.ascii.eqlIgnoreCase(actual.scheme, allowed.scheme)) continue;
        if (!std.ascii.eqlIgnoreCase(actual.host, allowed.host)) continue;
        if (allowed.port) |allowed_port| {
            if (actual.port == null or !std.mem.eql(u8, actual.port.?, allowed_port)) continue;
        } else if (actual.port != null) {
            continue;
        }
        return true;
    }
    return false;
}

const Envelope = struct {
    cmd: []const u8,
    args: std.json.Value = .null,
    id: i64 = 0,
};

/// Dispatch an inbound payload. Returns an owned JS string of the form
/// `window.mer._resolve(<id>,<ok>,<json>);` for the IMP to evaluate.
pub fn dispatch(ctx: *Ctx, payload: []const u8) BridgeError![]u8 {
    const alloc = ctx.allocator;

    if (payload.len > max_payload_bytes) {
        return resolveStr(alloc, 0, false, "\"PayloadTooLarge\"");
    }

    var parsed = std.json.parseFromSlice(Envelope, alloc, payload, .{}) catch {
        return resolveStr(alloc, 0, false, "\"ParseError\"");
    };
    defer parsed.deinit();
    const env = parsed.value;

    for (registry) |cmd| {
        if (std.mem.eql(u8, cmd.name, env.cmd)) {
            if (!hasPermission(ctx, cmd.permission)) {
                return resolveStr(alloc, env.id, false, "\"PermissionDenied\"");
            }
            const res = cmd.handler(ctx, env.args);
            switch (res) {
                .ok => |json| return resolveStr(alloc, env.id, true, json),
                .ok_owned => |json| {
                    defer alloc.free(json);
                    return resolveStr(alloc, env.id, true, json);
                },
                .err => |e| return resolveError(alloc, env.id, @errorName(e)),
            }
        }
    }
    return resolveError(alloc, env.id, "UnknownCommand");
}

pub fn rejectFromPayload(ctx: *Ctx, payload: []const u8, name: []const u8) BridgeError![]u8 {
    var parsed = std.json.parseFromSlice(Envelope, ctx.allocator, payload, .{}) catch {
        return resolveError(ctx.allocator, 0, name);
    };
    defer parsed.deinit();
    return resolveError(ctx.allocator, parsed.value.id, name);
}

/// Format `window.mer._resolve(<id>,<ok>,<json>);` into an owned string.
fn resolveStr(alloc: std.mem.Allocator, id: i64, ok: bool, json: []const u8) BridgeError![]u8 {
    return std.fmt.allocPrint(alloc, "window.mer._resolve({d},{s},{s});", .{ id, if (ok) "true" else "false", json }) catch error.OutOfMemory;
}

fn resolveError(alloc: std.mem.Allocator, id: i64, name: []const u8) BridgeError![]u8 {
    return std.fmt.allocPrint(alloc, "window.mer._resolve({d},false,\"{s}\");", .{ id, name }) catch error.OutOfMemory;
}

// ── tests (standalone: bridge.zig only imports std) ─────────────────────────
const testing = std.testing;

fn newCtx(alloc: std.mem.Allocator, perms: []const []const u8) Ctx {
    return .{ .allocator = alloc, .permissions = perms };
}

test "dispatch: mer.ping resolves ok" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    const js = try dispatch(&ctx, "{\"cmd\":\"mer.ping\",\"args\":null,\"id\":7}");
    try testing.expectEqualStrings("window.mer._resolve(7,true,{\"pong\":true});", js);
}

test "dispatch: unknown command denies by default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    const js = try dispatch(&ctx, "{\"cmd\":\"nope\",\"args\":null,\"id\":1}");
    try testing.expectEqualStrings("window.mer._resolve(1,false,\"UnknownCommand\");", js);
}

test "dispatch: permission gate blocks unpermitted command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // manifest grants only "window"; dialog.openFile needs "dialog"
    var ctx = newCtx(alloc, &.{"window"});
    const js = try dispatch(&ctx, "{\"cmd\":\"dialog.openFile\",\"args\":{},\"id\":3}");
    try testing.expectEqualStrings("window.mer._resolve(3,false,\"PermissionDenied\");", js);
}

test "dispatch: permission gate blocks clipboard/open/window commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{"dialog"});
    try testing.expectEqualStrings(
        "window.mer._resolve(4,false,\"PermissionDenied\");",
        try dispatch(&ctx, "{\"cmd\":\"clipboard.read\",\"args\":null,\"id\":4}"),
    );
    try testing.expectEqualStrings(
        "window.mer._resolve(5,false,\"PermissionDenied\");",
        try dispatch(&ctx, "{\"cmd\":\"open.path\",\"args\":{\"path\":\"/tmp\"},\"id\":5}"),
    );
    try testing.expectEqualStrings(
        "window.mer._resolve(6,false,\"PermissionDenied\");",
        try dispatch(&ctx, "{\"cmd\":\"window.setTitle\",\"args\":{\"title\":\"X\"},\"id\":6}"),
    );
}

test "dispatch: oversized payload rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    const big = try alloc.alloc(u8, max_payload_bytes + 1);
    @memset(big, 'x');
    const js = try dispatch(&ctx, big);
    try testing.expectEqualStrings("window.mer._resolve(0,false,\"PayloadTooLarge\");", js);
}

test "dispatch: malformed json yields ParseError" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    const js = try dispatch(&ctx, "not json");
    try testing.expectEqualStrings("window.mer._resolve(0,false,\"ParseError\");", js);
}

test "hasPermission: empty perm always allowed" {
    var ctx = newCtx(testing.allocator, &.{});
    try testing.expect(hasPermission(&ctx, ""));
}

test "isOriginAllowed: matches scheme and host, not string prefixes" {
    var ctx = Ctx{
        .allocator = testing.allocator,
        .permissions = &.{},
        .allowed_origins = &.{ "http://127.0.0.1", "mer://app", "http://localhost:3000" },
    };
    try testing.expect(!isOriginAllowed(&ctx, "http://127.0.0.1:49152/"));
    try testing.expect(isOriginAllowed(&ctx, "http://127.0.0.1/"));
    try testing.expect(isOriginAllowed(&ctx, "mer://app/index.html"));
    try testing.expect(isOriginAllowed(&ctx, "http://localhost:3000/"));
    try testing.expect(!isOriginAllowed(&ctx, "http://127.0.0.1.evil.example/"));
    try testing.expect(!isOriginAllowed(&ctx, "mer://app.evil/index.html"));
    try testing.expect(!isOriginAllowed(&ctx, "http://localhost:3001/"));
    try testing.expect(!isOriginAllowed(&ctx, "https://example.com/"));
}

test "rejectFromPayload preserves caller id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    const js = try rejectFromPayload(&ctx, "{\"cmd\":\"mer.ping\",\"id\":42}", "OriginNotAllowed");
    try testing.expectEqualStrings("window.mer._resolve(42,false,\"OriginNotAllowed\");", js);
}
