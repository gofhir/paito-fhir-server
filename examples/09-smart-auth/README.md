# 09 — SMART on FHIR (OAuth2 / SMART App Launch)

This example drives the embedded SMART on FHIR authorization server end-to-end with `curl`: SMART discovery + JWKS, an anonymous request rejected with a FHIR `OperationOutcome` (401), the `client_credentials` grant issuing a signed JWT, token introspection (RFC 7662), scope enforcement (a `system/*.cruds` client can write while a `system/Patient.rs` client is blocked with a 403 and cannot read other resource types), the full `authorization_code` + consent + PKCE S256 flow yielding an `id_token`, `refresh_token`, and a `patient` launch context, single-use-code protection, SMART v2 granular sub-scopes (`system/Observation.rs?category=laboratory`), Backend Services `private_key_jwt` (RFC 7523, asymmetric auth with no shared secret), and the queryable `AuditEvent` trail. All clients are seeded via GitOps from `config/clients.smart-auth.yaml`.

## How to run

```bash
# from the repo root — boot the SMART/OAuth2 stack
docker compose -f docker-compose.smart-auth.yml up -d

# wait for readiness
curl -s http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

# run the walkthrough
cd examples/09-smart-auth
bash run.sh
```

Requires `python3` and `openssl` on the host (the Backend Services step hosts a client JWKS on `localhost:9443`, reached by the container via `host.docker.internal`). Tear down with `docker compose -f docker-compose.smart-auth.yml down -v`.
