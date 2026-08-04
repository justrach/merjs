// update.zig — signed update feed checks for native apps.
//
// This module implements the production-safe updater core for PR #100:
// signed update metadata verification, update availability decisions, and
// artifact byte/hash verification. It intentionally does not install or replace
// a running app; platform-specific self-install/rollback is separate work.

const std = @import("std");
const manifest_mod = @import("manifest.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_manifest_bytes: usize = 256 * 1024;
pub const max_artifact_bytes: usize = 512 * 1024 * 1024;

pub const Error = error{
    ManifestTooLarge,
    ArtifactTooLarge,
    ArtifactHashMismatch,
    InvalidSchemaVersion,
    InvalidMetadataVersion,
    StaleUpdateMetadata,
    EquivocatingUpdateMetadata,
    UpdateStateTargetMismatch,
    MissingAppId,
    MissingVersion,
    MissingPlatform,
    MissingPlatformField,
    InvalidUrl,
    InvalidHash,
    InvalidSignature,
    InvalidSize,
    DuplicatePlatform,
    InvalidVersion,
    RollbackWindowInvalid,
    PartialUpdateConfig,
    InvalidProvider,
    InvalidPublicKey,
    InvalidJson,
    AppIdMismatch,
    PlatformNotFound,
    OutOfMemory,
};

pub const Feed = struct {
    schema_version: u32,
    /// Monotonic signed feed metadata sequence.
    metadata_version: u64,
    app_id: []const u8,
    version: []const u8,
    min_supported_version: ?[]const u8 = null,
    published_at: ?[]const u8 = null,
    notes_url: ?[]const u8 = null,
    platforms: []const Platform,
};

pub const Platform = struct {
    os: []const u8,
    arch: []const u8,
    url: []const u8,
    sha256: []const u8,
    size: u64,
    /// Ed25519 signature over `signedPayload(feed, platform)` encoded as
    /// `ed25519:<base64-raw-64-byte-signature>`.
    signature: []const u8,
};

pub const UpdateState = struct {
    metadata_version: u64 = 0,
    signed_payload_digest: [Sha256.digest_length]u8 = .{0} ** Sha256.digest_length,
    target_digest: [Sha256.digest_length]u8 = .{0} ** Sha256.digest_length,
};

pub const VerifiedUpdate = struct {
    app_id: []u8,
    version: []u8,
    os: []u8,
    arch: []u8,
    url: []u8,
    sha256: []u8,
    size: u64,
    metadata_version: u64,
    update_state: UpdateState,
    notes_url: ?[]u8 = null,

    pub fn deinit(self: *VerifiedUpdate, alloc: std.mem.Allocator) void {
        alloc.free(self.app_id);
        alloc.free(self.version);
        alloc.free(self.os);
        alloc.free(self.arch);
        alloc.free(self.url);
        alloc.free(self.sha256);
        if (self.notes_url) |notes| alloc.free(notes);
        self.* = undefined;
    }
};

pub const CheckResult = union(enum) {
    /// Authenticated metadata state accepted by this check. Persist it and pass it
    /// on the next check to reject rollback and same-version equivocation.
    no_update: UpdateState,
    update_available: VerifiedUpdate,
    /// The current version is below `min_supported_version`; install this
    /// verified update and persist its state before proceeding.
    required_update: VerifiedUpdate,

    pub fn deinit(self: *CheckResult, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .no_update => {},
            .update_available, .required_update => |*info| info.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub const FetchFn = *const fn (alloc: std.mem.Allocator, url: []const u8, max_bytes: usize) anyerror![]u8;

fn updatesDisabled(config: manifest_mod.UpdateConfig) bool {
    return !nonEmpty(config.provider orelse "") and
        !nonEmpty(config.feed_url orelse "") and
        !nonEmpty(config.public_key orelse "");
}

pub fn validateFeedJson(alloc: std.mem.Allocator, json: []const u8) !void {
    if (json.len > max_manifest_bytes) return error.ManifestTooLarge;
    var parsed = std.json.parseFromSlice(Feed, alloc, json, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    try validateFeed(parsed.value);
}

pub fn validateFeed(feed: Feed) Error!void {
    if (feed.schema_version != 1) return error.InvalidSchemaVersion;
    if (feed.metadata_version == 0) return error.InvalidMetadataVersion;
    if (!isSafeSignedString(feed.app_id)) return error.MissingAppId;
    if (!nonEmpty(feed.version)) return error.MissingVersion;
    const version = try parseVersion(feed.version);
    if (feed.min_supported_version) |min| {
        if (!isSafeSignedString(min)) return error.InvalidVersion;
        const min_version = try parseVersion(min);
        if (compareVersion(min_version, version) == .gt) return error.RollbackWindowInvalid;
    }
    if (feed.notes_url) |url| {
        if (!isStrictHttpsUrl(url)) return error.InvalidUrl;
    }
    if (feed.platforms.len == 0) return error.MissingPlatform;

    for (feed.platforms, 0..) |platform, i| {
        try validatePlatform(platform);
        for (feed.platforms[i + 1 ..]) |other| {
            if (std.mem.eql(u8, platform.os, other.os) and std.mem.eql(u8, platform.arch, other.arch)) {
                return error.DuplicatePlatform;
            }
        }
    }
}

pub fn validatePlatform(platform: Platform) Error!void {
    if (!isSafeSignedString(platform.os) or !isSafeSignedString(platform.arch) or !nonEmpty(platform.url)) return error.MissingPlatformField;
    if (!isStrictHttpsUrl(platform.url)) return error.InvalidUrl;
    if (platform.size == 0 or platform.size > max_artifact_bytes) return error.InvalidSize;
    if (!isLowerHexSha256(platform.sha256)) return error.InvalidHash;
    if (!isEd25519Token(platform.signature)) return error.InvalidSignature;
}

/// Validate the update block from mer.app.zon. All fields omitted means updates
/// are disabled; any partial configuration fails closed.
pub fn validateFeedConfig(config: manifest_mod.UpdateConfig) Error!void {
    const has_provider = nonEmpty(config.provider orelse "");
    const has_feed_url = nonEmpty(config.feed_url orelse "");
    const has_public_key = nonEmpty(config.public_key orelse "");
    if (!has_provider and !has_feed_url and !has_public_key) return;
    if (!has_provider or !has_feed_url or !has_public_key) return error.PartialUpdateConfig;

    const provider = config.provider.?;
    if (!(std.mem.eql(u8, provider, "github-releases") or std.mem.eql(u8, provider, "custom-http"))) {
        return error.InvalidProvider;
    }
    if (!isStrictHttpsUrl(config.feed_url.?)) return error.InvalidUrl;
    _ = decodeEd25519PublicKey(config.public_key.?) catch return error.InvalidPublicKey;
}

pub fn checkForUpdate(
    alloc: std.mem.Allocator,
    config: manifest_mod.UpdateConfig,
    app_id: []const u8,
    current_version: []const u8,
    target_os: []const u8,
    target_arch: []const u8,
    state: UpdateState,
    fetch: FetchFn,
) !CheckResult {
    try validateFeedConfig(config);
    if (updatesDisabled(config)) return .{ .no_update = state };
    const feed_url = config.feed_url orelse return error.PartialUpdateConfig;
    const body = try fetch(alloc, feed_url, max_manifest_bytes);
    defer alloc.free(body);
    return try checkForUpdateJson(alloc, config, app_id, current_version, target_os, target_arch, state, body);
}

pub fn checkForUpdateJson(
    alloc: std.mem.Allocator,
    config: manifest_mod.UpdateConfig,
    app_id: []const u8,
    current_version: []const u8,
    target_os: []const u8,
    target_arch: []const u8,
    state: UpdateState,
    json: []const u8,
) !CheckResult {
    if (json.len > max_manifest_bytes) return error.ManifestTooLarge;
    try validateFeedConfig(config);
    if (updatesDisabled(config)) return .{ .no_update = state };
    const public_key = config.public_key orelse return error.PartialUpdateConfig;

    var parsed = std.json.parseFromSlice(Feed, alloc, json, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    const feed = parsed.value;
    try validateFeed(feed);
    if (!std.mem.eql(u8, feed.app_id, app_id)) return error.AppIdMismatch;

    const platform = findPlatform(feed, target_os, target_arch) orelse return error.PlatformNotFound;
    const digest = try verifyPlatformSignature(alloc, public_key, feed, platform);
    const target_digest = try updateTargetDigest(alloc, target_os, target_arch);
    if (state.metadata_version != 0 and
        !std.mem.eql(u8, &target_digest, &state.target_digest)) return error.UpdateStateTargetMismatch;
    if (feed.metadata_version < state.metadata_version) return error.StaleUpdateMetadata;
    const next_state: UpdateState = .{
        .metadata_version = feed.metadata_version,
        .signed_payload_digest = digest,
        .target_digest = target_digest,
    };
    if (feed.metadata_version == state.metadata_version and
        !std.mem.eql(u8, &digest, &state.signed_payload_digest)) return error.EquivocatingUpdateMetadata;

    const current = try parseVersion(current_version);
    const next = try parseVersion(feed.version);
    if (feed.min_supported_version) |min| {
        const min_version = try parseVersion(min);
        if (compareVersion(current, min_version) == .lt) {
            return .{ .required_update = try copyVerifiedUpdate(alloc, feed, platform, next_state) };
        }
    }
    if (compareVersion(next, current) != .gt) return .{ .no_update = next_state };
    return .{ .update_available = try copyVerifiedUpdate(alloc, feed, platform, next_state) };
}

pub fn verifyArtifactBytes(platform: Platform, artifact: []const u8) Error!void {
    if (artifact.len > max_artifact_bytes) return error.ArtifactTooLarge;
    if (artifact.len != platform.size) return error.ArtifactHashMismatch;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(artifact, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, platform.sha256)) return error.ArtifactHashMismatch;
}

pub fn verifyPlatformSignature(alloc: std.mem.Allocator, public_key_token: []const u8, feed: Feed, platform: Platform) ![Sha256.digest_length]u8 {
    const pk = decodeEd25519PublicKey(public_key_token) catch return error.InvalidPublicKey;
    const sig = decodeEd25519Signature(platform.signature) catch return error.InvalidSignature;
    const payload = try signedPayload(alloc, feed, platform);
    defer alloc.free(payload);
    sig.verifyStrict(payload, pk) catch return error.InvalidSignature;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload, &digest, .{});
    return digest;
}

fn updateTargetDigest(alloc: std.mem.Allocator, os: []const u8, arch: []const u8) ![Sha256.digest_length]u8 {
    const target = try std.fmt.allocPrint(alloc, "merjs-update-target-v1\n{d}:{s}\n{d}:{s}\n", .{ os.len, os, arch.len, arch });
    defer alloc.free(target);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(target, &digest, .{});
    return digest;
}

pub fn signedPayload(alloc: std.mem.Allocator, feed: Feed, platform: Platform) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "merjs-update-v1\n");
    try appendSignedField(alloc, &out, "schema_version", "1");
    var metadata_buf: [32]u8 = undefined;
    const metadata_version = try std.fmt.bufPrint(&metadata_buf, "{d}", .{feed.metadata_version});
    try appendSignedField(alloc, &out, "metadata_version", metadata_version);
    try appendSignedField(alloc, &out, "app_id", feed.app_id);
    try appendSignedField(alloc, &out, "version", feed.version);
    try appendSignedField(alloc, &out, "min_supported_version", feed.min_supported_version orelse "-");
    try appendSignedField(alloc, &out, "notes_url", feed.notes_url orelse "-");
    try appendSignedField(alloc, &out, "published_at", feed.published_at orelse "-");
    try appendSignedField(alloc, &out, "os", platform.os);
    try appendSignedField(alloc, &out, "arch", platform.arch);
    try appendSignedField(alloc, &out, "url", platform.url);
    try appendSignedField(alloc, &out, "sha256", platform.sha256);
    var size_buf: [32]u8 = undefined;
    const size = try std.fmt.bufPrint(&size_buf, "{d}", .{platform.size});
    try appendSignedField(alloc, &out, "size", size);
    return out.toOwnedSlice(alloc);
}

fn appendSignedField(alloc: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    if (!isSafeSignedString(name) or !isSafeSignedString(value)) return error.InvalidSignature;
    try out.appendSlice(alloc, name);
    try out.append(alloc, ':');
    var len_buf: [32]u8 = undefined;
    const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{value.len});
    try out.appendSlice(alloc, len_str);
    try out.append(alloc, ':');
    try out.appendSlice(alloc, value);
    try out.append(alloc, '\n');
}

