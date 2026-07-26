#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# paito FHIR Server — FHIR Operations demo
#
# Derived from the proven e2e smoke tests in go-fhir-server:
#   scripts/e2e-ops-smoke.sh        ($validate, $everything, XML, output shaping)
#   scripts/e2e-ops-sweep-smoke.sh  ($versions, $lastn, $stats, $convert, $meta*)
#   scripts/e2e-operation-smoke.sh  (operation framework / CapabilityStatement)
#
# All calls run against the FHIR R4 endpoint. Start a stack first (see README),
# then:  bash run.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

B="\033[1m"; G="\033[32m"; R="\033[31m"; C="\033[36m"; N="\033[0m"
header() { printf "\n${B}${C}=== %s ===${N}\n" "$1"; }
ok()     { printf "${G}OK${N}  %s\n" "$1"; }
info()   { printf "${B}--> %s${N}\n" "$1"; }

# curl helper: METHOD URL [BODY-FILE] [CONTENT-TYPE]. Sets RESP_STATUS + RESP_BODY.
req() {
  local method=$1 url=$2 file=${3:-} ctype=${4:-application/fhir+json}
  local args=(-s -X "$method" -o /tmp/paito-op.out -w '%{http_code}')
  [[ -n "$file" ]] && args+=(-H "Content-Type: $ctype" --data-binary "@$file")
  RESP_STATUS=$(curl "${args[@]}" "$url")
  RESP_BODY=$(cat /tmp/paito-op.out)
}

# ─────────────────────────────────────────────────────────────────────────────
header "0. Readiness — CapabilityStatement advertises operations"
info "GET \$BASE_URL/metadata (count advertised operations)"
curl -fsS "$BASE_URL/metadata" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);\
sysops={o['name'] for r in d.get('rest',[]) for o in r.get('operation',[])};\
resops={o['name'] for r in d.get('rest',[]) for res in r.get('resource',[]) for o in res.get('operation',[])};\
print('system operations:', sorted(sysops));\
print('resource operations:', sorted(resops))"
ok "server reachable and advertising operations"

# ─────────────────────────────────────────────────────────────────────────────
header "1. \$validate — resource validation (no data required)"

info "1a. Validate a minimal-but-valid Patient -> 200, 0 errors"
req POST "$BASE_URL/Patient/\$validate" "$DIR/patient-valid.json"
echo "  HTTP $RESP_STATUS"
echo "$RESP_BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);\
print('  errors:', sum(1 for i in d.get('issue',[]) if i.get('severity')=='error'))"
[[ "$RESP_STATUS" == "200" ]] && ok "valid Patient accepted"

info "1b. Validate a Patient with a bad gender enum -> 200 + OperationOutcome error"
req POST "$BASE_URL/Patient/\$validate" "$DIR/patient-bad-enum.json"
echo "  HTTP $RESP_STATUS"
echo "$RESP_BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);\
print('  errors:', sum(1 for i in d.get('issue',[]) if i.get('severity')=='error'))"
echo "$RESP_BODY" | grep -q 'administrative-gender' && ok "diagnostics cite the administrative-gender ValueSet"

info "1c. Validate with missing resourceType -> 400"
RESP_STATUS=$(curl -s -o /tmp/paito-op.out -w '%{http_code}' -X POST \
  -H 'Content-Type: application/fhir+json' --data-binary '{"gender":"male"}' \
  "$BASE_URL/Patient/\$validate")
echo "  HTTP $RESP_STATUS (expected 400)"
[[ "$RESP_STATUS" == "400" ]] && ok "missing resourceType rejected"

# ─────────────────────────────────────────────────────────────────────────────
header "2. \$everything — Patient compartment retrieval"

info "2a. Seed: 1 Patient + 2 Observations + 1 Condition"
req POST "$BASE_URL/Patient" "$DIR/patient.json"
PID=$(echo "$RESP_BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
ok "Patient/$PID created (HTTP $RESP_STATUS)"

for code in 8867-4 29463-7; do
  curl -s -o /dev/null -X POST "$BASE_URL/Observation" \
    -H 'Content-Type: application/fhir+json' --data-binary "{
      \"resourceType\":\"Observation\",\"status\":\"final\",
      \"code\":{\"coding\":[{\"system\":\"http://loinc.org\",\"code\":\"$code\"}]},
      \"subject\":{\"reference\":\"Patient/$PID\"},
      \"effectiveDateTime\":\"2026-05-01T10:00:00Z\",
      \"valueQuantity\":{\"value\":72,\"unit\":\"bpm\",\"system\":\"http://unitsofmeasure.org\",\"code\":\"/min\"}
    }"
done
curl -s -o /dev/null -X POST "$BASE_URL/Condition" \
  -H 'Content-Type: application/fhir+json' --data-binary "{
    \"resourceType\":\"Condition\",
    \"subject\":{\"reference\":\"Patient/$PID\"},
    \"code\":{\"coding\":[{\"system\":\"http://snomed.info/sct\",\"code\":\"73211009\",\"display\":\"Diabetes\"}]}
  }"
ok "seeded 2 Observations + 1 Condition"

