# 11 — Multi-Tenancy (header isolation)

Demonstrates end-to-end tenant data isolation on a single paito server. Two
tenants — `tenant-a` and `tenant-b` — are selected purely by the `X-Tenant-ID`
request header. The demo proves that a resource created under one tenant is
invisible to the other for read, search, delete, and version/history, that a
data request without a tenant is rejected (`401` with `issue.code=security`)
while public endpoints (`/metadata`, `/health`) stay reachable without one, and
that the SAME logical id can coexist independently in each tenant. Every call is
derived from the proven `go-fhir-server/scripts/e2e-tenancy-smoke.sh` test.

## How to run

```bash
# from the repo root — bring up the strict header-mode tenancy stack
docker compose -f docker-compose.multitenancy.yml up -d

# wait for readiness (metadata is public, no tenant needed), then drive the flow
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
bash examples/11-multi-tenancy/run.sh
```

Override the target with `BASE_URL=... bash examples/11-multi-tenancy/run.sh`.
Tear down with `docker compose -f docker-compose.multitenancy.yml down -v`.
