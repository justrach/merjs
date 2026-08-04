// telemetry.zig — opt-in Sentry + Datadog integration.
// Activates when SENTRY_DSN or DD_AGENT_HOST env vars are set.
// Sentry sends are bounded and fire-and-forget; DogStatsD sends are synchronous UDP.

const std = @import("std");
const builtin = @import("builtin");
const env_mod = @import("env.zig");

const max_sentry_field_len = 2048;
const max_sentry_envelope_len = 16 * 1024;
const max_sentry_sends = 8;
const sentry_send_timeout = std.Io.Duration.fromSeconds(5);
const telemetry_poll_interval = std.Io.Duration.fromMilliseconds(1);
const sentry_message_prefix = "Route handler error on ";

fn env(name: []const u8) ?[]const u8 {
    return env_mod.get(name);
}

// ── Sentry ──────────────────────────────────────────────────────────────────
// Sends error events to Sentry via the HTTP envelope endpoint.
// Set SENTRY_DSN=https://<key>@<host>/<project_id>

/// Parsed Sentry DSN components. The slices borrow from `dsn`.
const SentryConfig = struct {
    key: []const u8,
    host: []const u8,
    project_id: []const u8,
};

fn isDsnComponent(value: []const u8, allow_host_punctuation: bool) bool {
    if (value.len == 0 or value.len > max_sentry_field_len) return false;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') continue;
        if (allow_host_punctuation and (c == ':' or c == '[' or c == ']')) continue;
        return false;
    }
    return true;
}

pub fn parseSentryDsn(dsn: []const u8) ?SentryConfig {
    const prefix = "https://";
    if (!std.mem.startsWith(u8, dsn, prefix)) return null;
    const authority = dsn[prefix.len..];
    const at = std.mem.indexOfScalar(u8, authority, '@') orelse return null;
    const key = authority[0..at];
    const rest = authority[at + 1 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const host = rest[0..slash];
    const project_id = rest[slash + 1 ..];
    if (!isDsnComponent(key, false) or
        !isDsnComponent(host, true) or
        !isDsnComponent(project_id, false)) return null;
    return .{ .key = key, .host = host, .project_id = project_id };
}

fn appendBounded(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    if (bytes.len > max_sentry_envelope_len -| out.items.len) return error.EventTooLarge;
    try out.appendSlice(allocator, bytes);
}

fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    if (value.len > max_sentry_field_len or !std.unicode.utf8ValidateSlice(value)) return error.InvalidEventField;
    try appendBounded(out, allocator, "\"");
    const hex = "0123456789abcdef";
    for (value) |c| switch (c) {
        '"' => try appendBounded(out, allocator, "\\\""),
        '\\' => try appendBounded(out, allocator, "\\\\"),
        '\n' => try appendBounded(out, allocator, "\\n"),
        '\r' => try appendBounded(out, allocator, "\\r"),
        '\t' => try appendBounded(out, allocator, "\\t"),
        0...7, 11, 12, 14...31 => {
            const escaped = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf] };
            try appendBounded(out, allocator, &escaped);
        },
        else => try appendBounded(out, allocator, &.{c}),
    };
    try appendBounded(out, allocator, "\"");
}

