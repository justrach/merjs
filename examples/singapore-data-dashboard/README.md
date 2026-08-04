# singapore-data-dashboard

A real-time Singapore government data dashboard built with merjs.

Live demo: [sgdata.merlionjs.com](https://sgdata.merlionjs.com)

## Features

- **Dashboard** — PSI, UV index, 2-hour regional forecast from data.gov.sg
- **Weather** — Interactive Leaflet map with live NEA station readings
- **Environment** — Air quality, UV charts, rainfall by station
- **Explore** — Browse 1,300+ open Singapore government datasets
- **AI** — RAG chat over Singapore's FY2026 Budget Statement (GPT-5-nano + EmergentDB)

## Setup

Copy to a new directory and add env vars:

```bash
cp -r examples/singapore-data-dashboard myapp
cd myapp

# Set env vars
export OPENAI_API_KEY=sk-...
export EMERGENT_API_KEY=emdb-...
export AI_BEARER_TOKEN="$(openssl rand -hex 32)"
# AI_BUDGET_ACCOUNT and AI_BUDGET_GUARD are configured in worker/wrangler.toml.

zig build codegen
zig build serve
```

## Deploy

```bash
zig build sgdata-worker
cd worker
wrangler secret put OPENAI_API_KEY
wrangler secret put EMERGENT_API_KEY
wrangler secret put AI_BEARER_TOKEN
wrangler deploy
```

Before deployment, deploy the shared Durable Object-backed budget service named by
`AI_BUDGET_GUARD` and configure this account's daily limit there. The required
request/response, atomic reservation, and idempotency contract is documented in
[`../site/worker/AI_BUDGET_GUARD.md`](../site/worker/AI_BUDGET_GUARD.md).

The browser or API client must send `Authorization: Bearer <AI_BEARER_TOKEN>`
when calling the AI endpoints. The Worker fails closed if the bearer control,
`AI_BUDGET_ACCOUNT`, shared binding, or a valid admission is missing. Its local
concurrency and per-minute counters are defense-in-depth for one isolate only; the
shared gate is the deployment-wide daily budget authority.
