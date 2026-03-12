---
name: new-page
description: Scaffold a new merjs page. Use when the user wants to create a new page, route, or view.
argument-hint: "[page-name]"
disable-model-invocation: true
---

# Create a new merjs page

Scaffold a new page at `app/$ARGUMENTS.zig` that follows the merjs conventions.

## Steps

1. Create `app/$ARGUMENTS.zig` with this template:

```zig
const mer = @import("mer");
const h = mer.h;

pub const meta: mer.Meta = .{
    .title = "PAGE_TITLE",
    .description = "PAGE_DESCRIPTION",
};

const page_node = page();

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, page_node);
}

fn page() h.Node {
    return h.div(.{ .class = "page" }, .{
        h.h1(.{}, "PAGE_TITLE"),
    });
}
```

2. Replace PAGE_TITLE and PAGE_DESCRIPTION with sensible values derived from the page name
3. Run `zig build codegen` to regenerate routes
4. Confirm the new route appears in `src/generated/routes.zig`
5. Tell the user the route is available at the mapped URL path

## Conventions

- Every app/ page MUST export `pub const meta: mer.Meta`
- Every page MUST export `pub fn render(req: mer.Request) mer.Response`
- Use the `h` DSL (mer.h) for HTML — prefer comptime nodes
- For dynamic routes, use bracket syntax: `app/users/[id].zig` → `/users/:id`
- `app/index.zig` maps to `/`
- `app/foo/index.zig` maps to `/foo`
- Add `pub const prerender = true;` for static pages that don't need request data