fn copyVerifiedUpdate(alloc: std.mem.Allocator, feed: Feed, platform: Platform, update_state: UpdateState) !VerifiedUpdate {
    var out: VerifiedUpdate = .{
        .app_id = try alloc.dupe(u8, feed.app_id),
        .metadata_version = feed.metadata_version,
        .update_state = update_state,
        .version = &.{},
        .os = &.{},
        .arch = &.{},
        .url = &.{},
        .sha256 = &.{},
        .size = platform.size,
        .notes_url = null,
    };
    errdefer alloc.free(out.app_id);
    out.version = try alloc.dupe(u8, feed.version);
    errdefer alloc.free(out.version);
    out.os = try alloc.dupe(u8, platform.os);
    errdefer alloc.free(out.os);
    out.arch = try alloc.dupe(u8, platform.arch);
    errdefer alloc.free(out.arch);
    out.url = try alloc.dupe(u8, platform.url);
    errdefer alloc.free(out.url);
    out.sha256 = try alloc.dupe(u8, platform.sha256);
    errdefer alloc.free(out.sha256);
    if (feed.notes_url) |url| {
        out.notes_url = try alloc.dupe(u8, url);
        errdefer alloc.free(out.notes_url.?);
    }
    return out;
}

fn findPlatform(feed: Feed, os: []const u8, arch: []const u8) ?Platform {
    for (feed.platforms) |platform| {
        if (std.mem.eql(u8, platform.os, os) and std.mem.eql(u8, platform.arch, arch)) return platform;
    }
    return null;
}

