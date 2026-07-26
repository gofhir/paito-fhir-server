# Master Data Management (MDM)

**What it is** — MDM (Master Data Management) links duplicate source records to a
single **golden record** per real-world entity, following the HAPI FHIR / Smile CDR
MDM convention. paito FHIR Server ships a probabilistic + deterministic matching
engine (Enterprise Identifier matching, weighted-average scoring, and an optional
Fellegi-Sunter aggregator with LSH blocking and EM calibration), a full set of
`$mdm-*` FHIR operations for stewardship, and — uniquely among open-source FHIR
servers — synchronization of MDM links into `Patient.link[]`. Supported resource
types: **Patient, Practitioner, Organization, Person**. MDM is only registered on
the **PostgreSQL** backend.

**When to use it**

- Deduplicating patients/practitioners across feeds that lack a shared identifier.
- Building golden records with survivorship (most-recent or manual).
- Human-in-the-loop stewardship: review `POSSIBLE_MATCH` queues, confirm/deny links.
- Merging two golden records that turned out to be the same person.
- Tuning the matcher against steward labels via `$mdm-calibrate` (Fellegi-Sunter).

## Launch

```bash
docker compose -f docker-compose.mdm.yml up -d

# Readiness
curl -sf http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
# Confirm MDM is wired (200 = enabled)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3500/fhir/r4/\$mdm-query-links
```

The compose file (`docker-compose.mdm.yml`) starts `paito` + `postgres` with
`MDM_ENABLED=true`, managed types `Patient,Practitioner,Organization`, the
`mostRecent` survivorship strategy, auto-linking on, and `Patient.link[]` sync on.

Run the full worked example: `cd examples/19-mdm && bash run.sh`.

## Examples

All calls use the FHIR R4 base `http://localhost:3500/fhir/r4`. A tenant header
(`X-Tenant-ID`) is optional; it isolates links per tenant.

**1. Auto-match — POST two identical Patients; the second links to the first's golden**

```bash
curl -X POST http://localhost:3500/fhir/r4/Patient \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Patient","name":[{"family":"García","given":["María"]}],"gender":"female","birthDate":"1985-04-12"}'
# POST the same body again, then query the second patient's links:
curl "http://localhost:3500/fhir/r4/\$mdm-query-links?resourceId=<id-2>"
```

Expected: a `link` parameter with `matchResult = MATCH` and `linkSource = AUTO`.

**2. Query links with filters + pagination**

```bash
curl "http://localhost:3500/fhir/r4/\$mdm-query-links?matchResult=POSSIBLE_MATCH&_count=10"
```

Expected: `Parameters` with `totalCount`/`offset`/`count` and matching `link` entries.

**3. Bulk-import a Bundle through the MDM engine (async)**

```bash
curl -i -X POST http://localhost:3500/fhir/r4/\$mdm-bulk-import \
  -H "Content-Type: application/fhir+json" \
  --data-binary @examples/19-mdm/bundle-bulk-import.json
```

Expected: `HTTP/1.1 202 Accepted` with a `Content-Location` header pointing at the job.

**4. Manually create a link (steward override)**

```bash
curl -X POST http://localhost:3500/fhir/r4/\$mdm-create-link \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Parameters","parameter":[
        {"name":"goldenResourceId","valueId":"Patient/golden-1"},
        {"name":"resourceId","valueId":"Patient/source-1"},
        {"name":"matchResult","valueCode":"MATCH"}]}'
```

Expected: `Parameters` echoing `linkId`, `matchResult=MATCH`, `linkSource=MANUAL`.

**5. Update a link + read its audit trail**

```bash
curl -X POST http://localhost:3500/fhir/r4/\$mdm-update-link \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Parameters","parameter":[
        {"name":"goldenResourceId","valueId":"golden-1"},
        {"name":"resourceId","valueId":"source-1"},
        {"name":"matchResult","valueCode":"NO_MATCH"}]}'

curl -X POST http://localhost:3500/fhir/r4/Patient/<id>/\$mdm-link-history
```

Expected: the update returns the rewritten link; the history returns entries for
both the AUTO decision and the MANUAL verdict with `changedBy`/`changedAt`.

**6. Calibrate the matcher (Fellegi-Sunter proposal — proposes, never applies)**

```bash
curl -X POST http://localhost:3500/fhir/r4/\$mdm-calibrate \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Parameters","parameter":[
        {"name":"resourceType","valueCode":"Patient"},
        {"name":"minLabels","valueInteger":5}]}'
```

