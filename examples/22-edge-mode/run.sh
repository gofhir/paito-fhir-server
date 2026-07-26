#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Edge Mode — runnable examples
#
# Derived from the proven e2e-edge-smoke.sh: drives a full FHIR lifecycle
# (metadata → create → read → update → search → $validate) against an edge-mode
# server running on embedded SQLite with zero external services. Also confirms
# the edge invariant that the admin API port is closed.
#
# Launch the stack first:
#   docker compose -f docker-compose.edge.yml up -d
# Then:
#   bash run.sh
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

hr()  { printf '\n=== %s ===\n' "$1"; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }

# ── 1. Capability statement ───────────────────────────────────────────────────
hr "1. metadata — the edge server serves the full CapabilityStatement"
STATUS=$(code "$BASE_URL/metadata")
echo "GET /metadata -> HTTP $STATUS"
[[ "$STATUS" == "200" ]] || { echo "server not ready (want 200)"; exit 1; }

# ── 2. Create a Patient ───────────────────────────────────────────────────────
hr "2. create Patient (embedded SQLite persists it)"
CREATE=$(curl -s -w '\n%{http_code}' -X POST "$BASE_URL/Patient" \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @"$DIR/patient.json")
STATUS=$(echo "$CREATE" | tail -n1)
BODY=$(echo "$CREATE" | sed '$d')
echo "POST /Patient -> HTTP $STATUS (want 201)"
[[ "$STATUS" == "201" ]] || { echo "$BODY"; exit 1; }
PID=$(echo "$BODY" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
echo "created Patient/$PID"

# ── 3. Read it back ───────────────────────────────────────────────────────────
hr "3. read Patient/$PID"
STATUS=$(code "$BASE_URL/Patient/$PID")
echo "GET /Patient/$PID -> HTTP $STATUS (want 200)"

# ── 4. Update it ──────────────────────────────────────────────────────────────
hr "4. update Patient/$PID (add a second given name)"
UPDATE=$(sed "s/\"__ID__\"/\"$PID\"/" "$DIR/patient-update.json")
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE_URL/Patient/$PID" \
  -H 'Content-Type: application/fhir+json' -d "$UPDATE")
echo "PUT /Patient/$PID -> HTTP $STATUS (want 200)"

# ── 5. Search ─────────────────────────────────────────────────────────────────
hr "5. search Patient?family=Edge"
SEARCH=$(curl -s "$BASE_URL/Patient?family=Edge")
TOTAL=$(echo "$SEARCH" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("total",0))')
echo "GET /Patient?family=Edge -> total = $TOTAL"

# ── 6. $validate ──────────────────────────────────────────────────────────────
hr "6. \$validate a resource (structural validation runs on edge)"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/Patient/\$validate" \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @"$DIR/patient-validate.json")
echo "POST /Patient/\$validate -> HTTP $STATUS (200 = OperationOutcome returned)"

# ── 7. Edge invariant: admin API is disabled ──────────────────────────────────
hr "7. edge invariant — admin API port (3501) is closed"
ADMIN=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:3501/health" 2>/dev/null) || ADMIN="000"
if [[ "$ADMIN" == "000" ]]; then
  echo "admin port 3501 closed (edge disables the admin API) — OK"
else
  echo "note: admin port answered HTTP $ADMIN"
fi

echo
echo "Done — a self-contained FHIR server on embedded SQLite, zero external services."
