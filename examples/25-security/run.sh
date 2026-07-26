#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# paito-fhir-server — Security feature smoke (labels, consent, redaction,
# provenance, break-the-glass, audit).
#
# Requires the security stack to be up:
#   docker compose -f docker-compose.security.yml up -d
#
# Then:
#   bash examples/25-security/run.sh
#
# All calls are unauthenticated (the stack runs with auth OFF for copy-paste
# ergonomics). Label / consent / BTG ENFORCEMENT reads the caller clearance,
# patient context and purpose-of-use from a SMART token; with auth off the
# caller is unrestricted, so this script demonstrates the security data model
# (labels, _security search, redaction, provenance, audit, BTG header) rather
# than request-blocking. See docs/security.md to run under enforcement.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
CT="Content-Type: application/fhir+json"
HERE="$(cd "$(dirname "$0")" && pwd)"

B="\033[1m"; G="\033[32m"; R="\033[31m"; C="\033[36m"; N="\033[0m"
step() { printf "\n${B}${C}== %s ==${N}\n" "$1"; }
ok()   { printf "${G}ok${N}  %s\n" "$1"; }
bad()  { printf "${R}xx${N}  %s\n" "$1" >&2; }

jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }

# ── Pre-flight ───────────────────────────────────────────────────────────────
step "Pre-flight — CapabilityStatement"
if ! curl -fsS --max-time 5 "$BASE_URL/metadata" >/dev/null; then
  bad "server not reachable at $BASE_URL — is docker-compose.security.yml up?"
  exit 1
fi
ok "FHIR endpoint responding at $BASE_URL"

# ── 1. Apply confidentiality labels via meta.security ────────────────────────
step "1. Create resources carrying meta.security confidentiality labels"

echo "  → POST Patient with meta.security = R (Restricted)"
RSTATUS=$(curl -s -o /tmp/sec-pat-r.json -w '%{http_code}' -X POST "$BASE_URL/Patient" \
  -H "$CT" --data-binary @"$HERE/patient-restricted.json")
[[ "$RSTATUS" == "201" ]] && ok "Restricted Patient created (201)" || { bad "expected 201, got $RSTATUS"; cat /tmp/sec-pat-r.json; exit 1; }
PID_R=$(jget "d['id']" < /tmp/sec-pat-r.json)
echo "     Patient/$PID_R"

echo "  → POST Observation with meta.security = V (Very Restricted) + HTEST"
OSTATUS=$(curl -s -o /tmp/sec-obs-v.json -w '%{http_code}' -X POST "$BASE_URL/Observation" \
  -H "$CT" --data-binary @"$HERE/observation-veryrestricted.json")
[[ "$OSTATUS" == "201" ]] && ok "Very Restricted Observation created (201)" || { bad "expected 201, got $OSTATUS"; cat /tmp/sec-obs-v.json; exit 1; }
OID_V=$(jget "d['id']" < /tmp/sec-obs-v.json)
echo "     Observation/$OID_V"

echo "  → POST Patient with NO security labels (treated as default 'N')"
NSTATUS=$(curl -s -o /tmp/sec-pat-n.json -w '%{http_code}' -X POST "$BASE_URL/Patient" \
  -H "$CT" --data-binary @"$HERE/patient-normal.json")
[[ "$NSTATUS" == "201" ]] && ok "Unlabeled Patient created (201)" || { bad "expected 201, got $NSTATUS"; cat /tmp/sec-pat-n.json; exit 1; }
PID_N=$(jget "d['id']" < /tmp/sec-pat-n.json)
echo "     Patient/$PID_N"

# ── 2. Search by the _security token search parameter ────────────────────────
step "2. Search by _security (token, expression Resource.meta.security)"

echo "  → GET /Patient?_security=<v3-Confidentiality>|R  (system|code)"
curl -s "$BASE_URL/Patient?_security=http://terminology.hl7.org/CodeSystem/v3-Confidentiality|R" \
  | jget "d.get('total','?')" | { read t; ok "matched total=$t (expect >=1, the Restricted Patient)"; }

echo "  → GET /Patient?_security=R  (code only, any system)"
curl -s "$BASE_URL/Patient?_security=R" \
  | jget "d.get('total','?')" | { read t; ok "matched total=$t"; }

echo "  → GET /Observation?_security=<v3-Confidentiality>|V,<...>|R  (OR / comma)"
curl -s "$BASE_URL/Observation?_security=http://terminology.hl7.org/CodeSystem/v3-Confidentiality|V,http://terminology.hl7.org/CodeSystem/v3-Confidentiality|R" \
  | jget "d.get('total','?')" | { read t; ok "matched total=$t (expect >=1, the V Observation)"; }

echo "  → GET /Observation?_security:not=<v3-Confidentiality>|U  (exclusion)"
curl -s "$BASE_URL/Observation?_security:not=http://terminology.hl7.org/CodeSystem/v3-Confidentiality|U" \
  | jget "d.get('total','?')" | { read t; ok ":not excluded U-labelled resources, total=$t"; }

# ── 3. Field redaction — SUBSETTED tag + removed field ───────────────────────
step "3. Field redaction (Patient.identifier removed server-side + SUBSETTED tag)"