fn decodeEd25519PublicKey(token: []const u8) !Ed25519.PublicKey {
    var bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    try decodeTokenExact(token, &bytes);
    return Ed25519.PublicKey.fromBytes(bytes) catch error.InvalidPublicKey;
}

fn decodeEd25519Signature(token: []const u8) !Ed25519.Signature {
    var bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    try decodeTokenExact(token, &bytes);
    return Ed25519.Signature.fromBytes(bytes);
}

fn decodeTokenExact(token: []const u8, out: []u8) !void {
    const prefix = "ed25519:";
    if (!std.mem.startsWith(u8, token, prefix)) return error.InvalidSignature;
    const encoded = token[prefix.len..];
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidSignature;
    if (decoded_len != out.len) return error.InvalidSignature;
    _ = std.base64.standard.Decoder.decode(out, encoded) catch return error.InvalidSignature;
}

fn nonEmpty(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len > 0;
}

fn isSafeSignedString(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (c < 0x21 or c > 0x7e) return false;
    }
    return true;
}

fn isForbiddenUrlByte(c: u8) bool {
    return c <= 0x20 or c == 0x7f or c == '\\';
}

fn isValidPort(port: []const u8) bool {
    if (port.len == 0 or port.len > 5) return false;
    for (port) |c| if (!std.ascii.isDigit(c)) return false;
    const value = std.fmt.parseInt(u16, port, 10) catch return false;
    return value > 0;
}

