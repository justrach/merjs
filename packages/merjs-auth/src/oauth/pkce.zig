//! PKCE (Proof Key for Code Exchange) helpers for OAuth 2.0.
//!
//! RFC 7636 §4 specifies the S256 method:
//!   code_verifier  = 32 random bytes → base64url-no-pad (43 chars)
//!   code_challenge = BASE64URL(SHA-256(ASCII(code_verifier)))
//!
//! All functions that allocate return owned slices; the caller must free
//! them (or use an arena).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const base64url = std.base64.url_safe_no_pad;

// ── Code verifier ──────────────────────────────────────────────────────────

/// Generate a PKCE code verifier: 32 random bytes → base64url-no-pad.
/// Produces exactly 43 characters (ceil(32 * 4 / 3)).
/// Store this in the DB during the OAuth flow; never send it to the
/// authorization server.
pub fn generateCodeVerifier(alloc: Allocator) ![]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const encoded_len = base64url.Encoder.calcSize(raw.len);
    const buf = try alloc.alloc(u8, encoded_len);
    _ = base64url.Encoder.encode(buf, &raw);
    return buf;
}

// ── Code challenge ─────────────────────────────────────────────────────────

/// Derive the S256 code challenge from a verifier:
///   BASE64URL(SHA-256(verifier))
/// Send this as `code_challenge` in the authorization request.
/// The caller owns the returned slice.
pub fn codeChallenge(alloc: Allocator, verifier: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(verifier, &digest, .{});
    const encoded_len = base64url.Encoder.calcSize(digest.len);
    const buf = try alloc.alloc(u8, encoded_len);
    _ = base64url.Encoder.encode(buf, &digest);
    return buf;
}

// ── State nonce ────────────────────────────────────────────────────────────

/// Generate a state nonce for CSRF protection: 16 random bytes → 32-char
/// lowercase hex string.
/// Include this as the `state` parameter in the authorization redirect, store
/// it in the DB, and verify it matches in the callback.
pub fn generateState(alloc: Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    return alloc.dupe(u8, &hex);
}

// ── Verification ───────────────────────────────────────────────────────────

/// Verify that `verifier` produces `expected_challenge` under S256.
/// Computes the challenge from `verifier` and compares in constant time.
pub fn verifyChallenge(verifier: []const u8, expected_challenge: []const u8) bool {
    var digest: [32]u8 = undefined;
    Sha256.hash(verifier, &digest, .{});

    // Encode the computed challenge into a stack buffer.
    const encoded_len = base64url.Encoder.calcSize(digest.len);
    // Maximum base64url encoding of 32 bytes is 43 chars — fits on stack.
    var computed_buf: [64]u8 = undefined;
    if (encoded_len > computed_buf.len) return false;
    const computed = base64url.Encoder.encode(computed_buf[0..encoded_len], &digest);

    if (computed.len != expected_challenge.len) return false;

    // Constant-time comparison.
    var diff: u8 = 0;
    for (computed, expected_challenge) |a, b| diff |= a ^ b;
    return diff == 0;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "generateCodeVerifier produces 43-char base64url string" {
    const alloc = std.testing.allocator;
    const v = try generateCodeVerifier(alloc);
    defer alloc.free(v);
    try std.testing.expectEqual(@as(usize, 43), v.len);
    // All chars must be base64url alphabet: A-Z a-z 0-9 - _
    for (v) |c| {
        const valid = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_';
        try std.testing.expect(valid);
    }
}

test "codeChallenge has correct length" {
    const alloc = std.testing.allocator;
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const challenge = try codeChallenge(alloc, verifier);
    defer alloc.free(challenge);
    // SHA-256 is 32 bytes → base64url-no-pad → 43 chars
    try std.testing.expectEqual(@as(usize, 43), challenge.len);
}

test "verifyChallenge accepts matching pair" {
    const alloc = std.testing.allocator;
    const v = try generateCodeVerifier(alloc);
    defer alloc.free(v);
    const ch = try codeChallenge(alloc, v);
    defer alloc.free(ch);
    try std.testing.expect(verifyChallenge(v, ch));
}

test "verifyChallenge rejects wrong verifier" {
    const alloc = std.testing.allocator;
    const v1 = try generateCodeVerifier(alloc);
    defer alloc.free(v1);
    const v2 = try generateCodeVerifier(alloc);
    defer alloc.free(v2);
    const ch = try codeChallenge(alloc, v1);
    defer alloc.free(ch);
    try std.testing.expect(!verifyChallenge(v2, ch));
}

test "generateState produces 32-char lowercase hex" {
    const alloc = std.testing.allocator;
    const s = try generateState(alloc);
    defer alloc.free(s);
    try std.testing.expectEqual(@as(usize, 32), s.len);
    for (s) |c| {
        const valid = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(valid);
    }
}

test "RFC 7636 Appendix B known-good S256 challenge" {
    // Test vector from RFC 7636 Appendix B:
    //   verifier  = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    //   challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    const alloc = std.testing.allocator;
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
    const ch = try codeChallenge(alloc, verifier);
    defer alloc.free(ch);
    try std.testing.expectEqualStrings(expected, ch);
}
