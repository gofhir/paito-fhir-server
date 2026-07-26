# Paito FHIR Server

A production-ready FHIR R4/R4B/R5 server written in Go.

> **New here?** Jump to the **[Use-case catalog](USE-CASES.md)** — a runnable demo,
> launch command, and guide for every capability below.

## Features

Every feature ships a standalone guide in [`docs/`](docs/) and a runnable demo in [`examples/`](examples/).

- **[FHIR R4, R4B, R5](docs/crud.md)** — Full resource CRUD, [history & versioning](docs/crud.md), [bundles](docs/bundles.md), [conditional ops & PATCH](docs/conditional-patch.md), [documents](docs/documents.md), [binary](docs/binary.md)
- **[Search](docs/search.md)** — All parameter types & modifiers, `_include`/`_revinclude`/`_has`/chained, `_sort`/paging/`_summary`
- **[Storage Backends](docs/storage-backends.md)** — PostgreSQL, MongoDB, SQLite, MySQL, SQL Server + [full-text search](docs/storage-backends.md) (`_text`/`_content` via Bleve or Elasticsearch)
- **[Terminology Service](docs/terminology.md)** — SNOMED CT, LOINC, ICD, FONASA with `$expand`, `$validate-code`, `$lookup`, `$subsumes`, `$translate`, `$closure`
- **[Validation, Profiles & IGs](docs/validation-ig.md)** — Profile-driven validation, `$validate`, install any IG from packages.fhir.org
- **[FHIR Operations](docs/operations.md)** — `$validate`, `Patient/$everything`, `$meta`, `$convert`, `$versions`/`$lastn`/`$stats`, output shaping
- **[SMART on FHIR](docs/smart-auth.md)** — Embedded OAuth2, PKCE, Backend Services, granular scopes, patient launch context
- **[Federated Auth](docs/federated-auth.md)** — Broker login to external OIDC (Keycloak/Okta/Azure AD)
- **[Multi-Tenancy](docs/multi-tenancy.md)** — Header (`X-Tenant-ID`) or JWT-claim data isolation
- **[Subscriptions](docs/subscriptions.md)** — R4 criteria + R5 Backport topics; NATS (embedded), RabbitMQ, or Kafka brokers
- **[Bulk Data](docs/bulk-data.md)** — FHIR Bulk Data Access IG (`$export`), experimental opt-in `$import`
- **[Messaging](docs/messaging.md)** — `$process-message` envelope/profile validation, async delivery
- **[MDM](docs/mdm.md)** — Golden-record auto-linking + full `$mdm-*` steward operation surface
- **[FHIR-as-Code / GitOps](docs/fhir-as-code.md)** — Reconcile declarative FHIR files from a git-tracked repo
- **[Sync Protocol](docs/sync-protocol.md)** & **[Edge Mode](docs/edge-mode.md)** — Edge↔cloud replication; full FHIR API on embedded SQLite
- **[GraphQL](docs/graphql.md)** — Dynamic schema generated from StructureDefinitions + Playground UI
- **[XML + Narrative](docs/xml-narrative.md)** — Full FHIR XML content negotiation + automatic XHTML narrative generation
- **[StructureMap `$transform`](docs/transform-fml.md)** & **[HL7 v2](docs/hl7v2.md)** — Native FML engine; `$parse-v2` for legacy v2 feeds
- **[SQL on FHIR v2](docs/sql-on-fhir.md)** — Flatten FHIR to tabular JSON/CSV/NDJSON via ViewDefinition `$run`
- **[Clinical Reasoning](docs/clinical-reasoning.md)** — CQL, quality measures, CRMI lifecycle, CDS Hooks 2.0
- **[Security](docs/security.md)** — Security labels, Break-the-Glass, Consent, redaction, Provenance + AuditEvent trail
- **[Custom Operations](docs/custom-operations.md)** — Extension point via the shipped `$example-echo` reference operation *(experimental)*
- **[Admin API & Web UI](docs/admin-api.md)** — Server management, OAuth client CRUD, IG management, audit query/export (`:3501`)
- **[Observability](docs/observability.md)** — OpenTelemetry traces, metrics, and logs (Grafana + Tempo + Prometheus + Loki)

## Quick Start

### Minimal (PostgreSQL only)

```bash
curl -O https://raw.githubusercontent.com/gofhir/paito-fhir-server/main/docker-compose.yml
docker compose up -d
```

### MongoDB