pub fn isStrictHttpsUrl(url: []const u8) bool {
    if (url.len == 0) return false;
    for (url) |c| if (isForbiddenUrlByte(c)) return false;

    const scheme_end = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    if (!std.ascii.eqlIgnoreCase(url[0..scheme_end], "https")) return false;
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
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return false;

    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
        if (close == 1) return false;
        const rest = authority[close + 1 ..];
        return rest.len == 0 or (rest[0] == ':' and isValidPort(rest[1..]));
    }

    const colon = std.mem.indexOfScalar(u8, authority, ':');
    const host = if (colon) |c| authority[0..c] else authority;
    if (host.len == 0) return false;
    if (std.mem.indexOfScalar(u8, host, '.') == null and !std.ascii.eqlIgnoreCase(host, "localhost")) return false;
    if (colon) |c| {
        if (!isValidPort(authority[c + 1 ..])) return false;
    }
    return true;
}

fn isLowerHexSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

fn isEd25519Token(value: []const u8) bool {
    const prefix = "ed25519:";
    if (!std.mem.startsWith(u8, value, prefix) or value.len == prefix.len) return false;
    for (value[prefix.len..]) |c| {
        if (isForbiddenUrlByte(c)) return false;
    }
    return true;
}

const Version = [3]u32;
const VersionOrder = enum { lt, eq, gt };

pub fn parseVersion(value: []const u8) Error!Version {
    if (value.len == 0) return error.InvalidVersion;
    var out: Version = .{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, value, '.');
    var count: usize = 0;
    while (it.next()) |part| {
        if (count == out.len or part.len == 0) return error.InvalidVersion;
        if (part.len > 1 and part[0] == '0') return error.InvalidVersion;
        for (part) |c| if (!std.ascii.isDigit(c)) return error.InvalidVersion;
        out[count] = std.fmt.parseInt(u32, part, 10) catch return error.InvalidVersion;
        count += 1;
    }
    if (count == 0) return error.InvalidVersion;
    return out;
}

