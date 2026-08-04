// manifest.zig — comptime parsing/validation of `mer.app.zon`.
//
// The manifest is a .zon file imported as a module (`manifest`) wired in
// build.zig to the project's `mer.app.zon`. Because it is `@import`-ed, every
// field is comptime-known and flows into the build with zero runtime parsing.
//
// This mirrors how `build.zig.zon` is consumed by `build.zig` itself.

const std = @import("std");

/// A single window declaration from the manifest.
pub const WindowConfig = struct {
    label: []const u8 = "main",
    title: []const u8 = "merjs app",
    width: u32 = 1024,
    height: u32 = 720,
};

pub const BridgeSecurityConfig = struct {
    /// Optional command allowlist. Empty means "all built-ins allowed by permission".
    /// Generated manifests set this explicitly for Tauri-style least privilege.
    allowed_commands: []const []const u8 = &.{},
    /// Optional per-command origin bindings, encoded as "command|origin" strings.
    /// Example: "clipboard.read|http://127.0.0.1".
    command_origins: []const []const u8 = &.{},
};

pub const OpenSecurityConfig = struct {
    /// URL schemes that `open.external` may hand to the OS.
    external_schemes: []const []const u8 = &.{ "http", "https", "mailto" },
    /// Optional path roots for `open.path`. Empty disables `open.path`;
    /// generated manifests set explicit roots for production apps.
    path_roots: []const []const u8 = &.{},
};

pub const SecurityConfig = struct {
    /// Extra origins allowed to navigate and call the bridge. The shell always
    /// injects the exact runtime loopback origin after binding its ephemeral
    /// port; defaults stay empty to avoid authorizing unrelated local servers.
    allowed_origins: []const []const u8 = &.{},
    bridge: BridgeSecurityConfig = .{},
    open: OpenSecurityConfig = .{},
};

pub const MacOSConfig = struct {
    signing_identity: ?[]const u8 = null,
    team_id: ?[]const u8 = null,
    entitlements: ?[]const u8 = null,
    notarization_profile: ?[]const u8 = null,
};

pub const UpdateConfig = struct {
    provider: ?[]const u8 = null,
    feed_url: ?[]const u8 = null,
    public_key: ?[]const u8 = null,
};

/// Resolved manifest. Built comptime from the imported .zon struct.
pub const Manifest = struct {
    id: []const u8,
    name: []const u8,
    display_name: []const u8,
    version: []const u8,
    web_engine: []const u8,
    server_mode: []const u8,
    host: []const u8,
    port: u16,
    watch_dir: []const u8,
    /// Directory to serve static files from (e.g. "dist" for a built SPA).
    /// null = serve from public/ (merjs default).
    static_dir: ?[]const u8,
    dev: bool,
    window: WindowConfig,
    permissions: []const []const u8,
    capabilities: []const []const u8,
    security: SecurityConfig = .{},
    macos: MacOSConfig = .{},
    update: UpdateConfig = .{},
};

