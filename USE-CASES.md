# Paito FHIR Server — Use-Case Catalog

A hands-on tour of **every** capability of the Paito FHIR Server. Each entry below
is a self-contained, runnable demo: launch its compose stack, then run its
`examples/<dir>/run.sh` script and read its guide in `docs/`.

> **Conventions**
> - All examples run against the published image **`ghcr.io/gofhir/paito-fhir-server:latest`**.
> - The FHIR REST API is served at **`http://localhost:3500/fhir/r4`**; the Admin plane at **`http://localhost:3501`**.
> - Every `run.sh` honors `BASE_URL` and defaults to `http://localhost:3500/fhir/r4`.
> - **Each compose file is standalone and binds `:3500`** — run one stack at a time
>   (`docker compose -f <other> down` before switching).

## Quick start

```bash
# 1. Launch the base stack (FHIR server + PostgreSQL)
docker compose -f docker-compose.yml up -d

# 2. Wait until the server is ready
curl -sf http://localhost:3500/fhir/r4/metadata > /dev/null && echo "ready"

# 3. Run the CRUD demo
bash examples/01-crud/run.sh

# 4. When done
docker compose -f docker-compose.yml down
```

Most features work on the base `docker-compose.yml`. Features that need extra
services (Keycloak, RabbitMQ, Grafana) or an opt-in config overlay ship a
dedicated compose file — named in each row below.

---

## Core FHIR API

| Feature | What it does | Launch | Example | Guide |
|---------|--------------|--------|---------|-------|
| **CRUD, History & Versioning** | create/read/update/delete, `vread`, `_history`, ETags, optimistic locking, referential-integrity deletes, tombstones | `docker compose -f docker-compose.yml up -d` | [`examples/01-crud/run.sh`](examples/01-crud/run.sh) | [docs/crud.md](docs/crud.md) |
| **Bundles** | transaction (with rollback), batch (partial success), document, message, searchset, collection | `docker compose -f docker-compose.yml up -d` | [`examples/03-bundles/run.sh`](examples/03-bundles/run.sh) | [docs/bundles.md](docs/bundles.md) |
| **Conditional Operations & PATCH** | If-None-Exist upsert, If-Match / If-None-Match concurrency, JSON Patch + FHIRPath Patch, conditional PUT/DELETE | `docker compose -f docker-compose.yml up -d` | [`examples/04-conditional-patch/run.sh`](examples/04-conditional-patch/run.sh) | [docs/conditional-patch.md](docs/conditional-patch.md) |
| **FHIR Documents** | `Composition/$document` generation (with `persist=true`) and document-Bundle self-containment validation | `docker compose -f docker-compose.yml up -d` | [`examples/15-documents/run.sh`](examples/15-documents/run.sh) | [docs/documents.md](docs/documents.md) |
| **Binary Resource** | raw upload/download, dual JSON/bytes wire behavior, `_format` override, `X-Security-Context` | `docker compose -f docker-compose.yml up -d` | [`examples/16-binary/run.sh`](examples/16-binary/run.sh) | [docs/binary.md](docs/binary.md) |
| **Validation, Profiles & IGs** | `$validate` against US Core 5.0.1 and IPS 1.1.0; cardinality, invariants, terminology-binding enforcement | `docker compose -f docker-compose.validation-ig.yml up -d` | [`examples/05-validation-ig/run.sh`](examples/05-validation-ig/run.sh) | [docs/validation-ig.md](docs/validation-ig.md) |

## Search

| Feature | What it does | Launch | Example | Guide |
|---------|--------------|--------|---------|-------|
| **Search (all parameters & modifiers)** | string/token/date/reference/quantity/number/uri/composite; `:exact`/`:contains`/`:not`/`:above`/`:below`; `_include`/`_revinclude`/`_has`/chained; `_sort`/`_count`/`_summary`/`_elements` | `docker compose -f docker-compose.yml up -d` | [`examples/02-search/run.sh`](examples/02-search/run.sh) | [docs/search.md](docs/search.md) |
| **Storage Backends & Full-Text Search** | PostgreSQL/MongoDB/SQLite/MySQL/SQL Server backends; `_text`/`_content` (Bleve), `$reindex`, optional Elasticsearch | `docker compose -f docker-compose.mongodb.yml up -d` | [`examples/28-storage-backends/run.sh`](examples/28-storage-backends/run.sh) | [docs/storage-backends.md](docs/storage-backends.md) |

## Terminology

| Feature | What it does | Launch | Example | Guide |
|---------|--------------|--------|---------|-------|
| **Terminology Service** | `$expand`, `$lookup`, `$validate-code`, `$subsumes`, `$translate`, `$closure`; embedded R4 packages out of the box; SNOMED/LOINC/ICD/FONASA opt-in | `docker compose -f docker-compose.terminology.yml up -d` | [`examples/06-terminology/run.sh`](examples/06-terminology/run.sh) | [docs/terminology.md](docs/terminology.md) |

