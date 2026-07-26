#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Clinical Reasoning demo — CQL, Quality Measures, CRMI lifecycle, CDS Hooks
#
# Requires the clinical-reasoning stack:
#   docker compose -f docker-compose.clinical-reasoning.yml up -d
#
# FHIR REST is served under /fhir/r4 (:3500). CDS Hooks 2.0 lives at the server
# ROOT (/cds-services), not under the FHIR base path.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
# CDS Hooks routes are mounted at the server root, so derive it from BASE_URL.
SERVER_URL="${SERVER_URL:-${BASE_URL%/fhir/r4}}"
CT="Content-Type: application/fhir+json"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

hr()  { printf '\n\033[1;36m== %s\033[0m\n' "$1"; }
note(){ printf '   \033[0;90m%s\033[0m\n' "$1"; }

# Best-effort call: prints status, never aborts the script (for CQL-dependent
# operations that need library content / subject data to return a full result).
soft() {
  local method="$1" url="$2" body="${3:-}"
  local code
  if [[ -n "$body" ]]; then
    code=$(curl -s -o /tmp/cr_resp.json -w '%{http_code}' -X "$method" -H "$CT" "$url" -d "$body")
  else
    code=$(curl -s -o /tmp/cr_resp.json -w '%{http_code}' -X "$method" "$url")
  fi
  note "HTTP $code"
  head -c 600 /tmp/cr_resp.json; echo
}

# ─────────────────────────────────────────────────────────────────────────────
hr "0. Readiness — CapabilityStatement lists the clinical-reasoning operations"
curl -s "$BASE_URL/metadata" -o /tmp/cr_meta.json -w '   HTTP %{http_code}\n'
grep -o '"code":"[a-z-]*"' /tmp/cr_meta.json | sort -u | \
  grep -E 'evaluate-measure|data-requirements|care-gaps|draft|approve|release|package|clone' || \
  note "(operations present but not listed by this grep — continuing)"

# ─────────────────────────────────────────────────────────────────────────────
hr "1. Seed a Patient, an active CQL Library and a proportion Measure"
curl -s -o /dev/null -w '   Patient  -> HTTP %{http_code}\n' \
  -X PUT -H "$CT" "$BASE_URL/Patient/cql-demo-patient" --data @"$DIR/patient.json"
curl -s -o /dev/null -w '   Library  -> HTTP %{http_code}\n' \
  -X PUT -H "$CT" "$BASE_URL/Library/example-cql" --data @"$DIR/library-cql.json"
curl -s -o /dev/null -w '   Measure  -> HTTP %{http_code}\n' \
  -X PUT -H "$CT" "$BASE_URL/Measure/example-proportion" --data @"$DIR/measure.json"

# ─────────────────────────────────────────────────────────────────────────────
hr "2. CRMI \$draft — fork the active Library into a new draft (version bumped)"
note "POST Library/example-cql/\$draft  (always available — storage only)"
DRAFT=$(curl -s -X POST "$BASE_URL/Library/example-cql/\$draft")
DRAFT_ID=$(printf '%s' "$DRAFT" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || echo "")
echo "$DRAFT" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("   id=%s version=%s status=%s"%(d.get("id"),d.get("version"),d.get("status")))' 2>/dev/null || echo "$DRAFT"

if [[ -n "$DRAFT_ID" ]]; then
  hr "3. CRMI \$approve — stamp an approval date + comment on the draft"
  soft POST "$BASE_URL/Library/$DRAFT_ID/\$approve" \
    '{"resourceType":"Parameters","parameter":[{"name":"approvalDate","valueDate":"2026-01-15"},{"name":"comment","valueString":"Approved by Clinical Quality Committee"}]}'

  hr "4. CRMI \$release — transition the draft to active"
  soft POST "$BASE_URL/Library/$DRAFT_ID/\$release"
else
  note "draft id not captured — skipping approve/release"
fi

# ─────────────────────────────────────────────────────────────────────────────
hr "5. CRMI \$package — bundle the Measure with its depends-on Library"
note "GET Measure/example-proportion/\$package  -> Bundle(collection)"
curl -s "$BASE_URL/Measure/example-proportion/\$package" -o /tmp/cr_pkg.json -w '   HTTP %{http_code}\n'
python3 -c 'import json;d=json.load(open("/tmp/cr_pkg.json"));print("   Bundle type=%s entries=%d -> %s"%(d.get("type"),len(d.get("entry",[])),[e.get("resource",{}).get("resourceType") for e in d.get("entry",[])]))' 2>/dev/null || head -c 400 /tmp/cr_pkg.json

# ─────────────────────────────────────────────────────────────────────────────
hr "6. \$data-requirements — discover the data elements the Measure needs"
note "GET Measure/example-proportion/\$data-requirements  -> Library(module-definition)"
soft GET "$BASE_URL/Measure/example-proportion/\$data-requirements?periodStart=2026-01-01&periodEnd=2026-12-31"

# ─────────────────────────────────────────────────────────────────────────────
hr "7. Library/\$evaluate — run a CQL expression against a subject (needs CQL_ENABLED)"
note "POST Library/example-cql/\$evaluate  -> Parameters with expression results"
soft POST "$BASE_URL/Library/example-cql/\$evaluate" "$(cat "$DIR/library-evaluate-parameters.json")"

# ─────────────────────────────────────────────────────────────────────────────
hr "8. \$evaluate-measure — compute a MeasureReport for the period (needs CQL_ENABLED)"
note "GET Measure/example-proportion/\$evaluate-measure  -> MeasureReport(summary)"
soft GET "$BASE_URL/Measure/example-proportion/\$evaluate-measure?periodStart=2026-01-01&periodEnd=2026-12-31&reportType=summary"

# ─────────────────────────────────────────────────────────────────────────────
hr "9. CDS Hooks 2.0 discovery — GET /cds-services (server root, needs CDS_HOOKS_ENABLED)"
CDS_CODE=$(curl -s -o /tmp/cr_cds.json -w '%{http_code}' "$SERVER_URL/cds-services")
note "GET $SERVER_URL/cds-services -> HTTP $CDS_CODE"
if [[ "$CDS_CODE" == "200" ]]; then
  python3 -c 'import json;d=json.load(open("/tmp/cr_cds.json"));print("   registered services: %d"%len(d.get("services",[])))' 2>/dev/null || cat /tmp/cr_cds.json
  note "Services are auto-discovered from PlanDefinition resources; empty until you POST one."
else
  note "CDS Hooks not mounted — start the clinical-reasoning compose (CDS_HOOKS_ENABLED=true)."
fi

hr "Done."
note "CRMI lifecycle + \$package + \$data-requirements work on storage alone."
note "\$evaluate-measure / Library/\$evaluate return full results once CQL_ENABLED + data are present."
