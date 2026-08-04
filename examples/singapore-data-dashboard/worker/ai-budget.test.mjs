import assert from "node:assert/strict";
import test from "node:test";

import {
  AiAdmissionError,
  authorizePaidOperation as authorizeSingapore,
  createAiAdmission as createSingaporeAdmission,
} from "./ai-budget.js";
import {
  authorizePaidOperation as authorizeSite,
  createAiAdmission as createSiteAdmission,
} from "../../site/worker/worker/ai-budget.js";

function request(idempotencyKey) {
  return new Request("https://example.test/api/ai", {
    headers: idempotencyKey ? { "idempotency-key": idempotencyKey } : {},
  });
}

function sharedGate(limit) {
  let spent = 0;
  const seen = new Map();
  return {
    get spent() { return spent; },
    async fetch(_url, init) {
      const body = JSON.parse(init.body);
      assert.equal(body.accountKey, "shared-production-account");
      assert.equal(body.date, "2026-03-10");
      if (seen.has(body.idempotencyKey)) {
        return Response.json({ allowed: true, replayed: true, authorizationId: seen.get(body.idempotencyKey) });
      }
      if (spent + body.estimatedMaxCostUsd > limit)
        return Response.json({ allowed: false, reason: "budget_exhausted" });
      spent += body.estimatedMaxCostUsd;
      const authorizationId = `authorization-${seen.size + 1}`;
      seen.set(body.idempotencyKey, authorizationId);
      return Response.json({ allowed: true, replayed: false, authorizationId });
    },
  };
}

const now = Date.parse("2026-03-10T12:00:00Z");

async function denied(promise, status) {
  await assert.rejects(promise, error => error instanceof Error && error.status === status);
}

test("separate Worker isolates use one deployment-wide gate", async () => {
  const gate = sharedGate(0.03);
  const env = { AI_BUDGET_ACCOUNT: "shared-production-account", AI_BUDGET_GUARD: gate };
  const siteIsolate = createSiteAdmission(request("site-request-0001"), env, now);
  const singaporeIsolate = createSingaporeAdmission(request("singapore-req-01"), env, now);

  await authorizeSite(env, siteIsolate, "openai.answer", 0.02);
  await denied(authorizeSingapore(env, singaporeIsolate, "openai.answer", 0.02), 429);
  assert.equal(gate.spent, 0.02);
});

test("missing and failed shared gates deny admission", async () => {
  assert.throws(
    () => createSingaporeAdmission(request("missing-gate-0001"), { AI_BUDGET_ACCOUNT: "shared-production-account" }, now),
    error => error instanceof AiAdmissionError && error.status === 503,
  );

  const env = {
    AI_BUDGET_ACCOUNT: "shared-production-account",
    AI_BUDGET_GUARD: { async fetch() { throw new Error("down"); } },
  };
  const admission = createSingaporeAdmission(request("failed-gate-0001"), env, now);
  await denied(authorizeSingapore(env, admission, "openai.answer", 0.02), 503);
});

test("a budget gate timeout denies execution", async () => {
  const env = {
    AI_BUDGET_ACCOUNT: "shared-production-account",
    AI_BUDGET_GUARD: { fetch() { return new Promise(() => {}); } },
  };
  const admission = createSingaporeAdmission(request("timeout-gate-0001"), env, now);
  await denied(authorizeSingapore(env, admission, "openai.answer", 0.02), 503);
});

test("oversized budget decisions are canceled and denied", async () => {
  for (const [createAdmission, authorize] of [
    [createSingaporeAdmission, authorizeSingapore],
    [createSiteAdmission, authorizeSite],
  ]) {
    let canceled = 0;
    const env = {
      AI_BUDGET_ACCOUNT: "shared-production-account",
      AI_BUDGET_GUARD: {
        async fetch() {
          return new Response(new ReadableStream({
            start(controller) { controller.enqueue(new Uint8Array(20 * 1024)); },
            cancel() { canceled++; },
          }));
        },
      },
    };
    const admission = createAdmission(request("oversized-gate-01"), env, now);
    await denied(authorize(env, admission, "openai.answer", 0.02), 503);
    assert.equal(canceled, 1);
  }
});

test("malformed decisions and replayed authorizations deny execution", async () => {
  for (const decision of [{ allowed: true }, { allowed: true, replayed: true, authorizationId: "old" }]) {
    const env = {
      AI_BUDGET_ACCOUNT: "shared-production-account",
      AI_BUDGET_GUARD: { async fetch() { return Response.json(decision); } },
    };
    const admission = createSingaporeAdmission(request("replay-check-0001"), env, now);
    await denied(authorizeSingapore(env, admission, "openai.answer", 0.02), 503);
  }
});