fn buildSentryEnvelope(
    allocator: std.mem.Allocator,
    cfg: SentryConfig,
    error_name: []const u8,
    path: []const u8,
    framework_version: []const u8,
) ![]u8 {
    if (error_name.len > max_sentry_field_len or
        path.len > max_sentry_field_len - sentry_message_prefix.len or
        framework_version.len > max_sentry_field_len) return error.InvalidEventField;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, @min(max_sentry_envelope_len, 1024 + path.len * 2));

    try appendBounded(&out, allocator, "{\"dsn\":");
    var dsn: [max_sentry_field_len * 3 + 10]u8 = undefined;
    const dsn_value = try std.fmt.bufPrint(&dsn, "https://{s}@{s}/{s}", .{ cfg.key, cfg.host, cfg.project_id });
    try appendJsonString(&out, allocator, dsn_value);
    try appendBounded(&out, allocator, "}\n{\"type\":\"event\"}\n{\"level\":\"error\",\"platform\":\"other\",\"sdk\":{\"name\":\"merjs\",\"version\":");
    try appendJsonString(&out, allocator, framework_version);
    try appendBounded(&out, allocator, "},\"exception\":{\"values\":[{\"type\":");
    try appendJsonString(&out, allocator, error_name);
    try appendBounded(&out, allocator, ",\"value\":");

    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(allocator);
    try message.appendSlice(allocator, sentry_message_prefix);
    try message.appendSlice(allocator, path);
    try appendJsonString(&out, allocator, message.items);
    try appendBounded(&out, allocator, "}]},\"request\":{\"url\":");
    try appendJsonString(&out, allocator, path);
    try appendBounded(&out, allocator, "},\"tags\":{\"framework\":\"merjs\",\"zig\":");
    try appendJsonString(&out, allocator, builtin.zig_version_string);
    try appendBounded(&out, allocator, "}}\n");
    return out.toOwnedSlice(allocator);
}

const SentrySendContext = struct {
    allocator: std.mem.Allocator,
    url: []u8,
    payload: []u8,
    owners: std.atomic.Value(usize) = .init(1),
    completed: std.atomic.Value(bool) = .init(false),

    fn retain(ctx: *SentrySendContext) void {
        _ = ctx.owners.fetchAdd(1, .monotonic);
    }

    fn release(ctx: *SentrySendContext) void {
        if (ctx.owners.fetchSub(1, .acq_rel) != 1) return;
        const allocator = ctx.allocator;
        allocator.free(ctx.url);
        allocator.free(ctx.payload);
        allocator.destroy(ctx);
    }

    fn finish(ctx: *SentrySendContext) void {
        ctx.completed.store(true, .release);
    }

    fn wait(ctx: *SentrySendContext, io: std.Io, timeout: std.Io.Duration) bool {
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = timeout, .clock = .awake });
        var budget = pollBudget(timeout);
        while (!ctx.completed.load(.acquire)) {
            if (budget == 0 or std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) return false;
            budget -= 1;
            std.Io.sleep(io, telemetry_poll_interval, .awake) catch return false;
        }
        return true;
    }
};

const LifecycleState = enum { running, stopping, stopped };

var lifecycle_mutex: std.atomic.Mutex = .unlocked;
var lifecycle_state: LifecycleState = .running;
var sentry_in_flight: usize = 0;
var sentry_network_in_flight: usize = 0;
var statsd_in_flight: usize = 0;
var statsd_addr: ?std.Io.net.IpAddress = null;

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn pollBudget(timeout: std.Io.Duration) usize {
    const milliseconds = @max(timeout.toMilliseconds(), 0);
    return @intCast(@min(milliseconds + 1, 60_001));
}

fn acquireSentrySlot() bool {
    lock(&lifecycle_mutex);
    defer lifecycle_mutex.unlock();
    if (lifecycle_state != .running or sentry_network_in_flight == max_sentry_sends) return false;
    sentry_in_flight += 1;
    sentry_network_in_flight += 1;
    return true;
}

fn releaseSentrySlot() void {
    lock(&lifecycle_mutex);
    defer lifecycle_mutex.unlock();
    std.debug.assert(sentry_in_flight > 0 and sentry_network_in_flight > 0);
    sentry_in_flight -= 1;
    sentry_network_in_flight -= 1;
}

fn releaseSentrySupervisor() void {
    lock(&lifecycle_mutex);
    defer lifecycle_mutex.unlock();
    std.debug.assert(sentry_in_flight > 0);
    sentry_in_flight -= 1;
}

fn releaseSentryWorker() void {
    lock(&lifecycle_mutex);
    defer lifecycle_mutex.unlock();
    std.debug.assert(sentry_network_in_flight > 0);
    sentry_network_in_flight -= 1;
}

