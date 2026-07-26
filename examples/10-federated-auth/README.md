# 10 — Federated Auth (external OIDC / Keycloak)

This example runs the complete **federated SMART App Launch** against a real
Keycloak. paito acts as the SMART on FHIR authorization server (consent, client
registry, token issuance) while delegating **user login** to Keycloak. `run.sh`
walks the whole flow: `/auth/authorize` → redirect to Keycloak → `dr.smith` logs
in → paito's `/auth/oidc/callback` validates Keycloak's `id_token` signature
against the realm JWKS, resolves the federated `(issuer, subject)` pair to
`Practitioner/dr-smith` via the binding table, and sets a session → consent →
paito issues **its own** access_token + id_token (`iss = paito`, never Keycloak's
tokens) → the token authorizes `GET /Patient`. `practitioner.json` is the FHIR
resource the `(issuer, subject)` binding points at (shown for reference).

## How to run

```bash
# From the repo root — boot paito + Keycloak + Postgres
docker compose -f docker-compose.federated.yml up -d

# Wait until paito is ready
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

# Drive the federated login end-to-end
bash examples/10-federated-auth/run.sh
```

The script is self-contained (needs `curl` and `python3`). Keycloak is reached at
`host.docker.internal:8081` via `curl --resolve`, matching how paito reaches it
inside the Docker network, so the OIDC issuer is identical on both sides.
