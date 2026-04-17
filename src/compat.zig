const std = @import("std");
const runtime = @import("runtime");

/// Thin compat shims for std.Io adoption.
///
/// These are for mechanical rewrites only — places where the std.Io API
/// differs from the old std.fs/std.time API. Use native std.Io directly
/// where the adoption is zero-cost (Mutex, Condition, RwLock, net).
///
/// Goal: delete this file once the ecosystem stabilizes and we can use
/// std.Io directly everywhere.

// ============================================================================
// File System (std.fs.cwd() -> std.Io.Dir.cwd())
// ============================================================================

pub const fs = struct {
    /// Delete a directory tree starting at path.
    pub fn cwdDeleteTree(path: []const u8) !void {
        return std.Io.Dir.cwd().deleteTree(runtime.io, path);
    }

    /// Create a directory.
    pub fn cwdMakeDir(path: []const u8) !void {
        return std.Io.Dir.cwd().makeDir(runtime.io, path);
    }

    /// Open a directory.
    pub fn cwdOpenDir(path: []const u8, flags: std.fs.Dir.OpenDirOptions) !std.fs.Dir {
        return std.Io.Dir.cwd().openDir(runtime.io, path, flags);
    }

    /// Open a file.
    pub fn cwdOpenFile(path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
        return std.Io.Dir.cwd().openFile(runtime.io, path, flags);
    }

    /// Create a file.
    pub fn cwdCreateFile(path: []const u8, flags: std.fs.File.CreateFlags) !std.fs.File {
        return std.Io.Dir.cwd().createFile(runtime.io, path, flags);
    }

    /// Get the canonical absolute path.
    pub fn cwdRealpath(path: []const u8, out_buffer: []u8) ![]u8 {
        return std.Io.Dir.cwd().realpath(runtime.io, path, out_buffer);
    }

    /// Check if path exists (access).
    pub fn cwdAccess(path: []const u8, mode: std.fs.File.AccessMode) !void {
        return std.Io.Dir.cwd().access(runtime.io, path, mode);
    }
};

// ============================================================================
// Time (clock_gettime shims)
// ============================================================================

pub fn milliTimestamp() i64 {
    // Use std.time.milliTimestamp for now — it's portable
    // In full std.Io mode, this would be runtime.io.clock(.realtime)
    return std.time.milliTimestamp();
}

pub fn nanoTimestamp() i128 {
    return std.time.nanoTimestamp();
}

/// Sleep for nanoseconds (nanosleep).
pub fn threadSleep(ns: u64) void {
    std.time.sleep(ns);
}

// ============================================================================
// Random (crypto.random -> io.random)
// ============================================================================

pub fn randomBytes(buf: []u8) void {
    // std.crypto.random is still the way for now
    std.crypto.random.bytes(buf);
}
