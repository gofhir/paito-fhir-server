# Terminology Service

**What it is** — Paito implements the full set of FHIR R4 terminology
operations: `ValueSet/$expand`, `ValueSet/$validate-code`,
`CodeSystem/$lookup`, `CodeSystem/$validate-code`, `CodeSystem/$subsumes`,
`ConceptMap/$translate`, and `$closure`. Out of the box it serves the
**embedded FHIR R4 packages** (core ValueSets like `administrative-gender`,
UCUM units, and ISO 3166-1 country codes). Real clinical code systems —
SNOMED CT (International / Spanish / Chile editions), LOINC, ICD-10, ICD-O-3,
and the Chilean **FONASA** billing catalogs (MLE/MAI) — are loaded on demand
from source files. FONASA + SNOMED CT Chile Edition support is unusual among
open-source FHIR servers.

**When to use it**

- Validate that a `Coding`/`CodeableConcept` value is in an allowed ValueSet.
- Expand a ValueSet for pick-lists, autocompletes, or client-side validation.
- Look up display names, designations (multilingual), and properties for a code.
- Test subsumption (is-a) between two codes in a hierarchy (e.g. SNOMED CT).
- Translate a code from one system to another via a ConceptMap.
- Maintain a running subsumption `$closure` table across many requests.

## Launch

The embedded-package profile requires no licensed files:

```bash
docker compose -f docker-compose.terminology.yml up -d

# Readiness check (ISO 3166 is indexed asynchronously just after boot)
curl -s http://localhost:3500/fhir/r4/metadata | head -c 200
curl -s "http://localhost:3500/fhir/r4/CodeSystem/\$lookup?system=urn:iso:std:iso:3166&code=CL"
```

To load real clinical terminologies, uncomment the opt-in env vars + volume
mount in `docker-compose.terminology.yml` and drop the licensed source
archives under `./terminology`. **First SNOMED boot takes 5–10 minutes**
(transitive-closure build); subsequent boots against the same Postgres volume
are fast. Code systems load asynchronously — `/metadata` responds before a
`$lookup` against a freshly loaded system succeeds.

## Examples

All paths use the FHIR base `/fhir/r4`. In shells escape `$` as `\$`.

**1. Expand a built-in ValueSet** — returns 4 codes (male/female/other/unknown):

```bash
curl "http://localhost:3500/fhir/r4/ValueSet/\$expand?url=http://hl7.org/fhir/ValueSet/administrative-gender"
# -> Parameters/ValueSet with expansion.total = 4
```

**2. Expand with filter + count**:

```bash
curl "http://localhost:3500/fhir/r4/ValueSet/\$expand?url=http://hl7.org/fhir/ValueSet/administrative-gender&filter=female"
# -> expansion.total = 1 (only "female")
curl "http://localhost:3500/fhir/r4/ValueSet/\$expand?url=http://hl7.org/fhir/ValueSet/administrative-gender&count=2"
# -> expansion.contains has 2 entries (bounded)
```

**3. Lookup a UCUM unit**:

```bash
curl "http://localhost:3500/fhir/r4/CodeSystem/\$lookup?system=http://unitsofmeasure.org&code=kg"
# -> Parameters with display=kilogram + properties (canonical form, mass dimension)
```

**4. Lookup an ISO 3166 country**:

```bash
curl "http://localhost:3500/fhir/r4/CodeSystem/\$lookup?system=urn:iso:std:iso:3166&code=CL"
# -> Parameters with display=Chile ; unknown code -> HTTP 404 not-found
```

**5. Create a custom ValueSet, then validate a code against it**:

```bash
curl -X POST http://localhost:3500/fhir/r4/ValueSet \
  -H "Content-Type: application/fhir+json" \
  --data-binary @examples/06-terminology/valueset-latam-countries.json
# -> 201 Created

curl "http://localhost:3500/fhir/r4/ValueSet/\$validate-code?url=http://example.org/fhir/ValueSet/latam-countries&system=urn:iso:std:iso:3166&code=CL"
# -> result=true, display "Chile"
curl "http://localhost:3500/fhir/r4/ValueSet/\$validate-code?url=http://example.org/fhir/ValueSet/latam-countries&system=urn:iso:std:iso:3166&code=US"
# -> result=false + message (US is outside the VS)
```

