# Multi-Tenancy (header & JWT isolation)

**What it is** — paito can serve many isolated tenants from a single deployment.
Each request carries a tenant identity — extracted from an `X-Tenant-ID` HTTP
header and/or a JWT claim — and the storage layer scopes every read, write,
search, and history operation to that tenant. On PostgreSQL, isolation is
defense-in-depth: the SQL adapter adds `WHERE tenant_id = $` to every statement
**and** PostgreSQL Row-Level Security (RLS) policies enforce it at the database
layer via `SET LOCAL app.current_tenant`. Public discovery endpoints
(`/fhir/r4/metadata`, `/health`) remain reachable without a tenant.

**When to use it**

- Host multiple organizations, hospitals, or environments on one server with
  guaranteed data separation.
- Front the server with an API gateway that authenticates the caller and stamps
  a trusted `X-Tenant-ID` header (service-to-service, internal routing).
- Derive the tenant from a signed SMART on FHIR / OIDC JWT claim so end users
  cannot spoof another tenant (set a JWT secret + claim name).
- Let the same logical resource id exist independently per tenant.

**Launch**

```bash
docker compose -f docker-compose.multitenancy.yml up -d

# metadata is public — no tenant header required
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
```

Then drive the isolation demo:

```bash
bash examples/11-multi-tenancy/run.sh
```

Tear down with `docker compose -f docker-compose.multitenancy.yml down -v`.

> The bundled stack runs in **strict header mode** (`ALLOW_ANONYMOUS_TENANT=false`),
> so every data request must present `X-Tenant-ID`. Header-only tenant trust is
> only safe behind a gateway that authenticates the caller — for production with
> end users, extract the tenant from a JWT claim instead (see Configuration).

**Examples**

Public endpoint — no tenant needed:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3500/fhir/r4/metadata
# → 200
```

Data request with no tenant is rejected:

```bash
curl -s -w '\n%{http_code}\n' http://localhost:3500/fhir/r4/Patient
# → OperationOutcome with issue.code=security, HTTP 401
```

Create a Patient in `tenant-a`:

```bash
curl -s -w '\n%{http_code}\n' \
  -H 'X-Tenant-ID: tenant-a' \
  -H 'Content-Type: application/fhir+json' \
  -X POST http://localhost:3500/fhir/r4/Patient \
  -d '{"resourceType":"Patient","name":[{"family":"IsoA"}]}'
# → 201 Created (note the returned id)
```

Read isolation — `tenant-b` cannot see `tenant-a`'s resource:

```bash
# using the id returned above, e.g. <PID>
curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Tenant-ID: tenant-a' http://localhost:3500/fhir/r4/Patient/<PID>
# → 200
curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Tenant-ID: tenant-b' http://localhost:3500/fhir/r4/Patient/<PID>
# → 404 (isolated)
```

Search isolation — searchset is scoped to the requesting tenant:

```bash
curl -s -H 'X-Tenant-ID: tenant-a' 'http://localhost:3500/fhir/r4/Patient?name=IsoA' | grep -o '"total":[0-9]*'
# → "total":1
curl -s -H 'X-Tenant-ID: tenant-b' 'http://localhost:3500/fhir/r4/Patient?name=IsoA' | grep -o '"total":[0-9]*'
# → "total":0
```

Same-id coexistence — the same logical id lives independently per tenant:

```bash
curl -s -H 'X-Tenant-ID: tenant-a' -H 'Content-Type: application/fhir+json' \
  -X PUT http://localhost:3500/fhir/r4/Patient/shared-1 \
  -d '{"resourceType":"Patient","id":"shared-1","name":[{"family":"OwnerA"}]}' >/dev/null
curl -s -H 'X-Tenant-ID: tenant-b' -H 'Content-Type: application/fhir+json' \
  -X PUT http://localhost:3500/fhir/r4/Patient/shared-1 \
  -d '{"resourceType":"Patient","id":"shared-1","name":[{"family":"OwnerB"}]}' >/dev/null
curl -s -H 'X-Tenant-ID: tenant-a' http://localhost:3500/fhir/r4/Patient/shared-1 | grep -o '"family":"[^"]*"'  # → OwnerA
curl -s -H 'X-Tenant-ID: tenant-b' http://localhost:3500/fhir/r4/Patient/shared-1 | grep -o '"family":"[^"]*"'  # → OwnerB
```

**Configuration**

The image is configured via environment variables (authoritative names from
`internal/config/config_env.go`):

| Env var | Config key | Default | Description |
|---------|-----------|---------|-------------|
| `MULTI_TENANCY_ENABLED` | `multiTenancy.enabled` | `false` | Turn on tenant isolation (WHERE-filter + PostgreSQL RLS). |
| `TENANT_HEADER_NAME` | `multiTenancy.headerName` | `X-Tenant-ID` | HTTP header the tenant id is read from. |
| `ALLOW_ANONYMOUS_TENANT` | `multiTenancy.allowAnonymous` | `false` | If `true`, data requests without a tenant fall back to `DEFAULT_TENANT`; if `false`, they get `401`. |
| `DEFAULT_TENANT` | `multiTenancy.defaultTenant` | — | Tenant used when anonymous access is allowed. |
| `JWT_SECRET` | `multiTenancy.jwt.secret` | — | Setting this enables JWT tenant extraction; the tenant is read from a signed token claim. |
| `JWT_CLAIM_NAME` | `multiTenancy.jwt.claimName` | — | Name of the JWT claim that holds the tenant id. |

When both a JWT claim and the header are present, they are cross-validated and
must match to prevent spoofing. Multi-tenant isolation with RLS requires the
PostgreSQL storage driver (`STORAGE_DRIVER=postgres`); MongoDB uses app-level
filtering.

**References**

- Multi-tenancy overview — `site/content/en/docs/multi-tenancy/_index.md`
- Configuration — `site/content/en/docs/multi-tenancy/configuration.md`
- Isolation model — `site/content/en/docs/multi-tenancy/isolation.md`
- JWT integration — `site/content/en/docs/multi-tenancy/jwt-integration.md`
- ADR-006 Multi-Tenancy — `site/content/en/docs/architecture/adrs/adr-006-multi-tenancy.md`