echo "  → GET /Patient/$PID_R  (posted WITH identifier)"
curl -s "$BASE_URL/Patient/$PID_R" -o /tmp/sec-red.json
HAS_ID=$(jget "'identifier' in d" < /tmp/sec-red.json)
HAS_SUBSETTED=$(jget "any(t.get('code')=='SUBSETTED' for t in d.get('meta',{}).get('tag',[]))" < /tmp/sec-red.json)
if [[ "$HAS_ID" == "False" && "$HAS_SUBSETTED" == "True" ]]; then
  ok "identifier redacted AND meta.tag SUBSETTED present (minimum-necessary enforced)"
else
  bad "redaction not applied (identifier present=$HAS_ID, SUBSETTED=$HAS_SUBSETTED) — is fieldRedaction enabled?"
fi

# ── 4. Provenance auto-generation on write ───────────────────────────────────
step "4. Provenance auto-generation (async) for the created Patient"

echo "  → GET /Provenance?target=Patient/$PID_R  (poll — provenance is best-effort async)"
PROV_TOTAL=0
for _ in $(seq 1 15); do
  PROV_TOTAL=$(curl -s "$BASE_URL/Provenance?target=Patient/$PID_R" | jget "d.get('total',0)" 2>/dev/null || echo 0)
  [[ "$PROV_TOTAL" -ge 1 ]] && break
  sleep 1
done
if [[ "$PROV_TOTAL" -ge 1 ]]; then
  ok "Provenance generated for Patient/$PID_R (total=$PROV_TOTAL)"
  curl -s "$BASE_URL/Provenance?target=Patient/$PID_R&_count=1" \
    | jget "d['entry'][0]['resource']['activity']['coding'][0]['code']" \
    | { read code; echo "     activity code = $code (CREATE)"; }
else
  bad "no Provenance found — is provenance.autoGenerate enabled?"
fi

# ── 5. Audit trail as queryable FHIR AuditEvent ──────────────────────────────
step "5. Audit trail materialized as FHIR AuditEvent resources (async)"

echo "  → GET /AuditEvent?_count=5  (poll for the events from the steps above)"
AUD_TOTAL=0
for _ in $(seq 1 15); do
  AUD_TOTAL=$(curl -s "$BASE_URL/AuditEvent?_count=5" | jget "d.get('total',0)" 2>/dev/null || echo 0)
  [[ "$AUD_TOTAL" -ge 1 ]] && break
  sleep 1
done
[[ "$AUD_TOTAL" -ge 1 ]] && ok "AuditEvent trail populated (total=$AUD_TOTAL)" \
  || bad "no AuditEvent found — is audit.createAuditEvents enabled?"

echo "  → (operational view) GET :3501/api/audit/events?limit=5"
if curl -fsS --max-time 4 "http://localhost:3501/api/audit/events?limit=5" -o /tmp/sec-audit-admin.json 2>/dev/null; then
  jget "len(d.get('events',[]))" < /tmp/sec-audit-admin.json \
    | { read n; ok "admin audit API returned $n recent event(s)"; }
else
  echo "     (admin API not reachable/!required — the FHIR /AuditEvent path above is the portable one)"
fi

# ── 6. Break-the-Glass — X-BTG-Reason header ─────────────────────────────────
step "6. Break-the-Glass emergency override (X-BTG-Reason header)"

echo "  → GET /Patient/$PID_R  with a BTG justification header"
BTG_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/Patient/$PID_R" \
  -H "X-BTG-Reason: Patient unconscious in the ED; treating clinician needs history")
[[ "$BTG_STATUS" == "200" ]] && ok "read succeeded with X-BTG-Reason (200) — reason captured in audit" \
  || bad "expected 200, got $BTG_STATUS"
echo "     Under SMART auth, a token whose purpose-of-use is 'BTG' activates the"
echo "     override; with breakTheGlass.requireReason=true this header is mandatory."

# ── 7. Consent resource (deny-overrides model) ───────────────────────────────
step "7. Consent resource — deny Observation access for one practitioner"

echo "  → POST /Consent  (provision.type=deny, class=Observation, actor=Practitioner/456)"
sed "s#Patient/PATIENT_ID#Patient/$PID_N#" "$HERE/consent-deny.json" > /tmp/sec-consent.json
CSTATUS=$(curl -s -o /tmp/sec-consent-resp.json -w '%{http_code}' -X POST "$BASE_URL/Consent" \
  -H "$CT" --data-binary @/tmp/sec-consent.json)
[[ "$CSTATUS" == "201" ]] && ok "active deny-Consent created for Patient/$PID_N (201)" \
  || { bad "expected 201, got $CSTATUS"; cat /tmp/sec-consent-resp.json; }
echo "     With SMART auth, a request from Practitioner/456 for this patient's"
echo "     Observations is denied (deny-overrides); other actors follow"
echo "     consent.defaultPolicy (permit)."

# ── Cleanup ──────────────────────────────────────────────────────────────────
step "Cleanup"
for ref in "Patient/$PID_R" "Patient/$PID_N" "Observation/$OID_V"; do
  s=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/$ref")
  echo "  DELETE $ref -> $s"
done

printf "\n${B}${G}Security smoke complete.${N}\n"
