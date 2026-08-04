// static.zig — serve files from public/ with in-memory cache (Zig 0.16).

const std = @import("std");
const builtin = @import("builtin");
const mer = @import("mer");
const security = @import("security.zig");

// Zig 0.16 removed Thread.Mutex. This small yielding lock is portable and the
// cache never holds it while writing a response.
const CacheMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(m: *CacheMutex) void {
        while (!m.inner.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
    }

    pub fn unlock(m: *CacheMutex) void {
        m.inner.unlock();
    }
};

const mime_table = [_]struct { ext: []const u8, ct: mer.ContentType }{
    .{ .ext = ".html", .ct = .html },
    .{ .ext = ".htm", .ct = .html },
    .{ .ext = ".css", .ct = .css },
    .{ .ext = ".js", .ct = .js },
    .{ .ext = ".wasm", .ct = .wasm },
    .{ .ext = ".json", .ct = .json },
    .{ .ext = ".txt", .ct = .text },
    .{ .ext = ".png", .ct = .png },
    .{ .ext = ".jpg", .ct = .jpeg },
    .{ .ext = ".jpeg", .ct = .jpeg },
    .{ .ext = ".gif", .ct = .gif },
    .{ .ext = ".svg", .ct = .svg },
    .{ .ext = ".ico", .ct = .ico },
    .{ .ext = ".webp", .ct = .webp },
};

fn mimeForPath(path: []const u8) mer.ContentType {
    for (mime_table) |entry| {
        if (std.mem.endsWith(u8, path, entry.ext)) return entry.ct;
    }
    return .octet_stream;
}

/// Cached static file entry. Both the map key and body are cache-owned.
const CacheEntry = struct {
    key: []u8,
    body: []u8,
    ct: mer.ContentType,
    sequence: u64,
    refs: usize = 1, // one cache reference plus active leases
    allocator: std.mem.Allocator,
};

pub const CacheLimits = struct {
    max_entries: usize = 256,
    max_bytes: usize = 64 * 1024 * 1024,
    /// Bounds bytes pinned by concurrent static responses.
    max_in_flight_bytes: usize = 128 * 1024 * 1024,
};

/// Process-wide cache. Entries are stable allocations pinned by response leases.
var cache: std.StringHashMapUnmanaged(*CacheEntry) = .{};
var cache_loads: std.StringHashMapUnmanaged(*CacheLoad) = .{};
// Cache storage must outlive every Server allocator and every outstanding lease.
const cache_alloc = std.heap.page_allocator;
var cache_mu: CacheMutex = .{};
var cache_init_done: bool = false;
var cache_owners: usize = 0;
var cache_limits: CacheLimits = .{};
var cache_bytes: usize = 0;
var cache_in_flight_bytes: usize = 0;
var cache_sequence: u64 = 0;
var cache_generation: u64 = 0;

/// Joins the process cache. The first active owner deterministically selects the
/// limits; later owners with different limits share those limits until all
/// active owners call deinitCache.
pub fn initCache(alloc: std.mem.Allocator, limits: CacheLimits) void {
    _ = alloc;
    cache_mu.lock();
    defer cache_mu.unlock();
    if (cache_owners == 0) {
        cache_limits = limits;
        cache_generation +%= 1;
        cache_init_done = true;
    }
    cache_owners += 1;
}

pub fn deinitCache() void {
    cache_mu.lock();
    defer cache_mu.unlock();
    if (cache_owners == 0) return;
    cache_owners -= 1;
    if (cache_owners != 0) return;
    deinitCacheLocked();
}

fn deinitCacheLocked() void {
    var it = cache.iterator();
    while (it.next()) |item| releaseEntryLocked(item.value_ptr.*);
    cache.deinit(cache_alloc);
    cache = .{};
    cache_bytes = 0;
    cache_sequence = 0;
    cache_init_done = false;
    // Owners and followers retain CacheLoad objects until they finish. The load
    // map is drained by those leases rather than invalidated during teardown.
    if (cache_loads.count() == 0) {
        cache_loads.deinit(cache_alloc);
        cache_loads = .{};
    }
}