```bash
curl -O https://raw.githubusercontent.com/gofhir/paito-fhir-server/main/docker-compose.mongodb.yml
docker compose -f docker-compose.mongodb.yml up -d
```

### Verify

```bash
# CapabilityStatement
curl http://localhost:3500/fhir/r4/metadata | jq .

# Create a Patient
curl -X POST http://localhost:3500/fhir/r4/Patient \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Patient","name":[{"family":"Garcia","given":["Maria"]}]}'

# Search
curl "http://localhost:3500/fhir/r4/Patient?name=Garcia"
```

## Use-case catalog

The **[USE-CASES.md](USE-CASES.md)** catalog is the fastest way to try every
capability: it lists each feature with a one-line description, the exact
`docker compose -f <file> up -d` command, its runnable `examples/<dir>/run.sh`
script, and a link to its guide. Features are grouped into Core FHIR API, Search,
Terminology, Security & Auth, Multi-Tenancy, Async & Eventing, Data Management,
Interop & Formats, Clinical Reasoning, and Operations & Ops.

Every demo assumes the published image `ghcr.io/gofhir/paito-fhir-server:latest`
and `BASE_URL=http://localhost:3500/fhir/r4`. Compose files are standalone and each
binds `:3500`, so run one stack at a time.

```bash
# Example: launch a feature stack and run its demo
docker compose -f docker-compose.terminology.yml up -d
curl -sf http://localhost:3500/fhir/r4/metadata > /dev/null && echo "ready"
bash examples/06-terminology/run.sh
```

## Deployment Profiles

Each profile is a standalone docker-compose file ready to use:

| Profile | File | Description | Guide |
|---------|------|-------------|-------|
| Minimal | `docker-compose.yml` | FHIR server + PostgreSQL (CRUD, search, bundles, docs, binary, `$transform`, HL7v2) | [crud](docs/crud.md) |
| MongoDB | `docker-compose.mongodb.yml` | FHIR server + MongoDB + PostgreSQL; full-text search | [storage-backends](docs/storage-backends.md) |
| Auth | `docker-compose.auth.yml` | + SMART on FHIR, Admin API, Audit | [smart-auth](docs/smart-auth.md) |
| SMART on FHIR | `docker-compose.smart-auth.yml` | Embedded OAuth2 with six seeded demo clients | [smart-auth](docs/smart-auth.md) |
| Federated Auth | `docker-compose.federated.yml` | + Keycloak external OIDC broker | [federated-auth](docs/federated-auth.md) |
| Terminology | `docker-compose.terminology.yml` | + `$expand`/`$lookup`/`$validate-code`/`$closure` (embedded packages) | [terminology](docs/terminology.md) |
| Validation & IG | `docker-compose.validation-ig.yml` | + US Core / IPS profile validation | [validation-ig](docs/validation-ig.md) |
| Multi-Tenancy | `docker-compose.multitenancy.yml` | + `X-Tenant-ID` data isolation | [multi-tenancy](docs/multi-tenancy.md) |
| Subscriptions | `docker-compose.subscriptions.yml` | + R5 Subscriptions with RabbitMQ | [subscriptions](docs/subscriptions.md) |
| Bulk Data | `docker-compose.bulk-data.yml` | + `$export` / experimental `$import` | [bulk-data](docs/bulk-data.md) |
| Messaging | `docker-compose.messaging.yml` | + `$process-message` | [messaging](docs/messaging.md) |
| SQL on FHIR | `docker-compose.sqlfhir.yml` | + SQL on FHIR v2 ViewDefinition execution | [sql-on-fhir](docs/sql-on-fhir.md) |
| GraphQL | `docker-compose.graphql.yml` | + GraphQL transport + Playground | [graphql](docs/graphql.md) |
| XML & Narrative | `docker-compose.xml-narrative.yml` | + FHIR XML + narrative generation | [xml-narrative](docs/xml-narrative.md) |
| MDM | `docker-compose.mdm.yml` | + Master Data Management (Patient/Practitioner/Organization) | [mdm](docs/mdm.md) |
| FHIR-as-Code | `docker-compose.gitops.yml` | + GitOps reconciliation of declarative FHIR files | [fhir-as-code](docs/fhir-as-code.md) |
| Sync Protocol | `docker-compose.sync.yml` | Two-peer edge↔cloud replication | [sync-protocol](docs/sync-protocol.md) |
| Edge Mode | `docker-compose.edge.yml` | Full FHIR API on embedded SQLite (zero external services) | [edge-mode](docs/edge-mode.md) |
| Clinical Reasoning | `docker-compose.clinical-reasoning.yml` | + CQL, measures, CRMI, CDS Hooks | [clinical-reasoning](docs/clinical-reasoning.md) |
| Custom Operations | `docker-compose.custom-operations.yml` | + `$example-echo` reference operation *(experimental)* | [custom-operations](docs/custom-operations.md) |
| Security | `docker-compose.security.yml` | + labels, Break-the-Glass, Consent, redaction, Provenance | [security](docs/security.md) |
| Admin | `docker-compose.admin.yml` | + Admin API & Web Dashboard on `:3501` | [admin-api](docs/admin-api.md) |
| Observability | `docker-compose.observability.yml` | + OpenTelemetry, Grafana, Tempo, Loki | [observability](docs/observability.md) |
| Full | `docker-compose.full.yml` | All features enabled | [USE-CASES.md](USE-CASES.md) |