fn compareVersion(a: Version, b: Version) VersionOrder {
    for (a, b) |av, bv| {
        if (av < bv) return .lt;
        if (av > bv) return .gt;
    }
    return .eq;
}

const TestSigned = struct {
    pub const seed: [32]u8 = .{0} ** 32;
    pub const sha = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    pub fn keyPair() Ed25519.KeyPair {
        return Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
    }
    pub fn publicKeyToken(alloc: std.mem.Allocator) ![]u8 {
        const pk = keyPair().public_key.toBytes();
        const encoded_len = std.base64.standard.Encoder.calcSize(pk.len);
        const out = try alloc.alloc(u8, "ed25519:".len + encoded_len);
        @memcpy(out[0.."ed25519:".len], "ed25519:");
        _ = std.base64.standard.Encoder.encode(out["ed25519:".len..], &pk);
        return out;
    }
    pub fn signToken(alloc: std.mem.Allocator, feed: Feed, platform: Platform) ![]u8 {
        const payload = try signedPayload(alloc, feed, platform);
        defer alloc.free(payload);
        const sig = try Ed25519.KeyPair.sign(keyPair(), payload, null);
        const sig_bytes = sig.toBytes();
        const encoded_len = std.base64.standard.Encoder.calcSize(sig_bytes.len);
        const out = try alloc.alloc(u8, "ed25519:".len + encoded_len);
        @memcpy(out[0.."ed25519:".len], "ed25519:");
        _ = std.base64.standard.Encoder.encode(out["ed25519:".len..], &sig_bytes);
        return out;
    }
    pub fn feedJson(alloc: std.mem.Allocator, metadata_version: u64, version: []const u8, signature: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc,
            \\{{
            \\  "schema_version": 1,
            \\  "metadata_version": {d},
            \\  "app_id": "com.example.app",
            \\  "version": "{s}",
            \\  "min_supported_version": "1.0.0",
            \\  "notes_url": "https://example.com/notes",
            \\  "platforms": [{{
            \\    "os": "macos",
            \\    "arch": "aarch64",
            \\    "url": "https://example.com/app.zip",
            \\    "sha256": "{s}",
            \\    "size": 5,
            \\    "signature": "{s}"
            \\  }}]
            \\}}
        , .{ metadata_version, version, sha, signature });
    }
};

var test_fetch_body: []const u8 = "";

fn testFetch(alloc: std.mem.Allocator, url: []const u8, max_bytes: usize) anyerror![]u8 {
    try std.testing.expectEqualStrings("https://example.com/update.json", url);
    try std.testing.expect(test_fetch_body.len <= max_bytes);
    return try alloc.dupe(u8, test_fetch_body);
}

fn signedTestPlatform(signature: []const u8) Platform {
    return .{
        .os = "macos",
        .arch = "aarch64",
        .url = "https://example.com/app.zip",
        .sha256 = TestSigned.sha,
        .size = 5,
        .signature = signature,
    };
}

fn signedTestFeed(signature: []const u8, metadata_version: u64, version: []const u8) Feed {
    return .{
        .schema_version = 1,
        .metadata_version = metadata_version,
        .app_id = "com.example.app",
        .version = version,
        .min_supported_version = "1.0.0",
        .notes_url = "https://example.com/notes",
        .platforms = &[_]Platform{signedTestPlatform(signature)},
    };
}

test "validateFeedJson accepts structurally valid signed update feed" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, 1, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, 1, "1.2.3", sig);
    defer std.testing.allocator.free(json);
    try validateFeedJson(std.testing.allocator, json);
}

test "checkForUpdateJson treats disabled updates as no_update without panic" {
    var result = try checkForUpdateJson(std.testing.allocator, .{}, "com.example.app", "1.0.0", "macos", "aarch64", .{}, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), result.no_update.metadata_version);
}

test "checkForUpdateJson accepts repeated canonical metadata despite JSON differences" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, 1, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, 1, "1.2.3", sig);
    defer std.testing.allocator.free(json);
    const reordered_json = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"platforms":[{{"signature":"{s}","size":5,"sha256":"{s}","url":"https://example.com/app.zip","arch":"aarch64","os":"macos"}}],"notes_url":"https://example.com/notes","min_supported_version":"1.0.0","version":"1.2.3","app_id":"com.example.app","metadata_version":1,"schema_version":1}}
    , .{ sig, TestSigned.sha });
    defer std.testing.allocator.free(reordered_json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    var first = try checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", .{}, json);
    const state = first.update_available.update_state;
    defer first.deinit(std.testing.allocator);
    var second = try checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", state, reordered_json);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(second == .update_available);
}

