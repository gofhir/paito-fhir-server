#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# Paito FHIR Server — Bundle types demo
# Derived from go-fhir-server scripts/e2e-bundle-smoke.sh (proven, passing).
#
# Demonstrates every FHIR R4 Bundle type the server handles:
#   transaction  — POST /          atomic write + rollback
#   batch        — POST /          independent entries, partial success
#   document     — POST /          stored verbatim as a Bundle resource
#   message      — POST /$process-message
#   searchset    — returned by GET /{resource}?...
#   collection   — POST /          REJECTED (400 OperationOutcome)
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
        args+=(-H 'Content-Type: application/fhir+json')
        if [[ "$body" == @* ]]; then args+=(--data-binary "$body"); else args+=(--data-binary "$body"); fi
    fi
    RESP_STATUS=$(curl "${args[@]}" "$url")
    RESP_BODY=$(cat "$TMP")
}

check() { # actual expected label
    if [[ "$1" == "$2" ]]; then ok "$3 → $1"; else fail "$3 → $1 (want $2)"; exit 1; fi
}
contains() { # label needle
    if echo "$RESP_BODY" | grep -q -- "$2"; then ok "$1 contains: $2"; else fail "$1 missing: $2"; exit 1; fi
}
jget() { echo "$RESP_BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

header "Readiness — GET /metadata"
http GET "$BASE_URL/metadata"
check "$RESP_STATUS" "200" "GET /metadata (CapabilityStatement)"

# ── 1. TRANSACTION — atomic create with urn:uuid forward reference ──────────
header "1. TRANSACTION — atomic Patient + Observation (forward ref)"
echo "POST /  a transaction bundle; the Observation.subject points at the"
echo "Patient via urn:uuid, which the server rewrites to Patient/<id>."
http POST "$BASE_URL/" "@$DIR/bundle-transaction.json"
check "$RESP_STATUS" "200" "POST / (transaction)"
contains "response type" '"type":"transaction-response"'
contains "entries created" '"status":"201 Created"'
TX_PATIENT_ID=$(jget "d['entry'][0]['resource']['id']")
TX_OBS_ID=$(jget "d['entry'][1]['resource']['id']")
ok "Patient resolved id:     $TX_PATIENT_ID"
ok "Observation resolved id: $TX_OBS_ID"

echo
echo "Verify the urn:uuid was rewritten to a real Patient reference:"
http GET "$BASE_URL/Observation/$TX_OBS_ID"
check "$RESP_STATUS" "200" "GET Observation"
contains "subject reference" "\"reference\":\"Patient/$TX_PATIENT_ID\""

# ── 1b. TRANSACTION rollback — one bad entry undoes the whole bundle ────────
header "1b. TRANSACTION atomicity — a bad entry rolls back the good one"
echo "POST /  a transaction where entry[1] has an invalid gender code."
echo "The whole bundle must fail; entry[0] must NOT persist."
http POST "$BASE_URL/" "@$DIR/bundle-transaction-invalid.json"
check "$RESP_STATUS" "400" "POST / (invalid transaction)"
contains "OperationOutcome" '"resourceType":"OperationOutcome"'
http GET "$BASE_URL/Patient?family=TX-Should-NOT-Persist"
check "$(jget "d.get('total')")" "0" "rollback — TX-Should-NOT-Persist not created"

# ── 2. BATCH — independent entries, partial success ─────────────────────────
header "2. BATCH — independent entries, partial success"
echo "POST /  a batch with one valid + one invalid Patient."
echo "Unlike a transaction, the valid entry still persists."
http POST "$BASE_URL/" "@$DIR/bundle-batch.json"
check "$RESP_STATUS" "200" "POST / (batch)"
contains "response type" '"type":"batch-response"'
contains "entry[0] created"     '"status":"201 Created"'
contains "entry[1] unprocessable" '"status":"422 Unprocessable Entity"'
http GET "$BASE_URL/Patient?family=Batch-OK"
check "$(jget "d.get('total')")" "1" "Batch-OK persisted"

# ── 3. DOCUMENT — stored verbatim as a Bundle resource ──────────────────────
header "3. DOCUMENT — stored as an immutable Bundle resource"
echo "POST /  a document bundle (Composition first, Bundle.identifier +"
echo "timestamp required). The server stores it as a retrievable Bundle."
http POST "$BASE_URL/" "@$DIR/bundle-document.json"
check "$RESP_STATUS" "200" "POST / (document)"
contains "response type" '"type":"document"'
STORED_BUNDLE_ID=$(jget "d['id']")
ok "stored Bundle id: $STORED_BUNDLE_ID"

echo
echo "The stored document is independently retrievable:"
http GET "$BASE_URL/Bundle/$STORED_BUNDLE_ID"
check "$RESP_STATUS" "200" "GET Bundle/$STORED_BUNDLE_ID"
contains "type=document"       '"type":"document"'
contains "Composition preserved" '"resourceType":"Composition"'

echo
echo "…and discoverable via search:"
http GET "$BASE_URL/Bundle?type=document"
check "$RESP_STATUS" "200" "GET /Bundle?type=document"

echo
echo "A document missing the required Bundle.identifier is rejected (bdl-11):"
http POST "$BASE_URL/" '{"resourceType":"Bundle","type":"document","timestamp":"2026-05-24T16:00:00Z","entry":[{"resource":{"resourceType":"Composition","status":"final","title":"x","type":{"coding":[{"system":"http://loinc.org","code":"11488-4"}]},"date":"2026-05-24T16:00:00Z","author":[{"display":"x"}]}}]}'
check "$RESP_STATUS" "400" "document without identifier"
contains "cites constraint" "bdl-11"

# ── 4. MESSAGE — via $process-message (NOT POST /) ──────────────────────────
header "4. MESSAGE — dispatched via \$process-message"
echo "Message bundles go to the operation endpoint, not the base URL."
http POST "$BASE_URL/\$process-message" "@$DIR/bundle-message.json"
check "$RESP_STATUS" "200" "POST /\$process-message"
contains "response type"   '"type":"message"'
contains "MessageHeader"   '"resourceType":"MessageHeader"'
contains "response ok"     '"code":"ok"'

echo
echo "Sending the same message to POST / (base) is rejected:"
http POST "$BASE_URL/" "@$DIR/bundle-message.json"
if [[ "$RESP_STATUS" == "400" || "$RESP_STATUS" == "422" ]]; then
    ok "POST / rejects message bundles → $RESP_STATUS"
else
    fail "POST / with type=message returned $RESP_STATUS (want 400/422)"; exit 1
fi

# ── 5. SEARCHSET — the Bundle you get back from a GET search ─────────────────
header "5. SEARCHSET — returned by GET /{resource}?..."
http GET "$BASE_URL/Patient"
check "$RESP_STATUS" "200" "GET /Patient"
contains "response type" '"type":"searchset"'
contains "self link"     '"relation":"self"'

echo
echo "A search with no matches still returns a searchset with total=0:"
http GET "$BASE_URL/Patient?family=DoesNotExistAtAll"
check "$RESP_STATUS" "200" "negative search"
check "$(jget "d.get('total')")" "0" "no matches"
contains "still searchset" '"type":"searchset"'

# ── 6. COLLECTION — clients cannot POST one ─────────────────────────────────
header "6. COLLECTION — rejected on POST"
echo "A collection bundle has no request semantics, so POST / rejects it."
http POST "$BASE_URL/" "@$DIR/bundle-collection.json"
check "$RESP_STATUS" "400" "POST / (collection)"
contains "mentions type" "collection"
http GET "$BASE_URL/Patient?family=Should-Be-Rejected"
check "$(jget "d.get('total')")" "0" "rejected collection did not leak entries"

header "Done — 6 bundle types verified"
echo "transaction · batch · document · message · searchset · collection"
