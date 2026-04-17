//! SAML 2.0 SP — Endpoint orchestration for merjs-auth.
//!
//! Handles the four SAML endpoints:
//!   GET  /auth/saml/:provider_id/initiate  — SP-initiated SSO redirect
//!   POST /auth/saml/:provider_id/callback  — ACS (Assertion Consumer Service)
//!   GET  /auth/saml/:provider_id/metadata  — SP metadata XML for IdP registration
//!   POST /auth/saml/:provider_id/slo       — Single Logout (v1: clear local session)

const std = @import("std");
const Allocator = std.mem.Allocator;

const saml_schema = @import("schema.zig");
const xml = @import("xml.zig");
const authn = @import("authn.zig");
const db = @import("../db/root.zig");
const crypto = @import("../crypto.zig");
const session = @import("../session.zig");
const mer = @import("mer");
const AuthContext = @import("../auth.zig").AuthContext;

/// Get current Unix timestamp in seconds (Zig 0.16 compatible).
fn currentUnixSeconds() i64 {
    var ts: std.c.time.timespec = undefined;
    _ = std.c.clock_gettime(std.c.time.CLOCK.REALTIME, &ts);
    return ts.sec;
}

// ── SAML session TTL ──────────────────────────────────────────────────────

/// In-flight SAML session expires after 5 minutes.
const SAML_SESSION_TTL_S: i64 = 5 * 60;

// ── Initiate: SP-initiated SSO ────────────────────────────────────────────

/// GET /auth/saml/:provider_id/initiate
///
/// 1. Find provider config by ID
/// 2. Generate request_id and relay_state
/// 3. Store in-flight record in mauth_saml_sessions (replay protection)
/// 4. Build and sign AuthnRequest
/// 5. Redirect user to IdP SSO URL
pub fn initiate(ctx: *AuthContext, provider_id: []const u8) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    const provider = findProvider(ctx, provider_id) orelse {
        return mer.badRequest("unknown SAML provider");
    };

    // Resolve SP entity ID.
    const base_url = mer.env("BASE_URL") orelse "http://localhost:3000";
    const sp_entity_id = if (provider.sp_entity_id) |eid| eid else blk: {
        break :blk try std.fmt.allocPrint(alloc, "{s}/auth/saml/{s}/metadata", .{ base_url, provider.id });
    };
    const acs_url = try std.fmt.allocPrint(alloc, "{s}/auth/saml/{s}/callback", .{ base_url, provider.id });
    const now_unix = currentUnixSeconds();

    // Generate IDs.
    const request_id = try authn.generateRequestId(alloc);
    const relay_state = try crypto.generateToken(alloc);

    // Persist the in-flight SAML session for replay-attack prevention.
    const session_id = try crypto.generateUuid(alloc);
    const expires_at = now_unix + SAML_SESSION_TTL_S;

    // INSERT INTO mauth_saml_sessions (id, provider_id, request_id, relay_state, expires_at, created_at)
    const insert_sql =
        \\INSERT INTO mauth_saml_sessions (id, provider_id, request_id, relay_state, expires_at, created_at)
        \\VALUES ($1, $2, $3, $4, TO_TIMESTAMP($5), NOW())
    ;
    const expires_at_str = try std.fmt.allocPrint(alloc, "{d}", .{expires_at});
    const insert_result = try ctx.db.query(alloc, insert_sql, &.{
        .{ .text = session_id },
        .{ .text = provider.id },
        .{ .text = request_id },
        .{ .text = relay_state },
        .{ .text = expires_at_str },
    });
    _ = insert_result;

    // Build AuthnRequest XML.
    const now_iso = try authn.formatIsoTimestamp(alloc, now_unix);
    const authn_xml = try authn.buildAuthnRequest(alloc, provider, sp_entity_id, acs_url, request_id, now_iso);

    // Encode for HTTP-Redirect binding.
    const saml_request = try authn.encodeForRedirect(alloc, authn_xml);

    // Build final redirect URL.
    const redirect_url = try authn.buildRedirectUrl(alloc, provider.idp_sso_url, saml_request, relay_state);

    return mer.redirect(redirect_url, .found);
}

