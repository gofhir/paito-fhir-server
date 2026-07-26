# CRUD, History & Versioning

**What it is** — The core FHIR RESTful API: create, read, update, and delete
resources at `/fhir/r4/{ResourceType}`, with full version tracking. Every write
bumps a `versionId`, is stamped with a weak `ETag`, and is retained in an
append-only history so you can list versions (`_history`), read a specific past
version (`vread`), and recover deletes. Deletes are soft (tombstones): a deleted
resource returns `410 Gone` but its history survives. Referential integrity is
enforced by default, so deleting a resource that is still referenced is blocked.

**When to use it**

- Standard record management: register a patient, record an observation, amend a record.
- Optimistic concurrency control with `If-Match` to prevent lost updates.
- Auditing and point-in-time reads via `_history` and `vread`.
- Linking resources with references and pulling them together via `_revinclude`.
- Safe deletion where dangling references must be prevented.

## Launch

Reuse the base compose (paito + PostgreSQL). No feature flags needed — CRUD,
history, and referential integrity are on by default.

```bash
docker compose -f docker-compose.yml up -d

# readiness check
curl -fsS http://localhost:3500/fhir/r4/metadata | grep -o '"resourceType":"CapabilityStatement"'
```

FHIR API: `http://localhost:3500/fhir/r4` · Admin API: `http://localhost:3501`

## Examples

All examples assume `BASE=http://localhost:3500/fhir/r4`.

**Create** — returns `201 Created`, `Location`, `ETag: W/"1"`, and the stored body with `versionId: "1"`.

```bash
curl -i -X POST "$BASE/Patient" \
  -H 'Content-Type: application/fhir+json' \
  -d '{"resourceType":"Patient","name":[{"family":"Quintana","given":["María"]}],"gender":"female","birthDate":"1985-03-15"}'
```

**Read** — `200 OK`; the response carries the weak `ETag` you use for `If-Match`/`If-None-Match`.

```bash
curl -i "$BASE/Patient/{id}"
```

**Update** — `PUT` the full resource; `200 OK` with `versionId: "2"` and `ETag: W/"2"`.

```bash
curl -i -X PUT "$BASE/Patient/{id}" \
  -H 'Content-Type: application/fhir+json' \
  -d '{"resourceType":"Patient","id":"{id}","name":[{"family":"Quintana-Soto","given":["María"]}],"gender":"female","birthDate":"1985-03-15"}'
```

**Optimistic locking** — a stale `If-Match` is rejected with `409 Conflict` (version mismatch).

```bash
curl -i -X PUT "$BASE/Patient/{id}" -H 'If-Match: W/"1"' \
  -H 'Content-Type: application/fhir+json' -d '{...}'
```

**Instance history** — `200 OK`, a `Bundle` of type `history` (`total: 2` after one update).

```bash
curl "$BASE/Patient/{id}/_history"
```

**Vread (past version)** — `200 OK` returns the resource exactly as it was at version 1.

```bash
curl "$BASE/Patient/{id}/_history/1"
```

**Referential integrity delete guard** — with a referencing `Observation` present, `DELETE` the Patient returns `409 Conflict` and an `OperationOutcome` citing `REFERENCE_STILL_REFERENCED`. Delete the `Observation` first (`204`), then the Patient (`204`).

```bash
curl -i -X DELETE "$BASE/Patient/{id}"        # 409 while referenced
curl -i -X DELETE "$BASE/Observation/{obsId}" # 204
curl -i -X DELETE "$BASE/Patient/{id}"         # 204
```

**Tombstone + surviving history** — a deleted resource reads as `410 Gone`, but its `_history` still lists the `POST`, `PUT`, and `DELETE` entries (`total: 3`).

```bash
curl -i "$BASE/Patient/{id}"            # 410 Gone
curl "$BASE/Patient/{id}/_history"      # 200, total: 3, includes "method":"DELETE"
```

For an end-to-end runnable version of all of the above, see
[`examples/01-crud/run.sh`](../examples/01-crud/run.sh).

## Configuration

CRUD and history need no configuration. The knobs below (all optional) tune
referential integrity, conditional operations, and history retention. Env-var
names come from `internal/config/config_env.go`.

| Env var | Default | Purpose |
| --- | --- | --- |
| `FHIR_VERSION` | `R4` | FHIR release served under `/fhir/r4`. |
| `REFERENTIAL_INTEGRITY_ENFORCE_ON_WRITE` | `true` | Reject writes whose references target missing resources. |
| `REFERENTIAL_INTEGRITY_ENFORCE_ON_DELETE` | `true` | Block deleting a resource that is still referenced (`409`). |
| `REFERENTIAL_INTEGRITY_ALLOW_EXTERNAL` | `false` | Permit absolute/external references without local resolution. |
| `CONDITIONAL_UPDATE_AS_CREATE` | `false` | Let a conditional `PUT` that matches nothing create the resource. |
| `CONDITIONAL_ALLOW_MULTIPLE_DELETE` | `false` | Allow a single conditional `DELETE` to remove multiple matches. |
| `HISTORY_RETENTION_DAYS` | unset (keep all) | Days to retain history versions before cleanup. |
| `HISTORY_CLEANUP_INTERVAL` | unset | Interval for the background history-cleanup job. |

## References

- CRUD: `go-fhir-server/site/content/en/docs/fhir-api/crud.md`
- History & versioning: `go-fhir-server/site/content/en/docs/fhir-api/history.md`, `.../history-versioning.md`
- Conditional operations: `go-fhir-server/site/content/en/docs/fhir-api/conditional.md`
- CapabilityStatement: `go-fhir-server/site/content/en/docs/fhir-api/capability-statement.md`
- Proven E2E test: `go-fhir-server/scripts/e2e-smoke.sh`
- FHIR R4 RESTful API: https://hl7.org/fhir/R4/http.html
