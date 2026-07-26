# Binary Resource (raw upload / download)

**What it is** — The FHIR `Binary` resource holds arbitrary content (images, PDFs,
CDA documents, plain text) and has a dual wire behavior per
[binary.html](https://hl7.org/fhir/R4/binary.html): it can be exchanged either as
a normal FHIR resource (JSON/XML with base64 `data`) **or** as its raw content.
paito honors both. On write, a non-FHIR `Content-Type` means the request body IS
the raw content and the server wraps it into a `Binary` resource; on read, a
non-FHIR (or absent) `Accept` returns the raw decoded bytes with the stored
`contentType`. This is standard FHIR behavior — no opt-in flag required.

**When to use it**

- Store and serve binary attachments (PNG, JPEG, PDF, plain text, CDA) alongside FHIR data.
- Upload raw bytes directly (`--data-binary @file`) without hand-building a base64 resource.
- Download the original bytes back with the correct `Content-Type` for a viewer or download.
- Bind a binary to a clinical context via `securityContext` (e.g. `Patient/123`) for access control.
- Reference stored binaries from `DocumentReference.content.attachment.url` or `Media`.

**Launch**

The base compose already covers Binary (it is core CRUD — no special service or config):

```bash
docker compose -f docker-compose.yml up -d

# readiness check
curl -s http://localhost:3500/fhir/r4/metadata | head -c 200
```

**Examples**

Upload a raw text file — the server wraps it into a `Binary` (`contentType` = the
request `Content-Type`, `data` = base64 of the body). The `X-Security-Context`
header populates `Binary.securityContext.reference`:

```bash
curl -X POST "http://localhost:3500/fhir/r4/Binary" \
  -H "Content-Type: text/plain" \
  -H "X-Security-Context: Patient/example" \
  --data-binary @note.txt
# → 201 Created; body is the Binary resource with base64 data + securityContext
```

Download the raw bytes back (non-FHIR `Accept` → decoded content, not JSON):

```bash
curl "http://localhost:3500/fhir/r4/Binary/{id}" -H "Accept: text/plain"
# → 200; the original file bytes, Content-Disposition: attachment, nosniff
```

Read the same object as the FHIR resource (FHIR `Accept` → JSON):

```bash
curl "http://localhost:3500/fhir/r4/Binary/{id}" -H "Accept: application/fhir+json"
# → 200; {"resourceType":"Binary","contentType":"text/plain","data":"...","securityContext":{...}}
```

`_format` overrides `Accept` — force raw even with a FHIR `Accept`:

```bash
curl "http://localhost:3500/fhir/r4/Binary/{id}?_format=text/plain" \
  -H "Accept: application/fhir+json"
# → 200; raw bytes (the _format wins)
```

Update-as-raw with a URL id (`PUT`, non-FHIR `Content-Type`):

```bash
curl -X PUT "http://localhost:3500/fhir/r4/Binary/my-doc" \
  -H "Content-Type: application/pdf" \
  --data-binary @report.pdf
# → 200/201; wrapped into a Binary whose id is "my-doc"
```

Post a native FHIR `Binary` resource (FHIR `Content-Type` → stored as-is, no wrap):

```bash
curl -X POST "http://localhost:3500/fhir/r4/Binary" \
  -H "Content-Type: application/fhir+json" \
  --data-binary @binary-fhir.json
# → 201; contentType/data/securityContext taken verbatim from the body
```

**Configuration**

Binary works out of the box. These optional env vars tune the attachment-security
layer that also guards raw Binary uploads (names from `internal/config/config_env.go`):

| Env var | Config key | Purpose | Default |
|---------|-----------|---------|---------|
| `ATTACHMENT_SECURITY_ENABLED` | `attachmentSecurity.enabled` | Enable attachment/Binary security checks | enabled |
| `ATTACHMENT_SECURITY_MAX_BINARY_BYTES` | `attachmentSecurity.sizeLimits.maxBinaryBytes` | Max raw Binary body; exceeding → `413` | 50 MB |
| `ATTACHMENT_SECURITY_MAX_INLINE_BYTES` | `attachmentSecurity.sizeLimits.maxInlineBytes` | Max inline base64 attachment size | — |
| `ATTACHMENT_SECURITY_EXECUTABLE_DETECTION` | `attachmentSecurity.executableDetection` | Reject executable content | — |
| `ATTACHMENT_SECURITY_BASE64_VALIDATION` | `attachmentSecurity.base64Validation` | Validate base64 `data` | — |
| `ATTACHMENT_SECURITY_MIME_MODE` | `attachmentSecurity.mimeTypes.mode` | MIME allow/deny mode | — |

Notes on the wire contract:

- The raw create/update path is triggered by any non-FHIR request `Content-Type`; a
  FHIR media type (`application/fhir+json` / `+xml`) is treated as a Binary resource body.
- The `X-Security-Context` request header sets `Binary.securityContext.reference` on the raw path.
- Raw downloads always send `Content-Disposition: attachment` plus the global
  `X-Content-Type-Options: nosniff` and a restrictive `Content-Security-Policy`, so
  active content (HTML/SVG/JS) is never rendered inline. Authorization runs
  identically to a normal read — there is no raw-path bypass.

**References**

- go-fhir-server site docs: `site/content/en/docs/fhir-api/crud.md` — "Binary Resources (native/raw handling)"
- go-fhir-server site docs: `site/content/en/docs/fhir-api/_index.md` — Content Types
- go-fhir-server site docs: `site/content/en/docs/security/attachment-security.md`
- FHIR R4: [Binary](https://hl7.org/fhir/R4/binary.html), [HTTP API](https://hl7.org/fhir/R4/http.html)
