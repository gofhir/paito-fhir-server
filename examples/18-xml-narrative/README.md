# 18 — XML Format & Automatic Narrative Generation

This example demonstrates paito's FHIR XML support and automatic narrative
generation. Resources are stored internally as JSON and transparently converted
to/from `application/fhir+xml` at the HTTP boundary: you can request XML via the
`Accept` header or the `?_format=xml` query parameter, and POST resources as XML.
With `NARRATIVE_ENABLED=true`, the server injects a human-readable XHTML
`text.div` (sanitized against XSS) into resources on create/update. The calls are
derived from the proven `e2e-ops-smoke.sh` Step 7 (content negotiation).

## How to run

```bash
# from the repo root — enables narrative generation (XML is always on)
docker compose -f docker-compose.xml-narrative.yml up -d

# wait until the server is ready
curl -s http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

bash examples/18-xml-narrative/run.sh
```

`BASE_URL` defaults to `http://localhost:3500/fhir/r4` and can be overridden.
