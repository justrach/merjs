//! merjs-auth — authentication library for the merjs framework.
//!
//! Feature-parity target: better-auth.
//! Compiles to WASM for deployment on Cloudflare Workers.
//!
//! Public API surface — import what you need:
//!
//!   const auth = @import("merjs-auth");
//!
//!   // Core types
//!   auth.Session, auth.User, auth.SessionWithUser
//!   auth.COOKIE_SESSION, auth.CSRF_COOKIE, auth.DEFAULT_TTL_S
//!
//!   // Sub-modules
//!   auth.crypto      — token gen, UUID, HMAC, signed tokens
//!   auth.password    — Argon2id hash/verify
//!   auth.token       — short-lived verification tokens
//!   auth.session     — session cookie helpers
//!   auth.csrf        — CSRF double-submit protection
//!   auth.email       — email hook interface + template builders
//!   auth.rate_limit  — DB-backed rate limiting
//!   auth.db          — Adapter vtable, Row/Value helpers
//!   auth.migrations  — embedded SQL migrations

// ── Sub-modules (re-exported) ──────────────────────────────────────────────

pub const crypto = @import("crypto.zig");
pub const password = @import("password.zig");
pub const token = @import("token.zig");
pub const session = @import("session.zig");
pub const csrf = @import("csrf.zig");
pub const email = @import("email.zig");
pub const rate_limit = @import("rate_limit.zig");
pub const db = @import("db/root.zig");
pub const migrations = @import("db/migrations.zig");
pub const auth = @import("auth.zig");

// ── Flat re-exports of the most-used symbols ──────────────────────────────

// Session types
pub const Session = session.Session;
pub const User = session.User;
pub const SessionWithUser = session.SessionWithUser;
pub const COOKIE_SESSION = session.COOKIE_SESSION;
pub const CSRF_COOKIE = session.CSRF_COOKIE;
pub const DEFAULT_TTL_S = session.DEFAULT_TTL_S;

// Token purpose
pub const TokenPurpose = token.TokenPurpose;

// Email
pub const EmailMessage = email.EmailMessage;
pub const SendEmailFn = email.SendEmailFn;
pub const TemplateType = email.TemplateType;

// DB
pub const Adapter = db.Adapter;
pub const Value = db.Value;
pub const Row = db.Row;
pub const Field = db.Field;
pub const QueryResult = db.QueryResult;
pub const FetchResult = db.FetchResult;
pub const FetchFn = db.FetchFn;

// Password params
pub const WorkersParams = password.WorkersParams;
pub const ServerParams = password.ServerParams;

// CSRF error
pub const CsrfError = csrf.CsrfError;

// Rate limit
pub const RateLimitConfig = rate_limit.RateLimitConfig;
pub const RateLimitKey = rate_limit.RateLimitKey;

// Auth top-level
pub const Config = auth.Config;
pub const AuthContext = auth.AuthContext;
pub const handle = auth.handle;
pub const getSession = auth.getSession;

// ── Comptime version ───────────────────────────────────────────────────────

pub const version = "0.1.0";

// ── Test runner ───────────────────────────────────────────────────────────
// Referencing each module causes `zig build test` to compile and run their
// tests transitively.

test {
    _ = crypto;
    _ = password;
    _ = token;
    _ = session;
    _ = csrf;
    _ = email;
    _ = rate_limit;
    _ = db;
    _ = auth;
}