fn releaseEntryLocked(entry: *CacheEntry) void {
    entry.refs -= 1;
    if (entry.refs != 0) return;
    const allocator = entry.allocator;
    allocator.free(entry.key);
    allocator.free(entry.body);
    allocator.destroy(entry);
}

const CacheLease = struct {
    entry: *CacheEntry,

    fn release(self: CacheLease) void {
        cache_mu.lock();
        defer cache_mu.unlock();
        cache_in_flight_bytes -|= self.entry.body.len;
        releaseEntryLocked(self.entry);
    }
};

const CacheLookup = union(enum) {
    miss,
    overloaded,
    hit: CacheLease,
};

const LoadResult = enum { found, not_found, send_error };

const CacheLoad = struct {
    key: []u8,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: LoadResult = .found,
    refs: usize = 1,
};

const LoadLease = struct {
    load: *CacheLoad,
    owner: bool,

    fn wait(self: LoadLease) LoadResult {
        while (!self.load.done.load(.acquire)) std.Thread.yield() catch std.atomic.spinLoopHint();
        return self.load.result;
    }

    fn finish(self: LoadLease, result: LoadResult) void {
        if (!self.owner) return;
        cache_mu.lock();
        _ = cache_loads.remove(self.load.key);
        self.load.result = result;
        self.load.done.store(true, .release);
        releaseLoadLocked(self.load);
        cache_mu.unlock();
    }

    fn release(self: LoadLease) void {
        if (self.owner) return;
        cache_mu.lock();
        releaseLoadLocked(self.load);
        cache_mu.unlock();
    }
};

fn releaseLoadLocked(load: *CacheLoad) void {
    load.refs -= 1;
    if (load.refs != 0) return;
    cache_alloc.free(load.key);
    cache_alloc.destroy(load);
    if (!cache_init_done and cache_loads.count() == 0) {
        cache_loads.deinit(cache_alloc);
        cache_loads = .{};
    }
}

fn beginLoad(key: []const u8) ?LoadLease {
    cache_mu.lock();
    defer cache_mu.unlock();
    if (!cache_init_done) return null;
    if (cache_loads.get(key)) |load| {
        load.refs += 1;
        return .{ .load = load, .owner = false };
    }
    const load = cache_alloc.create(CacheLoad) catch return null;
    const owned_key = cache_alloc.dupe(u8, key) catch {
        cache_alloc.destroy(load);
        return null;
    };
    load.* = .{ .key = owned_key };
    cache_loads.put(cache_alloc, load.key, load) catch {
        cache_alloc.free(owned_key);
        cache_alloc.destroy(load);
        return null;
    };
    return .{ .load = load, .owner = true };
}

/// Pins cache storage without copying it while the response is in flight.
fn getCached(key: []const u8) CacheLookup {
    cache_mu.lock();
    defer cache_mu.unlock();
    if (!cache_init_done) return .miss;
    const entry = cache.get(key) orelse return .miss;
    if (entry.body.len > cache_limits.max_in_flight_bytes -| cache_in_flight_bytes) return .overloaded;
    entry.refs += 1;
    cache_in_flight_bytes += entry.body.len;
    return .{ .hit = .{ .entry = entry } };
}

pub fn reserveInFlight(bytes: usize) bool {
    cache_mu.lock();
    defer cache_mu.unlock();
    if (!cache_init_done or bytes > cache_limits.max_in_flight_bytes -| cache_in_flight_bytes) return false;
    cache_in_flight_bytes += bytes;
    return true;
}

pub fn releaseInFlight(bytes: usize) void {
    cache_mu.lock();
    defer cache_mu.unlock();
    cache_in_flight_bytes -|= bytes;
}

fn evictOldestLocked() void {
    var oldest_key: ?[]const u8 = null;
    var oldest_sequence: u64 = std.math.maxInt(u64);
    var it = cache.iterator();
    while (it.next()) |item| {
        if (item.value_ptr.*.sequence < oldest_sequence) {
            oldest_sequence = item.value_ptr.*.sequence;
            oldest_key = item.key_ptr.*;
        }
    }
    const key = oldest_key orelse return;
    const removed = cache.fetchRemove(key) orelse return;
    cache_bytes -= removed.value.body.len;
    releaseEntryLocked(removed.value);
}