// ── Callback: ACS endpoint ────────────────────────────────────────────────

/// POST /auth/saml/:provider_id/callback
///
/// ACS (Assertion Consumer Service) — processes the SAMLResponse from the IdP.
///
/// 1. Parse SAMLResponse from POST body
/// 2. Base64-decode the response
/// 3. Parse and validate the assertion
/// 4. Optionally verify the assertion signature
/// 5. Validate InResponseTo against mauth_saml_sessions
/// 6. Delete the consumed saml_session (prevent replay)
/// 7. Find or create user by email
/// 8. Create session, set cookie, redirect to /
pub fn callback(ctx: *AuthContext, provider_id: []const u8) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    const provider = findProvider(ctx, provider_id) orelse {
        return mer.badRequest("unknown SAML provider");
    };

    // Read SAMLResponse from form body.
    const saml_response_b64_raw = mer.formParam(ctx.req.body, "SAMLResponse") orelse {
        return mer.badRequest("missing SAMLResponse");
    };

    // URL-decode the base64 string (IdPs may percent-encode it even in POST body).
    const saml_response_b64 = try urlDecode(alloc, saml_response_b64_raw);

    // Base64-decode to raw XML.
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(saml_response_b64) catch {
        return mer.badRequest("invalid SAMLResponse encoding");
    };
    const xml_bytes = try alloc.alloc(u8, decoded_size);
    std.base64.standard.Decoder.decode(xml_bytes, saml_response_b64) catch {
        return mer.badRequest("invalid SAMLResponse base64");
    };
    const now_unix = currentUnixSeconds();
    // Resolve SP entity ID for audience validation.
    const base_url = mer.env("BASE_URL") orelse "http://localhost:3000";
    const sp_entity_id = if (provider.sp_entity_id) |eid| eid else blk: {
        break :blk try std.fmt.allocPrint(alloc, "{s}/auth/saml/{s}/metadata", .{ base_url, provider.id });
    };


    // Parse and validate the assertion (structure, conditions, audience, status).
    const assertion = xml.parseSamlResponse(xml_bytes, sp_entity_id, now_unix, alloc) catch |err| {
        // Log internally; return generic error to client.
        std.log.err("saml: parseSamlResponse failed: {}", .{err});
        return mer.internalError("authentication failed");
    };

    // Signature verification.
    if (provider.verify_signature) {
        if (provider.verify_signature_fn) |verify_fn| {
            // Extract the SignedInfo and Signature from the raw XML for verification.
            // The caller-provided function handles RSA-SHA256 verification.
            // We pass the raw XML bytes as the message (the caller must canonicalize).
            const sig_valid = extractAndVerifySignature(xml_bytes, provider.idp_cert_pem, verify_fn) catch |err| {
                std.log.err("saml: signature extraction failed: {}", .{err});
                return mer.internalError("authentication failed");
            };
            if (!sig_valid) {
                std.log.warn("saml: signature verification failed for provider {s}", .{provider.id});
                return mer.internalError("authentication failed");
            }
        } else {
            // verify_signature = true but no function provided — this is a configuration error.
            std.log.err("saml: verify_signature=true but verify_signature_fn is null for provider {s}", .{provider.id});
            return mer.internalError("SAML configuration error: verify_signature_fn not set. " ++
                "Set Provider.verify_signature_fn to an RSA-SHA256 verification function, " ++
                "or set Provider.verify_signature = false (not recommended for production).");
        }
    }

    // Validate InResponseTo: must match a non-expired mauth_saml_sessions row.
    const in_response_to = assertion.in_response_to orelse {
        std.log.warn("saml: assertion missing InResponseTo (possible IdP-initiated SSO, not supported)", .{});
        return mer.internalError("authentication failed");
    };

    const session_sql =
        \\SELECT id FROM mauth_saml_sessions
        \\WHERE request_id = $1
        \\  AND provider_id = $2
        \\  AND expires_at > NOW()
        \\LIMIT 1
    ;
    const session_result = try ctx.db.query(alloc, session_sql, &.{
        .{ .text = in_response_to },
        .{ .text = provider.id },
    });
    if (session_result.rows.len == 0) {
        std.log.warn("saml: no valid saml_session found for request_id={s}", .{in_response_to});
        return mer.internalError("authentication failed");
    }
    const saml_session_id = db.rowText(session_result.rows[0], 0) orelse "";

    // Delete the consumed session to prevent replay attacks.
    const delete_sql = "DELETE FROM mauth_saml_sessions WHERE id = $1";
    _ = try ctx.db.query(alloc, delete_sql, &.{.{ .text = saml_session_id }});

    // Resolve email: try assertion.email first, then fall back to name_id.
    const email = assertion.email orelse blk: {
        // Only use name_id as email if it looks like an email address.
        if (std.mem.indexOfScalar(u8, assertion.name_id, '@') != null) {
            break :blk assertion.name_id;
        }
        std.log.err("saml: no email attribute and name_id is not an email for provider {s}", .{provider.id});
        return mer.internalError("authentication failed");
    };

    // Derive display name from assertion attributes.
    const display_name = assertion.display_name orelse blk: {
        if (assertion.given_name != null and assertion.family_name != null) {
            break :blk try std.fmt.allocPrint(alloc, "{s} {s}", .{ assertion.given_name.?, assertion.family_name.? });
        }
        break :blk email;
    };

    // Find or create user by email.
    const user_id = try findOrCreateUser(ctx, alloc, email, display_name);

    // Create session.
    const sess_token = try crypto.generateToken(alloc);
    const sess_id = try crypto.generateUuid(alloc);
    const sess_ttl = session.DEFAULT_TTL_S;
    const sess_expires = now_unix + @as(i64, sess_ttl);
    const sess_expires_str = try std.fmt.allocPrint(alloc, "{d}", .{sess_expires});

    const insert_session_sql =
        \\INSERT INTO mauth_sessions (id, user_id, token, expires_at, created_at, updated_at)
        \\VALUES ($1, $2, $3, TO_TIMESTAMP($4), NOW(), NOW())
    ;
    _ = try ctx.db.query(alloc, insert_session_sql, &.{
        .{ .text = sess_id },
        .{ .text = user_id },
        .{ .text = sess_token },
        .{ .text = sess_expires_str },
    });

    // Sign the session cookie value.
    const secret = mer.env("MULTICLAW_SESSION_SECRET") orelse {
        std.log.err("saml: MULTICLAW_SESSION_SECRET not set", .{});
        return mer.internalError("server configuration error");
    };
    const cookie_val = try session.cookieValue(alloc, sess_id, secret);
    const cookie = mer.SetCookie{
        .name = session.COOKIE_SESSION,
        .value = cookie_val,
        .path = "/",
        .max_age = sess_ttl,
        .http_only = true,
        .secure = std.mem.startsWith(u8, base_url, "https"),
        .same_site = .lax,
    };

    // Redirect to / (or relay_state if present and safe).
    const relay_state = mer.formParam(ctx.req.body, "RelayState");
    const redirect_path = blk: {
        if (relay_state) |rs| {
            // Only allow relative paths as relay state targets (prevent open redirect).
            if (rs.len > 0 and rs[0] == '/') break :blk rs;
        }
        break :blk "/";
    };

    const resp = mer.redirect(redirect_path, .see_other);
    return mer.withCookies(resp, &.{cookie});
}

