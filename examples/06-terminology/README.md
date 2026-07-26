# 06 — Terminology Service

This example exercises the Paito FHIR R4 terminology operations against the
**embedded R4 packages** that ship inside the image (core ValueSets such as
`administrative-gender`, UCUM units, and the ISO 3166-1 country codes) — no
licensed data files are required. It walks through `ValueSet/$expand`
(built-in VS, `filter`, `count`, unknown-VS error), `CodeSystem/$lookup`
(UCUM `kg`, ISO 3166 `CL`, unknown-code 404), creating a custom ValueSet and
running `ValueSet/$validate-code` (GET and POST), and initializing a durable
`$closure` session. Hierarchy operations (`$subsumes`, ISA `$expand`) and
`$translate` need real clinical code systems loaded — see the repo `docs/terminology.md`.

## How to run

```bash
# From the repo root: launch the terminology stack
docker compose -f docker-compose.terminology.yml up -d

# Wait for readiness, then run the demo
bash examples/06-terminology/run.sh
```

`BASE_URL` defaults to `http://localhost:3500/fhir/r4`; override it if you
mapped the FHIR port elsewhere. Stop the stack with
`docker compose -f docker-compose.terminology.yml down -v`.