/// Extract a `Manifest` from an imported .zon struct, applying defaults for
/// any optional fields. `zon` is the value of `@import("manifest")`.
pub fn fromZon(comptime zon: anytype) Manifest {
    const T = @TypeOf(zon);

    // server{} block is optional; default to embedded loopback on port 0.
    const has_server = @hasField(T, "server");
    const ServerT = if (has_server) @TypeOf(zon.server) else struct {};
    const server_mode = if (has_server and @hasField(ServerT, "mode")) zon.server.mode else "embedded";
    const host = if (has_server and @hasField(ServerT, "host")) zon.server.host else "127.0.0.1";
    const port: u16 = if (has_server and @hasField(ServerT, "port")) zon.server.port else 0;
    const watch_dir = if (has_server and @hasField(ServerT, "watch_dir")) zon.server.watch_dir else "app";
    const static_dir: ?[]const u8 = if (has_server and @hasField(ServerT, "static_dir")) zon.server.static_dir else null;

    // First window drives the shell. windows[] is required.
    const win = zon.windows[0];
    const WinT = @TypeOf(win);
    const default_window: WindowConfig = .{};
    const window = WindowConfig{
        .label = if (@hasField(WinT, "label")) win.label else default_window.label,
        .title = if (@hasField(WinT, "title")) win.title else default_window.title,
        .width = if (@hasField(WinT, "width")) win.width else default_window.width,
        .height = if (@hasField(WinT, "height")) win.height else default_window.height,
    };

    // permissions[] and capabilities[] are optional.
    const perms: []const []const u8 = if (@hasField(T, "permissions")) &zon.permissions else &.{};
    const caps: []const []const u8 = if (@hasField(T, "capabilities")) &zon.capabilities else &.{};

    const security: SecurityConfig = if (@hasField(T, "security")) blk: {
        const SecurityT = @TypeOf(zon.security);
        const allowed_origins = if (@hasField(SecurityT, "navigation")) nav_blk: {
            const NavigationT = @TypeOf(zon.security.navigation);
            if (@hasField(NavigationT, "allowed_origins")) break :nav_blk &zon.security.navigation.allowed_origins;
            break :nav_blk (SecurityConfig{}).allowed_origins;
        } else (SecurityConfig{}).allowed_origins;
        const bridge = if (@hasField(SecurityT, "bridge")) bridge_blk: {
            const BridgeT = @TypeOf(zon.security.bridge);
            break :bridge_blk BridgeSecurityConfig{
                .allowed_commands = if (@hasField(BridgeT, "allowed_commands")) &zon.security.bridge.allowed_commands else &.{},
                .command_origins = if (@hasField(BridgeT, "command_origins")) &zon.security.bridge.command_origins else &.{},
            };
        } else BridgeSecurityConfig{};
        const open = if (@hasField(SecurityT, "open")) open_blk: {
            const OpenT = @TypeOf(zon.security.open);
            break :open_blk OpenSecurityConfig{
                .external_schemes = if (@hasField(OpenT, "external_schemes")) &zon.security.open.external_schemes else (OpenSecurityConfig{}).external_schemes,
                .path_roots = if (@hasField(OpenT, "path_roots")) &zon.security.open.path_roots else &.{},
            };
        } else OpenSecurityConfig{};
        break :blk .{ .allowed_origins = allowed_origins, .bridge = bridge, .open = open };
    } else .{};

    const macos: MacOSConfig = if (@hasField(T, "macos")) blk: {
        const MacT = @TypeOf(zon.macos);
        break :blk .{
            .signing_identity = if (@hasField(MacT, "signing_identity")) zon.macos.signing_identity else null,
            .team_id = if (@hasField(MacT, "team_id")) zon.macos.team_id else null,
            .entitlements = if (@hasField(MacT, "entitlements")) zon.macos.entitlements else null,
            .notarization_profile = if (@hasField(MacT, "notarization_profile")) zon.macos.notarization_profile else null,
        };
    } else .{};

    const update: UpdateConfig = if (@hasField(T, "update")) blk: {
        const UpdateT = @TypeOf(zon.update);
        break :blk .{
            .provider = if (@hasField(UpdateT, "provider")) zon.update.provider else null,
            .feed_url = if (@hasField(UpdateT, "feed_url")) zon.update.feed_url else null,
            .public_key = if (@hasField(UpdateT, "public_key")) zon.update.public_key else null,
        };
    } else .{};

    return .{
        .id = zon.id,
        .name = zon.name,
        .display_name = zon.display_name,
        .version = zon.version,
        .web_engine = zon.web_engine,
        .server_mode = server_mode,
        .host = host,
        .port = port,
        .watch_dir = watch_dir,
        .static_dir = static_dir,
        .dev = std.mem.eql(u8, server_mode, "dev"),
        .window = window,
        .permissions = perms,
        .capabilities = caps,
        .security = security,
        .macos = macos,
        .update = update,
    };
}

fn parseIpv4Byte(part: []const u8) ?u8 {
    if (part.len == 0 or part.len > 3 or (part.len > 1 and part[0] == '0')) return null;
    for (part) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u8, part, 10) catch null;
}

fn isIpv4LoopbackLiteral(host: []const u8) bool {
    var it = std.mem.splitScalar(u8, host, '.');
    var count: usize = 0;
    var first: u8 = 0;
    while (it.next()) |part| {
        const value = parseIpv4Byte(part) orelse return false;
        if (count == 0) first = value;
        count += 1;
        if (count > 4) return false;
    }
    return count == 4 and first == 127;
}

/// True when a native server host stays on local loopback. The native bridge
/// security model assumes the embedded HTTP server is not LAN/publicly exposed.
pub fn isLoopbackHost(host: []const u8) bool {
    return isIpv4LoopbackLiteral(host) or
        std.ascii.eqlIgnoreCase(host, "::1") or
        std.ascii.eqlIgnoreCase(host, "[::1]");
}

/// True if the manifest declares a capability (e.g. "webview", "js_bridge").
pub fn hasCapability(manifest: Manifest, cap: []const u8) bool {
    for (manifest.capabilities) |declared| {
        if (std.mem.eql(u8, declared, cap)) return true;
    }
    return false;
}