test "checkForUpdateJson rejects update state from a different target" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, 1, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, 1, "1.2.3", sig);
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    const state: UpdateState = .{
        .metadata_version = 1,
        .signed_payload_digest = try verifyPlatformSignature(std.testing.allocator, public_key, unsigned_feed, signedTestPlatform(sig)),
        .target_digest = try updateTargetDigest(std.testing.allocator, "windows", "x86_64"),
    };
    try std.testing.expectError(error.UpdateStateTargetMismatch, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", state, json));
}

test "checkForUpdate uses fetcher abstraction with size cap" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, 1, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, 1, "1.2.3", sig);
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    test_fetch_body = json;
    var result = try checkForUpdate(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", .{}, testFetch);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .update_available);
}

test "checkForUpdateJson returns state for no_update" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, 1, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, 1, "1.2.3", sig);
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    var result = try checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.3", "macos", "aarch64", .{}, json);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), result.no_update.metadata_version);
}

test "checkForUpdateJson rejects wrong signature app platform and rollback window" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, 1, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, 1, "1.2.4", sig);
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    try std.testing.expectError(error.InvalidSignature, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", .{}, json));

    const good_json = try TestSigned.feedJson(std.testing.allocator, 1, "1.2.3", sig);
    defer std.testing.allocator.free(good_json);
    try std.testing.expectError(error.AppIdMismatch, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.other.app", "1.2.2", "macos", "aarch64", .{}, good_json));
    try std.testing.expectError(error.PlatformNotFound, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "windows", "x86_64", .{}, good_json));
    var required = try checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "0.9.0", "macos", "aarch64", .{}, good_json);
    defer required.deinit(std.testing.allocator);
    try std.testing.expect(required == .required_update);
    try std.testing.expectEqual(@as(u64, 1), required.required_update.update_state.metadata_version);
}

test "checkForUpdateJson rejects tampered min_supported_version" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, 1, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "schema_version": 1,
        \\  "metadata_version": 1,
        \\  "app_id": "com.example.app",
        \\  "version": "1.2.3",
        \\  "min_supported_version": "1.1.0",
        \\  "platforms": [{{
        \\    "os": "macos",
        \\    "arch": "aarch64",
        \\    "url": "https://example.com/app.zip",
        \\    "sha256": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        \\    "size": 5,
        \\    "signature": "{s}"
        \\  }}]
        \\}}
    , .{sig});
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    try std.testing.expectError(error.InvalidSignature, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", .{}, json));
}

test "checkForUpdateJson rejects tampered version that would suppress updates" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, 1, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, 1, "1.0.0", sig);
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    try std.testing.expectError(error.InvalidSignature, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.0.0", "macos", "aarch64", .{}, json));
}

test "checkForUpdateJson rejects tampered notes_url returned in metadata" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const unsigned_feed = signedTestFeed(unsigned_platform.signature, 1, "1.2.3");
    const sig = try TestSigned.signToken(std.testing.allocator, unsigned_feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "schema_version": 1,
        \\  "metadata_version": 1,
        \\  "app_id": "com.example.app",
        \\  "version": "1.2.3",
        \\  "min_supported_version": "1.0.0",
        \\  "notes_url": "https://evil.example/notes",
        \\  "platforms": [{{
        \\    "os": "macos",
        \\    "arch": "aarch64",
        \\    "url": "https://example.com/app.zip",
        \\    "sha256": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        \\    "size": 5,
        \\    "signature": "{s}"
        \\  }}]
        \\}}
    , .{sig});
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    try std.testing.expectError(error.InvalidSignature, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", .{}, json));
}

test "checkForUpdateJson treats empty-string config as disabled" {
    var result = try checkForUpdateJson(std.testing.allocator, .{ .provider = "", .feed_url = "", .public_key = "" }, "com.example.app", "1.0.0", "macos", "aarch64", .{}, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), result.no_update.metadata_version);
}

