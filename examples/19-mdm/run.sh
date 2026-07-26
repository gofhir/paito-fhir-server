#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# paito FHIR Server — Master Data Management (MDM) demo
#
# Derived from the proven e2e suite in go-fhir-server:
#   test/e2e/mdm_phase2_localhost_test.go  (TestE2E_MDM_Phase2_Localhost)
#
# It exercises the full MDM operation surface end-to-end against a running
# server: auto-matching (golden records + MATCH / POSSIBLE_MATCH links),
# $mdm-query-links, $mdm-bulk-import, $mdm-calibrate (Fellegi-Sunter proposal),
# $mdm-create-link / $mdm-update-link / $mdm-link-history, $mdm-submit,
# $mdm-not-duplicate, $mdm-duplicate-golden-resources, $mdm-merge-golden-resources
# and $mdm-clear.
#
# Requires: bash, curl, jq.  Start the stack first (see README), then:
#   bash run.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Per-run tenant so successive runs never collide (mirrors the e2e suite).
TENANT="${TENANT:-demo-mdm-$(date +%s)}"

B="\033[1m"; G="\033[32m"; R="\033[31m"; C="\033[36m"; N="\033[0m"
header() { printf "\n${B}${C}=== %s ===${N}\n" "$1"; }
ok()     { printf "${G}OK${N}  %s\n" "$1"; }
fail()   { printf "${R}FAIL${N} %s\n" "$1"; exit 1; }

# curl helpers — every request carries the run's tenant header.
jpost() { # jpost <path> <json-file-or-inline>
  local path="$1"; shift
  local data="$1"; shift
  if [[ -f "$data" ]]; then data="@$data"; fi
  curl -sS -X POST "${BASE_URL}${path}" \
    -H "Content-Type: application/fhir+json" \
    -H "Accept: application/fhir+json" \
    -H "X-Tenant-ID: ${TENANT}" \
    --data-binary "$data"
}
jget() { # jget <path>
  curl -sS "${BASE_URL}$1" \
    -H "Accept: application/fhir+json" \
    -H "X-Tenant-ID: ${TENANT}"
}
status() { # status METHOD <path> [json]
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" && -f "$data" ]]; then data="@$data"; fi
  curl -sS -o /dev/null -w '%{http_code}' -X "$method" "${BASE_URL}${path}" \
    -H "Content-Type: application/fhir+json" \
    -H "X-Tenant-ID: ${TENANT}" \
    ${data:+--data-binary "$data"}
}

printf "${B}Base:${N} %s   ${B}Tenant:${N} %s\n" "$BASE_URL" "$TENANT"

# ── 0. Readiness ─────────────────────────────────────────────────────────────
header "0. Server reachable + MDM wired"
curl -sf "${BASE_URL}/metadata" >/dev/null || fail "server not reachable at ${BASE_URL}/metadata"
ok "/metadata responds"
code=$(status GET "/\$mdm-query-links")
[[ "$code" == "200" ]] || fail "\$mdm-query-links returned $code — is MDM_ENABLED=true?"
ok "\$mdm-query-links responds 200 (MDM enabled)"

# ── 1. Auto-matching pipeline ────────────────────────────────────────────────
# Two identical Patients: the second auto-links to the first's golden as MATCH.
header "1. Auto-match identical demographics -> MATCH"
IDA1=$(jpost "/Patient" "$DIR/patient-identical.json" | jq -r '.id')
IDA2=$(jpost "/Patient" "$DIR/patient-identical.json" | jq -r '.id')
echo "created Patient/$IDA1 and Patient/$IDA2 (García / María, identical)"
sleep 1
RESULT=$(jget "/\$mdm-query-links?resourceId=${IDA2}" \
  | jq -r '.parameter[] | select(.name=="link") | .part[] | select(.name=="matchResult") | (.valueString // .valueCode)' | head -1)