// ── Metadata: SP metadata XML ─────────────────────────────────────────────

/// GET /auth/saml/:provider_id/metadata
///
/// Returns SP metadata XML for registration with the IdP.
pub fn metadata(ctx: *AuthContext, provider_id: []const u8) anyerror!mer.Response {
    const alloc = ctx.req.allocator;

    const provider = findProvider(ctx, provider_id) orelse {
        return mer.badRequest("unknown SAML provider");
    };

    const base_url = mer.env("BASE_URL") orelse "http://localhost:3000";
    const sp_entity_id = if (provider.sp_entity_id) |eid| eid else blk: {
        break :blk try std.fmt.allocPrint(alloc, "{s}/auth/saml/{s}/metadata", .{ base_url, provider.id });
    };
    const acs_url = try std.fmt.allocPrint(alloc, "{s}/auth/saml/{s}/callback", .{ base_url, provider.id });
    const slo_url = try std.fmt.allocPrint(alloc, "{s}/auth/saml/{s}/slo", .{ base_url, provider.id });

    // Replace template placeholders.
    const template = saml_schema.SP_METADATA_TEMPLATE;

    // Simple three-pass substitution for the three placeholders.
    const tmp1 = try replacePlaceholder(alloc, template, "{entity_id}", sp_entity_id);
    defer alloc.free(tmp1);
    const tmp2 = try replacePlaceholder(alloc, tmp1, "{acs_url}", acs_url);
    defer alloc.free(tmp2);
    const xml_str = try replacePlaceholder(alloc, tmp2, "{slo_url}", slo_url);

    // Return with application/xml content type.
    // ContentType.text is the closest available enum value in this build;
    // we use it here since there is no .xml variant in the current ContentType enum.
    return mer.Response{
        .status = .ok,
        .content_type = .text,
        .body = xml_str,
    };
}

