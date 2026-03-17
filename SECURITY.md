# Security Policy

## Supported versions

merjs is pre-1.0 and experimental. Only the latest commit on `main` receives security fixes.

## Reporting a vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Email **rach@merlionjs.com** with:

- A description of the vulnerability and its impact
- Steps to reproduce (minimal PoC if possible)
- Affected component (`src/server.zig`, `worker/worker.js`, etc.)
- Your suggested fix if you have one

You will receive an acknowledgement within 48 hours and a resolution timeline within 7 days.

## Scope

In scope:
- HTTP server request handling (`src/server.zig`)
- Session signing/verification (`src/mer.zig` `signSession`/`verifySession`)
- Cloudflare Workers WASM handler (`worker/worker.js`)
- `merjs-auth` package (`packages/merjs-auth/`)

Out of scope:
- Vulnerabilities in Zig toolchain itself (report to https://github.com/ziglang/zig)
- Issues in third-party dependencies (dhi, Tailwind)
- Demo/example apps that are not the framework runtime
