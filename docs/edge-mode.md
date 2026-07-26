# Edge Mode

**What it is** — Edge mode runs the **full FHIR API** — CRUD, search, `$validate`,
history, and transaction Bundles — as a single self-contained process backed by
embedded SQLite. There is no database server, no message broker, and no network
access required at boot. It is a *footprint* profile, not a reduced API: the FHIR
surface is identical to full mode, only PostgreSQL-only and operationally heavy
subsystems are turned off. Setting `SERVER_MODE=edge` reshapes the rest of the
configuration automatically at load time.

**When to use it**

- On-device, point-of-care, or field deployments with no infrastructure.
- Offline / air-gapped environments (FHIR definitions are embedded, no downloads at boot).
- Lightweight demos, CI fixtures, or a "runs anywhere" single-binary FHIR server.
- Edge nodes that replicate to/from an upstream "cloud" via the experimental sync protocol.

**Launch**

```bash
docker compose -f docker-compose.edge.yml up -d

# Readiness check (expect HTTP 200 + a CapabilityStatement):
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3500/fhir/r4/metadata
```

The SQLite database persists on the `paito_edge_data` volume. Only the FHIR API
port (3500) is exposed — edge disables the admin API by design.

**Examples**

```bash
# 1. Capability statement (full FHIR surface is served on edge)
curl http://localhost:3500/fhir/r4/metadata
# → 200, a CapabilityStatement resource

# 2. Create a Patient (persisted to embedded SQLite)
curl -X POST http://localhost:3500/fhir/r4/Patient \
  -H 'Content-Type: application/fhir+json' \
  -d '{"resourceType":"Patient","name":[{"family":"Edge","given":["Ana"]}],"gender":"female","birthDate":"1990-01-01"}'
# → 201 Created, Location: .../Patient/<id>/_history/1

# 3. Read it back
curl http://localhost:3500/fhir/r4/Patient/<id>
# → 200, the Patient resource

# 4. Update it
curl -X PUT http://localhost:3500/fhir/r4/Patient/<id> \
  -H 'Content-Type: application/fhir+json' \
  -d '{"resourceType":"Patient","id":"<id>","name":[{"family":"Edge","given":["Ana","Maria"]}],"gender":"female","birthDate":"1990-01-01"}'
# → 200, versionId bumps to 2

# 5. Search
curl 'http://localhost:3500/fhir/r4/Patient?family=Edge'
# → 200, a searchset Bundle with total = 1

# 6. Validate a resource (structural validation runs on edge)
curl -X POST 'http://localhost:3500/fhir/r4/Patient/$validate' \
  -H 'Content-Type: application/fhir+json' \
  -d '{"resourceType":"Patient","name":[{"family":"V"}],"gender":"male"}'
# → 200, an OperationOutcome
```

> **Limitations (auto-disabled on edge).** Terminology (`$expand` /
> `$validate-code` / `$lookup` / `$subsumes`), MDM, SQL-on-FHIR
> (`$viewdefinition-run`), the admin API, Bulk Data `$export`, `:above`/`:below`
> reference hierarchy search, and CDC-based system history all require PostgreSQL
> and are turned off. Profile bindings still validate structurally, but
> **terminology binding checks are not enforced**. Run full mode against
> PostgreSQL if you need any of these.
>
> **Sync is experimental.** Edge mode also enables the upstream sync endpoints
> (`POST /$sync`, `/_changes`) so an edge node can replicate to/from a "cloud"
> peer. That workflow is experimental — see `docker-compose.sync.yml` and
> `examples/21-sync-protocol`.

**Configuration**

`SERVER_MODE=edge` is the only required setting; the rest is forced by the edge
profile at load time and shown here for clarity.

| Env var | Config key | Value / meaning |
| --- | --- | --- |
| `SERVER_MODE` | `server.mode` | `edge` — activates the profile (required) |
| `SERVER_PORT` | `server.port` | HTTP listen port (compose maps host `3500`) |
| `SERVER_BASE_PATH` | `server.basePath` | FHIR base path, default `/fhir/r4` |
| `SQLITE_PATH` | `storage.sqlite.path` | embedded SQLite database file |
| `STORAGE_DRIVER` | `storage.driver` | forced to `sqlite` by edge (no need to set) |
| `FHIR_VERSION` | `fhir.version` | `R4` \| `R4B` \| `R5` (only the active one is loaded) |
| `AUTH_ENABLED` | `auth.enabled` | `false` by default; set `true` (with `AUTH_MODE=smart`) if exposed beyond a trusted perimeter |
| `GOMEMLIMIT` | (runtime) | optional soft memory limit, e.g. `192MiB`, to trade CPU for lower RSS |

Edge forces `packages.offline=true`, `packages.resolveDependencies=false`, and
disables `terminology`, `mdm`, `admin`, and `sqlOnFhir` — no env vars needed.

**References**

- Edge Mode (go-fhir-server site docs): `site/content/en/docs/deployment/edge-mode.md`
- Sample edge config: `configs/config.edge.yaml`
- Edge container image: `deployments/docker/Dockerfile.edge`
- Proven e2e test: `scripts/e2e-edge-smoke.sh`
