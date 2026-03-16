-- merjs-auth: initial schema
-- Run this once against your Postgres database before starting the app.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── Users ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS mauth_users (
    id           TEXT        PRIMARY KEY,
    name         TEXT        NOT NULL,
    email        TEXT        NOT NULL,
    email_verified BOOLEAN   NOT NULL DEFAULT false,
    image        TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS mauth_users_email_idx ON mauth_users (email);

-- ── Sessions ───────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS mauth_sessions (
    id           TEXT        PRIMARY KEY,
    user_id      TEXT        NOT NULL REFERENCES mauth_users(id) ON DELETE CASCADE,
    token        TEXT        NOT NULL,
    expires_at   TIMESTAMPTZ NOT NULL,
    ip_address   TEXT,
    user_agent   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS mauth_sessions_token_idx ON mauth_sessions (token);
CREATE        INDEX IF NOT EXISTS mauth_sessions_user_idx  ON mauth_sessions (user_id);
CREATE        INDEX IF NOT EXISTS mauth_sessions_expires_idx ON mauth_sessions (expires_at);

-- ── Verification / Reset / Magic-link tokens ───────────────────────────────

CREATE TABLE IF NOT EXISTS mauth_tokens (
    id           TEXT        PRIMARY KEY,
    user_id      TEXT        NOT NULL REFERENCES mauth_users(id) ON DELETE CASCADE,
    token_hash   TEXT        NOT NULL,
    purpose      TEXT        NOT NULL CHECK (purpose IN ('email_verify', 'password_reset', 'magic_link')),
    expires_at   TIMESTAMPTZ NOT NULL,
    used_at      TIMESTAMPTZ,              -- NULL means not yet consumed
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS mauth_tokens_hash_idx    ON mauth_tokens (token_hash);
CREATE        INDEX IF NOT EXISTS mauth_tokens_user_idx    ON mauth_tokens (user_id);
CREATE        INDEX IF NOT EXISTS mauth_tokens_expires_idx ON mauth_tokens (expires_at);

-- ── Rate limits ────────────────────────────────────────────────────────────
-- key is a SHA-256 hex of the raw identifier (email or IP) to avoid storing PII.

CREATE TABLE IF NOT EXISTS mauth_rate_limits (
    key          TEXT        PRIMARY KEY,
    count        INT         NOT NULL DEFAULT 0,
    window_start TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
