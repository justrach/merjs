// worker.js — Cloudflare Workers fetch handler for merjs.
// Static assets from public/ are served automatically by Wrangler [assets].
// This worker handles dynamic routes via the merjs WASM module.

import merWasm from "./merjs.wasm";
import { AiAdmissionError, authorizePaidOperation, createAiAdmission } from "./ai-budget.js";

const merModule = Promise.resolve(merWasm).then(source =>
  source instanceof WebAssembly.Module ? source : WebAssembly.compile(source));

async function createInstance() {
  const instantiated = await WebAssembly.instantiate(await merModule, {});
  const wasm = instantiated.exports || instantiated;
  wasm.init();
  return wasm;
}

// Explicit application policy for this dashboard's inline UI, maps, fonts, and APIs.
const securityHeaders = {
  "strict-transport-security": "max-age=63072000; includeSubDomains; preload",
  "content-security-policy": "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://unpkg.com https://static.cloudflareinsights.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://unpkg.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: https://*.basemaps.cartocdn.com https://*.tile.openstreetmap.org; connect-src 'self' https://api.open-meteo.com https://api-open.data.gov.sg https://cloudflareinsights.com https://cdn.jsdelivr.net https://unpkg.com; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  "x-frame-options": "DENY",
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  "cross-origin-opener-policy": "same-origin",
  "permissions-policy": "camera=(), microphone=(), geolocation=()",
};

function injectEnv(wasm, env) {
  if (!wasm.__mer_set_env_status) {
    throw new Error("WASM module does not expose observable environment injection");
  }
  const enc = new TextEncoder();
  for (const [key, val] of Object.entries(env)) {
    if (typeof val !== "string") continue;
    const kb = enc.encode(key);
    const vb = enc.encode(val);
    const kp = kb.length === 0 ? 0 : wasm.alloc(kb.length);
    const vp = vb.length === 0 ? 0 : wasm.alloc(vb.length);
    try {
      if ((kb.length !== 0 && !kp) || (vb.length !== 0 && !vp))
        throw new Error(`WASM env allocation failed for ${key}`);
      const mem = new Uint8Array(wasm.memory.buffer);
      mem.set(kb, kp);
      mem.set(vb, vp);
      const status = wasm.__mer_set_env_status(kp, kb.length, vp, vb.length);
      if (status !== 0) throw new Error(`WASM env injection failed for ${key}: ${status}`);
    } finally {
      if (kb.length !== 0 && kp) wasm.dealloc(kp, kb.length);
      if (vb.length !== 0 && vp) wasm.dealloc(vp, vb.length);
    }
  }
}

const resolverScript = "(()=>{for(const s of document.querySelectorAll('template[data-mer-resolve]')){for(const p of document.querySelectorAll('[data-mer-placeholder]')){if(p.getAttribute('data-mer-placeholder')===s.getAttribute('data-mer-resolve')){p.replaceWith(s.content);s.remove();break}}}})();";
const forwardedHeaders = ["accept", "authorization", "content-type", "origin", "referer", "user-agent"];

async function readIncomingBody(message, limit = 1024 * 1024, maxDurationMs = 30000, externalSignal) {
  const controller = new AbortController();
  const abortFromMessage = () => controller.abort(message.signal?.reason);
  const abortFromExternal = () => controller.abort(externalSignal?.reason);
  if (message.signal?.aborted) abortFromMessage();
  else message.signal?.addEventListener("abort", abortFromMessage, { once: true });
  if (externalSignal?.aborted) abortFromExternal();
  else externalSignal?.addEventListener("abort", abortFromExternal, { once: true });
  const timeoutError = new Error("body deadline exceeded");
  timeoutError.name = "TimeoutError";
  const timeout = setTimeout(() => controller.abort(timeoutError), maxDurationMs);
  try {
    if (controller.signal.aborted) throw controller.signal.reason;
    const value = message.headers.get("content-length");
    if (value !== null && (!/^(0|[1-9][0-9]*)$/.test(value) ||
        !Number.isSafeInteger(Number(value)) || Number(value) > limit)) {
      await message.body?.cancel("invalid or oversized body").catch(() => {});
      throw new Error("invalid or oversized body");
    }
    if (!message.body) return new Uint8Array();
    const reader = message.body.getReader();
    const chunks = [];
    let length = 0;
    let complete = false;
    const cancel = () => { void reader.cancel(controller.signal.reason).catch(() => {}); };
    controller.signal.addEventListener("abort", cancel, { once: true });
    try {
      while (true) {
        if (controller.signal.aborted) throw controller.signal.reason;
        const { done, value: chunk } = await reader.read();
        if (controller.signal.aborted) throw controller.signal.reason;
        if (done) { complete = true; break; }
        if (chunk.byteLength > limit - length) {
          await reader.cancel("body too large").catch(() => {});
          throw new Error("body too large");
        }
        chunks.push(chunk);
        length += chunk.byteLength;
      }
    } finally {
      controller.signal.removeEventListener("abort", cancel);
      if (!complete) await reader.cancel(controller.signal.reason || "body read failed").catch(() => {});
      reader.releaseLock();
    }
    const body = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
    return body;
  } finally {
    clearTimeout(timeout);
    message.signal?.removeEventListener("abort", abortFromMessage);
    externalSignal?.removeEventListener("abort", abortFromExternal);
  }
}

