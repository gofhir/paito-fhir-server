# Federated Auth (external OIDC / Keycloak)

**What it is** — Federated auth (`AUTH_MODE=federated`) lets paito act as the
**SMART on FHIR authorization server** — owning consent, the client registry, and
token issuance — while delegating **user login** to an external OIDC Identity
Provider (Keycloak, Okta, Azure AD). The SMART app only ever talks to paito;
paito redirects the browser to the IdP for authentication, validates the upstream
`id_token` (signature against the realm JWKS, plus `iss` / `aud` / `exp` / `nonce`),
maps the federated identity to a real FHIR user, and then issues **its own** SMART
tokens (`iss = paito`). The IdP's tokens are never exposed to the app.

**When to use it**

- You already run an enterprise IdP (Keycloak, Okta, Azure AD) for login, MFA and SSO and want to reuse it for FHIR access.
- You need SMART on FHIR scopes, consent and token issuance, but do not want to teach the IdP anything FHIR-specific (it only needs standard OIDC authorization-code flow).
- You want federated users mapped to real FHIR resources via a stable `(issuer, subject)` binding rather than a fabricated identity.
- You want role-to-scope mapping (e.g. `clinician` → a fixed scope set) enforced at paito without changing the IdP.

## Launch

```bash
docker compose -f docker-compose.federated.yml up -d

# Readiness check
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
```

This boots three services: `keycloak` (realm `gofhir` on host `8081`, imported
from `config/keycloak/realm-gofhir.json`), `postgres`, and `paito`
(FHIR on `3500`, admin on `3501`, `auth.mode=federated` from the mounted
`config/federated.yaml`). Keycloak is pinned to `host.docker.internal:8081` so
its issuer is identical from inside the network and from the host.

Then drive the full flow:

```bash
bash examples/10-federated-auth/run.sh
```

## Examples

The federated flow is a browser redirect dance; the snippets below show the
key HTTP steps. See `examples/10-federated-auth/run.sh` for the complete,
runnable sequence (PKCE, cookies, CSRF are handled there).

**1. Confirm the pinned IdP issuer (must equal `discoveryURL`)**

```bash
curl -s --resolve host.docker.internal:8081:127.0.0.1 \
  http://host.docker.internal:8081/realms/gofhir/.well-known/openid-configuration \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['issuer'])"
# Expected: http://host.docker.internal:8081/realms/gofhir
```

**2. Start the SMART launch — paito redirects to Keycloak**

```bash
curl -s -D - -o /dev/null \
  "http://localhost:3500/auth/authorize?response_type=code&client_id=smoke-fed-app&redirect_uri=http%3A%2F%2Flocalhost%3A9999%2Fcallback&scope=openid%20fhirUser%20offline_access%20user%2FPatient.read&state=demo-state-1&aud=http%3A%2F%2Flocalhost%3A3500%2Ffhir%2Fr4&code_challenge=<PKCE_CHALLENGE>&code_challenge_method=S256" \
  | grep -i '^location:'
# Expected: Location: http://host.docker.internal:8081/realms/gofhir/protocol/openid-connect/auth?...
```

**3. paito callback validates the Keycloak id_token and sets a session**

```bash
# After Keycloak login redirects back with ?code&state:
curl -s -D - -o /dev/null "http://localhost:3500/auth/oidc/callback?code=...&state=..."
# Expected: Set-Cookie: auth_session=...   (upstream id_token signature validated)
#           Location: .../auth/authorize... (returns to the SMART consent step)
```

**4. Exchange the app code for paito-issued tokens (note the issuer)**

```bash
curl -s -u smoke-fed-app:smoke-fed-app-secret-do-not-use-in-prod \
  -X POST http://localhost:3500/auth/token \
  --data-urlencode grant_type=authorization_code \
  --data-urlencode code=<APP_CODE> \
  --data-urlencode redirect_uri=http://localhost:9999/callback \
  --data-urlencode code_verifier=<PKCE_VERIFIER>
# Expected JSON: access_token + id_token where
#   id_token.iss      = http://localhost:3500   (paito, NOT Keycloak)
#   id_token.fhirUser = Practitioner/dr-smith    (from the (issuer,subject) binding)
```

