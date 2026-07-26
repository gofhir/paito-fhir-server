# HL7 v2 Integration

**What it is** — paito FHIR Server can parse raw HL7v2 pipe-delimited messages
into JSON FHIR **logical-model instances** via the `$parse-v2` operation. Parsing is
driven entirely by a FHIR logical-model `StructureDefinition` (`kind: logical`) whose
elements carry HL7 v2 field mappings (`mapping.identity = "v2"`, e.g. `PID.5.1`) —
nothing about the v2 structure is hard-coded. The resulting logical-model instance can
then be transformed into a standard FHIR resource with the FML `$transform` operation,
giving a complete v2-to-FHIR pipeline. This bridges legacy HL7v2 feeds (ADT, ORU, ORM…)
into FHIR.

**When to use it**

- Ingesting ADT / ORU / ORM (and other) HL7v2 feeds from legacy hospital systems
- Building a v2-to-FHIR conversion pipeline (`$parse-v2` → FML `$transform`)
- Prototyping v2 mappings without writing custom code — mappings live in a StructureDefinition
- Normalizing pipe-delimited messages into JSON for downstream tooling

## Launch

The parser is always enabled and needs no configuration, so the base stack is enough:

```bash
docker compose -f docker-compose.yml up -d

# readiness check
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
```

Then run the worked example:

```bash
cd examples/29-hl7v2 && bash run.sh
```

## Examples

The `$parse-v2` operation is served at `<base>/$parse-v2`, i.e.
`http://localhost:3500/fhir/r4/$parse-v2`. It takes the raw message as a
`text/plain` body and the logical-model canonical URL in the `X-V2-Profile` header.

### 1. Register a logical-model StructureDefinition

The SD must be `kind: "logical"`; each mapped element needs a `mapping` entry with
`identity: "v2"` and a `map` using `SEGMENT.field.component` (1-based) notation.

```bash
curl -X PUT http://localhost:3500/fhir/r4/StructureDefinition/adt-a01-logical \
  -H "Content-Type: application/fhir+json" \
  --data-binary @examples/29-hl7v2/adt-a01-logical.json
```

Expected: `200 OK` (or `201 Created`); the SD `url` is
`http://example.org/StructureDefinition/ADT-A01`.

### 2. Parse a raw ADT^A01 message

```bash
curl -X POST 'http://localhost:3500/fhir/r4/$parse-v2' \
  -H "Content-Type: text/plain" \
  -H "X-V2-Profile: http://example.org/StructureDefinition/ADT-A01" \
  --data-binary $'MSH|^~\\&|HIS|HOSP||FHIR|20240115||ADT^A01|MSG001|P|2.5\nPID|||12345^^^HOSP^MR~67890^^^SSA^SS||Smith^John||19850315|M\nNK1|1|Doe^Jane|SPO\nNK1|2|López^Ana|MTH'
```

Expected `200 OK`, a JSON logical-model instance (`resourceType` = the SD's `type`).
Repeating `patientId` becomes an array; the two `NK1` segments become an array:

```json
{
  "resourceType": "ADT-A01",
  "PID": {
    "patientId": [
      { "value": "12345", "authority": "HOSP", "typeCode": "MR" },
      { "value": "67890", "authority": "SSA", "typeCode": "SS" }
    ],
    "familyName": "Smith",
    "givenName": ["John"],
    "dateOfBirth": "19850315",
    "gender": "M"
  },
  "NK1": [
    { "familyName": "Doe", "givenName": "Jane", "relationship": "SPO" },
    { "familyName": "López", "givenName": "Ana", "relationship": "MTH" }
  ]
}
```

### 3. Missing `X-V2-Profile` header → 400

```bash
curl -i -X POST 'http://localhost:3500/fhir/r4/$parse-v2' \
  -H "Content-Type: text/plain" \
  --data-binary @examples/29-hl7v2/adt-a01.hl7
```

Expected: `400 Bad Request`, body `{"error":"X-V2-Profile header is required"}`.

### 4. Unknown profile URL → 404

```bash
curl -i -X POST 'http://localhost:3500/fhir/r4/$parse-v2' \
  -H "Content-Type: text/plain" \
  -H "X-V2-Profile: http://example.org/StructureDefinition/DOES-NOT-EXIST" \
  --data-binary @examples/29-hl7v2/adt-a01.hl7
```

Expected: `404 Not Found`, body `{"error":"failed to load profile: ..."}`.

### 5. (Optional) Chain into FHIR with `$transform`

For a full v2→FHIR conversion, feed the logical-model instance from step 2 into an
FML StructureMap:

```bash
curl -X POST 'http://localhost:3500/fhir/r4/StructureMap/adt-to-patient/$transform' \
  -H "Content-Type: application/fhir+json" \
  --data-binary @logical-model.json
```

See the FML `$transform` example (`examples/24-transform-fml`) for authoring StructureMaps.

## Configuration

The HL7 v2 parser requires **no** feature flag — the `$parse-v2` route is registered
automatically at server startup. The relevant knobs are general server settings and
the built-in parser safety limits.

| Env var | Config key | Default | Purpose |
|---------|-----------|---------|---------|
| `SERVER_BASE_PATH` | `server.basePath` | `/fhir/r4` (paito image) | Prefix the operation is mounted under (`<base>/$parse-v2`) |
| `FHIR_VERSION` | `server.fhirVersion` | `R4` | FHIR release |

Built-in parser safety limits (not configurable): max message size 1 MB, max 1,000
segments, max 100 field repetitions.

The logical-model StructureDefinition is supplied at runtime, either by:

- **Direct upload** — `PUT /fhir/r4/StructureDefinition/{id}` with the logical-model JSON
- **IG packages** that contain the logical-model SD

## References

- go-fhir-server site docs — `fhir-api/hl7v2-integration.md` (`$parse-v2` overview)
- go-fhir-server site docs — `fhir-api/hl7v2-parser.md` (parser internals, mapping notation, repeating fields/segments)
- go-fhir-server site docs — `modules/hl7v2/_index.md` (package reference)
- [HL7 v2-to-FHIR Implementation Guide](https://build.fhir.org/ig/HL7/v2-to-fhir/)
- [FHIR Logical Models](https://hl7.org/fhir/R4/structuredefinition.html#logical)
