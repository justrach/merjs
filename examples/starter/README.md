# merjs Starter Template

This is the default template used by `create-mer-app`.

## Structure

```
app/
  index.zig    → /           (welcome page)
  about.zig    → /about      (static page, prerendered)
  layout.zig   → shared layout wrapper
  404.zig      → not-found handler
api/
  hello.zig    → /api/hello  (JSON API)
```

## Getting started

```bash
zig build codegen   # generate routes
zig build serve     # start dev server on :3000
```
