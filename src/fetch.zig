// fetch.zig — SSR HTTP client (single + parallel fetch).

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");

pub const default_max_response_size: usize = 8 * 1024 * 1024;
pub const max_response_size_limit: usize = 8 * 1024 * 1024;
pub const max_wasm_requests: usize = 64;
pub const max_wasm_request_bytes: usize = 1024 * 1024;
pub const max_wasm_response_bytes: usize = 32 * 1024 * 1024;
/// Maximum native transport workers. A worker whose transport does not cooperate with
/// cancellation keeps one of these slots until it exits.
pub const max_fetch_concurrency: usize = 8;
pub const max_fetch_requests: usize = 64;
pub const max_fetch_response_bytes: usize = 32 * 1024 * 1024;
/// 30-second native caller and transport cancellation deadline. The caller returns at
/// this deadline even if cancellation stalls; a non-cooperative transport remains within
/// `max_fetch_concurrency` until it exits.
pub const fetch_wait_timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(30), .clock = .awake };
/// Backward-compatible name for `fetch_wait_timeout`.
pub const fetch_total_timeout = fetch_wait_timeout;

/// Options for a single HTTP request made during server-side rendering.
pub const FetchRequest = struct {
    url: []const u8,
    method: std.http.Method = .GET,
    body: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    /// Maximum decompressed response body size.
    max_response_size: usize = default_max_response_size,
};

/// Response from an HTTP fetch. Owns the exact body slice — call `deinit()` when done.
pub const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: FetchResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

// ── Freestanding (Workers) two-phase fetch state ─────────────────────────────

const wasm_alloc = if (builtin.os.tag == .freestanding)
    std.heap.wasm_allocator
else
    std.heap.page_allocator;

pub const WasmFetchError = enum(u32) {
    none = 0,
    too_many_requests = 1,
    request_bytes_exceeded = 2,
    out_of_memory = 3,
    protocol_mismatch = 4,
    invalid_result = 5,
    response_too_large = 6,
    invalid_max_response_size = 7,
    response_bytes_exceeded = 8,
};

const ExpectedRequest = struct {
    hash: u64,
    max_response_size: usize,
    serialized_bytes: usize,
};

const CachedResponse = struct {
    status: std.http.Status,
    body: []u8,
};

var wasm_collect_mode = false;
var wasm_replay_index: usize = 0;
var wasm_last_error: WasmFetchError = .none;
var wasm_requests_buf: std.ArrayListUnmanaged(u8) = .empty;
var wasm_expected_state_buf: std.ArrayListUnmanaged(u8) = .empty;
var wasm_expected: std.ArrayListUnmanaged(ExpectedRequest) = .empty;
var wasm_fetch_cache: std.AutoHashMapUnmanaged(u32, CachedResponse) = .{};
var wasm_cached_bytes: usize = 0;

fn hashSlice(hash: *std.hash.Wyhash, bytes: ?[]const u8) void {
    var len_buf: [8]u8 = undefined;
    const len = if (bytes) |slice| @as(u64, @intCast(slice.len)) else std.math.maxInt(u64);
    std.mem.writeInt(u64, &len_buf, len, .little);
    hash.update(&len_buf);
    if (bytes) |slice| hash.update(slice);
}

fn requestHash(opts: FetchRequest) u64 {
    var hash = std.hash.Wyhash.init(0);
    hashSlice(&hash, @tagName(opts.method));
    hashSlice(&hash, opts.url);
    hashSlice(&hash, opts.body);
    for (opts.headers) |header| {
        hashSlice(&hash, header.name);
        hashSlice(&hash, header.value);
    }
    var max_buf: [@sizeOf(usize)]u8 = undefined;
    std.mem.writeInt(usize, &max_buf, opts.max_response_size, .little);
    hash.update(&max_buf);
    return hash.final();
}