info "2b. GET /Patient/$PID/\$everything -> searchset Bundle (Patient + related)"
req GET "$BASE_URL/Patient/$PID/\$everything"
echo "  HTTP $RESP_STATUS"
echo "$RESP_BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);\
print('  Bundle.type:', d.get('type'), ' total:', d.get('total'));\
print('  resource types:', sorted({e['resource']['resourceType'] for e in d.get('entry',[])}))"
ok "\$everything returned the compartment"

info "2c. \$everything on an unknown Patient id -> 404"
RESP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
  "$BASE_URL/Patient/00000000-0000-0000-0000-000000000000/\$everything")
echo "  HTTP $RESP_STATUS (expected 404)"

# ─────────────────────────────────────────────────────────────────────────────
header "3. \$meta / \$meta-add / \$meta-delete (instance-level)"

info "3a. GET /Patient/$PID/\$meta -> Parameters with valueMeta (versionId, lastUpdated)"
req GET "$BASE_URL/Patient/$PID/\$meta"
echo "  HTTP $RESP_STATUS"
echo "$RESP_BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);\
m=next((p.get('valueMeta') for p in d.get('parameter',[]) if p.get('name')=='return'),{});\
print('  versionId:', m.get('versionId'), ' lastUpdated:', m.get('lastUpdated'))" 2>/dev/null || echo "  $RESP_BODY"

info "3b. POST /Patient/$PID/\$meta-add -> add a tag to the resource meta"
req POST "$BASE_URL/Patient/$PID/\$meta-add" "$DIR/meta-add.json"
echo "  HTTP $RESP_STATUS"
echo "$RESP_BODY" | grep -q 'reviewed' && ok "tag 'reviewed' added to meta"

info "3c. POST /Patient/$PID/\$meta-delete -> remove that tag again"
req POST "$BASE_URL/Patient/$PID/\$meta-delete" "$DIR/meta-delete.json"
echo "  HTTP $RESP_STATUS"
ok "\$meta-delete applied"

# ─────────────────────────────────────────────────────────────────────────────
header "4. \$convert — serialization conversion (system-level, JSON -> XML)"

info "4. POST /\$convert with Accept: application/fhir+xml -> FHIR-XML"
RESP_STATUS=$(curl -s -o /tmp/paito-op.xml -w '%{http_code}' -X POST "$BASE_URL/\$convert" \
  -H 'Content-Type: application/fhir+json' -H 'Accept: application/fhir+xml' \
  --data-binary "@$DIR/convert-input.json")
echo "  HTTP $RESP_STATUS"
head -c 60 /tmp/paito-op.xml; echo
head -c 20 /tmp/paito-op.xml | grep -q '<?xml' && ok "response serialized as FHIR-XML"

# ─────────────────────────────────────────────────────────────────────────────
header "5. Output shaping — _pretty / _summary / _elements"

info "5a. _pretty=true -> indented multi-line JSON"
req GET "$BASE_URL/Patient/$PID?_pretty=true"
LINES=$(echo "$RESP_BODY" | wc -l | tr -d ' ')
echo "  HTTP $RESP_STATUS, $LINES lines"
(( LINES > 3 )) && ok "response is pretty-printed"

info "5b. _summary=count -> Bundle carries total, zero entries"
req GET "$BASE_URL/Patient?_summary=count"
echo "  HTTP $RESP_STATUS"
echo "$RESP_BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);\
print('  total:', d.get('total'), ' entries:', len(d.get('entry',[])))"
ok "_summary=count returns metadata only"

info "5c. _elements=id,name -> sparse resource + SUBSETTED tag"
req GET "$BASE_URL/Patient/$PID?_elements=id,name"
echo "  HTTP $RESP_STATUS"
echo "$RESP_BODY" | grep -q 'SUBSETTED' && ok "response flagged SUBSETTED"
echo "$RESP_BODY" | grep -q '"birthDate"' \
  && echo "  (birthDate present)" \
  || ok "birthDate correctly filtered out (not requested)"

# ─────────────────────────────────────────────────────────────────────────────
header "6. System / type-level discovery operations"

info "6a. GET /\$versions -> Parameters reporting supported FHIR versions"
req GET "$BASE_URL/\$versions"
echo "  HTTP $RESP_STATUS"
echo "$RESP_BODY" | grep -q '4.0.1' && ok "reports FHIR 4.0.1"

info "6b. GET /Observation/\$lastn -> most recent Observation per code"
req GET "$BASE_URL/Observation/\$lastn?subject=Patient/$PID&code=http://loinc.org|8867-4"
echo "  HTTP $RESP_STATUS"
echo "$RESP_BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);\
print('  Bundle total:', d.get('total'))" 2>/dev/null || true

info "6c. GET /Observation/\$stats -> ObservationStatistics (avg/min/max/count)"
req GET "$BASE_URL/Observation/\$stats?subject=Patient/$PID&code=http://loinc.org|8867-4&statistic=avg,min,max,count"
echo "  HTTP $RESP_STATUS"
echo "$RESP_BODY" | grep -q 'observation-statistics' && ok "spec-shaped statistics returned"

header "Done"
echo "Demonstrated: \$validate, \$everything, \$meta/\$meta-add/\$meta-delete,"
echo "              \$convert, output shaping (_pretty/_summary/_elements),"
echo "              \$versions, \$lastn, \$stats."
