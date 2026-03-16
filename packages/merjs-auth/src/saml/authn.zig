//! SAML 2.0 SP — AuthnRequest builder for HTTP-Redirect binding.
//!
//! SP-initiated SSO flow:
//!   1. generateRequestId   — unique "_" + 32 hex chars
//!   2. buildAuthnRequest   — XML AuthnRequest string
//!   3. encodeForRedirect   — raw-deflate + base64 + URL-encode
//!   4. buildRedirectUrl    — assemble full IdP redirect URL

const std = @import("std");
const Allocator = std.mem.Allocator;
const saml_schema = @import("schema.zig");

// ── Request ID ───────────────────────────────────────────────────────────

/// Generate a unique AuthnRequest ID: "_" followed by 32 hex chars (16 random bytes).
/// Per the SAML spec the ID must begin with a letter or underscore (NCName rule).
pub fn generateRequestId(alloc: Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    const buf = try alloc.alloc(u8, 33); // '_' + 32 hex chars
    buf[0] = '_';
    @memcpy(buf[1..], &hex);
    return buf;
}

// ── AuthnRequest XML builder ──────────────────────────────────────────────

/// Build the AuthnRequest XML string.
/// Caller owns the returned slice.
pub fn buildAuthnRequest(
    alloc: Allocator,
    provider: saml_schema.Provider,
    sp_entity_id: []const u8,
    acs_url: []const u8,
    request_id: []const u8,
    issue_instant: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(alloc, saml_schema.AUTHN_REQUEST_TEMPLATE, .{
        request_id,
        issue_instant,
        provider.idp_sso_url,
        acs_url,
        sp_entity_id,
        provider.name_id_format,
    });
}

// ── HTTP-Redirect encoding ────────────────────────────────────────────────

/// Encode AuthnRequest XML for HTTP-Redirect binding.
///
/// Steps per SAML 2.0 Binding spec §3.4.4:
///   1. Raw-deflate (RFC 1951, no headers — Container.raw)
///   2. Base64-encode the compressed bytes
///   3. URL-encode the base64 string
///
/// Returns the URL-encoded SAMLRequest parameter value. Caller owns the result.
pub fn encodeForRedirect(alloc: Allocator, xml: []const u8) ![]u8 {
    // Step 1: raw deflate (RFC 1951, no headers).
    // Use Compress.Simple — the full Compress pipeline is still in development.
    // Simple uses Huffman encoding of the raw bytes as a single block.
    var deflated: std.Io.Writer.Allocating = .init(alloc);
    defer deflated.deinit();

    // Compress.Simple.buffer holds the input bytes; wp is the fill level.
    // Maximum AuthnRequest is well under 4KB; use a stack buffer.
    var input_buf: [8192]u8 = undefined;
    if (xml.len > input_buf.len) return error.InputTooLarge;
    @memcpy(input_buf[0..xml.len], xml);

    var compressor = try std.compress.flate.Compress.Simple.init(
        &deflated.writer,
        input_buf[0..xml.len],
        .raw,
        .huffman,
    );
    compressor.wp = xml.len;
    try compressor.finish();

    const compressed = deflated.written();

    // Step 2: base64-encode.
    const b64_len = std.base64.standard.Encoder.calcSize(compressed.len);
    const b64_buf = try alloc.alloc(u8, b64_len);
    defer alloc.free(b64_buf);
    _ = std.base64.standard.Encoder.encode(b64_buf, compressed);

    // Step 3: URL-encode the base64 string.
    return urlEncode(alloc, b64_buf);
}

/// URL-encode a string (percent-encode all non-unreserved characters).
/// RFC 3986 unreserved: ALPHA / DIGIT / "-" / "." / "_" / "~"
fn urlEncode(alloc: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    for (input) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~') {
            try out.append(alloc, ch);
        } else {
            var hex_buf: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&hex_buf, "%{X:0>2}", .{ch}) catch unreachable;
            try out.appendSlice(alloc, &hex_buf);
        }
    }
    return out.toOwnedSlice(alloc);
}

// ── Redirect URL builder ──────────────────────────────────────────────────

/// Build the full redirect URL to the IdP.
/// Format: {idp_sso_url}?SAMLRequest={encoded}[&RelayState={relay_state}]
/// Caller owns the returned slice.
pub fn buildRedirectUrl(
    alloc: Allocator,
    idp_sso_url: []const u8,
    saml_request: []const u8,
    relay_state: ?[]const u8,
) ![]u8 {
    if (relay_state) |rs| {
        const rs_enc = try urlEncode(alloc, rs);
        defer alloc.free(rs_enc);
        return std.fmt.allocPrint(
            alloc,
            "{s}?SAMLRequest={s}&RelayState={s}",
            .{ idp_sso_url, saml_request, rs_enc },
        );
    }
    return std.fmt.allocPrint(
        alloc,
        "{s}?SAMLRequest={s}",
        .{ idp_sso_url, saml_request },
    );
}

// ── ISO 8601 timestamp formatter ──────────────────────────────────────────

/// Format a Unix timestamp as an ISO 8601 UTC string for IssueInstant.
/// Output format: "2024-01-15T10:30:00Z"
/// Caller owns the returned slice.
pub fn formatIsoTimestamp(alloc: Allocator, unix_seconds: i64) ![]u8 {
    // Convert Unix seconds to calendar fields via std epoch utilities.
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, unix_seconds)) };
    const epoch_day = epoch_secs.getEpochDay();
    const day_secs = epoch_secs.getDaySeconds();

    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "generateRequestId format" {
    const alloc = std.testing.allocator;
    const id = try generateRequestId(alloc);
    defer alloc.free(id);
    try std.testing.expectEqual(@as(usize, 33), id.len);
    try std.testing.expectEqual('_', id[0]);
    for (id[1..]) |ch| try std.testing.expect(std.ascii.isHex(ch));
}

test "urlEncode encodes plus and slash" {
    const alloc = std.testing.allocator;
    const enc = try urlEncode(alloc, "a+b/c=d");
    defer alloc.free(enc);
    // '+' -> %2B, '/' -> %2F, '=' -> %3D
    try std.testing.expect(std.mem.indexOf(u8, enc, "%2B") != null);
    try std.testing.expect(std.mem.indexOf(u8, enc, "%2F") != null);
    try std.testing.expect(std.mem.indexOf(u8, enc, "%3D") != null);
}

test "formatIsoTimestamp produces correct UTC string" {
    const alloc = std.testing.allocator;
    // Unix 0 = 1970-01-01T00:00:00Z
    const s = try formatIsoTimestamp(alloc, 0);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", s);
}

test "buildRedirectUrl without relay state" {
    const alloc = std.testing.allocator;
    const url = try buildRedirectUrl(alloc, "https://idp.example.com/sso", "REQ123", null);
    defer alloc.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, "https://idp.example.com/sso?SAMLRequest=REQ123"));
}

test "buildRedirectUrl with relay state" {
    const alloc = std.testing.allocator;
    const url = try buildRedirectUrl(alloc, "https://idp.example.com/sso", "REQ", "/dashboard");
    defer alloc.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "RelayState=") != null);
}