fn appendInt(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn serializedRequestSize(opts: FetchRequest) ?usize {
    var size: usize = 24;
    size = std.math.add(usize, size, @tagName(opts.method).len) catch return null;
    size = std.math.add(usize, size, opts.url.len) catch return null;
    if (opts.body) |body| size = std.math.add(usize, size, body.len) catch return null;
    for (opts.headers) |header| {
        size = std.math.add(usize, size, 8) catch return null;
        size = std.math.add(usize, size, header.name.len) catch return null;
        size = std.math.add(usize, size, header.value.len) catch return null;
    }
    return size;
}

fn requestValidationError(opts: FetchRequest, request_count: usize, serialized_bytes: usize) ?WasmFetchError {
    if (opts.max_response_size > max_response_size_limit) return .invalid_max_response_size;
    if (request_count >= max_wasm_requests) return .too_many_requests;
    const record_size = serializedRequestSize(opts) orelse return .request_bytes_exceeded;
    if (record_size > max_wasm_request_bytes -| serialized_bytes or
        opts.url.len > std.math.maxInt(u32) or
        (opts.body != null and opts.body.?.len > std.math.maxInt(u32)) or
        opts.headers.len > std.math.maxInt(u32) or
        opts.max_response_size > std.math.maxInt(u32)) return .request_bytes_exceeded;
    for (opts.headers) |header| {
        if (header.name.len > std.math.maxInt(u32) or header.value.len > std.math.maxInt(u32))
            return .request_bytes_exceeded;
    }
    return null;
}

fn expectedRequestBytes() usize {
    var total: usize = 0;
    for (wasm_expected.items) |expected| total += expected.serialized_bytes;
    return total;
}

fn collectRequest(opts: FetchRequest) void {
    if (requestValidationError(opts, wasm_expected.items.len, expectedRequestBytes())) |validation_error| {
        wasm_last_error = validation_error;
        return;
    }

    const old_len = wasm_requests_buf.items.len;
    const id: u32 = @intCast(wasm_expected.items.len);
    const method = @tagName(opts.method);
    appendInt(&wasm_requests_buf, wasm_alloc, id) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    appendInt(&wasm_requests_buf, wasm_alloc, @intCast(opts.max_response_size)) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    appendInt(&wasm_requests_buf, wasm_alloc, @intCast(method.len)) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    appendInt(&wasm_requests_buf, wasm_alloc, @intCast(opts.url.len)) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    appendInt(&wasm_requests_buf, wasm_alloc, if (opts.body) |body| @intCast(body.len) else std.math.maxInt(u32)) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    appendInt(&wasm_requests_buf, wasm_alloc, @intCast(opts.headers.len)) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    wasm_requests_buf.appendSlice(wasm_alloc, method) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    wasm_requests_buf.appendSlice(wasm_alloc, opts.url) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    if (opts.body) |body| wasm_requests_buf.appendSlice(wasm_alloc, body) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
        return;
    };
    for (opts.headers) |header| {
        appendInt(&wasm_requests_buf, wasm_alloc, @intCast(header.name.len)) catch {
            wasm_requests_buf.shrinkRetainingCapacity(old_len);
            wasm_last_error = .out_of_memory;
            return;
        };
        appendInt(&wasm_requests_buf, wasm_alloc, @intCast(header.value.len)) catch {
            wasm_requests_buf.shrinkRetainingCapacity(old_len);
            wasm_last_error = .out_of_memory;
            return;
        };
        wasm_requests_buf.appendSlice(wasm_alloc, header.name) catch {
            wasm_requests_buf.shrinkRetainingCapacity(old_len);
            wasm_last_error = .out_of_memory;
            return;
        };
        wasm_requests_buf.appendSlice(wasm_alloc, header.value) catch {
            wasm_requests_buf.shrinkRetainingCapacity(old_len);
            wasm_last_error = .out_of_memory;
            return;
        };
    }
    wasm_expected.append(wasm_alloc, .{
        .hash = requestHash(opts),
        .max_response_size = opts.max_response_size,
        .serialized_bytes = wasm_requests_buf.items.len - old_len,
    }) catch {
        wasm_requests_buf.shrinkRetainingCapacity(old_len);
        wasm_last_error = .out_of_memory;
    };
}

pub const WasmCollection = struct {
    bytes: []const u8,
    error_code: u32,
};

const expected_state_magic: u32 = 0x3246534d; // "MSF2"

/// Begin request collection. Existing restored requests and results are replayed,
/// allowing the host to discover response-dependent requests in later rounds.
pub fn wasmBeginCollect() void {
    if (wasm_fetch_cache.count() == 0) _ = wasmClearCacheV2();
    wasm_collect_mode = true;
    wasm_replay_index = 0;
    wasm_last_error = .none;
    wasm_requests_buf.clearRetainingCapacity();
}

/// End collection and return the bounded binary request list in WASM memory.
pub fn wasmEndCollectV2() WasmCollection {
    wasm_collect_mode = false;
    wasm_replay_index = 0;
    wasm_expected_state_buf.clearRetainingCapacity();
    appendInt(&wasm_expected_state_buf, wasm_alloc, expected_state_magic) catch {
        wasm_last_error = .out_of_memory;
    };
    appendInt(&wasm_expected_state_buf, wasm_alloc, @intCast(wasm_expected.items.len)) catch {
        wasm_last_error = .out_of_memory;
    };
    for (wasm_expected.items) |expected| {
        var hash_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &hash_bytes, expected.hash, .little);
        wasm_expected_state_buf.appendSlice(wasm_alloc, &hash_bytes) catch {
            wasm_last_error = .out_of_memory;
            break;
        };
        appendInt(&wasm_expected_state_buf, wasm_alloc, @intCast(expected.max_response_size)) catch {
            wasm_last_error = .out_of_memory;
            break;
        };
        appendInt(&wasm_expected_state_buf, wasm_alloc, @intCast(expected.serialized_bytes)) catch {
            wasm_last_error = .out_of_memory;
            break;
        };
    }
    return .{ .bytes = wasm_requests_buf.items, .error_code = @intFromEnum(wasm_last_error) };
}

/// Opaque expected-request state copied by the host before restoring a dry-run
/// linear-memory snapshot.
pub fn wasmExpectedState() []const u8 {
    return wasm_expected_state_buf.items;
}

