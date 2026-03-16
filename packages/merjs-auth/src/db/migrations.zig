//! SQL migration strings, embedded at compile time.
//!
//! Usage (run all migrations on startup):
//!
//!   try migrations.runAll(db_adapter, allocator);
//!
//! For production you may prefer a dedicated migration tool; this runner is
//! a convenience for development and testing.

const std = @import("std");
const root = @import("root.zig");

// ── Embedded SQL ───────────────────────────────────────────────────────────

pub const migration_001 = @embedFile("../../schema/001_initial.sql");
pub const migration_002 = @embedFile("../../schema/002_oauth.sql");
pub const migration_003 = @embedFile("../../schema/003_organizations.sql");
pub const migration_004 = @embedFile("../../schema/004_saml.sql");

/// All migrations in order. Pass to `runAll` or iterate manually.
pub const all: []const []const u8 = &.{
    migration_001,
    migration_002,
    migration_003,
    migration_004,
};

// ── Runner ─────────────────────────────────────────────────────────────────

/// Execute every migration SQL string against `db` in sequence.
///
/// Each migration is executed as a single `exec` call. Most SQL files
/// contain multiple statements; your adapter's `execFn` must support
/// multi-statement SQL (standard for Postgres drivers).
///
/// Stops and returns the first error encountered so partial migrations
/// can be rolled back at the adapter level.
pub fn runAll(db: root.Adapter, alloc: std.mem.Allocator) !void {
    for (all) |sql| {
        try db.exec(alloc, sql, &.{});
    }
}