fn putCache(key_src: []const u8, body: []const u8, ct: mer.ContentType) void {
    cache_mu.lock();
    if (!cache_init_done or cache_limits.max_entries == 0 or body.len > cache_limits.max_bytes or cache.contains(key_src)) {
        cache_mu.unlock();
        return;
    }
    const allocator = cache_alloc;
    const generation = cache_generation;
    cache_mu.unlock();

    // Large allocation/copy work is deliberately outside the cache mutex.
    const entry = allocator.create(CacheEntry) catch return;
    const key = allocator.dupe(u8, key_src) catch {
        allocator.destroy(entry);
        return;
    };
    const owned_body = allocator.dupe(u8, body) catch {
        allocator.free(key);
        allocator.destroy(entry);
        return;
    };
    entry.* = .{ .key = key, .body = owned_body, .ct = ct, .sequence = 0, .allocator = allocator };

    cache_mu.lock();
    defer cache_mu.unlock();
    if (!cache_init_done or cache_generation != generation or cache.contains(key_src)) {
        releaseEntryLocked(entry);
        return;
    }
    while (cache.count() >= cache_limits.max_entries or cache_bytes > cache_limits.max_bytes - body.len) {
        evictOldestLocked();
    }
    cache_sequence +%= 1;
    entry.sequence = cache_sequence;
    cache.put(cache_alloc, entry.key, entry) catch {
        releaseEntryLocked(entry);
        return;
    };
    cache_bytes += owned_body.len;
}

/// Attempt to serve `url_path` from the public/ directory. The tri-state result
/// keeps misses distinct from failures after response commitment.
/// Options for static serving.
pub const ServeResult = enum { served, not_found, send_error };

pub const ServeOpts = struct {
    /// Directory to serve from (default "public"). Set to "dist" for a built SPA.
    dir: []const u8 = "public",
    /// When true, "/" serves index.html and unknown paths fall back to it
    /// (SPA history-fallback mode). Use for Vite/React builds with client routing.
    spa: bool = false,
    dev: bool = false,
    csp: []const u8 = security.production_csp,
    on_commit: ?*const fn (std.http.Status) void = null,
};

