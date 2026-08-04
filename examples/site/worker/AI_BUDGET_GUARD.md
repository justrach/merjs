# AI budget guard contract

The site and Singapore Workers require an `AI_BUDGET_GUARD` service binding for every
paid AI/upstream operation. This must point to one separately deployed service backed
by a Durable Object (or an equivalent strongly consistent store). Do not replace it
with module globals, KV, or per-isolate counters.

Configure each caller with a stable `AI_BUDGET_ACCOUNT` and bind the same guard
service, as shown in both production `wrangler.toml` files. Configure daily USD limits
in the guard service, not in the caller Workers. `AI_BEARER_TOKEN` remains a required
secret on each caller.

## Admission API

The binding receives `POST https://ai-budget-guard.internal/v1/admit` with JSON:

```json
{
  "accountKey": "merlionjs-site-production",
  "date": "2026-03-10",
  "idempotencyKey": "request-uuid:openai.answer",
  "operation": "openai.answer",
  "estimatedMaxCostUsd": 0.019
}
```

The guard must route `(accountKey, date)` to one Durable Object and atomically:

1. authenticate/allow-list the service-binding caller and validate every field;
2. reject an already-seen idempotency key as a replay without charging it again;
3. reject when reserving `estimatedMaxCostUsd` would exceed that account's daily
   limit; and
4. persist the reservation and idempotency key before allowing the operation.

A new reservation returns HTTP 200 with exactly the following required fields:

```json
{"allowed":true,"replayed":false,"authorizationId":"durable-unique-id"}
```

An exhausted account returns HTTP 200 with, for example:

```json
{"allowed":false,"reason":"budget_exhausted"}
```

A duplicate may return `allowed: true` with `replayed: true`, but the caller Worker
will deny it rather than execute a paid operation twice. The guard should retain
idempotency records for at least the full UTC budget day. Admission reservations are
conservative maximum charges; any optional reconciliation must never make a paid call
possible before its reservation is durably recorded.

The callers fail closed on a missing binding/account, a two-second timeout, transport
failure, non-2xx response, malformed JSON, explicit denial, or replay. Each upstream
call has a distinct operation-suffixed idempotency key and is made only after its own
admission succeeds. A client may supply a 16-128 character `Idempotency-Key`; otherwise
the Worker creates a UUID. Bearer authentication and the concurrency/per-minute
counters remain defense-in-depth only: those counters are isolate-local and are not a
global rate or budget control.
