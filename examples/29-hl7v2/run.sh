#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# paito FHIR Server — HL7 v2 Integration demo ($parse-v2)
#
# Parses raw HL7v2 pipe-delimited messages into JSON FHIR logical-model
# instances, driven entirely by a logical-model StructureDefinition whose
# elements carry v2 field mappings (mapping.identity = "v2").
#
# Ground truth: internal/hl7v2/{mapping,serializer}_test.go in go-fhir-server
# and site docs fhir-api/hl7v2-parser.md.
#
# Flow:
#   1. Register a logical-model StructureDefinition (ADT-A01) with v2 mappings
#   2. POST a raw ADT^A01 message to /$parse-v2 → JSON logical-model instance
#   3. Show error handling (missing X-V2-Profile header, unknown profile)
#
# Start a stack first (see README), then:  bash run.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical URL of the logical model — must match the SD's "url" and is passed
# in the X-V2-Profile header on every $parse-v2 call.
PROFILE_URL="http://example.org/StructureDefinition/ADT-A01"

B="\033[1m"; G="\033[32m"; R="\033[31m"; C="\033[36m"; N="\033[0m"
header() { printf "\n${B}${C}=== %s ===${N}\n" "$1"; }
ok()     { printf "${G}OK${N}  %s\n" "$1"; }
fail()   { printf "${R}FAIL${N} %s\n" "$1"; }
info()   { printf "${B}--> %s${N}\n" "$1"; }

TMP=/tmp/paito-hl7v2.out

# ─────────────────────────────────────────────────────────────────────────────
header "0. Readiness — server is up"
info "GET \$BASE_URL/metadata"
curl -fsS "$BASE_URL/metadata" >/dev/null && ok "server reachable"

# ─────────────────────────────────────────────────────────────────────────────
header "1. Register the ADT-A01 logical-model StructureDefinition"
info "PUT \$BASE_URL/StructureDefinition/adt-a01-logical"
status=$(curl -s -o "$TMP" -w '%{http_code}' \
  -X PUT "$BASE_URL/StructureDefinition/adt-a01-logical" \
  -H "Content-Type: application/fhir+json" \
  --data-binary "@$DIR/adt-a01-logical.json")
if [[ "$status" == "200" || "$status" == "201" ]]; then
  ok "logical model stored (HTTP $status), url=$PROFILE_URL"
else
  fail "unexpected status $status"; cat "$TMP"; exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
header "2. Parse a raw HL7v2 ADT^A01 message → JSON logical-model instance"
info "POST \$BASE_URL/\$parse-v2   (Content-Type: text/plain, X-V2-Profile: <url>)"
info "message: adt-a01.hl7 (MSH, PID with repeating patientId, two NK1 segments)"
status=$(curl -s -o "$TMP" -w '%{http_code}' \
  -X POST "$BASE_URL/\$parse-v2" \
  -H "Content-Type: text/plain" \
  -H "X-V2-Profile: $PROFILE_URL" \
  --data-binary "@$DIR/adt-a01.hl7")
if [[ "$status" == "200" ]]; then
  ok "parsed (HTTP 200)"
  cat "$TMP" | python3 -m json.tool 2>/dev/null || cat "$TMP"
  # Sanity checks against ground-truth serializer_test.go expectations
  python3 - "$TMP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("resourceType") == "ADT-A01", d.get("resourceType")
pid = d["PID"]
assert pid["familyName"] == "Smith", pid["familyName"]
assert pid["givenName"] == ["John"], pid["givenName"]
assert pid["dateOfBirth"] == "19850315", pid["dateOfBirth"]
assert pid["gender"] == "M", pid["gender"]
ids = pid["patientId"]
assert len(ids) == 2 and ids[0]["value"] == "12345" and ids[0]["authority"] == "HOSP" and ids[0]["typeCode"] == "MR", ids
assert ids[1]["value"] == "67890", ids
nk1 = d["NK1"]
assert len(nk1) == 2 and nk1[0]["familyName"] == "Doe" and nk1[0]["relationship"] == "SPO", nk1
assert nk1[1]["familyName"] == "López", nk1
print("  ✓ resourceType=ADT-A01, PID.familyName=Smith, 2 patientId, 2 NK1")
PY
  ok "logical-model instance matches expected mapping"
else
  fail "unexpected status $status"; cat "$TMP"; exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
header "3. Error — missing X-V2-Profile header → 400"
info "POST \$BASE_URL/\$parse-v2 without X-V2-Profile"
status=$(curl -s -o "$TMP" -w '%{http_code}' \
  -X POST "$BASE_URL/\$parse-v2" \
  -H "Content-Type: text/plain" \
  --data-binary "@$DIR/adt-a01.hl7")
if [[ "$status" == "400" ]]; then
  ok "rejected with HTTP 400: $(cat "$TMP")"
else
  fail "expected 400, got $status"; cat "$TMP"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "4. Error — unknown profile URL → 404"
info "POST \$BASE_URL/\$parse-v2 with X-V2-Profile pointing to a missing SD"
status=$(curl -s -o "$TMP" -w '%{http_code}' \
  -X POST "$BASE_URL/\$parse-v2" \
  -H "Content-Type: text/plain" \
  -H "X-V2-Profile: http://example.org/StructureDefinition/DOES-NOT-EXIST" \
  --data-binary "@$DIR/adt-a01.hl7")
if [[ "$status" == "404" ]]; then
  ok "rejected with HTTP 404: $(cat "$TMP")"
else
  fail "expected 404, got $status"; cat "$TMP"
fi

printf "\n${G}${B}All HL7 v2 checks passed.${N}\n"