async function readBoundedUpstreamText(response, signal) {
  const bytes = await readIncomingBody(response, 1024 * 1024, 15000, signal);
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

async function readBoundedUpstreamJson(response, signal) {
  return JSON.parse(await readBoundedUpstreamText(response, signal));
}

async function encodeIncomingRequest(request, url) {
  const encoder = new TextEncoder();
  const parts = [encoder.encode(request.method), encoder.encode(url.pathname + url.search)];
  parts.push(await readIncomingBody(request));
  parts.push(encoder.encode(request.headers.get("cookie") || ""));
  parts.push(encoder.encode(request.headers.get("cf-connecting-ip") || ""));
  const headers = forwardedHeaders.flatMap(name => {
    const value = request.headers.get(name);
    return value === null ? [] : [[encoder.encode(name), encoder.encode(value)]];
  });
  const headerBytes = headers.reduce((sum, [name, value]) => sum + 8 + name.length + value.length, 0);
  const total = 24 + parts.reduce((sum, part) => sum + part.length, 0) + headerBytes;
  if (!parts[0].length || parts[0].length > 16 || !parts[1].length || parts[1].length > 16 * 1024 ||
      parts[2].length > 1024 * 1024 || parts[3].length > 16 * 1024 || parts[4].length > 256 ||
      headerBytes > 64 * 1024 || total > 2 * 1024 * 1024)
    throw new Error("request metadata too large");
  const encoded = new Uint8Array(total);
  const view = new DataView(encoded.buffer);
  parts.forEach((part, index) => view.setUint32(index * 4, part.length, true));
  view.setUint32(20, headers.length, true);
  let offset = 24;
  for (const part of parts) { encoded.set(part, offset); offset += part.length; }
  for (const [name, value] of headers) {
    view.setUint32(offset, name.length, true); view.setUint32(offset + 4, value.length, true); offset += 8;
    encoded.set(name, offset); offset += name.length; encoded.set(value, offset); offset += value.length;
  }
  return encoded;
}

// ── AI route handlers (JS-native — wasm32 can't do process/fs/network) ────────

const AI_MAX_CONCURRENCY = 2;
const AI_MAX_PER_MINUTE = 10;
let aiActive = 0;
let aiMinute = 0;
let aiMinuteCount = 0;

async function rejectAiRequest(request, data, status) {
  await request.body?.cancel("AI request rejected").catch(() => {});
  return jsonResp(data, status);
}

async function raceWithSignal(promise, signal) {
  let onAbort;
  const aborted = new Promise((_, reject) => {
    onAbort = () => reject(signal.reason || new Error("AI deadline exceeded"));
    if (signal.aborted) onAbort();
    else signal.addEventListener("abort", onAbort, { once: true });
  });
  try { return await Promise.race([promise, aborted]); }
  finally { signal.removeEventListener("abort", onAbort); }
}

async function admitAi(request, env, work) {
  if (!env.AI_BEARER_TOKEN)
    return rejectAiRequest(request, { error: "AI controls are not configured" }, 503);
  if (request.headers.get("authorization") !== `Bearer ${env.AI_BEARER_TOKEN}`)
    return rejectAiRequest(request, { error: "Unauthorized" }, 401);
  const contentLength = request.headers.get("content-length");
  if (contentLength !== null && (!/^(0|[1-9][0-9]*)$/.test(contentLength) ||
      !Number.isSafeInteger(Number(contentLength)) || Number(contentLength) > 8192)) {
    await request.body?.cancel("AI request too large").catch(() => {});
    return jsonResp({ error: "AI request too large" }, 413);
  }
  let admission;
  try { admission = createAiAdmission(request, env); }
  catch (error) {
    return rejectAiRequest(request, { error: error.message }, error instanceof AiAdmissionError ? error.status : 503);
  }
  const minute = Math.floor(Date.now() / 60000);
  if (minute !== aiMinute) { aiMinute = minute; aiMinuteCount = 0; }
  // These isolate-local limits are defense-in-depth only; the shared gate is authoritative.
  if (aiActive >= AI_MAX_CONCURRENCY || aiMinuteCount >= AI_MAX_PER_MINUTE)
    return rejectAiRequest(request, { error: "AI capacity exceeded" }, 429);
  aiActive++;
  aiMinuteCount++;
  const controller = new AbortController();
  const abortFromRequest = () => controller.abort(request.signal?.reason);
  if (request.signal?.aborted) abortFromRequest();
  else request.signal?.addEventListener("abort", abortFromRequest, { once: true });
  const timeoutError = new Error("AI deadline exceeded");
  timeoutError.name = "TimeoutError";
  const timeout = setTimeout(() => controller.abort(timeoutError), 15000);
  const workPromise = controller.signal.aborted
    ? Promise.reject(controller.signal.reason)
    : Promise.resolve().then(() => work(controller.signal, admission));
  // Keep the strict concurrency slot charged until the underlying operation
  // actually settles, even if the caller-facing deadline wins the race.
  void workPromise.finally(() => { aiActive--; }).catch(() => {});
  try { return await raceWithSignal(workPromise, controller.signal); }
  catch (error) {
    if (error instanceof AiAdmissionError) return jsonResp({ error: error.message }, error.status);
    return jsonResp({ error: error?.name === "TimeoutError" ? "AI request timed out" : "AI upstream unavailable" }, error?.name === "TimeoutError" ? 504 : 502);
  } finally {
    clearTimeout(timeout);
    request.signal?.removeEventListener("abort", abortFromRequest);
  }
}

async function readAiJson(request, deadlineSignal) {
  if (!request.body) throw new Error("missing body");
  const controller = new AbortController();
  const abortFromRequest = () => controller.abort(request.signal?.reason);
  const abortFromDeadline = () => controller.abort(deadlineSignal?.reason);
  if (request.signal?.aborted) abortFromRequest();
  else request.signal?.addEventListener("abort", abortFromRequest, { once: true });
  if (deadlineSignal?.aborted) abortFromDeadline();
  else deadlineSignal?.addEventListener("abort", abortFromDeadline, { once: true });

  const reader = request.body.getReader();
  const chunks = [];
  let length = 0;
  let complete = false;
  const cancel = () => { void reader.cancel(controller.signal.reason).catch(() => {}); };
  controller.signal.addEventListener("abort", cancel, { once: true });
  try {
    while (true) {
      if (controller.signal.aborted) throw controller.signal.reason;
      const { done, value } = await reader.read();
      if (controller.signal.aborted) throw controller.signal.reason;
      if (done) { complete = true; break; }
      if (value.byteLength > 8192 - length) {
        await reader.cancel("body too large").catch(() => {});
        throw new Error("body too large");
      }
      chunks.push(value);
      length += value.byteLength;
    }
  } finally {
    controller.signal.removeEventListener("abort", cancel);
    request.signal?.removeEventListener("abort", abortFromRequest);
    deadlineSignal?.removeEventListener("abort", abortFromDeadline);
    if (!complete) await reader.cancel(controller.signal.reason || "AI body read failed").catch(() => {});
    reader.releaseLock();
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}

async function handleAi(request, env, signal, admission) {
  let body;
  try { body = await readAiJson(request, signal); } catch { return jsonResp({ error: "Invalid or oversized JSON" }, 400); }
  const question = body?.question;
  if (typeof question !== "string" || !question.trim() || question.length > 512)
    return jsonResp({ error: "question must be 1-512 characters" }, 400);

  const openaiKey = env.OPENAI_API_KEY;
  const emergentKey = env.EMERGENT_API_KEY;
  if (!openaiKey || !emergentKey) return jsonResp({ error: "AI upstream is not configured" }, 503);
  // Step 1: Reformulate question into keyword search query (improves retrieval)
  let searchQuery = question;
  await authorizePaidOperation(env, admission, "openai.reform", 0.001, signal);
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
      signal,
    });
    const reformData = await readBoundedUpstreamJson(reformRes, signal);
    for (const out of reformData?.output ?? []) {
      if (out.type !== "message") continue;
      for (const c of out.content ?? []) { if (c.text) { searchQuery = c.text.trim(); break; } }
      if (searchQuery !== question) break;
    }
  } catch { /* fall back to raw question */ }

  // Step 2: Embed search query
  await authorizePaidOperation(env, admission, "openai.embedding", 0.001, signal);
  const embedRes = await fetch("https://api.openai.com/v1/embeddings", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${openaiKey}` },
    body: JSON.stringify({ model: "text-embedding-3-small", input: searchQuery.slice(0, 512) }),
    signal,
  });
  const embedData = await readBoundedUpstreamJson(embedRes, signal);
  const embedding = embedData?.data?.[0]?.embedding;
  if (!embedding) return jsonResp({ error: "Embedding failed: " + JSON.stringify(embedData).slice(0, 200) });


  // Step 2: Search EmergentDB
  await authorizePaidOperation(env, admission, "emergentdb.search", 0.003, signal);
  const searchRes = await fetch("https://api.emergentdb.com/vectors/search", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${emergentKey}`,
      "User-Agent": "EmergentDB-Ingest/1.0",
    },
    body: JSON.stringify({ vector: embedding, k: 6, namespace: "budget2026v2", include_metadata: true }),
    signal,
  });
  const searchText = await readBoundedUpstreamText(searchRes, signal);
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
    const separator = context ? "\n\n---\n\n" : "";
    context += separator + chunk.slice(0, Math.max(0, 12000 - context.length - separator.length));
    if (context.length >= 12000) break;
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

  await authorizePaidOperation(env, admission, "openai.answer", 0.015, signal);
  const chatRes = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${openaiKey}` },
    body: JSON.stringify({ model: "gpt-5-nano", instructions: systemPrompt, input: userMsg.slice(0, 13000), max_output_tokens: 1024 }),
    signal,
  });
  const chatData = await readBoundedUpstreamJson(chatRes, signal);

  let answer = "";
  for (const out of chatData?.output ?? []) {
    if (out.type !== "message") continue;
    for (const c of out.content ?? []) {
      if (c.text) { answer = c.text; break; }
    }
    if (answer) break;
  }

  if (!answer) return jsonResp({ error: "No answer from AI" }, 502);
  return jsonResp({ answer: answer.slice(0, 8000), searches_performed: 1 });
}

async function handleSuggestions(request, env, signal, admission) {
  let body;
  try { body = await readAiJson(request, signal); } catch { return jsonResp({ error: "Invalid or oversized JSON" }, 400); }
  const { question, answer = "" } = body ?? {};
  if (typeof question !== "string" || !question.trim() || question.length > 512 || typeof answer !== "string" || answer.length > 2000)
    return jsonResp({ error: "invalid suggestion input" }, 400);

  const openaiKey = env.OPENAI_API_KEY;
  if (!openaiKey) return jsonResp({ error: "AI upstream is not configured" }, 503);

  const prompt = answer
    ? `A user asked about Singapore's FY2026 Budget: "${question}"\nThe answer was: "${answer.slice(0, 400)}"\n\nGenerate exactly 3 short follow-up questions they might want to ask next. Each question should be concise (under 12 words) and explore a different aspect. Return ONLY a raw JSON array of 3 strings — no markdown, no explanation. Example format: ["Question one?","Question two?","Question three?"]`
    : `A user is asking about Singapore's FY2026 Budget: "${question}"\n\nGenerate exactly 3 short follow-up questions they might want to explore next. Each question should be concise (under 12 words) and cover a different related aspect. Return ONLY a raw JSON array of 3 strings — no markdown, no explanation. Example format: ["Question one?","Question two?","Question three?"]`;

  await authorizePaidOperation(env, admission, "openai.suggestions", 0.002, signal);
  const res = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${openaiKey}` },
    body: JSON.stringify({
      model: "gpt-5-nano",
      instructions: "You generate follow-up questions. Return only a JSON array of strings.",
      input: prompt,
      max_output_tokens: 256,
    }),
    signal,
  });
  const data = await readBoundedUpstreamJson(res, signal);

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
    const suggestions = JSON.parse(text.slice(start, end + 1));
    if (!Array.isArray(suggestions)) throw new Error("invalid suggestions");
    return jsonResp({ suggestions: suggestions.slice(0, 3).filter(value => typeof value === "string").map(value => value.slice(0, 100)) });
  } catch {
    return jsonResp({ suggestions: [] });
  }
}

function workerResponse(body, init = {}) {
  const headers = new Headers(securityHeaders);
  if (Array.isArray(init.headers)) {
    for (const [name, value] of init.headers) headers.append(name, value);
  } else {
    new Headers(init.headers || {}).forEach((value, name) => headers.append(name, value));
  }
  const status = init.status ?? 200;
  const responseBody = status === 204 || status === 205 || status === 304 ? null : body;
  return new Response(responseBody, { ...init, headers });
}

function finalizeWorkerResponse(request, response) {
  if (request.method !== "HEAD" || response.body === null) return response;
  return new Response(null, { status: response.status, statusText: response.statusText, headers: response.headers });
}

const RESPONSE_MAGIC = 0x3152454d;
const RESPONSE_VERSION = 1;
const MAX_RESPONSE_HEADERS = 10;
const MAX_RESPONSE_HEADER_NAME_BYTES = 64;
const MAX_RESPONSE_HEADER_VALUE_BYTES = 4096;
const MAX_RESPONSE_HEADER_BYTES = 32 * 1024;
const headerNamePattern = /^[!#$%&'*+.^_`|~0-9a-z-]+$/;

