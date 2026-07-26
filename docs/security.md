# Security — Labels, Break-the-Glass, Consent, Redaction, Provenance & Audit

**What it is** — paito-fhir-server ships a layered data-protection stack that goes well
beyond authentication. Resources carry confidentiality **security labels** in
`meta.security`; a configurable ordinal hierarchy enforces **label-based access control**;
FHIR **Consent** resources are evaluated with a deny-overrides algorithm; **field
redaction** strips minimum-necessary fields server-side and tags the result `SUBSETTED`; a
**Break-the-Glass** protocol allows audited emergency overrides; every write can
auto-generate a FHIR **Provenance** resource; and every operation lands in an **audit
trail** exposed as queryable `AuditEvent` resources. Each module is opt-in, nil-safe (zero
overhead when off), and follows a zero-coupling design.

**When to use it**

- Protect sensitive records (mental health, HIV, substance abuse) with `meta.security`
  confidentiality labels and clearance-based filtering.
- Honor patient privacy preferences by evaluating `Consent` resources at read/search time.
- Enforce minimum-necessary disclosure by redacting fields (e.g., `identifier`) from
  responses regardless of what the client asked for.
- Allow clinicians emergency ("break-the-glass") access with a mandatory, audited reason.
- Produce an immutable, queryable `Provenance` + `AuditEvent` trail for HIPAA / compliance
  review.

**Launch**

```bash
docker compose -f docker-compose.security.yml up -d

# readiness
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

bash examples/25-security/run.sh
```

The compose mounts [`config/security.yaml`](../config/security.yaml) (via `CONFIG_PATH`),
which turns on all six modules. Auth is left OFF so examples are copy-pasteable. Because
label / consent / BTG enforcement reads the caller's **clearance**, **patient context**,
and **purpose-of-use** from a SMART access token, with auth off the caller is treated as
*unrestricted* — the modules index, tag and search data but do not block requests. To see
enforcement actually deny/mask requests, run the same config layered on SMART auth
(`docker-compose.auth.yml`) so tokens carry those claims.

**Examples**

Apply a confidentiality label on create:

```bash
curl -s -X POST http://localhost:3500/fhir/r4/Patient \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/25-security/patient-restricted.json
# → 201 Created; the Patient carries meta.security = v3-Confidentiality|R
```

Search by the `_security` token parameter (system|code, code-only, OR, and `:not`):

```bash
# system|code
curl -s 'http://localhost:3500/fhir/r4/Patient?_security=http://terminology.hl7.org/CodeSystem/v3-Confidentiality|R'
# code only (any system)
curl -s 'http://localhost:3500/fhir/r4/Patient?_security=R'
# OR (comma) — any of these labels
curl -s 'http://localhost:3500/fhir/r4/Observation?_security=http://terminology.hl7.org/CodeSystem/v3-Confidentiality|V,http://terminology.hl7.org/CodeSystem/v3-Confidentiality|R'
# exclusion
curl -s 'http://localhost:3500/fhir/r4/Observation?_security:not=http://terminology.hl7.org/CodeSystem/v3-Confidentiality|U'
# → Bundle whose entries match the requested confidentiality labels
```

Field redaction — the `identifier` is stripped and a `SUBSETTED` tag is added:

```bash
curl -s http://localhost:3500/fhir/r4/Patient/<id>
# → Patient WITHOUT identifier, WITH
#   meta.tag[] = { system: ".../v3-ObservationValue", code: "SUBSETTED" }
```

Provenance auto-generated on write (queryable via the FHIR API):

```bash
curl -s 'http://localhost:3500/fhir/r4/Provenance?target=Patient/<id>'
# → Bundle with a Provenance whose activity.coding.code = CREATE and
#   agent.who = Device/paito-fhir-server
```

Audit trail as FHIR `AuditEvent` (and the operational admin view):

```bash
curl -s 'http://localhost:3500/fhir/r4/AuditEvent?_count=5'
curl -s 'http://localhost:3501/api/audit/events?limit=5'
# → recent read/search/create/delete events with outcome, type and resourceType
```

Break-the-Glass emergency access with a justification header:

```bash
curl -s http://localhost:3500/fhir/r4/Patient/<id> \
  -H 'X-BTG-Reason: Patient unconscious in the ED; treating clinician needs history'
# → 200; the reason is captured in the audit trail. Under SMART auth, a token
#   whose purpose-of-use is "BTG" activates the override and (with
#   requireReason=true) this header becomes mandatory.
```

