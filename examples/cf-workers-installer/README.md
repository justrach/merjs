# Cloudflare Workers — merjs Installer

Serve merjs install.sh from the edge at `merjs.trilok.ai`.

## Deploy

```bash
cd examples/cf-workers-installer

# Deploy to Cloudflare
wrangler deploy

# Add custom domain in Cloudflare dashboard:
# Workers & Pages → merjs-installer → Settings → Triggers → Custom Domains
# Add: merjs.trilok.ai
```

Or add to `wrangler.toml`:

```toml
[[routes]]
pattern = "merjs.trilok.ai"
custom_domain = true
```

## Usage

```bash
curl -fsSL https://merjs.trilok.ai/install.sh | bash
```

## Files

- `public/install.sh` — The installer script (served at `/install.sh`)
- `public/index.html` — Landing page (served at `/`)
- `wrangler.toml` — Cloudflare config

## How It Works

1. Static assets served from Cloudflare's edge (300+ locations)
2. `install.sh` is cached globally
3. HTTPS by default
4. Free tier: 100k requests/day
