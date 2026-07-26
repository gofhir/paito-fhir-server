#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Paito FHIR Server — Admin API & Web UI demo
# ─────────────────────────────────────────────────────────────────────────────
# Exercises the Admin API on :3501 the same way the go-fhir-server security
# smoke does (Bearer/API-key auth, /api/clients, /api/audit/events, /api/audit/
# stats) and adds the client CRUD, IG package, config, and storage endpoints.
#
# Prereq:  docker compose -f docker-compose.admin.yml up -d
# Usage:   bash examples/26-admin-api/run.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# FHIR API base (create a Patient so the audit trail has an event).
BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
# Admin API base + key (matches ADMIN_API_KEY in docker-compose.admin.yml).
ADMIN_URL="${ADMIN_URL:-http://localhost:3501}"
ADMIN_KEY="${ADMIN_API_KEY:-paito-admin-key-change-me}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Both accepted auth styles; the smoke uses the Bearer form.
AUTH=(-H "Authorization: Bearer ${ADMIN_KEY}")

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$1"; }
code() { # code METHOD URL [curl args...] -> prints HTTP status
  local m=$1 u=$2; shift 2
  curl -s -o /dev/null -w '%{http_code}' -X "$m" "$u" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
say "0. Pre-flight — FHIR + Admin API reachable"
curl -fsS --max-time 5 "${BASE_URL}/metadata" >/dev/null && echo "  FHIR ok: ${BASE_URL}"
curl -fsS --max-time 5 ${AUTH[@]+"${AUTH[@]}"} "${ADMIN_URL}/api/clients" >/dev/null \
  && echo "  Admin ok (Bearer auth): ${ADMIN_URL}"

# ─────────────────────────────────────────────────────────────────────────────
say "1. Auth is enforced — no key -> 401"
ST=$(code GET "${ADMIN_URL}/api/clients")
echo "  GET /api/clients (no key) -> ${ST}   (expect 401)"

say "1b. Health + metrics need no auth"
echo "  GET /health  -> $(code GET "${ADMIN_URL}/health")   (expect 200)"
echo "  GET /metrics -> $(code GET "${ADMIN_URL}/metrics")  (expect 200)"

# ─────────────────────────────────────────────────────────────────────────────
say "2. OAuth Client CRUD"
echo "  -> GET /api/clients (seeded 'patient-portal' should be present)"
curl -s ${AUTH[@]+"${AUTH[@]}"} "${ADMIN_URL}/api/clients" | head -c 600; echo

echo "  -> POST /api/clients (register a backend-service client)"
ST=$(code POST "${ADMIN_URL}/api/clients" ${AUTH[@]+"${AUTH[@]}"} \
      -H "Content-Type: application/json" --data @"${DIR}/client.json")
echo "     status ${ST}   (expect 201, or 409 if it already exists)"

echo "  -> GET /api/clients/backend-service"
curl -s ${AUTH[@]+"${AUTH[@]}"} "${ADMIN_URL}/api/clients/backend-service" | head -c 400; echo

echo "  -> PUT /api/clients/backend-service (widen scopes)"
ST=$(code PUT "${ADMIN_URL}/api/clients/backend-service" ${AUTH[@]+"${AUTH[@]}"} \
      -H "Content-Type: application/json" --data @"${DIR}/client-update.json")
echo "     status ${ST}   (expect 200)"

echo "  -> DELETE /api/clients/backend-service"
ST=$(code DELETE "${ADMIN_URL}/api/clients/backend-service" ${AUTH[@]+"${AUTH[@]}"})
echo "     status ${ST}   (expect 200)"

# ─────────────────────────────────────────────────────────────────────────────
say "3. IG / Package management"
echo "  -> GET /api/packages (installed IG packages)"
curl -s ${AUTH[@]+"${AUTH[@]}"} "${ADMIN_URL}/api/packages" | head -c 400; echo
echo "  (Install pulls from packages.fhir.org and needs network + time:)"
echo "     curl -X POST ${ADMIN_URL}/api/packages/install -H 'Authorization: Bearer ***' \\"
echo "          -H 'Content-Type: application/json' -d '{\"name\":\"hl7.fhir.us.core\",\"version\":\"6.1.0\"}'"

# ─────────────────────────────────────────────────────────────────────────────
say "4. Generate FHIR activity, then query the audit trail"
echo "  -> POST ${BASE_URL}/Patient (creates an auditable event)"
curl -s -o /dev/null -w '     Patient create -> %{http_code}\n' \
  -X POST "${BASE_URL}/Patient" \
  -H "Content-Type: application/fhir+json" --data @"${DIR}/patient.json"

echo "  -> GET /api/audit/events?limit=10 (poll briefly — audit writes are batched)"
for _ in $(seq 1 10); do
  N=$(curl -s ${AUTH[@]+"${AUTH[@]}"} "${ADMIN_URL}/api/audit/events?limit=10" \
       | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('events',[])))" 2>/dev/null || echo 0)
  [ "${N:-0}" -ge 1 ] && break
  sleep 1
done
echo "     recent events: ${N:-0}"
curl -s ${AUTH[@]+"${AUTH[@]}"} "${ADMIN_URL}/api/audit/events?limit=3" | head -c 500; echo

echo "  -> GET /api/audit/stats (aggregate by type + outcome)"
curl -s ${AUTH[@]+"${AUTH[@]}"} "${ADMIN_URL}/api/audit/stats" | head -c 400; echo

echo "  -> GET /api/audit/export?format=csv (download denied+all events as CSV)"
curl -s ${AUTH[@]+"${AUTH[@]}"} "${ADMIN_URL}/api/audit/export?format=csv&limit=100" -o "${DIR}/audit-export.csv"
echo "     wrote ${DIR}/audit-export.csv ($(wc -l < "${DIR}/audit-export.csv" | tr -d ' ') lines)"

# ─────────────────────────────────────────────────────────────────────────────
say "5. Configuration"
echo "  -> GET /api/config (secrets redacted)"
curl -s ${AUTH[@]+"${AUTH[@]}"} "${ADMIN_URL}/api/config" | head -c 500; echo

# ─────────────────────────────────────────────────────────────────────────────
say "6. Storage management (PostgreSQL stats + VACUUM ANALYZE)"
echo "  -> GET /api/storage/stats"
curl -s ${AUTH[@]+"${AUTH[@]}"} "${ADMIN_URL}/api/storage/stats" | head -c 400; echo
echo "  -> POST /api/storage/vacuum"
ST=$(code POST "${ADMIN_URL}/api/storage/vacuum" ${AUTH[@]+"${AUTH[@]}"})
echo "     status ${ST}   (expect 200)"

# ─────────────────────────────────────────────────────────────────────────────
say "7. Web Dashboard"
echo "  Open in a browser:  ${ADMIN_URL}/ui/"
echo "  -> GET /ui/ -> $(code GET "${ADMIN_URL}/ui/" ${AUTH[@]+"${AUTH[@]}"})   (expect 200)"

say "Done."
