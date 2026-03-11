const std = @import("std");
const mer = @import("mer");

/// Budget 2026 AI — Agentic RAG pipeline:
///   1. AI formulates search query via tool calling (search_budget tool)
///   2. Embed query → search EmergentDB → return results to AI
///   3. AI refines query or generates final answer (up to 3 search rounds)
///
/// POST body: {"question": "...", "trace": true}
/// trace=true returns search_rounds array for debugging.
const SEARCH_TOOL =
    \\{"type":"function","name":"search_budget","description":"Search the FY2026 Singapore Budget Statement for relevant passages. Use a specific, keyword-focused query such as 'CDC vouchers households', 'fiscal surplus GDP percentage', or 'corporate income tax rebate'. Avoid question-style queries.","parameters":{"type":"object","properties":{"query":{"type":"string","description":"Keyword-focused search query (not a question)"}},"required":["query"]}}
;

const system_prompt =
    "You are a helpful assistant that answers questions about the FY2026 Singapore Budget Statement. " ++
    "You have access to a search tool to find relevant passages from the document. " ++
    "Use specific, keyword-focused queries (not questions) to find the best passages. " ++
    "After searching, give accurate, concise answers citing relevant figures and policies. " ++
    "If search results are insufficient, answer from general knowledge about Singapore's FY2026 Budget " ++
    "but clearly indicate you are not drawing from the retrieved document.";

// ── Structs ───────────────────────────────────────────────────────────────────

const ChatContent = struct { type: []const u8 = "", text: []const u8 = "" };
const OutputItem = struct {
    type: []const u8 = "",
    content: []ChatContent = &.{},
    id: []const u8 = "",
    call_id: []const u8 = "",
    name: []const u8 = "",
    arguments: []const u8 = "",
};
const RespOut = struct { output: []OutputItem };
const SearchArgs = struct { query: []const u8 = "" };
const Meta = struct { text: []const u8 = "", title: []const u8 = "" };
const SearchItem = struct { id: u64 = 0, score: f64 = 0, metadata: Meta = .{} };
const SearchResp = struct { results: []SearchItem };

const ToolRound = struct {
    query: []const u8,
    id: []const u8,
    call_id: []const u8,
    arguments: []const u8,
    result: []const u8,
    reasoning_id: []const u8, // id of preceding reasoning item ("rs_..."), or ""
};

// ── Main handler ──────────────────────────────────────────────────────────────

