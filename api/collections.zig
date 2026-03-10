const std = @import("std");
const mer = @import("mer");

/// Proxy to data.gov.sg collections API — keeps the API key server-side.
/// Query params:
///   ?page=N       — paginate collections (default 1)
///   ?search=term  — search datasets by keyword
pub fn render(req: mer.Request) mer.Response {
    const api_key = mer.env("SG_DATA_API_KEY") orelse {
        return mer.json(
            \\{"error":"SG_DATA_API_KEY not configured. Set this environment variable to browse datasets."}
        );
    };

    const search = req.queryParam("search");
    const page = req.queryParam("page") orelse "1";

    // Build URL
    const url = if (search) |q|
        std.fmt.allocPrint(req.allocator,
            "https://api-production.data.gov.sg/v2/public/api/datasets?search={s}", .{q}) catch
            return mer.internalError("alloc failed")
    else
        std.fmt.allocPrint(req.allocator,
            "https://api-production.data.gov.sg/v2/public/api/collections?page={s}", .{page}) catch
            return mer.internalError("alloc failed");

    const result = mer.fetch(req.allocator, .{
        .url   = url,
        .headers = &.{
            .{ .name = "x-api-key", .value = api_key },
        },
    }) catch {
        return mer.json(
            \\{"error":"Failed to fetch from data.gov.sg"}
        );
    };

    if (result.status != .ok) {
        return mer.json(
            \\{"error":"data.gov.sg returned an error"}
        );
    }

    // Return the raw JSON from data.gov.sg — it's already valid JSON
    return mer.Response.init(.ok, .json, result.body);
}
