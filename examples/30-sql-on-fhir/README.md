# 30 — SQL on FHIR v2 (ViewDefinition `$run`)

This example demonstrates the paito server's [SQL on FHIR v2](https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/)
support: projecting FHIR resources into flat, tabular views defined by
`ViewDefinition` resources and FHIRPath expressions. It seeds two Patients and an
Observation, then walks all three operations — `$viewdefinition-validate`
(accept a valid view, reject one missing `resource`), `$viewdefinition-run`
(flatten Patients to JSON `columns`/`rows`, CSV, and NDJSON; `forEach` array
unnesting of `telecom`; `_limit` capping; an Observation analytics view; and
`patient=` compartment scoping), and the opt-in async `$viewdefinition-export`
(kick-off `202` + `Content-Location`, poll to a manifest, download the NDJSON
file). Requests are derived from the go-fhir-server ground-truth collection
`test/http/sqlfhir-viewdefinition.http`.

## How to run

SQL on FHIR is enabled via `SQLFHIR_ENABLED=true` in the sqlfhir stack (async
export is turned on with `SQLFHIR_EXPORT_ENABLED=true`):

```bash
docker compose -f docker-compose.sqlfhir.yml up -d
# wait until ready:
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

bash run.sh
```

Override the endpoint with `BASE_URL=http://localhost:3500/fhir/r4 bash run.sh` if
you mapped a different port.

See [`../../docs/sql-on-fhir.md`](../../docs/sql-on-fhir.md) for the full guide.
