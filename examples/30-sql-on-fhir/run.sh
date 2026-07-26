#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# paito FHIR Server — SQL on FHIR v2 (ViewDefinition) demo
#
# Derived from the go-fhir-server ground-truth request collection:
#   test/http/sqlfhir-viewdefinition.http
# and the site docs:  fhir-api/sql-on-fhir.md
#
# Exercises the three SQL-on-FHIR operations on the FHIR R4 endpoint:
#   $viewdefinition-validate  — validate a ViewDefinition without running it
#   $viewdefinition-run       — flatten resources to JSON / CSV / NDJSON rows
#   $viewdefinition-export    — async bulk export (202 + poll + download)
#
# Start the sqlfhir stack first (see README), then:  bash run.sh
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
header "1. Seed data — 2 Patients + 1 Observation"
PID1=$(curl -fsS -X POST -H "Content-Type: application/fhir+json" \
  --data-binary "@$DIR/patient1.json" "$BASE_URL/Patient" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
ok "created Patient/$PID1 (Garcia)"

PID2=$(curl -fsS -X POST -H "Content-Type: application/fhir+json" \
  --data-binary "@$DIR/patient2.json" "$BASE_URL/Patient" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
ok "created Patient/$PID2 (Lopez)"

# Bind the sample Observation to the first patient before posting.
sed "s/PATIENT_ID/$PID1/" "$DIR/observation.json" > "$WORK/obs.json"
OID=$(curl -fsS -X POST -H "Content-Type: application/fhir+json" \
  --data-binary "@$WORK/obs.json" "$BASE_URL/Observation" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
ok "created Observation/$OID (heart rate, subject Patient/$PID1)"

# ─────────────────────────────────────────────────────────────────────────────
header "2. \$viewdefinition-validate — valid ViewDefinition"
info "POST \$viewdefinition-validate  (view-patient-demographics.json)"
OUT=$(curl -fsS -X POST -H "Content-Type: application/json" \
  --data-binary "@$DIR/view-patient-demographics.json" \
  "$BASE_URL/\$viewdefinition-validate")
echo "$OUT" | python3 -c "import sys,json;d=json.load(sys.stdin);print('   ->',d['issue'][0]['severity'],'-',d['issue'][0].get('diagnostics',''))"
echo "$OUT" | grep -q '"severity":"information"' && ok "valid ViewDefinition accepted" \
  || fail "expected information-severity OperationOutcome"

# ─────────────────────────────────────────────────────────────────────────────
header "3. \$viewdefinition-validate — invalid ViewDefinition (missing 'resource')"
info "POST \$viewdefinition-validate  (view-invalid.json)"
OUT=$(curl -fsS -X POST -H "Content-Type: application/json" \
  --data-binary "@$DIR/view-invalid.json" \
  "$BASE_URL/\$viewdefinition-validate")
echo "$OUT" | python3 -c "import sys,json;d=json.load(sys.stdin);print('   ->',d['issue'][0]['severity'],'-',d['issue'][0].get('diagnostics',''))"
echo "$OUT" | grep -q '"severity":"error"' && ok "invalid ViewDefinition rejected with error" \
  || fail "expected error-severity OperationOutcome"

# ─────────────────────────────────────────────────────────────────────────────
header "4. \$viewdefinition-run — Patient demographics (JSON: columns + rows)"
info "POST \$viewdefinition-run  (default JSON format)"
OUT=$(curl -fsS -X POST -H "Content-Type: application/json" \
  --data-binary "@$DIR/view-patient-demographics.json" \
  "$BASE_URL/\$viewdefinition-run")
echo "$OUT" | python3 -c "import sys,json;d=json.load(sys.stdin);print('   columns:',[c['name'] for c in d['columns']]);print('   rows   :',len(d['rows']))"
echo "$OUT" | python3 -c "import sys,json;sys.exit(0 if json.load(sys.stdin)['rows'] else 1)" \
  && ok "flattened Patient rows returned" || fail "expected at least one row"

# ─────────────────────────────────────────────────────────────────────────────
header "5. \$viewdefinition-run — CSV output (?_format=csv, Accept text/csv)"
info "POST \$viewdefinition-run?_format=csv"
curl -fsS -X POST -H "Content-Type: application/json" -H "Accept: text/csv" \
  --data-binary "@$DIR/view-patient-demographics.json" \
  "$BASE_URL/\$viewdefinition-run?_format=csv" | tee "$WORK/patients.csv"
head -1 "$WORK/patients.csv" | grep -q "id,family" && ok "CSV header emitted" \
  || fail "expected CSV header row 'id,family,...'"

# ─────────────────────────────────────────────────────────────────────────────
header "6. \$viewdefinition-run — NDJSON output (?_format=ndjson, Accept x-ndjson)"
info "POST \$viewdefinition-run?_format=ndjson"
curl -fsS -X POST -H "Content-Type: application/json" -H "Accept: application/x-ndjson" \
  --data-binary "@$DIR/view-patient-demographics.json" \
  "$BASE_URL/\$viewdefinition-run?_format=ndjson" | tee "$WORK/patients.ndjson"
head -1 "$WORK/patients.ndjson" | python3 -c "import sys,json;json.loads(sys.stdin.readline())" \
  && ok "each line is a JSON object" || fail "expected NDJSON output"

# ─────────────────────────────────────────────────────────────────────────────
header "7. \$viewdefinition-run — forEach array unnesting (one row per telecom)"
info "POST \$viewdefinition-run  (view-patient-telecom.json)"
OUT=$(curl -fsS -X POST -H "Content-Type: application/json" \
  --data-binary "@$DIR/view-patient-telecom.json" \
  "$BASE_URL/\$viewdefinition-run")
echo "$OUT" | python3 -c "import sys,json;d=json.load(sys.stdin);print('   rows   :',len(d['rows']),'(one per telecom entry across patients)')"
ok "forEach unnested telecom into rows"

# ─────────────────────────────────────────────────────────────────────────────
header "8. \$viewdefinition-run — _limit parameter (cap output rows)"
info "POST \$viewdefinition-run?_limit=1"
OUT=$(curl -fsS -X POST -H "Content-Type: application/json" \
  --data-binary "@$DIR/view-patient-demographics.json" \
  "$BASE_URL/\$viewdefinition-run?_limit=1")
N=$(echo "$OUT" | python3 -c "import sys,json;print(len(json.load(sys.stdin)['rows']))")
[[ "$N" -le 1 ]] && ok "_limit=1 capped output to $N row(s)" || fail "_limit not honored (got $N rows)"

# ─────────────────────────────────────────────────────────────────────────────
header "9. \$viewdefinition-run — Observation analytics view (where status='final')"
info "POST \$viewdefinition-run  (view-observation-flat.json)"
OUT=$(curl -fsS -X POST -H "Content-Type: application/json" \
  --data-binary "@$DIR/view-observation-flat.json" \
  "$BASE_URL/\$viewdefinition-run")
echo "$OUT" | python3 -c "import sys,json;d=json.load(sys.stdin);print('   columns:',[c['name'] for c in d['columns']]);print('   rows   :',len(d['rows']))"
ok "Observation flattened to LOINC/value columns"

# ─────────────────────────────────────────────────────────────────────────────
header "10. \$viewdefinition-run — patient compartment scoping (?patient=...)"
info "POST \$viewdefinition-run?patient=$PID1"
OUT=$(curl -fsS -X POST -H "Content-Type: application/json" \
  --data-binary "@$DIR/view-observation-flat.json" \
  "$BASE_URL/\$viewdefinition-run?patient=$PID1")
echo "$OUT" | python3 -c "import sys,json;print('   rows scoped to Patient/'+'$PID1'+':',len(json.load(sys.stdin)['rows']))"
ok "output scoped to a single patient compartment"

# ─────────────────────────────────────────────────────────────────────────────
header "11. \$viewdefinition-export — async bulk export (202 + poll + download)"
info "POST \$viewdefinition-export  (Prefer: respond-async)"
HDRS=$(curl -fsS -D - -o /dev/null -X POST \
  -H "Content-Type: application/json" -H "Prefer: respond-async" \
  --data-binary "@$DIR/view-patient-demographics.json" \
  "$BASE_URL/\$viewdefinition-export")
LOC=$(printf '%s' "$HDRS" | tr -d '\r' | awk 'tolower($1)=="content-location:"{print $2}')
[[ -n "$LOC" ]] && ok "kicked off export — Content-Location: $LOC" \
  || fail "no Content-Location header returned (is SQLFHIR_EXPORT_ENABLED=true?)"

# Status endpoint may be absolute or relative; normalize to an absolute URL.
case "$LOC" in
  http*) STATUS_URL="$LOC" ;;
  /fhir/r4/*) STATUS_URL="${BASE_URL%/fhir/r4}$LOC" ;;
  /*) STATUS_URL="${BASE_URL}$LOC" ;;
  *) STATUS_URL="$BASE_URL/$LOC" ;;
esac

info "Poll status until 200 (manifest) — GET $STATUS_URL"
MANIFEST=""
for i in $(seq 1 20); do
  CODE=$(curl -s -o "$WORK/status.json" -w '%{http_code}' "$STATUS_URL" || true)
  if [[ "$CODE" == "200" ]]; then
    MANIFEST="$WORK/status.json"; ok "export complete (poll #$i → 200)"; break
  fi
  printf "   poll #%s → %s (in progress)\n" "$i" "$CODE"
  sleep 1
done
[[ -n "$MANIFEST" ]] || fail "export did not complete within timeout"

info "Manifest output files:"
DATA_URL=$(python3 -c "import sys,json;d=json.load(open('$MANIFEST'));print(d['output'][0]['url'])" < /dev/null)
python3 -c "import json;d=json.load(open('$MANIFEST'));[print('   ',o['type'],'->',o['url']) for o in d['output']]"

case "$DATA_URL" in
  http*) FILE_URL="$DATA_URL" ;;
  /fhir/r4/*) FILE_URL="${BASE_URL%/fhir/r4}$DATA_URL" ;;
  /*) FILE_URL="${BASE_URL}$DATA_URL" ;;
  *) FILE_URL="$BASE_URL/$DATA_URL" ;;
esac
info "Download NDJSON — GET $FILE_URL"
curl -fsS "$FILE_URL" | tee "$WORK/export.ndjson" >/dev/null
ok "downloaded $(wc -l < "$WORK/export.ndjson" | tr -d ' ') NDJSON line(s)"

printf "\n${B}${G}All SQL-on-FHIR examples completed.${N}\n"
