-- merjs-auth: OAuth 2.0 accounts and PKCE state

-- ── OAuth accounts ─────────────────────────────────────────────────────────
-- One row per (provider, account) pair. A single user can have multiple
-- providers linked (e.g. Google + GitHub).

CREATE TABLE IF NOT EXISTS mauth_oauth_accounts (
    id                        TEXT        PRIMARY KEY,
    user_id                   TEXT        NOT NULL REFERENCES mauth_users(id) ON DELETE CASCADE,
    provider_id               TEXT        NOT NULL,   -- e.g. "google", "github"
    account_id                TEXT        NOT NULL,   -- provider's own user/sub identifier
    access_token              TEXT,
    refresh_token             TEXT,
    access_token_expires_at   TIMESTAMPTZ,
    refresh_token_expires_at  TIMESTAMPTZ,
    scope                     TEXT,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (provider_id, account_id)
);

CREATE INDEX IF NOT EXISTS mauth_oauth_accounts_user_idx ON mauth_oauth_accounts (user_id);

-- ── OAuth state (PKCE / anti-CSRF) ─────────────────────────────────────────
-- Short-lived rows created at authorization-redirect time. Deleted after
-- the callback is consumed. Expired rows are safe to prune with a cron job.

CREATE TABLE IF NOT EXISTS mauth_oauth_states (
    id            TEXT        PRIMARY KEY,
    state         TEXT        NOT NULL,   -- random value included in the OAuth redirect
    provider_id   TEXT        NOT NULL,
    code_verifier TEXT,                   -- PKCE S256 verifier (null for legacy flows)
    redirect_uri  TEXT,
    expires_at    TIMESTAMPTZ NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS mauth_oauth_states_state_idx   ON mauth_oauth_states (state);
CREATE        INDEX IF NOT EXISTS mauth_oauth_states_expires_idx ON mauth_oauth_states (expires_at);
