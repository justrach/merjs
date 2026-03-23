// kuri.zig — kuri browser automation sidecar for debug mode.
// Spawns Chrome + kuri and proxies /_mer/kuri/* requests to kuri's HTTP API.

const std = @import("std");
const log = std.log.scoped(.kuri);
pub const default_port: u16 = 9222;

pub const Kuri = struct {
    child: ?std.process.Child,
    chrome: ?std.process.Child,
    port: u16,
    app_port: u16,
    allocator: std.mem.Allocator,

    const cdp_port: u16 = 9223;

    pub fn spawn(allocator: std.mem.Allocator, app_port: u16, kuri_port: u16) Kuri {
        var self = Kuri{
            .child = null,
            .chrome = null,
            .port = kuri_port,
            .app_port = app_port,
            .allocator = allocator,
        };

        const kuri_bin = findKuriBinary(allocator) orelse {
            log.warn("kuri binary not found — debug browser automation disabled", .{});
            log.warn("install: curl -fsSL https://raw.githubusercontent.com/justrach/kuri/main/install.sh | sh", .{});
            return self;
        };
        defer allocator.free(kuri_bin);

        // Launch headless Chrome with a known CDP port.
        self.chrome = launchChrome(allocator, cdp_port);
        if (self.chrome == null) {
            log.warn("Chrome not found — debug browser automation disabled", .{});
            return self;
        }
        std.Thread.sleep(1 * std.time.ns_per_s);

        // Set env vars for kuri — needs null-terminated strings for C setenv.
        var port_z: [8:0]u8 = .{0} ** 8;
        _ = std.fmt.bufPrint(&port_z, "{d}", .{kuri_port}) catch return self;
        var cdp_z: [64:0]u8 = .{0} ** 64;
        _ = std.fmt.bufPrint(&cdp_z, "ws://127.0.0.1:{d}", .{cdp_port}) catch return self;

        var child = std.process.Child.init(&.{kuri_bin}, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        var env_map = std.process.EnvMap.init(allocator);
        env_map.put("PORT", &port_z) catch {};
        env_map.put("HOST", "127.0.0.1") catch {};
        env_map.put("CDP_URL", &cdp_z) catch {};
        env_map.put("HEADLESS", "true") catch {};
        child.env_map = &env_map;
        child.spawn() catch |err| {
            log.warn("failed to spawn kuri: {} — debug browser automation disabled", .{err});
            return self;
        };

        self.child = child;

        log.info("kuri started on :{d} — browser automation active", .{kuri_port});
        log.info("  snapshot:   /_mer/kuri/snapshot", .{});
        log.info("  screenshot: /_mer/kuri/screenshot", .{});
        log.info("  navigate:   /_mer/kuri/navigate?url=/your-page", .{});
        log.info("  dashboard:  /_mer/kuri/", .{});
        return self;
    }

    pub fn deinit(self: *Kuri) void {
        if (self.child) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }
        self.child = null;
        if (self.chrome) |*chrome| {
            _ = chrome.kill() catch {};
            _ = chrome.wait() catch {};
        }
        self.chrome = null;
    }

    pub fn isRunning(self: *const Kuri) bool {
        return self.child != null;
    }

    /// Proxy a request to the kuri sidecar.
    pub fn proxyRequest(
        self: *const Kuri,
        alloc: std.mem.Allocator,
        std_req: *std.http.Server.Request,
        raw_target: []const u8,
    ) !void {
        const kuri_path = if (std.mem.startsWith(u8, raw_target, "/_mer/kuri"))
            raw_target["/_mer/kuri".len..]
        else
            raw_target;

        const target = if (kuri_path.len == 0 or std.mem.eql(u8, kuri_path, "/"))
            "/health"
        else
            kuri_path;

        var url_buf: [2048]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ self.port, target }) catch {
            try sendKuriError(std_req, "URL too long");
            return;
        };

        var client = std.http.Client{ .allocator = alloc };
        defer client.deinit();

        var collecting: std.io.Writer.Allocating = .init(alloc);
        defer collecting.deinit();

        _ = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &collecting.writer,
        }) catch {
            try sendKuriError(std_req, "kuri is not responding — is it running?");
            return;
        };

        const body = if (collecting.writer.end > 0)
            collecting.writer.buffer[0..collecting.writer.end]
        else
            "{\"status\":\"ok\"}";

        const fixed = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        };
        std_req.respond(body, .{ .extra_headers = &fixed }) catch {};
    }
};


fn sendKuriError(std_req: *std.http.Server.Request, msg: []const u8) !void {
    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{msg}) catch msg;
    const fixed = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };
    std_req.respond(body, .{
        .status = .service_unavailable,
        .extra_headers = &fixed,
    }) catch {};
}

fn launchChrome(allocator: std.mem.Allocator, port: u16) ?std.process.Child {
    const chrome_paths = [_][]const u8{
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "google-chrome",
        "chromium",
    };

    var port_buf: [32]u8 = undefined;
    const port_arg = std.fmt.bufPrint(&port_buf, "--remote-debugging-port={d}", .{port}) catch return null;

    for (chrome_paths) |chrome_path| {
        var child = std.process.Child.init(
            &.{ chrome_path, "--headless", "--disable-gpu", "--no-sandbox", "--incognito", port_arg, "about:blank" },
            allocator,
        );
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch continue;
        log.info("Chrome launched (headless) on CDP port {d}", .{port});
        return child;
    }
    return null;
}

fn findKuriBinary(allocator: std.mem.Allocator) ?[]const u8 {
    // 1. Check alongside our own executable (zig-out/bin/kuri).
    if (std.fs.selfExePath(&self_exe_buf)) |self_path| {
        const dir = std.fs.path.dirname(self_path) orelse ".";
        if (std.fmt.allocPrint(allocator, "{s}/kuri", .{dir})) |s| {
            std.fs.cwd().access(s, .{}) catch {
                allocator.free(s);
                return findKuriFallback(allocator);
            };
            return s;
        } else |_| {}
    } else |_| {}
    return findKuriFallback(allocator);
}

var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;

fn findKuriFallback(allocator: std.mem.Allocator) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "which", "kuri" },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term == .Exited and result.term.Exited == 0 and result.stdout.len > 0) {
        const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r ");
        return allocator.dupe(u8, trimmed) catch null;
    }

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);
    const home_bin = std.fmt.allocPrint(allocator, "{s}/.local/bin/kuri", .{home}) catch return null;
    std.fs.cwd().access(home_bin, .{}) catch {
        allocator.free(home_bin);
        return null;
    };
    return home_bin;
}
