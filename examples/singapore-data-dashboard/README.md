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

zig build codegen
zig build serve
```

## Deploy

```bash
cd worker
wrangler secret put OPENAI_API_KEY
wrangler secret put EMERGENT_API_KEY
wrangler deploy
```
