// bridge.zig — `window.mer.invoke` JS↔Zig bridge dispatch.
//
// Client side (injected JS shim, see macos.zig):
//   const path = await window.mer.invoke("dialog.openFile", { filters: ["*.md"] });
//
// The shim postMessages a JSON envelope to a WKScriptMessageHandler named
// "merInvoke". The ObjC IMP (macos.zig) pulls the body string and calls
// dispatch() here, which:
//   1. size limit  — reject payloads > max_payload_bytes
//   2. parse       — { cmd, args, id, token }
//   3. token       — when configured, every call must prove the per-session capability
//   4. permission  — command.permission ∈ manifest.permissions (deny-default)
//   5. dispatch    — command name → handler via comptime registry
//                    (same shape as Router.exact_map in src/dispatch.zig)
//   6. resolve     — returns a `window.mer._resolve(<token>, <id>, ok, <json>)`
//                    JS string the IMP evaluates on the webview when a valid
//                    token is configured
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
    /// Optional explicit command allowlist. Empty preserves the older
    /// permission-only behavior; generated manifests fill this in for least privilege.
    allowed_commands: []const []const u8 = &.{},
    /// Optional per-command origin bindings encoded as "command|origin".
    command_origins: []const []const u8 = &.{},
    /// Origin of the current bridge call, set by the platform backend.
    current_origin: ?[]const u8 = null,
    /// Optional app-provided static command registry. Dynamic/plugin loading is
    /// intentionally unsupported; these entries are validated before dispatch.
    extra_commands: []const Command = &.{},
    /// Per-process unguessable bridge capability. Platform backends inject this
    /// into the private JS shim closure and every bridge envelope must echo it.
    bridge_token: ?[]const u8 = null,
    /// Token validation is required by default for fail-closed embedders. Opting
    /// out is intended for non-WebView tests only; the macOS shim requires
    /// token-bearing requests and responses.
    require_bridge_token: bool = true,
    external_url_schemes: []const []const u8 = &.{ "http", "https", "mailto" },
    open_path_roots: []const []const u8 = &.{},
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
    CommandDenied,
    UrlDenied,
    PathDenied,
    InvalidArgs,
    InvalidRegistry,
    InvalidToken,
    OutOfMemory,
};

/// Result of a handler invocation.
pub const HandlerResult = union(enum) {
    /// Borrowed/static JSON payload; dispatch validates it as JSON and does not free it.
    ok: Json,
    /// Owned JSON payload allocated with ctx.allocator; dispatch validates it as
    /// JSON and frees it after copying it into the JS resolve string.
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

/// Built-in commands shipped by merjs. Apps can pass additional static commands
/// to `dispatchWithRegistry`; dynamic/plugin loading is intentionally not part
/// of the bridge surface.
pub const builtin_registry = [_]Command{
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
    .{ .name = "window.close", .permission = "window", .handler = windowClose },
};

/// Back-compat alias for callers that inspect the built-in registry.
pub const registry = builtin_registry;

const reserved_command_prefixes = [_][]const u8{ "mer.", "dialog.", "clipboard.", "open.", "window." };

fn isValidBridgeTokenByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

pub fn isValidBridgeToken(token: []const u8) bool {
    if (token.len < 32 or token.len > 128) return false;
    for (token) |c| if (!isValidBridgeTokenByte(c)) return false;
    return true;
}

fn isCommandNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_';
}

pub fn isValidCommandName(name: []const u8) bool {
    if (name.len == 0 or name.len > 96) return false;
    if (name[0] == '.' or name[name.len - 1] == '.') return false;
    var saw_dot = false;
    var prev_dot = false;
    for (name) |c| {
        if (!isCommandNameChar(c)) return false;
        if (c == '.') {
            if (prev_dot) return false;
            saw_dot = true;
            prev_dot = true;
        } else {
            prev_dot = false;
        }
    }
    return saw_dot;
}

pub fn isValidPermissionName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_' or c == ':')) return false;
    }
    return true;
}

fn isReservedCommandName(name: []const u8) bool {
    for (reserved_command_prefixes) |prefix| {
        if (name.len >= prefix.len and std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix)) return true;
    }
    return false;
}

fn builtinCommandExists(name: []const u8) bool {
    for (builtin_registry) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return true;
    }
    return false;
}

/// Validate app-provided static bridge commands. Custom commands must be in an
/// app namespace (for example `app.export`) and must declare an explicit,
/// non-empty permission; only benign built-ins may use empty permissions.
pub fn validateCommandRegistry(extra_commands: []const Command) BridgeError!void {
    for (extra_commands, 0..) |cmd, i| {
        if (!isValidCommandName(cmd.name)) return error.InvalidRegistry;
        if (isReservedCommandName(cmd.name) or builtinCommandExists(cmd.name)) return error.InvalidRegistry;
        if (!isValidPermissionName(cmd.permission)) return error.InvalidRegistry;
        for (extra_commands[i + 1 ..]) |other| {
            if (std.mem.eql(u8, cmd.name, other.name)) return error.InvalidRegistry;
        }
    }
}

