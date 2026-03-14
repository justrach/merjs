# Twitter Thread — merjs 0.1.0 Performance Update

---

## Tweet 1 (Hook)

merjs just went from 2,400 req/s to 115,000 req/s.

A 48x improvement. In one afternoon.

No Rust rewrite. No C extensions. Just better Zig.

Here's what changed (thread) 🧵

---

## Tweet 2 (The problem)

People told us the benchmarks were weak.

2,437 req/s for a compiled framework? "I expected ~1M RPS." Binary size 2MB? "That's a lot."

They were right. We were leaving performance on the table everywhere.

---

## Tweet 3 (What we found)

The hot path was doing insane things:

• Reading static files from disk on EVERY request
• 128 threads on an 8-core machine (context switch hell)
• 4KB write buffer = constant flush syscalls
• Linear O(N) route matching on every request
• HTML escaping byte-by-byte instead of batch writes
• New memory allocation per request, never reused

---

## Tweet 4 (The fixes)

Six changes. No architectural rewrite:

1. In-memory static file cache (disk I/O once, then memory)
2. Hash map router — O(1) exact match
3. Write buffer 4KB → 64KB
4. Arena reset between keep-alive requests (reuse, don't realloc)
5. CPU-based thread pool (not hardcoded 128)
6. Batch HTML escaping

---

## Tweet 5 (The numbers)

Before → After:

Homepage (SSR):  2,400 → 115,093 req/s (48x)
API JSON:        2,400 → 133,957 req/s (56x)
Static files:    2,400 → 10,011 req/s (4x)

Avg latency: 350-398μs
Binary size: 1.9MB → 260KB

All on Apple Silicon, measured with wrk.

---

## Tweet 6 (CLI announcement)

Also shipped: the `mer` CLI

```
mer init my-app    # scaffold project
mer dev            # codegen + hot reload
mer --version      # 0.1.0
```

131KB binary. Cross-compiled for macOS + Linux.

Download: github.com/justrach/merjs/releases

---

## Tweet 7 (What's next)

merjs is still early. But the foundation is solid now:

• 115K req/s SSR on a laptop
• 260KB binary
• Zero node_modules
• File-based routing, type-safe APIs, WASM client logic

If the web doesn't need a runtime, it definitely doesn't need a slow one.

github.com/justrach/merjs ⭐

---

## Tweet 8 (Credit)

Built this with Claude Code in one session:

• Profiled the hot path
• Identified 15 bottlenecks
• Implemented 6 fixes
• 48x improvement

The code writes itself when you know what to measure.
