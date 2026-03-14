# Changelog

All notable changes to merjs will be documented in this file.

## [0.1.0] — 2026-03-14

### Added
- `mer` CLI with `init`, `dev`, `build`, `--version` commands
- `mer init <name>` scaffolds a new project from the starter template
- `mer dev` combines codegen + dev server in one command
- `mer build` runs production build with ReleaseSmall + prerender
- Binary stripping for release builds (1.9MB → 260KB)
- `Content-Length` headers on all responses (HTML, static, prerendered)
- `<link rel="preload">` for hero image in layout
- `fetchpriority="high"` and explicit `width`/`height` on logo image
- Versioning via `build.zig.zon` and `--version` flag

### Changed
- Static asset responses now include `Content-Length` for progressive rendering
- Prerendered page responses now include `Content-Length`

### Fixed
- Layout shift (CLS) from logo image without explicit dimensions
