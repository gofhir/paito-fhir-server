# 03 — Bundles

Demonstrates every FHIR R4 Bundle type the Paito server handles: **transaction**
(atomic write with `urn:uuid` forward-reference resolution and full rollback on
failure), **batch** (independent entries with partial success), **document**
(stored verbatim as a retrievable `Bundle` resource), **message** (dispatched via
the `$process-message` operation), **searchset** (the shape returned by any GET
search), and **collection** (rejected on POST). The requests here are derived
directly from the proven `e2e-bundle-smoke.sh` test in the go-fhir-server repo.

## How to run

```bash
# From the repo root — the base compose (Postgres + paito) is all you need:
docker compose up -d

# Wait for readiness, then run the demo:
bash examples/03-bundles/run.sh
```

Override the target with `BASE_URL=... bash run.sh` (default
`http://localhost:3500/fhir/r4`).
