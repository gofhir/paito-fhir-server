# FHIR Operations

**What it is** — FHIR extended operations (invoked with a leading `$`) let clients do
work that plain REST CRUD cannot express: validate a resource, pull a patient's whole
record, edit resource metadata, convert serialization formats, or compute statistics.
The paito server registers these at startup and advertises them in its
`CapabilityStatement` at the correct level (system, type, or instance). This guide
covers the operations that run without extra setup: `$validate`, `Patient/$everything`,
`$meta` / `$meta-add` / `$meta-delete`, `$convert`, the discovery/analytics ops
`$versions` / `$lastn` / `$stats`, plus HTTP-level output shaping (`_pretty`,
`_summary`, `_elements`).

**When to use it**

- Validate a resource against base FHIR (and installed profiles) before storing it — `$validate`.
- Retrieve a patient's complete clinical record as one Bundle — `Patient/$everything`.
- Read or edit tags, security labels, and profile claims on a stored resource — `$meta`, `$meta-add`, `$meta-delete`.
- Convert a resource between JSON and XML without persisting it — `$convert`.
- Trim response payloads for bandwidth or privacy — `_summary`, `_elements`, `_pretty`.
- Discover server capabilities and run simple analytics — `$versions`, `Observation/$lastn`, `Observation/$stats`.

## Launch

The operations here are exercised by the terminology stack (a superset that also
enables terminology-backed validation). Reuse the existing compose file:

```bash
docker compose -f docker-compose.terminology.yml up -d

# readiness check
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo "ready"
```

The base stack (`docker compose -f docker-compose.yml up -d`) also serves every
operation below. FHIR API is on `:3500` at base path `/fhir/r4`; the Admin API is on `:3501`.

Run the full scripted demo:

```bash
cd examples/07-operations && bash run.sh
```

## Examples

All examples assume `BASE=http://localhost:3500/fhir/r4`.

**1. `$validate` a valid resource → `200` with an `OperationOutcome` and no `severity:error` issues:**

```bash
curl -s -X POST "$BASE/Patient/\$validate" \
  -H 'Content-Type: application/fhir+json' \
  -d '{"resourceType":"Patient","gender":"male"}'
```

**2. `$validate` a bad enum → `200` + `OperationOutcome` with an error citing the ValueSet:**

```bash
curl -s -X POST "$BASE/Patient/\$validate" \
  -H 'Content-Type: application/fhir+json' \
  -d '{"resourceType":"Patient","gender":"NOT-A-REAL-GENDER"}'
# → issue.code = "code-invalid", diagnostics cite administrative-gender
```

A body with no `resourceType` returns `400`.

**3. `Patient/$everything` → a `searchset` Bundle with the Patient and every compartment resource:**

```bash
curl -s "$BASE/Patient/{id}/\$everything"
# → Bundle.type = "searchset"; entries include Patient, Observation, Condition, ...
# Optional: ?_type=Observation,Condition  ?_since=2026-01-01T00:00:00Z  ?_count=100
```

An unknown patient id returns `404`.

**4. `$meta` (instance) → a `Parameters` resource whose `return` param carries `valueMeta`:**

```bash
curl -s "$BASE/Patient/{id}/\$meta"
# → Parameters { parameter:[{ name:"return", valueMeta:{ versionId, lastUpdated, tag? }}]}
```

**5. `$meta-add` / `$meta-delete` (instance, POST only) — add or remove a tag:**

```bash
curl -s -X POST "$BASE/Patient/{id}/\$meta-add" \
  -H 'Content-Type: application/fhir+json' \
  -d '{"resourceType":"Parameters","parameter":[
        {"name":"meta","valueMeta":{"tag":[
          {"system":"http://example.org/tags","code":"reviewed"}]}}]}'
# → updated Parameters/valueMeta including the new tag
```

`$meta-add` / `$meta-delete` are instance-only and POST-only: a type-level call
(`/Patient/$meta-add`) is not routable, and `GET` returns `405 Method Not Allowed`.

**6. `$convert` (system-level) — JSON in, FHIR-XML out:**

```bash
curl -s -X POST "$BASE/\$convert" \
  -H 'Content-Type: application/fhir+json' \
  -H 'Accept: application/fhir+xml' \
  -d '{"resourceType":"Patient","name":[{"family":"ConvertMe"}]}'
# → the same resource serialized as <?xml ...><Patient .../>
```

`$convert` is system-level only; it is intentionally NOT advertised under individual
resource types in the CapabilityStatement.

**7. Output shaping via HTTP query parameters:**

```bash
curl -s "$BASE/Patient/{id}?_pretty=true"          # indented, multi-line JSON
curl -s "$BASE/Patient?_summary=count"             # Bundle.total only, zero entries
curl -s "$BASE/Patient/{id}?_elements=id,name"     # sparse resource + meta.tag SUBSETTED
```

`_elements` returns only the requested fields and stamps a `SUBSETTED` tag so
consumers know the resource is partial.

**8. Discovery + analytics:**

```bash
curl -s "$BASE/\$versions"                          # Parameters: supported FHIR versions (4.0.1)
curl -s "$BASE/Observation/\$lastn?subject=Patient/{id}&code=http://loinc.org|8867-4"
curl -s "$BASE/Observation/\$stats?subject=Patient/{id}&code=http://loinc.org|8867-4&statistic=avg,min,max,count"
# $stats → Parameters { name:"statistics", resource:Observation{ component:[average,minimum,maximum,count] }}
```

Content negotiation also works globally: `Accept: application/fhir+xml` or `?_format=xml`
returns XML on any read.

## Configuration

Operations are always registered — no flag turns them on. These env vars affect the
behaviour observed in the examples (exact names from `internal/config/config_env.go`):

| Env var | Values | Effect |
|---|---|---|
| `STORAGE_DRIVER` | `postgres`, `mongodb`, `sqlite`, `mysql`, `sqlserver` | Backend that `$everything` / `$lastn` / `$stats` query. |
| `FHIR_VERSION` | `R4` (default) | FHIR release; `$versions` reports `4.0.1`. |
| `VALIDATION_ENABLED` | `true` / `false` | Enables the validation engine behind `$validate`. |
| `VALIDATION_MODE` | `enforced`, `advisory` | Whether validation issues block writes or are advisory. |
| `VALIDATION_TERMINOLOGY_MODE` | `internal`, `off`, remote | How `$validate` resolves terminology bindings. |
| `TERMINOLOGY_ENABLED` | `true` / `false` | Enables terminology so coded `$validate` and UCUM-aware `$stats` work fully. |
| `AUTH_ENABLED` | `true` / `false` | When `true`, operation endpoints require a bearer token. |

## References

- Operations overview — `go-fhir-server/site/content/en/docs/fhir-api/operations.md`
- Full operations reference table — `go-fhir-server/site/content/en/docs/fhir-api/operations-reference.md`
- `$everything` guide — `go-fhir-server/site/content/en/docs/fhir-api/everything.md`
- FHIR R4 spec: [Operations](https://hl7.org/fhir/R4/operations.html) ·
  [Patient/$everything](https://hl7.org/fhir/R4/patient-operation-everything.html) ·
  [$meta-add](https://hl7.org/fhir/R4/resource-operation-meta-add.html) ·
  [$convert](https://hl7.org/fhir/R4/resource-operation-convert.html)
