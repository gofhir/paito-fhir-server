# Clinical Reasoning (CQL, Measures, CRMI, CDS Hooks)

**What it is** — Paito ships a native clinical-reasoning stack: a Go CQL (Clinical Quality Language) evaluation engine, quality-measure computation via `$evaluate-measure`, the CRMI (Canonical Resource Management Infrastructure) artifact-lifecycle operations, care-gap and data-requirements analysis, and a CDS Hooks 2.0 decision-support service. Measures and CDS services are driven by CQL `Library` and `PlanDefinition` resources — nothing is hardcoded. The CQL engine reuses the server's storage (for `Retrieve`) and terminology service (for `in ValueSet`) so evaluation runs against your real data.

**When to use it**

- Compute quality measures (proportion, ratio, cohort, continuous-variable) and emit conformant `MeasureReport` resources.
- Identify care gaps across a patient or population (`$care-gaps`).
- Manage the lifecycle of authored artifacts (Library, Measure, PlanDefinition, ValueSet, …) with draft/approve/release/retire and dependency packaging.
- Serve clinical decision support to an EHR at workflow trigger points (patient-view, order-select/sign, encounter-start/discharge) via CDS Hooks 2.0.
- Analyze what data a measure needs before running it (`$data-requirements`).

## Launch

The clinical-reasoning stack is the terminology stack plus the CQL / CDS / CRMI feature flags (see [`docker-compose.terminology.yml`](../docker-compose.terminology.yml) for the base topology it extends):

```bash
docker compose -f docker-compose.clinical-reasoning.yml up -d

# readiness check
curl -s http://localhost:3500/fhir/r4/metadata | head -c 80
```

FHIR REST is under `/fhir/r4` on `:3500`; the Admin API is on `:3501`. CDS Hooks routes are mounted at the **server root** (`/cds-services`), not under the FHIR base path.

> **Note.** CRMI lifecycle operations, `$package` and `$data-requirements` are always available (storage only). `$evaluate-measure`, `$care-gaps`, `$collect-data` and `Library/$evaluate` need `CQL_ENABLED=true`; the `/cds-services` routes need both `CQL_ENABLED=true` and `CDS_HOOKS_ENABLED=true`. The compose above sets all of them.

## Examples

Full runnable script: [`examples/23-clinical-reasoning/run.sh`](../examples/23-clinical-reasoning/run.sh).

**1. Fork an active Library into a draft (CRMI `$draft`)**

```bash
curl -s -X POST http://localhost:3500/fhir/r4/Library/example-cql/\$draft
```

Expected: `201 Created` — a new `Library` with a fresh UUID, `status:"draft"`, version bumped `1.0.0` → `1.0.1`, `approvalDate` cleared.

**2. Approve the draft (CRMI `$approve`)**

```bash
curl -s -X POST http://localhost:3500/fhir/r4/Library/<draft-id>/\$approve \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Parameters","parameter":[
        {"name":"approvalDate","valueDate":"2026-01-15"},
        {"name":"comment","valueString":"Approved by Clinical Quality Committee"}]}'
```

Expected: `200 OK` — the Library with `approvalDate` set and a `cqf-approvalComment` extension.

**3. Release the draft to active (CRMI `$release`)**

```bash
curl -s -X POST http://localhost:3500/fhir/r4/Library/<draft-id>/\$release
```

Expected: `200 OK` — `status:"active"` with `effectivePeriod.start` set to today. Releasing a non-draft returns `422`.

**4. Package a Measure with its dependencies (CRMI `$package`)**

```bash
curl -s "http://localhost:3500/fhir/r4/Measure/example-proportion/\$package"
```

Expected: `200 OK` — a `Bundle` (`type:"collection"`) containing the Measure and every `relatedArtifact` of type `depends-on` / `composed-of` (here, the `example-cql` Library).

**5. Discover the data a Measure needs (`$data-requirements`)**

```bash
curl -s "http://localhost:3500/fhir/r4/Measure/example-proportion/\$data-requirements?periodStart=2026-01-01&periodEnd=2026-12-31"
```

Expected: `200 OK` — a `Library` with `type.coding.code = module-definition` carrying `dataRequirement[]` entries derived by walking the CQL AST.

**6. Evaluate a CQL expression against a subject (`Library/$evaluate`)**

```bash
curl -s -X POST http://localhost:3500/fhir/r4/Library/example-cql/\$evaluate \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Parameters","parameter":[
        {"name":"subject","valueString":"Patient/cql-demo-patient"},
        {"name":"expression","valueString":"InInitialPopulation"}]}'
```

Expected: `200 OK` — a `Parameters` resource, e.g. `{"name":"InInitialPopulation","valueBoolean":true}`.

**7. Compute a MeasureReport (`$evaluate-measure`)**

```bash
curl -s "http://localhost:3500/fhir/r4/Measure/example-proportion/\$evaluate-measure?periodStart=2026-01-01&periodEnd=2026-12-31&reportType=summary"
```

