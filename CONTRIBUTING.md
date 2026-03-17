# Contributing to merjs

Thanks for your interest. merjs is experimental — expect sharp edges and API churn.

## Prerequisites

- [Zig 0.15.x](https://ziglang.org/download/) — check with `zig version`
- macOS or Linux (Windows is untested)

## Local setup

```bash
git clone https://github.com/justrach/merjs.git
cd merjs
git config core.hooksPath .githooks   # enable pre-commit (fmt+build) and pre-push (test)
```

## One-command dev start

```bash
zig build codegen    # generate src/generated/routes.zig from app/
zig build serve      # start dev server on :3000 with hot reload
```

Or via the `mer` CLI (built from `cli.zig`):

```bash
zig build cli                   # produces zig-out/bin/mer
./zig-out/bin/mer dev           # codegen + serve in one step
```

## Build targets

| Command | What it does |
|---|---|
| `zig build` | Compile the framework binary |
| `zig build serve` | Dev server on :3000, hot reload |
| `zig build codegen` | Regenerate `src/generated/routes.zig` |
| `zig build worker` | Compile `worker/merjs.wasm` for Cloudflare Workers |
| `zig build desktop` | Native macOS `.app` bundle (macOS only, experimental) |
| `zig build test` | Run unit tests |
| `zig build test-auth` | Run `packages/merjs-auth` tests |
| `zig build css` | Recompile Tailwind → `public/styles.css` |

## Before submitting a PR

1. `zig fmt src/ app/ api/ examples/ *.zig` — formatter is enforced by pre-commit hook
2. `zig build` — must compile without errors
3. `zig build test` — must pass
4. Open an issue first for anything non-trivial so we can align on approach

## Branch naming

- `feat/<name>` — new feature
- `fix/<name>` — bug fix
- `docs/<name>` — documentation only
- `refactor/<name>` — no behaviour change

## Repo layout

See [docs/architecture.md](docs/architecture.md) for a full breakdown. The short version:

- `src/` — framework runtime (server, router, SSR, HTML builder, watcher)
- `app/`, `api/`, `public/` — the merjs website / demo app (not the framework itself)
- `examples/` — standalone demo apps (kanban, desktop, singapore-data-dashboard)
- `packages/` — optional packages (`merjs-auth`)
- `cli.zig` — `mer` CLI entry point
- `wasm/` — client-side WASM modules

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Please include:
- `zig version` output
- OS + arch
- Minimal reproduction steps