```bash
# Example: Subscriptions with RabbitMQ
docker compose -f docker-compose.subscriptions.yml up -d

# Example: Full stack
docker compose -f docker-compose.full.yml up -d
```

---

## Enabling Features

By default, only the FHIR server and database are enabled. All features are activated via environment variables.

### SMART on FHIR Authentication

```yaml
environment:
  AUTH_ENABLED: "true"
  AUTH_MODE: smart                          # Embedded OAuth2 server
  AUTH_SMART_ISSUER: "http://localhost:3500"
  # AUTH_SMART_SIGNING_KEY_FILE: ""         # Empty = auto-generate keypair (dev)
  # AUTH_SCOPES_ALLOW_UNSCOPED: "false"     # Require Bearer token
```

Or use an external IdP (Keycloak, Auth0):

```yaml
environment:
  AUTH_ENABLED: "true"
  AUTH_MODE: external
  AUTH_EXTERNAL_ISSUER: "https://keycloak.example.com/realms/fhir"
  AUTH_EXTERNAL_JWKS_URI: "https://keycloak.example.com/realms/fhir/protocol/openid-connect/certs"
  AUTH_EXTERNAL_AUDIENCE: "https://fhir.example.com/fhir/r4"
```

### Subscriptions (R5 Backport IG)

Supports three broker drivers:

**NATS (embedded, zero-config)**
```yaml
environment:
  SUBSCRIPTION_ENABLED: "true"
  BROKER_DRIVER: "nats"
  BROKER_INCLUDE_PAYLOAD: "true"
```

**RabbitMQ**
```yaml
environment:
  SUBSCRIPTION_ENABLED: "true"
  BROKER_DRIVER: "rabbitmq"
  BROKER_INCLUDE_PAYLOAD: "true"
  BROKER_RABBITMQ_URL: "amqp://guest:guest@rabbitmq:5672/"
  BROKER_RABBITMQ_EXCHANGE: "fhir.events"
  BROKER_RABBITMQ_EXCHANGE_TYPE: "topic"
  BROKER_RABBITMQ_DURABLE: "true"
```

**Kafka**
```yaml
environment:
  SUBSCRIPTION_ENABLED: "true"
  BROKER_DRIVER: "kafka"
  BROKER_INCLUDE_PAYLOAD: "true"
  BROKER_KAFKA_BROKERS: "kafka:9092"
  BROKER_KAFKA_TOPIC_PREFIX: "fhir.events"
  BROKER_KAFKA_NUM_PARTITIONS: "3"
  BROKER_KAFKA_REPLICATION_FACTOR: "1"
```

### OpenTelemetry Observability

```yaml
environment:
  # Traces → Tempo
  OTEL_TRACING_ENABLED: "true"
  OTEL_TRACING_EXPORTER: otlp
  OTEL_TRACING_ENDPOINT: "otel-collector:4317"
  OTEL_TRACING_SERVICE_NAME: paito-fhir-server

  # Metrics → Prometheus
  OTEL_METRICS_ENABLED: "true"
  OTEL_METRICS_PORT: "9090"

  # Logs → Loki
  OTEL_LOGS_ENABLED: "true"
  OTEL_LOGS_EXPORTER: otlp
  OTEL_LOGS_ENDPOINT: "otel-collector:4317"
```

Pipeline: `Paito → OTel Collector (:4317) → Tempo + Loki + Prometheus → Grafana (:3000)`