## Security & Auth

| Feature | What it does | Launch | Example | Guide |
|---------|--------------|--------|---------|-------|
| **SMART on FHIR** | embedded OAuth2 server: discovery/JWKS, `client_credentials`, `authorization_code`+PKCE, refresh, granular scopes, patient launch context, Backend Services `private_key_jwt` | `docker compose -f docker-compose.smart-auth.yml up -d` | [`examples/09-smart-auth/run.sh`](examples/09-smart-auth/run.sh) | [docs/smart-auth.md](docs/smart-auth.md) |
| **Federated Auth (external OIDC)** | broker login to Keycloak/Okta/Azure AD, validate upstream `id_token`, resolve `fhirUser` via `(issuer,subject)` binding, issue own SMART tokens | `docker compose -f docker-compose.federated.yml up -d` | [`examples/10-federated-auth/run.sh`](examples/10-federated-auth/run.sh) | [docs/federated-auth.md](docs/federated-auth.md) |
| **Security (labels, BTG, consent, audit)** | `meta.security` labels, `_security` search, field redaction, Consent evaluation, Break-the-Glass, Provenance + AuditEvent trail | `docker compose -f docker-compose.security.yml up -d` | [`examples/25-security/run.sh`](examples/25-security/run.sh) | [docs/security.md](docs/security.md) |

## Multi-Tenancy

| Feature | What it does | Launch | Example | Guide |
|---------|--------------|--------|---------|-------|
| **Multi-Tenancy** | strict `X-Tenant-ID` header (or signed JWT claim) isolation; read/search/delete/history isolation; same-id coexistence across tenants | `docker compose -f docker-compose.multitenancy.yml up -d` | [`examples/11-multi-tenancy/run.sh`](examples/11-multi-tenancy/run.sh) | [docs/multi-tenancy.md](docs/multi-tenancy.md) |

## Async & Eventing

| Feature | What it does | Launch | Example | Guide |
|---------|--------------|--------|---------|-------|
| **Subscriptions** | R4 criteria + R5 Backport topic subscriptions; rest-hook/websocket/email channels; NATS/RabbitMQ/Kafka brokers; `canFilterBy`, `$status` | `docker compose -f docker-compose.subscriptions.yml up -d` | [`examples/12-subscriptions/run.sh`](examples/12-subscriptions/run.sh) | [docs/subscriptions.md](docs/subscriptions.md) |
| **Bulk Data Access** ⚠️ | `$export` (system/patient/group, kick-off/poll/NDJSON/cancel), `_type`/`_since`; experimental opt-in `$import` (disabled by default) | `docker compose -f docker-compose.bulk-data.yml up -d` | [`examples/13-bulk-data/run.sh`](examples/13-bulk-data/run.sh) | [docs/bulk-data.md](docs/bulk-data.md) |
| **Messaging** | `$process-message` envelope/profile/MessageDefinition validation, reference persist processor, async delivery (202 + Content-Location) | `docker compose -f docker-compose.messaging.yml up -d` | [`examples/14-messaging/run.sh`](examples/14-messaging/run.sh) | [docs/messaging.md](docs/messaging.md) |

## Data Management

| Feature | What it does | Launch | Example | Guide |
|---------|--------------|--------|---------|-------|
| **Master Data Management (MDM)** | golden-record auto-linking; `$mdm-*` steward ops (query/create/update/history, bulk-import, calibrate, not-duplicate, merge, clear); FS+LSH+EM | `docker compose -f docker-compose.mdm.yml up -d` | [`examples/19-mdm/run.sh`](examples/19-mdm/run.sh) | [docs/mdm.md](docs/mdm.md) |
| **FHIR-as-Code / GitOps** | reconcile declarative ValueSet/CodeSystem/SearchParameter/profile files from a mounted repo; per-source tagging, anti-clobber, prune safety | `docker compose -f docker-compose.gitops.yml up -d` | [`examples/20-fhir-as-code/run.sh`](examples/20-fhir-as-code/run.sh) | [docs/fhir-as-code.md](docs/fhir-as-code.md) |
| **Sync Protocol** | edge↔cloud replication: change feed `GET /_changes`, pull/push PUT-by-id, tombstones, conflict strategies, `POST /$sync` | `docker compose -f docker-compose.sync.yml up -d` | [`examples/21-sync-protocol/run.sh`](examples/21-sync-protocol/run.sh) | [docs/sync-protocol.md](docs/sync-protocol.md) |
| **Edge Server Mode** | full FHIR API on embedded SQLite with zero external services; on-device/offline/air-gapped; optional upstream sync | `docker compose -f docker-compose.edge.yml up -d` | [`examples/22-edge-mode/run.sh`](examples/22-edge-mode/run.sh) | [docs/edge-mode.md](docs/edge-mode.md) |

