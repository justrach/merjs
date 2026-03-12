// worker.js — Cloudflare Workers fetch handler for merjs (merlionjs.com).

import merWasm from "./merjs.wasm";
import grepWasm from "./grep.wasm";

let instance = null;
let grepInstance = null;

async function getInstance() {
  if (instance) return instance;
  const mod = await WebAssembly.instantiate(merWasm, {
    env: { memory: new WebAssembly.Memory({ initial: 256 }) },
  });
  instance = mod.exports || mod;
  instance.init();
  return instance;
}

async function getGrepInstance() {
  if (grepInstance) return grepInstance;
  const mod = await WebAssembly.instantiate(grepWasm, {
    env: { memory: new WebAssembly.Memory({ initial: 64 }) },
  });
  grepInstance = mod.exports || mod;
  return grepInstance;
}

const securityHeaders = {
  "strict-transport-security": "max-age=63072000; includeSubDomains; preload",
  "content-security-policy": "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://unpkg.com https://static.cloudflareinsights.com https://fonts.googleapis.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://unpkg.com; font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self' https://api.open-meteo.com https://cloudflareinsights.com; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  "x-frame-options": "DENY",
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  "cross-origin-opener-policy": "same-origin",
  "permissions-policy": "camera=(), microphone=(), geolocation=()",
};

function jsonResp(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", ...securityHeaders },
  });
}

// ── R2 grep search (WASM-powered, no embeddings) ──────────────────────────────

let cachedChunks = null;

async function getChunks(env) {
  if (cachedChunks) return cachedChunks;
  const obj = await env.BUCKET.get("budget2026/all_chunks.json");
  if (!obj) return [];
  cachedChunks = JSON.parse(await obj.text());
  return cachedChunks;
}

// Pack chunk texts into length-prefixed binary for WASM: [u32-LE len][text]...
function packChunks(chunks) {
  const encoder = new TextEncoder();
  const encoded = chunks.map(c => encoder.encode(c.text));
  const totalLen = encoded.reduce((sum, e) => sum + 4 + e.length, 0);
  const buf = new Uint8Array(totalLen);
  let off = 0;
  for (const e of encoded) {
    buf[off] = e.length & 0xff;
    buf[off + 1] = (e.length >> 8) & 0xff;
    buf[off + 2] = (e.length >> 16) & 0xff;
    buf[off + 3] = (e.length >> 24) & 0xff;
    off += 4;
    buf.set(e, off);
    off += e.length;
  }
  return buf;
}

async function grepChunks(chunks, query) {
  const grep = await getGrepInstance();
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  // Write query into WASM memory
  const qBytes = encoder.encode(query);
  const qPtr = grep.get_query_ptr();
  const mem = new Uint8Array(grep.memory.buffer);
  mem.set(qBytes, qPtr);

  // Pack and write chunks into WASM memory
  const packed = packChunks(chunks);
  const cPtr = grep.get_chunks_ptr();
  mem.set(packed, cPtr);

  // Run grep in WASM
  grep.grep(qBytes.length, packed.length);

  // Read results
  const rPtr = grep.get_result_ptr();
  const rLen = grep.get_result_len();
  const resultBytes = new Uint8Array(grep.memory.buffer, rPtr, rLen);
  const results = JSON.parse(decoder.decode(resultBytes));

  // Map back: [[index, score], ...] → chunk objects with score
  return results.map(([idx, score]) => ({ ...chunks[idx], score }));
}

