# Paito FHIR Server

A production-ready FHIR R4/R4B/R5 server written in Go.

## Features

- **FHIR R4, R4B, R5** — Full resource CRUD, search, history, transactions
- **Dual Storage** — PostgreSQL (with RLS multi-tenancy) or MongoDB
- **Terminology Service** — SNOMED CT, LOINC, ICD-O-3 with `$expand`, `$validate-code`, `$lookup`, `$subsumes`
- **SMART on FHIR** — OAuth2 authorization, patient compartment filtering, consent enforcement
- **Subscriptions** — R5 Backport IG with NATS (embedded), RabbitMQ, or Kafka brokers
- **Validation** — Profile-driven validation from StructureDefinitions, `$validate` operation
- **Implementation Guides** — Install any IG from packages.fhir.org or custom `.tgz` URLs
- **Full-Text Search** — `_text`, `_content` via Bleve (embedded) or Elasticsearch
- **Advanced Search** — `_filter`, `_has`, `_include`, `_revinclude`, `_contained`, chained parameters
- **Bulk Data Export** — FHIR Bulk Data Access IG (`$export`)
- **GraphQL** — Dynamic schema generated from StructureDefinitions
- **XML + JSON** — Full FHIR XML and JSON format support
- **Narrative Generation** — Automatic XHTML narrative generation for all resource types
- **Observability** — OpenTelemetry traces, metrics, and logs (Grafana stack)
- **Admin API** — Server management, OAuth client CRUD, IG management, audit query
- **Security** — TLS, CORS, XSS sanitization, security labels, Break-the-Glass protocol

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

## Deployment Profiles

Each profile is a standalone docker-compose file ready to use:

| Profile | File | Description |
|---------|------|-------------|
| Minimal | `docker-compose.yml` | FHIR server + PostgreSQL |
| MongoDB | `docker-compose.mongodb.yml` | FHIR server + MongoDB + PostgreSQL |
| Auth | `docker-compose.auth.yml` | + SMART on FHIR, Admin API, Audit |
| Subscriptions | `docker-compose.subscriptions.yml` | + R5 Subscriptions with RabbitMQ |
| Observability | `docker-compose.observability.yml` | + OpenTelemetry, Grafana, Tempo, Loki |
| Full | `docker-compose.full.yml` | All features enabled |

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
| `OTEL_TRACING_ENABLED` | `false` | Enable OpenTelemetry traces |
| `OTEL_METRICS_ENABLED` | `false` | Enable OpenTelemetry metrics |
| `OTEL_LOGS_ENABLED` | `false` | Enable OpenTelemetry logs |

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
