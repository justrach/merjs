# Changelog

All notable changes to merjs will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] — 2026-03-28

### Added
- **turboapi-core dependency** — merjs now imports [turboapi-core](https://github.com/justrach/turboAPI/tree/main/turboapi-core), a shared Zig library providing a radix trie router, HTTP utilities (`percentDecode`, `queryStringGet`, `statusText`, `formatHttpDate`), and a bounded response cache. This is the first step toward sharing routing primitives between merjs and turboAPI. See [#66](https://github.com/justrach/merjs/issues/66) for the full integration roadmap.

### Next (tracked in #66)
- Method-based API routing via turboapi-core's radix trie (GET vs POST on same path)
- Replace `queryParamFromStr` with turboapi-core's `queryStringGet`
- Optional: radix trie for dynamic page routes (perf upgrade for large route counts)

---

## [Unreleased]

### Added
- **Shell-first HTML rendering** — layout splits into head (CSS, meta, nav) and tail (footer, closing tags). The server flushes the head chunk immediately via chunked transfer encoding before the page's `render()` runs. This is NOT true streaming SSR (render still blocks) — it's early shell flushing so the browser can start painting the layout while waiting for page content.
- **`mer.fetchAll()`** — parallel HTTP fetching. Spawns a thread per request, joins all. Cuts total latency to the slowest single fetch instead of the sum.
- **`<link rel="preload">` hints** for external scripts on sgdata pages (Leaflet, Chart.js)

### Fixed
- **sgdata LCP 5.4s → 0.8s** — root cause was render-blocking `<script>` tags in `<head>` for Leaflet (170KB) and Chart.js (200KB). Added `<link rel="preload">` hints so the browser starts downloading them earlier. Layout preload hints and `fetchpriority="high"` also applied.
- sgdata layout had duplicate wordmark element and missing `<header>` tag

### Lighthouse scores (after all fixes)
| Site | Score | LCP |
|------|-------|-----|
| merlionjs.com | **100/100** | 0.8s |
| sgdata.merlionjs.com | **99/100** | 0.8s |
| sgdata.merlionjs.com/weather | 82/100 | 4.7s (Leaflet CSS still blocking) |

---

## [0.1.0] — 2026-03-14

First stable release.

### Added
- **`mer` CLI** (131 KB binary) with `init`, `dev`, `build`, `--version` commands
  - `mer init <name>` scaffolds a new project with embedded starter template
  - `mer dev` combines codegen + dev server in one command
  - `mer build` runs production build with ReleaseSmall + prerender
- **Cross-platform releases** — macOS (aarch64/x86_64) + Linux (aarch64/x86_64) binaries published automatically via GitHub Actions
- **Beta release workflow** — push to `beta` branch auto-publishes pre-release binaries
- **Stable release workflow** — push a `v*.*.*` tag to auto-publish a stable release with checksums
- **Pre-commit hooks** — `zig fmt --check` + `zig build` on commit, `zig build test` on push
- `Content-Length` headers on all responses (SSR, static, prerendered)
- `<link rel="preload">` and `fetchpriority="high"` for hero image
- Explicit `width`/`height` on logo image to eliminate layout shift (CLS)
- Versioning via `build.zig.zon`, `mer.version`, and `--version` flag
- This changelog

### Performance — 48x throughput improvement
- **In-memory static file cache** — disk I/O on first request only, served from memory thereafter
- **Hash map router** — O(1) exact route matching, replaces O(N) linear scan
- **Write buffer 4 KB → 64 KB** — reduces flush syscalls
- **Read buffer 8 KB → 16 KB** — fewer reads per request
- **Arena reset between keep-alive requests** — memory reuse instead of free + realloc
- **CPU-based thread pool sizing** — auto-scales to hardware, replaces hardcoded 128 threads
- **Batch HTML/attribute escaping** — writes chunks instead of byte-by-byte
- **Binary stripping** — `.strip = true` for release builds

### Results
| Metric | Before | After |
|--------|--------|-------|
| Homepage SSR throughput | 2,400 req/s | **115,093 req/s** (48x) |
| API JSON throughput | 2,400 req/s | **133,957 req/s** (56x) |
| Avg latency | 41 ms | **0.39 ms** (105x) |
| Binary size | 1.9 MB | **260 KB** (-86%) |
| CLI binary | — | **131 KB** |

> Measured locally on Apple M-series with `wrk -t4 -c50 -d10s`.

### Changed
- CI E2E tests updated to use [kuri](https://github.com/justrach/kuri) (renamed from agentic-browdie)
- Homepage benchmark section updated with verified local numbers
- Deployed updated site to merlionjs.com via Cloudflare Workers
- Codebase formatted with `zig fmt` (now enforced by pre-commit hook)

### Fixed
- Layout shift (CLS) from logo image without explicit dimensions
- Static files re-read from disk on every request (now cached)
- Thread pool hardcoded to 128 threads regardless of CPU count

[Unreleased]: https://github.com/justrach/merjs/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/justrach/merjs/releases/tag/v0.1.0