**6. `$closure` — initialize a durable subsumption session** (PostgreSQL-backed
sessions survive restarts):

```bash
curl -X POST http://localhost:3500/fhir/r4/\$closure \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Parameters","parameter":[{"name":"name","valueString":"demo-closure-session"}]}'
# -> ConceptMap for the session (empty group until concepts are added)
```

The following need real clinical code systems loaded (opt-in block):

**7. SNOMED CT `$subsumes`** (Diabetes subsumes Type-2 diabetes):

```bash
curl "http://localhost:3500/fhir/r4/CodeSystem/\$subsumes?system=http://snomed.info/sct&codeA=73211009&codeB=44054006"
# -> outcome = subsumes  (unrelated branches -> not-subsumed)
```

**8. SNOMED ISA `$expand` + multilingual `$lookup`**:

```bash
curl "http://localhost:3500/fhir/r4/ValueSet/\$expand?url=http://snomed.info/sct?fhir_vs=isa/73211009&count=10"
# -> descendants of Diabetes mellitus
curl "http://localhost:3500/fhir/r4/CodeSystem/\$lookup?system=http://snomed.info/sct&code=73211009&displayLanguage=es-CL"
# -> Chilean-Spanish designation
```

**9. `ConceptMap/$translate`** (requires a loaded ConceptMap):

```bash
curl "http://localhost:3500/fhir/r4/ConceptMap/\$translate?url=http://example.org/fhir/ConceptMap/icd10-to-snomed&system=http://hl7.org/fhir/sid/icd-10&code=E11"
# -> result=true with a matched target Coding
```

## Configuration

Configured via environment variables (see `docker-compose.terminology.yml`).
Names below are authoritative (`internal/config/config_env.go`).

| Env var | Purpose |
|---------|---------|
| `TERMINOLOGY_ENABLED` | Master switch — enables the operation handlers. Set `"true"`. |
| `TERMINOLOGY_SNOMED_PATH` / `_URL` | SNOMED CT RF2 source (mounted file or download URL). |
| `TERMINOLOGY_SNOMED_VERSION` / `_NAME` | SNOMED edition version / CodeSystem name. |
| `TERMINOLOGY_LOINC_PATH` / `_URL` / `_VERSION` | LOINC source, version. |
| `TERMINOLOGY_ICD10_PATH` / `_URL` / `_VERSION` | ICD-10 source. |
| `TERMINOLOGY_ICDO_PATH` / `_URL` / `_VERSION` | ICD-O-3 (oncology morphology) source. |
| `TERMINOLOGY_FONASA_PATH` / `_URL` / `_VERSION` | FONASA MLE (Chilean billing) source. |
| `TERMINOLOGY_FONASA_MAI_PATH` / `_URL` / `_VERSION` | FONASA MAI (public-sector billing) source. |
| `TERMINOLOGY_POSTGRES_HOST` / `_PORT` / `_USER` / `_PASSWORD` / `_DATABASE` | Optional dedicated Postgres for terminology storage + durable `$closure`. |

Notes:
- With no `TERMINOLOGY_*_PATH` configured, only the embedded R4 packages are
  served (enough for the examples 1–6 above).
- Remote fallback to an external terminology server (e.g. tx.fhir.org) is
  **off** unless a `terminology.remote` block is set in a mounted config file;
  the embedded profile is fully hermetic.
- Durable `$closure` sessions require PostgreSQL terminology storage; without
  it, sessions are process-local and lost on restart.

## References

- go-fhir-server site docs — Terminology Operations API reference:
  `site/content/en/docs/fhir-api/terminology-operations.md`
- go-fhir-server site docs — Terminology Guide (4-tier expansion, architecture):
  `site/content/en/docs/terminology-guide/`
- go-fhir-server site docs — Loading terminologies (SNOMED/LOINC/ICD/FONASA):
  `site/content/en/docs/terminology-guide/loading-terminologies.md`
- go-fhir-server site docs — Terminology mode (deployment):
  `site/content/en/docs/deployment/terminology-mode.md`
- FHIR R4 terminology service spec: https://hl7.org/fhir/R4/terminology-service.html
