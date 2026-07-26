# 01 — CRUD, History & Versioning

Demonstrates the full FHIR REST lifecycle against paito: create → read (with
`ETag`) → update (version bump) → optimistic locking with `If-Match` → instance
`_history` → `vread` of a prior version → search → references between resources
(`Observation.subject` → `Patient`) with `_revinclude`, referential-integrity
delete guard (`409` + `REFERENCE_STILL_REFERENCED`), cascade delete, tombstone
(`410 Gone`), and history that survives deletion. Every call is derived from the
proven `go-fhir-server/scripts/e2e-smoke.sh` end-to-end test.

## How to run

```bash
# from the repo root — reuse the base compose (Postgres + paito)
docker compose -f docker-compose.yml up -d

# wait for readiness, then drive the flow
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
bash examples/01-crud/run.sh
```

Override the target with `BASE_URL=... bash examples/01-crud/run.sh`.
Tear down with `docker compose -f docker-compose.yml down -v`.
