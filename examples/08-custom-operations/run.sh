#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Custom Operations (extension point) — runnable examples
#
# Derived from the proven e2e smoke: scripts/e2e-custom-operation-smoke.sh
#
# Proves the full lifecycle of the shipped reference CUSTOM operation
# $example-echo (enabled via operations.exampleEcho=true):
#   1. Defined via an OperationDefinition, served as a FHIR resource.
#   2. Declared in the CapabilityStatement (rest.operation.definition).
#   3. Invocable over HTTP with a raw resource body (+ query param).
#   3b. Invocable with the general Parameters input form.
#   4. Error path: no body → 400 OperationOutcome.
#
# Prerequisite: bring up the stack with the custom-operations overlay first:
#   docker compose -f docker-compose.custom-operations.yml up -d
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Custom Operations demo against ${BASE_URL} =="

# ── 0. Wait for the server to be reachable ───────────────────────────────────
echo
echo "0. Waiting for server /metadata ..."
for i in $(seq 1 30); do
  S=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${BASE_URL}/metadata" 2>/dev/null || echo 000)
  [[ "$S" == "200" ]] && { echo "   server reachable"; break; }
  [[ $i == 30 ]] && { echo "   server not reachable at ${BASE_URL}" >&2; exit 1; }
  sleep 1
done

# ── 1. OperationDefinition served as a FHIR resource ─────────────────────────
echo
echo "1. GET /OperationDefinition/example-echo  (expect 200; code=example-echo)"
S=$(curl -s -o /tmp/paito-op.json -w '%{http_code}' \
  "${BASE_URL}/OperationDefinition/example-echo")
echo "   HTTP ${S}"
[[ "$S" == "200" ]] || { echo "   FAILED (is operations.exampleEcho enabled?)" >&2; cat /tmp/paito-op.json; exit 1; }
grep -q '"code": *"example-echo"' /tmp/paito-op.json && echo "   OperationDefinition.code = example-echo"

# ── 2. Declared in the CapabilityStatement ───────────────────────────────────
echo
echo "2. GET /metadata  (expect example-echo advertised under rest.operation)"
curl -s "${BASE_URL}/metadata" | grep -q "example-echo" \
  && echo "   metadata advertises example-echo" \
  || { echo "   example-echo NOT advertised" >&2; exit 1; }

# ── 3. Invocable over HTTP with a raw resource body + query param ─────────────
echo
echo "3. POST /\$example-echo?note=hello  (raw Patient body → 200 Parameters)"
S=$(curl -s -o /tmp/paito-op.json -w '%{http_code}' -X POST \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @"${DIR}/patient.json" \
  "${BASE_URL}/\$example-echo?note=hello")
echo "   HTTP ${S}"
[[ "$S" == "200" ]] || { echo "   FAILED" >&2; cat /tmp/paito-op.json; exit 1; }
echo "   response:"; cat /tmp/paito-op.json; echo

# ── 3b. Invocable with the general Parameters input form ─────────────────────
echo
echo "3b. POST /\$example-echo  (Parameters body wrapping Patient/p2 + note)"
S=$(curl -s -o /tmp/paito-op.json -w '%{http_code}' -X POST \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @"${DIR}/parameters-echo.json" \
  "${BASE_URL}/\$example-echo")
echo "   HTTP ${S}"
[[ "$S" == "200" ]] || { echo "   FAILED" >&2; cat /tmp/paito-op.json; exit 1; }
echo "   response:"; cat /tmp/paito-op.json; echo

# ── 4. Error path: no body → 400 OperationOutcome ────────────────────────────
echo
echo "4. POST /\$example-echo  (no body → expect 400 OperationOutcome)"
S=$(curl -s -o /tmp/paito-op.json -w '%{http_code}' -X POST \
  -H 'Content-Type: application/fhir+json' \
  "${BASE_URL}/\$example-echo")
echo "   HTTP ${S}"
[[ "$S" == "400" ]] || { echo "   expected 400" >&2; cat /tmp/paito-op.json; exit 1; }
grep -q '"resourceType": *"OperationOutcome"' /tmp/paito-op.json \
  && echo "   returns an OperationOutcome" \
  || { echo "   expected OperationOutcome" >&2; exit 1; }

echo
echo "== Done: custom operation defined + declared + invocable + error path all verified =="
