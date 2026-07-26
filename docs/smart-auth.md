# SMART on FHIR (OAuth2 / SMART App Launch)

**What it is** — Paito ships an embedded SMART on FHIR authorization server: a
standards-compliant OAuth2 provider (SMART App Launch v1 + v2) built into the
FHIR server. It publishes SMART discovery and a JWKS, issues signed access
tokens for the `authorization_code` (browser apps, with PKCE), `client_credentials`
(Backend Services), and `refresh_token` grants, and enforces SMART scopes —
including v2 granular sub-scopes — on every FHIR request. Every operation is
recorded in a queryable `AuditEvent` trail.

**When to use it**

- Protect the FHIR API so anonymous requests are rejected (401) and every call carries a bearer token.
- Let patient- or provider-facing SMART apps launch via `authorization_code` + PKCE and receive a `patient` launch context.
- Grant server-to-server / bulk clients access via `client_credentials` (symmetric secret) or Backend Services `private_key_jwt` (asymmetric, no shared secret).
- Restrict a client to specific resource types and verbs (`system/Patient.rs`) or a fine-grained slice (`system/Observation.rs?category=laboratory`).
- Produce an audit trail of who accessed what, attributed by `clientId`.

## Launch

```bash
docker compose -f docker-compose.smart-auth.yml up -d

# readiness check
curl -s http://localhost:3500/fhir/r4/metadata | head -c 80
```

The compose mounts `config/smart-auth.yaml` (SMART turned on, issuer, audit) and
`config/clients.smart-auth.yaml` (six demo OAuth clients seeded via GitOps). The
bare `docker-compose.auth.yml` turns auth on but seeds no clients or login user,
so use this file to run the flows end-to-end.

## Examples

**1. SMART discovery + JWKS**

```bash
curl -s http://localhost:3500/.well-known/smart-configuration | python3 -m json.tool
curl -s http://localhost:3500/.well-known/jwks.json | python3 -m json.tool
```

Expected: a JSON document with `issuer`, `authorization_endpoint`, `token_endpoint`,
`introspection_endpoint`, `jwks_uri`, `grant_types_supported`, `scopes_supported`,
`code_challenge_methods_supported` (includes `S256`); and a JWKS with at least one
`RS384` signing key.

**2. Anonymous request is rejected**

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3500/fhir/r4/Patient
```

Expected: `401`. The body is a FHIR `OperationOutcome` with `issue.code=login` and
`details.coding.code=invalid_token`.

**3. client_credentials grant → access token (JWT)**

```bash
curl -s -X POST http://localhost:3500/auth/token \
  -u demo-full:demo-full-secret-do-not-use-in-prod \
  -d 'grant_type=client_credentials&scope=system/*.cruds'
