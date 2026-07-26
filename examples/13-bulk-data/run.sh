#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# paito FHIR Server — Bulk Data Access ($export) demo
#
# Derived from the proven go-fhir-server e2e smoke test:
#   scripts/e2e-ops-sweep-smoke.sh  (Step 18.10 — Bulk Data $export header rules)
# plus the documented three-step kick-off / poll / download workflow from the
# FHIR Bulk Data Access IG (site docs: fhir-api/bulk-data.md).
#
# Runs against the FHIR R4 endpoint. Start the bulk-data stack first (see
# README), then:  bash run.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

B="\033[1m"; G="\033[32m"; R="\033[31m"; C="\033[36m"; N="\033[0m"
header() { printf "\n${B}${C}=== %s ===${N}\n" "$1"; }
ok()     { printf "${G}OK${N}  %s\n" "$1"; }
fail()   { printf "${R}FAIL${N} %s\n" "$1"; exit 1; }
info()   { printf "${B}--> %s${N}\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
header "0. Readiness — CapabilityStatement"
info "GET \$BASE_URL/metadata"
curl -fsS "$BASE_URL/metadata" >/dev/null && ok "server is up at $BASE_URL"

# ─────────────────────────────────────────────────────────────────────────────
header "1. Seed data — POST 2 Patients + 1 Observation"
PID1=$(curl -fsS -X POST -H "Content-Type: application/fhir+json" \
  --data-binary "@$DIR/patient.json" "$BASE_URL/Patient" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
ok "created Patient/$PID1"

PID2=$(curl -fsS -X POST -H "Content-Type: application/fhir+json" \
  --data-binary "@$DIR/patient.json" "$BASE_URL/Patient" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
ok "created Patient/$PID2"

# Bind the sample Observation to the first patient before posting.
sed "s/PATIENT_ID/$PID1/" "$DIR/observation.json" > "$WORK/obs.json"
OID=$(curl -fsS -X POST -H "Content-Type: application/fhir+json" \
  --data-binary "@$WORK/obs.json" "$BASE_URL/Observation" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
ok "created Observation/$OID (subject Patient/$PID1)"

# ─────────────────────────────────────────────────────────────────────────────
header "2. Header validation (Bulk Data IG §2 — proven in e2e-ops-sweep 18.10)"

info "GET \$export WITHOUT Accept  → expect 400 (Accept required)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -H 'Prefer: respond-async' "$BASE_URL/\$export")
[[ "$CODE" == "400" ]] && ok "missing Accept → 400" || fail "missing Accept got $CODE (want 400)"

info "GET \$export with Accept: text/html  → expect 406 (Not Acceptable)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -H 'Prefer: respond-async' -H 'Accept: text/html' "$BASE_URL/\$export")
[[ "$CODE" == "406" ]] && ok "non-FHIR Accept → 406" || fail "bad Accept got $CODE (want 406)"

# ─────────────────────────────────────────────────────────────────────────────
# Helper: kick off an export, poll to completion, return the manifest JSON path.
# Usage: run_export <url>  → sets MANIFEST (path to json) and STATUS_URL
run_export() {
  local url=$1
  # Kick-off — 202 Accepted + Content-Location header with the polling URL.
  local hdrs; hdrs=$(curl -s -D - -o /dev/null \
    -H 'Accept: application/fhir+json' -H 'Prefer: respond-async' "$url")
  local code; code=$(printf '%s' "$hdrs" | head -1 | awk '{print $2}')
  [[ "$code" == "202" ]] || fail "kick-off got $code (want 202) for $url"
  local loc; loc=$(printf '%s' "$hdrs" | grep -i '^content-location:' | tr -d '\r' | awk '{print $2}')
  [[ -n "$loc" ]] || fail "no Content-Location header on kick-off"
  # Rebuild the polling URL against BASE_URL so it works regardless of the
  # advertised host (extract the job id after _bulkstatus/).
  local jobid; jobid=${loc##*_bulkstatus/}
  STATUS_URL="$BASE_URL/_bulkstatus/$jobid"
  ok "kick-off accepted → job $jobid"

  # Poll: 202 (in progress) → 200 (complete). Bounded retry.
  local i
  for i in $(seq 1 30); do
    curl -s -o "$WORK/manifest.json" -w '%{http_code}' "$STATUS_URL" > "$WORK/poll.code"
    code=$(cat "$WORK/poll.code")
    if [[ "$code" == "200" ]]; then
      MANIFEST="$WORK/manifest.json"
      ok "export complete (poll #$i → 200)"
      return 0
    fi
    [[ "$code" == "202" ]] || fail "poll got $code (want 202/200)"
    sleep 1
  done
  fail "export did not complete within 30 polls"
}

# ─────────────────────────────────────────────────────────────────────────────
header "3. System-level \$export (all resource types)"
info "GET \$export  (Prefer: respond-async, Accept: application/fhir+json)"
run_export "$BASE_URL/\$export"

info "Manifest output[] files:"
python3 -c "
import sys,json
m=json.load(open('$MANIFEST'))
print('  transactionTime:', m.get('transactionTime'))
print('  requiresAccessToken:', m.get('requiresAccessToken'))
for o in m.get('output',[]):
    print('  -', o['type'], o.get('count'), o['url'])
"

# Download the Patient NDJSON file referenced in the manifest.
PURL=$(python3 -c "
import sys,json
m=json.load(open('$MANIFEST'))
for o in m.get('output',[]):
    if o['type']=='Patient':
        print(o['url']); break
")
if [[ -n "${PURL:-}" ]]; then
  # Rebuild against BASE_URL (path after /_bulkdata/).
  DL="$BASE_URL/_bulkdata/${PURL##*/_bulkdata/}"
  info "GET $DL  → NDJSON (one Patient per line)"
  curl -fsS -H 'Accept: application/fhir+ndjson' "$DL" -o "$WORK/Patient.ndjson"
  LINES=$(wc -l < "$WORK/Patient.ndjson" | tr -d ' ')
  ok "downloaded Patient.ndjson ($LINES lines)"
  head -1 "$WORK/Patient.ndjson" | python3 -c "import sys,json;print('  first line resourceType:', json.load(sys.stdin)['resourceType'])"
else
  info "no Patient file in manifest (empty dataset?) — skipping download"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "4. Type-filtered \$export (_type=Patient,Observation)"
info "GET \$export?_type=Patient,Observation"
run_export "$BASE_URL/\$export?_type=Patient,Observation"
python3 -c "
import json
m=json.load(open('$MANIFEST'))
types=sorted({o['type'] for o in m.get('output',[])})
print('  exported types:', types)
"
ok "type-filtered export complete"

# ─────────────────────────────────────────────────────────────────────────────
header "5. Patient-level \$export (Patient compartment, all patients)"
info "GET Patient/\$export"
run_export "$BASE_URL/Patient/\$export"
ok "patient-compartment export complete"

# ─────────────────────────────────────────────────────────────────────────────
header "6. Single-patient instance \$export"
info "GET Patient/$PID1/\$export"
run_export "$BASE_URL/Patient/$PID1/\$export"
ok "single-patient export complete"

# ─────────────────────────────────────────────────────────────────────────────
header "7. Cancel a job — DELETE /_bulkstatus/{jobId}"
info "Kick off one more export, then cancel it"
HDRS=$(curl -s -D - -o /dev/null -H 'Accept: application/fhir+json' -H 'Prefer: respond-async' "$BASE_URL/\$export")
LOC=$(printf '%s' "$HDRS" | grep -i '^content-location:' | tr -d '\r' | awk '{print $2}')
JOBID=${LOC##*_bulkstatus/}
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/_bulkstatus/$JOBID")
[[ "$CODE" == "204" || "$CODE" == "202" ]] && ok "cancel returned $CODE for job $JOBID" || info "cancel returned $CODE (job may have already completed)"

# ─────────────────────────────────────────────────────────────────────────────
header "8. Cleanup — delete seeded resources"
curl -s -o /dev/null -X DELETE "$BASE_URL/Observation/$OID" && ok "deleted Observation/$OID"
curl -s -o /dev/null -X DELETE "$BASE_URL/Patient/$PID1" && ok "deleted Patient/$PID1"
curl -s -o /dev/null -X DELETE "$BASE_URL/Patient/$PID2" && ok "deleted Patient/$PID2"

# ─────────────────────────────────────────────────────────────────────────────
# EXPERIMENTAL $import (opt-in, off by default) — NOT run here.
# $import is a draft/unratified operation and disabled unless you mount
# config/bulk-data.yaml (import.enabled + allowedSources). See docs/bulk-data.md.
# Kick-off shape (rejected with 400/404 unless enabled + source allowlisted):
#
#   curl -X POST "$BASE_URL/\$import" \
#     -H "Content-Type: application/fhir+json" \
#     -H "Prefer: respond-async" \
#     --data-binary "@import-parameters.json"
# ─────────────────────────────────────────────────────────────────────────────

header "DONE — Bulk Data \$export workflow verified"
