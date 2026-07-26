# 29 — HL7 v2 Integration (`$parse-v2`)

This example demonstrates parsing a raw HL7v2 message (an ADT^A01 admit) into a
JSON FHIR **logical-model instance**. Parsing is driven entirely by a logical-model
`StructureDefinition` whose elements carry HL7 v2 field mappings
(`mapping.identity = "v2"`, e.g. `PID.5.1`). The script registers the logical model,
POSTs the message to `/$parse-v2` with the `X-V2-Profile` header, and verifies the
serialized output (repeating `patientId` fields, two `NK1` segments) against the
mapping. It also shows the 400 (missing header) and 404 (unknown profile) errors.

## How to run

The HL7 v2 parser is always enabled — no special configuration is needed, so the
base stack works:

```bash
docker compose -f docker-compose.yml up -d
# wait until ready:
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

bash run.sh
```

## Files

- `adt-a01-logical.json` — logical-model `StructureDefinition` (`kind: logical`) with v2 mappings
- `adt-a01.hl7` — raw HL7v2 ADT^A01 message
- `run.sh` — registers the SD, calls `$parse-v2`, checks the result and error paths
