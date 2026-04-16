# Zig 0.16 Migration Guide

**From:** Zig 0.15.x
**To:** Zig 0.16.0
**Status:** In progress

This guide documents every breaking change encountered migrating merjs from 0.15.x to 0.16.0,
with the verified fixes. Intended as a reference for future agents or developers working in this codebase.

---

## Summary of Breaking Changes

0.16 has three major categories of breakage:

1. **`std.net` completely removed** — replaced by `std.Io.net`, which needs an `Io` instance.
   `Io.net.Stream` has a different API: different close signature, no `.read()`/`.writeAll()`.
2. **`std.io` (lowercase) completely removed** — `std.Io` (capital) is the new async IO module
   but has totally different semantics. `std.fmt.bufPrint` replaces `fixedBufferStream`.
3. **Time, threading, and POSIX API pruning** — `std.time.timestamp/milliTimestamp/nanoTimestamp`,
   `std.Thread.Mutex/Condition/sleep`, `std.debug.lockStderrWriter`, `std.posix.write/connect/socket`,
   and `std.crypto.random` all removed.

---

## 1. Networking: `std.net` → `std.Io.net`

### 1a. Type rename: `std.net.Stream` → `std.Io.net.Stream`

### 1b. Accept loop: `std.net.Address` → `std.Io.net.IpAddress` + `io` argument

### 1c. `stream.close()` → `stream.close(io)` — takes Io argument

### 1d. Raw fd: `stream.handle` → `stream.socket.handle`

### 1e. `Io.net.Stream` has NO `.read()` or `.writeAll()` methods — use raw C wrappers

### 1f. `std.net.has_unix_sockets` → `std.Io.net.has_unix_sockets`

### 1g. `std.net.connectUnixSocket/tcpConnectToHost` removed — use raw C externs

---

## 2. `std.io` (lowercase) completely removed

### 2a. `std.io.fixedBufferStream` → `std.fmt.bufPrint`

### 2b. `*std.io.Writer` vtable parameter → `*std.Io.Writer`

---

## 3. Time APIs removed: use `clock_gettime`

`std.time.timestamp()`, `milliTimestamp()`, and `nanoTimestamp()` are all removed.
Use `std.c.clock_gettime(.REALTIME, &ts)`.

`ts.nsec` is signed — use `@divTrunc` not `/` for division.

---

## 4. Thread primitives removed: use POSIX pthreads

`std.Thread.Mutex`, `std.Thread.Condition`, and `std.Thread.sleep` are removed.
Use POSIX pthread shims (`pthread_mutex_t`, `pthread_cond_t`, `nanosleep`).

---

## 5. `std.debug.lockStderrWriter` → `std.debug.lockStderr`

---

## 6. `std.crypto.random` removed — use `arc4random_buf`

---

## 7. `ArrayListUnmanaged` empty init changed

```zig
// Before (0.15)
._list = .{},

// After (0.16) — explicit fields required
._list = .{ .items = &.{}, .capacity = 0 },
```

---

## 8. Local constants cannot shadow module-level `extern` declarations