// ── SLO: Single Logout ────────────────────────────────────────────────────

/// POST /auth/saml/:provider_id/slo
///
/// Single Logout handler — v1 implementation.
/// Clears the local session and redirects to /.
///
/// TODO: Full SLO protocol (sending LogoutRequest to IdP) is not yet implemented.
pub fn slo(ctx: *AuthContext, provider_id: []const u8) anyerror!mer.Response {
    _ = provider_id; // reserved for future full SLO protocol

    // Clear the session cookie by setting Max-Age=0.
    const clear_cookie = mer.SetCookie{
        .name = session.COOKIE_SESSION,
        .value = "",
        .path = "/",
        .max_age = 0,
        .http_only = true,
        .secure = false,
        .same_site = .lax,
    };

    // Delete the session from the database if present.
    const cookie_val = ctx.req.cookie(session.COOKIE_SESSION);
    if (cookie_val) |cv| {
        const secret = mer.env("MULTICLAW_SESSION_SECRET") orelse "";
        if (session.verifyCookie(cv, secret)) |sess_id| {
            const alloc = ctx.req.allocator;
            const del_sql = "DELETE FROM mauth_sessions WHERE id = $1";
            _ = ctx.db.query(alloc, del_sql, &.{.{ .text = sess_id }}) catch {};
        }
    }

    const resp = mer.redirect("/", .see_other);
    return mer.withCookies(resp, &.{clear_cookie});
}

// ── Private helpers ───────────────────────────────────────────────────────

/// Find a provider by ID from the AuthContext configuration.
fn findProvider(ctx: *AuthContext, provider_id: []const u8) ?saml_schema.Provider {
    for (ctx.config.saml_providers) |p| {
        if (std.mem.eql(u8, p.id, provider_id)) return p;
    }
    return null;
}

/// Find an existing user by email or create a new one.
/// Returns the user ID (owned by alloc).
fn findOrCreateUser(ctx: *AuthContext, alloc: Allocator, email: []const u8, display_name: []const u8) ![]const u8 {
    // Try to find existing user.
    const find_sql = "SELECT id FROM mauth_users WHERE email = $1 LIMIT 1";
    const find_result = try ctx.db.query(alloc, find_sql, &.{.{ .text = email }});
    if (find_result.rows.len > 0) {
        const uid = db.rowText(find_result.rows[0], 0) orelse return error.DatabaseError;
        return try alloc.dupe(u8, uid);
    }

    // Create new user.
    const user_id = try crypto.generateUuid(alloc);
    const insert_sql =
        \\INSERT INTO mauth_users (id, name, email, email_verified, created_at, updated_at)
        \\VALUES ($1, $2, $3, true, NOW(), NOW())
    ;
    _ = try ctx.db.query(alloc, insert_sql, &.{
        .{ .text = user_id },
        .{ .text = display_name },
        .{ .text = email },
    });
    return user_id;
}

