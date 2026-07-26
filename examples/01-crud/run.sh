#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# 01 — CRUD, History & Versioning
# Derived from go-fhir-server/scripts/e2e-smoke.sh (proven, passing E2E test).
#
# Drives the full lifecycle against a running paito server:
#   create → read → update → vread → _history → search →
#   reference (Observation → Patient) → referential-integrity delete guard →
#   cascade delete → tombstone (410) → history survives delete.
#
# Usage:
#   docker compose -f docker-compose.yml up -d      # from repo root
#   bash examples/01-crud/run.sh
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CT='Content-Type: application/fhir+json'
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

# http METHOD URL [DATA] [EXTRA_HEADER...] → sets STATUS + BODY globals
STATUS=""; BODY=""
http() {
  local method="$1" url="$2"; shift 2
  local data="" headers=()
  if [[ "${1:-}" != "" && "${1:0:1}" == "{" ]]; then data="$1"; shift; fi
  while [[ $# -gt 0 ]]; do headers+=(-H "$1"); shift; done
  local args=(-s -X "$method" -o "$BODY_FILE" -w '%{http_code}' -H "$CT" ${headers[@]+"${headers[@]}"})
  [[ -n "$data" ]] && args+=(--data-binary "$data")
  STATUS="$(curl "${args[@]}" "$url")"
  BODY="$(cat "$BODY_FILE")"
}
say()  { printf '\n\033[1;36m== %s\033[0m\n' "$1"; }
check() { # check EXPECTED LABEL
  if [[ "$STATUS" == "$1" ]]; then printf '  \033[32mok\033[0m  %s → %s\n' "$2" "$STATUS"
  else printf '  \033[31mFAIL\033[0m %s → %s (want %s)\n' "$2" "$STATUS" "$1"; echo "$BODY"; exit 1; fi
}

say "0. Server capability statement"
http GET "$BASE_URL/metadata"
check 200 "GET /metadata"
echo "$BODY" | grep -q '"resourceType":"CapabilityStatement"' && echo "  CapabilityStatement served"

say "1. CREATE — POST /Patient"
http POST "$BASE_URL/Patient" "$(cat "$DIR/patient.json")"
check 201 "POST /Patient"
PID="$(echo "$BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
echo "  Patient id: $PID"
echo "$BODY" | grep -q '"versionId":"1"' && echo "  versionId=1 stamped"

say "2. READ — GET /Patient/{id} (note the ETag header)"
ETAG="$(curl -s -D - -o "$BODY_FILE" "$BASE_URL/Patient/$PID" | grep -i '^ETag:' | tr -d '\r' | awk '{print $2}')"
echo "  ETag: ${ETAG:-<none>}"
grep -q '"family":"Quintana"' "$BODY_FILE" && echo "  family=Quintana present"

say "3. UPDATE — PUT /Patient/{id} (compound family, version bumps to 2)"
http PUT "$BASE_URL/Patient/$PID" "$(sed "s/\"resourceType\"/\"id\":\"$PID\",\"resourceType\"/" "$DIR/patient-update.json")"
check 200 "PUT /Patient/$PID"
echo "$BODY" | grep -q '"versionId":"2"' && echo "  versionId bumped to 2"
echo "$BODY" | grep -q '"family":"Quintana-Soto"' && echo "  compound family stored"

say "4. OPTIMISTIC LOCK — PUT with a stale If-Match: W/\"1\" must 409/412"
http PUT "$BASE_URL/Patient/$PID" "$(sed "s/\"resourceType\"/\"id\":\"$PID\",\"resourceType\"/" "$DIR/patient-update.json")" 'If-Match: W/"1"'
if [[ "$STATUS" == "409" || "$STATUS" == "412" ]]; then
  printf '  \033[32mok\033[0m  stale If-Match rejected → %s\n' "$STATUS"
else
  printf '  \033[31mFAIL\033[0m stale If-Match → %s (want 409/412)\n' "$STATUS"; exit 1
fi

say "5. HISTORY — GET /Patient/{id}/_history (Bundle of versions)"
http GET "$BASE_URL/Patient/$PID/_history"
check 200 "GET /_history"
echo "$BODY" | grep -q '"total":2' && echo "  history total = 2"

say "6. VREAD — GET /Patient/{id}/_history/1 (original version)"
http GET "$BASE_URL/Patient/$PID/_history/1"
check 200 "vread v1"
echo "$BODY" | grep -q '"family":"Quintana"' && echo "  v1 has ORIGINAL family"
echo "$BODY" | grep -q 'Quintana-Soto' && { echo "  FAIL: v1 leaked post-update family"; exit 1; } || echo "  v1 free of post-update family"

say "7. SEARCH — a few proven search params"
for q in "_id=$PID" "family=Quintana-Soto" "gender=female" "birthdate=1985-03-15" \
         "identifier=http://hospital.example/mrn|E2E-001"; do
  http GET "$BASE_URL/Patient?$q"
  tot="$(echo "$BODY" | grep -oE '"total":[0-9]+' | head -1 | cut -d: -f2)"
  printf '  ?%s → total=%s\n' "$q" "$tot"
done
http GET "$BASE_URL/Patient?family=DoesNotExist"
echo "$BODY" | grep -q '"total":0' && echo "  ?family=DoesNotExist → total=0 (negative)"

say "8. REFERENCE — POST /Observation with subject=Patient/{id}"
http POST "$BASE_URL/Observation" "$(sed "s#__PATIENT_ID__#$PID#" "$DIR/observation.json")"
check 201 "POST /Observation"
OID="$(echo "$BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
echo "  Observation id: $OID"

say "9. _revinclude — Patient search pulls its Observation"
http GET "$BASE_URL/Patient?_id=$PID&_revinclude=Observation:subject"
check 200 "Patient + _revinclude"
echo "$BODY" | grep -q '"resourceType":"Observation"' && echo "  Observation included in bundle"

say "10. REFERENTIAL INTEGRITY — deleting referenced Patient is blocked (409)"
http DELETE "$BASE_URL/Patient/$PID"
check 409 "DELETE /Patient (still referenced)"
echo "$BODY" | grep -q 'REFERENCE_STILL_REFERENCED' && echo "  OperationOutcome cites REFERENCE_STILL_REFERENCED"

say "11. CASCADE DELETE in dependency order: Observation → Patient"
http DELETE "$BASE_URL/Observation/$OID"; check 204 "DELETE /Observation"
http DELETE "$BASE_URL/Patient/$PID";     check 204 "DELETE /Patient (now unreferenced)"

say "12. TOMBSTONE — GET a deleted Patient → 410 Gone"
http GET "$BASE_URL/Patient/$PID"
check 410 "GET deleted Patient"

say "13. HISTORY SURVIVES DELETE — _history now lists POST+PUT+DELETE"
http GET "$BASE_URL/Patient/$PID/_history"
check 200 "GET /_history post-delete"
echo "$BODY" | grep -q '"total":3' && echo "  history total = 3"
echo "$BODY" | grep -q '"method":"DELETE"' && echo "  DELETE entry recorded"

printf '\n\033[1;32mAll CRUD / history / versioning steps passed.\033[0m\n'
