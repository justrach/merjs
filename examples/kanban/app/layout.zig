const std = @import("std");
const mer = @import("mer");

pub fn wrap(allocator: std.mem.Allocator, path: []const u8, body: []const u8, meta: mer.Meta) []const u8 {
    _ = path;
    const title = if (meta.title.len > 0) meta.title else "Kanban — merjs";
    const desc = if (meta.description.len > 0) meta.description else "Kanban board built with merjs.";

    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);

    w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"UTF-8\">\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n") catch return body;
    w.print("  <title>{s}</title>\n  <meta name=\"description\" content=\"{s}\">\n", .{ title, desc }) catch return body;
    w.writeAll(
        \\  <link rel="preconnect" href="https://fonts.googleapis.com">
        \\  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        \\  <link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet" media="print" onload="this.media='all'">
        \\  <style>
        \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        \\    :root { --bg:#f0ebe3; --bg2:#e8e2d9; --bg3:#ddd5cc; --text:#252530; --muted:#8a7f78; --border:#d5cdc4; --red:#e8251f; }
        \\    body { background:var(--bg); color:var(--text); font-family:'DM Sans',system-ui,sans-serif; min-height:100vh; }
        \\    a { color:inherit; text-decoration:none; }
        \\  </style>
        \\
    ) catch return body;

    if (meta.extra_head) |extra| {
        w.writeAll(extra) catch {};
        w.writeAll("\n") catch {};
    }

    w.writeAll("</head>\n<body>\n") catch return body;
    w.writeAll(body) catch return body;
    w.writeAll("\n</body>\n</html>\n") catch return body;

    return buf.items;
}
