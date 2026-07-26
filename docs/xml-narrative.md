# XML Format & Narrative Generation

**What it is** — paito supports FHIR XML (`application/fhir+xml`) alongside JSON.
Resources are stored internally as JSON and converted to/from XML at the HTTP
transport boundary, so format is purely a wire concern. Content negotiation
follows the FHIR R4 spec: the `_format` query parameter wins, then the `Accept`
header (RFC 7231 quality values), defaulting to `application/fhir+json`.
Separately, automatic **narrative generation** (opt-in) injects a sanitized,
human-readable XHTML `Resource.text.div` into resources on create/update using
built-in Go templates.

**When to use it**

- Integrating with clients or trading partners that speak FHIR XML.
- Migrating XML documents/messages into a JSON-native store without a converter.
- Rendering resources for humans (portals, printouts) via the generated narrative.
- Serving both JSON and XML consumers from a single endpoint via content negotiation.
- Hardening narratives: the XHTML sanitizer strips scripts, event handlers, and
  dangerous CSS/URIs to prevent XSS.

**Launch**

```bash
# XML negotiation works on ANY paito stack (no config). To ALSO see automatic
# narrative generation, use the compose that sets NARRATIVE_ENABLED=true:
docker compose -f docker-compose.xml-narrative.yml up -d

# readiness check
curl -s http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
```

> XML support is enabled by default and needs no configuration. The base
> `docker-compose.yml` serves and accepts XML too — the dedicated compose only
> adds `NARRATIVE_ENABLED=true` so narratives are generated out of the box.

**Examples**

Request a resource as XML via the `Accept` header:

```bash
curl -s -H 'Accept: application/fhir+xml' \
  http://localhost:3500/fhir/r4/Patient/<id>
# → 200, Content-Type: application/fhir+xml
#   body: <?xml ...?><Patient xmlns="http://hl7.org/fhir">...</Patient>
```

Request XML via the `_format` query parameter (overrides Accept):

```bash
curl -s 'http://localhost:3500/fhir/r4/Patient/<id>?_format=xml'
# → 200, Content-Type: application/fhir+xml
```

POST a resource as XML — the server converts it to JSON for storage:

```bash
curl -s -X POST \
  -H 'Content-Type: application/fhir+xml' \
  -H 'Accept: application/fhir+xml' \
  --data @examples/18-xml-narrative/patient.xml \
  http://localhost:3500/fhir/r4/Patient
# → 201 Created; response echoes the resource as XML with a server-assigned <id>
```

The XML-created resource is searchable like any other (format-transparent store):

```bash
curl -s 'http://localhost:3500/fhir/r4/Patient?family=XML-Created'
# → 200 searchset Bundle with total >= 1
```

Create a resource and inspect the auto-generated narrative (requires
`NARRATIVE_ENABLED=true`):

```bash
curl -s -X POST \
  -H 'Content-Type: application/fhir+json' \
  --data @examples/18-xml-narrative/patient.json \
  http://localhost:3500/fhir/r4/Patient | \
  python3 -c 'import sys,json; print(json.load(sys.stdin)["text"]["div"][:200])'
# → <div xmlns="http://www.w3.org/1999/xhtml">...human-readable summary...</div>
```

If a resource already includes its own `text.div`, it is preserved and not
overwritten.

**Configuration**

| Env var | Config key | Default | Meaning |
|---|---|---|---|
| — (always on) | — | enabled | FHIR XML content negotiation (`application/fhir+xml`, `_format=xml`) |
| `NARRATIVE_ENABLED` | `narrative.enabled` | `false` | Auto-generate `text.div` on create/update (opt-in) |
| `NARRATIVE_TEMPLATE_DIR` | `narrative.templateDir` | `""` | Directory of custom `{ResourceType}.html` templates (overrides embedded) |
| — | `narrative.sanitize` | `true` | Enforce the XHTML allowlist / XSS sanitizer |
| — | `narrative.defaultStatus` | `generated` | Value written to `text.status` |

Notes:

- Supported wire types: `application/fhir+xml`, `application/xml`, `text/xml`,
  and `xml`/`json` shorthands for `_format`. Default output is `application/fhir+json`.
- If XML conversion fails, the server gracefully falls back to JSON with a
  `Warning: 199 - "XML conversion failed"` header.
- Built-in narrative templates ship for `Patient`, `Observation`, `Condition`,
  `MedicationRequest`, and `DiagnosticReport`. Other resource types return no
  narrative (resource operations never fail because of narrative generation).
- Narrative generation during search is off by default (performance); it applies
  to create/update.

**References**

- XML format: `site/content/en/docs/fhir-api/xml-format.md`
- Narrative module: `site/content/en/docs/modules/narrative/_index.md`
- Config reference: `configs/config.yaml` (`narrative:` block)
- FHIR R4 §2.21.0.6 (content negotiation), §6.1.1 (narrative)
