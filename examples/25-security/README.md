# 25 — Security (labels, Break-the-Glass, consent, redaction, provenance, audit)

This example walks the full data-protection surface of paito-fhir-server: it applies
`meta.security` confidentiality labels, searches them with the `_security` parameter,
shows server-enforced field redaction (identifier removed + `SUBSETTED` tag), verifies
automatic FHIR `Provenance` generation on write, reads the audit trail back as queryable
`AuditEvent` resources, sends a Break-the-Glass justification via the `X-BTG-Reason`
header, and creates a deny-overrides `Consent` resource. The stack runs with auth OFF so
every call is plain `curl`; label/consent/BTG *enforcement* reads the caller clearance,
patient context and purpose-of-use from a SMART token, so this script demonstrates the
security data model rather than request-blocking (see `docs/security.md` for the
enforcement path under `docker-compose.auth.yml`).

## How to run

```bash
# From the repo root
docker compose -f docker-compose.security.yml up -d

# Wait until the CapabilityStatement responds
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

bash examples/25-security/run.sh
```

Tear down with `docker compose -f docker-compose.security.yml down -v`.