fn createSentryContext(
    allocator: std.mem.Allocator,
    cfg: SentryConfig,
    error_name: []const u8,
    path: []const u8,
    framework_version: []const u8,
) !*SentrySendContext {
    const payload = try buildSentryEnvelope(allocator, cfg, error_name, path, framework_version);
    errdefer allocator.free(payload);
    const url = try std.fmt.allocPrint(allocator, "https://{s}/api/{s}/envelope/", .{ cfg.host, cfg.project_id });
    errdefer allocator.free(url);
    const ctx = try allocator.create(SentrySendContext);
    ctx.* = .{ .allocator = allocator, .url = url, .payload = payload };
    return ctx;
}

/// Report an error to Sentry. At most eight sends may be in flight; excess
/// reports are dropped rather than creating unbounded detached threads.
pub fn sentryCapture(error_name: []const u8, path: []const u8, framework_version: []const u8) void {
    if (comptime builtin.os.tag == .freestanding) return;
    const dsn_str = env("SENTRY_DSN") orelse return;
    const cfg = parseSentryDsn(dsn_str) orelse return;
    if (!acquireSentrySlot()) return;
    const ctx = createSentryContext(std.heap.page_allocator, cfg, error_name, path, framework_version) catch {
        releaseSentrySlot();
        return;
    };

    const thread = std.Thread.spawn(.{}, sentrySendThread, .{ctx}) catch {
        releaseSentrySlot();
        ctx.release();
        return;
    };
    thread.detach();
}

fn sentryFetch(client: *std.http.Client, ctx: *const SentrySendContext) bool {
    const result = client.fetch(.{
        .location = .{ .url = ctx.url },
        .method = .POST,
        .payload = ctx.payload,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/x-sentry-envelope" },
        },
    }) catch return false;
    return result.status.class() == .success;
}

const SentryWork = *const fn (*const SentrySendContext) void;

fn sentryNetworkWork(ctx: *const SentrySendContext) void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    var client = std.http.Client{ .allocator = std.heap.page_allocator, .io = threaded.io() };
    defer client.deinit();

    // Zig 0.16 FetchOptions/RequestOptions expose no connect or read deadline.
    // ConnectTcpOptions has a timeout field, but connectTcpOptions currently
    // does not pass it to DNS/TCP and fetch cannot use it. A blocked DNS/TLS
    // operation therefore cannot be safely canceled or joined here. Detached
    // network workers retain their context, and this strict cap bounds them.
    _ = sentryFetch(&client, ctx);
}

fn sentryNetworkThread(ctx: *SentrySendContext, work: SentryWork) void {
    defer releaseSentryWorker();
    defer ctx.release();
    defer ctx.finish();
    work(ctx);
}

const SentrySpawn = *const fn (*SentrySendContext, SentryWork) std.Thread.SpawnError!std.Thread;

fn spawnSentryNetwork(ctx: *SentrySendContext, work: SentryWork) std.Thread.SpawnError!std.Thread {
    return std.Thread.spawn(.{}, sentryNetworkThread, .{ ctx, work });
}

fn superviseSentry(ctx: *SentrySendContext, io: std.Io, timeout: std.Io.Duration, work: SentryWork, spawn: SentrySpawn) ?std.Thread {
    ctx.retain();
    const thread = spawn(ctx, work) catch {
        ctx.release();
        releaseSentryWorker();
        return null;
    };
    _ = ctx.wait(io, timeout);
    return thread;
}

fn sentrySendThread(ctx: *SentrySendContext) void {
    defer releaseSentrySupervisor();
    defer ctx.release();
    var timer = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer timer.deinit();
    const thread = superviseSentry(ctx, timer.io(), sentry_send_timeout, sentryNetworkWork, spawnSentryNetwork) orelse return;
    thread.detach();
}

// ── Datadog (DogStatsD) ─────────────────────────────────────────────────────
// Sends metrics via UDP to the local Datadog agent.
// Set DD_AGENT_HOST and optionally DD_DOGSTATSD_PORT (default: 8125).

