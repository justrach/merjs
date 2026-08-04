import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const root = resolve(process.argv[2] || ".");
const deployments = [
  {
    config: "examples/site/worker/wrangler.toml",
    main: "worker/worker.js",
    command: "cd ../../.. && zig build worker",
    wasm: ["worker/merjs.wasm", "worker/grep.wasm"],
    budget: "merlionjs-site-production",
  },
  {
    config: "examples/singapore-data-dashboard/worker/wrangler.toml",
    main: "worker.js",
    command: "cd ../../.. && zig build sgdata-worker",
    wasm: ["merjs.wasm"],
    budget: "merlionjs-sgdata-production",
  },
];

function resolveImports(file, seen = new Set()) {
  const absolute = resolve(file);
  if (seen.has(absolute)) return seen;
  seen.add(absolute);
  const source = readFileSync(absolute, "utf8");
  for (const match of source.matchAll(/\bfrom\s+["'](\.[^"']+)["']/g)) {
    const imported = resolve(dirname(absolute), match[1]);
    assert.ok(existsSync(imported), `${absolute}: unresolved import ${match[1]}`);
    if (imported.endsWith(".js")) resolveImports(imported, seen);
  }
  return seen;
}

for (const deployment of deployments) {
  const configPath = join(root, deployment.config);
  const configDir = dirname(configPath);
  const config = readFileSync(configPath, "utf8");
  assert.match(config, new RegExp(`^main = "${deployment.main.replaceAll(".", "\\.")}"$`, "m"));
  assert.ok(config.includes(`command = "${deployment.command}"`), `${deployment.config}: wrong build command`);
  assert.ok(config.includes(`AI_BUDGET_ACCOUNT = "${deployment.budget}"`), `${deployment.config}: AI budget account changed`);
  assert.ok(config.includes('binding = "AI_BUDGET_GUARD"'), `${deployment.config}: AI budget binding missing`);
  resolveImports(join(configDir, deployment.main));
  for (const wasm of deployment.wasm) {
    assert.ok(existsSync(join(configDir, wasm)), `${deployment.config}: missing generated ${wasm}`);
  }
}

assert.ok(!existsSync(join(root, "examples/site/worker/worker/wrangler.toml")), "site has a duplicate nested Wrangler config");

const kanbanConfigPath = join(root, "examples/kanban/worker/wrangler.toml");
const kanbanConfig = readFileSync(kanbanConfigPath, "utf8");
assert.match(kanbanConfig, /^main = "worker\.js"$/m);
assert.ok(kanbanConfig.includes('command = "cd ../../../ && zig build worker-example-kanban"'), "Kanban deployment: wrong build command");
resolveImports(join(dirname(kanbanConfigPath), "worker.js"));
assert.ok(existsSync(join(dirname(kanbanConfigPath), "merjs.wasm")), "Kanban deployment is missing merjs.wasm");