Expected (with enough steward labels): `Parameters` carrying a `candidate`
(FellegiSunterConfig JSON) and a `recommendation` code in `{install, review, reject}`.
With too few labels it returns `422 Unprocessable Entity` — seed more verdicts first.

**7. Merge two golden records**

```bash
curl -X POST http://localhost:3500/fhir/r4/\$mdm-merge-golden-resources \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Parameters","parameter":[
        {"name":"fromGoldenResourceId","valueId":"golden-old"},
        {"name":"toGoldenResourceId","valueId":"golden-new"}]}'
```

Expected: `Parameters` with `status=completed`, `movedLinks`, `referencesUpdated`.
The `from` golden is deactivated with a `REDIRECT` link to the survivor.

**8. Clear AUTO links (MANUAL links are preserved)**

```bash
curl -X POST http://localhost:3500/fhir/r4/Patient/<id>/\$mdm-clear
```

Expected: `Parameters` with `status=success` and `deletedCount`.

> **Note on scoring presets.** By default the engine uses the `weighted-average`
> aggregator. Set `MDM_PRESET=phase-2-full` to switch to the **Fellegi-Sunter**
> aggregator with **LSH blocking** and optimal array assignment — the pipeline
> `$mdm-calibrate` proposes configs for. `$mdm-submit` (type-level batch) and the
> async broker path require `MDM_BROKER_ENABLED=true`.

## Configuration

Environment variables (authoritative names from `internal/config/config_env.go`):

| Env var | Config key | Default | Description |
|---------|-----------|---------|-------------|
| `MDM_ENABLED` | `mdm.enabled` | `false` | Master switch; registers the `$mdm-*` operations (PostgreSQL only). |
| `MDM_MANAGED_TYPES` | `mdm.managedResourceTypes` | `Patient` | Comma-separated resource types the engine manages. |
| `MDM_SURVIVORSHIP_STRATEGY` | `mdm.survivorshipStrategy` | `mostRecent` | Golden-record field survivorship: `mostRecent` or `manual`. |
| `MDM_AUTO_LINK` | `mdm.autoLink` | `true` | Auto-create links on resource create/update. |
| `MDM_SYNC_PATIENT_LINKS` | `mdm.syncPatientLinks` | `true` | Mirror MDM links into `Patient.link[]` (`refer` / `replaced-by`). |
| `MDM_AGGREGATOR` | `mdm.aggregator` | `weighted-average` | Score aggregator: `weighted-average` or `fellegi-sunter`. |
| `MDM_PRESET` | `mdm.preset` | _(none)_ | `phase-2-full` enables Fellegi-Sunter + LSH blocking + optimal array matching. |
| `MDM_RULES_PATH` | `mdm.matchingRulesPath` | _(built-in)_ | Path to a custom matching-rules JSON. |
| `MDM_EID_CERTAIN_THRESHOLD` | `mdm.eidCertainThreshold` | — | EID score threshold for a certain (MATCH) link. |
| `MDM_EID_PROBABLE_THRESHOLD` | `mdm.eidProbableThreshold` | — | EID score threshold for a probable (POSSIBLE_MATCH) link. |
| `MDM_BROKER_ENABLED` | `mdm.broker.enabled` | `false` | Async broker-driven MDM (enables type-level `$mdm-submit`). |
| `MDM_BLOCKING_LSH_ENABLED` | `mdm.blocking.lsh.enabled` | `false` | LSH candidate blocking (also on via `phase-2-full`). |
| `MDM_TFREFRESH_ENABLED` | `mdm.tfRefresh.enabled` | `false` | Background term-frequency table refresh job. |
| `MDM_ASYNC_TIMEOUT` | `mdm.asyncTimeout` | — | Timeout for synchronous MDM processing on write. |

## References

- go-fhir-server docs — MDM Operations: `site/content/en/docs/fhir-api/mdm-operations.md`
- go-fhir-server docs — MDM module overview: `site/content/en/docs/modules/mdm/_index.md`
- go-fhir-server docs — Fellegi-Sunter aggregator: `site/content/en/docs/modules/mdm/fellegi-sunter.md`
- go-fhir-server docs — `$mdm-calibrate`: `site/content/en/docs/modules/mdm/mdm-calibrate.md`
- go-fhir-server docs — LSH blocking: `site/content/en/docs/modules/mdm/lsh-blocking.md`
- Proven e2e suite this example derives from: `test/e2e/mdm_phase2_localhost_test.go`
- [HAPI FHIR MDM Operations](https://hapifhir.io/hapi-fhir/docs/server_jpa_mdm/mdm_operations.html)