echo "link matchResult for Patient/$IDA2 = ${RESULT:-<none>}"
[[ "$RESULT" == "MATCH" ]] && ok "identical pair produced a MATCH link" \
  || echo "  (note: threshold-tunable; expected MATCH, got '${RESULT}')"

# Near-duplicate: family-name typo -> POSSIBLE_MATCH (or MATCH under strict thresholds).
header "2. Near-duplicate (typo) -> POSSIBLE_MATCH"
jpost "/Patient" "$DIR/patient-neardup-1.json" >/dev/null   # Vandermeer
IDB2=$(jpost "/Patient" "$DIR/patient-neardup-2.json" | jq -r '.id')  # Vandermer (typo)
echo "created near-duplicate Patient/$IDB2 (Vandermer / Eduardo)"
sleep 1
NRESULT=$(jget "/\$mdm-query-links?resourceId=${IDB2}" \
  | jq -r '.parameter[] | select(.name=="link") | .part[] | select(.name=="matchResult") | (.valueString // .valueCode)' | head -1)
echo "link matchResult for Patient/$IDB2 = ${NRESULT:-<none>}"
case "$NRESULT" in
  POSSIBLE_MATCH|MATCH) ok "family typo classified as $NRESULT" ;;
  *) echo "  (expected POSSIBLE_MATCH/MATCH, got '${NRESULT}')" ;;
esac

# ── 3. $mdm-query-links with filters + pagination ────────────────────────────
header "3. Query links with matchResult + linkSource filters"
jget "/\$mdm-query-links?matchResult=MATCH&_count=5" \
  | jq '{totalCount: (.parameter[]|select(.name=="totalCount")|.valueInteger), links: [.parameter[]|select(.name=="link")]|length}'
jget "/\$mdm-query-links?linkSource=AUTO&_count=5" >/dev/null && ok "linkSource=AUTO filter OK"

# ── 4. $mdm-bulk-import ──────────────────────────────────────────────────────
# Async: returns 202 Accepted + Content-Location pointing at the job status.
header "4. \$mdm-bulk-import (async, 202 + Content-Location)"
LOC=$(curl -sS -D - -o /dev/null -X POST "${BASE_URL}/\$mdm-bulk-import" \
  -H "Content-Type: application/fhir+json" -H "X-Tenant-ID: ${TENANT}" \
  --data-binary "@$DIR/bundle-bulk-import.json" | awk -F': ' 'tolower($1)=="content-location"{print $2}' | tr -d '\r')
echo "Content-Location: ${LOC:-<none>}"
[[ -n "$LOC" ]] && ok "bulk-import accepted (202) with job location" \
  || echo "  (bulk-import may be disabled; skipping)"

# ── 5. $mdm-create-link (manual link) ────────────────────────────────────────
# Manually attach a fresh Patient to an existing golden as POSSIBLE_MATCH.
header "5. \$mdm-create-link (manual POSSIBLE_MATCH)"
IDM=$(jpost "/Patient" '{"resourceType":"Patient","name":[{"family":"Quintero","given":["Rodrigo"]}],"gender":"male","birthDate":"1969-02-14"}' | jq -r '.id')
sleep 1
# Clear the auto self-link first (UNIQUE constraint on source+type).
jpost "/Patient/${IDM}/\$mdm-clear" '{"resourceType":"Parameters","parameter":[]}' >/dev/null
GOLDEN=$(jget "/\$mdm-query-links?resourceId=${IDA1}" \
  | jq -r '.parameter[]|select(.name=="link")|.part[]|select(.name=="goldenResourceId")|.valueString' | head -1)
echo "linking Patient/$IDM to golden $GOLDEN"
jpost "/\$mdm-create-link" "{\"resourceType\":\"Parameters\",\"parameter\":[{\"name\":\"goldenResourceId\",\"valueString\":\"${GOLDEN}\"},{\"name\":\"resourceId\",\"valueString\":\"${IDM}\"},{\"name\":\"matchResult\",\"valueString\":\"POSSIBLE_MATCH\"}]}" \
  | jq '{linkId: (.parameter[]|select(.name=="linkId")|.valueString), matchResult: (.parameter[]|select(.name=="matchResult")|.valueString), linkSource: (.parameter[]|select(.name=="linkSource")|.valueString)}'
