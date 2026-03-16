-- merjs-auth: multi-tenant organizations, members, and invitations

-- ── Organizations ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS mauth_organizations (
    id         TEXT        PRIMARY KEY,
    name       TEXT        NOT NULL,
    slug       TEXT        NOT NULL,
    logo       TEXT,
    metadata   JSONB       NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS mauth_orgs_slug_idx ON mauth_organizations (slug);

-- ── Organization members ───────────────────────────────────────────────────
-- role is free-text so applications can define their own RBAC model
-- (e.g. 'owner', 'admin', 'member', 'viewer').

CREATE TABLE IF NOT EXISTS mauth_org_members (
    id         TEXT        PRIMARY KEY,
    org_id     TEXT        NOT NULL REFERENCES mauth_organizations(id) ON DELETE CASCADE,
    user_id    TEXT        NOT NULL REFERENCES mauth_users(id)         ON DELETE CASCADE,
    role       TEXT        NOT NULL DEFAULT 'member',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (org_id, user_id)
);

CREATE INDEX IF NOT EXISTS mauth_org_members_org_idx  ON mauth_org_members (org_id);
CREATE INDEX IF NOT EXISTS mauth_org_members_user_idx ON mauth_org_members (user_id);

-- ── Organization invitations ───────────────────────────────────────────────
-- Invitee may or may not already have an account; matched on email.

CREATE TABLE IF NOT EXISTS mauth_org_invitations (
    id          TEXT        PRIMARY KEY,
    org_id      TEXT        NOT NULL REFERENCES mauth_organizations(id) ON DELETE CASCADE,
    email       TEXT        NOT NULL,
    role        TEXT        NOT NULL DEFAULT 'member',
    invited_by  TEXT        NOT NULL REFERENCES mauth_users(id) ON DELETE CASCADE,
    status      TEXT        NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'accepted', 'rejected', 'expired')),
    expires_at  TIMESTAMPTZ NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS mauth_org_invitations_org_idx    ON mauth_org_invitations (org_id);
CREATE INDEX IF NOT EXISTS mauth_org_invitations_email_idx  ON mauth_org_invitations (email);
CREATE INDEX IF NOT EXISTS mauth_org_invitations_status_idx ON mauth_org_invitations (status);