fn ping(_: *Ctx, _: std.json.Value) HandlerResult {
    return .{ .ok = "{\"pong\":true}" };
}

fn echo(_: *Ctx, _: std.json.Value) HandlerResult {
    // This release: static ack. Dynamic arg reflection (re-stringify args) needs a
    // JSON writer; the round-trip itself is proven by mer.ping.
    return .{ .ok = "{\"echo\":true}" };
}

fn dialogOpenFile(ctx: *Ctx, args: std.json.Value) HandlerResult {
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
    const title = argString(args, "title") orelse "Choose a folder";
    const result = commands.openPanel(ctx.allocator, .{
        .title = title,
        .can_choose_files = false,
        .can_choose_directories = true,
        .can_create_directories = argBool(args, "canCreateDirectories") orelse false,
    }) catch return .{ .err = error.HandlerError };
    const json = if (result) |path| blk: {
        defer ctx.allocator.free(path);
        break :blk jsonString(ctx.allocator, path) catch return .{ .err = error.OutOfMemory };
    } else return .{ .ok = "null" };
    return .{ .ok_owned = json };
}

fn clipboardRead(ctx: *Ctx, _: std.json.Value) HandlerResult {
    const text = commands.clipboardRead() catch return .{ .err = error.HandlerError };
    const json = jsonString(ctx.allocator, text) catch return .{ .err = error.OutOfMemory };
    return .{ .ok_owned = json };
}

fn clipboardWrite(_: *Ctx, args: std.json.Value) HandlerResult {
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

fn openExternal(ctx: *Ctx, args: std.json.Value) HandlerResult {
    const url = argString(args, "url") orelse if (args == .string) args.string else return .{ .err = error.InvalidArgs };
    if (!isAllowedExternalUrl(ctx, url)) return .{ .err = error.UrlDenied };
    commands.openUrl(url) catch return .{ .err = error.HandlerError };
    return .{ .ok = "null" };
}

fn openPath(ctx: *Ctx, args: std.json.Value) HandlerResult {
    const path = argString(args, "path") orelse if (args == .string) args.string else return .{ .err = error.InvalidArgs };
    const resolved_path = resolveAllowedPath(ctx, path) orelse return .{ .err = error.PathDenied };
    defer ctx.allocator.free(resolved_path);
    commands.openPath(resolved_path) catch return .{ .err = error.HandlerError };
    return .{ .ok = "null" };
}

fn windowSetTitle(_: *Ctx, args: std.json.Value) HandlerResult {
    const title = argString(args, "title") orelse if (args == .string) args.string else return .{ .err = error.HandlerError };
    commands.setWindowTitle(title) catch return .{ .err = error.HandlerError };
    return .{ .ok = "null" };
}

fn windowClose(_: *Ctx, _: std.json.Value) HandlerResult {
    commands.closeWindow() catch return .{ .err = error.HandlerError };
    return .{ .ok = "null" };
}

fn argString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn argBool(args: std.json.Value, key: []const u8) ?bool {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn jsonString(alloc: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(value);
    return out.toOwnedSlice();
}

fn isValidJsonFragment(alloc: std.mem.Allocator, json: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch return false;
    defer parsed.deinit();
    return true;
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

pub fn isCommandAllowed(ctx: *Ctx, name: []const u8) bool {
    if (ctx.allowed_commands.len == 0) return true;
    for (ctx.allowed_commands) |allowed| {
        if (std.mem.eql(u8, allowed, name)) return true;
    }
    return false;
}

fn isLoopbackOriginHost(host: []const u8) bool {
    const normalized = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')
        host[1 .. host.len - 1]
    else
        host;
    if (std.ascii.eqlIgnoreCase(normalized, "::1")) return true;

    var parts = std.mem.splitScalar(u8, normalized, '.');
    var count: usize = 0;
    var first: u8 = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 3) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
        const value = std.fmt.parseInt(u8, part, 10) catch return false;
        if (count == 0) first = value;
        count += 1;
        if (count > 4) return false;
    }
    return count == 4 and first == 127;
}

fn commandOriginHostsEqual(actual: []const u8, allowed: []const u8, globally_constrained: bool) bool {
    return std.ascii.eqlIgnoreCase(actual, allowed) or
        (globally_constrained and isLoopbackOriginHost(actual) and isLoopbackOriginHost(allowed));
}

pub fn isCommandOriginAllowed(ctx: *Ctx, name: []const u8) bool {
    const origin = ctx.current_origin orelse return ctx.command_origins.len == 0;
    const actual = parseOrigin(origin) orelse return false;
    var saw_rule_for_command = false;
    for (ctx.command_origins) |entry| {
        const sep = std.mem.indexOfScalar(u8, entry, '|') orelse continue;
        const cmd_name = entry[0..sep];
        if (!std.mem.eql(u8, cmd_name, name)) continue;
        saw_rule_for_command = true;
        const allowed = parseOrigin(entry[sep + 1 ..]) orelse continue;
        if (!std.ascii.eqlIgnoreCase(actual.scheme, allowed.scheme)) continue;
        // The global exact-origin check has already constrained the frame to
        // this app's ephemeral runtime origin. Treat IPv4/IPv6 loopback host
        // spellings as equivalent for generated portless command policies.
        if (!commandOriginHostsEqual(actual.host, allowed.host, ctx.allowed_origins.len != 0)) continue;
        // Command-origin entries may omit the port for ephemeral loopback apps.
        // The platform backend has already enforced the strict global origin,
        // so this does not expand bridge access beyond the loaded app origin.
        if (allowed.port) |allowed_port| {
            if (actual.port == null or !std.mem.eql(u8, actual.port.?, allowed_port)) continue;
        } else if (actual.port != null and ctx.allowed_origins.len == 0) {
            // Portless command-origin entries are only safe as a convenience
            // after a global exact-origin allowlist has already constrained the
            // runtime port. Lower-level embedders without that allowlist must
            // use exact ports in command_origins.
            continue;
        }
        return true;
    }
    return ctx.command_origins.len == 0 and !saw_rule_for_command;
}

fn isValidUrlScheme(scheme: []const u8) bool {
    if (scheme.len == 0) return false;
    for (scheme, 0..) |c, i| {
        if (i == 0) {
            if (!std.ascii.isAlphabetic(c)) return false;
        } else if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    }
    return true;
}

fn isValidPort(port: []const u8) bool {
    if (port.len == 0 or port.len > 5) return false;
    for (port) |c| if (!std.ascii.isDigit(c)) return false;
    const value = std.fmt.parseInt(u16, port, 10) catch return false;
    return value > 0;
}

fn isValidIpv6Literal(value: []const u8) bool {
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, ':') == null) return false;
    if (std.mem.indexOf(u8, value, ":::")) |_| return false;
    const compressed = std.mem.indexOf(u8, value, "::") != null;
    if (compressed and std.mem.indexOf(u8, value, "::") != std.mem.lastIndexOf(u8, value, "::")) return false;
    if (!compressed and (value[0] == ':' or value[value.len - 1] == ':')) return false;

    var groups: usize = 0;
    var it = std.mem.splitScalar(u8, value, ':');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (part.len > 4) return false;
        for (part) |c| if (!std.ascii.isHex(c)) return false;
        groups += 1;
    }
    return if (compressed) groups < 8 else groups == 8;
}