Use `docker-compose.observability.yml` for the complete stack with pre-configured Grafana.

### Terminology Service

Load SNOMED CT, LOINC, or ICD-O-3 code systems. Two modes available:

**Mode 1: Local files (Docker volume)**

```yaml
environment:
  TERMINOLOGY_ENABLED: "true"
  TERMINOLOGY_SNOMED_PATH: "/app/terminology/SnomedCT.zip"
  TERMINOLOGY_SNOMED_VERSION: "20251201"
volumes:
  - ./terminology:/app/terminology:ro
```

Place your ZIP files in a local `./terminology/` folder and mount it as a read-only volume.

**Mode 2: Remote URL (downloaded at startup)**

```yaml
environment:
  TERMINOLOGY_ENABLED: "true"
  TERMINOLOGY_SNOMED_URL: "https://my-bucket.s3.amazonaws.com/SnomedCT.zip"
  TERMINOLOGY_SNOMED_VERSION: "20251201"
```

No volume needed. The server downloads the ZIP on first startup and caches it in `/app/data/terminology/`. Use a named volume for `/app/data` to persist across restarts.

**Multiple code systems:**

```yaml
environment:
  TERMINOLOGY_ENABLED: "true"
  TERMINOLOGY_SNOMED_PATH: "/app/terminology/SnomedCT.zip"
  TERMINOLOGY_SNOMED_VERSION: "20251201"
  TERMINOLOGY_LOINC_URL: "https://bucket.s3.amazonaws.com/Loinc.zip"
  TERMINOLOGY_LOINC_VERSION: "2.77"
  TERMINOLOGY_ICDO_PATH: "/app/terminology/ICDO3.zip"
```

Both modes can be combined. If both `_PATH` and `_URL` are set for the same format, the local path takes priority.

Use `docker-compose.terminology.yml` for a ready-to-use profile.

### Validation

```yaml
environment:
  VALIDATION_ENABLED: "true"
  VALIDATION_MODE: "enforced"         # enforced | declared | optional | off
  VALIDATION_STRICT: "false"          # Treat warnings as errors
  VALIDATION_TERMINOLOGY_MODE: "internal"  # off | internal | external
```

### Admin System

```yaml
environment:
  ADMIN_ENABLED: "true"
  AUDIT_ENABLED: "true"
```

Endpoints:
- `http://localhost:3501/ui` — Web dashboard
- `http://localhost:3501/health` — Health check
- `http://localhost:3501/api/clients` — OAuth client management
- `http://localhost:3501/api/packages` — IG management
- `http://localhost:3501/api/config` — Configuration
- `http://localhost:3501/api/audit` — Audit log query

### Multi-Tenancy

```yaml
environment:
  MULTI_TENANCY_ENABLED: "true"
  # JWT_CLAIM_NAME: "tenant_id"
  # TENANT_HEADER_NAME: "X-Tenant-ID"
```

Uses PostgreSQL Row-Level Security (RLS) for complete data isolation between tenants.

### SQL on FHIR v2

Execute [ViewDefinitions](https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/) against stored FHIR resources. Supports NDJSON, CSV, and JSON output.

```yaml
environment:
  SQLFHIR_ENABLED: "true"
  SQLFHIR_DEFAULT_FORMAT: "ndjson"    # ndjson | csv | json
  SQLFHIR_MAX_ROWS_SYNC: "10000"
  SQLFHIR_MAX_RESOURCES: "50000"
  # SQLFHIR_EXPORT_ENABLED: "true"   # Async export for large datasets
  # SQLFHIR_EXPORT_TIMEOUT: "10m"
```

Use `docker-compose.sqlfhir.yml` for a ready-to-use profile.

### Master Data Management (MDM)

Automatic patient matching and linking with MDM links synced to `Patient.link[]`.

```yaml
environment:
  MDM_ENABLED: "true"
  MDM_MANAGED_TYPES: "Patient,Practitioner,Organization"
  MDM_SURVIVORSHIP_STRATEGY: "mostRecent"  # mostRecent | manual
  MDM_AUTO_LINK: "true"
  MDM_SYNC_PATIENT_LINKS: "true"
  # MDM_RULES_PATH: "/app/config/mdm-rules.json"
  # MDM_ASYNC_TIMEOUT: "10s"
```

Use `docker-compose.mdm.yml` for a ready-to-use profile.

---

## Endpoints

