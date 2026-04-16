# Cloudflare Workers — Add Install Route

If you already have wrangler set up, just add the install.sh route.

## Option 1: Add Route to Existing Worker (JavaScript)

Add to your existing `worker.js`:

```javascript
if (url.pathname === '/install.sh' || url.pathname === '/install') {
  const installScript = await fetch('https://raw.githubusercontent.com/justrach/merjs/main/install.sh');
  return new Response(installScript.body, {
    headers: {
      'Content-Type': 'text/x-shellscript; charset=utf-8',
      'Cache-Control': 'public, max-age=3600',
    },
  });
}
```

## Option 2: Standalone Installer Worker

Use the included `worker.js` as a minimal standalone:

```bash
# Copy files
cp worker.js your-worker-directory/
cp public/install.sh your-worker-directory/public/

# Deploy
cd your-worker-directory
wrangler deploy
```

## Files Included

- `worker.js` — Complete worker that serves install.sh
- `public/install.sh` — The installer script (copy to your public/ folder)

## Custom Domain

Update your `wrangler.toml`:

```toml
name = "merjs-installer"
routes = [
  { pattern = "install.yourdomain.com", custom_domain = true }
]
```

Or add via Cloudflare dashboard:
Workers & Pages → Your worker → Settings → Triggers → Custom Domains

## Usage

```bash
# After deploy
curl -fsSL https://install.yourdomain.com/install.sh | bash
```

## How It Works

1. Worker runs at Cloudflare's edge (300+ locations)
2. Fetches install.sh from GitHub (cached for 1 hour)
3. Returns with proper content-type for shell execution
4. User's curl pipes it directly to bash

**Benefits:**
- 🌍 Edge-deployed (fast from anywhere)
- 📦 No server to maintain
- 🔒 HTTPS by default
- 🆓 Free tier: 100k requests/day