/// Simple string placeholder replacement. Returns a newly allocated string.
/// Replaces the first occurrence of `placeholder` in `template` with `value`.
fn replacePlaceholder(alloc: Allocator, template: []const u8, placeholder: []const u8, value: []const u8) ![]u8 {
    const idx = std.mem.indexOf(u8, template, placeholder) orelse {
        return alloc.dupe(u8, template);
    };
    const before = template[0..idx];
    const after = template[idx + placeholder.len ..];
    return std.mem.concat(alloc, u8, &.{ before, value, after });
}

/// URL-decode a percent-encoded string (e.g. from form body).
/// Only decodes %XX sequences; '+' is NOT treated as space (SAML spec).
fn urlDecode(alloc: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                try out.append(alloc, input[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                try out.append(alloc, input[i]);
                i += 1;
                continue;
            };
            try out.append(alloc, @intCast(hi * 16 + lo));
            i += 3;
        } else {
            try out.append(alloc, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Extract signature bytes and verify against the IdP cert.
/// Searches the raw XML for <ds:SignatureValue> and <ds:SignedInfo>.
/// Returns false if signature is not found or verification fails.
/// Returns error if XML extraction itself fails in an unexpected way.
fn extractAndVerifySignature(
    raw_xml: []const u8,
    cert_pem: []const u8,
    verify_fn: *const fn (message: []const u8, signature: []const u8, cert_pem: []const u8) bool,
) !bool {
    // Extract <SignedInfo>...</SignedInfo> (the canonicalized message).
    const si_open = std.mem.indexOf(u8, raw_xml, "<ds:SignedInfo") orelse
        std.mem.indexOf(u8, raw_xml, "<SignedInfo") orelse return false;
    const si_tag_end = std.mem.indexOfPos(u8, raw_xml, si_open, "</ds:SignedInfo>") orelse
        std.mem.indexOfPos(u8, raw_xml, si_open, "</SignedInfo>") orelse return false;
    const si_end = blk: {
        if (std.mem.indexOfPos(u8, raw_xml, si_tag_end, "</ds:SignedInfo>")) |pos| {
            break :blk pos + "</ds:SignedInfo>".len;
        }
        if (std.mem.indexOfPos(u8, raw_xml, si_tag_end, "</SignedInfo>")) |pos| {
            break :blk pos + "</SignedInfo>".len;
        }
        return false;
    };
    const signed_info = raw_xml[si_open..si_end];

    // Extract <SignatureValue>...</SignatureValue> (base64-encoded signature).
    const sv_open_tag = std.mem.indexOf(u8, raw_xml, "<ds:SignatureValue>") orelse
        std.mem.indexOf(u8, raw_xml, "<SignatureValue>") orelse return false;
    const sv_content_start = (std.mem.indexOfPos(u8, raw_xml, sv_open_tag, ">") orelse return false) + 1;
    const sv_close = std.mem.indexOfPos(u8, raw_xml, sv_content_start, "</") orelse return false;
    const sig_b64 = std.mem.trim(u8, raw_xml[sv_content_start..sv_close], " \t\n\r");

    // Base64-decode the signature value — use a stack buffer for reasonable signature sizes.
    var sig_buf: [1024]u8 = undefined;
    const sig_size = std.base64.standard.Decoder.calcSizeForSlice(sig_b64) catch return false;
    if (sig_size > sig_buf.len) return false;
    std.base64.standard.Decoder.decode(sig_buf[0..sig_size], sig_b64) catch return false;
    const signature = sig_buf[0..sig_size];

    return verify_fn(signed_info, signature, cert_pem);
}
