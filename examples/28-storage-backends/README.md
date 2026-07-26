# 28 — Storage Backends & Full-Text Search

This example shows that Paito's core FHIR surface (CRUD, common search) and its
embedded **full-text search** (`_text` / `_content`, powered by the Bleve engine)
behave identically regardless of the configured storage backend. The exact same
requests run unchanged on **PostgreSQL** (default), **MongoDB**, or **SQLite**.
It creates two Patients and an Observation, runs a token search, then queries the
narrative (`_text=diabetes`) and whole-resource text (`_content=blood pressure`),
combines FTS with a structured parameter, and rebuilds the index with `$reindex`.

## How to run

Bring up any backend, then run the script:

```bash
# From the repo root — PostgreSQL (default backend):
docker compose -f docker-compose.yml up -d

# ...or the MongoDB backend (identical requests, different store):
docker compose -f docker-compose.mongodb.yml up -d

# Wait until the server is ready, then:
curl -s http://localhost:3500/fhir/r4/metadata | head -c 80
bash examples/28-storage-backends/run.sh
```

Full-text indexing is asynchronous (best-effort, in a background goroutine), so
the script pauses briefly before the `_text`/`_content` queries. Override the
target with `BASE_URL=... bash examples/28-storage-backends/run.sh`.
