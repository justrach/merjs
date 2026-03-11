const std = @import("std");
const mer = @import("mer");

/// POST body: {"question": "...", "answer": "..."}
/// Returns: {"suggestions": ["q1", "q2", "q3"]}
pub fn render(req: mer.Request) mer.Response {
    // wasm32-freestanding has no process/fs — intercepted by worker.js on CF Workers
    if (comptime @import("builtin").target.cpu.arch == .wasm32)
        return mer.json("{\"suggestions\":[]}");
    const openai_key = mer.env("OPENAI_API_KEY") orelse
        return mer.json("{\"suggestions\":[]}");

    if (req.body.len == 0) return mer.json("{\"suggestions\":[]}");

    const Req = struct { question: []const u8, answer: []const u8 = "" };
    const body = std.json.parseFromSlice(Req, req.allocator, req.body,
        .{ .ignore_unknown_fields = true }) catch return mer.json("{\"suggestions\":[]}");

    const openai_auth = std.fmt.allocPrint(req.allocator,
        "Authorization: Bearer {s}", .{openai_key}) catch return mer.json("{\"suggestions\":[]}");

    const prompt = if (body.value.answer.len > 0)
        std.fmt.allocPrint(req.allocator,
            "A user asked about Singapore's FY2026 Budget: \"{s}\"\n" ++
            "The answer was: \"{s}\"\n\n" ++
            "Generate exactly 3 short follow-up questions they might want to ask next. " ++
            "Each question should be concise (under 12 words) and explore a different aspect. " ++
            "Return ONLY a raw JSON array of 3 strings — no markdown, no explanation. " ++
            "Example format: [\"Question one?\",\"Question two?\",\"Question three?\"]",
            .{ body.value.question, body.value.answer[0..@min(400, body.value.answer.len)] })
        else
        std.fmt.allocPrint(req.allocator,
            "A user is asking about Singapore's FY2026 Budget: \"{s}\"\n\n" ++
            "Generate exactly 3 short follow-up questions they might want to explore next. " ++
            "Each question should be concise (under 12 words) and cover a different related aspect. " ++
            "Return ONLY a raw JSON array of 3 strings — no markdown, no explanation. " ++
            "Example format: [\"Question one?\",\"Question two?\",\"Question three?\"]",
            .{body.value.question});
    const resolved_prompt = prompt catch return mer.json("{\"suggestions\":[]}");

    var buf: std.io.Writer.Allocating = .init(req.allocator);
    var jw: std.json.Stringify = .{ .writer = &buf.writer };
    jw.beginObject()               catch return mer.json("{\"suggestions\":[]}");
    jw.objectField("model")        catch return mer.json("{\"suggestions\":[]}");
    jw.write("gpt-5-nano")         catch return mer.json("{\"suggestions\":[]}");
    jw.objectField("instructions") catch return mer.json("{\"suggestions\":[]}");
    jw.write("You generate follow-up questions. Return only a JSON array of strings.")
        catch return mer.json("{\"suggestions\":[]}");
    jw.objectField("input")             catch return mer.json("{\"suggestions\":[]}");
    jw.write(resolved_prompt)           catch return mer.json("{\"suggestions\":[]}");
    jw.objectField("max_output_tokens") catch return mer.json("{\"suggestions\":[]}");
    jw.write(@as(u32, 1024))            catch return mer.json("{\"suggestions\":[]}");
    jw.endObject()                      catch return mer.json("{\"suggestions\":[]}");

    const ts = std.time.milliTimestamp();
    const tmp = std.fmt.allocPrint(req.allocator, "/tmp/merjs_sug_{d}.json", .{ts})
        catch return mer.json("{\"suggestions\":[]}");
    const tmp_at = std.fmt.allocPrint(req.allocator, "@{s}", .{tmp})
        catch return mer.json("{\"suggestions\":[]}");

    {
        const f = std.fs.createFileAbsolute(tmp, .{}) catch return mer.json("{\"suggestions\":[]}");
        f.writeAll(buf.written()) catch { f.close(); return mer.json("{\"suggestions\":[]}"); };
        f.close();
    }

    const run = std.process.Child.run(.{
        .allocator = req.allocator,
        .max_output_bytes = 64 * 1024,
        .argv = &.{ "curl", "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", openai_auth,
            "-d", tmp_at,
            "https://api.openai.com/v1/responses" },
    }) catch return mer.json("{\"suggestions\":[]}");

    // Extract text from Responses API output
    const ChatContent = struct { type: []const u8 = "", text: []const u8 = "" };
    const OutputItem = struct {
        type: []const u8 = "",
        content: []ChatContent = &.{},
    };
    const Resp = struct { output: []OutputItem };

    const parsed = std.json.parseFromSlice(Resp, req.allocator,
        run.stdout, .{ .ignore_unknown_fields = true })
        catch return mer.json("{\"suggestions\":[]}");

    var text: []const u8 = "";
    for (parsed.value.output) |item| {
        if (!std.mem.eql(u8, item.type, "message")) continue;
        for (item.content) |c| {
            if (c.text.len > 0) { text = c.text; break; }
        }
        if (text.len > 0) break;
    }
    if (text.len == 0) return mer.json("{\"suggestions\":[]}");

    // Find the JSON array in the response (model may add surrounding text)
    const arr_start = std.mem.indexOf(u8, text, "[") orelse
        return mer.json("{\"suggestions\":[]}");
    const arr_end = std.mem.lastIndexOf(u8, text, "]") orelse
        return mer.json("{\"suggestions\":[]}");
    if (arr_end <= arr_start) return mer.json("{\"suggestions\":[]}");
    const arr_json = text[arr_start .. arr_end + 1];

    // Build {"suggestions": <arr_json>} by splicing the raw array in
    const resp = std.fmt.allocPrint(req.allocator, "{{\"suggestions\":{s}}}", .{arr_json})
        catch return mer.json("{\"suggestions\":[]}");
    return mer.Response.init(.ok, .json, resp);
}