test "isLoopbackHost only accepts local native bind hosts" {
    try std.testing.expect(isLoopbackHost("127.0.0.1"));
    try std.testing.expect(isLoopbackHost("127.10.20.30"));
    try std.testing.expect(isLoopbackHost("::1"));
    try std.testing.expect(isLoopbackHost("[::1]"));
    try std.testing.expect(!isLoopbackHost("localhost"));
    try std.testing.expect(!isLoopbackHost("127.000.000.001"));
    try std.testing.expect(!isLoopbackHost("2130706433"));
    try std.testing.expect(!isLoopbackHost("0177.0.0.1"));
    try std.testing.expect(!isLoopbackHost("0x7f000001"));
    try std.testing.expect(!isLoopbackHost("127.1"));
    try std.testing.expect(!isLoopbackHost("0:0:0:0:0:0:0:1"));
    try std.testing.expect(!isLoopbackHost("[0:0:0:0:0:0:0:1]"));
    try std.testing.expect(!isLoopbackHost("::127.0.0.1"));
    try std.testing.expect(!isLoopbackHost("::ffff:127.0.0.1"));
    try std.testing.expect(!isLoopbackHost("::7f00:1"));
    try std.testing.expect(!isLoopbackHost("::ffff:7f00:1"));
    try std.testing.expect(!isLoopbackHost("127.example.com"));
    try std.testing.expect(!isLoopbackHost("127.0.0.1.evil"));
    try std.testing.expect(!isLoopbackHost("0.0.0.0"));
    try std.testing.expect(!isLoopbackHost("192.168.1.5"));
    try std.testing.expect(!isLoopbackHost("example.com"));
}

test "fromZon parses allowed origins" {
    const zon = .{
        .id = "com.example.test",
        .name = "test",
        .display_name = "Test",
        .version = "0.1.0",
        .web_engine = "system",
        .security = .{
            .navigation = .{ .allowed_origins = .{ "http://127.0.0.1", "mer://app" } },
        },
        .windows = .{
            .{ .label = "main", .title = "Test", .width = 800, .height = 600 },
        },
    };
    const parsed = fromZon(zon);
    try std.testing.expectEqual(@as(usize, 2), parsed.security.allowed_origins.len);
    try std.testing.expectEqualStrings("mer://app", parsed.security.allowed_origins[1]);
}

test "fromZon parses capabilities" {
    const zon = .{
        .id = "com.example.test",
        .name = "test",
        .display_name = "Test",
        .version = "0.1.0",
        .web_engine = "system",
        .capabilities = .{ "webview", "js_bridge" },
        .windows = .{
            .{ .title = "Test" },
        },
    };
    const parsed = fromZon(zon);
    try std.testing.expect(hasCapability(parsed, "webview"));
    try std.testing.expect(hasCapability(parsed, "js_bridge"));
    try std.testing.expect(!hasCapability(parsed, "clipboard"));
}

test "fromZon defaults omitted capabilities" {
    const zon = .{
        .id = "com.example.test",
        .name = "test",
        .display_name = "Test",
        .version = "0.1.0",
        .web_engine = "system",
        .windows = .{
            .{ .title = "Test" },
        },
    };
    const parsed = fromZon(zon);
    try std.testing.expect(!hasCapability(parsed, "webview"));
}

test "fromZon defaults navigation origins to shell-injected runtime origin only" {
    const zon = .{
        .id = "com.example.test",
        .name = "test",
        .display_name = "Test",
        .version = "0.1.0",
        .web_engine = "system",
        .windows = .{
            .{ .title = "Test" },
        },
    };
    const parsed = fromZon(zon);
    try std.testing.expectEqual(@as(usize, 0), parsed.security.allowed_origins.len);
}

test "fromZon applies optional server watch_dir" {
    const zon = .{
        .id = "com.example.test",
        .name = "test",
        .display_name = "Test",
        .version = "0.1.0",
        .web_engine = "system",
        .server = .{
            .mode = "dev",
            .host = "127.0.0.1",
            .port = 0,
            .watch_dir = "examples/site/app",
        },
        .windows = .{
            .{ .title = "Test" },
        },
    };
    const parsed = fromZon(zon);
    try std.testing.expectEqualStrings("examples/site/app", parsed.watch_dir);
    try std.testing.expect(parsed.dev);
}

