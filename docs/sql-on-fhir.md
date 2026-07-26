# SQL on FHIR v2 (ViewDefinition `$run`)

**What it is** — paito implements the [SQL on FHIR v2 Implementation Guide](https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/)
for projecting FHIR resources into flat, tabular views. A `ViewDefinition`
resource uses FHIRPath expressions to declare columns, filters (`where`), array
unnesting (`forEach` / `forEachOrNull`), and concatenation (`unionAll`); the
server flattens matching resources into rows and returns them as JSON, CSV, or
NDJSON. Two execution engines are available: an in-memory FHIRPath evaluator
(default) and a PostgreSQL transpiler that runs the view as native SQL over JSONB.

**When to use it**

- Build analytics-ready flat tables (CSV / NDJSON / Parquet-friendly) from FHIR without an external ETL.
- Feed BI tools, data warehouses, or notebooks with denormalized rows per Patient, Observation, etc.
- Validate a `ViewDefinition` (`$viewdefinition-validate`) in CI before shipping it.
- Bulk-export large flattened datasets asynchronously (`$viewdefinition-export`).
- Unnest repeating elements (names, telecom, addresses, codings) into one row each.

## Launch

```bash
docker compose -f docker-compose.sqlfhir.yml up -d

# readiness check
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
```

Then run the worked example:

```bash
cd examples/30-sql-on-fhir && bash run.sh
```

The operations live on the FHIR base path (`/fhir/r4`) at the system, type
(`/ViewDefinition/...`), and instance levels.

## Examples

All snippets assume `BASE=http://localhost:3500/fhir/r4`.

**1. Validate a ViewDefinition (no execution)**

```bash
curl -X POST "$BASE/\$viewdefinition-validate" \
  -H "Content-Type: application/json" \
  --data-binary @examples/30-sql-on-fhir/view-patient-demographics.json
```

Expected: an `OperationOutcome` with `severity: information`, `"ViewDefinition is valid"`. A view missing the required `resource` field returns `severity: error`.

**2. Run inline — flatten Patients to JSON `columns` + `rows`**

```bash
curl -X POST "$BASE/\$viewdefinition-run" \
  -H "Content-Type: application/json" \
  --data-binary @examples/30-sql-on-fhir/view-patient-demographics.json
```

Expected: `{"columns":[{"name":"id",...}], "rows":[["...","Garcia",...]]}`.

**3. CSV output**

```bash
curl -X POST "$BASE/\$viewdefinition-run?_format=csv" \
  -H "Content-Type: application/json" -H "Accept: text/csv" \
  --data-binary @examples/30-sql-on-fhir/view-patient-demographics.json
```

Expected: a header row `id,family,given,gender,birth_date` followed by one line per patient. Add `&header=false` to omit the header.

**4. NDJSON output (streamed)**

```bash
curl -X POST "$BASE/\$viewdefinition-run?_format=ndjson" \
  -H "Content-Type: application/json" -H "Accept: application/x-ndjson" \
  --data-binary @examples/30-sql-on-fhir/view-patient-demographics.json
```

Expected: one JSON object per line (`{"id":"...","family":"Garcia",...}`). With an `Accept` of `application/x-ndjson` or `text/csv` the response streams directly.

**5. `forEach` array unnesting — one row per telecom entry**

```bash
curl -X POST "$BASE/\$viewdefinition-run" \
  -H "Content-Type: application/json" \
  --data-binary @examples/30-sql-on-fhir/view-patient-telecom.json
```

Expected: each Patient contributes one row per `telecom` element (INNER JOIN semantics; `forEachOrNull` gives LEFT JOIN — one null-filled row when empty).

**6. Cap rows with `_limit`**

```bash
curl -X POST "$BASE/\$viewdefinition-run?_limit=1" \
  -H "Content-Type: application/json" \
  --data-binary @examples/30-sql-on-fhir/view-patient-demographics.json
```

Expected: at most one row in the output.

**7. Scope to a single patient compartment**

```bash
curl -X POST "$BASE/\$viewdefinition-run?patient=PATIENT_ID" \
  -H "Content-Type: application/json" \
  --data-binary @examples/30-sql-on-fhir/view-observation-flat.json
```

Expected: only rows for resources in that patient's compartment. `patient` and `group` are mutually exclusive.

**8. Async bulk export (opt-in) — kick off, poll, download**

```bash
# kick-off → 202 Accepted + Content-Location
curl -i -X POST "$BASE/\$viewdefinition-export" \
  -H "Content-Type: application/json" -H "Prefer: respond-async" \
  --data-binary @examples/30-sql-on-fhir/view-patient-demographics.json

# poll status → 202 (in progress) then 200 (manifest with output[].url)
curl "$BASE/_asyncstatus/<job-id>"

# download the NDJSON file listed in the manifest
curl "$BASE/_asyncdata/<job-id>"
```

Export is **experimental / opt-in** — enable it with `SQLFHIR_EXPORT_ENABLED=true` (already set in `docker-compose.sqlfhir.yml`). A `Parameters` body with repeating `viewResource` / `viewReference` entries exports multiple views in one job.

## Configuration

All keys live under `sqlfhir:` in config and map to these environment variables
(authoritative names from `internal/config/config_env.go`):

| Env var | Config key | Default | Description |
|---------|-----------|---------|-------------|
| `SQLFHIR_ENABLED` | `sqlfhir.enabled` | `false` | Master switch for all SQL-on-FHIR operations. |
| `SQLFHIR_ENGINE` | `sqlfhir.engine` | `memory` | `memory` (in-process FHIRPath) or `postgres` (SQL transpiler over JSONB). |
| `SQLFHIR_DEFAULT_FORMAT` | `sqlfhir.defaultFormat` | `ndjson` | Default output format: `ndjson`, `csv`, or `json`. |
| `SQLFHIR_MAX_ROWS_SYNC` | `sqlfhir.maxRowsSync` | `10000` | Max rows returned by synchronous `$viewdefinition-run`. |
| `SQLFHIR_MAX_RESOURCES` | `sqlfhir.maxResources` | `50000` | Max resources loaded from storage per execution. |
| `SQLFHIR_EXPORT_ENABLED` | `sqlfhir.export.enabled` | `false` | Enable async `$viewdefinition-export` (opt-in). |
| `SQLFHIR_EXPORT_TIMEOUT` | `sqlfhir.export.timeout` | `10m` | Max duration per export job. |

`$viewdefinition-run` query parameters: `viewReference` (canonical URL of a stored view; `url` is a legacy alias), `resource`, `_format`, `_limit`, `_since`, `header`, `patient`, `group`. Stored ViewDefinitions are managed via the Admin API at `/api/viewdefinitions` on port `3501`.

## References

- go-fhir-server docs: [`site/content/en/docs/fhir-api/sql-on-fhir.md`](https://github.com/gofhir/go-fhir-server/blob/main/site/content/en/docs/fhir-api/sql-on-fhir.md) (`/docs/fhir-api/sql-on-fhir/`)
- Ground-truth requests: `test/http/sqlfhir-viewdefinition.http`
- [SQL on FHIR v2 Implementation Guide](https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/)
- Related: [Bulk Data Access](./bulk-data.md), [`$transform` (FML)](https://github.com/gofhir/go-fhir-server/blob/main/site/content/en/docs/fhir-api/transform.md)