test "checkForUpdateJson rejects equal-version equivocation" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const first_feed = signedTestFeed(unsigned_platform.signature, 1, "1.2.3");
    const first_sig = try TestSigned.signToken(std.testing.allocator, first_feed, unsigned_platform);
    defer std.testing.allocator.free(first_sig);
    const first_json = try TestSigned.feedJson(std.testing.allocator, 1, "1.2.3", first_sig);
    defer std.testing.allocator.free(first_json);
    const conflicting_feed = signedTestFeed(unsigned_platform.signature, 1, "1.2.4");
    const conflicting_sig = try TestSigned.signToken(std.testing.allocator, conflicting_feed, unsigned_platform);
    defer std.testing.allocator.free(conflicting_sig);
    const conflicting_json = try TestSigned.feedJson(std.testing.allocator, 1, "1.2.4", conflicting_sig);
    defer std.testing.allocator.free(conflicting_json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    var first = try checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", .{}, first_json);
    const state = first.update_available.update_state;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectError(error.EquivocatingUpdateMetadata, checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", state, conflicting_json));
}

test "checkForUpdateJson accepts higher metadata_version" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const feed = signedTestFeed(unsigned_platform.signature, 2, "1.2.4");
    const sig = try TestSigned.signToken(std.testing.allocator, feed, unsigned_platform);
    defer std.testing.allocator.free(sig);
    const json = try TestSigned.feedJson(std.testing.allocator, 2, "1.2.4", sig);
    defer std.testing.allocator.free(json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    var result = try checkForUpdateJson(std.testing.allocator, .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }, "com.example.app", "1.2.2", "macos", "aarch64", .{
        .metadata_version = 1,
        .target_digest = try updateTargetDigest(std.testing.allocator, "macos", "aarch64"),
    }, json);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), result.update_available.update_state.metadata_version);
}

test "checkForUpdateJson authenticates lower metadata before rejecting it as stale" {
    const unsigned_platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    const old_feed = signedTestFeed(unsigned_platform.signature, 1, "1.2.3");
    const old_sig = try TestSigned.signToken(std.testing.allocator, old_feed, unsigned_platform);
    defer std.testing.allocator.free(old_sig);
    const old_json = try TestSigned.feedJson(std.testing.allocator, 1, "1.2.3", old_sig);
    defer std.testing.allocator.free(old_json);
    const mandatory_feed = signedTestFeed(unsigned_platform.signature, 2, "1.2.3");
    const mandatory_sig = try TestSigned.signToken(std.testing.allocator, mandatory_feed, unsigned_platform);
    defer std.testing.allocator.free(mandatory_sig);
    const mandatory_json = try TestSigned.feedJson(std.testing.allocator, 2, "1.2.3", mandatory_sig);
    defer std.testing.allocator.free(mandatory_json);
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    const config: manifest_mod.UpdateConfig = .{
        .provider = "custom-http",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    };
    var mandatory = try checkForUpdateJson(std.testing.allocator, config, "com.example.app", "0.9.0", "macos", "aarch64", .{}, mandatory_json);
    defer mandatory.deinit(std.testing.allocator);
    try std.testing.expect(mandatory == .required_update);
    const state = mandatory.required_update.update_state;
    try std.testing.expectError(error.StaleUpdateMetadata, checkForUpdateJson(std.testing.allocator, config, "com.example.app", "0.9.0", "macos", "aarch64", state, old_json));

    const invalid_old_json = try TestSigned.feedJson(std.testing.allocator, 1, "1.2.4", old_sig);
    defer std.testing.allocator.free(invalid_old_json);
    try std.testing.expectError(error.InvalidSignature, checkForUpdateJson(std.testing.allocator, config, "com.example.app", "0.9.0", "macos", "aarch64", state, invalid_old_json));
}

test "verifyArtifactBytes enforces size and sha256" {
    const platform = signedTestPlatform("ed25519:placeholderplaceholderplaceholderplaceholderplaceholderplaceholder");
    try verifyArtifactBytes(platform, "hello");
    try std.testing.expectError(error.ArtifactHashMismatch, verifyArtifactBytes(platform, "hellO"));
    try std.testing.expectError(error.ArtifactHashMismatch, verifyArtifactBytes(platform, "hello!"));
}

test "validateFeedJson rejects http artifact URLs" {
    const bad =
        \\{
        \\  "schema_version": 1,
        \\  "metadata_version": 1,
        \\  "app_id": "com.example.app",
        \\  "version": "1.2.3",
        \\  "platforms": [{
        \\    "os": "macos",
        \\    "arch": "aarch64",
        \\    "url": "http://example.com/app.zip",
        \\    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\    "size": 12345,
        \\    "signature": "ed25519:abcdef"
        \\  }]
        \\}
    ;
    try std.testing.expectError(error.InvalidUrl, validateFeedJson(std.testing.allocator, bad));
}