fn isValidHttpHost(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;
    var prev_dot = true;
    for (host) |c| {
        if (c == '.') {
            if (prev_dot) return false;
            prev_dot = true;
            continue;
        }
        prev_dot = false;
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    }
    return !prev_dot;
}

fn isStrictHttpUrl(url: []const u8, scheme_end: usize) bool {
    if (url.len < scheme_end + 3 or !std.mem.eql(u8, url[scheme_end + 1 .. scheme_end + 3], "//")) return false;
    const authority_start = scheme_end + 3;
    const authority_end = blk: {
        var i: usize = authority_start;
        while (i < url.len) : (i += 1) {
            switch (url[i]) {
                '/', '?', '#' => break :blk i,
                else => {},
            }
        }
        break :blk url.len;
    };
    const authority = url[authority_start..authority_end];
    if (authority.len == 0) return false;
    // Userinfo produces ambiguous native-open behavior and is unnecessary for
    // desktop handoff URLs, so deny it at the bridge boundary.
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return false;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
        if (!isValidIpv6Literal(authority[1..close])) return false;
        const rest = authority[close + 1 ..];
        return rest.len == 0 or (rest[0] == ':' and isValidPort(rest[1..]));
    }
    const colon = std.mem.indexOfScalar(u8, authority, ':');
    const host = if (colon) |c| authority[0..c] else authority;
    if (!isValidHttpHost(host)) return false;
    if (colon) |c| if (!isValidPort(authority[c + 1 ..])) return false;
    return true;
}

fn isAllowedExternalUrl(ctx: *Ctx, url: []const u8) bool {
    if (url.len == 0) return false;
    for (url) |c| {
        if (c <= 0x20 or c == 0x7f or c == '\\') return false;
    }
    const scheme_end = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    const scheme = url[0..scheme_end];
    if (!isValidUrlScheme(scheme)) return false;
    var scheme_allowed = false;
    for (ctx.external_url_schemes) |allowed| {
        if (std.ascii.eqlIgnoreCase(scheme, allowed)) {
            scheme_allowed = true;
            break;
        }
    }
    if (!scheme_allowed) return false;
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) {
        return isStrictHttpUrl(url, scheme_end);
    }
    // Non-hierarchical schemes such as mailto: still need a non-empty payload.
    return scheme_end + 1 < url.len;
}

