// worker.js — Cloudflare Workers fetch handler for merjs.
// Static assets from public/ are served automatically by Wrangler [assets].
// This worker handles dynamic routes via the merjs WASM module.

import merWasm from "./merjs.wasm";

let instance = null;

async function getInstance() {
  if (instance) return instance;
  const mod = await WebAssembly.instantiate(merWasm, {
    env: { memory: new WebAssembly.Memory({ initial: 256 }) },
  });
  instance = mod.exports || mod;
  instance.init();
  return instance;
}

const securityHeaders = {
  "strict-transport-security": "max-age=63072000; includeSubDomains; preload",
  "content-security-policy": "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://unpkg.com https://static.cloudflareinsights.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://unpkg.com; font-src https://fonts.gstatic.com; img-src 'self' data: https://*.basemaps.cartocdn.com https://*.tile.openstreetmap.org; connect-src 'self' https://api.open-meteo.com https://api-open.data.gov.sg https://cloudflareinsights.com; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  "x-frame-options": "DENY",
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  "cross-origin-opener-policy": "same-origin",
  "permissions-policy": "camera=(), microphone=(), geolocation=()",
};

// Track whether env bindings have been injected into the WASM module.
let envInjected = false;

function injectEnv(wasm, env) {
  if (envInjected || !wasm.__mer_set_env) return;
  envInjected = true;
  const enc = new TextEncoder();
  for (const [key, val] of Object.entries(env)) {
    if (typeof val !== "string") continue;
    const kb = enc.encode(key);
    const vb = enc.encode(val);
    const kp = wasm.alloc(kb.length);
    const vp = wasm.alloc(vb.length);
    if (!kp || !vp) continue;
    const mem = new Uint8Array(wasm.memory.buffer);
    mem.set(kb, kp);
    mem.set(vb, vp);
    wasm.__mer_set_env(kp, kb.length, vp, vb.length);
    // Originals freed here — Zig already copied into its string_buf.
    wasm.dealloc(kp, kb.length);
    wasm.dealloc(vp, vb.length);
  }
}

// ── AI route handlers (JS-native — wasm32 can't do process/fs/network) ────────

async function handleAi(request, env) {
  let body;
  try { body = await request.json(); } catch { return jsonResp({ error: "Invalid JSON" }, 400); }
  const question = body?.question;
  if (!question) return jsonResp({ error: "question required" }, 400);

  const openaiKey = env.OPENAI_API_KEY;
  const emergentKey = env.EMERGENT_API_KEY;
  if (!openaiKey) return jsonResp({ error: "OPENAI_API_KEY not set" });
  if (!emergentKey) return jsonResp({ error: "EMERGENT_API_KEY not set" });
  // Step 1: Reformulate question into keyword search query (improves retrieval)
  let searchQuery = question;
  try {
    const reformRes = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${openaiKey}` },
      body: JSON.stringify({
        model: "gpt-5-nano",
        instructions: "Convert the user's question into a short keyword-focused search query (3-7 words, no question words like 'what/how/when'). Return only the keywords, nothing else.",
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

  // Step 2: Embed search query
  const embedRes = await fetch("https://api.openai.com/v1/embeddings", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${openaiKey}` },
    body: JSON.stringify({ model: "text-embedding-3-small", input: searchQuery }),
  });
  const embedData = await embedRes.json();
  const embedding = embedData?.data?.[0]?.embedding;
  if (!embedding) return jsonResp({ error: "Embedding failed: " + JSON.stringify(embedData).slice(0, 200) });


  // Step 2: Search EmergentDB
  const searchRes = await fetch("https://api.emergentdb.com/vectors/search", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${emergentKey}`,
      "User-Agent": "EmergentDB-Ingest/1.0",
    },
    body: JSON.stringify({ vector: embedding, k: 10, namespace: "budget2026v2", include_metadata: true }),
  });
  const searchText = await searchRes.text();
  let searchData;
  try { searchData = JSON.parse(searchText); } catch { searchData = null; }
  if (!searchRes.ok || !searchData?.results) {
    return jsonResp({ error: `EmergentDB ${searchRes.status}: ${searchText.slice(0, 300)}` });
  }

  let context = "";
  // Sort by score descending, take top results regardless of threshold
  const results = [...searchData.results].sort((a, b) => (b.score ?? 0) - (a.score ?? 0));
  for (const r of results) {
    const chunk = r.metadata?.text || r.metadata?.title || "";
    if (!chunk) continue;
    if (context) context += "\n\n---\n\n";
    context += chunk;
  }


  // Step 3: Chat with gpt-5-nano
  const systemPrompt =
    "You are a helpful assistant that answers questions about the FY2026 Singapore Budget Statement. " +
    "Use the provided document context to give accurate, concise answers. " +
    "Cite relevant figures and policies from the document when applicable. " +
    "If no context is provided, use your general knowledge about Singapore's FY2026 Budget " +
    "but clearly indicate you are not drawing from the retrieved document.";

  const userMsg = context
    ? `Context from FY2026 Budget Statement:\n${context}\n\nQuestion: ${question}`
    : `No relevant document context was found for this question.\n\nQuestion: ${question}`;

  const chatRes = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${openaiKey}` },
    body: JSON.stringify({ model: "gpt-5-nano", instructions: systemPrompt, input: userMsg, max_output_tokens: 128000 }),
  });
  const chatData = await chatRes.json();

  let answer = "";
  for (const out of chatData?.output ?? []) {
    if (out.type !== "message") continue;
    for (const c of out.content ?? []) {
      if (c.text) { answer = c.text; break; }
    }
    if (answer) break;
  }

  if (!answer) return jsonResp({ error: "No answer from AI", raw: chatData });
  return jsonResp({ answer, searches_performed: 1 });
}