test "validateFeed rejects invalid hash signature duplicate platform and rollback window" {
    const platform: Platform = .{
        .os = "macos",
        .arch = "aarch64",
        .url = "https://example.com/app.zip",
        .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .size = 1,
        .signature = "ed25519:sig",
    };
    var bad_hash = platform;
    bad_hash.sha256 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    try std.testing.expectError(error.InvalidHash, validatePlatform(bad_hash));

    var bad_sig = platform;
    bad_sig.signature = "not-ed25519:sig";
    try std.testing.expectError(error.InvalidSignature, validatePlatform(bad_sig));

    var bad_size = platform;
    bad_size.size = 0;
    try std.testing.expectError(error.InvalidSize, validatePlatform(bad_size));

    const dupes = [_]Platform{ platform, platform };
    try std.testing.expectError(error.DuplicatePlatform, validateFeed(.{
        .schema_version = 1,
        .metadata_version = 1,
        .app_id = "com.example.app",
        .version = "1.2.3",
        .platforms = &dupes,
    }));

    const one = [_]Platform{platform};
    try std.testing.expectError(error.RollbackWindowInvalid, validateFeed(.{
        .schema_version = 1,
        .metadata_version = 1,
        .app_id = "com.example.app",
        .version = "1.2.3",
        .min_supported_version = "2.0.0",
        .platforms = &one,
    }));
}

test "validateFeedConfig accepts disabled and complete update config" {
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    try validateFeedConfig(.{});
    try validateFeedConfig(.{
        .provider = "github-releases",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    });
    try validateFeedConfig(.{
        .provider = "custom-http",
        .feed_url = "https://updates.example.com/feed.json",
        .public_key = public_key,
    });
}

test "validateFeedConfig rejects partial invalid provider url and public key" {
    const public_key = try TestSigned.publicKeyToken(std.testing.allocator);
    defer std.testing.allocator.free(public_key);
    try std.testing.expectError(error.PartialUpdateConfig, validateFeedConfig(.{ .provider = "github-releases" }));
    try std.testing.expectError(error.PartialUpdateConfig, validateFeedConfig(.{ .feed_url = "https://example.com/update.json" }));
    try std.testing.expectError(error.PartialUpdateConfig, validateFeedConfig(.{ .public_key = public_key }));
    try std.testing.expectError(error.PartialUpdateConfig, validateFeedConfig(.{
        .provider = "github-releases",
        .feed_url = "https://example.com/update.json",
    }));
    try std.testing.expectError(error.InvalidProvider, validateFeedConfig(.{
        .provider = "s3",
        .feed_url = "https://example.com/update.json",
        .public_key = public_key,
    }));
    try std.testing.expectError(error.InvalidUrl, validateFeedConfig(.{
        .provider = "github-releases",
        .feed_url = "http://example.com/update.json",
        .public_key = public_key,
    }));
    try std.testing.expectError(error.InvalidPublicKey, validateFeedConfig(.{
        .provider = "github-releases",
        .feed_url = "https://example.com/update.json",
        .public_key = "ed25519:",
    }));
}

test "parseVersion accepts numeric versions and rejects ambiguous strings" {
    try std.testing.expectEqual(@as(Version, .{ 1, 0, 0 }), try parseVersion("1"));
    try std.testing.expectEqual(@as(Version, .{ 1, 2, 0 }), try parseVersion("1.2"));
    try std.testing.expectEqual(@as(Version, .{ 1, 2, 3 }), try parseVersion("1.2.3"));
    try std.testing.expectError(error.InvalidVersion, parseVersion("1.2.3.4"));
    try std.testing.expectError(error.InvalidVersion, parseVersion("1.02.3"));
    try std.testing.expectError(error.InvalidVersion, parseVersion("1.2.3-beta"));
}

test "isStrictHttpsUrl rejects malformed URLs" {
    try std.testing.expect(isStrictHttpsUrl("https://example.com/a.zip"));
    try std.testing.expect(!isStrictHttpsUrl("https:///a.zip"));
    try std.testing.expect(!isStrictHttpsUrl("https://example.com\\evil"));
    try std.testing.expect(!isStrictHttpsUrl("https://example.com/evil path"));
    try std.testing.expect(!isStrictHttpsUrl("https://user@example.com/a.zip"));
    try std.testing.expect(!isStrictHttpsUrl("https://example.com:notaport/a.zip"));
    try std.testing.expect(!isStrictHttpsUrl("https://example.com:0/a.zip"));
    try std.testing.expect(isStrictHttpsUrl("https://example.com:443/a.zip"));
}
