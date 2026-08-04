const GATE_TIMEOUT_MS = 2000;
const accountKeyPattern = /^[A-Za-z0-9._:-]{1,128}$/;
const idempotencyKeyPattern = /^[A-Za-z0-9._:-]{16,128}$/;
const operationPattern = /^[a-z0-9._:-]{1,64}$/;
const MAX_GATE_RESPONSE_BYTES = 16 * 1024;

async function readBoundedText(response, limit, signal) {
  const contentLength = response.headers.get("content-length");
  if (contentLength !== null && (!/^(0|[1-9][0-9]*)$/.test(contentLength) ||
      !Number.isSafeInteger(Number(contentLength)) || Number(contentLength) > limit)) {
    await response.body?.cancel("budget response too large").catch(() => {});
    throw new Error("budget response too large");
  }
  if (signal?.aborted) throw signal.reason;
  if (!response.body) return "";
  const reader = response.body.getReader();
  const chunks = [];
  let length = 0;
  let complete = false;
  const cancel = () => { void reader.cancel(signal?.reason).catch(() => {}); };
  signal?.addEventListener("abort", cancel, { once: true });
  try {
    while (true) {
      if (signal?.aborted) throw signal.reason;
      const { done, value } = await reader.read();
      if (signal?.aborted) throw signal.reason;
      if (done) { complete = true; break; }
      if (value.byteLength > limit - length) {
        await reader.cancel("budget response too large").catch(() => {});
        throw new Error("budget response too large");
      }
      chunks.push(value);
      length += value.byteLength;
    }
  } finally {
    signal?.removeEventListener("abort", cancel);
    if (!complete) await reader.cancel(signal?.reason || "budget response read failed").catch(() => {});
    reader.releaseLock();
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

export class AiAdmissionError extends Error {
  constructor(message, status = 503) {
    super(message);
    this.status = status;
  }
}

export function createAiAdmission(request, env, now = Date.now()) {
  if (!env.AI_BUDGET_GUARD || typeof env.AI_BUDGET_GUARD.fetch !== "function" ||
      typeof env.AI_BUDGET_ACCOUNT !== "string" || !accountKeyPattern.test(env.AI_BUDGET_ACCOUNT))
    throw new AiAdmissionError("AI budget guard is not configured");
  const suppliedKey = request.headers.get("idempotency-key");
  if (suppliedKey !== null && !idempotencyKeyPattern.test(suppliedKey))
    throw new AiAdmissionError("Invalid Idempotency-Key", 400);
  return {
    accountKey: env.AI_BUDGET_ACCOUNT,
    date: new Date(now).toISOString().slice(0, 10),
    requestKey: suppliedKey || crypto.randomUUID(),
  };
}

export async function authorizePaidOperation(env, admission, operation, estimatedMaxCostUsd, outerSignal) {
  if (!operationPattern.test(operation) || !Number.isFinite(estimatedMaxCostUsd) || estimatedMaxCostUsd <= 0)
    throw new AiAdmissionError("Invalid AI budget request");
  if (outerSignal?.aborted) throw new AiAdmissionError("AI budget guard unavailable");
  const controller = new AbortController();
  const abort = () => controller.abort();
  outerSignal?.addEventListener("abort", abort, { once: true });
  let rejectTimeout;
  const timedOut = new Promise((_, reject) => { rejectTimeout = reject; });
  const timeout = setTimeout(() => {
    abort();
    rejectTimeout(new AiAdmissionError("AI budget guard unavailable"));
  }, GATE_TIMEOUT_MS);
  let response;
  let text;
  try {
    response = await Promise.race([
      env.AI_BUDGET_GUARD.fetch("https://ai-budget-guard.internal/v1/admit", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          accountKey: admission.accountKey,
          date: admission.date,
          idempotencyKey: `${admission.requestKey}:${operation}`,
          operation,
          estimatedMaxCostUsd,
        }),
        signal: controller.signal,
      }),
      timedOut,
    ]);
    text = await Promise.race([readBoundedText(response, MAX_GATE_RESPONSE_BYTES, controller.signal), timedOut]);
  } catch {
    throw new AiAdmissionError("AI budget guard unavailable");
  } finally {
    clearTimeout(timeout);
    outerSignal?.removeEventListener("abort", abort);
  }
  let decision;
  try { decision = JSON.parse(text); } catch { throw new AiAdmissionError("Invalid AI budget guard response"); }
  if (!response.ok || !decision || typeof decision !== "object")
    throw new AiAdmissionError("Invalid AI budget guard response");
  if (decision.allowed === false && typeof decision.reason === "string")
    throw new AiAdmissionError("AI daily budget exhausted", 429);
  if (decision.allowed !== true || decision.replayed !== false ||
      typeof decision.authorizationId !== "string" || !decision.authorizationId)
    throw new AiAdmissionError("Invalid AI budget guard response");
  return decision.authorizationId;
}