async function handleSuggestions(request, env) {
  let body;
  try { body = await request.json(); } catch { return jsonResp({ suggestions: [] }); }
  const { question, answer = "" } = body ?? {};
  if (!question) return jsonResp({ suggestions: [] });

  const openaiKey = env.OPENAI_API_KEY;
  if (!openaiKey) return jsonResp({ suggestions: [] });

  const prompt = answer
    ? `A user asked about Singapore's FY2026 Budget: "${question}"\nThe answer was: "${answer.slice(0, 400)}"\n\nGenerate exactly 3 short follow-up questions they might want to ask next. Each question should be concise (under 12 words) and explore a different aspect. Return ONLY a raw JSON array of 3 strings — no markdown, no explanation. Example format: ["Question one?","Question two?","Question three?"]`
    : `A user is asking about Singapore's FY2026 Budget: "${question}"\n\nGenerate exactly 3 short follow-up questions they might want to explore next. Each question should be concise (under 12 words) and cover a different related aspect. Return ONLY a raw JSON array of 3 strings — no markdown, no explanation. Example format: ["Question one?","Question two?","Question three?"]`;

  const res = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${openaiKey}` },
    body: JSON.stringify({
      model: "gpt-5-nano",
      instructions: "You generate follow-up questions. Return only a JSON array of strings.",
      input: prompt,
      max_output_tokens: 1024,
    }),
  });
  const data = await res.json();

  let text = "";
  for (const out of data?.output ?? []) {
    if (out.type !== "message") continue;
    for (const c of out.content ?? []) {
      if (c.text) { text = c.text; break; }
    }
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

function jsonResp(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export default {
  async fetch(request, env, _ctx) {
    const url = new URL(request.url);

    // Handle AI routes in JS — wasm32-freestanding can't use process/fs/network
    if (url.pathname === "/api/ai" && request.method === "POST")
      return handleAi(request, env);
    if (url.pathname === "/api/suggestions" && request.method === "POST")
      return handleSuggestions(request, env);

    const wasm = await getInstance();

    // Inject Cloudflare secret bindings into the Zig env table once per cold start.
    injectEnv(wasm, env);

    const input = `${request.method} ${url.pathname}`;
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    const encoded = encoder.encode(input);

    // Allocate memory in WASM and write the request.
    const ptr = wasm.alloc(encoded.length);
    if (!ptr) return new Response("WASM alloc failed", { status: 500 });

    const mem = new Uint8Array(wasm.memory.buffer);
    mem.set(encoded, ptr);

    // Call handle and read the response.
    const resPtr = wasm.handle(ptr, encoded.length);
    wasm.dealloc(ptr, encoded.length);

    if (!resPtr) return new Response("Not Found", { status: 404 });

    const resLen = wasm.response_len();
    const resBuf = new Uint8Array(wasm.memory.buffer, resPtr, resLen);

    // Decode: u16 status LE | u16 ct_len LE | content-type | body
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