```

Expected: `200` with `access_token` (a signed JWT carrying `iss`, `exp`, `iat`,
`scope`, `client_id`), `token_type=Bearer`, `expires_in=3600`. A wrong secret
returns `401` `invalid_client`.

**4. Scope enforcement**

```bash
# read-only client (system/Patient.rs) tries to create a Patient
TOKEN=$(curl -s -X POST http://localhost:3500/auth/token \
  -u demo-readonly:demo-readonly-secret-do-not-use-in-prod \
  -d 'grant_type=client_credentials&scope=system/Patient.rs' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:3500/fhir/r4/Patient \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/fhir+json' \
  -d '{"resourceType":"Patient"}'
```

Expected: `403` — `OperationOutcome` with `issue.code=forbidden`,
`details.coding.code=access_denied`, diagnostic `insufficient scope`. Reading a
type not covered by the scope (e.g. `GET /Observation`) also returns `403`, not a
filtered `200`.

**5. Token introspection (RFC 7662)**

```bash
curl -s -X POST http://localhost:3500/auth/introspect \
  -u demo-full:demo-full-secret-do-not-use-in-prod \
  -d "token=$TOKEN"
```

Expected: `{"active":true, ...}` for a valid token; `{"active":false}` for a bogus one.

**6. Authorization Code + PKCE + patient launch context**

The full browser dance (login → consent → `code` → token exchange) is scripted in
`examples/09-smart-auth/run.sh`. A successful token exchange returns:

```json
{
  "access_token": "…",
  "id_token": "…",
  "refresh_token": "…",
  "patient": "<launch-context Patient id>",
  "scope": "openid fhirUser offline_access launch/patient patient/Patient.read"
}
```

Replaying a consumed `code` returns `400 invalid_grant` (single-use); a wrong PKCE
`code_verifier` or a mismatched `redirect_uri` also returns `400 invalid_grant`.

**7. Refresh token grant**

```bash
curl -s -X POST http://localhost:3500/auth/token \
  -u demo-app:demo-app-secret-do-not-use-in-prod \
  -d "grant_type=refresh_token&refresh_token=<refresh_token>"
```

Expected: `200` with a fresh `access_token`.

**8. Backend Services — private_key_jwt (RFC 7523)**

```bash
curl -s -X POST http://localhost:3500/auth/token \
  --data-urlencode 'grant_type=client_credentials' \
  --data-urlencode 'scope=system/Patient.rs' \
  --data-urlencode 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' \
  --data-urlencode 'client_assertion=<signed JWT>'
```

The `client_assertion` is an RS256-signed JWT with `iss=sub=<client_id>` and
`aud=<issuer>/auth/token` (here `http://localhost:3500/fhir/r4/auth/token`). The
server fetches the client's public key from its registered `jwksUri` and verifies
the assertion. Expected: `200` with an `access_token` and no shared secret; a
replayed assertion (same `jti`) is rejected. `run.sh` generates the key and hosts
the JWKS for you.

## Configuration

The image is configured via a mounted YAML (`CONFIG_PATH`) because seeded OAuth
clients and the consent login user are not plain env vars. The relevant keys /
env vars:

| Env var | Config key | Purpose |
|---|---|---|
| `AUTH_ENABLED` | `auth.enabled` | Turn the auth layer on |
| `AUTH_MODE` | `auth.mode` | `smart` = embedded SMART on FHIR OAuth2 server |
| `AUTH_SMART_ISSUER` | `auth.smart.issuer` | Public base URL used as token issuer / `aud` base |
| `AUTH_SMART_SIGNING_ALGORITHM` | `auth.smart.signingAlgorithm` | Access/ID token signing alg (`RS384`) |
| `AUTH_SMART_SIGNING_KEY_FILE` | `auth.smart.signingKeyFile` | PEM signing key; empty = auto-generate (dev) |
| `AUTH_SCOPES_ALLOW_UNSCOPED` | `auth.scopes.allowUnscoped` | Whether tokens with no scope may access data |
| — | `auth.smart.accessTokenTTL` | Access token lifetime (seconds) |
| — | `auth.smart.refreshTokenTTL` | Refresh token lifetime (seconds) |
| — | `auth.smart.codeExpirySeconds` | Authorization-code lifetime (seconds) |
| — | `auth.smart.requireUserAuth` | Require a logged-in user for consent (auth code flow) |
| — | `auth.scopes.enforceOnRead` | Enforce scopes on reads/searches, not just writes |
| — | `auth.initialAdmin.username/password` | Bootstrap login user for the consent flow |
| `ADMIN_ENABLED` | `admin.enabled` | Admin API (client management + audit query) |
| `ADMIN_API_KEY` | `admin.auth.apiKeys[]` | Bearer key for the admin API |
| — | `admin.gitops.clientsPath` | YAML file of OAuth clients seeded at startup |
| `AUDIT_ENABLED` | `audit.enabled` | Write an `AuditEvent` per operation |
| `AUDIT_LEVEL` | `audit.level` | `all` records reads and writes |

Note: the SMART/OAuth endpoints (`/.well-known/smart-configuration`,
`/.well-known/jwks.json`, `/auth/token`, `/auth/introspect`, `/auth/authorize`,
`/auth/login`, `/auth/launch`) are served at the server root; FHIR resources live
under `/fhir/r4`.

## References

- SMART on FHIR overview: `site/content/en/docs/auth/smart-on-fhir.md`
- OAuth2 grant flows: `site/content/en/docs/auth/oauth2-flows.md`
- SMART scopes (v1 + v2 granular): `site/content/en/docs/auth/scopes.md`
- Patient compartment: `site/content/en/docs/auth/patient-compartment.md`
- Federated / external IdP auth: `site/content/en/docs/auth/federated-auth.md`