fn isSafeRelativePath(rel: []const u8) bool {
    if (rel.len == 0 or std.mem.indexOfScalar(u8, rel, 0) != null or std.mem.indexOfScalar(u8, rel, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn pathWithinProject(path: []const u8, project: []const u8) bool {
    const equal = if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(path, project)
    else
        std.mem.eql(u8, path, project);
    if (equal) return true;
    const starts = if (builtin.os.tag == .windows)
        std.ascii.startsWithIgnoreCase(path, project)
    else
        std.mem.startsWith(u8, path, project);
    if (!starts or project.len == 0 or path.len <= project.len) return false;
    return if (builtin.os.tag == .windows)
        project[project.len - 1] == '/' or project[project.len - 1] == '\\' or path[project.len] == '/' or path[project.len] == '\\'
    else
        project[project.len - 1] == '/' or path[project.len] == '/';
}

fn configuredRootRequiresProjectContainment(dir: []const u8) bool {
    return !std.fs.path.isAbsolute(dir);
}

fn openedDirIsInsideProject(dir: std.Io.Dir, io: std.Io) bool {
    var project_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const project_len = std.Io.Dir.cwd().realPath(io, &project_buf) catch return false;
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = dir.realPath(io, &dir_buf) catch return false;
    return pathWithinProject(dir_buf[0..dir_len], project_buf[0..project_len]);
}

/// Read a static file by walking one component at a time below an already-open
/// root directory. No component may be a symlink, so path validation and file
/// opening are tied to directory handles rather than a race-prone path check.
pub const MaterializedFile = struct {
    body: []u8,
    reserved: usize,

    pub fn release(self: MaterializedFile) void {
        if (self.reserved != 0) releaseInFlight(self.reserved);
    }
};

fn readAdmittedFileBody(reader: *std.Io.Reader, alloc: std.mem.Allocator, admitted_size: usize) ![]u8 {
    return reader.allocRemaining(alloc, .limited(admitted_size));
}

pub const MaterializeResult = union(enum) {
    file: MaterializedFile,
    not_found,
    send_error,
};

fn openFailure(err: anyerror) MaterializeResult {
    return switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.IsDir,
        error.SymLinkLoop,
        error.NetworkNotFound,
        error.BadPathName,
        error.NameTooLong,
        => .not_found,
        else => .send_error,
    };
}

fn materializeContainedFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    rel: []const u8,
    admission_copies: usize,
) MaterializeResult {
    if (!isSafeRelativePath(rel)) return .not_found;

    var current = std.Io.Dir.cwd().openDir(io, dir, .{}) catch |err| return openFailure(err);
    defer current.close(io);
    // Absolute configured roots are trusted (for example, packaged .app
    // resources). Relative roots may follow a top-level symlink only when it
    // resolves within the project (public -> examples/site/public is intentional).
    if (configuredRootRequiresProjectContainment(dir) and !openedDirIsInsideProject(current, io)) return .not_found;

    var parts = std.mem.splitScalar(u8, rel, '/');
    var component = parts.next() orelse return .not_found;
    while (parts.next()) |next| {
        const child = current.openDir(io, component, .{ .follow_symlinks = false }) catch |err| return openFailure(err);
        current.close(io);
        current = child;
        component = next;
    }

    const file = current.openFile(io, component, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| return openFailure(err);
    defer file.close(io);
    const stat = file.stat(io) catch return .send_error;
    const size = std.math.cast(usize, stat.size) orelse return .send_error;
    if (size > 10 * 1024 * 1024) return .send_error;
    const reserved = std.math.mul(usize, size, admission_copies) catch return .send_error;
    if (reserved != 0 and !reserveInFlight(reserved)) return .send_error;

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    // The stat size is the admission decision. A file that grows afterward
    // must not cause a larger allocation or escape the in-flight reservation.
    const body = readAdmittedFileBody(&reader.interface, alloc, size) catch {
        if (reserved != 0) releaseInFlight(reserved);
        return .send_error;
    };
    return .{ .file = .{ .body = body, .reserved = reserved } };
}

pub fn readContainedFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    rel: []const u8,
) ?[]u8 {
    return switch (materializeContainedFile(alloc, io, dir, rel, 0)) {
        .file => |file| file.body,
        .not_found, .send_error => null,
    };
}

/// Reserve response bytes from the file's stat size before allocating or reading.
pub fn readContainedFileInFlight(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    rel: []const u8,
) MaterializeResult {
    return materializeContainedFile(alloc, io, dir, rel, 1);
}

pub fn tryServe(
    alloc: std.mem.Allocator,
    std_req: *std.http.Server.Request,
    url_path: []const u8,
    io: std.Io,
    opts: ServeOpts,
) ServeResult {
    const rel = if (url_path.len > 0 and url_path[0] == '/') url_path[1..] else url_path;

    // "/" or empty → index.html.
    if (rel.len == 0) {
        if (opts.spa) return serveIndex(alloc, std_req, opts.dir, io, opts);
        return .not_found;
    }
    if (!isSafeRelativePath(rel)) return .not_found;

    const cache_key = std.fmt.allocPrint(alloc, "{s}/{s}", .{ opts.dir, rel }) catch return .send_error;
    defer alloc.free(cache_key);
    var load: ?LoadLease = null;
    if (!opts.dev) {
        switch (getCached(cache_key)) {
            .hit => |lease| {
                defer lease.release();
                return sendStatic(std_req, lease.entry.body, lease.entry.ct, rel, opts);
            },
            .overloaded => return .send_error,
            .miss => {},
        }
        load = beginLoad(cache_key) orelse return .send_error;
        if (!load.?.owner) {
            const owner_result = load.?.wait();
            load.?.release();
            switch (getCached(cache_key)) {
                .hit => |lease| {
                    defer lease.release();
                    return sendStatic(std_req, lease.entry.body, lease.entry.ct, rel, opts);
                },
                .overloaded => return .send_error,
                .miss => switch (owner_result) {
                    .not_found => {
                        if (opts.spa) return serveIndex(alloc, std_req, opts.dir, io, opts);
                        return .not_found;
                    },
                    .send_error => return .send_error,
                    .found => {},
                },
            }
            load = null;
        }
    }
    var load_result: LoadResult = .found;
    defer if (load) |lease| lease.finish(load_result);

    const file = switch (materializeContainedFile(alloc, io, opts.dir, rel, if (opts.dev) 1 else 2)) {
        .file => |file| file,
        .not_found => {
            load_result = .not_found;
            if (opts.spa) return serveIndex(alloc, std_req, opts.dir, io, opts);
            return .not_found;
        },
        .send_error => {
            load_result = .send_error;
            return .send_error;
        },
    };
    defer file.release();
    defer alloc.free(file.body);

    const ct = mimeForPath(rel);

    // Development reads from disk on every request so edits are immediately visible.
    if (!opts.dev) putCache(cache_key, file.body, ct);
    // Wake duplicate loaders after the disk/cache decision, never after a
    // potentially slow client socket write.
    if (load) |lease| {
        lease.finish(.found);
        load = null;
    }
    return sendStatic(std_req, file.body, ct, rel, opts);
}

/// Serve <dir>/index.html (SPA shell). Cached under the key "<dir>/index.html".
fn serveIndex(
    alloc: std.mem.Allocator,
    std_req: *std.http.Server.Request,
    dir: []const u8,
    io: std.Io,
    opts: ServeOpts,
) ServeResult {
    const cache_key = std.fmt.allocPrint(alloc, "{s}/index.html", .{dir}) catch return .send_error;
    defer alloc.free(cache_key);
    var load: ?LoadLease = null;
    if (!opts.dev) {
        switch (getCached(cache_key)) {
            .hit => |lease| {
                defer lease.release();
                return sendStatic(std_req, lease.entry.body, lease.entry.ct, "index.html", opts);
            },
            .overloaded => return .send_error,
            .miss => {},
        }
        load = beginLoad(cache_key) orelse return .send_error;
        if (!load.?.owner) {
            const owner_result = load.?.wait();
            load.?.release();
            switch (getCached(cache_key)) {
                .hit => |lease| {
                    defer lease.release();
                    return sendStatic(std_req, lease.entry.body, lease.entry.ct, "index.html", opts);
                },
                .overloaded => return .send_error,
                .miss => switch (owner_result) {
                    .not_found => return .not_found,
                    .send_error => return .send_error,
                    .found => {},
                },
            }
            load = null;
        }
    }
    var load_result: LoadResult = .found;
    defer if (load) |lease| lease.finish(load_result);
    const file = switch (materializeContainedFile(alloc, io, dir, "index.html", if (opts.dev) 1 else 2)) {
        .file => |file| file,
        .not_found => {
            load_result = .not_found;
            return .not_found;
        },
        .send_error => {
            load_result = .send_error;
            return .send_error;
        },
    };
    defer file.release();
    defer alloc.free(file.body);
    if (!opts.dev) putCache(cache_key, file.body, .html);
    if (load) |lease| {
        lease.finish(.found);
        load = null;
    }
    return sendStatic(std_req, file.body, .html, "index.html", opts);
}

fn isFingerprintToken(token: []const u8) bool {
    if (token.len < 16) return false;
    var has_alpha = false;
    var has_digit = false;
    for (token) |c| {
        if (std.ascii.isDigit(c)) {
            has_digit = true;
        } else if ((c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
            has_alpha = true;
        } else return false;
    }
    return has_alpha and has_digit;
}

fn isFingerprinted(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    const extension = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - extension.len];
    const delimiter = std.mem.lastIndexOfAny(u8, stem, ".-") orelse return false;
    if (delimiter == 0) return false;
    return isFingerprintToken(stem[delimiter + 1 ..]);
}

fn browserCacheControl(path: []const u8, ct: mer.ContentType, dev: bool) []const u8 {
    if (dev) return "no-store";
    if (ct == .html) return "no-cache";
    if (isFingerprinted(path)) return "public, max-age=31536000, immutable";
    return "public, max-age=3600";
}

fn sendStatic(std_req: *std.http.Server.Request, body: []const u8, ct: mer.ContentType, path: []const u8, opts: ServeOpts) ServeResult {
    var extra: [2 + security.header_count]std.http.Header = undefined;
    extra[0] = .{ .name = "content-type", .value = ct.mime() };
    extra[1] = .{ .name = "cache-control", .value = browserCacheControl(path, ct, opts.dev) };
    const security_headers = security.headers(opts.csp);
    @memcpy(extra[2..], &security_headers);

    var header_buf: [2048]u8 = undefined;
    var bw = std_req.respondStreaming(&header_buf, .{
        .content_length = body.len,
        .respond_options = .{
            .status = .ok,
            .extra_headers = &extra,
        },
    }) catch return .send_error;
    if (opts.on_commit) |on_commit| on_commit(.ok);
    if (std_req.head.method != .HEAD) bw.writer.writeAll(body) catch return .send_error;
    bw.end() catch return .send_error;
    return .served;
}

test "cold cache loads are single-flight per key" {
    initCache(std.testing.allocator, .{});
    defer deinitCache();

    const owner = beginLoad("public/cold.js") orelse return error.TestUnexpectedResult;
    try std.testing.expect(owner.owner);
    const follower = beginLoad("public/cold.js") orelse return error.TestUnexpectedResult;
    try std.testing.expect(!follower.owner);
    owner.finish(.found);
    try std.testing.expectEqual(LoadResult.found, follower.wait());
    follower.release();
    try std.testing.expectEqual(@as(usize, 0), cache_loads.count());
}

test "concurrent server owners keep leases and loads alive through teardown" {
    initCache(std.testing.allocator, .{ .max_entries = 1, .max_bytes = 16, .max_in_flight_bytes = 16 });
    putCache("shared", "stable", .text);
    const held = switch (getCached("shared")) {
        .hit => |lease| lease,
        else => return error.TestUnexpectedResult,
    };
    const owner = beginLoad("public/concurrent.js") orelse return error.TestUnexpectedResult;

    const Context = struct {
        ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

        fn run(ctx: *@This()) void {
            var buffer: [128]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buffer);
            initCache(fba.allocator(), .{ .max_entries = 99, .max_bytes = 99, .max_in_flight_bytes = 99 });
            const follower = beginLoad("public/concurrent.js") orelse {
                ctx.ok.store(false, .release);
                ctx.ready.store(true, .release);
                deinitCache();
                return;
            };
            ctx.ready.store(true, .release);
            if (follower.owner or follower.wait() != .found) ctx.ok.store(false, .release);
            follower.release();
            deinitCache();
        }
    };
    var ctx: Context = .{};
    const thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});
    while (!ctx.ready.load(.acquire)) std.Thread.yield() catch std.atomic.spinLoopHint();

    cache_mu.lock();
    const owners = cache_owners;
    const max_entries = cache_limits.max_entries;
    cache_mu.unlock();
    try std.testing.expectEqual(@as(usize, 2), owners);
    try std.testing.expectEqual(@as(usize, 1), max_entries);
    deinitCache();
    owner.finish(.found);
    thread.join();

    try std.testing.expect(ctx.ok.load(.acquire));
    try std.testing.expectEqualStrings("stable", held.entry.body);
    held.release();
    try std.testing.expectEqual(@as(usize, 0), cache_in_flight_bytes);
    deinitCache();
}

