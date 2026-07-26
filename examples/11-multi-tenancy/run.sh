#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# paito FHIR Server — Multi-Tenancy isolation demo
# ══════════════════════════════════════════════════════════════════════════════
# Proves tenant data isolation end-to-end over plain HTTP using the X-Tenant-ID
# header. Two tenants — tenant-a and tenant-b — are driven purely by the header.
# NOTHING created under one tenant is readable, searchable, deletable, or
# version-visible under the other, while the SAME logical id can coexist
# independently in both. Derived from go-fhir-server/scripts/e2e-tenancy-smoke.sh.
#
# Prereq: docker compose -f docker-compose.multitenancy.yml up -d
# Run:    bash examples/11-multi-tenancy/run.sh
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
HEALTH_URL="${BASE_URL%/fhir/r4}/health"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TA="tenant-a"
TB="tenant-b"
MARK="tn-$(date +%s)"
JSON='Content-Type: application/fhir+json'

pass() { printf '  \033[32m✔\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# code METHOD TENANT URL [body-file] → prints HTTP status, body to /tmp/mt.json
code() {
  local method=$1 tenant=$2 url=$3 file=${4:-}
  local args=(-s -X "$method" -o /tmp/mt.json -w '%{http_code}' -H "X-Tenant-ID: $tenant")
  [[ -n "$file" ]] && args+=(-H "$JSON" --data-binary "@$file")
  curl "${args[@]}" "$url"
}
jqf() { python3 -c "import json,sys;print(json.load(open('/tmp/mt.json'))$1)"; }

CREATED_A=(); CREATED_B=()
cleanup() {
  local rc=$?
  echo; echo "── Cleanup"
  for id in "${CREATED_A[@]+${CREATED_A[@]}}"; do curl -s -H "X-Tenant-ID: $TA" -X DELETE "$BASE_URL/Patient/$id" >/dev/null || true; done
  for id in "${CREATED_B[@]+${CREATED_B[@]}}"; do curl -s -H "X-Tenant-ID: $TB" -X DELETE "$BASE_URL/Patient/$id" >/dev/null || true; done
  pass "removed ${#CREATED_A[@]} tenant-a + ${#CREATED_B[@]} tenant-b Patients"
  exit "$rc"
}
trap cleanup EXIT INT TERM

echo "▶ Pre-flight: FHIR endpoint reachable"
curl -fsS --max-time 3 "$BASE_URL/metadata" >/dev/null || die "paito not reachable at $BASE_URL — is the multitenancy compose up?"
pass "metadata responding"

echo
echo "▶ Step 1 — Public endpoints are reachable WITHOUT a tenant"
S=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/metadata"); [[ $S == 200 ]] && pass "GET /metadata (no tenant) → 200 (public)" || die "metadata → $S"
S=$(curl -s -o /dev/null -w '%{http_code}' "$HEALTH_URL");       [[ $S == 200 ]] && pass "GET /health   (no tenant) → 200 (public)" || die "health → $S"

echo
echo "▶ Step 1b — Tenant presence + format enforced on DATA endpoints"
S=$(curl -s -o /tmp/mt.json -w '%{http_code}' "$BASE_URL/Patient")
[[ $S == 401 ]] && pass "GET /Patient with NO X-Tenant-ID → 401" || die "expected 401, got $S"
grep -q '"code":"security"' /tmp/mt.json && pass "OperationOutcome issue.code=security" || die "missing security issue"
S=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Tenant-ID: bad id with spaces' "$BASE_URL/Patient")
[[ $S == 401 ]] && pass "malformed X-Tenant-ID (spaces) → 401" || die "expected 401, got $S"
S=$(code GET "$TA" "$BASE_URL/Patient")
[[ $S == 200 ]] && pass "GET /Patient with valid X-Tenant-ID → 200" || die "expected 200, got $S"

echo
echo "▶ Step 2 — Read isolation: a resource created in A is invisible to B"
sed "s/__MARK__/$MARK/" "$DIR/patient-tenant-a.json" > /tmp/mt-a.json
S=$(code POST "$TA" "$BASE_URL/Patient" /tmp/mt-a.json)
[[ $S == 201 ]] && pass "POST Patient in tenant-a → 201" || die "create in A → $S"
PID=$(jqf "['id']"); CREATED_A+=("$PID")
S=$(code GET "$TA" "$BASE_URL/Patient/$PID"); [[ $S == 200 ]] && pass "A reads its own Patient/$PID → 200" || die "A read → $S"
S=$(code GET "$TB" "$BASE_URL/Patient/$PID"); [[ $S == 404 ]] && pass "B reads same id → 404 (isolated)" || die "B read → $S (want 404)"

echo
echo "▶ Step 3 — Search isolation: searchset scoped to the requesting tenant"
S=$(code GET "$TA" "$BASE_URL/Patient?identifier=http://example.org/tenant|$MARK-read")
T=$(jqf ".get('total',0)"); [[ $S == 200 && $T == 1 ]] && pass "A search by identifier → total=1" || die "A search → $S total=$T"
S=$(code GET "$TB" "$BASE_URL/Patient?identifier=http://example.org/tenant|$MARK-read")
T=$(jqf ".get('total',0)"); [[ $S == 200 && $T == 0 ]] && pass "B same search → total=0 (A's data not searchable)" || die "B search → $S total=$T"

echo
echo "▶ Step 4 — Mutation isolation: B cannot delete a resource it cannot see"
S=$(code POST "$TA" "$BASE_URL/Patient" "$DIR/patient-del.json")
[[ $S == 201 ]] && pass "POST A-only Patient → 201" || die "create A-only → $S"
DID=$(jqf "['id']"); CREATED_A+=("$DID")
S=$(code DELETE "$TB" "$BASE_URL/Patient/$DID"); [[ $S == 404 ]] && pass "B DELETE that id → 404 (nothing to delete in B)" || die "B delete → $S"
S=$(code GET "$TA" "$BASE_URL/Patient/$DID"); [[ $S == 200 ]] && pass "A still reads it → 200 (survived B's delete)" || die "A read after → $S"

echo
echo "▶ Step 5 — Coexistence: the SAME logical id lives independently per tenant"
FID="$MARK-coexist"
printf '{"resourceType":"Patient","id":"%s","name":[{"family":"OwnerA"}]}' "$FID" > /tmp/mt-fa.json
printf '{"resourceType":"Patient","id":"%s","name":[{"family":"OwnerB"}]}' "$FID" > /tmp/mt-fb.json
S=$(code PUT "$TA" "$BASE_URL/Patient/$FID" /tmp/mt-fa.json); [[ $S == 201 ]] && pass "PUT id in A (OwnerA) → 201" || die "A put → $S"; CREATED_A+=("$FID")
S=$(code PUT "$TB" "$BASE_URL/Patient/$FID" /tmp/mt-fb.json); [[ $S == 201 ]] && pass "PUT same id in B (OwnerB) → 201 (independent row)" || die "B put → $S"; CREATED_B+=("$FID")
code GET "$TA" "$BASE_URL/Patient/$FID" >/dev/null; FA=$(jqf "['name'][0]['family']"); [[ $FA == OwnerA ]] && pass "A reads OwnerA" || die "A read $FA"
code GET "$TB" "$BASE_URL/Patient/$FID" >/dev/null; FB=$(jqf "['name'][0]['family']"); [[ $FB == OwnerB ]] && pass "B reads OwnerB (no overwrite, no leak)" || die "B read $FB"

echo
echo "▶ Step 6 — Version & history isolation"
S=$(code POST "$TA" "$BASE_URL/Patient" "$DIR/patient-hist.json"); [[ $S == 201 ]] && pass "create in A → 201" || die "create → $S"
HID=$(jqf "['id']"); CREATED_A+=("$HID")
printf '{"resourceType":"Patient","id":"%s","name":[{"family":"HistA2"}],"birthDate":"1999-09-09"}' "$HID" > /tmp/mt-h2.json
S=$(code PUT "$TA" "$BASE_URL/Patient/$HID" /tmp/mt-h2.json); [[ $S == 200 ]] && pass "update in A → 200 (now 2 versions)" || die "update → $S"
code GET "$TA" "$BASE_URL/Patient/$HID/_history" >/dev/null; T=$(jqf ".get('total',0)")
[[ $T -ge 2 ]] && pass "A instance _history total=$T (≥2)" || die "A history total=$T"
S=$(code GET "$TB" "$BASE_URL/Patient/$HID/_history/1"); [[ $S == 404 ]] && pass "B vread of A's version 1 → 404 (version isolated)" || die "B vread → $S"
code GET "$TB" "$BASE_URL/Patient/$HID/_history" >/dev/null; T=$(jqf ".get('total',0)")
[[ $T == 0 ]] && pass "B _history of A's id → total=0 (no versions leaked)" || die "B history leaked $T entries"

echo
echo "✅ Multi-tenancy isolation demonstrated — read·search·delete·version·history all scoped to X-Tenant-ID"
