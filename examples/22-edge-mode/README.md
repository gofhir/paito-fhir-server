# 22 — Edge Mode

Demonstrates the Paito FHIR server running in **edge mode**: the full FHIR API
(CRUD, search, `$validate`, history, transactions) as a single self-contained
process backed by embedded SQLite — no PostgreSQL, no message broker, no network
at boot. `run.sh` drives a complete Patient lifecycle (create → read → update →
search → `$validate`) and confirms the edge invariant that the admin API port is
closed.

## How to run

```bash
# From the repo root — launch a single edge-mode server on embedded SQLite:
docker compose -f docker-compose.edge.yml up -d

# Wait until ready, then run the examples:
bash examples/22-edge-mode/run.sh
```

The server listens on `http://localhost:3500/fhir/r4`. Override with
`BASE_URL=... bash run.sh` if you mapped a different port.

> Upstream sync between edge nodes (`$sync` / `_changes`) is **experimental** and
> demonstrated separately in `docker-compose.sync.yml` / `examples/21-sync-protocol`.