test "duplicate missing-path follower observes the owner miss" {
    initCache(std.testing.allocator, .{});
    defer deinitCache();

    const owner = beginLoad("public/does-not-exist") orelse return error.TestUnexpectedResult;
    const follower = beginLoad("public/does-not-exist") orelse return error.TestUnexpectedResult;
    const Context = struct {
        lease: LoadLease,
        result: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

        fn run(ctx: *@This()) void {
            const result = ctx.lease.wait();
            ctx.result.store(if (result == .not_found) 1 else 2, .release);
            ctx.lease.release();
        }
    };
    var ctx: Context = .{ .lease = follower };
    const thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});
    owner.finish(.not_found);
    thread.join();

    try std.testing.expectEqual(@as(u8, 1), ctx.result.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), cache_loads.count());
}

test "duplicate failed-load follower observes the owner send error" {
    initCache(std.testing.allocator, .{});
    defer deinitCache();

    const owner = beginLoad("public/overloaded") orelse return error.TestUnexpectedResult;
    const follower = beginLoad("public/overloaded") orelse return error.TestUnexpectedResult;
    const Context = struct {
        lease: LoadLease,
        result: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(ctx: *@This()) void {
            ctx.result.store(ctx.lease.wait() == .send_error, .release);
            ctx.lease.release();
        }
    };
    var ctx: Context = .{ .lease = follower };
    const thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});
    owner.finish(.send_error);
    thread.join();

    try std.testing.expect(ctx.result.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), cache_loads.count());
}