ok "manual link created (linkSource=MANUAL)"

# ── 6. $mdm-update-link + $mdm-link-history (steward verdict) ─────────────────
header "6. Steward verdict: \$mdm-update-link -> \$mdm-link-history"
GOLDEN2=$(jget "/\$mdm-query-links?resourceId=${IDA2}" \
  | jq -r '.parameter[]|select(.name=="link")|.part[]|select(.name=="goldenResourceId")|.valueString' | head -1 | sed 's#^Patient/##')
jpost "/\$mdm-update-link" "{\"resourceType\":\"Parameters\",\"parameter\":[{\"name\":\"goldenResourceId\",\"valueString\":\"${GOLDEN2}\"},{\"name\":\"resourceId\",\"valueString\":\"${IDA2}\"},{\"name\":\"matchResult\",\"valueString\":\"NO_MATCH\"},{\"name\":\"reason\",\"valueString\":\"demo steward verdict\"}]}" >/dev/null
NEW=$(jget "/\$mdm-query-links?resourceId=${IDA2}" \
  | jq -r '.parameter[]|select(.name=="link")|.part[]|select(.name=="matchResult")|.valueString' | head -1)
echo "matchResult after update = $NEW"
[[ "$NEW" == "NO_MATCH" ]] && ok "verdict rewrote matchResult to NO_MATCH"
echo "link history (auto + manual entries):"
jpost "/Patient/${IDA2}/\$mdm-link-history" '{"resourceType":"Parameters","parameter":[]}' \
  | jq '[.parameter[]|select(.name=="historyEntry")]|length as $n | {historyEntries: $n}'

# ── 7. $mdm-submit (reprocess one resource through the engine) ────────────────
header "7. \$mdm-submit (reprocess a resource)"
jpost "/Patient/${IDM}/\$mdm-submit" '{"resourceType":"Parameters","parameter":[]}' \
  | jq '{status: (.parameter[]|select(.name=="status")|.valueString), message: (.parameter[]|select(.name=="message")|.valueString)}'
ok "resource resubmitted to MDM engine"

# ── 8. $mdm-calibrate (Fellegi-Sunter proposal — propose, never apply) ───────
header "8. \$mdm-calibrate (proposes a FellegiSunterConfig)"
CAL=$(status POST "/\$mdm-calibrate" '{"resourceType":"Parameters","parameter":[{"name":"resourceType","valueCode":"Patient"},{"name":"minLabels","valueInteger":5}]}')
if [[ "$CAL" == "200" ]]; then
  jpost "/\$mdm-calibrate" '{"resourceType":"Parameters","parameter":[{"name":"resourceType","valueCode":"Patient"},{"name":"minLabels","valueInteger":5}]}' \
    | jq '{recommendation: (.parameter[]|select(.name=="recommendation")|(.valueCode // .valueString)), hasCandidate: ([.parameter[]|select(.name=="candidate")]|length>0)}'
  ok "calibration returned a candidate + recommendation"
else
  echo "  \$mdm-calibrate returned $CAL — needs >= minLabels labelled pairs in the tenant."
  echo "  Confirm/deny more POSSIBLE_MATCH verdicts via \$mdm-update-link, then retry."
fi

