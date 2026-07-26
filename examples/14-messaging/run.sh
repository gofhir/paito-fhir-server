#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Paito FHIR Server — Messaging ($process-message) examples
#
# Derived from the proven e2e-messaging-smoke.sh. Demonstrates, in order:
#   1. CapabilityStatement declares the messaging paradigm.
#   2. Envelope validation: a message missing MessageHeader.source -> 400.
#   3. Processing: a valid message -> response.code=ok, focus Patient persisted.
#   4. Bundle profile validation: a message violating its meta.profile -> fatal-error.
#   5. MessageDefinition focus validation: a message missing a required focus -> fatal-error.
#   6. Async delivery: async=true -> 202 + Content-Location -> poll -> ok.
#
# Prereqs: stack up (see README) and python3 available for JSON parsing.
#   docker compose -f docker-compose.messaging.yml up -d
#   bash examples/14-messaging/run.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON='Content-Type: application/fhir+json'
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

hr()  { printf '\n=== %s ===\n' "$1"; }
# reply_code -> MessageHeader.response.code from the reply Bundle in $TMP
reply_code() {
  python3 -c "import json;d=json.load(open('$TMP'));print(next(e['resource']['response']['code'] for e in d['entry'] if e['resource']['resourceType']=='MessageHeader'))"
}
patient_total() {
  curl -s "$BASE_URL/Patient?identifier=urn:mrn|$1" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('total',0))"
}

# ── Wait for the server ───────────────────────────────────────────────────────
hr "Waiting for server at $BASE_URL"
for i in $(seq 1 30); do
  S=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$BASE_URL/metadata" 2>/dev/null || echo 000)
  [[ "$S" == "200" ]] && { echo "server reachable"; break; }
  [[ $i == 30 ]] && { echo "server not reachable at $BASE_URL" >&2; exit 1; }
  sleep 1
done

# ── 1. CapabilityStatement declares messaging ─────────────────────────────────
hr "1. CapabilityStatement.messaging (requires the reference processor enabled)"
HAS_MSG=$(curl -s "$BASE_URL/metadata" \
  | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('messaging',[])))")
echo "metadata.messaging element count: $HAS_MSG"
[[ "$HAS_MSG" -ge 1 ]] && echo "OK: server advertises the messaging paradigm" \
  || { echo "FAIL: messaging not declared (is persistReference enabled?)" >&2; exit 1; }

# ── 2. Envelope validation: missing MessageHeader.source -> 400 ───────────────
hr "2. Envelope validation — MessageHeader.source is 1..1 (expect HTTP 400)"
STATUS=$(curl -s -o "$TMP" -w '%{http_code}' -X POST -H "$JSON" \
  --data-binary @"$DIR/message-no-source.json" "$BASE_URL/\$process-message")
echo "HTTP $STATUS"
[[ "$STATUS" == "400" ]] && echo "OK: malformed envelope rejected" \
  || { echo "FAIL: expected 400" >&2; head -c 400 "$TMP" >&2; exit 1; }

# ── 3. Processing: valid message -> ok + persisted ────────────────────────────
hr "3. Processing — valid message (expect HTTP 200, response.code=ok, Patient persisted)"
STATUS=$(curl -s -o "$TMP" -w '%{http_code}' -X POST -H "$JSON" \
  --data-binary @"$DIR/message-valid.json" "$BASE_URL/\$process-message")
echo "HTTP $STATUS, response.code=$(reply_code)"
[[ "$STATUS" == "200" && "$(reply_code)" == "ok" ]] && echo "OK: message processed" \
  || { echo "FAIL: expected 200 + ok" >&2; head -c 400 "$TMP" >&2; exit 1; }
[[ "$(patient_total PAITO-SYNC)" -ge "1" ]] && echo "OK: focus Patient is searchable" \
  || { echo "FAIL: focus Patient not persisted" >&2; exit 1; }

# ── 4. Bundle profile validation (tool-enforced) ──────────────────────────────
hr "4. Bundle profile validation — install strict profile (Bundle.entry min 3)"
STATUS=$(curl -s -o "$TMP" -w '%{http_code}' -X PUT -H "$JSON" \
  --data-binary @"$DIR/bundle-profile.json" "$BASE_URL/StructureDefinition/PaitoMsgBundle")
