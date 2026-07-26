#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# 18 — XML Format & Automatic Narrative Generation
# Derived from go-fhir-server/scripts/e2e-ops-smoke.sh, Step 7 "Content
# negotiation (XML)" (proven, passing E2E test), plus narrative demonstration.
#
# Demonstrates:
#   - Content-Type: application/fhir+xml request  → XML response
#   - ?_format=xml query parameter                → XML response
#   - POST an XML resource (Content-Type: application/fhir+xml) → server reads it
#   - XML-created resource is searchable          → JSON/XML transparent
#   - Automatic XHTML narrative (Resource.text.div) injected on create
#
# Usage:
#   docker compose -f docker-compose.xml-narrative.yml up -d   # from repo root
#   bash examples/18-xml-narrative/run.sh
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BODY_FILE="$(mktemp)"
HDR_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE" "$HDR_FILE"' EXIT

STATUS=""; BODY=""; CT=""
# req METHOD URL [--data @file|STRING] [-H header]...
req() {
  local method="$1" url="$2"; shift 2
  STATUS="$(curl -sS -X "$method" -o "$BODY_FILE" -D "$HDR_FILE" -w '%{http_code}' "$@" "$url")"
  BODY="$(cat "$BODY_FILE")"
  CT="$(grep -i '^content-type:' "$HDR_FILE" | tail -1 | tr -d '\r' | sed 's/^[Cc]ontent-[Tt]ype: *//')"
}
say()  { printf '\n\033[1;36m== %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32mok\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; echo "$BODY"; exit 1; }
check_status() { [[ "$STATUS" == "$1" ]] && ok "$2 → $STATUS" || fail "$2 → $STATUS (want $1)"; }
contains() { echo "$BODY" | grep -qF "$1" && ok "$2" || fail "$2 (missing: $1)"; }

# ── Seed a Patient (JSON create) ─────────────────────────────────────────────
say "Seed — POST Patient as JSON (narrative auto-generated on create)"
req POST "$BASE_URL/Patient" \
  -H 'Content-Type: application/fhir+json' \
  -H 'Accept: application/fhir+json' \
  --data @"$DIR/patient.json"
check_status 201 "create Patient (JSON)"
PID="$(echo "$BODY" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"id"[^"]*"([^"]+)"/\1/')"
[[ -n "$PID" ]] && ok "Patient id: $PID" || fail "could not extract id"

# ── Automatic narrative generation ───────────────────────────────────────────
# NARRATIVE_ENABLED=true (see docker-compose.xml-narrative.yml) makes the server
# inject a human-readable XHTML text.div during create/update.
say "Narrative — resource carries an auto-generated text.div"
req GET "$BASE_URL/Patient/$PID" -H 'Accept: application/fhir+json'
check_status 200 "read Patient (JSON)"
contains '"text"'   "resource has a text element"
contains '"status"' "text.status present"
contains 'http://www.w3.org/1999/xhtml' "text.div is XHTML-namespaced"

# ── 7.1  Accept: application/fhir+xml → XML response ─────────────────────────
say "7.1 — Accept: application/fhir+xml → XML response"
req GET "$BASE_URL/Patient/$PID" -H 'Accept: application/fhir+xml'
check_status 200 "GET with Accept=xml"
[[ "$CT" == *"application/fhir+xml"* ]] && ok "Content-Type is application/fhir+xml" \
  || fail "Content-Type=$CT, want application/fhir+xml"
contains '<?xml' "body starts with XML preamble"
contains '<Patient xmlns="http://hl7.org/fhir">' "Patient root element"

# ── 7.2  ?_format=xml query parameter → XML response ─────────────────────────
say "7.2 — ?_format=xml query parameter → XML response"
req GET "$BASE_URL/Patient/$PID?_format=xml" -H 'Accept: application/fhir+json'
check_status 200 "GET with _format=xml"
[[ "$CT" == *"application/fhir+xml"* ]] && ok "Content-Type is XML via query param" \
  || fail "Content-Type=$CT, want application/fhir+xml"

# ── 7.3  POST an XML resource → server reads XML ─────────────────────────────
say "7.3 — POST Content-Type=application/fhir+xml → server reads XML"
req POST "$BASE_URL/Patient" \
  -H 'Content-Type: application/fhir+xml' \
  -H 'Accept: application/fhir+xml' \
  --data @"$DIR/patient.xml"
check_status 201 "POST XML body"
XML_PID="$(echo "$BODY" | grep -oE '<id value="[^"]+"' | head -1 | sed -E 's/<id value="([^"]+)"/\1/')"
[[ -n "$XML_PID" ]] && ok "XML-POSTed Patient id: $XML_PID" || fail "could not extract id from XML"

# ── 7.4  XML-created resource is searchable ──────────────────────────────────
say "7.4 — search finds the XML-created Patient (format-transparent storage)"
req GET "$BASE_URL/Patient?family=XML-Created" -H 'Accept: application/fhir+json'
check_status 200 "search family=XML-Created"
contains '"total"' "search Bundle has a total"
echo "$BODY" | grep -qE '"total"[[:space:]]*:[[:space:]]*[1-9]' \
  && ok "at least one match" || fail "expected >=1 match"

say "XML + Narrative demo PASSED"
