# merjs Kanban Example

A drag-and-drop Kanban board — the merjs answer to [Remix Trellix](https://github.com/remix-run/example-trellix).

**merjs renders the shell. Everything else is vanilla JS.**

## Features

- Drag and drop cards between columns (HTML5 Drag API)
- Add cards (type + Enter, or click Add)
- Delete cards (hover × button)
- Edit card text (double-click)
- Add columns (prompt)
- Delete columns (hover × button)
- Edit column titles (double-click)
- Reset board to defaults
- State persisted in `localStorage`

## vs Remix Trellix

| | merjs Kanban | Remix Trellix |
|---|---|---|
| Runtime | Zig → WASM | Node.js |
| State | `localStorage` | SQLite / Postgres |
| JS framework | none (vanilla) | React |
| Hydration | none | full |
| Bundle size | ~1KB JS | ~100KB+ |

The point: merjs serves pure HTML + ~1KB of vanilla JS. No React, no hydration, no server mutations needed for client-only state.

## Run locally

```bash
zig build serve
# visit http://localhost:3000
```

## Deploy to Cloudflare Workers

```bash
cd worker
npx wrangler deploy
```