echo "HTTP $STATUS (install)"
[[ "$STATUS" == "200" || "$STATUS" == "201" ]] && echo "OK: strict Bundle profile installed" \
  || { echo "FAIL: could not install StructureDefinition" >&2; head -c 400 "$TMP" >&2; exit 1; }

echo "-- post a 2-entry message that declares (and violates) that profile"
STATUS=$(curl -s -o "$TMP" -w '%{http_code}' -X POST -H "$JSON" \
  --data-binary @"$DIR/message-bad-profile.json" "$BASE_URL/\$process-message")
echo "HTTP $STATUS, response.code=$(reply_code)"
[[ "$STATUS" == "200" && "$(reply_code)" == "fatal-error" ]] \
  && echo "OK: message rejected with fatal-error (profile violated)" \
  || { echo "FAIL: expected 200 + fatal-error" >&2; head -c 400 "$TMP" >&2; exit 1; }
[[ "$(patient_total PAITO-BADPROFILE)" == "0" ]] \
  && echo "OK: focus NOT persisted (rejected before dispatch)" \
  || { echo "FAIL: focus persisted despite validation failure" >&2; exit 1; }

# ── 5. MessageDefinition focus validation (hybrid) ────────────────────────────
hr "5. MessageDefinition focus validation — install MessageDefinition (lab-result needs Observation 1..1)"
STATUS=$(curl -s -o "$TMP" -w '%{http_code}' -X PUT -H "$JSON" \
  --data-binary @"$DIR/message-definition-lab.json" "$BASE_URL/MessageDefinition/PaitoMDLab")
echo "HTTP $STATUS (install)"
[[ "$STATUS" == "200" || "$STATUS" == "201" ]] && echo "OK: MessageDefinition installed" \
  || { echo "FAIL: could not install MessageDefinition" >&2; head -c 400 "$TMP" >&2; exit 1; }

echo "-- post a lab-result message with NO Observation focus"
STATUS=$(curl -s -o "$TMP" -w '%{http_code}' -X POST -H "$JSON" \
  --data-binary @"$DIR/message-lab-no-focus.json" "$BASE_URL/\$process-message")
echo "HTTP $STATUS, response.code=$(reply_code)"
[[ "$STATUS" == "200" && "$(reply_code)" == "fatal-error" ]] \
  && echo "OK: message rejected with fatal-error (missing required focus)" \
  || { echo "FAIL: expected 200 + fatal-error" >&2; head -c 400 "$TMP" >&2; exit 1; }

# ── 6. Async delivery: 202 -> poll -> ok ──────────────────────────────────────
hr "6. Async delivery — async=true (expect 202 + Content-Location, then poll)"
CL=$(curl -s -D - -o /dev/null --max-time 5 -X POST -H "$JSON" \
  --data-binary @"$DIR/message-async.json" "$BASE_URL/\$process-message?async=true" \
  | grep -i '^content-location' | tr -d '\r' | awk '{print $2}')
[[ -n "$CL" ]] && echo "OK: async kickoff -> Content-Location: $CL" \
  || { echo "FAIL: async=true did not return a Content-Location (is async enabled?)" >&2; exit 1; }

JID="${CL##*/_asyncstatus/}"
POLLED=""
for i in $(seq 1 20); do
  PS=$(curl -s -o "$TMP" -w '%{http_code}' "$BASE_URL/_asyncstatus/$JID")
  [[ "$PS" == "200" ]] && { POLLED=1; break; }
  sleep 0.3
done
[[ -n "$POLLED" ]] && echo "OK: polled status -> 200 (response Bundle ready)" \
  || { echo "FAIL: async job did not complete" >&2; exit 1; }
echo "async response.code=$(reply_code)"
[[ "$(reply_code)" == "ok" ]] && echo "OK: async message processed" \
  || { echo "FAIL: expected async ok" >&2; exit 1; }
[[ "$(patient_total PAITO-ASYNC)" -ge "1" ]] && echo "OK: focus Patient persisted in background" \
  || { echo "FAIL: async focus Patient not persisted" >&2; exit 1; }

# ── Cleanup (best-effort) ─────────────────────────────────────────────────────
hr "Cleanup"
curl -s -o /dev/null -X DELETE "$BASE_URL/StructureDefinition/PaitoMsgBundle" || true
curl -s -o /dev/null -X DELETE "$BASE_URL/MessageDefinition/PaitoMDLab" || true

hr "RESULT"
echo "All messaging examples passed."
