# 15 — FHIR Documents (`$document`)

Demonstrates FHIR clinical documents on the Paito server. First it seeds a
`Patient`, an `Observation`, and a `Composition` that references both, then calls
**`GET /Composition/{id}/$document`** — the server assembles a self-contained
`Bundle.type = document` with the `Composition` first followed by every resource
it directly references, injecting a fresh `Bundle.identifier` and `timestamp`.
With `persist=true` the generated document is stored and retrievable as a `Bundle`.
Finally it shows **document self-containment validation**: a valid client-authored
document Bundle POSTed to `/` is stored verbatim, while one missing the required
`Bundle.identifier` is rejected `400` citing constraint `bdl-11`. The requests are
derived directly from the proven `e2e-ops-sweep-smoke.sh` (Step 8) and
`e2e-bundle-smoke.sh` (Step 7) tests in the go-fhir-server repo.

## How to run

```bash
# From the repo root — the base compose (Postgres + paito) is all you need:
docker compose up -d

# Wait for readiness, then run the demo:
bash examples/15-documents/run.sh
```

Override the target with `BASE_URL=... bash run.sh` (default
`http://localhost:3500/fhir/r4`).