async function handleBudgetAi(request, env) {
  let body;
  try { body = await request.json(); } catch { return jsonResp({ error: "Invalid JSON" }, 400); }
  const question = body?.question;
  if (!question) return jsonResp({ error: "question required" }, 400);

  const openaiKey = env.OPENAI_API_KEY;
  if (!openaiKey) return jsonResp({ error: "OPENAI_API_KEY not set" }, 500);

  // Step 1: Extract search keywords via LLM
  let searchQuery = question;
  try {
    const reformRes = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${openaiKey}` },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        instructions: "Convert the user's question into a short keyword-focused search query (3-7 words, no question words like 'what/how/when'). Include synonyms for budget terms (e.g. spending=expenditure, money=allocation). Return only the keywords, nothing else.",
        input: question,
        max_output_tokens: 30,
      }),
    });
    const reformData = await reformRes.json();
    for (const out of reformData?.output ?? []) {
      if (out.type !== "message") continue;
      for (const c of out.content ?? []) { if (c.text) { searchQuery = c.text.trim(); break; } }
      if (searchQuery !== question) break;
    }
  } catch { /* fall back to raw question */ }

  // Step 2: Grep R2 chunks
  const chunks = await getChunks(env);
  const matched = await grepChunks(chunks, searchQuery);

  let context = "";
  for (const m of matched) {
    if (context) context += "\n\n---\n\n";
    context += `[Page ${m.page}, score ${m.score}] ${m.text}`;
  }

  // Step 3: Answer with LLM
  const systemPrompt =
    "You are a helpful assistant that answers questions about Singapore's FY2026 Budget Statement. " +
    "Use the provided document context to give accurate, concise answers. " +
    "Cite page numbers when possible. " +
    "If the context doesn't contain relevant information, say so clearly.";

  const userMsg = context
    ? `Context from FY2026 Budget (matched by keyword search):\n${context}\n\nQuestion: ${question}`
    : `No relevant sections were found for this question.\n\nQuestion: ${question}`;

  const chatRes = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${openaiKey}` },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      instructions: systemPrompt,
      input: userMsg,
      max_output_tokens: 2048,
    }),
  });
  const chatData = await chatRes.json();

  let answer = "";
  for (const out of chatData?.output ?? []) {
    if (out.type !== "message") continue;
    for (const c of out.content ?? []) { if (c.text) { answer = c.text; break; } }
    if (answer) break;
  }

  if (!answer) return jsonResp({ error: "No answer from AI", raw: chatData });
  return jsonResp({
    answer,
    method: "r2-grep",
    chunks_searched: chunks.length,
    chunks_matched: matched.length,
    keywords: searchQuery,
  });
}

async function handleBudgetSuggestions(request, env) {
  let body;
  try { body = await request.json(); } catch { return jsonResp({ suggestions: [] }); }
  const { question, answer = "" } = body ?? {};
  if (!question) return jsonResp({ suggestions: [] });

  const openaiKey = env.OPENAI_API_KEY;
  if (!openaiKey) return jsonResp({ suggestions: [] });

  const prompt = answer
    ? `User asked about Singapore FY2026 Budget: "${question}"\nAnswer: "${answer.slice(0, 400)}"\n\nGenerate exactly 3 short follow-up questions (under 12 words each). Return ONLY a JSON array of 3 strings.`
    : `User is asking about Singapore FY2026 Budget: "${question}"\n\nGenerate exactly 3 related questions. Return ONLY a JSON array of 3 strings.`;

  const res = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${openaiKey}` },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      instructions: "You generate follow-up questions. Return only a JSON array of strings.",
      input: prompt,
      max_output_tokens: 256,
    }),
  });
  const data = await res.json();

  let text = "";
  for (const out of data?.output ?? []) {
    if (out.type !== "message") continue;
    for (const c of out.content ?? []) { if (c.text) { text = c.text; break; } }
    if (text) break;
  }

  if (!text) return jsonResp({ suggestions: [] });
  const start = text.indexOf("[");
  const end = text.lastIndexOf("]");
  if (start === -1 || end <= start) return jsonResp({ suggestions: [] });
  try {
    return jsonResp({ suggestions: JSON.parse(text.slice(start, end + 1)) });
  } catch {
    return jsonResp({ suggestions: [] });
  }
}

// ── Main fetch handler ────────────────────────────────────────────────────────

export default {
  async fetch(request, env, _ctx) {
    const url = new URL(request.url);

    // JS-handled API routes (wasm32 can't do network/clock)
    if (url.pathname === "/api/time") {
      const ts = Math.floor(Date.now() / 1000);
      return jsonResp({ timestamp: ts, unit: "unix_seconds", iso: new Date().toISOString() });
    }
    if (url.pathname === "/api/budget-ai" && request.method === "POST")
      return handleBudgetAi(request, env);
    if (url.pathname === "/api/budget-suggestions" && request.method === "POST")
      return handleBudgetSuggestions(request, env);

    // WASM-handled routes
    const wasm = await getInstance();
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    const input = `${request.method} ${url.pathname}`;
    const encoded = encoder.encode(input);

    const ptr = wasm.alloc(encoded.length);
    if (!ptr) return new Response("WASM alloc failed", { status: 500 });

    const mem = new Uint8Array(wasm.memory.buffer);
    mem.set(encoded, ptr);

    const resPtr = wasm.handle(ptr, encoded.length);
    wasm.dealloc(ptr, encoded.length);

    if (!resPtr) return new Response("Not Found", { status: 404 });

    const resLen = wasm.response_len();
    const resBuf = new Uint8Array(wasm.memory.buffer, resPtr, resLen);

    const status = resBuf[0] | (resBuf[1] << 8);
    const ctLen = resBuf[2] | (resBuf[3] << 8);
    const contentType = decoder.decode(resBuf.slice(4, 4 + ctLen));
    const body = resBuf.slice(4 + ctLen);

    return new Response(body, {
      status,
      headers: { "content-type": contentType, ...securityHeaders },
    });
  },
};