Consent — a deny-overrides provision blocking one practitioner's access to Observations:

```bash
curl -s -X POST http://localhost:3500/fhir/r4/Consent \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/25-security/consent-deny.json
# → 201; while active, Practitioner/456 requesting this patient's Observations
#   is denied; other actors follow consent.defaultPolicy (permit).
```

**Configuration**

All security modules are opt-in and configured in `config/security.yaml`. Simple toggles
also accept environment variables (map/list values — hierarchy, redaction rules, consent
provisions — must be set in the YAML file).

| Env var | Config key | Default | Description |
|---------|-----------|---------|-------------|
| `SECURITY_LABELS_ENABLED` | `security.enabled` | `false` | Enable label-based access control |
| `SECURITY_LABELS_DEFAULT_CONFIDENTIALITY` | `security.defaultConfidentiality` | `N` | Level for resources without labels |
| `SECURITY_LABELS_DENIAL_STRATEGY` | `security.denialStrategy` | `mask` | `mask` (404/empty) or `deny` (403) |
| _(file only)_ | `security.confidentialityHierarchy` | `U:0 L:1 M:2 N:3 R:4 V:5` | Code → ordinal map (higher = stricter) |
| `CONSENT_ENABLED` | `consent.enabled` | `false` | Enable Consent enforcement |
| `CONSENT_DEFAULT_POLICY` | `consent.defaultPolicy` | `permit` | `permit` (opt-out) or `deny` (opt-in) |
| `CONSENT_DENIAL_STRATEGY` | `consent.denialStrategy` | `mask` | `mask` or `deny` |
| `CONSENT_CACHE_TTL` | `consent.cacheTTL` | `5m` | Per-patient parsed-consent cache TTL |
| `BTG_ENABLED` | `breakTheGlass.enabled` | `false` | Enable Break-the-Glass evaluation |
| `BTG_REQUIRE_REASON` | `breakTheGlass.requireReason` | `false` | Require a non-empty `X-BTG-Reason` |
| _(file only)_ | `breakTheGlass.allowedPurposes` | `["BTG"]` | Purpose-of-use codes that activate BTG |
| `FIELD_REDACTION_ENABLED` | `fieldRedaction.enabled` | `false` | Enable server-enforced field redaction |
| _(file only)_ | `fieldRedaction.rules` | — | Per-resource `redactFields` + `preserveForScopes` |
| `PROVENANCE_AUTO_GENERATE` | `provenance.autoGenerate` | `false` | Auto-create Provenance on C/U/D |
| `PROVENANCE_AGENT_TYPE` | `provenance.agentType` | `author` | provenance-participant-type code |
| `PROVENANCE_AGENT_WHO` | `provenance.agentWho` | `""` | Default agent reference (e.g. `Device/...`) |
| `AUDIT_ENABLED` | `audit.enabled` | `false` | Enable audit logging |
| `AUDIT_LEVEL` | `audit.level` | `all` | `all`, `write`, or `denied` |
| `AUDIT_CREATE_EVENTS` | `audit.createAuditEvents` | `false` | Materialize FHIR `AuditEvent` resources |

Confidentiality hierarchy (v3-Confidentiality): `U`(0) < `L`(1) < `M`(2) < `N`(3) <
`R`(4) < `V`(5). A caller's clearance must be **>=** a resource's level; unknown codes are
denied (fail-closed).

**References**

- Security Labels — `site/content/en/docs/security/security-labels.md`
- Label-Based Access Control — `site/content/en/docs/security/label-access-control.md`
- Break-the-Glass — `site/content/en/docs/security/break-the-glass.md`
- Consent Enforcement — `site/content/en/docs/security/consent-enforcement.md`
- Field Redaction — `site/content/en/docs/security/field-redaction.md`
- Provenance Auto-Generation — `site/content/en/docs/security/provenance.md`
- Audit Logging — `site/content/en/docs/security/audit-logging.md`
- FHIR R4: [Security Labels](https://hl7.org/fhir/R4/security-labels.html) ·
  [Consent](https://hl7.org/fhir/R4/consent.html) ·
  [Provenance](https://hl7.org/fhir/R4/provenance.html) ·
  [AuditEvent](https://hl7.org/fhir/R4/auditevent.html)