test "fromZon parses native security hardening blocks" {
    const zon = .{
        .id = "com.example.test",
        .name = "test",
        .display_name = "Test",
        .version = "0.1.0",
        .web_engine = "system",
        .security = .{
            .navigation = .{ .allowed_origins = .{"http://127.0.0.1"} },
            .bridge = .{
                .allowed_commands = .{ "mer.ping", "window.close" },
                .command_origins = .{"window.close|http://127.0.0.1"},
            },
            .open = .{
                .external_schemes = .{"https"},
                .path_roots = .{"/tmp/test"},
            },
        },
        .macos = .{
            .signing_identity = "Developer ID Application: Example (TEAMID)",
            .team_id = "TEAMID",
            .entitlements = "native/entitlements.plist",
            .notarization_profile = "merjs-notary",
        },
        .update = .{
            .provider = "github-releases",
            .feed_url = "https://example.com/update.json",
            .public_key = "ed25519:example",
        },
        .windows = .{
            .{ .title = "Test" },
        },
    };
    const parsed = fromZon(zon);
    try std.testing.expectEqualStrings("window.close", parsed.security.bridge.allowed_commands[1]);
    try std.testing.expectEqualStrings("window.close|http://127.0.0.1", parsed.security.bridge.command_origins[0]);
    try std.testing.expectEqualStrings("https", parsed.security.open.external_schemes[0]);
    try std.testing.expectEqualStrings("/tmp/test", parsed.security.open.path_roots[0]);
    try std.testing.expectEqualStrings("Developer ID Application: Example (TEAMID)", parsed.macos.signing_identity.?);
    try std.testing.expectEqualStrings("TEAMID", parsed.macos.team_id.?);
    try std.testing.expectEqualStrings("native/entitlements.plist", parsed.macos.entitlements.?);
    try std.testing.expectEqualStrings("merjs-notary", parsed.macos.notarization_profile.?);
    try std.testing.expectEqualStrings("github-releases", parsed.update.provider.?);
    try std.testing.expectEqualStrings("https://example.com/update.json", parsed.update.feed_url.?);
    try std.testing.expectEqualStrings("ed25519:example", parsed.update.public_key.?);
}

test "fromZon defaults omitted window fields" {
    const zon = .{
        .id = "com.example.test",
        .name = "test",
        .display_name = "Test",
        .version = "0.1.0",
        .web_engine = "system",
        .windows = .{
            .{ .title = "Only Title" },
        },
    };
    const parsed = fromZon(zon);
    try std.testing.expectEqualStrings("main", parsed.window.label);
    try std.testing.expectEqualStrings("Only Title", parsed.window.title);
    try std.testing.expectEqual(@as(u32, 1024), parsed.window.width);
    try std.testing.expectEqual(@as(u32, 720), parsed.window.height);
    try std.testing.expectEqualStrings("app", parsed.watch_dir);
}

test "fromZon applies complete minimal manifest defaults" {
    const parsed = fromZon(.{
        .id = "com.example.minimal",
        .name = "minimal",
        .display_name = "Minimal",
        .version = "0.1.0",
        .web_engine = "system",
        .windows = .{.{}},
    });
    try std.testing.expectEqualStrings("embedded", parsed.server_mode);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.host);
    try std.testing.expectEqual(@as(u16, 0), parsed.port);
    try std.testing.expectEqualStrings("app", parsed.watch_dir);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.static_dir);
    try std.testing.expect(!parsed.dev);
    try std.testing.expectEqual(@as(usize, 0), parsed.permissions.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.capabilities.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.security.allowed_origins.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.security.bridge.allowed_commands.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.security.bridge.command_origins.len);
    try std.testing.expectEqualStrings("http", parsed.security.open.external_schemes[0]);
    try std.testing.expectEqualStrings("https", parsed.security.open.external_schemes[1]);
    try std.testing.expectEqualStrings("mailto", parsed.security.open.external_schemes[2]);
    try std.testing.expectEqual(@as(usize, 0), parsed.security.open.path_roots.len);
    try std.testing.expect(parsed.macos.signing_identity == null);
    try std.testing.expect(parsed.macos.team_id == null);
    try std.testing.expect(parsed.macos.entitlements == null);
    try std.testing.expect(parsed.macos.notarization_profile == null);
    try std.testing.expect(parsed.update.provider == null);
    try std.testing.expect(parsed.update.feed_url == null);
    try std.testing.expect(parsed.update.public_key == null);
}

test "fromZon defaults omitted fields inside a partial server block" {
    const parsed = fromZon(.{
        .id = "com.example.partial-server",
        .name = "partial-server",
        .display_name = "Partial Server",
        .version = "0.1.0",
        .web_engine = "system",
        .server = .{ .mode = "dev" },
        .windows = .{.{}},
    });
    try std.testing.expectEqualStrings("dev", parsed.server_mode);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.host);
    try std.testing.expectEqual(@as(u16, 0), parsed.port);
    try std.testing.expectEqualStrings("app", parsed.watch_dir);
    try std.testing.expect(parsed.static_dir == null);
}

test "fromZon parses explicit static directory" {
    const parsed = fromZon(.{
        .id = "com.example.static",
        .name = "static",
        .display_name = "Static",
        .version = "0.1.0",
        .web_engine = "system",
        .server = .{ .mode = "embedded", .host = "127.0.0.1", .port = 0, .static_dir = "dist" },
        .windows = .{.{}},
    });
    try std.testing.expectEqualStrings("dist", parsed.static_dir.?);
}