Expected: `200 OK` — a `MeasureReport` with per-population counts for the measurement period. `reportType` may be `individual`, `subject-list`, `summary` (default) or `data-collection`.

**8. CDS Hooks 2.0 discovery (`GET /cds-services`)**

```bash
curl -s http://localhost:3500/cds-services
```

Expected: `200 OK` — `{"services":[...]}`. Services are auto-discovered from `PlanDefinition` resources (those carrying the `cds-hook` extension or an `action.trigger[type=named-event]`), so the list is empty until you install a PlanDefinition. Invoke a service with `POST /cds-services/{id}` and report outcomes with `POST /cds-services/{id}/feedback`.

## Configuration

Environment variables (from `internal/config/config_env.go`):

| Env var | Config key | Default | Description |
|---------|-----------|---------|-------------|
| `CQL_ENABLED` | `cql.enabled` | `false` | Master switch for the CQL engine (`$evaluate-measure`, `Library/$evaluate`, `$care-gaps`, `$collect-data`) |
| `CQL_EVAL_TIMEOUT` | `cql.evalTimeout` | `30s` | Per-expression evaluation timeout |
| `CQL_MAX_EXPRESSION_LENGTH` | `cql.maxExpressionLength` | `102400` | Max CQL source size in bytes (DoS guard) |
| `CQL_MAX_RETRIEVE_SIZE` | `cql.maxRetrieveSize` | `10000` | Max resources returned by a single CQL `Retrieve` |
| `CQL_PUSHDOWN_ENABLED` | `cql.pushdownEnabled` | — | Enable SQL pushdown for CQL `Retrieve` filters |
| `CQL_BATCH_THRESHOLD` | `cql.batchThreshold` | — | Subject count above which pushdown uses batch retrieval |
| `CQL_MEASURE_MAX_SUBJECTS` | `cql.measure.maxSubjectsPerEvaluation` | `10000` | Max subjects per measure evaluation |
| `CQL_MEASURE_PARALLEL_WORKERS` | `cql.measure.parallelWorkers` | `4` | Worker-pool size for population evaluation |
| `CQL_MEASURE_DEFAULT_REPORT_TYPE` | `cql.measure.defaultReportType` | `summary` | Default `reportType` when omitted |
| `CDS_HOOKS_ENABLED` | `cdsHooks.enabled` | `false` | Mount the `/cds-services` routes (requires `CQL_ENABLED`) |
| `CDS_HOOKS_MAX_ACTIONS` | `cdsHooks.maxActionsPerHook` | `50` | Max PlanDefinition actions per hook invocation |
| `CDS_HOOKS_EVAL_TIMEOUT` | `cdsHooks.evalTimeout` | `10s` | Evaluation timeout per hook |
| `CDS_HOOKS_JWT_ENABLED` | `cdsHooks.jwtEnabled` | `false` | Require JWT bearer tokens on hook endpoints |
| `CDS_HOOKS_REFRESH_INTERVAL` | `cdsHooks.refreshInterval` | `5m` | How often the registry re-scans PlanDefinitions |
| `CRMI_ENABLED` | `crmi.enabled` | `false` | Enable CRMI feature declaration |
| `CRMI_ENFORCE_VERSIONING` | `crmi.enforceVersioning` | `false` | Enforce version bumps on artifact changes |
| `CRMI_REQUIRE_APPROVAL` | `crmi.requireApproval` | `false` | Require approval before release |
| `TERMINOLOGY_ENABLED` | `terminology.enabled` | `false` | Wire the ValueSet-membership provider used by CQL `in ValueSet` |

CRMI lifecycle operations apply to the 10 canonical resource types: `Library`, `Measure`, `PlanDefinition`, `ActivityDefinition`, `Questionnaire`, `ValueSet`, `CodeSystem`, `ConceptMap`, `StructureDefinition`, `StructureMap`.

## References

- Clinical Reasoning overview — `site/content/en/docs/clinical-reasoning/_index.md`
- CQL Engine & `Library/$evaluate` — `site/content/en/docs/clinical-reasoning/cql-engine.md`
- Measure Evaluation (`$evaluate-measure`) — `site/content/en/docs/clinical-reasoning/measure-evaluation.md`
- Data Requirements & Care Gaps — `site/content/en/docs/clinical-reasoning/data-requirements.md`
- CRMI Operations reference — `site/content/en/docs/clinical-reasoning/crmi-operations.md`
- CDS Hooks 2.0 — `site/content/en/docs/clinical-reasoning/cds-hooks.md`
- SQL Pushdown — `site/content/en/docs/clinical-reasoning/sql-pushdown.md`
- Module docs — `site/content/en/docs/modules/{measure,crmi,cqlpushdown,cdshooks}/_index.md`
- FHIR R4: [Measure](https://hl7.org/fhir/R4/measure.html) · [CQL](https://cql.hl7.org/) · [CRMI IG](http://hl7.org/fhir/uv/crmi/) · [CDS Hooks 2.0](https://cds-hooks.hl7.org/2.0/)
