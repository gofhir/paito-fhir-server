#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# paito FHIR Server — StructureMap $transform (FHIR Mapping Language) demo
#
# Derived from the proven go-fhir-server sources:
#   scripts/e2e-ops-sweep-smoke.sh   (§18.9 — $transform content/source contract)
#   internal/operations/transform.go + transform_test.go (Parameters body shape)
#   site/content/en/docs/fhir-api/transform.md (FML text upload, JSON StructureMap)
#
# The $transform operation applies a stored StructureMap to input content using
# the native FML engine. Source of the map is a canonical URL (type-level) or the
# StructureMap resource id (instance-level). The request body is a `Parameters`
# resource carrying `source` (valueUri) and `content` (the resource to transform).
#
# Start a stack first (see README), then:  bash run.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

B="\033[1m"; G="\033[32m"; R="\033[31m"; C="\033[36m"; N="\033[0m"
header() { printf "\n${B}${C}=== %s ===${N}\n" "$1"; }
ok()     { printf "${G}OK${N}  %s\n" "$1"; }
info()   { printf "${B}--> %s${N}\n" "$1"; }

# curl helper: METHOD URL [BODY-FILE] [CONTENT-TYPE]. Sets RESP_STATUS + RESP_BODY.
# Never uses -f, so the script keeps going and prints diagnostics on any status.
req() {
  local method=$1 url=$2 file=${3:-} ctype=${4:-application/fhir+json}
  local args=(-s -X "$method" -o /tmp/paito-fml.out -w '%{http_code}')
  [[ -n "$file" ]] && args+=(-H "Content-Type: $ctype" --data-binary "@$file")
  RESP_STATUS=$(curl "${args[@]}" "$url")
  RESP_BODY=$(cat /tmp/paito-fml.out)
}

# ─────────────────────────────────────────────────────────────────────────────
header "0. Readiness — CapabilityStatement advertises StructureMap \$transform"
info "GET \$BASE_URL/metadata"
curl -fsS "$BASE_URL/metadata" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);\
ops={o['name'] for r in d.get('rest',[]) for res in r.get('resource',[]) for o in res.get('operation',[])};\
print('  StructureMap resource ops advertised:', sorted(n for n in ops if 'transform' in n) or '(check server logs)')"
ok "server reachable"

# ─────────────────────────────────────────────────────────────────────────────
header "1. Upload a StructureMap (FHIR JSON format)"
info "POST /StructureMap  (PatientNormalize — copies name/gender/birthDate)"
req POST "$BASE_URL/StructureMap" "$DIR/structuremap-patient-normalize.json"
echo "  HTTP $RESP_STATUS"
[[ "$RESP_STATUS" == "201" || "$RESP_STATUS" == "200" ]] && ok "StructureMap stored (canonical url = .../PatientNormalize)"

info "GET /StructureMap?url=... — confirm it is resolvable by canonical URL"
req GET "$BASE_URL/StructureMap?url=http://example.org/fhir/StructureMap/PatientNormalize"
echo "  HTTP $RESP_STATUS"
echo "$RESP_BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);print('  Bundle total:', d.get('total'))" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
header "2. Upload a StructureMap written in FML text (Content-Type: text/fhir-mapping)"
info "POST /StructureMap  with FML source — server parses + stores it as JSON"
req POST "$BASE_URL/StructureMap" "$DIR/patient-normalize.fml" text/fhir-mapping
echo "  HTTP $RESP_STATUS"
if [[ "$RESP_STATUS" == "201" || "$RESP_STATUS" == "200" ]]; then
  echo "$RESP_BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);\
print('  stored resourceType:', d.get('resourceType'), ' url:', d.get('url'))" 2>/dev/null || true
  ok "FML text parsed and stored as a StructureMap JSON resource"
else
  echo "  (FML text upload returned $RESP_STATUS)"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "3. \$transform — type-level, source as query parameter"
info "POST /StructureMap/\$transform?source=<canonical-url>  (Parameters body carries content)"
req POST "$BASE_URL/StructureMap/\$transform?source=http://example.org/fhir/StructureMap/PatientNormalize" \
    "$DIR/content-only.json"
echo "  HTTP $RESP_STATUS"
if [[ "$RESP_STATUS" == "200" ]]; then
  echo "$RESP_BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);\
r=next((p.get('resource') for p in d.get('parameter',[]) if p.get('name')=='return'), d);\
print('  return resourceType:', r.get('resourceType'), ' name:', r.get('name'), ' gender:', r.get('gender'))" 2>/dev/null \
    || echo "  $RESP_BODY"
  ok "transform executed; result returned as Parameters(return)"
else
  echo "  body: $(echo "$RESP_BODY" | head -c 300)"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "4. \$transform — source AND content both inside the Parameters body"
info "POST /StructureMap/\$transform  (no query param; source is a Parameters valueUri)"
req POST "$BASE_URL/StructureMap/\$transform" "$DIR/transform-request.json"
echo "  HTTP $RESP_STATUS"
if [[ "$RESP_STATUS" == "200" ]]; then
  echo "$RESP_BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);\
r=next((p.get('resource') for p in d.get('parameter',[]) if p.get('name')=='return'), d);\
print('  return resourceType:', r.get('resourceType'), ' name:', r.get('name'))" 2>/dev/null \
    || echo "  $RESP_BODY"
  ok "transform executed from an all-in-one Parameters request"
else
  echo "  body: $(echo "$RESP_BODY" | head -c 300)"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "5. Contract checks (proven by e2e-ops-sweep-smoke.sh §18.9)"

info "5a. Missing content -> 400 with issue code 'required'"
RESP_STATUS=$(curl -s -o /tmp/paito-fml.out -w '%{http_code}' -X POST \
  -H 'Content-Type: application/fhir+json' \
  --data-binary '{"resourceType":"Parameters","parameter":[{"name":"source","valueUri":"http://example.org/fhir/StructureMap/PatientNormalize"}]}' \
  "$BASE_URL/StructureMap/\$transform")
echo "  HTTP $RESP_STATUS (expected 400)"
grep -q '"code":"required"' /tmp/paito-fml.out && ok "missing content rejected with code 'required'"

info "5b. Type-level with no source at all -> 400 'required'"
RESP_STATUS=$(curl -s -o /tmp/paito-fml.out -w '%{http_code}' -X POST \
  -H 'Content-Type: application/fhir+json' \
  --data-binary "@$DIR/content-only.json" \
  "$BASE_URL/StructureMap/\$transform")
echo "  HTTP $RESP_STATUS (expected 400)"
[[ "$RESP_STATUS" == "400" ]] && ok "type-level transform requires a source"

info "5c. Unknown StructureMap URL -> 404 or 422 (map cannot be resolved)"
RESP_STATUS=$(curl -s -o /tmp/paito-fml.out -w '%{http_code}' -X POST \
  -H 'Content-Type: application/fhir+json' \
  --data-binary '{"resourceType":"Parameters","parameter":[{"name":"source","valueUri":"http://example.org/fhir/StructureMap/DoesNotExist"},{"name":"content","resource":{"resourceType":"Patient"}}]}' \
  "$BASE_URL/StructureMap/\$transform")
echo "  HTTP $RESP_STATUS (expected 404 or 422)"
[[ "$RESP_STATUS" == "404" || "$RESP_STATUS" == "422" || "$RESP_STATUS" == "400" ]] && ok "unresolvable map rejected"

header "Done"
echo "Demonstrated: StructureMap upload (JSON + FML text), \$transform via query"
echo "              param and via Parameters body, and the content/source contract."