/// Allow telemetry submissions after a completed `deinit`. An `init` racing
/// an active shutdown is linearized before that shutdown and is a no-op.
pub fn init() void {
    if (comptime builtin.os.tag == .freestanding) return;
    lock(&lifecycle_mutex);
    defer lifecycle_mutex.unlock();
    if (lifecycle_state == .stopped) lifecycle_state = .running;
}

fn stopTelemetry(io: std.Io, timeout: std.Io.Duration) void {
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = timeout, .clock = .awake });
    lock(&lifecycle_mutex);
    switch (lifecycle_state) {
        .stopped => {
            lifecycle_mutex.unlock();
            return;
        },
        .stopping => {},
        .running => lifecycle_state = .stopping,
    }

    var budget = pollBudget(timeout);
    while (sentry_in_flight != 0 or statsd_in_flight != 0) {
        lifecycle_mutex.unlock();
        if (budget == 0 or std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) return finishStop();
        budget -= 1;
        std.Io.sleep(io, telemetry_poll_interval, .awake) catch return finishStop();
        lock(&lifecycle_mutex);
        if (lifecycle_state != .stopping) {
            lifecycle_mutex.unlock();
            return;
        }
    }
    lifecycle_state = .stopped;
    statsd_addr = null;
    lifecycle_mutex.unlock();
}

fn finishStop() void {
    lock(&lifecycle_mutex);
    defer lifecycle_mutex.unlock();
    if (lifecycle_state == .stopping) {
        lifecycle_state = .stopped;
        statsd_addr = null;
    }
}

/// Stop accepting telemetry and wait for admitted supervisors/UDP sends. The
/// wait is bounded; blocked Sentry network workers retain their own data and
/// remain counted against the fixed worker cap until they actually return.
pub fn deinit() void {
    if (comptime builtin.os.tag == .freestanding) return;

    var timer = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer timer.deinit();
    stopTelemetry(timer.io(), sentry_send_timeout);
}

fn getStatsdAddressLocked() ?std.Io.net.IpAddress {
    if (statsd_addr) |address| return address;
    const host = env("DD_AGENT_HOST") orelse return null;
    const port_str = env("DD_DOGSTATSD_PORT") orelse "8125";
    const port = std.fmt.parseInt(u16, port_str, 10) catch return null;
    statsd_addr = std.Io.net.IpAddress.parse(host, port) catch return null;
    return statsd_addr.?;
}

fn acquireStatsdAddress() ?std.Io.net.IpAddress {
    lock(&lifecycle_mutex);
    defer lifecycle_mutex.unlock();
    if (lifecycle_state != .running) return null;
    const address = getStatsdAddressLocked() orelse return null;
    statsd_in_flight += 1;
    return address;
}

fn releaseStatsd() void {
    lock(&lifecycle_mutex);
    defer lifecycle_mutex.unlock();
    std.debug.assert(statsd_in_flight > 0);
    statsd_in_flight -= 1;
}

fn statsdSend(message: []const u8) bool {
    if (comptime builtin.os.tag == .freestanding) return false;
    const address = acquireStatsdAddress() orelse return false;
    defer releaseStatsd();

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const local: std.Io.net.IpAddress = switch (address) {
        .ip4 => .{ .ip4 = std.Io.net.Ip4Address.unspecified(0) },
        .ip6 => .{ .ip6 = std.Io.net.Ip6Address.unspecified(0) },
    };
    const socket = local.bind(io, .{ .mode = .dgram }) catch return false;
    defer socket.close(io);
    socket.send(io, &address, message) catch return false;
    return true;
}

fn statsdTag(out: []u8, value: []const u8) ?[]const u8 {
    if (value.len > out.len) return null;
    for (value, 0..) |c, i| {
        out[i] = switch (c) {
            ',', '|', ':', '#', '\n', '\r' => '_',
            else => c,
        };
    }
    return out[0..value.len];
}

