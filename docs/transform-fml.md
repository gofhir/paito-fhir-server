# StructureMap `$transform` (FHIR Mapping Language)

**What it is** — paito ships a native **FHIR Mapping Language (FML)** engine that
executes `StructureMap` transformations. The FHIR `$transform` operation applies a
stored `StructureMap` to input content and returns the transformed result. The
engine supports the full FML lifecycle — parse FML text to an AST, serialize to a
FHIR `StructureMap` JSON, render back to FML text, and execute the transform — with
15 built-in transform functions (`copy`, `create`, `uuid`, `reference`, `translate`,
`cc`, `c`, `qty`, `id`, `cp`, `append`, `truncate`, `cast`, `evaluate`, `pointer`).
`$transform` is a core operation and is available out of the box; no extra
configuration is required.

**When to use it**

- Convert a resource from one structure/profile into another (normalization, de-identification, restructuring).
- Map between FHIR versions or between a source system's shape and your canonical model.
- Run instance-level or type-level transformations driven by declarative, versionable `StructureMap` rules instead of hand-written code.
- Author maps in the readable FML text syntax and store them as standard FHIR `StructureMap` resources.

## Launch

`$transform` needs no special stack — use the base compose:

```bash
docker compose -f docker-compose.yml up -d

# readiness
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
```

## Examples

Runnable end-to-end script: [`examples/24-transform-fml/run.sh`](../examples/24-transform-fml/run.sh).

**1. Upload a StructureMap (FHIR JSON)**

```bash
curl -X POST http://localhost:3500/fhir/r4/StructureMap \
  -H "Content-Type: application/fhir+json" \
  --data-binary @examples/24-transform-fml/structuremap-patient-normalize.json
```
Expected: `201 Created` with the stored `StructureMap` (canonical url
`http://example.org/fhir/StructureMap/PatientNormalize`).

**2. Upload a StructureMap written in FML text**

```bash
curl -X POST http://localhost:3500/fhir/r4/StructureMap \
  -H "Content-Type: text/fhir-mapping" \
  --data-binary @examples/24-transform-fml/patient-normalize.fml
```
Expected: `201 Created`. The server parses the FML text, converts it to a FHIR
`StructureMap` JSON resource, and stores it (readable back as JSON).

**3. `$transform` — source as query parameter (type-level)**

```bash
curl -X POST \
  'http://localhost:3500/fhir/r4/StructureMap/$transform?source=http://example.org/fhir/StructureMap/PatientNormalize' \
  -H "Content-Type: application/fhir+json" \
  --data-binary @examples/24-transform-fml/content-only.json
```
Expected: `200 OK` with a `Parameters` resource whose `return` parameter holds the
transformed resource.

**4. `$transform` — source and content in one Parameters body**

```bash
curl -X POST http://localhost:3500/fhir/r4/StructureMap/$transform \
  -H "Content-Type: application/fhir+json" \
  --data-binary @examples/24-transform-fml/transform-request.json
```
Expected: `200 OK`, same shape as above. The `source` (canonical URL) and the
`content` resource both travel as `Parameters.parameter` entries.

**5. Missing `content` → `400`**

```bash
curl -i -X POST http://localhost:3500/fhir/r4/StructureMap/$transform \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Parameters","parameter":[{"name":"source","valueUri":"http://example.org/fhir/StructureMap/PatientNormalize"}]}'
```
Expected: `400 Bad Request`, `OperationOutcome` with issue `code: "required"`
(content is `1..1` per the canonical OperationDefinition).

**6. Unknown StructureMap URL → `404`/`422`**

```bash
curl -i -X POST http://localhost:3500/fhir/r4/StructureMap/$transform \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Parameters","parameter":[{"name":"source","valueUri":"http://example.org/fhir/StructureMap/DoesNotExist"},{"name":"content","resource":{"resourceType":"Patient"}}]}'
```
Expected: `404 Not Found` (map cannot be resolved) — or `422` if the map resolves
but the transformation fails.

## Request contract

| Level | URL | Source of the map |
|-------|-----|-------------------|
| Type-level | `POST /StructureMap/$transform?source=<canonical-url>` | `source` query param, or a `source` `valueUri` in the `Parameters` body |
| Instance-level | `POST /StructureMap/{id}/$transform` | the URL `{id}` (the map's resource id) |

The `content` parameter (the resource to transform) is **required** (`1..1`) and is
carried as a `resource` inside a `Parameters` body. The result is returned as a
`Parameters` resource with a `return` parameter.

Status codes: `200` success · `400` missing `source`/`content` · `404` map not
found · `422` transformation failed (rule error, type mismatch, or a DoS limit hit).

## Configuration

The FML engine and `$transform` are enabled automatically when storage is
available — there are no dedicated environment variables. The base compose settings
are all that is required.

| Env var | Value (base compose) | Purpose |
|---------|----------------------|---------|
| `STORAGE_DRIVER` | `postgres` | Backing store (StructureMaps persist as FHIR resources) |
| `POSTGRES_HOST` / `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `postgres` / `paito` / `paito` / `paito` | PostgreSQL connection |
| `FHIR_VERSION` | `R4` | FHIR version |
| `AUTH_ENABLED` | `false` | Auth disabled for the demo |

Built-in DoS protections applied by the engine (fixed defaults): parse depth 50,
max rules 1000, execution depth 50, group calls 200, FHIRPath evaluations 500.
Exceeding any limit returns `422 Unprocessable Entity`.

## References

- go-fhir-server site docs — `$transform` operation & FML: `site/content/en/docs/fhir-api/transform.md`
- go-fhir-server site docs — FML engine module: `site/content/en/docs/modules/fml/_index.md`
- FHIR R4 — [StructureMap `$transform`](https://hl7.org/fhir/R4/structuremap-operation-transform.html)
- FHIR R4 — [FHIR Mapping Language](https://hl7.org/fhir/R4/mapping-language.html)
