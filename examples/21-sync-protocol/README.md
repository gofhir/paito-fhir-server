# 21 — Sync Protocol (replication)

Demonstrates offline-first edge↔cloud replication between two independent
paito servers (both in `edge` mode, each with its own embedded SQLite): pulling
a resumable **change feed** (`GET /_changes`), replaying changes as PUT-by-id
upserts / deletes, verifying id-preserving replication and reference integrity,
propagating a delete **tombstone** incrementally from a cursor, and finally
running the real server-driven `POST /$sync` operation.

## How to run

```bash
# From the repo root: bring up the two peers (CLOUD :3500, EDGE :3510)
docker compose -f docker-compose.sync.yml up -d

# Then run the walkthrough
cd examples/21-sync-protocol
bash run.sh
```

`run.sh` targets `CLOUD_URL=http://localhost:3500/fhir/r4` and
`EDGE_URL=http://localhost:3510/fhir/r4` by default; override those env vars to
point at other hosts. The `POST /$sync` step uses `PEER_URL=http://cloud:3500/fhir/r4`
— the CLOUD address as seen *inside the EDGE container* (the sync egress guard
always blocks `localhost` peers, so a non-loopback address is required).