function decodeWorkerResponse(bytes, decoder) {
  if (bytes.byteLength < 16 || bytes.byteLength > 32 * 1024 * 1024) throw new Error("invalid WASM response size");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (view.getUint32(0, true) !== RESPONSE_MAGIC || view.getUint16(4, true) !== RESPONSE_VERSION || view.getUint16(10, true) !== 0)
    throw new Error("unsupported WASM response protocol");
  const status = view.getUint16(6, true);
  const count = view.getUint16(8, true);
  const bodyLength = view.getUint32(12, true);
  if (status < 100 || status > 599 || count === 0 || count > MAX_RESPONSE_HEADERS) throw new Error("invalid WASM response metadata");
  const headers = [];  let offset = 16;
  let contentTypes = 0;
  let locations = 0;
  for (let i = 0; i < count; i++) {
    if (offset + 6 > bytes.byteLength) throw new Error("truncated WASM response header");
    const nameLength = view.getUint16(offset, true);
    const valueLength = view.getUint32(offset + 2, true);
    offset += 6;
    if (!nameLength || nameLength > MAX_RESPONSE_HEADER_NAME_BYTES || valueLength > MAX_RESPONSE_HEADER_VALUE_BYTES ||
        offset + nameLength + valueLength > bytes.byteLength || offset + nameLength + valueLength - 16 > MAX_RESPONSE_HEADER_BYTES)
      throw new Error("invalid WASM response header length");
    const name = decoder.decode(bytes.subarray(offset, offset + nameLength));
    offset += nameLength;
    const value = decoder.decode(bytes.subarray(offset, offset + valueLength));
    offset += valueLength;
    if (!headerNamePattern.test(name) || /[\0\r\n\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value) ||
        (name !== "content-type" && name !== "location" && name !== "set-cookie")) throw new Error("invalid WASM response header");
    if (name === "content-type") contentTypes++;
    if (name === "location") locations++;
    headers.push([name, value]);  }
  if (contentTypes !== 1 || locations > 1 || offset + bodyLength !== bytes.byteLength ||
      (locations === 1) !== (status >= 300 && status < 400)) throw new Error("inconsistent WASM response metadata");
  return { status, headers, body: bytes.slice(offset) };
}

