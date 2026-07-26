# Admin API & Web Dashboard

**What it is** — Paito ships a management plane that runs on a **separate port**
(default `3501`) from the FHIR API (`3500`). It exposes a REST **Admin API**
under `/api/*` and a server-rendered **Web Dashboard** under `/ui/` for OAuth
client CRUD, FHIR Implementation Guide (IG) package management, audit-log query
and export, configuration inspection, and PostgreSQL storage operations. Every
endpoint except `/health` and `/metrics` requires an **API key** and is
authorized by **RBAC** (`resource:action` permissions).

**When to use it**

- Register, update, and revoke SMART/OAuth clients without editing files or restarting.
- Install/uninstall FHIR IG packages (e.g. US Core) from `packages.fhir.org`.
- Query, filter, and export the audit trail (JSON / NDJSON / CSV) for security review.
- Read the live server configuration (secrets redacted) and validate changes.
- Inspect database size/row counts and run `VACUUM ANALYZE` on PostgreSQL.
- Give operators a point-and-click dashboard (htmx, no JS build) at `/ui/`.

## Launch

```bash
docker compose -f docker-compose.admin.yml up -d

# readiness — FHIR metadata and an authenticated admin call
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo "fhir ready"
curl -fsS -H "Authorization: Bearer paito-admin-key-change-me" \
  http://localhost:3501/api/clients >/dev/null && echo "admin ready"
```

Then run `bash examples/26-admin-api/run.sh`, or open the dashboard at
<http://localhost:3501/ui/>. The compose sets the admin key via `ADMIN_API_KEY`
(default `paito-admin-key-change-me`) and seeds one demo OAuth client through
GitOps. Tear down with `docker compose -f docker-compose.admin.yml down -v`.

## Examples

All admin calls send the key as either `X-Admin-API-Key: <key>` or
`Authorization: Bearer <key>`. Below, `KEY=paito-admin-key-change-me`.

**1. Auth is enforced** — a request with no key is rejected:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3501/api/clients
# -> 401
```

**2. List OAuth clients** (the seeded `patient-portal` appears; secrets are never returned):

```bash
curl -s -H "Authorization: Bearer $KEY" http://localhost:3501/api/clients
# -> {"clients":[{"id":"patient-portal", ...}],"total":1}
```

**3. Register a new client**:

```bash
curl -s -X POST http://localhost:3501/api/clients \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"name":"backend-service","secret":"backend-secret","grantTypes":["client_credentials"],"scopes":["system/Patient.rs"],"confidential":true,"active":true}'
# -> 201 Created  {"client":{"id":"backend-service", ...},"message":"Client created successfully"}
```

**4. List installed IG packages**:

```bash
curl -s -H "Authorization: Bearer $KEY" http://localhost:3501/api/packages
# -> {"packages":[ ... ],"total":N}
```

**5. Query the audit trail** (filter by type/outcome/client, paginate):

```bash
curl -s -H "Authorization: Bearer $KEY" \
  "http://localhost:3501/api/audit/events?type=create&limit=20"
# -> {"events":[{"type":"create","outcome":"success","resourceType":"Patient", ...}],"total":N}
```

**6. Audit aggregate stats**:

```bash
curl -s -H "Authorization: Bearer $KEY" http://localhost:3501/api/audit/stats
# -> {"totalEvents":N,"eventsByType":{...},"eventsByOutcome":{...},"topClients":[...]}
```

**7. Export audit events as CSV**:

```bash
curl -s -H "Authorization: Bearer $KEY" \
  "http://localhost:3501/api/audit/export?outcome=denied&format=csv" -o denied.csv
# formats: json | ndjson (default) | csv
```

**8. Storage stats + VACUUM** (PostgreSQL):

```bash
curl -s -H "Authorization: Bearer $KEY" http://localhost:3501/api/storage/stats
curl -s -X POST -H "Authorization: Bearer $KEY" http://localhost:3501/api/storage/vacuum
# -> {"message":"VACUUM ANALYZE completed successfully"}
```

Notes: installing a package (`POST /api/packages/install`) pulls from
`packages.fhir.org`, so it needs outbound network and can take time. Database
backup/restore via the API are **not implemented** (they return `501`); use
`pg_dump` / `pg_restore` directly.

## Configuration

The admin server is enabled and port-selected by env vars; the API key, RBAC
roles, and GitOps seeding live in the mounted `config/admin.yaml` (the image
reads it via `CONFIG_PATH`). Authoritative env names are in
`internal/config/config_env.go`.

| Env var | Config key | Purpose |
|---------|-----------|---------|
| `ADMIN_ENABLED` | `admin.enabled` | Turn the admin server on/off |
| `ADMIN_PORT` | `admin.port` | Admin API + Web UI port (default `3501`) |
| `ADMIN_API_KEY` | `admin.auth.apiKeys[]` | API key placeholder resolved at load time |
| `ADMIN_TLS_ENABLED` | `admin.tls.enabled` | Serve the admin port over TLS |
| `ADMIN_TLS_CERT_FILE` | `admin.tls.certFile` | TLS certificate path |
| `ADMIN_TLS_KEY_FILE` | `admin.tls.keyFile` | TLS private-key path |
| `ADMIN_TLS_MIN_VERSION` | `admin.tls.minVersion` | Minimum TLS version |

Config-file keys (in `config/admin.yaml`) not exposed as env vars:

| Config key | Purpose |
|-----------|---------|
| `admin.auth.strategy` | `apikey` (REST) or `smart`/`hybrid` (adds Web-UI session login) |
| `admin.rbac.enabled` | Enforce `resource:action` permissions per endpoint |
| `admin.rbac.roles` | Built-in roles: `super`, `security`, `devops`, `readonly` |
| `admin.gitops.clientsPath` | YAML of OAuth clients reconciled at boot |
| `admin.gitops.reconcileOnStart` | Seed/converge clients on startup |
| `audit.enabled` | Record AuditEvents so `/api/audit/*` has data |

An API key with no explicit role mapping defaults to the **`super`** role (full
access). The four built-in roles: `super` (everything), `security`
(`clients:*`, `audit:*`), `devops` (`igs:*`, `config:*`, `storage:*`),
`readonly` (`*:read`).

## References

- Admin system overview — `site/content/en/docs/admin-system/_index.md`
- API reference (all endpoints) — `site/content/en/docs/admin-system/api-reference.md`
- OAuth client management — `site/content/en/docs/admin-system/client-management.md`
- IG package management — `site/content/en/docs/admin-system/package-management.md`
- Audit query & export — `site/content/en/docs/admin-system/audit-query.md`
- RBAC & authentication — `site/content/en/docs/admin-system/rbac.md`
- Storage management — `site/content/en/docs/admin-system/storage-management.md`
- Web Dashboard — `site/content/en/docs/admin-system/web-ui.md`
- Configuration management — `site/content/en/docs/admin-system/config-management.md`