/// Send a timing metric to Datadog and report whether UDP accepted it.
pub fn ddTimingStatus(path: []const u8, method: []const u8, status: u16, duration_us: u64) bool {
    var path_buf: [256]u8 = undefined;
    var method_buf: [32]u8 = undefined;
    const safe_path = statsdTag(&path_buf, path) orelse return false;
    const safe_method = statsdTag(&method_buf, method) orelse return false;
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "merjs.request.duration:{d}|ms|#path:{s},method:{s},status:{d}\n" ++
            "merjs.request.count:1|c|#path:{s},method:{s},status:{d}",
        .{ duration_us / 1000, safe_path, safe_method, status, safe_path, safe_method, status },
    ) catch return false;
    return statsdSend(msg);
}

pub fn ddTiming(path: []const u8, method: []const u8, status: u16, duration_us: u64) void {
    _ = ddTimingStatus(path, method, status, duration_us);
}

/// Send an error event to Datadog and report whether UDP accepted it.
pub fn ddErrorStatus(path: []const u8, method: []const u8, error_name: []const u8) bool {
    var path_buf: [256]u8 = undefined;
    var method_buf: [32]u8 = undefined;
    var error_buf: [128]u8 = undefined;
    const safe_path = statsdTag(&path_buf, path) orelse return false;
    const safe_method = statsdTag(&method_buf, method) orelse return false;
    const safe_error = statsdTag(&error_buf, error_name) orelse return false;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "merjs.request.error:1|c|#path:{s},method:{s},error:{s}",
        .{ safe_path, safe_method, safe_error },
    ) catch return false;
    return statsdSend(msg);
}

pub fn ddError(path: []const u8, method: []const u8, error_name: []const u8) void {
    _ = ddErrorStatus(path, method, error_name);
}

test "production telemetry declarations compile" {
    std.testing.refAllDecls(@This());
}

test "parseSentryDsn validates a strict HTTPS DSN" {
    const cfg = parseSentryDsn("https://abc123@o1234.ingest.sentry.io/456789").?;
    try std.testing.expectEqualStrings("abc123", cfg.key);
    try std.testing.expectEqualStrings("o1234.ingest.sentry.io", cfg.host);
    try std.testing.expectEqualStrings("456789", cfg.project_id);
    try std.testing.expect(parseSentryDsn("http://abc@host/1") == null);
    try std.testing.expect(parseSentryDsn("https://abc@host/1?bad") == null);
    try std.testing.expect(parseSentryDsn("https://abc@host\n.invalid/1") == null);
}

test "Sentry envelope escapes JSON and owns its input" {
    const allocator = std.testing.allocator;
    var error_name = [_]u8{ 'B', 'a', 'd', '"', '\n' };
    var path = [_]u8{ '/', 'a', '\\', 'b', '\t' };
    const cfg = parseSentryDsn("https://key@host.test/42").?;
    const payload = try buildSentryEnvelope(allocator, cfg, &error_name, &path, "1\"2");
    defer allocator.free(payload);
    @memset(&error_name, 'x');
    @memset(&path, 'x');
    try std.testing.expect(std.mem.indexOf(u8, payload, "Bad\\\"\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "/a\\\\b\\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "1\\\"2") != null);
    try std.testing.expect(payload[payload.len - 1] == '\n');
}

test "Sentry envelope enforces generated message boundary" {
    const allocator = std.testing.allocator;
    const cfg = parseSentryDsn("https://key@host.test/42").?;
    var invalid = [_]u8{0xff};
    try std.testing.expectError(error.InvalidEventField, buildSentryEnvelope(allocator, cfg, &invalid, "/", "1"));

    const max_path_len = max_sentry_field_len - sentry_message_prefix.len;
    const boundary = try allocator.alloc(u8, max_path_len);
    defer allocator.free(boundary);
    @memset(boundary, 'a');
    const payload = try buildSentryEnvelope(allocator, cfg, "Error", boundary, "1");
    defer allocator.free(payload);

    const oversized = try allocator.alloc(u8, max_path_len + 1);
    defer allocator.free(oversized);
    @memset(oversized, 'a');
    try std.testing.expectError(error.InvalidEventField, buildSentryEnvelope(allocator, cfg, "Error", oversized, "1"));
}

