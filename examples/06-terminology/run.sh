#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Paito FHIR Server — Terminology Service demo
# ─────────────────────────────────────────────────────────────────────────────
# Derived from the proven e2e-terminology-smoke.sh. Exercises the FHIR R4
# terminology operations against the EMBEDDED R4 packages that ship in the
# image (core ValueSets + UCUM + ISO 3166-1) — no licensed data files needed.
#
# Prereq:  docker compose -f docker-compose.terminology.yml up -d
# Run:     bash examples/06-terminology/run.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON="Content-Type: application/fhir+json"

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$1"; }
note() { printf '   %s\n' "$1"; }

# GET helper: prints status + body
get() {
  local url=$1
  local code
  code=$(curl -s -o /tmp/tx-out -w '%{http_code}' "$url")
  note "HTTP $code"
  cat /tmp/tx-out
  echo
}

# ── 0. Readiness ─────────────────────────────────────────────────────────────
say "0. Wait for the server + terminology index (ISO 3166 loads asynchronously)"
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "$BASE_URL/CodeSystem/\$lookup?system=urn:iso:std:iso:3166&code=CL" || true)
  if [[ "$code" == "200" ]]; then note "terminology ready (~${i}s)"; break; fi
  [[ $i -eq 60 ]] && { echo "server/terminology not ready after 60s" >&2; exit 1; }
  sleep 1
done

# ── 1. Confirm operations are advertised in the CapabilityStatement ──────────
say "1. CapabilityStatement advertises the terminology operations"
curl -s "$BASE_URL/metadata" | grep -o '"name":"\(expand\|lookup\|validate-code\|subsumes\|translate\)"' | sort -u

# ── 2. ValueSet/\$expand ─────────────────────────────────────────────────────
say "2. \$expand a built-in ValueSet (administrative-gender) -> 4 codes"
note "expect male / female / other / unknown, expansion.total = 4"
get "$BASE_URL/ValueSet/\$expand?url=http://hl7.org/fhir/ValueSet/administrative-gender"

say "3. \$expand with filter=female -> only the matching code"
get "$BASE_URL/ValueSet/\$expand?url=http://hl7.org/fhir/ValueSet/administrative-gender&filter=female"

say "4. \$expand with count=2 -> bounded result (paging)"
get "$BASE_URL/ValueSet/\$expand?url=http://hl7.org/fhir/ValueSet/administrative-gender&count=2"

say "5. \$expand an unknown ValueSet -> 400 not found"
get "$BASE_URL/ValueSet/\$expand?url=http://example.org/this-vs-does-not-exist"

# ── 3. CodeSystem/\$lookup ───────────────────────────────────────────────────
say "6. \$lookup kg in UCUM -> display=kilogram + properties"
get "$BASE_URL/CodeSystem/\$lookup?system=http://unitsofmeasure.org&code=kg"

say "7. \$lookup CL in ISO 3166-1 -> Chile"
get "$BASE_URL/CodeSystem/\$lookup?system=urn:iso:std:iso:3166&code=CL"

say "8. \$lookup an unknown UCUM code -> 404 not-found"
get "$BASE_URL/CodeSystem/\$lookup?system=http://unitsofmeasure.org&code=THIS_IS_NOT_A_UCUM_CODE"

# ── 4. Custom ValueSet + \$validate-code ─────────────────────────────────────
say "9. Create a custom ValueSet over the embedded ISO 3166-1 CodeSystem"
note "POST ValueSet (idempotent: 201 first run, 200 update on reruns)"
curl -s -o /tmp/tx-out -w 'HTTP %{http_code}\n' \
  -X POST "$BASE_URL/ValueSet" -H "$JSON" \
  --data-binary @"$DIR/valueset-latam-countries.json"

say "10. \$expand the custom ValueSet -> 4 LATAM codes (CL/AR/MX/BR)"
get "$BASE_URL/ValueSet/\$expand?url=http://example.org/fhir/ValueSet/latam-countries"

say "11. \$validate-code CL (in the VS) -> result=true"
get "$BASE_URL/ValueSet/\$validate-code?url=http://example.org/fhir/ValueSet/latam-countries&system=urn:iso:std:iso:3166&code=CL"

say "12. \$validate-code US (outside the VS) -> result=false + message"
get "$BASE_URL/ValueSet/\$validate-code?url=http://example.org/fhir/ValueSet/latam-countries&system=urn:iso:std:iso:3166&code=US"

say "13. \$validate-code via POST with a Parameters body (coding AR) -> result=true"
get_post() {
  curl -s -o /tmp/tx-out -w '%{http_code}' -X POST "$BASE_URL/ValueSet/\$validate-code" \
    -H "$JSON" --data-binary @"$DIR/validate-code-parameters.json"
}
note "HTTP $(get_post)"; cat /tmp/tx-out; echo

# ── 5. $closure (durable subsumption session) ────────────────────────────────
say "14. \$closure — initialize a named closure session"
note "Returns a ConceptMap for the session (PostgreSQL-backed = durable)."
curl -s -o /tmp/tx-out -w 'HTTP %{http_code}\n' \
  -X POST "$BASE_URL/\$closure" -H "$JSON" \
  --data-binary @"$DIR/closure-init.json"
cat /tmp/tx-out; echo

# NOTE — hierarchy-dependent operations ($subsumes, ISA $expand, multilingual
# designations) and $translate need real clinical code systems (SNOMED CT,
# LOINC, ICD-10, FONASA). Load them via the opt-in block in
# docker-compose.terminology.yml, then see docs/terminology.md for examples.
say "Done."
note "\$subsumes / \$translate / SNOMED ISA \$expand require loaded clinical"
note "code systems — see docs/terminology.md (Configuration + References)."
