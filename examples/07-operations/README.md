# 07 — FHIR Operations

This example demonstrates the paito server's FHIR R4 extended operations: resource
validation (`$validate`), patient-record retrieval (`Patient/$everything`), meta
manipulation (`$meta`, `$meta-add`, `$meta-delete`), format conversion (`$convert`),
response output shaping (`_pretty`, `_summary`, `_elements`), and the discovery /
analytics operations `$versions`, `Observation/$lastn`, and `Observation/$stats`.
Every call is derived from the proven go-fhir-server e2e smoke tests
(`e2e-ops-smoke.sh`, `e2e-ops-sweep-smoke.sh`, `e2e-operation-smoke.sh`).

## How to run

Start a stack (the terminology stack enables the full operation set), then run the script:

```bash
docker compose -f docker-compose.terminology.yml up -d
# wait until ready:
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

bash run.sh
```

The plain base stack (`docker compose -f docker-compose.yml up -d`) also works for
every operation shown here except that `$stats`/`$lastn` UCUM unit handling is best
exercised with terminology enabled. Override the endpoint with
`BASE_URL=http://localhost:3500/fhir/r4 bash run.sh` if you mapped a different port.

See [`../../docs/operations.md`](../../docs/operations.md) for the full guide.
