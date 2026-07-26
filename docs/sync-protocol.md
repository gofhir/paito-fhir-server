# Sync Protocol (Edge ↔ Cloud replication)

**What it is** — A state-based, offline-first replication protocol that keeps an
[edge node](https://gofhir.io/docs/deployment/edge-mode/) and an upstream server
in agreement even when either is modified independently (including while the edge
is offline). Peers exchange the *latest* version of each resource — not full
history — via a resumable **change feed** (`GET /_changes`), apply changes
idempotently with **PUT-by-id** (so ids and references stay valid across the
wire), resolve conflicts by a configurable strategy, and resume from a durable
per-peer cursor. A single orchestrated cycle is exposed as `POST /$sync`.

**When to use it**

- Offline-first / intermittently-connected deployments (clinics, ships, field
  sites) that must reconcile with a cloud server when connectivity returns.
- Pull replication: mirror a cloud server's changes down to a local edge node.
- Push replication: forward locally-captured changes up to a cloud server.
- Bidirectional sync with automatic conflict resolution between two peers.
- Building a custom periodic/background replicator on top of the change feed.

## Launch

Both peers run in `edge` mode (embedded SQLite, no external database). `edge`
mode automatically enables the sync operation and PUT-by-id update-as-create.

```bash
docker compose -f docker-compose.sync.yml up -d

# Readiness — both peers should return 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3500/fhir/r4/metadata   # CLOUD
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3510/fhir/r4/metadata   # EDGE
```

`docker-compose.sync.yml` starts two services: **cloud** (host `:3500`) and
**edge** (host `:3510`), on a shared bridge network so the edge can reach the
cloud by the DNS name `cloud`.

## Examples

Base URLs used below: `CLOUD=http://localhost:3500/fhir/r4`,
`EDGE=http://localhost:3510/fhir/r4`.

**1. Create a resource on CLOUD (PUT-by-id)**

```bash
curl -X PUT "$CLOUD/Patient/pat-1" \
  -H 'Content-Type: application/fhir+json' \
  -d '{"resourceType":"Patient","id":"pat-1","name":[{"family":"Cloud"}]}'
```
Expected: `201 Created` (or `200` on a subsequent update).

**2. Pull the change feed (first page)**

```bash
curl "$CLOUD/_changes?_count=100"
```
Expected: a `Bundle` (`type: history`) with the current state of every changed
resource, oldest-first, plus a `link` whose relation is
`http://gofhir.io/fhir/sync/cursor` carrying the resume cursor (and a `next`
link when more pages remain).

**3. Resume from a cursor (incremental pull)**

```bash
curl "$CLOUD/_changes?since=<cursor>&_count=100"
```
Expected: only changes newer than `<cursor>`. Delivery is at-least-once — apply
idempotently and dedupe by `resourceType/id/versionId`.

**4. Replay a change into EDGE (the push wire format)**

```bash
curl -X PUT "$EDGE/Patient/pat-1" \
  -H 'Content-Type: application/fhir+json' \
  -d '{"resourceType":"Patient","id":"pat-1","name":[{"family":"Cloud"}]}'
```
Expected: `201`/`200`; EDGE now holds `Patient/pat-1` with the same id, so
references such as `Observation.subject → Patient/pat-1` remain valid.

**5. Replicate a delete (tombstone)**

```bash
curl -X DELETE "$CLOUD/Observation/obs-1"     # on CLOUD
curl -X DELETE "$EDGE/Observation/obs-1"      # replay the tombstone on EDGE
curl -s -o /dev/null -w '%{http_code}\n' "$EDGE/Observation/obs-1"
```
Expected: final GET returns `410 Gone` on EDGE.

**6. Run the orchestrated `POST /$sync` cycle (server-driven)**

```bash
# Run from a context that can resolve the peer DNS name (e.g. the compose network).
curl -X POST "$EDGE/\$sync?peer=http://cloud:3500/fhir/r4&direction=pull&strategy=cloud-wins"
```
Expected: `200` with a `Parameters` report — `pulledApplied`, `pulledDeleted`,
`pushed`, `deleted`, `conflicts`, `deferred`, `pullCursor`, `pushCursor`. The
peer URL is SSRF-guarded: **loopback/link-local/cloud-metadata peers are always
blocked**, so address the peer by a routable (non-`localhost`) name.

Conflict strategies (`strategy` query param): `last-write-wins` (default —
newer `lastUpdated` wins, ties converge to remote), `cloud-wins` (keep remote),
`edge-wins` (keep local), `manual` (leave both for out-of-band resolution).
Direction (`direction`): `both` (default), `pull`, or `push`.

## Configuration

`edge` mode (set via `SERVER_MODE=edge`) reshapes the config for a
zero-dependency deployment and turns the sync operation on automatically; the
individual keys below are what it toggles.

| Env var | Config key | Purpose | Default |
| --- | --- | --- | --- |
| `SERVER_MODE` | `server.mode` | `edge` forces embedded SQLite and enables `/_changes`, `POST /$sync`, and PUT-by-id upsert | `full` |
| `SQLITE_PATH` | `storage.sqlite.path` | On-disk SQLite database for the edge peer | `gofhir-edge.db` |
| `SERVER_PORT` | `server.port` | HTTP port the peer listens on | `3500` |
| `SYNC_ENABLED` | `sync.enabled` | Exposes `POST /$sync` (auto-enabled by edge mode) | `false` (→ `true` in edge) |
| `AUTH_ENABLED` | `auth.enabled` | Auth on the FHIR API (cross-peer traffic is a good fit for SMART Backend Services) | `false` |
| — | `egress.blockPrivateIPs` | Additionally block private/RFC1918 sync peers (loopback/link-local/metadata are *always* blocked) | `false` |

Notes:

- Edge mode also forces `packages.offline=true`, `conditional.updateAsCreate=true`,
  and disables PostgreSQL-only subsystems (terminology, MDM, admin API,
  SQL-on-FHIR) — so terminology binding checks degrade to "not enforced".
- The `internal/sync` engine is embeddable for custom drivers (e.g. a periodic
  background sync loop).

## References

- go-fhir-server docs — [Sync Protocol (Edge ↔ Cloud)](https://gofhir.io/docs/deployment/sync-protocol/)
- go-fhir-server docs — [Edge mode](https://gofhir.io/docs/deployment/edge-mode/)
- Proven end-to-end test: `scripts/e2e-sync-smoke.sh` in the go-fhir-server repo.
