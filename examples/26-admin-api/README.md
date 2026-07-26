# 26 — Admin API & Web UI

Demonstrates the Paito **Admin API** and **Web Dashboard**, served on a separate
port (`:3501`) from the FHIR API (`:3500`). The script drives the same admin
endpoints the go-fhir-server security smoke exercises — API-key/Bearer auth,
`/api/clients`, `/api/audit/events`, `/api/audit/stats` — and adds OAuth client
CRUD, IG/package listing, configuration read, and PostgreSQL storage stats +
`VACUUM`. Every request is authenticated with an admin API key and authorized by
RBAC (the demo key defaults to the `super` role).

## How to run

```bash
# from the repo root
docker compose -f docker-compose.admin.yml up -d

# wait for readiness
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

# run the demo
bash examples/26-admin-api/run.sh
```

Open the web dashboard at <http://localhost:3501/ui/>. Tear down with
`docker compose -f docker-compose.admin.yml down -v`.

The admin key is `paito-admin-key-change-me` (set via `ADMIN_API_KEY` in
`docker-compose.admin.yml`) — change it before exposing the admin port.
