# merjs-auth

## Browser request security

Browser-facing JSON auth endpoints require `Content-Type: application/json` (an optional parameter such as `charset=utf-8` is allowed). Requests using browser-simple media types such as `text/plain`, `application/x-www-form-urlencoded`, or `multipart/form-data` are rejected before their body is processed.

Every state-changing or session-issuing JSON POST must also include exactly one `Origin` header. Its parsed HTTP(S) origin must match the origin of `Config.base_url` or one of the exact origins in `Config.trusted_origins`; missing, malformed, duplicated, and prefix-matching origins are rejected. Configure additional browser frontends without paths:

```zig
const config = merjs_auth.Config{
    .base_url = "https://app.example.com",
    .trusted_origins = &.{"https://admin.example.com"},
    // .secret and .db omitted
};
```

Clients should send JSON requests as follows:

```http
POST /auth/sign-in/email HTTP/1.1
Content-Type: application/json
Origin: https://app.example.com

{"email":"user@example.com","password":"..."}
```

The session-bound CSRF cookie remains required by handlers that validate it (for example, password changes). Origin and JSON checks are additional defenses and do not replace that token.

Magic-link callback redirects accept only an absolute URL whose parsed origin exactly matches `base_url`, or a local path beginning with one `/`. The validated redirect is percent-encoded into the emailed `/auth/magic-link/verify` URL and decoded once by that endpoint, preserving query strings without allowing parameter injection. Scheme-relative paths, backslashes, control bytes, nested percent-encoded redirect forms, user-info URLs, and lookalike/prefix hosts fall back to `/`.

## OAuth callback and email security

OAuth initiation sets a 10-minute `mauth_oauth_state` correlation cookie (configurable with `Config.oauth_state_cookie`). It is HttpOnly, SameSite=Lax, and uses `Config.secure_cookies`. The callback requires that cookie to match both the query state and the atomically consumed database state, then clears it on every response. Consequently, a copied callback URL cannot create a login session in another browser. Keep `secure_cookies = true` in production.

OAuth email linking is fail closed. Google/OIDC userinfo must contain `email_verified: true`; GitHub always reads `/user/emails` and accepts only a verified entry (preferring the verified primary); Discord requires its explicit `verified: true` assertion. A custom provider must set `Provider.verified_email_mapping` to the userinfo field names carrying the account ID, email, and boolean verified assertion. Merely returning an `email` field is not trusted and cannot attach an OAuth account to an existing user.

```zig
const custom = merjs_auth.oauth.providers.Provider{
    // endpoints, credentials, scopes, and id omitted
    .verified_email_mapping = .{
        .account_id = "subject",
        .email = "email_address",
        .email_verified = "email_address_verified",
    },
};
```

### Microsoft status

Microsoft OAuth is deliberately disabled because Microsoft Graph `/me` does not assert `email_verified`, and merjs-auth does not yet cryptographically validate OIDC ID tokens. The `microsoft` constructors and `EmailVerification.microsoft` enum value remain for source compatibility, but any such provider configuration is rejected by `validateConfig` and `handle` with `error.UnsupportedProvider` before OAuth state is created or consumed. Supported built-ins are Google, GitHub, and Discord. Do not expose Microsoft OAuth routes until cryptographic OIDC claims verification is implemented.

## SAML status

SAML is deliberately disabled because XMLDSig verification is not implemented. The compatibility `Config.saml_providers` field remains so existing configuration types still compile, but a non-empty value is rejected by `validateConfig` and `handle` with `error.UnsupportedSaml`. Requests under `/auth/saml/` return `501 Not Implemented`; initiation and metadata are not advertised as usable flows. Do not configure an IdP until signature verification support is released.