function resolverResponse(request) {
  return workerResponse(request.method === "HEAD" ? null : resolverScript, {
    headers: { "content-type": "application/javascript; charset=utf-8", "cache-control": "public, max-age=3600" },
  });
}

function jsonResp(data, status = 200) {
  return workerResponse(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function handleCollections(request, env, url) {
  if (request.method !== "GET")
    return workerResponse(JSON.stringify({ error: "Method Not Allowed" }), {
      status: 405,
      headers: { "content-type": "application/json", "allow": "GET" },
    });
  if (!env.SG_DATA_API_KEY)
    return jsonResp({ error: "Collections service is not configured" }, 503);

  const search = url.searchParams.get("search");
  const page = url.searchParams.get("page") || "1";
  if (search !== null && search.length > 200)
    return jsonResp({ error: "Invalid search query" }, 400);
  if (search === null && !/^[1-9][0-9]*$/.test(page))
    return jsonResp({ error: "Invalid page" }, 400);

  const upstream = new URL(search === null
    ? "https://api-production.data.gov.sg/v2/public/api/collections"
    : "https://api-production.data.gov.sg/v2/public/api/datasets");
  if (search === null) upstream.searchParams.set("page", page);
  else upstream.searchParams.set("search", search);

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);
  try {
    const response = await fetch(upstream, {
      headers: { "x-api-key": env.SG_DATA_API_KEY },
      signal: controller.signal,
    });
    if (!response.ok) {
      await response.body?.cancel("upstream error").catch(() => {});
      return jsonResp({ error: "data.gov.sg returned an error" }, 502);
    }
    const body = await readIncomingBody(response, 1024 * 1024);
    return workerResponse(body, { headers: { "content-type": "application/json; charset=utf-8" } });
  } catch (_) {
    return jsonResp({ error: "Failed to fetch from data.gov.sg" }, 502);
  } finally {
    clearTimeout(timeout);
  }
}

async function handleRequest(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/_mer/resolve.js" && (request.method === "GET" || request.method === "HEAD"))
      return resolverResponse(request);

    // Handle network routes in JS — wasm32-freestanding can't use network APIs.
    if (url.pathname === "/api/collections")
      return handleCollections(request, env, url);
    if (url.pathname === "/api/ai" && request.method === "POST")
      return admitAi(request, env, (signal, admission) => handleAi(request, env, signal, admission));
    if (url.pathname === "/api/suggestions" && request.method === "POST")
      return admitAi(request, env, (signal, admission) => handleSuggestions(request, env, signal, admission));

    let wasm;
    try {
      // Mutable router, environment, and response state is isolated per request.
      wasm = await createInstance();
      injectEnv(wasm, env);
    } catch (_) {
      return workerResponse("WASM initialization failed", { status: 500 });
    }

    const decoder = new TextDecoder("utf-8", { fatal: true });
    let encoded;
    try {
      encoded = await encodeIncomingRequest(request, url);
    } catch (_) {
      return workerResponse("Request Too Large", { status: 413 });
    }
    const ptr = wasm.alloc(encoded.length);
    if (!ptr) return workerResponse("WASM alloc failed", { status: 500 });

    let resPtr;
    try {
      new Uint8Array(wasm.memory.buffer).set(encoded, ptr);
      resPtr = wasm.handle(ptr, encoded.length);
    } catch (_) {
      return workerResponse("Internal Server Error", { status: 500 });
    } finally {
      wasm.dealloc(ptr, encoded.length);
    }
    if (!resPtr) return workerResponse("Not Found", { status: 404 });

    try {
      const resLen = wasm.response_len();
      const decoded = decodeWorkerResponse(new Uint8Array(wasm.memory.buffer, resPtr, resLen), decoder);
      return workerResponse(decoded.body, decoded);
    } catch (_) {
      return workerResponse("Internal Server Error", { status: 500 });
    } finally {
      wasm.response_done();
    }
}

export default {
  async fetch(request, env, _ctx) {
    try {
      return finalizeWorkerResponse(request, await handleRequest(request, env));
    } catch (_) {
      return finalizeWorkerResponse(request, workerResponse("Internal Server Error", { status: 500 }));
    }
  },
};