| Endpoint | Description |
|----------|-------------|
| `http://localhost:3500/fhir/r4` | FHIR REST API |
| `http://localhost:3500/fhir/r4/metadata` | CapabilityStatement |
| `http://localhost:3501/ui` | Admin Web UI (requires `ADMIN_ENABLED=true`) |

## Environment Variables Reference

### Server & Storage

| Variable | Default | Description |
|----------|---------|-------------|
| `FHIR_VERSION` | `R4` | FHIR version: R4, R4B, R5 |
| `STORAGE_DRIVER` | `postgres` | Storage: `postgres` or `mongodb` |
| `POSTGRES_HOST` | `localhost` | PostgreSQL host |
| `POSTGRES_USER` | `gofhir` | PostgreSQL user |
| `POSTGRES_PASSWORD` | `gofhir` | PostgreSQL password |
| `POSTGRES_DB` | `gofhir` | PostgreSQL database |
| `MONGODB_URI` | — | MongoDB connection URI |
| `MONGODB_DATABASE` | `gofhir` | MongoDB database name |

### Feature Toggles

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTH_ENABLED` | `false` | Enable SMART on FHIR auth |
| `VALIDATION_ENABLED` | `false` | Enable resource validation |
| `TERMINOLOGY_ENABLED` | `false` | Enable terminology service |
| `FULLTEXT_ENABLED` | `false` | Enable full-text search (`_text`, `_content`) |
| `NARRATIVE_ENABLED` | `false` | Enable narrative generation |
| `SUBSCRIPTION_ENABLED` | `false` | Enable subscription engine |
| `ADMIN_ENABLED` | `false` | Enable admin API + web UI |
| `AUDIT_ENABLED` | `false` | Enable audit logging |
| `MULTI_TENANCY_ENABLED` | `false` | Enable multi-tenancy (RLS) |
| `SQLFHIR_ENABLED` | `false` | Enable SQL on FHIR v2 |
| `MDM_ENABLED` | `false` | Enable Master Data Management |
| `OTEL_TRACING_ENABLED` | `false` | Enable OpenTelemetry traces |
| `OTEL_METRICS_ENABLED` | `false` | Enable OpenTelemetry metrics |
| `OTEL_LOGS_ENABLED` | `false` | Enable OpenTelemetry logs |

### Terminology Loading

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `TERMINOLOGY_SNOMED_PATH` | — | Local path to SNOMED CT ZIP (volume mount) |
| `TERMINOLOGY_SNOMED_URL` | — | Remote URL to download SNOMED CT ZIP |
| `TERMINOLOGY_SNOMED_VERSION` | — | SNOMED CT version (e.g., `20251201`) |
| `TERMINOLOGY_SNOMED_NAME` | `SNOMED CT` | Custom display name |
| `TERMINOLOGY_LOINC_PATH` | — | Local path to LOINC ZIP |
| `TERMINOLOGY_LOINC_URL` | — | Remote URL to download LOINC ZIP |
| `TERMINOLOGY_LOINC_VERSION` | — | LOINC version (e.g., `2.77`) |
| `TERMINOLOGY_LOINC_NAME` | `LOINC` | Custom display name |
| `TERMINOLOGY_ICDO_PATH` | — | Local path to ICD-O-3 ZIP |
| `TERMINOLOGY_ICDO_URL` | — | Remote URL to download ICD-O-3 ZIP |
| `TERMINOLOGY_ICDO_VERSION` | — | ICD-O-3 version |
| `TERMINOLOGY_ICDO_NAME` | `ICD-O-3` | Custom display name |

## FHIR Operations

| Operation | Level | Description |
|-----------|-------|-------------|
| `$validate` | Instance/Type | Validate resource against profiles |
| `$expand` | Type | Expand a ValueSet |
| `$validate-code` | Type | Validate a code against CodeSystem/ValueSet |
| `$lookup` | Type | Look up a code in a CodeSystem |
| `$subsumes` | Type | Test subsumption between codes |
| `$export` | System/Patient | Bulk data export (NDJSON) |

## Docker Image

```bash
docker pull ghcr.io/gofhir/paito-fhir-server:latest
```

Available tags:
- `latest` — latest stable release
- `vX.Y.Z` — specific version (e.g., `0.1.0`)
- `vX.Y` — latest patch for a minor version
- `vX` — latest minor for a major version

Multi-architecture: `linux/amd64` and `linux/arm64`.

## License

Proprietary. The Docker image is provided for evaluation and use under the terms specified by the author.