const path_canonicalizer = if (builtin.os.tag == .windows) struct {
    fn realPathAlloc(_: std.mem.Allocator, _: []const u8) ![]u8 {
        // Windows needs drive/UNC/case-insensitive/symlink-aware canonicalization
        // before `open.path` can be enabled there. Until the WebView2 backend
        // lands, rooted open.path checks fail closed on Windows without pulling
        // POSIX libc symbols into the platform-neutral bridge.
        return error.RealPathFailed;
    }
} else struct {
    fn realPathAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
        const path_z = try alloc.dupeZ(u8, path);
        defer alloc.free(path_z);
        var buf: [std.c.PATH_MAX]u8 = undefined;
        const resolved = std.c.realpath(path_z.ptr, &buf) orelse return error.RealPathFailed;
        return try alloc.dupe(u8, std.mem.span(resolved));
    }
};

fn realPathAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return path_canonicalizer.realPathAlloc(alloc, path);
}

fn pathWithinRoot(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    return root.len > 0 and (root[root.len - 1] == '/' or (path.len > root.len and path[root.len] == '/'));
}

fn resolveAllowedPath(ctx: *Ctx, path: []const u8) ?[]u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    // `open.path` is a broad native capability; require explicit roots rather
    // than treating an omitted roots list as unrestricted filesystem access.
    if (ctx.open_path_roots.len == 0) return null;

    const resolved_path = realPathAlloc(ctx.allocator, path) catch return null;
    errdefer ctx.allocator.free(resolved_path);

    for (ctx.open_path_roots) |root| {
        if (root.len == 0 or std.mem.indexOfScalar(u8, root, 0) != null) continue;
        const resolved_root = realPathAlloc(ctx.allocator, root) catch continue;
        defer ctx.allocator.free(resolved_root);
        if (pathWithinRoot(resolved_path, resolved_root)) return resolved_path;
    }
    ctx.allocator.free(resolved_path);
    return null;
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
        // Browser origins are scheme+host+port. A portless manifest entry (for
        // example `http://127.0.0.1`) intentionally does not wildcard every
        // loopback port; shell.zig prepends the exact runtime origin after the
        // server binds its ephemeral port.
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
    token: ?[]const u8 = null,
};

fn dispatchCommand(ctx: *Ctx, env: Envelope, cmd: Command, require_explicit_allowlist: bool) BridgeError![]u8 {
    if (require_explicit_allowlist and ctx.allowed_commands.len == 0) {
        return resolveErrorForCtx(ctx, env.id, "CommandDenied");
    }
    if (!isCommandAllowed(ctx, cmd.name)) {
        return resolveErrorForCtx(ctx, env.id, "CommandDenied");
    }
    if (!isCommandOriginAllowed(ctx, cmd.name)) {
        return resolveErrorForCtx(ctx, env.id, "OriginNotAllowed");
    }
    if (!hasPermission(ctx, cmd.permission)) {
        return resolveStrForCtx(ctx, env.id, false, "\"PermissionDenied\"");
    }
    const res = cmd.handler(ctx, env.args);
    switch (res) {
        .ok => |json| {
            if (!isValidJsonFragment(ctx.allocator, json)) return resolveErrorForCtx(ctx, env.id, "HandlerError");
            return resolveStrForCtx(ctx, env.id, true, json);
        },
        .ok_owned => |json| {
            defer ctx.allocator.free(json);
            if (!isValidJsonFragment(ctx.allocator, json)) return resolveErrorForCtx(ctx, env.id, "HandlerError");
            return resolveStrForCtx(ctx, env.id, true, json);
        },
        .err => |e| return resolveErrorForCtx(ctx, env.id, @errorName(e)),
    }
}

