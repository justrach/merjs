const std = @import("std");
const mer = @import("mer");

/// Budget 2026 AI — RAG pipeline:
///   1. Embed question via text-embedding-3-small
///   2. Search EmergentDB (default namespace)
///   3. Chat with gpt-5-nano via /v1/responses
///
/// POST body: {"question": "...", "trace": true}
/// trace=true returns {"answer":"...","trace":{step1,step2,step3}} for debugging.
pub fn render(req: mer.Request) mer.Response {
    const openai_key   = mer.env("OPENAI_API_KEY")   orelse return mer.json("{\"error\":\"OPENAI_API_KEY not set\"}");
    const emergent_key = mer.env("EMERGENT_API_KEY") orelse return mer.json("{\"error\":\"EMERGENT_API_KEY not set\"}");

    if (req.body.len == 0) return mer.badRequest("Request body required");

    const Req = struct { question: []const u8, trace: bool = false };
    const body_parsed = std.json.parseFromSlice(Req, req.allocator, req.body,
        .{ .ignore_unknown_fields = true }) catch {
        return mer.badRequest("Invalid JSON — expected {\"question\":\"...\"}");
    };
    const question = body_parsed.value.question;
    const trace    = body_parsed.value.trace;

    const openai_auth   = std.fmt.allocPrint(req.allocator, "Authorization: Bearer {s}", .{openai_key})   catch return mer.internalError("alloc");
    const emergent_auth = std.fmt.allocPrint(req.allocator, "Authorization: Bearer {s}", .{emergent_key}) catch return mer.internalError("alloc");

    // ── Step 1: Embed ─────────────────────────────────────────────────────────
    var embed_buf: std.io.Writer.Allocating = .init(req.allocator);
    var ejw: std.json.Stringify = .{ .writer = &embed_buf.writer };
    ejw.beginObject() catch return mer.internalError("json");
    ejw.objectField("model") catch return mer.internalError("json");
    ejw.write("text-embedding-3-small") catch return mer.internalError("json");
    ejw.objectField("input") catch return mer.internalError("json");
    ejw.write(question) catch return mer.internalError("json");
    ejw.endObject() catch return mer.internalError("json");
    const embed_req = embed_buf.written();

    const embed_run = std.process.Child.run(.{
        .allocator = req.allocator,
        .max_output_bytes = 512 * 1024,
        .argv = &.{ "curl", "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", openai_auth,
            "-d", embed_req,
            "https://api.openai.com/v1/embeddings" },
    }) catch |err| return errJson(req.allocator, "curl embed failed: {}", .{err});

    // Extract raw embedding array (skip whitespace after "embedding":)
    const embed_prefix = "\"embedding\":";
    const pfx = std.mem.indexOf(u8, embed_run.stdout, embed_prefix) orelse {
        if (trace) return traceErr(req.allocator, "step1_embed", embed_req,
            embed_run.stdout, "\"embedding\" key not found in OpenAI response");
        return errJson(req.allocator, "OpenAI embed error: {s}",
            .{embed_run.stdout[0..@min(300, embed_run.stdout.len)]});
    };
    var arr_start = pfx + embed_prefix.len;
    while (arr_start < embed_run.stdout.len and embed_run.stdout[arr_start] != '[')
        arr_start += 1;
    if (arr_start >= embed_run.stdout.len)
        return errJson(req.allocator, "embedding '[' not found", .{});
    var depth: usize = 0;
    var arr_end: usize = arr_start;
    for (embed_run.stdout[arr_start..], 0..) |c, i| {
        switch (c) {
            '[' => depth += 1,
            ']' => { depth -= 1; if (depth == 0) { arr_end = arr_start + i + 1; break; } },
            else => {},
        }
    }
    if (arr_end == arr_start) return errJson(req.allocator, "embedding ']' not found", .{});
    const embedding_json = embed_run.stdout[arr_start..arr_end];
    const embed_dim = std.mem.count(u8, embedding_json, ",") + 1; // ≈ 1536

    // ── Step 2: Search EmergentDB ─────────────────────────────────────────────
    const search_req = std.fmt.allocPrint(req.allocator,
        \\{{"vector":{s},"k":5,"namespace":"budget2026","include_metadata":true}}
    , .{embedding_json}) catch return mer.internalError("alloc");
    { const f = std.fs.createFileAbsolute("/tmp/merjs_search.json", .{})
          catch return mer.internalError("tmpfile");
      f.writeAll(search_req) catch { f.close(); return mer.internalError("tmpwrite"); };
      f.close(); }

    const search_run = std.process.Child.run(.{
        .allocator = req.allocator,
        .max_output_bytes = 512 * 1024,
        .argv = &.{ "curl", "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", emergent_auth,
            "-H", "User-Agent: EmergentDB-Ingest/1.0",
            "-d", "@/tmp/merjs_search.json",
            "https://api.emergentdb.com/vectors/search" },
    }) catch |err| return errJson(req.allocator, "curl search failed: {}", .{err});

    // metadata may be absent (default .{}) and may use "text" or "title" for chunk content
    const Meta = struct { text: []const u8 = "", title: []const u8 = "" };
    const Item = struct { id: u64, score: f64, metadata: Meta = .{} };
    const SearchResp = struct { results: []Item };

    const search_parsed = std.json.parseFromSlice(SearchResp, req.allocator,
        search_run.stdout, .{ .ignore_unknown_fields = true }) catch {
        if (trace) return traceErr(req.allocator, "step2_search", search_req,
            search_run.stdout, "failed to parse EmergentDB response");
        return mer.Response.init(.ok, .json, search_run.stdout);
    };

    if (search_parsed.value.results.len == 0) {
        if (trace) return traceErr(req.allocator, "step2_search", search_req,
            search_run.stdout, "EmergentDB returned 0 results");
        return mer.Response.init(.ok, .json, search_run.stdout);
    }

    // Build context — prefer "text", fall back to "title"
    var context: []const u8 = "";
    for (search_parsed.value.results, 0..) |r, i| {
        const chunk = if (r.metadata.text.len > 0) r.metadata.text else r.metadata.title;
        if (chunk.len == 0) continue;
        const sep: []const u8 = if (i > 0) "\n\n---\n\n" else "";
        context = std.fmt.allocPrint(req.allocator, "{s}{s}{s}", .{ context, sep, chunk })
            catch return mer.internalError("alloc");
    }

    // ── Step 3: Chat with gpt-5-nano ─────────────────────────────────────────
    const system_prompt =
        "You are a helpful assistant that answers questions about the FY2026 Budget Statement. " ++
        "Use the provided document context to give accurate, concise answers. " ++
        "Cite relevant figures and policies from the document when applicable.";

    const user_msg = std.fmt.allocPrint(req.allocator,
        "Context from FY2026 Budget Statement:\n{s}\n\nQuestion: {s}",
        .{ context, question }) catch return mer.internalError("alloc");

    var chat_buf: std.io.Writer.Allocating = .init(req.allocator);
    var cjw: std.json.Stringify = .{ .writer = &chat_buf.writer };
    cjw.beginObject()                    catch return mer.internalError("json");
    cjw.objectField("model")             catch return mer.internalError("json");
    cjw.write("gpt-5-nano")              catch return mer.internalError("json");
    cjw.objectField("instructions")      catch return mer.internalError("json");
    cjw.write(system_prompt)             catch return mer.internalError("json");
    cjw.objectField("input")             catch return mer.internalError("json");
    cjw.write(user_msg)                  catch return mer.internalError("json");
    cjw.objectField("max_output_tokens") catch return mer.internalError("json");
    cjw.write(@as(u32, 128000))          catch return mer.internalError("json");
    cjw.endObject()                      catch return mer.internalError("json");
    const chat_req = chat_buf.written();

    { const f = std.fs.createFileAbsolute("/tmp/merjs_chat.json", .{})
          catch return mer.internalError("tmpfile");
      f.writeAll(chat_req) catch { f.close(); return mer.internalError("tmpwrite"); };
      f.close(); }

    const chat_run = std.process.Child.run(.{
        .allocator = req.allocator,
        .max_output_bytes = 512 * 1024,
        .argv = &.{ "curl", "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", openai_auth,
            "-d", "@/tmp/merjs_chat.json",
            "https://api.openai.com/v1/responses" },
    }) catch |err| return errJson(req.allocator, "curl chat failed: {}", .{err});

    // Responses API output array has mixed types:
    //   {"type":"reasoning","summary":[]}            ← no content field
    //   {"type":"message","content":[{"type":"output_text","text":"..."}]}
    const ChatContent = struct { type: []const u8 = "", text: []const u8 = "" };
    const ChatOutput  = struct {
        type:    []const u8 = "",
        content: []ChatContent = &.{},  // default empty — reasoning items have no content
    };
    const ChatResp = struct { output: []ChatOutput };

    const chat_parsed = std.json.parseFromSlice(ChatResp, req.allocator,
        chat_run.stdout, .{ .ignore_unknown_fields = true }) catch {
        if (trace) return traceErr(req.allocator, "step3_chat", chat_req,
            chat_run.stdout, "failed to parse OpenAI Responses API");
        return mer.Response.init(.ok, .json, chat_run.stdout);
    };

    // Find the first "message" output item that has non-empty text
    var answer: []const u8 = "";
    for (chat_parsed.value.output) |out| {
        if (!std.mem.eql(u8, out.type, "message")) continue;
        for (out.content) |c| {
            if (c.text.len > 0) { answer = c.text; break; }
        }
        if (answer.len > 0) break;
    }
    if (answer.len == 0) {
        if (trace) return traceErr(req.allocator, "step3_chat", chat_req,
            chat_run.stdout, "no message output with text found");
        return mer.Response.init(.ok, .json, chat_run.stdout);
    }

    // ── Build response ────────────────────────────────────────────────────────
    var out: std.io.Writer.Allocating = .init(req.allocator);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.beginObject()         catch return mer.internalError("json");
    jw.objectField("answer") catch return mer.internalError("json");
    jw.write(answer)         catch return mer.internalError("json");

    if (trace) {
        jw.objectField("trace")          catch return mer.internalError("json");
        jw.beginObject()                 catch return mer.internalError("json");

        // step1: embed
        jw.objectField("step1_embed")    catch return mer.internalError("json");
        jw.beginObject()                 catch return mer.internalError("json");
        jw.objectField("url")            catch return mer.internalError("json");
        jw.write("POST https://api.openai.com/v1/embeddings") catch return mer.internalError("json");
        jw.objectField("request_body")   catch return mer.internalError("json");
        jw.write(embed_req)              catch return mer.internalError("json");
        jw.objectField("embedding_dim")  catch return mer.internalError("json");
        jw.write(embed_dim)              catch return mer.internalError("json");
        jw.endObject()                   catch return mer.internalError("json");

        // step2: search
        jw.objectField("step2_search")   catch return mer.internalError("json");
        jw.beginObject()                 catch return mer.internalError("json");
        jw.objectField("url")            catch return mer.internalError("json");
        jw.write("POST https://api.emergentdb.com/vectors/search") catch return mer.internalError("json");
        jw.objectField("request_keys")   catch return mer.internalError("json");
        jw.write("{vector[1536],k:5,include_metadata:true}") catch return mer.internalError("json");
        jw.objectField("response")       catch return mer.internalError("json");
        jw.write(search_run.stdout)      catch return mer.internalError("json");
        jw.endObject()                   catch return mer.internalError("json");

        // step3: chat
        jw.objectField("step3_chat")     catch return mer.internalError("json");
        jw.beginObject()                 catch return mer.internalError("json");
        jw.objectField("url")            catch return mer.internalError("json");
        jw.write("POST https://api.openai.com/v1/responses") catch return mer.internalError("json");
        jw.objectField("request_body")   catch return mer.internalError("json");
        jw.write(chat_req)               catch return mer.internalError("json");
        jw.objectField("response_raw")   catch return mer.internalError("json");
        jw.write(chat_run.stdout)        catch return mer.internalError("json");
        jw.endObject()                   catch return mer.internalError("json");

        jw.endObject() catch return mer.internalError("json"); // trace
    }

    jw.endObject() catch return mer.internalError("json");
    return mer.Response.init(.ok, .json, out.written());
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn errJson(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) mer.Response {
    const msg = std.fmt.allocPrint(alloc, fmt, args) catch "error";
    var out: std.io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.beginObject()        catch return mer.internalError("json");
    jw.objectField("error") catch return mer.internalError("json");
    jw.write(msg)           catch return mer.internalError("json");
    jw.endObject()          catch return mer.internalError("json");
    return mer.Response.init(.ok, .json, out.written());
}

fn traceErr(alloc: std.mem.Allocator, step: []const u8, request: []const u8, response: []const u8, msg: []const u8) mer.Response {
    var out: std.io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.beginObject()              catch return mer.internalError("json");
    jw.objectField("error")       catch return mer.internalError("json");
    jw.write(msg)                 catch return mer.internalError("json");
    jw.objectField("failed_step") catch return mer.internalError("json");
    jw.write(step)                catch return mer.internalError("json");
    jw.objectField("request")     catch return mer.internalError("json");
    jw.write(request)             catch return mer.internalError("json");
    jw.objectField("response")    catch return mer.internalError("json");
    jw.write(response)            catch return mer.internalError("json");
    jw.endObject()                catch return mer.internalError("json");
    return mer.Response.init(.ok, .json, out.written());
}