/// Restore expected request hashes after the host has rolled back the dry run.
pub fn wasmRestoreExpectedState(bytes: []const u8) u32 {
    const record_size: usize = 16;
    const offset_start: usize = 8;
    if (bytes.len < offset_start or std.mem.readInt(u32, bytes[0..4], .little) != expected_state_magic) {
        wasm_last_error = .protocol_mismatch;
        return @intFromEnum(wasm_last_error);
    }
    const count = std.mem.readInt(u32, bytes[4..8], .little);
    if (count > max_wasm_requests or bytes.len != offset_start + count * record_size) {
        wasm_last_error = .protocol_mismatch;
        return @intFromEnum(wasm_last_error);
    }
    wasm_expected.clearRetainingCapacity();
    wasm_replay_index = 0;
    var serialized_bytes: usize = 0;
    var offset = offset_start;
    while (offset < bytes.len) : (offset += record_size) {
        const hash = std.mem.readInt(u64, bytes[offset..][0..8], .little);
        const max_response_size = std.mem.readInt(u32, bytes[offset + 8 ..][0..4], .little);
        const request_bytes = std.mem.readInt(u32, bytes[offset + 12 ..][0..4], .little);
        serialized_bytes = std.math.add(usize, serialized_bytes, request_bytes) catch max_wasm_request_bytes + 1;
        if (max_response_size > max_response_size_limit or serialized_bytes > max_wasm_request_bytes) {
            wasm_last_error = .protocol_mismatch;
            return @intFromEnum(wasm_last_error);
        }
        wasm_expected.append(wasm_alloc, .{
            .hash = hash,
            .max_response_size = max_response_size,
            .serialized_bytes = request_bytes,
        }) catch {
            wasm_last_error = .out_of_memory;
            return @intFromEnum(wasm_last_error);
        };
    }
    wasm_last_error = .none;
    return 0;
}

fn statusFromInt(value: u16) ?std.http.Status {
    if (value < 100 or value > 599) return null;
    return @enumFromInt(value);
}

fn responseFitsCache(current: usize, replaced: usize, new_len: usize) bool {
    return new_len <= max_wasm_response_bytes -| (current -| replaced);
}

/// Store one JS-fetched response by collection request ID. Returns a WasmFetchError code.
pub fn wasmProvideResultV2(id: u32, status_code: u32, body: []const u8) u32 {
    if (id >= wasm_expected.items.len or status_code > std.math.maxInt(u16)) {
        wasm_last_error = .invalid_result;
        return @intFromEnum(wasm_last_error);
    }
    const expected = wasm_expected.items[id];
    if (body.len > expected.max_response_size) {
        wasm_last_error = .response_too_large;
        return @intFromEnum(wasm_last_error);
    }
    const replaced_len = if (wasm_fetch_cache.get(id)) |cached| cached.body.len else 0;
    if (!responseFitsCache(wasm_cached_bytes, replaced_len, body.len)) {
        wasm_last_error = .response_bytes_exceeded;
        return @intFromEnum(wasm_last_error);
    }
    const status = statusFromInt(@intCast(status_code)) orelse {
        wasm_last_error = .invalid_result;
        return @intFromEnum(wasm_last_error);
    };
    const owned = wasm_alloc.dupe(u8, body) catch {
        wasm_last_error = .out_of_memory;
        return @intFromEnum(wasm_last_error);
    };
    if (wasm_fetch_cache.getPtr(id)) |cached| {
        wasm_cached_bytes -= cached.body.len;
        wasm_alloc.free(cached.body);
        cached.* = .{ .status = status, .body = owned };
        wasm_cached_bytes += owned.len;
        return 0;
    }
    wasm_fetch_cache.put(wasm_alloc, id, .{ .status = status, .body = owned }) catch {
        wasm_alloc.free(owned);
        wasm_last_error = .out_of_memory;
        return @intFromEnum(wasm_last_error);
    };
    wasm_cached_bytes += owned.len;
    return 0;
}

/// Free all bridge-owned request and response storage and return the final error code.
pub fn wasmClearCacheV2() u32 {
    const error_code = @intFromEnum(wasm_last_error);
    var it = wasm_fetch_cache.iterator();
    while (it.next()) |entry| wasm_alloc.free(entry.value_ptr.body);
    wasm_fetch_cache.deinit(wasm_alloc);
    wasm_fetch_cache = .{};
    wasm_cached_bytes = 0;
    wasm_requests_buf.deinit(wasm_alloc);
    wasm_requests_buf = .empty;
    wasm_expected_state_buf.deinit(wasm_alloc);
    wasm_expected_state_buf = .empty;
    wasm_expected.deinit(wasm_alloc);
    wasm_expected = .empty;
    wasm_replay_index = 0;
    return error_code;
}

/// Deprecated V1 bridge. The URL-only protocol cannot safely represent request
/// methods, headers, status codes, or response bounds, so it fails closed.
pub fn wasmEndCollect() []const u8 {
    _ = wasmEndCollectV2();
    wasm_last_error = .protocol_mismatch;
    return "";
}

/// Deprecated V1 bridge. Results are rejected; use wasmProvideResultV2.
pub fn wasmProvideResult(url: []const u8, body: []const u8) void {
    _ = url;
    _ = body;
    wasm_last_error = .protocol_mismatch;
}

