// grep.zig — WASM grep engine for sandbox retrieval.
// Keyword frequency search over text chunks. No embeddings, no vector DB.
// JS packs chunk texts as length-prefixed entries, WASM scores them.

const std = @import("std");

// ── Static buffers (JS writes/reads via WASM memory) ───────────────────────
var query_buf: [4096]u8 = undefined;
var chunks_buf: [1024 * 1024]u8 = undefined; // 1MB
var result_buf: [8192]u8 = undefined;
var result_len: u32 = 0;

export fn get_query_ptr() [*]u8 {
    return &query_buf;
}
export fn get_chunks_ptr() [*]u8 {
    return &chunks_buf;
}
export fn get_result_ptr() [*]const u8 {
    return &result_buf;
}
export fn get_result_len() u32 {
    return result_len;
}

// ── Stopwords ──────────────────────────────────────────────────────────────
fn isStopword(w: []const u8) bool {
    const stops = [_][]const u8{
        "the",   "and",    "for",  "are",  "was",  "were", "been", "have", "has",
        "had",   "not",    "but",  "with", "from", "this", "that", "its",  "which",
        "who",   "how",    "much", "many", "what", "does", "did",  "will", "would",
        "could", "should",
    };
    for (stops) |s| {
        if (std.mem.eql(u8, w, s)) return true;
    }
    return false;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// Case-insensitive occurrence count of needle in haystack.
fn countHits(haystack: []const u8, needle: []const u8) u32 {
    if (needle.len == 0 or needle.len > haystack.len) return 0;
    var count: u32 = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        var ok = true;
        for (0..needle.len) |j| {
            if (toLower(haystack[i + j]) != needle[j]) {
                ok = false;
                break;
            }
        }
        if (ok) {
            count += 1;
            i += needle.len;
        } else {
            i += 1;
        }
    }
    return count;
}

// ── Main grep function ─────────────────────────────────────────────────────
// Input format for chunks_buf: repeated [u32-LE length][text bytes]
// Writes JSON to result_buf: [[chunk_index, score], ...]

const TOP_N = 8;
const MAX_KW = 16;

export fn grep(q_len: u32, c_len: u32) void {
    const query = query_buf[0..q_len];
    const chunks = chunks_buf[0..c_len];

    // ── Extract keywords (lowercase, >2 chars, not stopword) ───────────
    var kw_bufs: [MAX_KW][64]u8 = undefined;
    var kw_lens: [MAX_KW]usize = [_]usize{0} ** MAX_KW;
    var nkw: usize = 0;

    var start: usize = 0;
    var qi: usize = 0;
    while (qi <= query.len) : (qi += 1) {
        const at_end = qi == query.len;
        const is_space = !at_end and query[qi] == ' ';
        if (is_space or at_end) {
            const wlen = qi - start;
            if (wlen > 2 and wlen < 64 and nkw < MAX_KW) {
                for (0..wlen) |j| {
                    kw_bufs[nkw][j] = toLower(query[start + j]);
                }
                if (!isStopword(kw_bufs[nkw][0..wlen])) {
                    kw_lens[nkw] = wlen;
                    nkw += 1;
                }
            }
            start = qi + 1;
        }
    }

    // ── Score chunks ───────────────────────────────────────────────────
    const Entry = struct { index: u32, score: u32 };
    var top: [TOP_N]Entry = [_]Entry{.{ .index = 0, .score = 0 }} ** TOP_N;

    var pos: usize = 0;
    var idx: u32 = 0;
    while (pos + 4 <= chunks.len) {
        const tlen = @as(u32, chunks[pos]) |
            (@as(u32, chunks[pos + 1]) << 8) |
            (@as(u32, chunks[pos + 2]) << 16) |
            (@as(u32, chunks[pos + 3]) << 24);
        pos += 4;
        if (pos + tlen > chunks.len) break;

        const text = chunks[pos .. pos + tlen];
        pos += tlen;

        var score: u32 = 0;
        for (0..nkw) |ki| {
            score += countHits(text, kw_bufs[ki][0..kw_lens[ki]]);
        }

        if (score > 0) {
            // Replace lowest entry if this score is higher
            var min_i: usize = 0;
            for (1..TOP_N) |i| {
                if (top[i].score < top[min_i].score) min_i = i;
            }
            if (score > top[min_i].score) {
                top[min_i] = .{ .index = idx, .score = score };
            }
        }
        idx += 1;
    }

    // Sort descending (bubble, 8 elements)
    for (0..TOP_N) |_| {
        for (0..TOP_N - 1) |i| {
            if (top[i].score < top[i + 1].score) {
                const tmp = top[i];
                top[i] = top[i + 1];
                top[i + 1] = tmp;
            }
        }
    }

    // ── Write JSON result ──────────────────────────────────────────────
    var out = std.io.fixedBufferStream(&result_buf);
    const w = out.writer();
    w.writeByte('[') catch return;
    var first = true;
    for (top) |t| {
        if (t.score == 0) continue;
        if (!first) w.writeByte(',') catch return;
        w.print("[{d},{d}]", .{ t.index, t.score }) catch return;
        first = false;
    }
    w.writeByte(']') catch return;
    result_len = @intCast(out.pos);
}