pub fn render(req: mer.Request) mer.Response {
    // wasm32-freestanding has no process/fs — intercepted by worker.js on CF Workers
    if (comptime @import("builtin").target.cpu.arch == .wasm32)
        return mer.json("{\"error\":\"AI route handled by edge worker\"}");
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

    // Per-request tmpfile names using milliTimestamp (i64, concurrent-request-safe)
    const ts = std.time.milliTimestamp();
    const chat_tmp   = std.fmt.allocPrint(req.allocator, "/tmp/merjs_chat_{d}.json",   .{ts}) catch return mer.internalError("alloc");
    const search_tmp = std.fmt.allocPrint(req.allocator, "/tmp/merjs_search_{d}.json", .{ts}) catch return mer.internalError("alloc");

    // ── Agentic loop (max 2 search rounds, then forced final answer) ──────────
    var rounds: std.ArrayList(ToolRound) = .{};
    var final_answer: []const u8 = "";
    var round: u32 = 0;
    const MAX_SEARCH: u32 = 1; // max tool-calling rounds; then synthesize from context


    while (round < MAX_SEARCH and final_answer.len == 0) : (round += 1) {
        // Build the Responses API request
        var chat_buf: std.io.Writer.Allocating = .init(req.allocator);
        var cjw: std.json.Stringify = .{ .writer = &chat_buf.writer };

        cjw.beginObject()               catch return mer.internalError("json");
        cjw.objectField("model")        catch return mer.internalError("json");
        cjw.write("gpt-5-nano")         catch return mer.internalError("json");
        cjw.objectField("instructions") catch return mer.internalError("json");
        cjw.write(system_prompt)        catch return mer.internalError("json");

        // input: round 0 = string, round 1+ = array replaying history
        cjw.objectField("input") catch return mer.internalError("json");
        if (round == 0) {
            cjw.write(question) catch return mer.internalError("json");
        } else {
            cjw.beginArray() catch return mer.internalError("json");

            // User message
            cjw.beginObject()                catch return mer.internalError("json");
            cjw.objectField("type")          catch return mer.internalError("json");
            cjw.write("message")             catch return mer.internalError("json");
            cjw.objectField("role")          catch return mer.internalError("json");
            cjw.write("user")                catch return mer.internalError("json");
            cjw.objectField("content")       catch return mer.internalError("json");
            cjw.write(question)              catch return mer.internalError("json");
            cjw.endObject()                  catch return mer.internalError("json");

            // Replay all prior rounds: reasoning? + function_call + function_call_output
            for (rounds.items) |r| {
                // reasoning item (OpenAI requires it before its function_call)
                if (r.reasoning_id.len > 0) {
                    cjw.beginObject()                    catch return mer.internalError("json");
                    cjw.objectField("type")              catch return mer.internalError("json");
                    cjw.write("reasoning")               catch return mer.internalError("json");
                    cjw.objectField("id")                catch return mer.internalError("json");
                    cjw.write(r.reasoning_id)            catch return mer.internalError("json");
                    cjw.objectField("summary")           catch return mer.internalError("json");
                    cjw.beginArray()                     catch return mer.internalError("json");
                    cjw.endArray()                       catch return mer.internalError("json");
                    cjw.endObject()                      catch return mer.internalError("json");
                }

                // function_call (assistant)
                cjw.beginObject()                    catch return mer.internalError("json");
                cjw.objectField("type")              catch return mer.internalError("json");
                cjw.write("function_call")           catch return mer.internalError("json");
                cjw.objectField("id")                catch return mer.internalError("json");
                cjw.write(r.id)                      catch return mer.internalError("json");
                cjw.objectField("call_id")           catch return mer.internalError("json");
                cjw.write(r.call_id)                 catch return mer.internalError("json");
                cjw.objectField("name")              catch return mer.internalError("json");
                cjw.write("search_budget")           catch return mer.internalError("json");
                cjw.objectField("arguments")         catch return mer.internalError("json");
                cjw.write(r.arguments)               catch return mer.internalError("json");
                cjw.endObject()                      catch return mer.internalError("json");

                // function_call_output (tool result)
                cjw.beginObject()                    catch return mer.internalError("json");
                cjw.objectField("type")              catch return mer.internalError("json");
                cjw.write("function_call_output")    catch return mer.internalError("json");
                cjw.objectField("call_id")           catch return mer.internalError("json");
                cjw.write(r.call_id)                 catch return mer.internalError("json");
                cjw.objectField("output")            catch return mer.internalError("json");
                cjw.write(r.result)                  catch return mer.internalError("json");
                cjw.endObject()                      catch return mer.internalError("json");
            }

            cjw.endArray() catch return mer.internalError("json");
        }


        // tools: round 0 → required, round 1+ → auto
        cjw.objectField("tools") catch return mer.internalError("json");
        cjw.beginWriteRaw()      catch return mer.internalError("json");
        cjw.writer.writeAll("[" ++ SEARCH_TOOL ++ "]") catch return mer.internalError("json");
        cjw.endWriteRaw();
        cjw.objectField("tool_choice") catch return mer.internalError("json");
        if (round == 0) {
            cjw.write("required") catch return mer.internalError("json");
        } else {
            cjw.write("auto") catch return mer.internalError("json");
        }


        cjw.objectField("max_output_tokens") catch return mer.internalError("json");
        cjw.write(@as(u32, 128000))          catch return mer.internalError("json");
        cjw.endObject()                      catch return mer.internalError("json");


        const chat_req = chat_buf.written();
        const chat_at  = std.fmt.allocPrint(req.allocator, "@{s}", .{chat_tmp})
            catch return mer.internalError("alloc");

        // Write to per-PID tmpfile (concurrent-request-safe)
        {
            const f = std.fs.createFileAbsolute(chat_tmp, .{})
                catch return mer.internalError("tmpfile");
            f.writeAll(chat_req) catch { f.close(); return mer.internalError("tmpwrite"); };
            f.close();
        }

        const chat_run = std.process.Child.run(.{
            .allocator = req.allocator,
            .max_output_bytes = 512 * 1024,
            .argv = &.{ "curl", "-s", "-X", "POST",
                "-H", "Content-Type: application/json",
                "-H", openai_auth,
                "-d", chat_at,
                "https://api.openai.com/v1/responses" },
        }) catch |err| return errJson(req.allocator, "curl chat failed: {}", .{err});

        const chat_parsed = std.json.parseFromSlice(RespOut, req.allocator,
            chat_run.stdout, .{ .ignore_unknown_fields = true }) catch {
            return errJson(req.allocator, "parse OpenAI response failed: {s}",
                .{chat_run.stdout[0..@min(400, chat_run.stdout.len)]});
        };

        // Process output items — track reasoning_id so we can replay it
        var reasoning_id: []const u8 = "";
        for (chat_parsed.value.output) |item| {
            if (std.mem.eql(u8, item.type, "reasoning")) {
                reasoning_id = item.id;
                continue;
            }

            if (std.mem.eql(u8, item.type, "function_call") and
                std.mem.eql(u8, item.name, "search_budget"))
            {
                // Parse query from arguments JSON
                const args_parsed = std.json.parseFromSlice(SearchArgs, req.allocator,
                    item.arguments, .{ .ignore_unknown_fields = true }) catch {
                    return errJson(req.allocator, "parse search_budget args failed: {s}", .{item.arguments});
                };
                const query = args_parsed.value.query;

                // Execute embed + search
                const search_result = embedAndSearch(req.allocator, query, openai_auth, emergent_auth, search_tmp)
                    catch |err| return errJson(req.allocator, "embedAndSearch failed: {}", .{err});

                rounds.append(req.allocator, .{
                    .query        = query,
                    .id           = item.id,
                    .call_id      = item.call_id,
                    .arguments    = item.arguments,
                    .result       = search_result,
                    .reasoning_id = reasoning_id,
                }) catch return mer.internalError("alloc");

                break; // process one function_call per round
            }

            if (std.mem.eql(u8, item.type, "message")) {
                for (item.content) |c| {
                    if (c.text.len > 0) {
                        final_answer = c.text;
                        break;
                    }
                }
            }
        }
    }

    // ── Synthesis pass (if tool rounds didn't produce a direct answer) ─────────
    if (final_answer.len == 0) {
        // Collect all retrieved passages into a single context string
        var context: []const u8 = "";
        for (rounds.items) |r| {
            if (r.result.len > 0) {
                context = std.fmt.allocPrint(req.allocator, "{s}\n\n[Search: \"{s}\"]\n{s}",
                    .{ context, r.query, r.result }) catch context;
            }
        }

        const user_msg = if (context.len == 0)
            std.fmt.allocPrint(req.allocator,
                "No relevant document passages were found. Answer from general knowledge about Singapore's FY2026 Budget, " ++
                "and clearly state you are not drawing from retrieved documents.\n\nQuestion: {s}", .{question})
                catch return mer.internalError("alloc")
        else
            std.fmt.allocPrint(req.allocator,
                "Context from FY2026 Budget Statement:\n{s}\n\nQuestion: {s}", .{ context, question })
                catch return mer.internalError("alloc");

        var syn_buf: std.io.Writer.Allocating = .init(req.allocator);
        var sjw: std.json.Stringify = .{ .writer = &syn_buf.writer };
        sjw.beginObject()               catch return mer.internalError("json");
        sjw.objectField("model")        catch return mer.internalError("json");
        sjw.write("gpt-5-nano")         catch return mer.internalError("json");
        sjw.objectField("instructions") catch return mer.internalError("json");
        sjw.write("You are a helpful assistant that answers questions about the FY2026 Singapore Budget Statement. " ++
            "Use the provided document context to give accurate, concise answers. " ++
            "Cite relevant figures and policies when applicable.")
            catch return mer.internalError("json");
        sjw.objectField("input")             catch return mer.internalError("json");
        sjw.write(user_msg)                  catch return mer.internalError("json");
        sjw.objectField("max_output_tokens") catch return mer.internalError("json");
        sjw.write(@as(u32, 128000))          catch return mer.internalError("json");
        sjw.endObject()                      catch return mer.internalError("json");

        const syn_req = syn_buf.written();
        {
            const f = std.fs.createFileAbsolute(chat_tmp, .{})
                catch return mer.internalError("tmpfile");
            f.writeAll(syn_req) catch { f.close(); return mer.internalError("tmpwrite"); };
            f.close();
        }
        const syn_at = std.fmt.allocPrint(req.allocator, "@{s}", .{chat_tmp})
            catch return mer.internalError("alloc");

        const syn_run = std.process.Child.run(.{
            .allocator = req.allocator,
            .max_output_bytes = 512 * 1024,
            .argv = &.{ "curl", "-s", "-X", "POST",
                "-H", "Content-Type: application/json",
                "-H", openai_auth,
                "-d", syn_at,
                "https://api.openai.com/v1/responses" },
        }) catch |err| return errJson(req.allocator, "curl synthesis failed: {}", .{err});

        const syn_parsed = std.json.parseFromSlice(RespOut, req.allocator,
            syn_run.stdout, .{ .ignore_unknown_fields = true }) catch {
            return errJson(req.allocator, "parse synthesis response failed: {s}",
                .{syn_run.stdout[0..@min(400, syn_run.stdout.len)]});
        };

        for (syn_parsed.value.output) |item| {
            if (!std.mem.eql(u8, item.type, "message")) continue;
            for (item.content) |c| {
                if (c.text.len > 0) { final_answer = c.text; break; }
            }
            if (final_answer.len > 0) break;
        }

        if (final_answer.len == 0)
            return errJson(req.allocator, "no answer from synthesis pass", .{});
    }


    // ── Build response ────────────────────────────────────────────────────────
    var out: std.io.Writer.Allocating = .init(req.allocator);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.beginObject()                      catch return mer.internalError("json");
    jw.objectField("answer")              catch return mer.internalError("json");
    jw.write(final_answer)                catch return mer.internalError("json");
    jw.objectField("searches_performed")  catch return mer.internalError("json");
    jw.write(@as(u32, @intCast(rounds.items.len))) catch return mer.internalError("json");

    if (trace) {
        jw.objectField("search_rounds") catch return mer.internalError("json");
        jw.beginArray()                 catch return mer.internalError("json");
        for (rounds.items) |r| {
            jw.beginObject()             catch return mer.internalError("json");
            jw.objectField("query")      catch return mer.internalError("json");
            jw.write(r.query)            catch return mer.internalError("json");
            jw.objectField("result")     catch return mer.internalError("json");
            jw.write(r.result)           catch return mer.internalError("json");
            jw.endObject()               catch return mer.internalError("json");
        }
        jw.endArray() catch return mer.internalError("json");
    }

    jw.endObject() catch return mer.internalError("json");
    return mer.Response.init(.ok, .json, out.written());
}

