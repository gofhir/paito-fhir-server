# Storage Backends & Full-Text Search

**What it is** — Paito can persist FHIR resources on any of five storage backends:
**PostgreSQL** (default, most complete), **MongoDB**, **SQLite**, **MySQL**, and
**SQL Server**. Core FHIR (CRUD, history, transactions, common search) works on
every backend; several advanced capabilities are PostgreSQL-only. Independently
of the resource store, Paito ships an embedded **Bleve** full-text search engine
that serves the `_text` and `_content` search parameters, with optional
**Elasticsearch** as an external FTS/terminology engine.

**When to use it**

- **PostgreSQL** — production deployments that need terminology, hierarchy search
  (`:above`/`:below`), MDM, bulk export (`$export`), audit persistence, or
  database-enforced (Row-Level Security) multi-tenancy.
- **MongoDB** — document-oriented teams, horizontal scaling, native geo-proximity
  search (`_near`); reaches ~97% feature parity with PostgreSQL. Requires a
  replica set (even single-node `rs.initiate()`), and PostgreSQL is still needed
  for terminology/auth/audit.
- **SQLite** — single-node dev, test, and edge deployments; no external database.
- **MySQL / SQL Server** — organisations standardised on those engines that need
  only core FHIR plus common search (share Paito's SQL adapter with SQLite).
- **Full-text search** — find resources by human-readable narrative (`_text`) or
  by any text anywhere in the resource (`_content`), on any backend.

> Not every feature is available on every backend. Terminology, MDM, `$export`,
> CDC system history, real RLS multi-tenancy, and audit persistence are
> **PostgreSQL-only**. See the compatibility matrix in the go-fhir-server
> "Features by Backend" doc linked below.

## Launch

The requests are backend-agnostic — pick one store and bring it up:

```bash
# PostgreSQL (default backend, Bleve FTS enabled):
docker compose -f docker-compose.yml up -d

# MongoDB backend (PostgreSQL still runs for terminology/auth/audit):
docker compose -f docker-compose.mongodb.yml up -d
```

Readiness check:

```bash
curl -s http://localhost:3500/fhir/r4/metadata | grep -o '"resourceType":"CapabilityStatement"'
```

**SQLite** needs no extra service — override the default compose's `paito`
environment with `STORAGE_DRIVER=sqlite` and `SQLITE_PATH=/app/data/fhir.db`
(the `paito_data` volume already persists `/app/data`). **MySQL** and **SQL
Server** are configured through a mounted `config.yaml` (they are not covered by
the storage env-var shortcuts) — mirror the go-fhir-server config and mount it as
`CONFIG_PATH`.

## Examples

Full runnable script: [`examples/28-storage-backends/run.sh`](../examples/28-storage-backends/run.sh).
FTS indexing is asynchronous (best-effort), so allow a moment after a write
before querying `_text`/`_content`.

```bash
# 1. Create a Patient whose narrative mentions diabetes
curl -s -X POST http://localhost:3500/fhir/r4/Patient \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/28-storage-backends/patient-diabetes.json
# → 201 Created, versionId=1 (identical on PostgreSQL, MongoDB, SQLite)
```

```bash
# 2. Common search — token parameter, available on all five backends
curl -s "http://localhost:3500/fhir/r4/Patient?gender=female"
# → 200, a searchset Bundle
```

```bash
# 3. Full-text _text — searches the narrative (Resource.text.div)
curl -s "http://localhost:3500/fhir/r4/Patient?_text=diabetes"
# → 200, Bundle containing the patient whose div mentions "diabetes"
```

```bash
# 4. Full-text _content — searches the whole serialized resource
curl -s "http://localhost:3500/fhir/r4/Observation?_content=blood%20pressure"
# → 200, Bundle of Observations mentioning "blood pressure" anywhere
```

```bash
# 5. FTS combined with a structured parameter (Bleve IDs ∩ active=true)
curl -s "http://localhost:3500/fhir/r4/Patient?_text=diabetes&active=true"
# → 200, intersection of the FTS hits and active=true
```

```bash
# 6. Rebuild the Bleve index for a resource type (admin-gated when auth is on)
curl -s -X POST "http://localhost:3500/fhir/r4/Patient/\$reindex"
# → 200 when the reindex runs; 401/403 if auth is enabled without an admin token
```

## Configuration

Environment variables (authoritative names from `internal/config/config_env.go`):

| Variable | Default | Applies to | Description |
|---|---|---|---|
| `STORAGE_DRIVER` | `postgres` | all | Backend: `postgres`, `mongodb`, `sqlite`, `mysql`, `sqlserver` |
| `POSTGRES_HOST` / `POSTGRES_PORT` | `localhost` / `5432` | postgres, aux | PostgreSQL host/port (aux services always use PostgreSQL) |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `gofhir` | postgres, aux | PostgreSQL credentials and database |
| `POSTGRES_SSL_MODE` | `disable` | postgres | `disable` / `require` / `verify-ca` / `verify-full` |
| `POSTGRES_ENABLE_PARTITIONING` | `false` | postgres | LIST-partition the `sp_*` search index tables |
| `SQLITE_PATH` | — | sqlite | Filesystem path to the SQLite database file |
| `MONGODB_URI` | `mongodb://localhost:27017` | mongodb | Connection string (replica set required) |
| `MONGODB_DATABASE` | `gofhir` | mongodb | Database name |
| `MONGODB_COLLECTION_STRATEGY` | `per_type` | mongodb | `per_type` or `single` |
| `MONGODB_ENABLE_COMBO_INDEXES` | `true` | mongodb | Combo hash indexes for common query patterns |
| `MONGODB_MAX_POOL_SIZE` | `100` | mongodb | Connection pool size |
| `FULLTEXT_ENABLED` | `true` | all | Enable/disable full-text search |
| `FULLTEXT_ENGINE` | `bleve` | all | FTS engine: `bleve` or `noop` |
| `BLEVE_DATA_DIR` | `./data/bleve` | all | On-disk directory for Bleve indexes |
| `ELASTICSEARCH_ENABLED` | `false` | all (opt-in) | Use Elasticsearch as external FTS/terminology engine |
| `ELASTICSEARCH_ADDRESSES` | — | all (opt-in) | Comma-separated node URLs, e.g. `http://elasticsearch:9200` |
| `ELASTICSEARCH_USERNAME` / `ELASTICSEARCH_PASSWORD` | — | all (opt-in) | Elasticsearch credentials |
| `ELASTICSEARCH_FTS_INDEX` | `gofhir-fulltext` | all (opt-in) | Full-text index name |
| `ELASTICSEARCH_TERMINOLOGY_INDEX` | `gofhir-terminology` | all (opt-in) | Terminology text index name |

> **MySQL / SQL Server** are *not* configurable through env-var shortcuts — set
> `storage.driver: mysql|sqlserver` and the matching `storage.mysql` /
> `storage.sqlserver` block in a mounted `config.yaml` (`CONFIG_PATH`).
>
> **Elasticsearch** is opt-in and requires a running cluster with the
> `analysis-icu` and `analysis-phonetic` plugins (see the go-fhir-server
> Elasticsearch deployment doc). Without it, FTS falls back to embedded Bleve.

## References

- Features by Backend — `site/content/en/docs/deployment/features-by-backend.md`
- Database (PostgreSQL) — `site/content/en/docs/deployment/database.md`
- MongoDB — `site/content/en/docs/deployment/mongodb.md`
- Full-Text Search (Bleve, `_text`/`_content`, `$reindex`) — `site/content/en/docs/search-indexing/full-text-search.md`
- Elasticsearch — `site/content/en/docs/deployment/elasticsearch.md` and `site/content/en/docs/search-indexing/elasticsearch.md`