const vercelConfig = JSON.parse(readFileSync(join(root, "examples/vercel-edge/vercel.json"), "utf8"));
assert.deepEqual(vercelConfig.rewrites, [{ source: "/(.*)", destination: "/api" }]);
assert.ok(!("buildCommand" in vercelConfig), "Vercel deployment unexpectedly requires a remote Zig toolchain");
assert.ok(existsSync(join(root, "examples/vercel-edge/merjs.wasm")), "Vercel deployment is missing merjs.wasm");
const vercelAdapter = readFileSync(join(root, "examples/vercel-edge/api/index.js"), "utf8");
assert.match(vercelAdapter, /new WebAssembly\.Instance\(wasmModule, \{\}\)/, "Vercel WASM is not request-local");
assert.doesNotMatch(vercelAdapter, /let instance\s*=|request\.arrayBuffer\(/, "Vercel adapter retains state or buffers requests");
assert.match(vercelAdapter, /0x3152454d/, "Vercel adapter does not validate MER1");
assert.match(vercelAdapter, /wasm\.response_done\(\)/, "Vercel adapter does not release response memory");
assert.match(vercelAdapter, /collect_fetch_urls/, "Vercel adapter omits fetch collection/replay");
assert.match(vercelAdapter, /x-vercel-forwarded-for/, "Vercel adapter omits trusted client identity");
assert.match(vercelAdapter, /__mer_set_env_status/, "Vercel adapter omits environment injection");
assert.match(vercelAdapter, /replayFetches\([\s\S]*request\.signal\)/, "Vercel fetch replay ignores client disconnects");
assert.doesNotMatch(vercelAdapter, /count\s*>=\s*\d+/, "Vercel adapter rejects valid environments by variable count");
assert.match(vercelAdapter, /await reader\.read\(\);\n\s+if \(signal\?\.aborted\)/, "Vercel body reads accept abort-driven truncation");

for (const adapter of [
  "examples/kanban/worker/worker.js",
  "examples/singapore-data-dashboard/worker/worker.js",
  "examples/site/worker/worker/fetch-bridge.js",
  "examples/vercel-edge/api/index.js",
]) {
  const source = readFileSync(join(root, adapter), "utf8");
  assert.doesNotMatch(source, /request\.arrayBuffer\(/, `${adapter}: request body is not streamed`);
  assert.match(source, /\^\(0\|\[1-9\]/, `${adapter}: canonical Content-Length validation missing`);
  assert.match(source, /\.cancel\(/, `${adapter}: oversized body is not canceled`);
  assert.match(source, /deadline exceeded/, `${adapter}: incoming body has no deadline`);
  assert.match(source, /\.signal|signal\?/, `${adapter}: incoming body ignores request cancellation`);
}

for (const adapter of [
  "examples/kanban/worker/worker.js",
  "examples/singapore-data-dashboard/worker/worker.js",
  "examples/site/worker/worker/worker.js",
  "examples/vercel-edge/api/index.js",
]) {
  const source = readFileSync(join(root, adapter), "utf8");
  assert.match(source, /status === 204 \|\| status === 205 \|\| status === 304/, `${adapter}: bodyless statuses are not enforced`);
  assert.match(source, /request\.method === "HEAD"|request\.method !== "HEAD"/, `${adapter}: HEAD responses retain bodies`);
}

for (const adapter of [
  "examples/singapore-data-dashboard/worker/worker.js",
  "examples/site/worker/worker/worker.js",
]) {
  const source = readFileSync(join(root, adapter), "utf8");
  assert.match(source, /readAiJson\(request, deadlineSignal\)/, `${adapter}: AI body reader omits its deadline`);
  assert.match(source, /readAiJson\(request, signal\)/, `${adapter}: AI handler drops its admission signal`);
  assert.match(source, /await reader\.read\(\);\n\s+if \(controller\.signal\.aborted\)/, `${adapter}: AI body accepts abort-driven truncation`);
  assert.match(source, /raceWithSignal\(workPromise/, `${adapter}: AI deadline does not bound the caller response`);
  assert.match(source, /workPromise\.finally\(\(\) => \{ aiActive--; \}\)/, `${adapter}: AI concurrency releases before work settles`);
  assert.match(source, /request\.body\?\.cancel\("AI request rejected"\)/, `${adapter}: rejected AI uploads are not canceled`);
  assert.match(source, /request\.signal\?\.addEventListener\("abort", abortFromRequest/, `${adapter}: AI work ignores client disconnects after upload`);
  assert.doesNotMatch(source, /await [A-Za-z]+(?:Res)?\.(?:json|text)\(\)/, `${adapter}: AI upstream response is buffered without a byte cap`);
}

for (const adapter of [
  "examples/singapore-data-dashboard/worker/ai-budget.js",
  "examples/site/worker/worker/ai-budget.js",
]) {
  const source = readFileSync(join(root, adapter), "utf8");
  assert.match(source, /MAX_GATE_RESPONSE_BYTES = 16 \* 1024/, `${adapter}: budget decision size is unbounded`);
  assert.doesNotMatch(source, /response\.text\(\)/, `${adapter}: budget decision bypasses bounded streaming`);
}

const siteAdapter = readFileSync(join(root, "examples/site/worker/worker/worker.js"), "utf8");
assert.match(siteAdapter, /readBoundedBody\(\{[\s\S]*body: obj\.body,[\s\S]*MAX_CORPUS_JSON_BYTES, signal\)/, "site R2 corpus read is not bounded");
assert.match(siteAdapter, /const obj = await env\.BUCKET\.get/, "site R2 acquisition is not tracked through real settlement");
assert.match(siteAdapter, /externalSignal: request\.signal/, "site fetch replay ignores client disconnects");
assert.match(siteAdapter, /obj\?\.body\?\.cancel\("AI deadline exceeded"\)/, "site abandons an R2 body that resolves after its deadline");
assert.match(siteAdapter, /cachedChunks\.expiresAt > now/, "site corpus cache never revalidates");
assert.match(siteAdapter, /GREP_CHUNKS_CAPACITY - totalLen - 4/, "site grep corpus can exceed WASM capacity");
assert.match(siteAdapter, /qBytes\.length > GREP_QUERY_CAPACITY/, "site grep query can exceed WASM capacity");

const singaporeAdapter = readFileSync(join(root, "examples/singapore-data-dashboard/worker/worker.js"), "utf8");
assert.match(singaporeAdapter, /request\.method !== "GET"/, "collections route does not enforce GET");
assert.match(singaporeAdapter, /headers: \{ "x-api-key": env\.SG_DATA_API_KEY \}/, "collections API key is not server-side");
assert.match(singaporeAdapter, /upstream\.searchParams\.set/, "collections query is not safely encoded");
assert.match(singaporeAdapter, /readIncomingBody\(response, 1024 \* 1024\)/, "collections response is not bounded");
