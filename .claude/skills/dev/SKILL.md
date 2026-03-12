---
name: dev
description: Build and start the merjs dev server with hot reload. Use when the user wants to run, start, or serve the project.
disable-model-invocation: true
---

# Start merjs dev server

## Steps

1. Kill any existing process on port 3000:
   ```bash
   lsof -ti :3000 | xargs kill -9 2>/dev/null
   ```

2. Regenerate routes (in case pages changed):
   ```bash
   zig build codegen
   ```

3. Build the project:
   ```bash
   zig build
   ```

4. Start the dev server in the background:
   ```bash
   ./zig-out/bin/merjs --port 3000 &
   ```

5. Wait 2 seconds, then verify the server is listening:
   ```bash
   lsof -i :3000 -sTCP:LISTEN
   ```

6. Tell the user the server is running at http://localhost:3000

## Flags

- `--port N` — listen on a different port
- `--no-dev` — disable hot reload (SSE watcher)
- `--prerender` — pre-render SSG pages to dist/ and exit