/// Deprecated V1 bridge cleanup retained for source compatibility.
pub fn wasmClearCache() void {
    _ = wasmClearCacheV2();
}

const NativeFetchFn = *const fn (std.Io, std.mem.Allocator, FetchRequest) anyerror!FetchResponse;

fn fetchUnpooled(io: std.Io, allocator: std.mem.Allocator, opts: FetchRequest) !FetchResponse {
    // A client local to the request cannot safely share its allocator or pool across callers.
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var response_buf = try allocator.alloc(u8, opts.max_response_size);
    errdefer allocator.free(response_buf);
    var response_writer: std.Io.Writer = .fixed(response_buf);

    const result = try client.fetch(.{
        .location = .{ .url = opts.url },
        .method = opts.method,
        .payload = opts.body,
        .extra_headers = opts.headers,
        .response_writer = &response_writer,
        .keep_alive = false,
    });

    response_buf = try allocator.realloc(response_buf, response_writer.end);
    return .{ .status = result.status, .body = response_buf };
}

var native_fetch_slots = std.atomic.Value(usize).init(max_fetch_concurrency);

fn tryAcquireFetchSlot() bool {
    var available = native_fetch_slots.load(.acquire);
    while (available != 0) {
        if (native_fetch_slots.cmpxchgWeak(available, available - 1, .acq_rel, .acquire)) |updated| {
            available = updated;
        } else return true;
    }
    return false;
}

fn releaseFetchSlot() void {
    const previous = native_fetch_slots.fetchAdd(1, .release);
    std.debug.assert(previous < max_fetch_concurrency);
}

const native_fetch_allocator = std.heap.smp_allocator;
var native_fetch_contexts = std.atomic.Value(usize).init(0);

const NativeFetchContext = struct {
    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(2),
    complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    request: FetchRequest,
    deadline: std.Io.Clock.Timestamp,
    result: ?(anyerror!FetchResponse) = null,

    fn create(opts: FetchRequest, deadline: std.Io.Clock.Timestamp) !*NativeFetchContext {
        const context = try native_fetch_allocator.create(NativeFetchContext);
        errdefer native_fetch_allocator.destroy(context);
        const url = try native_fetch_allocator.dupe(u8, opts.url);
        errdefer native_fetch_allocator.free(url);
        const body = if (opts.body) |value| try native_fetch_allocator.dupe(u8, value) else null;
        errdefer if (body) |value| native_fetch_allocator.free(value);
        const headers = try native_fetch_allocator.alloc(std.http.Header, opts.headers.len);
        errdefer native_fetch_allocator.free(headers);
        var initialized: usize = 0;
        errdefer for (headers[0..initialized]) |header| {
            native_fetch_allocator.free(header.name);
            native_fetch_allocator.free(header.value);
        };
        for (opts.headers, headers) |source, *header| {
            header.name = try native_fetch_allocator.dupe(u8, source.name);
            errdefer native_fetch_allocator.free(header.name);
            header.value = try native_fetch_allocator.dupe(u8, source.value);
            initialized += 1;
        }
        context.* = .{
            .request = .{
                .url = url,
                .method = opts.method,
                .body = body,
                .headers = headers,
                .max_response_size = opts.max_response_size,
            },
            .deadline = deadline,
        };
        _ = native_fetch_contexts.fetchAdd(1, .monotonic);
        return context;
    }

    fn release(context: *NativeFetchContext) void {
        if (context.refs.fetchSub(1, .acq_rel) != 1) return;
        if (context.result) |result| if (result) |response| response.deinit(native_fetch_allocator) else |_| {};
        for (context.request.headers) |header| {
            native_fetch_allocator.free(header.name);
            native_fetch_allocator.free(header.value);
        }
        native_fetch_allocator.free(context.request.headers);
        if (context.request.body) |body| native_fetch_allocator.free(body);
        native_fetch_allocator.free(context.request.url);
        native_fetch_allocator.destroy(context);
        _ = native_fetch_contexts.fetchSub(1, .monotonic);
    }
};

fn invokeFetch(fetch_fn: NativeFetchFn, io: std.Io, allocator: std.mem.Allocator, opts: FetchRequest) anyerror!FetchResponse {
    return fetch_fn(io, allocator, opts);
}

fn fetchWithWorkerTimeout(io: std.Io, allocator: std.mem.Allocator, opts: FetchRequest, timeout: std.Io.Clock.Duration, fetch_fn: NativeFetchFn) !FetchResponse {
    const Completion = union(enum) {
        response: anyerror!FetchResponse,
        timeout: std.Io.Cancelable!void,
    };
    var completion_buf: [2]Completion = undefined;
    var select = std.Io.Select(Completion).init(io, &completion_buf);
    select.async(.response, invokeFetch, .{ fetch_fn, io, allocator, opts });
    select.async(.timeout, std.Io.Clock.Duration.sleep, .{ timeout, io });

    switch (try select.await()) {
        .response => |result| {
            select.cancelDiscard();
            return result;
        },
        .timeout => |result| try result,
    }

    while (select.cancel()) |completion| switch (completion) {
        .response => |result| if (result) |response| response.deinit(allocator) else |_| {},
        .timeout => {},
    };
    return error.FetchTimeout;
}

