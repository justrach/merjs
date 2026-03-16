-- merjs-auth: SAML 2.0 providers and in-flight AuthnRequest sessions

-- ── SAML Identity Providers ────────────────────────────────────────────────
-- One row per configured IdP. Can be scoped to an organization (enterprise
-- SSO) or global (self-hosted deployments).

CREATE TABLE IF NOT EXISTS mauth_saml_providers (
    id               TEXT        PRIMARY KEY,
    org_id           TEXT        REFERENCES mauth_organizations(id) ON DELETE CASCADE,  -- nullable: global IdP
    name             TEXT        NOT NULL,
    provider_slug    TEXT        NOT NULL,    -- URL-safe identifier, e.g. "acme-okta"
    idp_entity_id    TEXT        NOT NULL,    -- EntityID from IdP metadata
    idp_sso_url      TEXT        NOT NULL,    -- SingleSignOnService Location
    idp_slo_url      TEXT,                    -- SingleLogoutService Location (optional)
    idp_cert_pem     TEXT        NOT NULL,    -- PEM-encoded X.509 signing cert from IdP
    sp_entity_id     TEXT        NOT NULL,    -- Our EntityID (SP metadata URL)
    name_id_format   TEXT        NOT NULL DEFAULT 'emailAddress',
    -- attribute_map: JSON object mapping IdP attribute names → our field names.
    -- Default maps the SAML "email" attribute to our email field.
    attribute_map    JSONB       NOT NULL DEFAULT '{"email":"email"}',
    verify_signature BOOLEAN     NOT NULL DEFAULT true,
    enabled          BOOLEAN     NOT NULL DEFAULT true,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS mauth_saml_providers_slug_idx   ON mauth_saml_providers (provider_slug);
CREATE        INDEX IF NOT EXISTS mauth_saml_providers_org_idx    ON mauth_saml_providers (org_id);

-- ── SAML in-flight AuthnRequests ───────────────────────────────────────────
-- Created when we redirect the user to the IdP, consumed on the ACS
-- callback. Stores the request_id for replay-attack prevention.

CREATE TABLE IF NOT EXISTS mauth_saml_sessions (
    id           TEXT        PRIMARY KEY,
    provider_id  TEXT        NOT NULL REFERENCES mauth_saml_providers(id) ON DELETE CASCADE,
    -- request_id is the <samlp:AuthnRequest ID="..."> value we generated.
    -- Uniqueness here prevents the same assertion being replayed.
    request_id   TEXT        NOT NULL,
    relay_state  TEXT,        -- opaque value we sent and expect back from IdP
    expires_at   TIMESTAMPTZ NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS mauth_saml_sessions_request_id_idx ON mauth_saml_sessions (request_id);
CREATE        INDEX IF NOT EXISTS mauth_saml_sessions_provider_idx   ON mauth_saml_sessions (provider_id);
CREATE        INDEX IF NOT EXISTS mauth_saml_sessions_expires_idx    ON mauth_saml_sessions (expires_at);
