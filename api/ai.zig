const std = @import("std");
const mer = @import("mer");

/// Budget 2026 AI — RAG pipeline:
///   1. Embed question via text-embedding-3-small
///   2. Search EmergentDB (namespace: budget2026)
///   3. Chat with gpt-5-nano using retrieved context
/// POST body: {"question": "..."}
pub fn render(req: mer.Request) mer.Response {
    const openai_key = mer.env("OPENAI_API_KEY") orelse {
        return mer.json(
            \\{"error":"OPENAI_API_KEY not configured"}
        );
    };
    const emergent_key = mer.env("EMERGENT_API_KEY") orelse {
        return mer.json(
            \\{"error":"EMERGENT_API_KEY not configured"}
        );
    };

    if (req.body.len == 0) return mer.badRequest("Request body required");

    const parsed = std.json.parseFromSlice(struct {
        question: []const u8,
    }, req.allocator, req.body, .{ .ignore_unknown_fields = true }) catch {
        return mer.badRequest("Invalid JSON body");
    };
    const question = parsed.value.question;

    // Pre-build header strings for curl
    const openai_auth_hdr = std.fmt.allocPrint(req.allocator, "Authorization: Bearer {s}", .{openai_key})
        catch return mer.internalError("alloc");
    const emergent_auth_hdr = std.fmt.allocPrint(req.allocator, "Authorization: Bearer {s}", .{emergent_key})
        catch return mer.internalError("alloc");

    // ── Step 1: Embed the question ───────────────────────────────────────────
    var embed_out: std.io.Writer.Allocating = .init(req.allocator);
    var ejw: std.json.Stringify = .{ .writer = &embed_out.writer };
    ejw.beginObject() catch return mer.internalError("json");
    ejw.objectField("model") catch return mer.internalError("json");
    ejw.write("text-embedding-3-small") catch return mer.internalError("json");
    ejw.objectField("input") catch return mer.internalError("json");
    ejw.write(question) catch return mer.internalError("json");
    ejw.endObject() catch return mer.internalError("json");

    const embed_run = std.process.Child.run(.{
        .allocator = req.allocator,
        .max_output_bytes = 512 * 1024,
        .argv = &.{
            "curl", "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", openai_auth_hdr,
            "-d", embed_out.written(),
            "https://api.openai.com/v1/embeddings",
        },
    }) catch |err| {
        const msg = std.fmt.allocPrint(req.allocator,
            \\{{"error":"curl embed failed: {}"}}
        , .{err}) catch return mer.internalError("alloc");
        return mer.Response.init(.ok, .json, msg);
    };

    // Extract the raw embedding JSON array directly — avoids f64 re-serialization precision issues
    const embed_prefix = "\"embedding\":";
    const prefix_idx = std.mem.indexOf(u8, embed_run.stdout, embed_prefix) orelse {
        const dbg = std.fmt.allocPrint(req.allocator,
            \\{{"error":"embedding key not found","stdout":"{s}"}}
        , .{embed_run.stdout[0..@min(200, embed_run.stdout.len)]}) catch return mer.internalError("alloc");
        return mer.Response.init(.ok, .json, dbg);
    };
    // Skip past key + any whitespace to find '['
    var array_start = prefix_idx + embed_prefix.len;
    while (array_start < embed_run.stdout.len and embed_run.stdout[array_start] != '[') {
        array_start += 1;
    }
    if (array_start >= embed_run.stdout.len) {
        return mer.json("{\"error\":\"embedding array bracket not found\"}");
    }
    var depth: usize = 0;
    var array_end: usize = array_start;
    for (embed_run.stdout[array_start..], 0..) |c, i| {
        switch (c) {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) { array_end = array_start + i + 1; break; }
            },
            else => {},
        }
    }
    if (array_end == array_start) {
        return mer.json("{\"error\":\"embedding array end not found\"}");
    }
    const embedding_json = embed_run.stdout[array_start..array_end];

    // ── Step 2: Search EmergentDB ────────────────────────────────────────────
    const search_body = std.fmt.allocPrint(req.allocator,
        \\{{"vector":{s},"k":5,"include_metadata":true}}
    , .{embedding_json}) catch return mer.internalError("alloc");

    // Write search body to temp file — avoids 30KB argv mangling
    {
        const f = std.fs.createFileAbsolute("/tmp/merjs_search.json", .{})
            catch return mer.internalError("tmpfile");
        f.writeAll(search_body) catch { f.close(); return mer.internalError("tmpwrite"); };
        f.close();
    }

    const search_run = std.process.Child.run(.{
        .allocator = req.allocator,
        .max_output_bytes = 512 * 1024,
        .argv = &.{
            "curl", "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", emergent_auth_hdr,
            "-H", "User-Agent: EmergentDB-Ingest/1.0",
            "-d", "@/tmp/merjs_search.json",
            "https://api.emergentdb.com/vectors/search",
        },
    }) catch |err| {
        const msg = std.fmt.allocPrint(req.allocator,
            \\{{"error":"curl search failed: {}"}}
        , .{err}) catch return mer.internalError("alloc");
        return mer.Response.init(.ok, .json, msg);
    };


    const SearchItem = struct {
        id:       u64,
        score:    f64,
        metadata: struct { text: []const u8 = "" },
    };
    const SearchResponse = struct { results: []SearchItem };
    const search_parsed = std.json.parseFromSlice(
        SearchResponse, req.allocator, search_run.stdout, .{ .ignore_unknown_fields = true },
    ) catch {
        return mer.Response.init(.ok, .json, search_run.stdout);
    };

    // Build context from retrieved chunks
    if (search_parsed.value.results.len == 0) {
        // Debug: return embedding info + search response
        const debug_msg = std.fmt.allocPrint(req.allocator,
            \\{{"error":"EmergentDB returned 0 results","emdb_response":{s},"embedding_len":{},"embedding_prefix":"{s}"}}
        , .{
            search_run.stdout,
            embedding_json.len,
            if (embedding_json.len > 30) embedding_json[0..30] else embedding_json,
        }) catch return mer.Response.init(.ok, .json, search_run.stdout);
        return mer.Response.init(.ok, .json, debug_msg);
    }
    var context: []const u8 = "";
    for (search_parsed.value.results, 0..) |r, i| {
        const sep: []const u8 = if (i > 0) "\n\n---\n\n" else "";
        context = std.fmt.allocPrint(req.allocator, "{s}{s}{s}", .{ context, sep, r.metadata.text })
            catch return mer.internalError("alloc");
    }

    // ── Step 3: Chat with gpt-5-nano ─────────────────────────────────────────
    const system_prompt =
        "You are a helpful assistant that answers questions about the FY2026 Budget Statement. " ++
        "Use the provided document context to give accurate, concise answers. " ++
        "Cite relevant figures and policies from the document when applicable.";

    const user_msg = std.fmt.allocPrint(req.allocator,
        "Context from FY2026 Budget Statement:\n{s}\n\nQuestion: {s}",
        .{ context, question },
    ) catch return mer.internalError("alloc");

    var chat_out: std.io.Writer.Allocating = .init(req.allocator);
    var cjw: std.json.Stringify = .{ .writer = &chat_out.writer };
    cjw.beginObject() catch return mer.internalError("json");
    cjw.objectField("model") catch return mer.internalError("json");
    cjw.write("gpt-5-nano") catch return mer.internalError("json");
    cjw.objectField("instructions") catch return mer.internalError("json");
    cjw.write(system_prompt) catch return mer.internalError("json");
    cjw.objectField("input") catch return mer.internalError("json");
    cjw.write(user_msg) catch return mer.internalError("json");
    cjw.objectField("max_output_tokens") catch return mer.internalError("json");
    cjw.write(@as(u32, 128000)) catch return mer.internalError("json");
    cjw.endObject() catch return mer.internalError("json");

    {
        const f = std.fs.createFileAbsolute("/tmp/merjs_chat.json", .{})
            catch return mer.internalError("tmpfile");
        f.writeAll(chat_out.written()) catch { f.close(); return mer.internalError("tmpwrite"); };
        f.close();
    }

    const chat_run = std.process.Child.run(.{
        .allocator = req.allocator,
        .max_output_bytes = 512 * 1024,
        .argv = &.{
            "curl", "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", openai_auth_hdr,
            "-d", "@/tmp/merjs_chat.json",
            "https://api.openai.com/v1/responses",
        },
    }) catch |err| {
        const msg = std.fmt.allocPrint(req.allocator,
            \\{{"error":"curl chat failed: {}"}}
        , .{err}) catch return mer.internalError("alloc");
        return mer.Response.init(.ok, .json, msg);
    };


    // Responses API: output[0].content[0].text
    const ChatResponse = struct {
        output: []struct {
            content: []struct {
                type: []const u8 = "",
                text: []const u8 = "",
            },
        },
    };
    const chat_parsed = std.json.parseFromSlice(
        ChatResponse, req.allocator, chat_run.stdout, .{ .ignore_unknown_fields = true },
    ) catch {
        return mer.Response.init(.ok, .json, chat_run.stdout);
    };
    if (chat_parsed.value.output.len == 0 or chat_parsed.value.output[0].content.len == 0) {
        return mer.Response.init(.ok, .json, chat_run.stdout);
    }
    const answer = chat_parsed.value.output[0].content[0].text;
    if (answer.len == 0) return mer.Response.init(.ok, .json, chat_run.stdout);

    var resp_out: std.io.Writer.Allocating = .init(req.allocator);
    var rjw: std.json.Stringify = .{ .writer = &resp_out.writer };
    rjw.beginObject() catch return mer.internalError("json");
    rjw.objectField("answer") catch return mer.internalError("json");
    rjw.write(answer) catch return mer.internalError("json");
    rjw.endObject() catch return mer.internalError("json");
    return mer.Response.init(.ok, .json, resp_out.written());
}
