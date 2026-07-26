# Conditional Operations & PATCH

**What it is** — Core FHIR R4 HTTP interactions that identify resources by
*search criteria* rather than a known logical id, plus optimistic-concurrency
control and partial updates. Conditional **create** (`If-None-Exist`),
conditional **update** and **delete** (`?query`), **ETag** concurrency
(`If-Match` / `If-None-Match`), and two **PATCH** dialects — JSON Patch
(RFC 6902) and FHIRPath Patch (a FHIR `Parameters` body). Every search parameter
is resolved dynamically from SearchParameter definitions — nothing is hardcoded.

**When to use it**

- Idempotent ingestion: upsert a record by business identifier (MRN, order id) without first looking up its FHIR id.
- Avoid duplicates from retries or at-least-once message delivery (`If-None-Exist`).
- Lost-update protection between concurrent writers (`If-Match` on the current ETag → `412` when stale).
- Cheap polling / cache revalidation (`If-None-Match` → `304 Not Modified`, empty body).
- Small field edits without sending (or race-clobbering) the whole resource (`PATCH`).

**Launch** — These are always-on core interactions; no feature flag or extra
service is required. Use the base stack (Postgres + Paito, auth off):

```bash
docker compose -f docker-compose.yml up -d

# readiness
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
```

Then run the worked examples:

```bash
bash examples/04-conditional-patch/run.sh
```

**Examples**

Conditional create — first call creates, a second identical call is idempotent:

```bash
# First POST with If-None-Exist → 201 Created
curl -i -X POST http://localhost:3500/fhir/r4/Patient \
  -H "Content-Type: application/fhir+json" \
  -H "If-None-Exist: identifier=http://hospital.example/mrn|MRN-001" \
  -d '{"resourceType":"Patient",
       "identifier":[{"system":"http://hospital.example/mrn","value":"MRN-001"}],
       "name":[{"family":"Cond-Create"}]}'
# → 201 Created, Location: Patient/<id>

# Same If-None-Exist again → 200 OK, returns the existing resource (no duplicate)
```

Conditional update (upsert by criteria):

```bash
# 0 matches → 201 Created; 1 match → 200 OK with versionId bumped
curl -i -X PUT "http://localhost:3500/fhir/r4/Patient?identifier=http://hospital.example/mrn|MRN-001" \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Patient",
       "identifier":[{"system":"http://hospital.example/mrn","value":"MRN-001"}],
       "name":[{"family":"CondUpd-Modified"}]}'
# → 200 OK, "versionId":"2"
```

Conditional delete:

```bash
curl -i -X DELETE "http://localhost:3500/fhir/r4/Patient?identifier=http://hospital.example/mrn|MRN-001"
# → 204 No Content (a subsequent search for that identifier returns total=0)
```

ETag concurrency — stale `If-Match` is rejected:

```bash
# Update with the current version → 200 and versionId=2
curl -i -X PUT "http://localhost:3500/fhir/r4/Patient/<id>" \
  -H 'If-Match: W/"1"' -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Patient","id":"<id>","name":[{"family":"v2"}]}'
# → 200 OK

# Reusing the now-stale W/"1" → 412 Precondition Failed
curl -i -X PUT "http://localhost:3500/fhir/r4/Patient/<id>" \
  -H 'If-Match: W/"1"' -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Patient","id":"<id>","name":[{"family":"stomp"}]}'
# → 412 Precondition Failed, OperationOutcome.code=conflict
```

Conditional read — `If-None-Match` for cache revalidation:

```bash
curl -i "http://localhost:3500/fhir/r4/Patient/<id>" -H 'If-None-Match: W/"2"'
# → 304 Not Modified, empty body (send a non-matching tag to get 200 + body)
```

JSON Patch (RFC 6902):

```bash
curl -i -X PATCH "http://localhost:3500/fhir/r4/Patient/<id>" \
  -H "Content-Type: application/json-patch+json" \
  -d '[{"op":"replace","path":"/gender","value":"female"}]'
# → 200 OK, "gender":"female", versionId bumped
```

FHIRPath Patch (FHIR `Parameters` body, `Content-Type: application/fhir+json`):

```bash
curl -i -X PATCH "http://localhost:3500/fhir/r4/Patient/<id>" \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Parameters","parameter":[
        {"name":"operation","part":[
          {"name":"type","valueCode":"replace"},
          {"name":"path","valueString":"Patient.name[0].family"},
          {"name":"value","valueString":"FHIRPathPatched"}]}]}'
# → 200 OK, family rewritten, versionId bumped
```

**Behavior reference**

| Interaction | 0 matches | 1 match | >1 match |
|-------------|-----------|---------|----------|
| Conditional create (`If-None-Exist`) | `201` create | `200` existing | `412` |
| Conditional update (`PUT ?query`) | `201` create | `200` update | `412` |
| Conditional delete (`DELETE ?query`) | `204` (no-op) | `204` | `412`* |

\* Multiple-match delete depends on server config; single-match is the common path.

| PATCH status | Meaning |
|--------------|---------|
| `200` | Patch applied |
| `400` | Invalid patch document / immutable field |
| `404` | Resource not found |
| `409` / `412` | Version conflict (`If-Match` mismatch) |
| `415` | Content-Type not a supported patch media type |
| `422` | `test` op failed, or patched resource fails validation |

**Configuration** — No feature toggle: these interactions are always enabled.
Only base server/storage settings apply (env vars, authoritative names from
`internal/config/config_env.go`):

| Env var | Purpose | Example |
|---------|---------|---------|
| `STORAGE_DRIVER` | Storage backend | `postgres` |
| `POSTGRES_HOST` | Postgres host | `postgres` |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Postgres credentials / db | `paito` |
| `FHIR_VERSION` | FHIR version | `R4` |
| `SERVER_PORT` | FHIR API port | `3500` |
| `SERVER_BASE_PATH` | FHIR base path | `/fhir/r4` |
| `AUTH_ENABLED` | Auth toggle (off for local) | `false` |
| `POSTGRES_ENFORCE_UNIQUE_IDENTIFIERS` | Optional DB-level identifier uniqueness | `false` |

> Note: the atomic (race-free) conditional create — existence re-check and
> insert inside one transaction guarded by a PostgreSQL advisory lock — is a
> PostgreSQL capability. On other SQL backends and MongoDB the conditional
> create falls back to a non-atomic check-then-create.

**References**

- go-fhir-server site docs: `site/content/en/docs/fhir-api/conditional.md`
- go-fhir-server site docs: `site/content/en/docs/fhir-api/patch.md`
- go-fhir-server site docs: `site/content/en/docs/fhir-api/patch-operations.md`
- FHIR R4 HTTP (conditional + concurrency): https://hl7.org/fhir/R4/http.html
- FHIRPath Patch: https://hl7.org/fhir/R4/fhirpatch.html
- JSON Patch (RFC 6902): https://datatracker.ietf.org/doc/html/rfc6902