/// Dispatch using built-ins plus an app-provided static command registry. The
/// extra registry is validated after envelope parse but before any handler runs,
/// so malformed custom command tables fail closed and still resolve the caller id.
pub fn dispatchWithRegistry(ctx: *Ctx, payload: []const u8, extra_commands: []const Command) BridgeError![]u8 {
    const alloc = ctx.allocator;

    if (payload.len > max_payload_bytes) {
        return resolveStr(alloc, 0, false, "\"PayloadTooLarge\"");
    }

    var parsed = std.json.parseFromSlice(Envelope, alloc, payload, .{}) catch {
        return resolveStr(alloc, 0, false, "\"ParseError\"");
    };
    defer parsed.deinit();
    const env = parsed.value;

    if (ctx.require_bridge_token) {
        // Do not resolve attacker-controlled ids until the request has proven
        // the session bridge capability. Forged messages should not be able to
        // reject legitimate in-flight renderer promises by guessing ids.
        const expected = ctx.bridge_token orelse return resolveError(alloc, 0, "InvalidToken");
        if (!isValidBridgeToken(expected)) return resolveError(alloc, 0, "InvalidToken");
        const supplied = env.token orelse return resolveError(alloc, 0, "InvalidToken");
        if (!std.mem.eql(u8, supplied, expected)) return resolveError(alloc, 0, "InvalidToken");
    }

    if (ctx.allowed_origins.len > 0) {
        const origin = ctx.current_origin orelse return resolveErrorForCtx(ctx, env.id, "OriginNotAllowed");
        if (!isOriginAllowed(ctx, origin)) return resolveErrorForCtx(ctx, env.id, "OriginNotAllowed");
    }

    validateCommandRegistry(extra_commands) catch {
        return resolveErrorForCtx(ctx, env.id, "InvalidRegistry");
    };

    for (builtin_registry) |cmd| {
        if (std.mem.eql(u8, cmd.name, env.cmd)) {
            return dispatchCommand(ctx, env, cmd, false);
        }
    }

    for (extra_commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, env.cmd)) {
            return dispatchCommand(ctx, env, cmd, true);
        }
    }
    return resolveErrorForCtx(ctx, env.id, "UnknownCommand");
}

/// Dispatch an inbound payload. Returns an owned JS string of the form
/// `window.mer._resolve(<id>,<ok>,<json>);` for the IMP to evaluate.
pub fn dispatch(ctx: *Ctx, payload: []const u8) BridgeError![]u8 {
    return dispatchWithRegistry(ctx, payload, ctx.extra_commands);
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

fn resolveStrWithToken(alloc: std.mem.Allocator, token: []const u8, id: i64, ok: bool, json: []const u8) BridgeError![]u8 {
    return std.fmt.allocPrint(alloc, "window.mer._resolve(\"{s}\",{d},{s},{s});", .{ token, id, if (ok) "true" else "false", json }) catch error.OutOfMemory;
}

fn resolveStrForCtx(ctx: *Ctx, id: i64, ok: bool, json: []const u8) BridgeError![]u8 {
    if (ctx.bridge_token) |token| {
        if (isValidBridgeToken(token)) return resolveStrWithToken(ctx.allocator, token, id, ok, json);
    }
    return resolveStr(ctx.allocator, id, ok, json);
}

fn resolveError(alloc: std.mem.Allocator, id: i64, name: []const u8) BridgeError![]u8 {
    return std.fmt.allocPrint(alloc, "window.mer._resolve({d},false,\"{s}\");", .{ id, name }) catch error.OutOfMemory;
}

fn resolveErrorForCtx(ctx: *Ctx, id: i64, name: []const u8) BridgeError![]u8 {
    if (ctx.bridge_token) |token| {
        if (isValidBridgeToken(token)) return std.fmt.allocPrint(ctx.allocator, "window.mer._resolve(\"{s}\",{d},false,\"{s}\");", .{ token, id, name }) catch error.OutOfMemory;
    }
    return resolveError(ctx.allocator, id, name);
}

// ── tests ───────────────────────────────────────────────────────────────────
const testing = std.testing;

fn newCtx(alloc: std.mem.Allocator, perms: []const []const u8) Ctx {
    return .{ .allocator = alloc, .permissions = perms, .require_bridge_token = false };
}

var custom_handler_called = false;

fn customOk(_: *Ctx, _: std.json.Value) HandlerResult {
    custom_handler_called = true;
    return .{ .ok = "{\"custom\":true}" };
}

fn customDanger(_: *Ctx, _: std.json.Value) HandlerResult {
    custom_handler_called = true;
    return .{ .ok = "{\"danger\":true}" };
}

fn customInvalidJson(_: *Ctx, _: std.json.Value) HandlerResult {
    custom_handler_called = true;
    return .{ .ok = "not json" };
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

test "dispatch: default context requires a bridge token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = Ctx{ .allocator = alloc, .permissions = &.{} };
    const js = try dispatch(&ctx, "{\"cmd\":\"mer.ping\",\"args\":null,\"id\":30}");
    try testing.expectEqualStrings("window.mer._resolve(0,false,\"InvalidToken\");", js);
}

test "dispatch: bridge token is required when configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    ctx.bridge_token = "abcdefghijklmnopqrstuvwxyzABCDEF";
    ctx.require_bridge_token = true;

    const missing = try dispatch(&ctx, "{\"cmd\":\"mer.ping\",\"args\":null,\"id\":31}");
    try testing.expectEqualStrings("window.mer._resolve(0,false,\"InvalidToken\");", missing);

    const wrong = try dispatch(&ctx, "{\"cmd\":\"mer.ping\",\"args\":null,\"id\":32,\"token\":\"wrong-token-wrong-token-wrong-token\"}");
    try testing.expectEqualStrings("window.mer._resolve(0,false,\"InvalidToken\");", wrong);

    const ok = try dispatch(&ctx, "{\"cmd\":\"mer.ping\",\"args\":null,\"id\":33,\"token\":\"abcdefghijklmnopqrstuvwxyzABCDEF\"}");
    try testing.expectEqualStrings("window.mer._resolve(\"abcdefghijklmnopqrstuvwxyzABCDEF\",33,true,{\"pong\":true});", ok);
}

