# FHIR Documents (`$document`)

**What it is** — FHIR clinical documents are immutable `Bundle.type = document`
resources whose first entry is a `Composition` (the document's metadata and
section structure) followed by every resource the Composition references. The
Paito server both **generates** documents from a stored `Composition` via the
`Composition/$document` operation and **validates self-containment** of any
document Bundle a client submits, per the FHIR
[documents paradigm](https://hl7.org/fhir/R4/documents.html). No extra services
are required — this runs on the base Postgres + Paito stack.

**When to use it**

- Produce a signed, self-contained clinical document (discharge summary, consult
  note, care plan) from an existing `Composition` for exchange or archival.
- Snapshot a Composition and the resources it references into a single retrievable
  artifact with `persist=true`.
- Ingest and store externally-authored FHIR documents while enforcing that the
  package is self-contained (Composition first, references resolve, identifier +
  timestamp present).
- Discover stored documents with `GET /Bundle?type=document`.

**Launch**

```bash
# Base compose (Postgres + Paito) — no extra services needed for documents.
docker compose -f docker-compose.yml up -d

# Readiness check:
curl -s http://localhost:3500/fhir/r4/metadata | head -c 200
```

**Examples**

Generate a document from a stored `Composition` (the server pulls in the resources
it references, Composition first):

```bash
# GET (or POST) — instance-level operation on a Composition
curl -s "http://localhost:3500/fhir/r4/Composition/<comp-id>/\$document"
# → 200; Bundle.type=document, entry[0]=Composition, plus referenced Patient/Observation/…,
#   with a fresh Bundle.identifier and Bundle.timestamp injected.
```

Generate and persist the document, then retrieve it as a `Bundle`:

```bash
curl -s "http://localhost:3500/fhir/r4/Composition/<comp-id>/\$document?persist=true"
# → 200; response Bundle.id is the stored resource id. A persist failure surfaces
#   as an error (the operation never returns an unstored document).

curl -s "http://localhost:3500/fhir/r4/Bundle/<bundle-id>"
# → 200; the stored document, type=document.
```

Discover stored documents by type:

```bash
curl -s "http://localhost:3500/fhir/r4/Bundle?type=document"
# → 200; searchset Bundle of stored documents.
```

Store a valid client-authored document Bundle (self-contained) by POSTing to the base:

```bash
curl -s -X POST "http://localhost:3500/fhir/r4/" \
  -H "Content-Type: application/fhir+json" \
  --data-binary @examples/15-documents/bundle-document.json
# → 200; stored verbatim as an immutable Bundle resource (type=document).
```

Reject an invalid document (missing the required `Bundle.identifier`):

```bash
curl -s -X POST "http://localhost:3500/fhir/r4/" \
  -H "Content-Type: application/fhir+json" \
  --data-binary @examples/15-documents/bundle-document-invalid.json
# → 400; OperationOutcome citing constraint bdl-11.
```

Self-containment checks applied to a submitted `Bundle.type=document`:

| Check | Rule | On failure |
|-------|------|------------|
| First entry | SHALL be a `Composition` (bdl-11) | error |
| `Bundle.identifier` / `Bundle.timestamp` | required for a document | error |
| Composition fields | `status`, `date`, `type` required | error |
| `entry.request` | must not be present (documents aren't transactions) | error |
| `entry.fullUrl` | every entry SHALL have one | error |
| Duplicate `fullUrl` | fullUrls must be unique (bdl-7) | error |
| Reference resolution | the Composition's direct relative / `urn:uuid:` refs SHALL resolve to an entry `fullUrl`; `#fragment` refs to a contained resource | error if dangling |
| External reference | absolute `http(s)` refs, or relative refs carried by deeper (non-Composition) resources | allowed |

**Configuration** — Documents need no feature flags; they work on the default
stack. The relevant environment variables (see `internal/config/config_env.go`)
are the standard storage/FHIR settings from the base compose:

| Env var | Purpose | Value in base compose |
|---------|---------|-----------------------|
| `STORAGE_DRIVER` | Storage backend | `postgres` |
| `POSTGRES_HOST` / `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Postgres connection | `postgres` / `paito` / `paito` / `paito` |
| `FHIR_VERSION` | FHIR release | `R4` |
| `AUTH_ENABLED` | Auth toggle | `false` |

The `$document` operation is exposed only when the FHIR context provides the
`Composition` `$document` `OperationDefinition` (part of the base R4 definitions
Paito ships with), so it is available out of the box.

**References**

- go-fhir-server docs — Bundles, "Document Bundles" and "`Composition/$document`":
  `site/content/en/docs/fhir-api/bundles.md`
- go-fhir-server docs — Operations reference: `site/content/en/docs/fhir-api/operations-reference.md`
- FHIR R4 — Documents paradigm: https://hl7.org/fhir/R4/documents.html
- FHIR R4 — `Composition/$document`: https://hl7.org/fhir/R4/composition-operation-document.html
