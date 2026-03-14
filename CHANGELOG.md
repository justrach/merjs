# Changelog

All notable changes to merjs will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/justrach/merjs/releases/tag/v0.1.0