// ── Embed + Search helper ─────────────────────────────────────────────────────

fn embedAndSearch(
    allocator: std.mem.Allocator,
    query: []const u8,
    openai_auth: []const u8,
    emergent_auth: []const u8,
    search_tmp: []const u8,
) ![]const u8 {
    // 1. Embed query
    var embed_buf: std.io.Writer.Allocating = .init(allocator);
    var ejw: std.json.Stringify = .{ .writer = &embed_buf.writer };
    ejw.beginObject()                    catch return error.JsonError;
    ejw.objectField("model")             catch return error.JsonError;
    ejw.write("text-embedding-3-small")  catch return error.JsonError;
    ejw.objectField("input")             catch return error.JsonError;
    ejw.write(query)                     catch return error.JsonError;
    ejw.endObject()                      catch return error.JsonError;

    const embed_run = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 512 * 1024,
        .argv = &.{ "curl", "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", openai_auth,
            "-d", embed_buf.written(),
            "https://api.openai.com/v1/embeddings" },
    });

    // Extract embedding array
    const embed_prefix = "\"embedding\":";
    const pfx = std.mem.indexOf(u8, embed_run.stdout, embed_prefix) orelse
        return error.EmbeddingNotFound;
    var arr_start = pfx + embed_prefix.len;
    while (arr_start < embed_run.stdout.len and embed_run.stdout[arr_start] != '[')
        arr_start += 1;
    if (arr_start >= embed_run.stdout.len) return error.EmbeddingBracketNotFound;

    var depth: usize = 0;
    var arr_end: usize = arr_start;
    for (embed_run.stdout[arr_start..], 0..) |c, i| {
        switch (c) {
            '[' => depth += 1,
            ']' => { depth -= 1; if (depth == 0) { arr_end = arr_start + i + 1; break; } },
            else => {},
        }
    }
    if (arr_end == arr_start) return error.EmbeddingEndNotFound;
    const embedding_json = embed_run.stdout[arr_start..arr_end];

    // 2. Search EmergentDB
    const search_req = try std.fmt.allocPrint(allocator,
        \\{{"vector":{s},"k":10,"namespace":"budget2026v2","include_metadata":true}}
    , .{embedding_json});

    const search_at = try std.fmt.allocPrint(allocator, "@{s}", .{search_tmp});
    {
        const f = try std.fs.createFileAbsolute(search_tmp, .{});
        f.writeAll(search_req) catch { f.close(); return error.TmpWriteFailed; };
        f.close();
    }

    const search_run = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 512 * 1024,
        .argv = &.{ "curl", "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", emergent_auth,
            "-H", "User-Agent: EmergentDB-Ingest/1.0",
            "-d", search_at,
            "https://api.emergentdb.com/vectors/search" },
    });

    const search_parsed = std.json.parseFromSlice(SearchResp, allocator,
        search_run.stdout, .{ .ignore_unknown_fields = true }) catch {
        // Return raw response so AI can see the error
        return search_run.stdout;
    };

    // Format results as numbered passages
    var result: []const u8 = "";
    var count: usize = 0;
    for (search_parsed.value.results) |r| {
        if (r.score < 0.2) continue;
        const chunk = if (r.metadata.text.len > 0) r.metadata.text else r.metadata.title;
        if (chunk.len == 0) continue;
        count += 1;
        result = try std.fmt.allocPrint(allocator, "{s}[{d}] score={d:.2}\n{s}\n\n",
            .{ result, count, r.score, chunk });
    }

    if (count == 0) {
        return try std.fmt.allocPrint(allocator,
            "No relevant passages found (top score was below 0.2 threshold). " ++
            "Try a different keyword query.", .{});
    }

    return result;
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
