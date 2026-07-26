# 24 — StructureMap `$transform` (FHIR Mapping Language)

This example demonstrates the native **FHIR Mapping Language (FML)** engine exposed
through the FHIR `$transform` operation. It uploads a `StructureMap` (both as FHIR
JSON and as human-readable FML text), then transforms `Patient` content through it,
and finally verifies the operation's `content`/`source` request contract. The map
source can be given as a canonical URL query parameter (type-level) or carried
entirely inside a `Parameters` request body.

## How to run

The base compose already includes everything needed (`$transform` is a core
operation, no extra services or config).

```bash
docker compose -f docker-compose.yml up -d
# wait until the server answers:
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

bash run.sh
```

Files:

- `structuremap-patient-normalize.json` — a StructureMap in FHIR JSON format.
- `patient-normalize.fml` — the same style of map written in FML text (uploaded with `Content-Type: text/fhir-mapping`).
- `transform-request.json` — a `Parameters` body carrying both `source` and `content`.
- `content-only.json` — a `Parameters` body with only `content` (source supplied via the `?source=` query param).