fn nativeFetchWorker(context: *NativeFetchContext, fetch_fn: NativeFetchFn) void {
    defer releaseFetchSlot();
    defer context.release();
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const remaining = context.deadline.durationFromNow(threaded.io());
    context.result = if (remaining.raw.toNanoseconds() <= 0)
        error.FetchTimeout
    else
        fetchWithWorkerTimeout(threaded.io(), native_fetch_allocator, context.request, remaining, fetch_fn);
    context.complete.store(true, .release);
}

const NativeSpawnFn = *const fn (*NativeFetchContext, NativeFetchFn) anyerror!std.Thread;

fn spawnNativeFetchWorker(context: *NativeFetchContext, fetch_fn: NativeFetchFn) !std.Thread {
    return std.Thread.spawn(.{}, nativeFetchWorker, .{ context, fetch_fn });
}

const NativeFetchJob = struct {
    context: *NativeFetchContext,
    wait_io: std.Io,
    poll_budget: usize,

    fn await(job: NativeFetchJob, allocator: std.mem.Allocator) !FetchResponse {
        defer job.context.release();
        var budget = job.poll_budget;
        while (!job.context.complete.load(.acquire)) {
            if (budget == 0 or std.Io.Clock.Timestamp.now(job.wait_io, job.context.deadline.clock).compare(.gte, job.context.deadline))
                return error.FetchTimeout;
            budget -= 1;
            std.Io.sleep(job.wait_io, std.Io.Duration.fromMilliseconds(1), .awake) catch return error.FetchTimeout;
        }
        const response = try job.context.result.?;
        return .{ .status = response.status, .body = try allocator.dupe(u8, response.body) };
    }
};

fn startNativeFetch(io: std.Io, opts: FetchRequest, timeout: std.Io.Clock.Duration, fetch_fn: NativeFetchFn, spawn_fn: NativeSpawnFn) !NativeFetchJob {
    if (!tryAcquireFetchSlot()) return error.FetchConcurrencyLimitExceeded;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, timeout);
    const context = NativeFetchContext.create(opts, deadline) catch |err| {
        releaseFetchSlot();
        return err;
    };
    const thread = spawn_fn(context, fetch_fn) catch |err| {
        context.release();
        context.release();
        releaseFetchSlot();
        return err;
    };
    thread.detach();
    const milliseconds = @max(timeout.raw.toMilliseconds(), 0);
    const poll_budget: usize = @intCast(@min(milliseconds +| 1, 60_001));
    return .{
        .context = context,
        .wait_io = io,
        .poll_budget = poll_budget,
    };
}

fn fetchNative(io: std.Io, allocator: std.mem.Allocator, opts: FetchRequest, timeout: std.Io.Clock.Duration, fetch_fn: NativeFetchFn) !FetchResponse {
    const job = try startNativeFetch(io, opts, timeout, fetch_fn, spawnNativeFetchWorker);
    return job.await(allocator);
}

fn collectOrReplayRequest(allocator: std.mem.Allocator, opts: FetchRequest) ?FetchResponse {
    if (wasm_replay_index < wasm_expected.items.len)
        return replayRequest(allocator, opts);
    collectRequest(opts);
    wasm_replay_index += 1;
    return null;
}

/// Make an HTTP request from a server-side page handler.
///
/// On native targets, `error.FetchTimeout` means the caller wait deadline expired. Its
/// worker also cancels a cancellable transport at that deadline; a non-cooperative transport
/// remains within the bounded worker cap. `error.FetchConcurrencyLimitExceeded` instead means
/// no worker slot was available when the request was admitted.
pub fn fetch(allocator: std.mem.Allocator, opts: FetchRequest) !FetchResponse {
    if (opts.max_response_size > max_response_size_limit) return error.ResponseSizeLimitExceeded;
    if (comptime builtin.os.tag == .freestanding) {
        if (wasm_collect_mode)
            return collectOrReplayRequest(allocator, opts) orelse error.WasmCollecting;
        return replayRequest(allocator, opts) orelse error.WasmProtocolMismatch;
    }
    return fetchNative(runtime.io, allocator, opts, fetch_wait_timeout, fetchUnpooled);
}

fn replayRequest(allocator: std.mem.Allocator, opts: FetchRequest) ?FetchResponse {
    const id = wasm_replay_index;
    wasm_replay_index += 1;
    if (id >= wasm_expected.items.len or wasm_expected.items[id].hash != requestHash(opts)) {
        wasm_last_error = .protocol_mismatch;
        return null;
    }
    const cached = wasm_fetch_cache.get(@intCast(id)) orelse return null;
    if (cached.body.len > opts.max_response_size) {
        wasm_last_error = .response_too_large;
        return null;
    }
    const owned = allocator.dupe(u8, cached.body) catch {
        wasm_last_error = .out_of_memory;
        return null;
    };
    return .{ .status = cached.status, .body = owned };
}