test "dispatch: invalid configured bridge token fails closed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    ctx.bridge_token = "short";
    ctx.require_bridge_token = true;
    const js = try dispatch(&ctx, "{\"cmd\":\"mer.ping\",\"args\":null,\"id\":34,\"token\":\"short\"}");
    try testing.expectEqualStrings("window.mer._resolve(0,false,\"InvalidToken\");", js);
}

test "dispatch: uses custom commands stored on context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    custom_handler_called = false;
    const extra = [_]Command{.{ .name = "app.exportData", .permission = "app.export", .handler = customOk }};
    var ctx = newCtx(alloc, &.{"app.export"});
    ctx.allowed_commands = &.{"app.exportData"};
    ctx.extra_commands = &extra;
    const js = try dispatch(&ctx, "{\"cmd\":\"app.exportData\",\"args\":null,\"id\":20}");
    try testing.expectEqualStrings("window.mer._resolve(20,true,{\"custom\":true});", js);
    try testing.expect(custom_handler_called);
}

test "dispatchWithRegistry: custom command requires explicit allowlist permission and origin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    custom_handler_called = false;
    var ctx = newCtx(alloc, &.{"app.export"});
    ctx.allowed_origins = &.{"http://127.0.0.1:49152"};
    ctx.allowed_commands = &.{"app.exportData"};
    ctx.command_origins = &.{"app.exportData|http://127.0.0.1"};
    ctx.current_origin = "http://127.0.0.1:49152";
    const extra = [_]Command{.{ .name = "app.exportData", .permission = "app.export", .handler = customOk }};
    const js = try dispatchWithRegistry(&ctx, "{\"cmd\":\"app.exportData\",\"args\":null,\"id\":21}", &extra);
    try testing.expectEqualStrings("window.mer._resolve(21,true,{\"custom\":true});", js);
    try testing.expect(custom_handler_called);
}

test "dispatchWithRegistry: custom command is denied when not explicitly allowlisted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    custom_handler_called = false;
    var ctx = newCtx(alloc, &.{"app.export"});
    const extra = [_]Command{.{ .name = "app.exportData", .permission = "app.export", .handler = customOk }};
    const js = try dispatchWithRegistry(&ctx, "{\"cmd\":\"app.exportData\",\"args\":null,\"id\":22}", &extra);
    try testing.expectEqualStrings("window.mer._resolve(22,false,\"CommandDenied\");", js);
    try testing.expect(!custom_handler_called);
}

test "dispatchWithRegistry: custom command invalid JSON is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    custom_handler_called = false;
    var ctx = newCtx(alloc, &.{"app.export"});
    ctx.allowed_commands = &.{"app.badJson"};
    const extra = [_]Command{.{ .name = "app.badJson", .permission = "app.export", .handler = customInvalidJson }};
    const js = try dispatchWithRegistry(&ctx, "{\"cmd\":\"app.badJson\",\"args\":null,\"id\":27}", &extra);
    try testing.expectEqualStrings("window.mer._resolve(27,false,\"HandlerError\");", js);
    try testing.expect(custom_handler_called);
}

test "dispatchWithRegistry: custom command without permission is invalid and not invoked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    custom_handler_called = false;
    var ctx = newCtx(alloc, &.{});
    ctx.allowed_commands = &.{"app.danger"};
    const extra = [_]Command{.{ .name = "app.danger", .permission = "", .handler = customDanger }};
    const js = try dispatchWithRegistry(&ctx, "{\"cmd\":\"app.danger\",\"args\":null,\"id\":23}", &extra);
    try testing.expectEqualStrings("window.mer._resolve(23,false,\"InvalidRegistry\");", js);
    try testing.expect(!custom_handler_called);
}

test "dispatchWithRegistry: invalid custom registry blocks built-ins before handlers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    custom_handler_called = false;
    var ctx = newCtx(alloc, &.{});
    const extra = [_]Command{.{ .name = "mer.ping", .permission = "app.fake", .handler = customDanger }};
    const js = try dispatchWithRegistry(&ctx, "{\"cmd\":\"mer.ping\",\"args\":null,\"id\":24}", &extra);
    try testing.expectEqualStrings("window.mer._resolve(24,false,\"InvalidRegistry\");", js);
    try testing.expect(!custom_handler_called);
}