test "cold materialization admission accounts for body and cache copy" {
    initCache(std.testing.allocator, .{ .max_in_flight_bytes = 7 });
    defer deinitCache();

    try std.testing.expect(reserveInFlight(3 * 2));
    try std.testing.expect(!reserveInFlight(2));
    releaseInFlight(3 * 2);
    try std.testing.expectEqual(@as(usize, 0), cache_in_flight_bytes);
}

test "file growth beyond the stat admission is rejected" {
    var reader = std.Io.Reader.fixed("grew");
    try std.testing.expectError(error.StreamTooLong, readAdmittedFileBody(&reader, std.testing.allocator, 3));
}

test "in-flight contained reads are admitted before body allocation" {
    const alloc = std.testing.allocator;
    initCache(alloc, .{ .max_in_flight_bytes = 1 });
    defer deinitCache();

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expect(readContainedFileInFlight(failing.allocator(), std.testing.io, "src", "static.zig") == .send_error);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), cache_in_flight_bytes);
}

test "static cache is byte and entry bounded with deterministic eviction" {
    const alloc = std.testing.allocator;
    initCache(alloc, .{ .max_entries = 2, .max_bytes = 6 });
    defer deinitCache();

    putCache("a", "aa", .text);
    putCache("b", "bbb", .text);
    putCache("c", "cc", .text); // byte limit evicts oldest entry, a
    try std.testing.expect(getCached("a") == .miss);
    const b = switch (getCached("b")) {
        .hit => |lease| lease,
        else => return error.TestUnexpectedResult,
    };
    defer b.release();
    try std.testing.expectEqualStrings("bbb", b.entry.body);
    const c = switch (getCached("c")) {
        .hit => |lease| lease,
        else => return error.TestUnexpectedResult,
    };
    defer c.release();
    try std.testing.expectEqualStrings("cc", c.entry.body);
    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expectEqual(@as(usize, 5), cache_bytes);

    putCache("oversized", "1234567", .text);
    try std.testing.expect(getCached("oversized") == .miss);
    try std.testing.expectEqual(@as(usize, 2), cache.count());
}

