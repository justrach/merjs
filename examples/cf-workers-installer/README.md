# Cloudflare Workers Installer Example

Serve merjs install.sh and landing page via Cloudflare Workers at the edge.

## Quick Start

```bash
# Install Wrangler CLI
npm install -g wrangler

# Login to Cloudflare
wrangler login

# Build the worker
zig build worker

# Deploy
wrangler deploy
```

## Files

- `src/worker.zig` — Worker that serves install.sh and index.html
- `public/install.sh` — The installer script
- `public/index.html` — Landing page
- `wrangler.toml` — Cloudflare config

## Routes

- `/` or `/index.html` → Landing page
- `/install.sh` → Installer script

## Custom Domain

```bash
wrangler deploy --name merjs-installer
# Then add custom domain in Cloudflare dashboard
```

## Architecture

```
User → Cloudflare Edge → Worker (WASM) → Static Content
         ↓                    ↓
    Global CDN          Compiled Zig
```

## Benefits

- 🌍 **Edge Deployed** — Runs at 300+ locations worldwide
- ⚡ **Sub-50ms Response** — From anywhere
- 📦 **No Server** — Zero maintenance
- 🔒 **Automatic HTTPS** — Free SSL
- 🎉 **Free Tier** — 100k requests/day