fn fetchAllNative(allocator: std.mem.Allocator, io: std.Io, results: []?FetchResponse, requests: []const FetchRequest, timeout: std.Io.Clock.Duration, fetch_fn: NativeFetchFn, spawn_fn: NativeSpawnFn) void {
    var batch_start: usize = 0;
    while (batch_start < requests.len) : (batch_start += max_fetch_concurrency) {
        const batch_end = @min(batch_start + max_fetch_concurrency, requests.len);
        var jobs: [max_fetch_concurrency]?NativeFetchJob = @splat(null);
        for (requests[batch_start..batch_end], batch_start..) |opts, i| {
            if (opts.max_response_size > max_response_size_limit) continue;
            jobs[i - batch_start] = startNativeFetch(io, opts, timeout, fetch_fn, spawn_fn) catch null;
        }
        for (jobs[0 .. batch_end - batch_start], batch_start..) |job, i| {
            if (job) |started| results[i] = started.await(allocator) catch null;
        }
    }
}

/// Fetch multiple URLs in parallel. Returns caller-owned results in input order.
pub fn fetchAll(allocator: std.mem.Allocator, requests: []const FetchRequest) []?FetchResponse {
    if (requests.len > max_fetch_requests) return allocator.alloc(?FetchResponse, 0) catch &.{};
    const results = allocator.alloc(?FetchResponse, requests.len) catch return &.{};
    @memset(results, null);
    if (requests.len == 0) return results;

    if (comptime builtin.os.tag == .freestanding) {
        for (requests, 0..) |opts, i| {
            results[i] = if (wasm_collect_mode)
                collectOrReplayRequest(allocator, opts)
            else
                replayRequest(allocator, opts);
        }
        return results;
    }

    if (comptime builtin.single_threaded) {
        var response_bytes: usize = 0;
        for (requests, 0..) |opts, i| {
            const response = fetch(allocator, opts) catch continue;
            if (response.body.len > max_fetch_response_bytes -| response_bytes) {
                response.deinit(allocator);
                continue;
            }
            response_bytes += response.body.len;
            results[i] = response;
        }
        return results;
    }

    fetchAllNative(allocator, runtime.io, results, requests, fetch_wait_timeout, fetchUnpooled, spawnNativeFetchWorker);

    var response_bytes: usize = 0;
    for (results) |*response| {
        if (response.*) |completed| {
            if (completed.body.len > max_fetch_response_bytes -| response_bytes) {
                completed.deinit(allocator);
                response.* = null;
                continue;
            }
            response_bytes += completed.body.len;
        }
    }
    return results;
}

test "native fetch wait deadline bounds workers and retains owned requests without UAF" {
    if (builtin.os.tag == .freestanding or builtin.single_threaded) return error.SkipZigTest;
    const Stall = struct {
        var entered = std.atomic.Value(usize).init(0);
        var release = std.atomic.Value(bool).init(false);
        var valid = std.atomic.Value(usize).init(0);

        fn fetch(io: std.Io, allocator: std.mem.Allocator, opts: FetchRequest) !FetchResponse {
            _ = io;
            _ = entered.fetchAdd(1, .release);
            while (!release.load(.acquire)) std.Thread.yield() catch {};
            if (std.mem.eql(u8, opts.url, "http://owned.invalid") and
                std.mem.eql(u8, opts.body.?, "body") and
                std.mem.eql(u8, opts.headers[0].name, "x-owned") and
                std.mem.eql(u8, opts.headers[0].value, "yes"))
                _ = valid.fetchAdd(1, .monotonic);
            return .{ .status = .ok, .body = try allocator.dupe(u8, "done") };
        }
    };

    const initial_contexts = native_fetch_contexts.load(.monotonic);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    const request: FetchRequest = .{
        .url = try allocator.dupe(u8, "http://owned.invalid"),
        .method = .POST,
        .body = try allocator.dupe(u8, "body"),
        .headers = try allocator.dupe(std.http.Header, &.{.{
            .name = try allocator.dupe(u8, "x-owned"),
            .value = try allocator.dupe(u8, "yes"),
        }}),
    };
    const timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(1), .clock = .awake };
    try std.testing.expectError(error.FetchTimeout, fetchNative(std.testing.io, allocator, request, timeout, Stall.fetch));

    var requests: [max_fetch_requests]FetchRequest = @splat(request);
    const results = try allocator.alloc(?FetchResponse, requests.len);
    @memset(results, null);
    fetchAllNative(allocator, std.testing.io, results, &requests, timeout, Stall.fetch, spawnNativeFetchWorker);
    arena.deinit();

    while (Stall.entered.load(.acquire) < max_fetch_concurrency) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(usize, 0), native_fetch_slots.load(.acquire));
    try std.testing.expectError(error.FetchConcurrencyLimitExceeded, startNativeFetch(
        std.testing.io,
        request,
        timeout,
        Stall.fetch,
        spawnNativeFetchWorker,
    ));
    try std.testing.expectEqual(initial_contexts + max_fetch_concurrency, native_fetch_contexts.load(.monotonic));
    Stall.release.store(true, .release);
    while (native_fetch_contexts.load(.monotonic) != initial_contexts or
        native_fetch_slots.load(.acquire) != max_fetch_concurrency) std.Thread.yield() catch {};
    try std.testing.expectEqual(max_fetch_concurrency, Stall.valid.load(.monotonic));
}

