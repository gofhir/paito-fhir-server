#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# Paito FHIR Server — FHIR Documents ($document) demo
# Derived from go-fhir-server scripts/e2e-ops-sweep-smoke.sh (Step 8, $document)
# and scripts/e2e-bundle-smoke.sh (Step 7, document-Bundle self-containment).
#
# Demonstrates:
#   1. Seeding a Patient + Observation + Composition
#   2. Composition/$document — the server assembles a self-contained
#      document Bundle (Composition first + every resource it references)
#   3. persist=true — the generated document is stored and retrievable
#   4. Self-containment validation — a valid document Bundle POSTed to /
#      is stored verbatim; an invalid one (missing Bundle.identifier) is
#      rejected 400 citing constraint bdl-11.
#
# Prereqs: a running stack (see README) + curl + python3.
#   docker compose up -d          # base docker-compose.yml (Postgres + paito)
#   bash run.sh
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

B="\033[1m"; G="\033[32m"; R="\033[31m"; C="\033[36m"; N="\033[0m"
header() { printf "\n${B}${C}═══ %s ═══${N}\n" "$1"; }
ok()     { printf "${G}✔${N} %s\n" "$1"; }
fail()   { printf "${R}✗${N} %s\n" "$1" >&2; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# http METHOD URL [BODY|@file] -> sets RESP_STATUS + RESP_BODY
http() {
    local method=$1 url=$2 body=${3:-}
    local args=(-s -X "$method" -o "$TMP" -w '%{http_code}')
    if [[ -n "$body" ]]; then
        args+=(-H 'Content-Type: application/fhir+json' --data-binary "$body")
    fi
    RESP_STATUS=$(curl "${args[@]}" "$url")
    RESP_BODY=$(cat "$TMP")
}

check()    { if [[ "$1" == "$2" ]]; then ok "$3 → $1"; else fail "$3 → $1 (want $2)"; exit 1; fi; }
contains() { if echo "$RESP_BODY" | grep -q -- "$2"; then ok "$1 contains: $2"; else fail "$1 missing: $2"; exit 1; fi; }
jget()     { echo "$RESP_BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

# ── Readiness ───────────────────────────────────────────────────────────────
header "Readiness — GET /metadata"
http GET "$BASE_URL/metadata"
check "$RESP_STATUS" "200" "GET /metadata (CapabilityStatement)"

# ── 0. Seed the resources the Composition will reference ────────────────────
header "0. Seed — Patient + Observation the document will pull in"
http POST "$BASE_URL/Patient" "@$DIR/patient.json"
check "$RESP_STATUS" "201" "POST /Patient"
PID=$(jget "d['id']")
ok "Patient id: $PID"

echo
echo "Create an Observation for that Patient (referenced from the Composition):"
http POST "$BASE_URL/Observation" '{
  "resourceType":"Observation",
  "status":"final",
  "code":{"coding":[{"system":"http://loinc.org","code":"29463-7","display":"Body weight"}]},
  "subject":{"reference":"Patient/'"$PID"'"},
  "effectiveDateTime":"2026-05-27T10:00:00Z",
  "valueQuantity":{"value":62,"unit":"kg","system":"http://unitsofmeasure.org","code":"kg"}
}'
check "$RESP_STATUS" "201" "POST /Observation"
OID=$(jget "d['id']")
ok "Observation id: $OID"

echo
echo "Create the Composition (references Patient as subject + Observation in a section):"
http POST "$BASE_URL/Composition" '{
  "resourceType":"Composition",
  "status":"final",
  "type":{"coding":[{"system":"http://loinc.org","code":"34133-9","display":"Summary of episode note"}]},
  "subject":{"reference":"Patient/'"$PID"'"},
  "date":"2026-05-27T10:00:00Z",
  "author":[{"display":"Paito Demo"}],
  "title":"Episode summary for Document-Subject",
  "section":[
    {"title":"Vitals","entry":[{"reference":"Observation/'"$OID"'"}]}
  ]
}'
check "$RESP_STATUS" "201" "POST /Composition"
COMP=$(jget "d['id']")
ok "Composition id: $COMP"

# ── 1. Composition/$document — assemble a self-contained document Bundle ────
header "1. Composition/\$document — generate the document Bundle"
echo "GET /Composition/$COMP/\$document — the server reads the Composition,"
echo "resolves the resources it references, and returns a Bundle.type=document"
echo "with the Composition FIRST followed by every referenced resource."
http GET "$BASE_URL/Composition/$COMP/\$document"
check "$RESP_STATUS" "200" "GET Composition/\$document"
contains "response type"        '"type":"document"'
contains "Composition present"  '"resourceType":"Composition"'
contains "Patient pulled in"    '"resourceType":"Patient"'
contains "Observation pulled in" '"resourceType":"Observation"'
contains "fresh Bundle.identifier" '"identifier"'
FIRST_RT=$(jget "d['entry'][0]['resource']['resourceType']")
check "$FIRST_RT" "Composition" "first entry is the Composition"
ENTRY_COUNT=$(jget "len(d.get('entry',[]))")
ok "document assembled with $ENTRY_COUNT entries"

# ── 2. persist=true — store the generated document, then retrieve it ────────
header "2. \$document?persist=true — store + retrieve the generated document"
http GET "$BASE_URL/Composition/$COMP/\$document?persist=true"
check "$RESP_STATUS" "200" "GET Composition/\$document?persist=true"
DOC_ID=$(jget "d['id']")
ok "persisted Bundle id: $DOC_ID"

echo
echo "The stored document is independently retrievable as a Bundle:"
http GET "$BASE_URL/Bundle/$DOC_ID"
check "$RESP_STATUS" "200" "GET Bundle/$DOC_ID"
contains "stored as document" '"type":"document"'

echo
echo "…and discoverable via search by type:"
http GET "$BASE_URL/Bundle?type=document"
check "$RESP_STATUS" "200" "GET /Bundle?type=document"
contains "searchset" '"type":"searchset"'

# ── 3. Self-containment validation — POST a document Bundle directly ────────
header "3. Self-containment — a valid document Bundle POSTed to / is stored"
echo "A client-authored document Bundle (Composition first, Bundle.identifier"
echo "+ timestamp present, its references resolve inside the bundle) is stored"
echo "verbatim as an immutable Bundle resource."
http POST "$BASE_URL/" "@$DIR/bundle-document.json"
check "$RESP_STATUS" "200" "POST / (valid document)"
contains "stored as document" '"type":"document"'
STORED=$(jget "d['id']")
ok "stored Bundle id: $STORED"

echo
echo "An INVALID document (missing the required Bundle.identifier) is rejected"
echo "with 400 and an OperationOutcome citing constraint bdl-11:"
http POST "$BASE_URL/" "@$DIR/bundle-document-invalid.json"
check "$RESP_STATUS" "400" "POST / (document without identifier)"
contains "OperationOutcome" '"resourceType":"OperationOutcome"'
contains "cites constraint"  "bdl-11"

header "Done — \$document generation + document self-containment verified"
echo "seed · Composition/\$document · persist=true · self-containment validation"
