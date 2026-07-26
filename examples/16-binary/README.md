# 16 — Binary Resource (raw upload / download)

Demonstrates the FHIR `Binary` resource's dual wire behavior: uploading a raw
(non-FHIR) body so the server wraps it into a `Binary` resource, downloading the
raw decoded bytes with a non-FHIR `Accept`, reading the same object back as the
FHIR resource JSON, the `_format` override, `PUT`-as-raw with a URL id, the
`X-Security-Context` header that populates `Binary.securityContext.reference`,
and posting a native FHIR `Binary` resource. Raw downloads are served defensively
(`Content-Disposition: attachment`, `X-Content-Type-Options: nosniff`) so active
content is never rendered inline.

## How to run

```bash
# from the repo root — the base compose already covers Binary (core CRUD)
docker compose -f docker-compose.yml up -d

# wait until ready, then:
bash examples/16-binary/run.sh
```

Override the target with `BASE_URL=... bash examples/16-binary/run.sh`
(default `http://localhost:3500/fhir/r4`).

Files:
- `note.txt` — raw text payload uploaded on the wrap path.
- `binary-fhir.json` — a native FHIR `Binary` resource (base64 `data` + `securityContext`).
