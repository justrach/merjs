// static.zig — serve files from public/ (Zig 0.15).

const std = @import("std");
const mer = @import("mer");

const server = @import("server.zig");
const log = std.log.scoped(.static);

const mime_table = [_]struct { ext: []const u8, ct: mer.ContentType }{
    .{ .ext = ".html", .ct = .html },
    .{ .ext = ".htm",  .ct = .html },
    .{ .ext = ".css",  .ct = .css },
    .{ .ext = ".js",   .ct = .js },
    .{ .ext = ".wasm", .ct = .wasm },
    .{ .ext = ".json", .ct = .json },
    .{ .ext = ".txt",  .ct = .text },
    .{ .ext = ".png",  .ct = .png },
    .{ .ext = ".jpg",  .ct = .jpeg },
    .{ .ext = ".jpeg", .ct = .jpeg },
    .{ .ext = ".gif",  .ct = .gif },
    .{ .ext = ".svg",  .ct = .svg },
    .{ .ext = ".ico",  .ct = .ico },
    .{ .ext = ".webp", .ct = .webp },
};

fn mimeForPath(path: []const u8) mer.ContentType {
    for (mime_table) |entry| {
        if (std.mem.endsWith(u8, path, entry.ext)) return entry.ct;
    }
    return .octet_stream;
}

/// Attempt to serve `url_path` from the public/ directory.
/// Returns `{}` if served, `null` if the file was not found.
pub fn tryServe(
    alloc: std.mem.Allocator,
    std_req: *std.http.Server.Request,
    url_path: []const u8,
) ?void {
    if (std.mem.indexOf(u8, url_path, "..") != null) return null;

    const rel = if (url_path.len > 0 and url_path[0] == '/') url_path[1..] else url_path;
    if (rel.len == 0) return null;

    const fs_path = std.fmt.allocPrint(alloc, "public/{s}", .{rel}) catch return null;
    defer alloc.free(fs_path);

    const file = std.fs.cwd().openFile(fs_path, .{}) catch return null;
    defer file.close();

    const body = file.readToEndAlloc(alloc, 10 * 1024 * 1024) catch |err| {
        log.err("read {s}: {}", .{ fs_path, err });
        return null;
    };
    defer alloc.free(body);

    const ct = mimeForPath(rel);
    const ct_header = [_]std.http.Header{
        .{ .name = "content-type", .value = ct.mime() },
        .{ .name = "cache-control", .value = "public, max-age=31536000, immutable" },
    };
    var header_buf: [2048]u8 = undefined;
    var bw = std_req.respondStreaming(&header_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &(ct_header ++ server.security_headers),
        },
    }) catch return null;
    bw.writer.writeAll(body) catch return null;
    bw.end() catch return null;

    return {};
}