## Interop & Formats

| Feature | What it does | Launch | Example | Guide |
|---------|--------------|--------|---------|-------|
| **GraphQL API** | dynamically-generated FHIR GraphQL: queries, mutations, inline reference resolution, cursor paging, history, instance `$graphql`, Playground UI | `docker compose -f docker-compose.graphql.yml up -d` | [`examples/17-graphql/run.sh`](examples/17-graphql/run.sh) | [docs/graphql.md](docs/graphql.md) |
| **XML Format & Narrative** | `application/fhir+xml` content negotiation, `?_format=xml`, XML POST, opt-in automatic XHTML narrative generation | `docker compose -f docker-compose.xml-narrative.yml up -d` | [`examples/18-xml-narrative/run.sh`](examples/18-xml-narrative/run.sh) | [docs/xml-narrative.md](docs/xml-narrative.md) |
| **StructureMap `$transform` (FML)** | native FHIR Mapping Language engine; instance/type-level `$transform` from a stored StructureMap | `docker compose -f docker-compose.yml up -d` | [`examples/24-transform-fml/run.sh`](examples/24-transform-fml/run.sh) | [docs/transform-fml.md](docs/transform-fml.md) |
| **HL7 v2 Integration** | always-on `$parse-v2` converting raw HL7v2 → JSON FHIR logical-model instances; chain into FML `$transform` | `docker compose -f docker-compose.yml up -d` | [`examples/29-hl7v2/run.sh`](examples/29-hl7v2/run.sh) | [docs/hl7v2.md](docs/hl7v2.md) |
| **SQL on FHIR v2** | ViewDefinition `$viewdefinition-validate` / `-run` / `-export`; flatten FHIR to JSON/CSV/NDJSON with `forEach` unnesting | `docker compose -f docker-compose.sqlfhir.yml up -d` | [`examples/30-sql-on-fhir/run.sh`](examples/30-sql-on-fhir/run.sh) | [docs/sql-on-fhir.md](docs/sql-on-fhir.md) |
| **Custom Operations** ⚠️ | extension-point pattern via the shipped `$example-echo` reference operation (OperationDefinition + CapabilityStatement + HTTP handler) | `docker compose -f docker-compose.custom-operations.yml up -d` | [`examples/08-custom-operations/run.sh`](examples/08-custom-operations/run.sh) | [docs/custom-operations.md](docs/custom-operations.md) |

## Clinical Reasoning

| Feature | What it does | Launch | Example | Guide |
|---------|--------------|--------|---------|-------|
| **Clinical Reasoning** | CQL engine, `$evaluate-measure` + MeasureReport, `Library/$evaluate`, CRMI lifecycle (`$draft`…`$package`), `$data-requirements`, `$care-gaps`, CDS Hooks 2.0 | `docker compose -f docker-compose.clinical-reasoning.yml up -d` | [`examples/23-clinical-reasoning/run.sh`](examples/23-clinical-reasoning/run.sh) | [docs/clinical-reasoning.md](docs/clinical-reasoning.md) |

## Operations & Ops

| Feature | What it does | Launch | Example | Guide |
|---------|--------------|--------|---------|-------|
| **FHIR Operations** | `$validate`, `Patient/$everything`, `$meta`/`$meta-add`/`$meta-delete`, `$convert`, `$versions`/`$lastn`/`$stats`, `_summary`/`_elements`/`_pretty` | `docker compose -f docker-compose.terminology.yml up -d` | [`examples/07-operations/run.sh`](examples/07-operations/run.sh) | [docs/operations.md](docs/operations.md) |
| **Admin API & Web UI** | OAuth client CRUD, IG/package management, audit query/export (JSON/NDJSON/CSV), config read, storage stats, RBAC on `:3501` | `docker compose -f docker-compose.admin.yml up -d` | [`examples/26-admin-api/run.sh`](examples/26-admin-api/run.sh) | [docs/admin-api.md](docs/admin-api.md) |
| **Observability** | OpenTelemetry traces→Tempo, metrics→Prometheus, logs→Loki, all in Grafana | `docker compose -f docker-compose.observability.yml up -d` | [`examples/27-observability/run.sh`](examples/27-observability/run.sh) | [docs/observability.md](docs/observability.md) |

---

⚠️ = **experimental / opt-in** — disabled by default; see the feature guide for how to enable it.

## See also

- [`README.md`](README.md) — feature matrix, deployment profiles, and environment-variable reference.
- [`examples/`](examples/) — every runnable demo, one directory per feature (each with its own `README.md`).
- [`docs/`](docs/) — the full guide for each feature.
