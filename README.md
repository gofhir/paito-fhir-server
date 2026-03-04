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

### PostgreSQL (recommended)

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
# FHIR metadata
curl http://localhost:3500/fhir/r4/metadata

# Create a Patient
curl -X POST http://localhost:3500/fhir/r4/Patient \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Patient","name":[{"family":"Garcia","given":["Maria"]}]}'

# Search
curl "http://localhost:3500/fhir/r4/Patient?name=Garcia"
```

## Endpoints

| Endpoint | Description |
|----------|-------------|
| `http://localhost:3500/fhir/r4` | FHIR REST API |
| `http://localhost:3500/fhir/r4/metadata` | CapabilityStatement |
| `http://localhost:3500/graphql` | GraphQL API |
| `http://localhost:3501` | Admin API |
| `http://localhost:3501/ui` | Admin Web UI |

## Configuration

Configuration is done via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `FHIR_VERSION` | `R4` | FHIR version: R4, R4B, R5 |
| `GOFHIR_SERVER_PORT` | `3500` | FHIR API port |
| `GOFHIR_STORAGE_DRIVER` | `postgres` | Storage: `postgres` or `mongodb` |
| `GOFHIR_DATABASE_HOST` | `localhost` | PostgreSQL host |
| `GOFHIR_DATABASE_PORT` | `5432` | PostgreSQL port |
| `GOFHIR_DATABASE_USER` | `gofhir` | PostgreSQL user |
| `GOFHIR_DATABASE_PASSWORD` | `gofhir` | PostgreSQL password |
| `GOFHIR_DATABASE_NAME` | `gofhir` | PostgreSQL database |
| `GOFHIR_MONGODB_URI` | — | MongoDB connection URI |
| `AUTH_ENABLED` | `false` | Enable SMART on FHIR auth |
| `VALIDATION_ENABLED` | `true` | Enable resource validation |
| `TERMINOLOGY_ENABLED` | `true` | Enable terminology service |
| `FULLTEXT_ENABLED` | `true` | Enable full-text search |
| `NARRATIVE_ENABLED` | `true` | Enable narrative generation |
| `MULTI_TENANCY_ENABLED` | `false` | Enable multi-tenancy (RLS) |

## Docker Image

```bash
docker pull ghcr.io/gofhir/paito-fhir-server:latest
```

Available tags:
- `latest` — latest stable release
- `vX.Y.Z` — specific version
- `vX.Y` — latest patch for a minor version
- `vX` — latest minor for a major version

Multi-architecture: `linux/amd64` and `linux/arm64`.

## FHIR Operations

| Operation | Level | Description |
|-----------|-------|-------------|
| `$validate` | Instance/Type | Validate resource against profiles |
| `$expand` | Type | Expand a ValueSet |
| `$validate-code` | Type | Validate a code against CodeSystem/ValueSet |
| `$lookup` | Type | Look up a code in a CodeSystem |
| `$subsumes` | Type | Test subsumption between codes |
| `$export` | System/Patient | Bulk data export (NDJSON) |
| `$everything` | Instance | Patient compartment export |

## License

Proprietary. The Docker image is provided for evaluation and use under the terms specified by the author.
