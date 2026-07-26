# 13 — Bulk Data Access ($export / $import)

This example demonstrates the paito server's [FHIR Bulk Data Access IG](https://hl7.org/fhir/uv/bulkdata/)
asynchronous export: it seeds a few resources, enforces the required kick-off
headers (missing `Accept` → 400, non-FHIR `Accept` → 406, exactly as verified in
the go-fhir-server `e2e-ops-sweep-smoke.sh` Step 18.10), then walks the full
three-step workflow — kick-off (`202 Accepted` + `Content-Location`), poll
(`_bulkstatus/{jobId}` returning `202` then `200` with a manifest), and download
(`_bulkdata/{jobId}/{file}` NDJSON). It exercises system-level, type-filtered
(`_type=Patient,Observation`), patient-compartment, and single-patient exports,
plus job cancellation. The experimental, opt-in `$import` operation is documented
but not run (see `docs/bulk-data.md`).

## How to run

Bulk data export is off by default, so start the bulk-data stack (base topology +
`BULK_DATA_ENABLED=true`):

```bash
docker compose -f docker-compose.bulk-data.yml up -d
# wait until ready:
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

bash run.sh
```

Override the endpoint with `BASE_URL=http://localhost:3500/fhir/r4 bash run.sh` if
you mapped a different port.

See [`../../docs/bulk-data.md`](../../docs/bulk-data.md) for the full guide.