**5. Use the paito token against the FHIR API**

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer <ACCESS_TOKEN>" \
  "http://localhost:3500/fhir/r4/Patient?_count=0"
# Expected: 200   (the user/Patient.read scope was granted)
```

## Configuration

paito's federated settings are supplied via the mounted `config/federated.yaml`
(under `auth.federated`). Several knobs — `userBindings`, `roleMapping`,
`fhirUserFallback`, `scopes` — have no environment-variable equivalent and must
be set in YAML, which is why this stack mounts a config file rather than using
env vars alone. The env vars below (from `internal/config/config_env.go`) can
override the scalar settings.

| Env var | Config key | Purpose |
|---------|-----------|---------|
| `AUTH_ENABLED` | `auth.enabled` | Master switch (`true`) |
| `AUTH_MODE` | `auth.mode` | Set to `federated` |
| `AUTH_SMART_ISSUER` | `auth.smart.issuer` | paito's OWN token issuer (root URL, no `/fhir/r4`) |
| `AUTH_SMART_SIGNING_ALGORITHM` | `auth.smart.signingAlgorithm` | JWT signing alg (e.g. `RS384`) |
| `AUTH_SMART_SIGNING_KEY_FILE` | `auth.smart.signingKeyFile` | Signing key path; empty = auto-generate (dev) |
| `AUTH_FEDERATED_DISCOVERY_URL` | `auth.federated.discoveryURL` | IdP OIDC discovery URL; also the **pinned** token issuer |
| `AUTH_FEDERATED_AUDIENCE` | `auth.federated.audience` | Expected access-token audience (`aud`) |
| `AUTH_FEDERATED_CLIENT_ID` | `auth.federated.clientId` | OAuth client ID registered at the IdP |
| `AUTH_FEDERATED_CLIENT_SECRET` | `auth.federated.clientSecret` | OAuth client secret |
| `AUTH_FEDERATED_FHIR_USER_CLAIM` | `auth.federated.fhirUserClaim` | id_token claim carrying the FHIR user (default `fhirUser`) |
| `AUTH_FEDERATED_ROLE_CLAIM` | `auth.federated.roleClaim` | Dot-path to roles claim (Keycloak: `realm_access.roles`) |
| `AUTH_FEDERATED_SESSION_TTL` | `auth.federated.sessionTTL` | Session cookie duration (e.g. `30m`) |
| `AUTH_FEDERATED_SESSION_KEY` | `auth.federated.sessionKey` | Session-cookie HMAC key (must be shared across replicas in HA) |

YAML-only keys used by this stack:

| Config key | Purpose |
|-----------|---------|
| `auth.federated.scopes` | OIDC scopes paito requests from the IdP |
| `auth.federated.fhirUserFallback` | `none` (default, no fabrication) / `preferred_username` / `sub` |
| `auth.federated.roleMapping` | Role → allowed SMART scope set (intersection enforced) |
| `auth.federated.userBindings` | `(issuer, subject)` → `fhirUser` bindings (recommended identity source) |

> **Security note.** The default `fhirUserFallback: none` means paito does **not**
> fabricate a FHIR identity. Give federated users a FHIR identity with an explicit
> `(issuer, subject)` binding (stable, non-reassignable) or a signed `fhirUser`
> claim from the IdP — never a mutable username.

## References

- go-fhir-server site docs: `site/content/en/docs/auth/federated-auth.md` (Federated Auth (OIDC))
- Related: `site/content/en/docs/auth/smart-on-fhir.md`, `site/content/en/docs/auth/scopes.md`, `site/content/en/docs/auth/oauth2-flows.md`
- Proven e2e sources: `scripts/e2e-federated-smoke.sh`, `scripts/e2e-federated-ha-smoke.sh`
- Smoke stack this compose mirrors: `deployments/docker/docker-compose.smoke-federated.yaml`, `configs/config.smoke-federated.yaml`
