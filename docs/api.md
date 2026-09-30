# Orders API

The contract lives in [`apps/cmd/api/openapi.yaml`](../apps/cmd/api/openapi.yaml) (OpenAPI 3.1). It is embedded in the binary and served by the running api:

- **Raw spec:** https://api.demo.bulbashenko.com/openapi.yaml
- **Interactive docs:** https://editor.swagger.io/?url=https://api.demo.bulbashenko.com/openapi.yaml (the endpoint sends CORS headers for this)

Both links work only while the demo environment is up. Locally, run `make local-up` and use `http://localhost:8080`.

## Keeping the spec honest

The spec cannot drift from the code without failing `go test` (locally, in pre-commit and in CI):

| Test | Fails when |
|---|---|
| `TestOpenAPISpecIsValid` | the document is not valid OpenAPI |
| `TestSpecMatchesRoutes` | a route is registered in code but not documented, or the reverse |
| every handler test (via the `do` helper) | a handler returns a status code, header or body the spec does not describe. This covers error paths (400, 404, 500, 503) as well as success paths |

## Endpoints

| Operation | Public | Purpose |
|---|---|---|
| `POST /orders` | yes | Place an order. It is queued (`202`) and processed asynchronously |
| `GET /orders/{id}` | yes | Get a processed order. `404` until the worker has stored it |
| `GET /version` | yes | Git SHA of the build serving the request |
| `GET /burn?ms=N` | yes | Burn N ms of CPU (max 500). A load-test helper for the HPA/Karpenter demo |
| `GET /openapi.yaml` | yes | This contract |
| `GET /healthz` | cluster only | Liveness probe |
| `GET /readyz` | cluster only | Readiness probe: the database answers, and the server is not shutting down |
| `GET /metrics` | cluster only | Prometheus RED metrics |

"Public" means routed by the internet-facing ALB. The other endpoints exist on every pod but are reachable only from inside the cluster (kubelet probes, Prometheus scrapes).

Every response carries **`X-App-Version`**, the build that served it. During a canary this shows the traffic split from outside:

```bash
for i in $(seq 20); do curl -sI https://api.demo.bulbashenko.com/version | grep -i x-app-version; done | sort | uniq -c
#   16 x-app-version: 8b7ef62     ← stable
#    4 x-app-version: 3f1c2aa     ← canary at 20%
```

## Examples

```bash
API=https://api.demo.bulbashenko.com

# Place an order → 202
curl -s -XPOST $API/orders -H 'Content-Type: application/json' -d '{"item":"coffee","qty":2}'
# {"id":"f359e6b5f0870f1a50c3411f270e8d05","status":"queued"}

# Read it back → 200 once processed (usually < 1 s), 404 before that
curl -s $API/orders/f359e6b5f0870f1a50c3411f270e8d05
# {"id":"f359e6b5…","item":"coffee","qty":2,"created_at":"2026-09-30T12:27:46.685863Z","processed_at":"2026-09-30T12:27:46.868175Z"}

# Validation errors → 400
curl -s -XPOST $API/orders -d '{"item":"coffee","qty":5000}'
# {"error":"qty must be between 1 and 1000"}

# Which version am I talking to?
curl -s $API/version
# {"version":"8b7ef62"}

# Internal endpoints are not routed publicly → 404
curl -s -o /dev/null -w '%{http_code}\n' $API/metrics
# 404
```

## Errors

All error bodies have the same shape: `{"error": "<message>"}`.

| Status | When |
|---|---|
| `400` | Malformed JSON, `item` empty or longer than 100 characters, `qty` outside 1–1000 |
| `404` | Unknown order id, or accepted but not processed yet |
| `500` | Database error while reading an order. Also returned for a fraction of requests when the deployment sets `FAULT_RATE > 0` (used only to demonstrate canary rollback) |
| `503` | The queue is unavailable; the order was **not** accepted and can be retried |

## Semantics worth knowing

- **Asynchronous writes.** `202` means "durably queued in SQS", not "stored". The worker deletes the message only after the order is in PostgreSQL and the receipt is in S3.
- **At-least-once, idempotent.** A message can be delivered twice. Inserts use the order id as the primary key with `ON CONFLICT DO NOTHING`, so duplicates are harmless.
- **Poison messages.** After 5 failed attempts a message moves to the dead-letter queue. See the [runbook](runbooks/README.md#messages-in-the-dlq).
