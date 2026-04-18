const std = @import("std");
const mer = @import("mer");

const version = mer.version;
const page_css = @embedFile("page.css");
const page_template = @embedFile("page.html");

pub const meta: mer.Meta = .{
    .title = "merjs v0.2.5 - release dashboard",
    .description = "A release page for merjs v0.2.5 with migration notes, memory and runtime updates, and chart-based performance summaries.",
    .og_title = "merjs v0.2.5",
    .og_description = "Zig 0.16 migration, installer updates, memory reuse, caching, and runtime charts.",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    const html = std.fmt.allocPrint(req.allocator, page_template, .{ version, version }) catch {
        return mer.internalError("render failed");
    };
    return mer.html(html);
}
