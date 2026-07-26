#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# Conditional Operations & PATCH — runnable examples
#
# Derived from go-fhir-server/scripts/e2e-advanced-smoke.sh (sections A, B, C).
# Demonstrates: conditional create (If-None-Exist), conditional update/delete,
# ETag concurrency (If-Match / If-None-Match), JSON Patch and FHIRPath Patch.
#
# Launch the server first (from repo root):
#   docker compose up -d
#   curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
#
# Then:  bash run.sh
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON="application/fhir+json"

# Unique identifier per run so the script is re-runnable without collisions.
MRN="MRN-$(date +%s)-$RANDOM"
SYS="http://hospital.example/mrn"

pass() { printf "  \033[32m✔\033[0m %s\n" "$1"; }
info() { printf "\n\033[1;36m═══ %s\033[0m\n" "$1"; }

# http METHOD URL [BODY] [CONTENT_TYPE] [EXTRA_HEADER...]
# Sets STATUS, BODY, ETAG globals.
http() {
  local method=$1 url=$2 body=${3:-} ctype=${4:-$JSON}; shift $(( $# < 4 ? $# : 4 ))
  local hdrs=/tmp/paito-cp-h; : >"$hdrs"; : >/tmp/paito-cp-b
  local args=(-s -X "$method" -o /tmp/paito-cp-b -D "$hdrs" -w '%{http_code}')
  [[ -n "$body" ]] && args+=(-H "Content-Type: $ctype" --data-binary "$body")
  local h; for h in "$@"; do args+=(-H "$h"); done
  STATUS=$(curl "${args[@]}" "$url")
  BODY=$(cat /tmp/paito-cp-b)
  ETAG=$(awk 'tolower($1)=="etag:"{sub(/\r$/,"",$2);print $2;exit}' "$hdrs")
}

id_of() { echo "$1" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4; }

info "Pre-flight: server reachable"
curl -fsS --max-time 5 "$BASE_URL/metadata" >/dev/null
pass "$BASE_URL is up"

# ── A. CONDITIONAL OPERATIONS ────────────────────────────────────────────────
info "A. Conditional create — first POST with If-None-Exist ⇒ 201 Created"
http POST "$BASE_URL/Patient" "$(sed "s#MRN-COND-001#$MRN#" "$DIR/patient.json")" \
  "$JSON" "If-None-Exist: identifier=$SYS|$MRN"
[[ "$STATUS" == 201 ]] && pass "created (201)" || { echo "expected 201 got $STATUS: $BODY"; exit 1; }
PID=$(id_of "$BODY")
pass "Patient id=$PID"

info "A. Conditional create — same If-None-Exist again ⇒ 200 OK, same id (idempotent)"
http POST "$BASE_URL/Patient" "$(sed "s#MRN-COND-001#$MRN#" "$DIR/patient.json")" \
  "$JSON" "If-None-Exist: identifier=$SYS|$MRN"
[[ "$STATUS" == 200 ]] && pass "no duplicate (200)" || { echo "expected 200 got $STATUS"; exit 1; }
[[ "$(id_of "$BODY")" == "$PID" ]] && pass "same id returned: $PID" || { echo "id changed"; exit 1; }

info "A. Conditional update — 0 matches ⇒ 201 (upsert-create a new MRN)"
MRN2="$MRN-B"
http PUT "$BASE_URL/Patient?identifier=$SYS|$MRN2" \
  "{\"resourceType\":\"Patient\",\"identifier\":[{\"system\":\"$SYS\",\"value\":\"$MRN2\"}],\"name\":[{\"family\":\"CondUpd-New\"}]}"
[[ "$STATUS" == 201 ]] && pass "conditional PUT created (201)" || { echo "expected 201 got $STATUS"; exit 1; }

info "A. Conditional update — 1 match ⇒ 200, version bumps to 2"
http PUT "$BASE_URL/Patient?identifier=$SYS|$MRN2" \
  "{\"resourceType\":\"Patient\",\"identifier\":[{\"system\":\"$SYS\",\"value\":\"$MRN2\"}],\"name\":[{\"family\":\"CondUpd-Modified\"}]}"
[[ "$STATUS" == 200 ]] && pass "conditional PUT updated (200)" || { echo "expected 200 got $STATUS"; exit 1; }
echo "$BODY" | grep -q '"versionId":"2"' && pass "versionId=2"
echo "$BODY" | grep -q '"family":"CondUpd-Modified"' && pass "family updated"

info "A. Conditional delete — DELETE /Patient?identifier=... ⇒ 204"
http DELETE "$BASE_URL/Patient?identifier=$SYS|$MRN2"
[[ "$STATUS" == 204 ]] && pass "conditional DELETE (204)" || { echo "expected 204 got $STATUS"; exit 1; }
http GET "$BASE_URL/Patient?identifier=$SYS|$MRN2"
echo "$BODY" | grep -q '"total":0' && pass "match removed (search total=0)"

# ── B. CONCURRENCY CONTROL (ETag + If-Match / If-None-Match) ─────────────────
info "B. Create a Patient to version (starts at versionId=1)"
http POST "$BASE_URL/Patient" '{"resourceType":"Patient","name":[{"family":"ETag-Test"}]}'
EPID=$(id_of "$BODY")
pass "Patient id=$EPID  ETag=$ETAG"

info "B. PUT with matching If-Match W/\"1\" ⇒ 200, version bumps to 2"
http PUT "$BASE_URL/Patient/$EPID" \
  "{\"resourceType\":\"Patient\",\"id\":\"$EPID\",\"name\":[{\"family\":\"ETag-Test-v2\"}]}" \
  "$JSON" 'If-Match: W/"1"'
[[ "$STATUS" == 200 ]] && pass "accepted (200)" || { echo "expected 200 got $STATUS"; exit 1; }
echo "$BODY" | grep -q '"versionId":"2"' && pass "versionId=2"

info "B. PUT with STALE If-Match W/\"1\" (current is v2) ⇒ 412 Precondition Failed"
http PUT "$BASE_URL/Patient/$EPID" \
  "{\"resourceType\":\"Patient\",\"id\":\"$EPID\",\"name\":[{\"family\":\"Stomp-Should-Fail\"}]}" \
  "$JSON" 'If-Match: W/"1"'
[[ "$STATUS" == 412 ]] && pass "rejected (412)" || { echo "expected 412 got $STATUS"; exit 1; }
echo "$BODY" | grep -q '"code":"conflict"' && pass "OperationOutcome.code=conflict"

info "B. GET with matching If-None-Match W/\"2\" ⇒ 304 Not Modified, empty body"
http GET "$BASE_URL/Patient/$EPID" "" "$JSON" 'If-None-Match: W/"2"'
[[ "$STATUS" == 304 ]] && pass "not modified (304)" || { echo "expected 304 got $STATUS"; exit 1; }
[[ -z "$BODY" ]] && pass "body is empty"

info "B. GET with non-matching If-None-Match W/\"999\" ⇒ 200 + full resource"
http GET "$BASE_URL/Patient/$EPID" "" "$JSON" 'If-None-Match: W/"999"'
[[ "$STATUS" == 200 ]] && pass "full body (200)"
echo "$BODY" | grep -q '"resourceType":"Patient"' && pass "resource returned"

# ── C. PARTIAL UPDATES (PATCH) ───────────────────────────────────────────────
info "C. Create a Patient to patch (gender=unknown, family=PatchMe)"
http POST "$BASE_URL/Patient" '{"resourceType":"Patient","name":[{"family":"PatchMe","given":["Original"]}],"gender":"unknown"}'
PPID=$(id_of "$BODY")
pass "Patient id=$PPID"

info "C. JSON Patch (RFC 6902) — replace /gender ⇒ female"
http PATCH "$BASE_URL/Patient/$PPID" "$(cat "$DIR/json-patch.json")" "application/json-patch+json"
[[ "$STATUS" == 200 ]] && pass "patched (200)" || { echo "expected 200 got $STATUS: $BODY"; exit 1; }
echo "$BODY" | grep -q '"versionId":"2"' && pass "versionId=2"
echo "$BODY" | grep -q '"gender":"female"' && pass "gender=female"

info "C. FHIRPath Patch (Parameters) — replace Patient.name[0].family"
http PATCH "$BASE_URL/Patient/$PPID" "$(cat "$DIR/fhirpath-patch.json")" "$JSON"
[[ "$STATUS" == 200 ]] && pass "patched (200)" || { echo "expected 200 got $STATUS: $BODY"; exit 1; }
echo "$BODY" | grep -q '"versionId":"3"' && pass "versionId=3"
echo "$BODY" | grep -q '"family":"FHIRPathPatched"' && pass "family=FHIRPathPatched"

info "C. History reflects all 3 versions (POST + 2 PATCH)"
http GET "$BASE_URL/Patient/$PPID/_history"
echo "$BODY" | grep -q '"total":3' && pass "_history total=3"

info "ALL EXAMPLES PASSED"