test "cached response body remains owned across eviction and teardown is idempotent" {
    const alloc = std.testing.allocator;
    initCache(alloc, .{ .max_entries = 1, .max_bytes = 16 });
    putCache("first", "stable", .text);
    const held = switch (getCached("first")) {
        .hit => |lease| lease,
        else => return error.TestUnexpectedResult,
    };
    putCache("second", "new", .text);
    try std.testing.expect(getCached("first") == .miss);
    try std.testing.expectEqualStrings("stable", held.entry.body);
    deinitCache();
    try std.testing.expectEqualStrings("stable", held.entry.body);
    held.release();
    deinitCache();
}

test "static leases pin evicted bytes and enforce the in-flight bound" {
    initCache(std.testing.allocator, .{ .max_entries = 1, .max_bytes = 16, .max_in_flight_bytes = 6 });
    defer deinitCache();
    putCache("first", "stable", .text);

    const held = switch (getCached("first")) {
        .hit => |lease| lease,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(getCached("first") == .overloaded);
    putCache("second", "new", .text);
    try std.testing.expectEqualStrings("stable", held.entry.body);
    held.release();
    try std.testing.expectEqual(@as(usize, 0), cache_in_flight_bytes);
}

test "browser cache policy distinguishes HTML, development, and fingerprints" {
    try std.testing.expectEqualStrings("no-store", browserCacheControl("assets/app.js", .js, true));
    try std.testing.expectEqualStrings("no-cache", browserCacheControl("index.html", .html, false));
    try std.testing.expectEqualStrings("public, max-age=31536000, immutable", browserCacheControl("assets/app-a1B2c3D4e5F60718.js", .js, false));
    try std.testing.expectEqualStrings("public, max-age=31536000, immutable", browserCacheControl("assets/app.0123abcdefABCDEF.css", .css, false));
    try std.testing.expectEqualStrings("public, max-age=3600", browserCacheControl("assets/application.js", .js, false));
}

test "immutable assets require a delimited mixed all-hex content hash of at least 16 characters" {
    try std.testing.expect(isFingerprinted("assets/app-a1b2c3d4e5f60718.js"));
    try std.testing.expect(isFingerprinted("assets/app.0123456789ABCDEF.css"));
    try std.testing.expect(!isFingerprinted("assets/appa1b2c3d4e5f60718.js"));
    try std.testing.expect(!isFingerprinted("assets/app-a1b2c3d4e5f6071.js"));
    try std.testing.expect(!isFingerprinted("assets/app-a1b2c3d4e5f6071g.js"));
    try std.testing.expect(!isFingerprinted("annual-cafe2024.js"));
    try std.testing.expect(!isFingerprinted("release-deadbeef.js"));
    try std.testing.expect(!isFingerprinted("report-2024-01-31.pdf"));
    try std.testing.expect(!isFingerprinted("library-v1.2.3.js"));
    try std.testing.expect(!isFingerprinted("report-2024202420242024.pdf"));
}

test "directory final components are treated as route misses" {
    try std.testing.expect(openFailure(error.IsDir) == .not_found);
    try std.testing.expect(openFailure(error.AccessDenied) == .send_error);
    try std.testing.expect(openFailure(error.SystemResources) == .send_error);
}

test "static relative paths reject traversal and ambiguous separators" {
    try std.testing.expect(pathWithinProject("/app/public/index.html", "/app"));
    try std.testing.expect(!pathWithinProject("/application/secret", "/app"));
    if (builtin.os.tag != .windows) try std.testing.expect(!pathWithinProject("/app\\private/secret", "/app\\"));
    try std.testing.expect(isSafeRelativePath("index.html"));
    try std.testing.expect(isSafeRelativePath("assets/app.js"));
    try std.testing.expect(!isSafeRelativePath("../secret"));
    try std.testing.expect(!isSafeRelativePath("assets/../secret"));
    try std.testing.expect(!isSafeRelativePath("assets//app.js"));
    try std.testing.expect(!isSafeRelativePath("assets\\app.js"));
}

test "trusted absolute static roots may be outside cwd" {
    try std.testing.expect(configuredRootRequiresProjectContainment("public"));
    if (builtin.os.tag == .windows) {
        try std.testing.expect(!configuredRootRequiresProjectContainment("C:\\Applications\\Mer.app\\Resources\\public"));
    } else {
        try std.testing.expect(!configuredRootRequiresProjectContainment("/Applications/Mer.app/Contents/Resources/public"));
    }
}

test "relative static roots reject contained and escaping symlinks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "root", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "root/inside.txt", .data = "inside" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside.txt", .data = "outside" });
    try tmp.dir.createDir(std.testing.io, "outside-dir", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside-dir/nested.txt", .data = "nested outside" });
    try tmp.dir.symLink(std.testing.io, "inside.txt", "root/inside-link", .{});
    try tmp.dir.symLink(std.testing.io, "../outside.txt", "root/outside-link", .{});
    try tmp.dir.symLink(std.testing.io, "../outside-dir", "root/outside-dir-link", .{ .is_directory = true });
    try tmp.dir.symLink(std.testing.io, "/etc", "outside-project-root", .{ .is_directory = true });

    const root_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/root", .{tmp.sub_path});
    defer alloc.free(root_path);

    const inside = readContainedFile(alloc, std.testing.io, root_path, "inside.txt") orelse return error.TestUnexpectedResult;
    defer alloc.free(inside);
    try std.testing.expectEqualStrings("inside", inside);
    try std.testing.expect(readContainedFile(alloc, std.testing.io, root_path, "inside-link") == null);
    try std.testing.expect(readContainedFile(alloc, std.testing.io, root_path, "outside-link") == null);
    try std.testing.expect(readContainedFile(alloc, std.testing.io, root_path, "outside-dir-link/nested.txt") == null);

    const outside_root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/outside-project-root", .{tmp.sub_path});
    defer alloc.free(outside_root);
    try std.testing.expect(readContainedFile(alloc, std.testing.io, outside_root, "passwd") == null);
}