test "native fetch deadline is fixed before delayed worker spawn" {
    if (builtin.os.tag == .freestanding or builtin.single_threaded) return error.SkipZigTest;
    const Delayed = struct {
        var started = std.atomic.Value(usize).init(0);

        fn fetch(io: std.Io, allocator: std.mem.Allocator, opts: FetchRequest) !FetchResponse {
            _ = io;
            _ = allocator;
            _ = opts;
            _ = started.fetchAdd(1, .monotonic);
            return error.UnexpectedFetch;
        }

        fn spawn(context: *NativeFetchContext, fetch_fn: NativeFetchFn) !std.Thread {
            try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
            return spawnNativeFetchWorker(context, fetch_fn);
        }
    };

    const initial_contexts = native_fetch_contexts.load(.monotonic);
    const timeout: std.Io.Clock.Duration = .{ .raw = .zero, .clock = .awake };
    const job = try startNativeFetch(
        std.testing.io,
        .{ .url = "http://delayed-spawn.invalid" },
        timeout,
        Delayed.fetch,
        Delayed.spawn,
    );
    try std.testing.expectError(error.FetchTimeout, job.await(std.testing.allocator));
    while (native_fetch_contexts.load(.monotonic) != initial_contexts or
        native_fetch_slots.load(.acquire) != max_fetch_concurrency) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(usize, 0), Delayed.started.load(.monotonic));
}

test "cancellable stalled native fetch releases its worker slot" {
    if (builtin.os.tag == .freestanding or builtin.single_threaded) return error.SkipZigTest;
    const Stall = struct {
        var event: std.Io.Event = .unset;

        fn fetch(io: std.Io, allocator: std.mem.Allocator, opts: FetchRequest) !FetchResponse {
            _ = allocator;
            _ = opts;
            try event.wait(io);
            return error.UnexpectedStallRelease;
        }
    };

    const initial_contexts = native_fetch_contexts.load(.monotonic);
    const timeout: std.Io.Clock.Duration = .{ .raw = .zero, .clock = .awake };
    try std.testing.expectError(error.FetchTimeout, fetchNative(
        std.testing.io,
        std.testing.allocator,
        .{ .url = "http://cancellable-stall.invalid" },
        timeout,
        Stall.fetch,
    ));
    while (native_fetch_contexts.load(.monotonic) != initial_contexts or
        native_fetch_slots.load(.acquire) != max_fetch_concurrency) std.Thread.yield() catch {};
    for (0..max_fetch_concurrency) |_| try std.testing.expect(tryAcquireFetchSlot());
    for (0..max_fetch_concurrency) |_| releaseFetchSlot();
}

test "native fetch spawn failure releases its slot and owned context once" {
    if (builtin.os.tag == .freestanding or builtin.single_threaded) return error.SkipZigTest;
    const Fake = struct {
        fn fetch(io: std.Io, allocator: std.mem.Allocator, opts: FetchRequest) !FetchResponse {
            _ = io;
            _ = allocator;
            _ = opts;
            return error.UnexpectedFetch;
        }

        fn fail(context: *NativeFetchContext, fetch_fn: NativeFetchFn) !std.Thread {
            _ = context;
            _ = fetch_fn;
            return error.DeterministicSpawnFailure;
        }
    };
    const initial_contexts = native_fetch_contexts.load(.monotonic);
    try std.testing.expectError(error.DeterministicSpawnFailure, startNativeFetch(
        std.testing.io,
        .{ .url = "http://unused.invalid" },
        fetch_total_timeout,
        Fake.fetch,
        Fake.fail,
    ));
    try std.testing.expectEqual(initial_contexts, native_fetch_contexts.load(.monotonic));
    try std.testing.expectEqual(max_fetch_concurrency, native_fetch_slots.load(.acquire));
}

test "native fetch admission fails fast at the process-wide limit" {
    if (builtin.os.tag == .freestanding) return error.SkipZigTest;
    for (0..max_fetch_concurrency) |_| try std.testing.expect(tryAcquireFetchSlot());
    defer for (0..max_fetch_concurrency) |_| releaseFetchSlot();
    try std.testing.expect(!tryAcquireFetchSlot());
    try std.testing.expectError(error.FetchConcurrencyLimitExceeded, fetch(std.testing.allocator, .{ .url = "http://unused.invalid" }));
    const results = fetchAll(std.testing.allocator, &.{.{ .url = "http://unused.invalid" }});
    defer std.testing.allocator.free(results);
    try std.testing.expect(results[0] == null);
}

test "FetchRequest defaults to a bounded response" {
    const request: FetchRequest = .{ .url = "https://example.com" };
    try std.testing.expectEqual(default_max_response_size, request.max_response_size);
}

test "fetch rejects an unsafe response limit before allocating or opening a client" {
    try std.testing.expectError(error.ResponseSizeLimitExceeded, fetch(std.testing.allocator, .{
        .url = "https://example.com",
        .max_response_size = max_response_size_limit + 1,
    }));
}

