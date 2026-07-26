#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# 16 — Binary Resource (raw upload / download)
# Derived from the FHIR Binary native-handling behavior in
# go-fhir-server (internal/transport/http/handlers_binary.go) and the
# FHIR REST API docs (fhir-api/crud.md — "Binary Resources").
#
# The FHIR Binary resource has dual wire behavior per https://hl7.org/fhir/R4/binary.html:
#   - POST/PUT with a NON-FHIR Content-Type → the request body IS the raw
#     content; the server wraps it into a Binary resource (contentType +
#     base64 data). An X-Security-Context header sets securityContext.reference.
#   - GET with a NON-FHIR (or absent) Accept → the RAW decoded bytes with the
#     stored contentType. A FHIR Accept returns the Binary resource JSON.
#
# Usage:
#   docker compose -f docker-compose.yml up -d      # from repo root
#   bash examples/16-binary/run.sh
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

say()   { printf '\n\033[1;36m== %s\033[0m\n' "$1"; }
check() { # check EXPECTED LABEL   (compares $STATUS)
  if [[ "$STATUS" == "$1" ]]; then printf '  \033[32mok\033[0m  %s → %s\n' "$2" "$STATUS"
  else printf '  \033[31mFAIL\033[0m %s → %s (want %s)\n' "$2" "$STATUS" "$1"; echo "$BODY"; exit 1; fi
}

# ───────────────────────────────────────────────────────────────────────────
say "1) POST a raw text file as a Binary (non-FHIR Content-Type → wrapped)"
# Body is raw text; server wraps it: contentType=text/plain, data=base64(body).
# X-Security-Context populates Binary.securityContext.reference.
STATUS="$(curl -s -o "$BODY_FILE" -w '%{http_code}' \
  -X POST "$BASE_URL/Binary" \
  -H "Content-Type: text/plain" \
  -H "X-Security-Context: Patient/example" \
  --data-binary @"$DIR/note.txt")"
BODY="$(cat "$BODY_FILE")"
check 201 "raw create wrapped into Binary"
RAW_ID="$(printf '%s' "$BODY" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
echo "  → Binary id: $RAW_ID"
echo "  → response resource (note contentType + securityContext):"
printf '%s\n' "$BODY" | head -c 400; echo

# ───────────────────────────────────────────────────────────────────────────
say "2) GET the Binary as RAW bytes (non-FHIR Accept → decoded content)"
# Accept: text/plain (a non-FHIR media type) yields the raw decoded bytes,
# served as Content-Disposition: attachment with the stored contentType.
STATUS="$(curl -s -o "$BODY_FILE" -w '%{http_code}' \
  "$BASE_URL/Binary/$RAW_ID" \
  -H "Accept: text/plain")"
BODY="$(cat "$BODY_FILE")"
check 200 "raw download"
echo "  → raw body (decoded, not FHIR JSON):"
printf '%s\n' "$BODY"

say "2b) Inspect the defensive response headers on the raw path"
curl -s -D - -o /dev/null "$BASE_URL/Binary/$RAW_ID" -H "Accept: text/plain" \
  | grep -i -E '^(Content-Type|Content-Disposition|Content-Length|X-Content-Type-Options|Vary):' \
  | sed 's/^/  /'

# ───────────────────────────────────────────────────────────────────────────
say "3) GET the SAME Binary as the FHIR resource (FHIR Accept → JSON)"
# Accept: application/fhir+json returns the Binary resource with base64 data
# and the securityContext set from step 1's X-Security-Context header.
STATUS="$(curl -s -o "$BODY_FILE" -w '%{http_code}' \
  "$BASE_URL/Binary/$RAW_ID" \
  -H "Accept: application/fhir+json")"
BODY="$(cat "$BODY_FILE")"
check 200 "read as FHIR Binary resource"
echo "  → FHIR resource JSON (base64 data + securityContext):"
printf '%s\n' "$BODY" | head -c 500; echo

# ───────────────────────────────────────────────────────────────────────────
say "4) _format overrides Accept — request raw via ?_format on a FHIR Accept"
# _format=text/plain is a non-FHIR format and wins over the FHIR Accept header.
STATUS="$(curl -s -o "$BODY_FILE" -w '%{http_code}' \
  "$BASE_URL/Binary/$RAW_ID?_format=text/plain" \
  -H "Accept: application/fhir+json")"
BODY="$(cat "$BODY_FILE")"
check 200 "raw via _format override"
echo "  → body: $BODY"

# ───────────────────────────────────────────────────────────────────────────
say "5) PUT /Binary/{id} with a raw JPEG body (update-as-raw, URL id)"
# A non-FHIR Content-Type on PUT also wraps: the URL id is used as the resource id.
PUT_ID="binary-example-$$"
STATUS="$(curl -s -o "$BODY_FILE" -w '%{http_code}' \
  -X PUT "$BASE_URL/Binary/$PUT_ID" \
  -H "Content-Type: application/pdf" \
  --data-binary $'%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF')"
BODY="$(cat "$BODY_FILE")"
# 201 (created) or 200 (updated) both acceptable for update-as-create
if [[ "$STATUS" == "201" || "$STATUS" == "200" ]]; then
  printf '  \033[32mok\033[0m  %s → %s\n' "raw PUT wrapped into Binary" "$STATUS"
else
  printf '  \033[31mFAIL\033[0m %s → %s (want 200/201)\n' "raw PUT" "$STATUS"; echo "$BODY"; exit 1
fi
echo "  → fetch back as raw PDF bytes:"
STATUS="$(curl -s -o "$BODY_FILE" -w '%{http_code}' "$BASE_URL/Binary/$PUT_ID" -H "Accept: application/pdf")"
BODY="$(cat "$BODY_FILE")"
check 200 "raw PDF download"
printf '  → first bytes: %s\n' "$(printf '%s' "$BODY" | head -c 8)"

# ───────────────────────────────────────────────────────────────────────────
say "6) POST a NATIVE FHIR Binary resource (FHIR Content-Type → stored as-is)"
# A FHIR Content-Type means the body is already a Binary resource; no wrapping.
STATUS="$(curl -s -o "$BODY_FILE" -w '%{http_code}' \
  -X POST "$BASE_URL/Binary" \
  -H "Content-Type: application/fhir+json" \
  --data-binary @"$DIR/binary-fhir.json")"
BODY="$(cat "$BODY_FILE")"
check 201 "native FHIR Binary create"
NAT_ID="$(printf '%s' "$BODY" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
echo "  → Binary id: $NAT_ID"
echo "  → fetch back as raw bytes (decodes the base64 data):"
STATUS="$(curl -s -o "$BODY_FILE" -w '%{http_code}' "$BASE_URL/Binary/$NAT_ID" -H "Accept: text/plain")"
BODY="$(cat "$BODY_FILE")"
check 200 "raw download of native Binary"
echo "  → $BODY"

say "Done — Binary raw upload/download + securityContext demonstrated."
