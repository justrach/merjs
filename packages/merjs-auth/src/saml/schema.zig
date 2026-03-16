//! SAML 2.0 SP — Configuration and parsed assertion types.
//!
//! These types are shared across all SAML modules. No imports from other
//! merjs-auth modules are needed here; this is pure data.

// ── Provider configuration ────────────────────────────────────────────────

/// A configured SAML 2.0 Identity Provider (IdP) for SP-initiated SSO.
pub const Provider = struct {
    /// Short machine identifier, e.g. "okta-prod", "azure-ad". Used in URLs.
    id: []const u8,
    /// Human-readable display name shown in login UI.
    name: []const u8,
    /// EntityID from IdP metadata — must match what the IdP sends in Issuer.
    idp_entity_id: []const u8,
    /// SingleSignOnService Location URL — where we redirect the user.
    idp_sso_url: []const u8,
    /// SingleLogoutService Location URL (optional).
    idp_slo_url: ?[]const u8 = null,
    /// PEM-encoded X.509 certificate from the IdP for signature verification.
    idp_cert_pem: []const u8,
    /// Our SP EntityID. Defaults to {base_url}/auth/saml/{id}/metadata when null.
    sp_entity_id: ?[]const u8 = null,
    /// NameID format requested in AuthnRequest.
    name_id_format: []const u8 = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress",
    /// Mapping from SAML attribute names to our field names.
    attribute_map: AttributeMap = .{},
    /// Whether to verify the assertion signature. Should be true in production.
    verify_signature: bool = true,
    /// Hook for RSA-SHA256 signature verification.
    ///
    /// Required when verify_signature = true. If null and verify_signature is
    /// true, the callback handler returns a 500 with a clear error message.
    ///
    /// Parameters:
    ///   message    — canonicalized SignedInfo bytes (UTF-8)
    ///   signature  — raw DER-encoded signature bytes (NOT base64)
    ///   cert_pem   — PEM-encoded X.509 certificate
    ///
    /// Returns true if the signature is valid.
    verify_signature_fn: ?*const fn (
        message: []const u8,
        signature: []const u8,
        cert_pem: []const u8,
    ) bool = null,
};

/// Maps IdP SAML attribute names to our semantic field names.
pub const AttributeMap = struct {
    email: []const u8 = "email",
    name: ?[]const u8 = "displayName",
    given_name: ?[]const u8 = "givenName",
    family_name: ?[]const u8 = "sn",
};

// ── Parsed assertion ─────────────────────────────────────────────────────

/// Structured representation of a validated SAML 2.0 assertion.
pub const ParsedAssertion = struct {
    /// NameID value, typically the user's email address.
    name_id: []const u8,
    /// NameID Format URI.
    name_id_format: []const u8,
    /// Email address extracted from the configured attribute.
    email: ?[]const u8,
    /// displayName / full name attribute.
    display_name: ?[]const u8,
    /// givenName / first name attribute.
    given_name: ?[]const u8,
    /// sn / family name attribute.
    family_name: ?[]const u8,
    /// Unix timestamp: when the IdP session expires (SessionNotOnOrAfter).
    session_not_on_or_after: ?i64,
    /// Unix timestamp: Conditions NotBefore.
    not_before: i64,
    /// Unix timestamp: Conditions NotOnOrAfter.
    not_on_or_after: i64,
    /// AudienceRestriction Audience value.
    audience: []const u8,
    /// InResponseTo attribute — matches our request ID.
    in_response_to: ?[]const u8,
    /// Issuer element text.
    issuer: []const u8,
    /// All parsed SAML attributes.
    attributes: []const Attribute,
};

/// A single SAML attribute extracted from an AttributeStatement.
pub const Attribute = struct {
    /// Attribute Name value.
    name: []const u8,
    /// All AttributeValue children as strings.
    values: []const []const u8,
};

// ── XML templates ─────────────────────────────────────────────────────────

/// SP Metadata XML template.
/// Placeholders: {entity_id}, {acs_url}, {slo_url}.
pub const SP_METADATA_TEMPLATE: []const u8 =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<md:EntityDescriptor
    \\    xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata"
    \\    entityID="{entity_id}">
    \\  <md:SPSSODescriptor
    \\      AuthnRequestsSigned="false"
    \\      WantAssertionsSigned="true"
    \\      protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
    \\    <md:AssertionConsumerService
    \\        Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
    \\        Location="{acs_url}"
    \\        index="1"/>
    \\    <md:SingleLogoutService
    \\        Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
    \\        Location="{slo_url}"/>
    \\  </md:SPSSODescriptor>
    \\</md:EntityDescriptor>
;

/// AuthnRequest XML template.
/// Positional format args (std.fmt.allocPrint):
///   {s} ID, {s} IssueInstant, {s} Destination (idp_sso_url),
///   {s} AssertionConsumerServiceURL, {s} sp_entity_id,
///   {s} NameIDPolicy Format.
pub const AUTHN_REQUEST_TEMPLATE: []const u8 =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<samlp:AuthnRequest
    \\    xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol"
    \\    xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion"
    \\    ID="{s}"
    \\    Version="2.0"
    \\    IssueInstant="{s}"
    \\    Destination="{s}"
    \\    AssertionConsumerServiceURL="{s}"
    \\    ProtocolBinding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST">
    \\  <saml:Issuer>{s}</saml:Issuer>
    \\  <samlp:NameIDPolicy
    \\      AllowCreate="true"
    \\      Format="{s}"/>
    \\</samlp:AuthnRequest>
;