test "serialized request sizing includes method body and duplicate headers" {
    const request: FetchRequest = .{
        .url = "https://example.com/data",
        .method = .POST,
        .body = "payload",
        .headers = &.{
            .{ .name = "x-test", .value = "one" },
            .{ .name = "x-test", .value = "two" },
        },
        .max_response_size = 1234,
    };
    try std.testing.expectEqual(@as(?usize, 24 + 4 + 24 + 7 + 8 + 6 + 3 + 8 + 6 + 3), serializedRequestSize(request));
    try std.testing.expect(requestHash(request) != requestHash(.{ .url = request.url }));
}

test "legacy WASM bridge signatures fail closed" {
    const end_collect: *const fn () []const u8 = wasmEndCollect;
    const provide_result: *const fn ([]const u8, []const u8) void = wasmProvideResult;
    const clear_cache: *const fn () void = wasmClearCache;
    _ = wasmClearCacheV2();
    defer _ = wasmClearCacheV2();
    wasmBeginCollect();
    try std.testing.expectEqualStrings("", end_collect());
    provide_result("https://example.test", "body");
    try std.testing.expectEqual(WasmFetchError.protocol_mismatch, wasm_last_error);
    clear_cache();
}

test "WASM response status validation preserves actual status" {
    try std.testing.expectEqual(std.http.Status.created, statusFromInt(201).?);
    try std.testing.expectEqual(@as(u10, 299), @intFromEnum(statusFromInt(299).?));
    try std.testing.expect(statusFromInt(99) == null);
    try std.testing.expect(statusFromInt(600) == null);
}

test "WASM bridge discovers and replays a response-dependent fetch round" {
    if (builtin.os.tag == .freestanding) return error.SkipZigTest;
    _ = wasmClearCacheV2();
    defer _ = wasmClearCacheV2();
    const first: FetchRequest = .{ .url = "https://example.test/index" };
    const second: FetchRequest = .{ .url = "https://example.test/detail-id" };

    wasmBeginCollect();
    try std.testing.expect(collectOrReplayRequest(std.testing.allocator, first) == null);
    _ = wasmEndCollectV2();
    const first_state = try std.testing.allocator.dupe(u8, wasmExpectedState());
    defer std.testing.allocator.free(first_state);

    _ = wasmClearCacheV2();
    try std.testing.expectEqual(@as(u32, 0), wasmRestoreExpectedState(first_state));
    try std.testing.expectEqual(@as(u32, 0), wasmProvideResultV2(0, 200, "detail-id"));
    wasmBeginCollect();
    const dependency = collectOrReplayRequest(std.testing.allocator, first).?;
    defer dependency.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("detail-id", dependency.body);
    try std.testing.expect(collectOrReplayRequest(std.testing.allocator, second) == null);
    _ = wasmEndCollectV2();
    const complete_state = try std.testing.allocator.dupe(u8, wasmExpectedState());
    defer std.testing.allocator.free(complete_state);

    _ = wasmClearCacheV2();
    try std.testing.expectEqual(@as(u32, 0), wasmRestoreExpectedState(complete_state));
    try std.testing.expectEqual(@as(u32, 0), wasmProvideResultV2(0, 200, "detail-id"));
    try std.testing.expectEqual(@as(u32, 0), wasmProvideResultV2(1, 201, "complete"));
    const replayed_first = replayRequest(std.testing.allocator, first).?;
    defer replayed_first.deinit(std.testing.allocator);
    const replayed_second = replayRequest(std.testing.allocator, second).?;
    defer replayed_second.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.created, replayed_second.status);
    try std.testing.expectEqualStrings("complete", replayed_second.body);
}

test "WASM aggregate response admission accounts for replacements" {
    try std.testing.expect(responseFitsCache(max_wasm_response_bytes, 4, 4));
    try std.testing.expect(!responseFitsCache(max_wasm_response_bytes, 4, 5));
}

test "WASM request admission enforces count bytes and response bounds" {
    const request: FetchRequest = .{ .url = "https://example.com" };
    try std.testing.expectEqual(WasmFetchError.too_many_requests, requestValidationError(request, max_wasm_requests, 0).?);
    try std.testing.expectEqual(WasmFetchError.request_bytes_exceeded, requestValidationError(request, 0, max_wasm_request_bytes).?);
    try std.testing.expectEqual(WasmFetchError.invalid_max_response_size, requestValidationError(.{
        .url = request.url,
        .max_response_size = max_response_size_limit + 1,
    }, 0, 0).?);
}

test "zero and over-limit request lists return allocator-owned empty slices" {
    const empty = fetchAll(std.testing.allocator, &.{});
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    var too_many: [max_fetch_requests + 1]FetchRequest = undefined;
    for (&too_many) |*request| request.* = .{ .url = "https://example.com" };
    const rejected = fetchAll(std.testing.allocator, &too_many);
    defer std.testing.allocator.free(rejected);
    try std.testing.expectEqual(@as(usize, 0), rejected.len);
}
