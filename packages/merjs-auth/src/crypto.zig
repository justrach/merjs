//! Cryptographic primitives for merjs-auth.
//!
//! All functions that allocate return owned slices; caller must free them
//! (or use an arena so they are freed in bulk).

const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const base64url = std.base64.url_safe_no_pad;

// ── Token generation ───────────────────────────────────────────────────────

/// Generate a cryptographically-random 43-character base64url-no-pad token.
/// 32 bytes of entropy → 43 chars after base64url encoding (ceil(32*4/3)).
/// Suitable for opaque session tokens, CSRF tokens, etc.
pub fn generateToken(alloc: Allocator) ![]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const encoded_len = base64url.Encoder.calcSize(raw.len);
    const buf = try alloc.alloc(u8, encoded_len);
    _ = base64url.Encoder.encode(buf, &raw);
    return buf;
}

/// Generate a UUID v4 string (36 bytes including hyphens), e.g.
/// "550e8400-e29b-41d4-a716-446655440000".
/// 16 random bytes with the version/variant bits set per RFC 4122 §4.4.
pub fn generateUuid(alloc: Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    // Set version 4: top nibble of byte[6] = 0x4
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Set variant bits: top two bits of byte[8] = 0b10
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const buf = try alloc.alloc(u8, 36);
    _ = std.fmt.bufPrint(
        buf,
        "{s}-{s}-{s}-{s}-{s}",
        .{
            std.fmt.bytesToHex(bytes[0..4], .lower),
            std.fmt.bytesToHex(bytes[4..6], .lower),
            std.fmt.bytesToHex(bytes[6..8], .lower),
            std.fmt.bytesToHex(bytes[8..10], .lower),
            std.fmt.bytesToHex(bytes[10..16], .lower),
        },
    ) catch unreachable; // 36 bytes is always enough
    return buf;
}

// ── HMAC ───────────────────────────────────────────────────────────────────

/// Compute HMAC-SHA256(message, key). Returns the 32-byte MAC.
pub fn hmacSign(message: []const u8, key: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    HmacSha256.create(&out, message, key);
    return out;
}

// ── Constant-time comparison ───────────────────────────────────────────────

/// Constant-time equality for variable-length byte slices.
///
/// IMPORTANT: This is constant-time with respect to the *data* when lengths
/// are equal. When lengths differ it returns false immediately — do not use
/// this to compare secret values where the length itself is secret.
/// For auth tokens of fixed known format (e.g. 64-hex chars) the lengths
/// will always be equal for valid inputs, so this is safe.
pub fn timingSafeEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

// ── Signed tokens ──────────────────────────────────────────────────────────

/// Produce a signed token: `"{payload}.{hex(HMAC-SHA256(payload, secret))}"`.
/// The caller owns the returned slice.
pub fn signedToken(alloc: Allocator, payload: []const u8, secret: []const u8) ![]u8 {
    const mac = hmacSign(payload, secret);
    const hex = std.fmt.bytesToHex(mac, .lower);
    // Format: payload + '.' + 64-char hex MAC
    const out = try alloc.alloc(u8, payload.len + 1 + 64);
    @memcpy(out[0..payload.len], payload);
    out[payload.len] = '.';
    @memcpy(out[payload.len + 1 ..], &hex);
    return out;
}

/// Verify a signed token produced by `signedToken`.
/// Returns the payload slice (a sub-slice of `token`) if the MAC is valid,
/// or null if the token is malformed or the MAC does not match.
/// No allocations.
pub fn verifySignedToken(token: []const u8, secret: []const u8) ?[]const u8 {
    // Find the last '.' — the MAC lives after it.
    const dot = std.mem.lastIndexOfScalar(u8, token, '.') orelse return null;
    const payload = token[0..dot];
    const given_hex = token[dot + 1 ..];
    if (given_hex.len != 64) return null;

    const expected_mac = hmacSign(payload, secret);
    const expected_hex = std.fmt.bytesToHex(expected_mac, .lower);

    if (!timingSafeEq(given_hex, &expected_hex)) return null;
    return payload;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "generateToken produces 43-char base64url string" {
    const alloc = std.testing.allocator;
    const tok = try generateToken(alloc);
    defer alloc.free(tok);
    try std.testing.expectEqual(@as(usize, 43), tok.len);
}

test "generateUuid produces valid UUID v4 format" {
    const alloc = std.testing.allocator;
    const uuid = try generateUuid(alloc);
    defer alloc.free(uuid);
    try std.testing.expectEqual(@as(usize, 36), uuid.len);
    try std.testing.expectEqual('-', uuid[8]);
    try std.testing.expectEqual('-', uuid[13]);
    try std.testing.expectEqual('-', uuid[18]);
    try std.testing.expectEqual('-', uuid[23]);
    // Version nibble must be '4'
    try std.testing.expectEqual('4', uuid[14]);
    // Variant nibble must be '8', '9', 'a', or 'b'
    const variant = uuid[19];
    try std.testing.expect(variant == '8' or variant == '9' or variant == 'a' or variant == 'b');
}

test "signedToken / verifySignedToken round-trip" {
    const alloc = std.testing.allocator;
    const secret = "super-secret-key";
    const payload = "user-id-1234";
    const tok = try signedToken(alloc, payload, secret);
    defer alloc.free(tok);
    const recovered = verifySignedToken(tok, secret);
    try std.testing.expect(recovered != null);
    try std.testing.expectEqualStrings(payload, recovered.?);
}

test "verifySignedToken rejects tampered payload" {
    const alloc = std.testing.allocator;
    const tok = try signedToken(alloc, "user-id-1234", "secret");
    defer alloc.free(tok);
    // Flip a byte in the payload portion
    var tampered = try alloc.dupe(u8, tok);
    defer alloc.free(tampered);
    tampered[0] ^= 0x01;
    try std.testing.expect(verifySignedToken(tampered, "secret") == null);
}

test "timingSafeEq length mismatch returns false" {
    try std.testing.expect(!timingSafeEq("abc", "abcd"));
}

test "timingSafeEq identical strings returns true" {
    try std.testing.expect(timingSafeEq("hello", "hello"));
}