test "validateCommandRegistry rejects reserved prefixes case-insensitively" {
    const extra = [_]Command{
        .{ .name = "Mer.fake", .permission = "app.fake", .handler = customDanger },
        .{ .name = "OPEN.fake", .permission = "app.fake", .handler = customDanger },
        .{ .name = "Window.fake", .permission = "app.fake", .handler = customDanger },
    };
    for (extra) |cmd| {
        const one = [_]Command{cmd};
        try testing.expectError(error.InvalidRegistry, validateCommandRegistry(&one));
    }
}

test "dispatchWithRegistry: duplicate custom commands are invalid" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    custom_handler_called = false;
    var ctx = newCtx(alloc, &.{"app.export"});
    ctx.allowed_commands = &.{"app.exportData"};
    const extra = [_]Command{
        .{ .name = "app.exportData", .permission = "app.export", .handler = customOk },
        .{ .name = "app.exportData", .permission = "app.export", .handler = customDanger },
    };
    const js = try dispatchWithRegistry(&ctx, "{\"cmd\":\"app.exportData\",\"args\":null,\"id\":25}", &extra);
    try testing.expectEqualStrings("window.mer._resolve(25,false,\"InvalidRegistry\");", js);
    try testing.expect(!custom_handler_called);
}

test "dispatchWithRegistry: command origin bindings deny missing origin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    custom_handler_called = false;
    var ctx = newCtx(alloc, &.{"app.export"});
    ctx.allowed_commands = &.{"app.exportData"};
    ctx.command_origins = &.{"app.exportData|http://127.0.0.1"};
    const extra = [_]Command{.{ .name = "app.exportData", .permission = "app.export", .handler = customOk }};
    const js = try dispatchWithRegistry(&ctx, "{\"cmd\":\"app.exportData\",\"args\":null,\"id\":26}", &extra);
    try testing.expectEqualStrings("window.mer._resolve(26,false,\"OriginNotAllowed\");", js);
    try testing.expect(!custom_handler_called);
}

test "dispatchWithRegistry: global origin allowlist is enforced in bridge dispatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    ctx.allowed_origins = &.{"http://127.0.0.1:3000"};
    ctx.current_origin = "http://127.0.0.1:4444";
    ctx.command_origins = &.{"mer.ping|http://127.0.0.1"};
    const js = try dispatch(&ctx, "{\"cmd\":\"mer.ping\",\"args\":null,\"id\":28}");
    try testing.expectEqualStrings("window.mer._resolve(28,false,\"OriginNotAllowed\");", js);
}

test "dispatchWithRegistry: generated IPv4 command origins allow an exact IPv6 runtime" {
    try testing.expect(commandOriginHostsEqual("[::1]", "127.0.0.1", true));
    try testing.expect(!commandOriginHostsEqual("[::1]", "127.0.0.1", false));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    ctx.allowed_origins = &.{"http://[::1]:4444"};
    ctx.current_origin = "http://[::1]:4444";
    ctx.command_origins = &.{"mer.ping|http://127.0.0.1"};
    const js = try dispatch(&ctx, "{\"cmd\":\"mer.ping\",\"args\":null,\"id\":30}");
    try testing.expectEqualStrings("window.mer._resolve(30,true,{\"pong\":true});", js);
}

test "dispatchWithRegistry: portless command origins require global origin allowlist" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    ctx.current_origin = "http://127.0.0.1:4444";
    ctx.command_origins = &.{"mer.ping|http://127.0.0.1"};
    const js = try dispatch(&ctx, "{\"cmd\":\"mer.ping\",\"args\":null,\"id\":29}");
    try testing.expectEqualStrings("window.mer._resolve(29,false,\"OriginNotAllowed\");", js);
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

test "jsonString returns an owned exact slice" {
    const json = try jsonString(testing.allocator, "clipboard text");
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("\"clipboard text\"", json);
}

test "dispatch: clipboard read owned result is freeable" {
    if (!platform_commands.has_platform_commands) return error.SkipZigTest;

    var ctx = newCtx(testing.allocator, &.{"clipboard"});
    const js = try dispatch(&ctx, "{\"cmd\":\"clipboard.read\",\"args\":null,\"id\":9}");
    defer testing.allocator.free(js);
    try testing.expect(std.mem.startsWith(u8, js, "window.mer._resolve(9,true,"));
}

test "hasPermission: empty perm always allowed" {
    var ctx = newCtx(testing.allocator, &.{});
    try testing.expect(hasPermission(&ctx, ""));
}

test "dispatch: explicit command allowlist denies unlisted commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{"window"});
    ctx.allowed_commands = &.{"mer.ping"};
    const js = try dispatch(&ctx, "{\"cmd\":\"window.close\",\"args\":null,\"id\":11}");
    try testing.expectEqualStrings("window.mer._resolve(11,false,\"CommandDenied\");", js);
}

