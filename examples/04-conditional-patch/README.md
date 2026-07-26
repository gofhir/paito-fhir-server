# 04 — Conditional Operations & PATCH

Demonstrates identifying resources by search criteria instead of logical id
(conditional **create** via `If-None-Exist`, conditional **update**/**delete**
via `?query`), optimistic-concurrency control with **ETag** + `If-Match` /
`If-None-Match` (200 / 412 / 304), and partial updates with both **JSON Patch**
(RFC 6902) and **FHIRPath Patch** (a FHIR `Parameters` body). The flow is a
copy-pasteable subset of the proven `e2e-advanced-smoke.sh` test.

## How to run

Start the base stack (Postgres + Paito, no auth) from the repo root, then run
the script:

```bash
docker compose up -d
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

bash examples/04-conditional-patch/run.sh
```

Override the target with `BASE_URL=... bash run.sh`. Each run uses a unique
MRN, so it is safe to re-run against the same server.
