#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Paito FHIR Server — Validation, Profiles & Implementation Guides
# ─────────────────────────────────────────────────────────────────────────────
# Derived from go-fhir-server scripts/e2e-conformance-smoke.sh.
#
# Demonstrates $validate against US Core 5.0.1 and IPS 1.1.0 (installed from
# packages.fhir.org by the GitOps reconciler at boot):
#   • a fully-conforming US Core Patient → no errors
#   • required cardinality enforced from the profile (identifier 1..*)
#   • profile invariants (us-core-6: name.family OR name.given)
#   • required terminology binding (Patient.gender → administrative-gender)
#   • a conforming IPS Patient
#   • per-call ?profile= override (same resource, two profiles, two outcomes)
#   • $validate via the FHIR Parameters wrapper
#
# Launch first:
#   docker compose -f docker-compose.validation-ig.yml up -d
#
# Then:
#   bash examples/05-validation-ig/run.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
ADMIN_URL="${ADMIN_URL:-http://localhost:3501}"
ADMIN_KEY="${ADMIN_API_KEY:-paito-validation-key}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

hr()  { printf '\n─── %s ───\n' "$1"; }
note(){ printf '    %s\n' "$1"; }

# validate <json-file> [query]  → POST to $validate, print issue summary
validate() {
  local file="$1" query="${2:-}"
  local url="$BASE_URL/Patient/\$validate${query}"
  local body status
  body="$(mktemp)"
  status=$(curl -s -o "$body" -w '%{http_code}' \
    -X POST "$url" \
    -H 'Content-Type: application/fhir+json' \
    --data-binary "@${file}")
  note "HTTP $status (\$validate always returns 200 with an OperationOutcome)"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.issue[]? | "    [\(.severity)] \(.code): \((.diagnostics // "")[0:140])"' "$body" || cat "$body"
  else
    cat "$body"; echo
  fi
  rm -f "$body"
}

# ── Pre-flight ───────────────────────────────────────────────────────────────
hr "Pre-flight: FHIR endpoint reachable"
curl -fsS --max-time 5 "$BASE_URL/metadata" >/dev/null
note "metadata OK at $BASE_URL"

# ── Step 1: confirm both IGs were installed by GitOps at boot ────────────────
hr "Step 1: IGs installed (admin API GET /api/packages)"
curl -fsS -H "Authorization: Bearer $ADMIN_KEY" "$ADMIN_URL/api/packages" \
  | { command -v jq >/dev/null 2>&1 && jq -r '.packages[]? | "    \(.name) \(.version)"' || cat; }
note "expect: hl7.fhir.us.core 5.0.1 and hl7.fhir.uv.ips 1.1.0"

# ── Step 1b: discover installed profiles via standard FHIR REST ──────────────
hr "Step 1b: profile discovery — GET /StructureDefinition?url=us-core-patient"
curl -fsS "$BASE_URL/StructureDefinition?url=http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient" \
  | { command -v jq >/dev/null 2>&1 && jq -r '.entry[0].resource | "    \(.id)  type=\(.type)  base=\(.baseDefinition)"' || cat; }

# ── Step 2: conforming US Core Patient → no errors ───────────────────────────
hr "Step 2: conforming US Core Patient (identifier + race + ethnicity + name + gender)"
note "Expected: only information/warning issues, 0 errors"
validate "$DIR/patient-uscore-valid.json"

# ── Step 3: required cardinality enforced from profile ───────────────────────
hr "Step 3: US Core Patient WITHOUT identifier → identifier 1..* error"
note "Expected: an error mentioning Patient.identifier (required)"
validate "$DIR/patient-uscore-missing-identifier.json"

# ── Step 4: profile invariant ────────────────────────────────────────────────
hr "Step 4: name with use only, no family/given → us-core-6 invariant"
note "Expected: an error referencing constraint us-core-6"
validate "$DIR/patient-uscore-badname.json"

# ── Step 5: required terminology binding ─────────────────────────────────────
hr "Step 5: gender='unicorn' (not in administrative-gender ValueSet)"
note "Expected: a code-invalid error referencing the bound ValueSet"
validate "$DIR/patient-uscore-badgender.json"

# ── Step 6: conforming IPS Patient (international baseline) ───────────────────
hr "Step 6: conforming IPS Patient (Patient-uv-ips, Latin-American identifier)"
note "Expected: 0 errors"
validate "$DIR/patient-ips-valid.json"

# ── Step 7: per-call ?profile= override — same resource, two outcomes ────────
hr "Step 7.1: minimal Patient, ?profile=IPS → conforming (0 errors)"
validate "$DIR/patient-minimal.json" "?profile=http://hl7.org/fhir/uv/ips/StructureDefinition/Patient-uv-ips"

hr "Step 7.2: SAME minimal Patient, ?profile=US-Core → identifier 1..* error"
validate "$DIR/patient-minimal.json" "?profile=http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"

# ── Step 8: $validate via the FHIR Parameters wrapper ────────────────────────
hr "Step 8: \$validate via Parameters (resource + profile parameters)"
note "Expected: same Patient.identifier error as the URL-param form"
validate "$DIR/validate-parameters.json"

printf '\n✔ Done. $validate exercised against US Core + IPS profiles.\n'