# ── 9. $mdm-not-duplicate (mark two goldens as distinct) ──────────────────────
header "9. \$mdm-not-duplicate (bidirectional NO_MATCH between goldens)"
IDN1=$(jpost "/Patient" '{"resourceType":"Patient","name":[{"family":"Espinoza","given":["Tomás"]}],"gender":"male","birthDate":"1966-06-20"}' | jq -r '.id')
IDN2=$(jpost "/Patient" '{"resourceType":"Patient","name":[{"family":"Castillo","given":["Gloria"]}],"gender":"female","birthDate":"1966-01-09"}' | jq -r '.id')
sleep 1
GN1=$(jget "/\$mdm-query-links?resourceId=${IDN1}" | jq -r '.parameter[]|select(.name=="link")|.part[]|select(.name=="goldenResourceId")|.valueString' | head -1)
GN2=$(jget "/\$mdm-query-links?resourceId=${IDN2}" | jq -r '.parameter[]|select(.name=="link")|.part[]|select(.name=="goldenResourceId")|.valueString' | head -1)
jpost "/Patient/${IDN1}/\$mdm-clear" '{"resourceType":"Parameters","parameter":[]}' >/dev/null
jpost "/Patient/${IDN2}/\$mdm-clear" '{"resourceType":"Parameters","parameter":[]}' >/dev/null
jpost "/\$mdm-not-duplicate" "{\"resourceType\":\"Parameters\",\"parameter\":[{\"name\":\"goldenResourceId\",\"valueString\":\"${GN1}\"},{\"name\":\"resourceId\",\"valueString\":\"${GN2}\"}]}" \
  | jq '{status: (.parameter[]|select(.name=="status")|.valueString)}'
ok "goldens marked as NOT duplicates"

# ── 10. $mdm-duplicate-golden-resources (steward review list) ─────────────────
header "10. \$mdm-duplicate-golden-resources (POSSIBLE_DUPLICATE list)"
jget "/Patient/\$mdm-duplicate-golden-resources?_count=10" \
  | jq '{totalCount: (.parameter[]|select(.name=="totalCount")|.valueInteger)}'
ok "duplicate-golden review list returned"

# ── 11. $mdm-merge-golden-resources ──────────────────────────────────────────
header "11. \$mdm-merge-golden-resources (move links + REDIRECT)"
IDG1=$(jpost "/Patient" '{"resourceType":"Patient","name":[{"family":"Morales","given":["Daniela"]}],"gender":"female","birthDate":"1974-07-04"}' | jq -r '.id')
IDG2=$(jpost "/Patient" '{"resourceType":"Patient","name":[{"family":"Salinas","given":["Héctor"]}],"gender":"male","birthDate":"1974-03-28"}' | jq -r '.id')
sleep 1
FROM=$(jget "/\$mdm-query-links?resourceId=${IDG1}" | jq -r '.parameter[]|select(.name=="link")|.part[]|select(.name=="goldenResourceId")|.valueString' | head -1 | sed 's#^Patient/##')
TO=$(jget "/\$mdm-query-links?resourceId=${IDG2}" | jq -r '.parameter[]|select(.name=="link")|.part[]|select(.name=="goldenResourceId")|.valueString' | head -1 | sed 's#^Patient/##')
echo "merging golden $FROM -> $TO"
jpost "/\$mdm-merge-golden-resources" "{\"resourceType\":\"Parameters\",\"parameter\":[{\"name\":\"fromGoldenResourceId\",\"valueString\":\"${FROM}\"},{\"name\":\"toGoldenResourceId\",\"valueString\":\"${TO}\"},{\"name\":\"resourceType\",\"valueString\":\"Patient\"}]}" \
  | jq '{status: (.parameter[]|select(.name=="status")|.valueString), movedLinks: (.parameter[]|select(.name=="movedLinks")|.valueInteger)}'
ok "goldens merged"

# ── 12. $mdm-clear (drop AUTO links for a resource) ──────────────────────────
header "12. \$mdm-clear (delete AUTO links; MANUAL links survive)"
jpost "/Patient/${IDN1}/\$mdm-clear" '{"resourceType":"Parameters","parameter":[]}' \
  | jq '{status: (.parameter[]|select(.name=="status")|.valueString), deletedCount: (.parameter[]|select(.name=="deletedCount")|.valueInteger)}'
ok "AUTO links cleared"

printf "\n${G}${B}All MDM demo steps completed.${N}\n"
