---
name: deploy
description: Full production build — codegen, compile, prerender, and prepare for deployment.
disable-model-invocation: true
---

# Production build

Run the full merjs production pipeline.

## Steps

1. Regenerate routes:
   ```bash
   zig build codegen
   ```

2. Run the full production build (codegen → compile → prerender):
   ```bash
   zig build prod
   ```

3. Verify the output:
   - Binary at `zig-out/bin/merjs`
   - Pre-rendered pages in `dist/`

4. Report which pages were pre-rendered (those with `pub const prerender = true`)

## Optional: Cloudflare Workers

To build the WASM worker target:
```bash
zig build worker
```
Output: `worker/merjs.wasm`
