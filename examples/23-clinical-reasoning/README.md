# 23 — Clinical Reasoning (CQL, Measures, CRMI, CDS Hooks)

This example walks the clinical-reasoning stack end to end: it seeds an active CQL `Library` and a proportion `Measure`, drives the CRMI artifact lifecycle (`$draft` → `$approve` → `$release`), bundles an artifact with its dependencies via `$package`, inspects a measure's data needs with `$data-requirements`, evaluates a CQL expression with `Library/$evaluate`, computes a `MeasureReport` with `$evaluate-measure`, and probes the CDS Hooks 2.0 discovery endpoint at `/cds-services`. The CRMI, `$package` and `$data-requirements` calls succeed on storage alone; the `$evaluate-measure` and `Library/$evaluate` calls return full results only when the CQL engine is enabled (it is, in the compose below) and subject data exists.

## How to run

```bash
# from the repo root
docker compose -f docker-compose.clinical-reasoning.yml up -d

# wait until the server is ready
curl -s http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

bash examples/23-clinical-reasoning/run.sh
```

Override the target with `BASE_URL` (FHIR base) and/or `SERVER_URL` (server root for CDS Hooks) if you run on a different host/port.
