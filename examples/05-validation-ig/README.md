# 05 — Validation, Profiles & Implementation Guides

This example exercises the `$validate` operation against two Implementation
Guides installed from packages.fhir.org at boot: **US Core 5.0.1** and
**IPS 1.1.0**. It proves the server enforces profile-driven rules — required
cardinality (`us-core-patient` identifier 1..\*), profile invariants
(`us-core-6`), and required terminology bindings (`Patient.gender` →
administrative-gender ValueSet) — plus the per-call `?profile=` override and
the FHIR `Parameters` invocation wrapper. Derived from the go-fhir-server
`scripts/e2e-conformance-smoke.sh`.

## How to run

```bash
# From the repo root — boots Paito + Postgres and installs US Core + IPS
docker compose -f docker-compose.validation-ig.yml up -d

# Wait until the server is ready (and IGs are downloaded on first boot)
curl -s http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

# Run the examples
bash examples/05-validation-ig/run.sh
```

First boot downloads ~7 MB of IG packages, so give it a moment. Tear down with
`docker compose -f docker-compose.validation-ig.yml down -v`.
