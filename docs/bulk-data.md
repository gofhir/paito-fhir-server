# Bulk Data Access ($export / $import)

**What it is** — An implementation of the [FHIR Bulk Data Access IG](https://hl7.org/fhir/uv/bulkdata/)
for asynchronous export of large datasets as NDJSON. A client kicks off an export,
receives a `202 Accepted` with a polling URL, polls `_bulkstatus/{jobId}` until it
returns a `200` manifest, then downloads the NDJSON files from `_bulkdata/{jobId}/{file}`.
Exports run in background jobs persisted to PostgreSQL. A draft, experimental
`$import` operation reuses the same job infrastructure to bulk-load NDJSON — it is
disabled by default and guarded by a mandatory source allowlist.

**When to use it**

- Extracting a full data snapshot for analytics, a data lake, or an external warehouse.
- Population-level export scoped to a `Group` (e.g. a measure cohort) or the Patient compartment.
- Incremental sync: `_since` returns only resources changed after a timestamp, plus a `deleted` manifest section (system-level export) so a client can reconcile deletions.
- Restricting output by resource type (`_type`), per-type filters (`_typeFilter`), or elements (`_elements`).
- Bulk-loading NDJSON from a trusted, allowlisted object store via the experimental `$import` (opt-in only).

**Launch**

Bulk data export is disabled by default, so use the bulk-data stack (base topology +
`BULK_DATA_ENABLED=true`):

```bash
docker compose -f docker-compose.bulk-data.yml up -d
# readiness:
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
```

**Examples**

The FHIR base path is `/fhir/r4`. `$export` uses HTTP GET with `Prefer: respond-async`
and a FHIR `Accept` header.

1. System-level kick-off — returns `202 Accepted` with a `Content-Location` polling URL:

```bash
curl -i -X GET "http://localhost:3500/fhir/r4/\$export" \
  -H "Accept: application/fhir+json" \
  -H "Prefer: respond-async"
# HTTP/1.1 202 Accepted
# Content-Location: http://localhost:3500/fhir/r4/_bulkstatus/550e8400-...
```

2. Poll status — `202` while running, `200` with a JSON manifest when complete:

```bash
curl -i "http://localhost:3500/fhir/r4/_bulkstatus/550e8400-..."
# 202 Accepted + X-Progress + Retry-After   (in progress)
# 200 OK + manifest JSON (output[].url per type)   (complete)
```

3. Download an NDJSON file from the manifest — `Content-Type: application/fhir+ndjson`, one resource per line:

```bash
curl "http://localhost:3500/fhir/r4/_bulkdata/550e8400-.../Patient.ndjson"
# {"resourceType":"Patient","id":"p1",...}
# {"resourceType":"Patient","id":"p2",...}
```

4. Type-filtered export — only the named types:

```bash
curl -X GET "http://localhost:3500/fhir/r4/\$export?_type=Patient,Observation" \
  -H "Accept: application/fhir+json" -H "Prefer: respond-async"
# 202 Accepted; manifest output[] contains only Patient and Observation files
```

5. Incremental export — only resources changed after a timestamp (RFC 3339):

```bash
curl -X GET "http://localhost:3500/fhir/r4/\$export?_since=2026-01-01T00:00:00Z" \
  -H "Accept: application/fhir+json" -H "Prefer: respond-async"
# manifest may include a `deleted` section for system-level incremental exports
```

6. Patient-compartment and single-patient / group exports:

```bash
curl -X GET "http://localhost:3500/fhir/r4/Patient/\$export"      -H "Accept: application/fhir+json" -H "Prefer: respond-async"
curl -X GET "http://localhost:3500/fhir/r4/Patient/pat-123/\$export" -H "Accept: application/fhir+json" -H "Prefer: respond-async"
curl -X GET "http://localhost:3500/fhir/r4/Group/group-123/\$export"  -H "Accept: application/fhir+json" -H "Prefer: respond-async"
# 202 Accepted; output limited to the Patient compartment / group members
```

7. Header enforcement (Bulk Data IG §2) — a kick-off with a missing or non-FHIR `Accept` is rejected:

```bash
curl -o /dev/null -w '%{http_code}\n' -H 'Prefer: respond-async' \
  "http://localhost:3500/fhir/r4/\$export"                       # 400 (Accept required)
curl -o /dev/null -w '%{http_code}\n' -H 'Prefer: respond-async' -H 'Accept: text/html' \
  "http://localhost:3500/fhir/r4/\$export"                       # 406 (Not Acceptable)
```

8. Cancel a running job — deletes its output files:

```bash
curl -X DELETE "http://localhost:3500/fhir/r4/_bulkstatus/550e8400-..."
# 204 No Content
```

**$import (experimental, opt-in)**

`$import` is a **draft, unratified** operation. Because it makes the server fetch
NDJSON from caller-supplied URLs (an SSRF primitive), it is **disabled by default**
and has **no env-var switch** — it is enabled only through the yaml config, and an
empty `allowedSources` allowlist rejects every import (fail-closed). To enable it,
uncomment `CONFIG_PATH` and the `./config/bulk-data.yaml` volume in
`docker-compose.bulk-data.yml`, then edit the allowlist in `config/bulk-data.yaml`.
Kick-off is `POST /$import` with `Prefer: respond-async` and a `Parameters` body
(see `examples/13-bulk-data/import-parameters.json`); it returns `202` and is polled
via `_bulkstatus/{jobId}` exactly like `$export`.

**Configuration**

Only `enabled` and `dataDir` are exposed as env vars; the remaining knobs (and all
of `$import`) live in the `bulkData` yaml block, mounted via `CONFIG_PATH`.

| Env var | Config key | Description | Default |
|---------|-----------|-------------|---------|
| `BULK_DATA_ENABLED` | `bulkData.enabled` | Enable the `$export` endpoints | `false` |
| `BULK_DATA_DIR` | `bulkData.dataDir` | Directory for NDJSON output files | `./data/bulkdata` |
| — | `bulkData.maxConcurrentJobs` | Max simultaneous exports (excess → `429`) | `5` |
| — | `bulkData.maxResourcesPerFile` | Split threshold per NDJSON file | `100000` |
| — | `bulkData.retentionPeriod` | Auto-cleanup age for completed jobs | `24h` |
| — | `bulkData.cleanupInterval` | How often the cleanup job runs | `1h` |
| — | `bulkData.pageSize` | Cursor page size for export search | `500` |
| — | `bulkData.import.enabled` | Enable the experimental `$import` | `false` |
| — | `bulkData.import.allowedSources` | Allowlist of source URL prefixes (empty rejects all) | `[]` |
| — | `bulkData.import.httpTimeout` | Timeout for downloading input files | `5m` |

Notes:
- `$export` emits **NDJSON only**. `_outputFormat` accepts `application/fhir+ndjson`, `application/ndjson`, or `ndjson`; any other value is `400`. For CSV/tabular output use the SQL-on-FHIR ViewDefinition `$run` operation instead.
- Terminology is always PostgreSQL-backed; bulk data jobs persist to PostgreSQL, so this feature requires the `postgres` storage driver.

**References**

- go-fhir-server site docs: `site/content/en/docs/fhir-api/bulk-data.md`
- go-fhir-server site docs (module): `site/content/en/docs/modules/bulkdata/_index.md`
- FHIR Bulk Data Access IG: https://hl7.org/fhir/uv/bulkdata/
