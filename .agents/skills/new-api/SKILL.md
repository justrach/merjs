---
name: new-api
description: Scaffold a new merjs API route. Use when the user wants to create a new API endpoint.
argument-hint: "[route-name]"
disable-model-invocation: true
---

# Create a new merjs API route

Scaffold a new API route at `api/$ARGUMENTS.zig`.

## Steps

1. Create `api/$ARGUMENTS.zig` with this template:

```zig
const mer = @import("mer");

const Response = struct {
    // Define your response fields here
    message: []const u8,
};

pub fn render(req: mer.Request) mer.Response {
    return mer.typedJson(req.allocator, Response{
        .message = "hello",
    });
}
```

2. Adapt the Response struct fields based on what the user described
3. Run `zig build codegen` to regenerate routes
4. Confirm the route appears at `/api/$ARGUMENTS`

## Conventions

- API routes live in `api/` and map to `/api/...`
- Use `mer.typedJson(allocator, value)` to return typed JSON responses
- Use `mer.json(string)` for raw JSON strings
- Access request body via `req.body`, method via `req.method`
- Access query string via `req.query_string`
- Access cookies via `req.cookie("name")`
- For validation, use dhi: `const dhi = @import("dhi_validator");`
- API routes do NOT need `pub const meta`