test "dispatch: per-command origin bindings deny commands without a rule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    ctx.allowed_commands = &.{ "mer.ping", "mer.echo" };
    ctx.command_origins = &.{"mer.ping|http://127.0.0.1:3000"};
    ctx.current_origin = "http://127.0.0.1:3000";
    const js = try dispatch(&ctx, "{\"cmd\":\"mer.echo\",\"args\":null,\"id\":16}");
    try testing.expectEqualStrings("window.mer._resolve(16,false,\"OriginNotAllowed\");", js);
}

test "dispatch: per-command origin bindings deny wrong origins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    ctx.allowed_commands = &.{"mer.ping"};
    ctx.command_origins = &.{"mer.ping|http://127.0.0.1:3000"};
    ctx.current_origin = "http://evil.test";
    const js = try dispatch(&ctx, "{\"cmd\":\"mer.ping\",\"args\":null,\"id\":12}");
    try testing.expectEqualStrings("window.mer._resolve(12,false,\"OriginNotAllowed\");", js);
}

test "dispatch: open.external rejects disallowed URL schemes before native open" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{"open"});
    ctx.allowed_commands = &.{"open.external"};
    const js = try dispatch(&ctx, "{\"cmd\":\"open.external\",\"args\":{\"url\":\"javascript:alert(1)\"},\"id\":13}");
    try testing.expectEqualStrings("window.mer._resolve(13,false,\"UrlDenied\");", js);
}

test "dispatch: open.external rejects malformed allowed-scheme URLs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{"open"});
    ctx.allowed_commands = &.{"open.external"};
    const bad = [_][]const u8{
        "https:example.com",
        "https://user@example.com",
        "https://example.com/has space",
        "http:javascript:alert(1)",
        "https://[not-an-ipv6]/",
        "https://exa<mple.com/",
        "https://example.com|evil/",
        "https://example.com^evil/",
    };
    for (bad, 0..) |url, i| {
        const payload = try std.fmt.allocPrint(alloc, "{{\"cmd\":\"open.external\",\"args\":{{\"url\":\"{s}\"}},\"id\":{d}}}", .{ url, 40 + i });
        const js = try dispatch(&ctx, payload);
        try testing.expect(std.mem.indexOf(u8, js, "UrlDenied") != null);
    }
}

test "dispatch: open.external allows strict http and mailto URLs" {
    var ctx = newCtx(testing.allocator, &.{"open"});
    try testing.expect(!isAllowedExternalUrl(&ctx, "https://example.com\\@evil.test"));
    try testing.expect(!isAllowedExternalUrl(&ctx, "https://example.com/has\x01control"));
    try testing.expect(isAllowedExternalUrl(&ctx, "https://example.com/path?x=1#frag"));
    try testing.expect(isAllowedExternalUrl(&ctx, "https://[::1]:8443/"));
    try testing.expect(isAllowedExternalUrl(&ctx, "http://127.0.0.1:8080/"));
    try testing.expect(isAllowedExternalUrl(&ctx, "mailto:hello@example.com"));
}

test "dispatch: open.path rejects when no roots are configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{"open"});
    const js = try dispatch(&ctx, "{\"cmd\":\"open.path\",\"args\":{\"path\":\"/tmp/file\"},\"id\":17}");
    try testing.expectEqualStrings("window.mer._resolve(17,false,\"PathDenied\");", js);
}

test "dispatch: open.path rejects paths outside configured roots before native open" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{"open"});
    ctx.allowed_commands = &.{"open.path"};
    ctx.open_path_roots = &.{"/safe/root"};
    const js = try dispatch(&ctx, "{\"cmd\":\"open.path\",\"args\":{\"path\":\"/safe/root-evil/file\"},\"id\":14}");
    try testing.expectEqualStrings("window.mer._resolve(14,false,\"PathDenied\");", js);
}

test "dispatch: open.path rejects parent traversal outside configured roots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{"open"});
    ctx.allowed_commands = &.{"open.path"};
    ctx.open_path_roots = &.{"public"};
    const js = try dispatch(&ctx, "{\"cmd\":\"open.path\",\"args\":{\"path\":\"public/../build.zig\"},\"id\":15}");
    try testing.expectEqualStrings("window.mer._resolve(15,false,\"PathDenied\");", js);
}

test "isOriginAllowed: matches scheme host and port, not string prefixes" {
    var ctx = Ctx{
        .allocator = testing.allocator,
        .permissions = &.{},
        .allowed_origins = &.{ "http://127.0.0.1", "http://127.0.0.1:49152", "mer://app", "http://localhost:3000" },
    };
    try testing.expect(isOriginAllowed(&ctx, "http://127.0.0.1:49152/"));
    try testing.expect(isOriginAllowed(&ctx, "http://127.0.0.1/"));
    try testing.expect(isOriginAllowed(&ctx, "mer://app/index.html"));
    try testing.expect(isOriginAllowed(&ctx, "http://localhost:3000/"));
    try testing.expect(!isOriginAllowed(&ctx, "http://127.0.0.1:31337/"));
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
