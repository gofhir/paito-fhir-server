# Search (all parameters & modifiers)

**What it is** — The paito FHIR server implements the [FHIR R4 Search specification](https://hl7.org/fhir/R4/search.html) with search parameters loaded dynamically from `SearchParameter` definitions (all standard R4 parameters plus any from installed Implementation Guides). Every search returns a `Bundle` of `type: searchset`. Search runs out of the box on the base stack — no extra configuration is required.

**When to use it**
- Look up resources by any FHIR parameter type: string, token, date, reference, quantity, number, uri, composite.
- Refine matches with modifiers (`:exact`, `:contains`, `:not`, `:above`, `:below`, `:identifier`, …).
- Pull related resources in one round trip with `_include` / `_revinclude`.
- Query across references with chained search and reverse-chained `_has`.
- Sort (`_sort`), page (`_count` + `link[next]`), and shape results (`_summary`, `_elements`).

## Launch

Search is part of the core server, so the base compose is all you need:

```bash
docker compose -f docker-compose.yml up -d

# Readiness check
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo "server up"
```

Then run the worked examples:

```bash
bash examples/02-search/run.sh
```

FHIR API base path is `/fhir/r4` on port `:3500`. All examples below assume `BASE=http://localhost:3500/fhir/r4`.

## Examples

**String parameter + modifiers.** Default is a case-insensitive prefix match; `:exact` and `:contains` change the semantics.

```bash
# Case-insensitive prefix match
curl "http://localhost:3500/fhir/r4/Patient?family=SearchDemo"
# -> Bundle.total = number of patients whose family starts with "SearchDemo"

curl "http://localhost:3500/fhir/r4/Patient?given:exact=Ana"      # exact, case-sensitive -> 1
curl "http://localhost:3500/fhir/r4/Patient?family:contains=archDem"  # substring anywhere
```

**Token parameter (`system|code`) + `:not`.**

```bash
curl "http://localhost:3500/fhir/r4/Patient?gender=female"
curl "http://localhost:3500/fhir/r4/Patient?gender:not=female"
curl "http://localhost:3500/fhir/r4/Patient?identifier=http://hospital.example/mrn|SD-002"
curl "http://localhost:3500/fhir/r4/Observation?code=http://loinc.org|8867-4"
# -> matching searchset Bundle
```

**Date parameter with comparison prefixes.** Prefixes: `eq` `ne` `gt` `lt` `ge` `le` `sa` `eb`.

```bash
curl "http://localhost:3500/fhir/r4/Patient?birthdate=gt1988-01-01"          # born after
curl "http://localhost:3500/fhir/r4/Patient?birthdate=ge1989&birthdate=le1992"  # range (AND)
# -> patients whose birthDate falls in the requested window
```

**Reference, quantity and composite (Observation).**

```bash
curl "http://localhost:3500/fhir/r4/Observation?subject=Patient/PID"         # reference
curl "http://localhost:3500/fhir/r4/Observation?value-quantity=gt60"         # quantity, numeric
curl "http://localhost:3500/fhir/r4/Observation?value-quantity=72||/min"     # value + unit
# composite: both criteria must match on the SAME element ($ separates components)
curl "http://localhost:3500/fhir/r4/Observation?code-value-quantity=http://loinc.org|8867-4\$gt60"
# -> the heart-rate Observation (code 8867-4 AND value > 60)
```

**Chained search and reverse chaining (`_has`).**

```bash
# forward chain: Observations whose subject Patient has family "SearchDemo"
curl "http://localhost:3500/fhir/r4/Observation?subject:Patient.family=SearchDemo"
# reverse chain: Patients who are the subject of an Observation with a given code
curl "http://localhost:3500/fhir/r4/Patient?_has:Observation:subject:code=http://loinc.org|8867-4"
# -> Patients matched via the referencing Observation
```

**`_include` / `_revinclude`.** Included resources appear in the Bundle with `search.mode = "include"`.

```bash
# forward: pull the referenced Patient alongside each Observation
curl "http://localhost:3500/fhir/r4/Observation?subject=Patient/PID&_include=Observation:subject"
# -> Bundle with 1 entry search.mode="match" + 1 entry search.mode="include"

# reverse: pull Observations that reference the Patient
curl "http://localhost:3500/fhir/r4/Patient?_id=PID&_revinclude=Observation:subject"
# -> Patient entry + its Observation entries
```

**Sorting and paging.** Prefix `_sort` with `-` for descending; page with `_count` and follow `link[next]`.

```bash
curl "http://localhost:3500/fhir/r4/Patient?family=SearchDemo&_sort=-birthdate"  # youngest first
curl "http://localhost:3500/fhir/r4/Patient?family=SearchDemo&_count=2"          # page 1 (2 entries) + link[next]
# -> Bundle.link[relation=next].url is the cursor for the following page
```

**Result shaping.**

```bash
curl "http://localhost:3500/fhir/r4/Patient?family=SearchDemo&_summary=count"   # total only, no entries
curl "http://localhost:3500/fhir/r4/Patient?_elements=name,birthDate"           # only requested elements (+ id/meta)
# -> trimmed resources / count-only Bundle
```

**Unknown parameters.** By default the server is lenient (FHIR R4 §3.1.1.3): unknown parameters are ignored and reported as a `warning` in an `OperationOutcome` entry (`search.mode = "outcome"`). Send `Prefer: handling=strict` to get `400 Bad Request` instead.

**Full-text (`_text` / `_content`) is opt-in.** These special parameters require the full-text engine to be enabled (`FULLTEXT_ENABLED=true`). Without it they return empty results. Rebuild the index for pre-existing resources with `POST /{resourceType}/$reindex`.

## Configuration

Search itself needs no configuration. The base stack settings plus a couple of optional search knobs:

| Env var | Config key | Default | Purpose |
|---------|-----------|---------|---------|
| `STORAGE_DRIVER` | `storage.driver` | `postgres` | Storage backend (search index tables live here). |
| `POSTGRES_HOST` / `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `storage.postgres.*` | — | Postgres connection. |
| `FHIR_VERSION` | `fhir.version` | `R4` | FHIR version; base path is `/fhir/r4`. |
| `SEARCH_DEFAULT_TOTAL_MODE` | `search.defaultTotalMode` | `estimate` | Default `_total` behaviour (`none` / `estimate` / `accurate`) when the request omits `_total`. |
| `FULLTEXT_ENABLED` | `fullText.enabled` | `false` | Enables `_text` / `_content` full-text search (opt-in). |
| `FULLTEXT_ENGINE` | `fullText.engine` | `bleve` | Full-text engine when enabled. |
| `BLEVE_DATA_DIR` | `fullText.bleve.dataDir` | — | On-disk path for the Bleve full-text index. |

Notes: `_count` is capped at **1000** per page; a capped page carries an informational `OperationOutcome` entry alongside `link[next]`. System-level search (`GET /?_type=Patient,Practitioner&...`) requires the `_type` parameter.

## References

- go-fhir-server docs — Search: `site/content/en/docs/fhir-api/search.md`
- go-fhir-server docs — Search parameters: `site/content/en/docs/search-indexing/search-parameters.md`
- go-fhir-server docs — Chaining & `_has`: `site/content/en/docs/search-indexing/chaining.md`
- go-fhir-server docs — Composite search: `site/content/en/docs/search-indexing/composite-search.md`
- go-fhir-server docs — `_include` / `_revinclude`: `site/content/en/docs/search-indexing/include-revinclude.md`
- go-fhir-server docs — Token modifiers: `site/content/en/docs/search-indexing/token-modifiers.md`
- go-fhir-server docs — Full-text search: `site/content/en/docs/search-indexing/full-text-search.md`
- FHIR R4 Search specification: https://hl7.org/fhir/R4/search.html
