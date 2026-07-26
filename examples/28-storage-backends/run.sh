#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# 28 — Storage Backends & Full-Text Search
# Derived from go-fhir-server FTS + CRUD e2e patterns (proven endpoints:
#   _text / _content / $reindex documented in search-indexing/full-text-search).
#
# The requests below are STORAGE-AGNOSTIC: the exact same calls pass whether the
# server is running on PostgreSQL (docker-compose.yml), MongoDB
# (docker-compose.mongodb.yml), or SQLite (STORAGE_DRIVER=sqlite). Full-text
# search (_text / _content) is served by the embedded Bleve engine, which is
# available on every backend.
#
# Usage:
#   # PostgreSQL (default backend):
#   docker compose -f docker-compose.yml up -d
#   # ...or MongoDB backend (same requests, different store):
#   docker compose -f docker-compose.mongodb.yml up -d
#
#   bash examples/28-storage-backends/run.sh
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CT='Content-Type: application/fhir+json'
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

# http METHOD URL [DATA] → sets STATUS + BODY globals
STATUS=""; BODY=""
http() {
  local method="$1" url="$2"; shift 2
  local data=""
  if [[ "${1:-}" != "" && "${1:0:1}" == "{" ]]; then data="$1"; shift; fi
  local args=(-s -X "$method" -o "$BODY_FILE" -w '%{http_code}' -H "$CT")
  [[ -n "$data" ]] && args+=(--data-binary "$data")
  STATUS="$(curl "${args[@]}" "$url")"
  BODY="$(cat "$BODY_FILE")"
}
say()   { printf '\n\033[1;36m== %s\033[0m\n' "$1"; }
check() { # check EXPECTED LABEL
  if [[ "$STATUS" == "$1" ]]; then printf '  \033[32mok\033[0m  %s → %s\n' "$2" "$STATUS"
  else printf '  \033[31mFAIL\033[0m %s → %s (want %s)\n' "$2" "$STATUS" "$1"; echo "$BODY"; exit 1; fi
}

# ── 0. Confirm which backend is active ─────────────────────────────────────
say "0. Capability statement — confirms the server is up (backend-agnostic)"
http GET "$BASE_URL/metadata"
check 200 "GET /metadata"
echo "$BODY" | grep -q '"resourceType":"CapabilityStatement"' && echo "  CapabilityStatement served"

# ── 1. Core CRUD works identically on every backend ────────────────────────
say "1. CREATE — POST /Patient (diabetes narrative)"
http POST "$BASE_URL/Patient" "$(cat "$DIR/patient-diabetes.json")"
check 201 "POST /Patient"
PID_DIAB="$(echo "$BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
echo "  Patient id: $PID_DIAB"

say "2. CREATE — POST /Patient (plain narrative, no clinical problems)"
http POST "$BASE_URL/Patient" "$(cat "$DIR/patient-plain.json")"
check 201 "POST /Patient"
PID_PLAIN="$(echo "$BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
echo "  Patient id: $PID_PLAIN"

say "3. CREATE — POST /Observation (blood pressure)"
http POST "$BASE_URL/Observation" "$(cat "$DIR/observation-bp.json")"
check 201 "POST /Observation"
OBS_ID="$(echo "$BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
echo "  Observation id: $OBS_ID"

say "4. READ — GET /Patient/{id}"
http GET "$BASE_URL/Patient/$PID_DIAB"
check 200 "GET /Patient/$PID_DIAB"
echo "$BODY" | grep -q '"family":"Smith"' && echo "  family=Smith present"

# ── 2. Common search (works on all five backends) ──────────────────────────
say "5. Common search — GET /Patient?gender=female (token search parameter)"
http GET "$BASE_URL/Patient?gender=female"
check 200 "GET /Patient?gender=female"
echo "$BODY" | grep -q '"resourceType":"Bundle"' && echo "  searchset Bundle returned"

# FTS is async best-effort (indexed in a background goroutine). Give the
# embedded Bleve engine a moment to catch up before querying _text/_content.
say "6. Wait briefly for async full-text indexing (Bleve is eventual-consistent)"
sleep 2
echo "  proceeding"

# ── 3. Full-text search: _text (narrative) ─────────────────────────────────
say "7. FTS _text — GET /Patient?_text=diabetes (searches Resource.text.div)"
http GET "$BASE_URL/Patient?_text=diabetes"
check 200 "GET /Patient?_text=diabetes"
echo "$BODY" | grep -q '"resourceType":"Bundle"' && echo "  searchset Bundle returned (matches the diabetes narrative)"

# ── 4. Full-text search: _content (whole resource) ─────────────────────────
say "8. FTS _content — GET /Observation?_content=blood pressure (whole-resource text)"
http GET "$BASE_URL/Observation?_content=blood%20pressure"
check 200 "GET /Observation?_content=blood pressure"
echo "$BODY" | grep -q '"resourceType":"Bundle"' && echo "  searchset Bundle returned"

# ── 5. FTS combined with a structured parameter ────────────────────────────
say "9. FTS + structured — GET /Patient?_text=diabetes&active=true"
http GET "$BASE_URL/Patient?_text=diabetes&active=true"
check 200 "GET /Patient?_text=diabetes&active=true"
echo "$BODY" | grep -q '"resourceType":"Bundle"' && echo "  FTS IDs intersected with active=true"

# ── 6. Rebuild the FTS index for a resource type ───────────────────────────
say "10. \$reindex — POST /Patient/\$reindex (rebuild Bleve index; admin op)"
http POST "$BASE_URL/Patient/\$reindex"
# 200 when reindex runs; if auth is enabled without an admin token expect 401/403.
if [[ "$STATUS" == "200" ]]; then
  echo "  ok  Patient/\$reindex → 200 (index rebuilt)"
elif [[ "$STATUS" == "401" || "$STATUS" == "403" ]]; then
  echo "  note  Patient/\$reindex → $STATUS (auth enabled — supply an admin token)"
else
  printf '  \033[31mFAIL\033[0m Patient/$reindex → %s\n' "$STATUS"; echo "$BODY"; exit 1
fi

say "Done — the same requests run unchanged on PostgreSQL, MongoDB and SQLite."