test "Sentry envelope reports allocation failure without leaking" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const cfg = parseSentryDsn("https://key@host.test/42").?;
    try std.testing.expectError(
        error.OutOfMemory,
        buildSentryEnvelope(failing.allocator(), cfg, "Error", "/", "1"),
    );
}

test "Sentry timeout leaves blocked work owned and capped" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    init();
    try std.testing.expect(acquireSentrySlot());

    const cfg = parseSentryDsn("https://key@host.test/42").?;
    const ctx = try createSentryContext(std.testing.allocator, cfg, "Error", "/", "1");
    const TestState = struct {
        var release = std.atomic.Value(bool).init(false);
        var accessed_after_timeout = std.atomic.Value(bool).init(false);

        fn blockedWork(send_ctx: *const SentrySendContext) void {
            while (!release.load(.acquire)) std.atomic.spinLoopHint();
            accessed_after_timeout.store(send_ctx.payload.len != 0, .release);
        }
    };
    TestState.release.store(false, .release);
    TestState.accessed_after_timeout.store(false, .release);
    const worker = superviseSentry(ctx, io, std.Io.Duration.fromMilliseconds(1), TestState.blockedWork, spawnSentryNetwork).?;
    releaseSentrySupervisor();
    ctx.release();

    stopTelemetry(io, std.Io.Duration.fromMilliseconds(1));
    try std.testing.expect(!acquireSentrySlot());
    TestState.release.store(true, .release);
    worker.join();

    try std.testing.expect(TestState.accessed_after_timeout.load(.acquire));
    lock(&lifecycle_mutex);
    defer lifecycle_mutex.unlock();
    try std.testing.expectEqual(@as(usize, 0), sentry_network_in_flight);
}

test "Sentry inner spawn failure releases ownership and capacity" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    init();
    try std.testing.expect(acquireSentrySlot());
    const cfg = parseSentryDsn("https://key@host.test/42").?;
    const ctx = try createSentryContext(std.testing.allocator, cfg, "Error", "/", "1");
    const TestState = struct {
        fn work(_: *const SentrySendContext) void {}
        fn failSpawn(_: *SentrySendContext, _: SentryWork) std.Thread.SpawnError!std.Thread {
            return error.OutOfMemory;
        }
    };
    try std.testing.expect(superviseSentry(ctx, threaded.io(), sentry_send_timeout, TestState.work, TestState.failSpawn) == null);
    releaseSentrySupervisor();
    ctx.release();

    lock(&lifecycle_mutex);
    defer lifecycle_mutex.unlock();
    try std.testing.expectEqual(@as(usize, 0), sentry_in_flight);
    try std.testing.expectEqual(@as(usize, 0), sentry_network_in_flight);
}

test "Sentry worker cap rejects deterministic exhaustion" {
    init();
    for (0..max_sentry_sends) |_| try std.testing.expect(acquireSentrySlot());
    try std.testing.expect(!acquireSentrySlot());
    for (0..max_sentry_sends) |_| releaseSentrySlot();
}

test "shutdown rejects StatsD admission and has a bounded fallback" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    init();
    lock(&lifecycle_mutex);
    statsd_addr = .{ .ip4 = std.Io.net.Ip4Address.loopback(8125) };
    lifecycle_mutex.unlock();
    _ = acquireStatsdAddress().?;

    stopTelemetry(threaded.io(), std.Io.Duration.zero);
    try std.testing.expect(acquireStatsdAddress() == null);
    releaseStatsd();
}

test "DogStatsD tags cannot inject metrics and enforce bounds" {
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a_b_c_d_e_f", statsdTag(&out, "a,b|c:d#e\nf").?);
    try std.testing.expect(statsdTag(out[0..2], "long") == null);
}
