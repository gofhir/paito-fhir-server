#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# 17 — GraphQL API
# Query and mutate FHIR resources through the dynamically-generated GraphQL
# schema. Every query/mutation below mirrors an example from the go-fhir-server
# GraphQL reference (site/content/en/docs/fhir-api/graphql.md).
#
# Endpoints exercised:
#   POST /graphql                          system-level queries + mutations
#   GET  /graphql                          Playground UI (introspection)
#   POST /fhir/r4/{Type}/{id}/$graphql     instance-level query root
#
# Usage:
#   docker compose -f docker-compose.graphql.yml up -d      # from repo root
#   bash examples/17-graphql/run.sh
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"   # FHIR REST base (seeding + $graphql)
GQL_URL="${GQL_URL:-http://localhost:3500/graphql}"     # dedicated GraphQL endpoint (root)
CT='Content-Type: application/json'
FCT='Content-Type: application/fhir+json'
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

STATUS=""; BODY=""
say()  { printf '\n\033[1;36m== %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32mok\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; echo "$BODY"; exit 1; }

# Build a {"query": "..."} JSON payload from a raw GraphQL document.
# Queries here contain no backslashes; escape embedded quotes, flatten newlines.
gql_payload() {
  local q="$1"
  q="${q//\"/\\\"}"
  q="${q//$'\n'/ }"
  printf '{"query":"%s"}' "$q"
}

# gql URL RAW_GRAPHQL → POST payload, sets STATUS + BODY
gql() {
  local url="$1" raw="$2"
  STATUS="$(curl -s -X POST -o "$BODY_FILE" -w '%{http_code}' -H "$CT" \
    --data-binary "$(gql_payload "$raw")" "$url")"
  BODY="$(cat "$BODY_FILE")"
}

# ---------------------------------------------------------------------------
say "0. Server readiness (REST capability statement)"
STATUS="$(curl -s -o "$BODY_FILE" -w '%{http_code}' "$BASE_URL/metadata")"
[[ "$STATUS" == "200" ]] || { echo "server not ready ($STATUS)"; exit 1; }
ok "GET /metadata → 200"

# ---------------------------------------------------------------------------
say "1. Schema introspection — discover the GraphQL query/mutation roots"
gql "$GQL_URL" '{ __schema { queryType { name } mutationType { name } } }'
[[ "$STATUS" == "200" ]] || fail "introspection POST /graphql → $STATUS"
echo "$BODY" | grep -q '"queryType"' && ok "__schema introspection returned query/mutation types"

# ---------------------------------------------------------------------------
say "2. Seed data via REST (Organization + Patient) for the GraphQL queries"
STATUS="$(curl -s -X POST -o "$BODY_FILE" -w '%{http_code}' -H "$FCT" \
  --data-binary "@$DIR/organization.json" "$BASE_URL/Organization")"
[[ "$STATUS" == "201" ]] || { BODY="$(cat "$BODY_FILE")"; fail "POST /Organization → $STATUS"; }
ORG_ID="$(grep -o '"id":"[^"]*"' "$BODY_FILE" | head -1 | cut -d'"' -f4)"
ok "Organization created: $ORG_ID"

# ---------------------------------------------------------------------------
say "3. Mutation — PatientCreate (with managingOrganization → the seeded Org)"
gql "$GQL_URL" "mutation {
  PatientCreate(res: {
    resourceType: \"Patient\"
    identifier: [{ use: \"official\" system: \"http://hospital.example.org/mrn\" value: \"MRN-77123\" }]
    name: [{ use: \"official\" family: \"Garcia\" given: [\"Maria\", \"Elena\"] }]
    gender: \"female\"
    birthDate: \"1990-05-15\"
    managingOrganization: { reference: \"Organization/$ORG_ID\" display: \"General Hospital\" }
  }) {
    id
    meta { versionId lastUpdated }
    name { family given }
  }
}"
[[ "$STATUS" == "200" ]] || fail "PatientCreate → $STATUS"
PID="$(echo "$BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
echo "$BODY" | grep -q '"family":"Garcia"' || fail "PatientCreate did not echo family"
ok "PatientCreate returned id=$PID (versionId 1)"

# ---------------------------------------------------------------------------
say "4. Read a single resource — Patient(id: ...) with field selection"
gql "$GQL_URL" "query {
  Patient(id: \"$PID\") {
    id
    resourceType
    meta { versionId lastUpdated }
    name { family given }
    gender
    birthDate
  }
}"
[[ "$STATUS" == "200" ]] || fail "Patient(id) → $STATUS"
echo "$BODY" | grep -q '"gender":"female"' && ok "Patient(id) selected exactly the requested fields"

# ---------------------------------------------------------------------------
say "5. Search (List API) — PatientList(name, gender) returns a Bundle-shaped result"
gql "$GQL_URL" '{
  PatientList(name: "Garcia", gender: "female", _count: 10) {
    total
    entry { fullUrl resource { id name { family given } gender } }
    link { relation url }
  }
}'
[[ "$STATUS" == "200" ]] || fail "PatientList → $STATUS"
echo "$BODY" | grep -q '"total"' && ok "PatientList returned total + entry[]"

# ---------------------------------------------------------------------------
say "6. Search (Connection API) — cursor-based pagination with edges + next"
gql "$GQL_URL" '{
  PatientConnection(name: "Garcia", _count: 10) {
    count offset pagesize
    edges { mode score resource { id name { family } gender } }
    first previous next last
  }
}'
[[ "$STATUS" == "200" ]] || fail "PatientConnection → $STATUS"
echo "$BODY" | grep -q '"edges"' && ok "PatientConnection returned edges[] + cursor fields"

# ---------------------------------------------------------------------------
say "7. Reference resolution — inline-load managingOrganization via DataLoader"
gql "$GQL_URL" "query {
  Patient(id: \"$PID\") {
    id
    name { family }
    managingOrganization {
      reference
      display
      resource { ... on Organization { id name address { city state country } } }
    }
  }
}"
[[ "$STATUS" == "200" ]] || fail "reference resolution → $STATUS"
echo "$BODY" | grep -q '"name":"General Hospital"' && ok "Referenced Organization resolved inline"

# ---------------------------------------------------------------------------
say "8. Directive @first — unwrap the first element of a repeating field"
gql "$GQL_URL" "{ Patient(id: \"$PID\") { name @first { family given } } }"
[[ "$STATUS" == "200" ]] || fail "@first directive → $STATUS"
ok "name @first executed (single object instead of array)"

# ---------------------------------------------------------------------------
say "9. Field-level fhirpath filter — return only names with use = 'official'"
gql "$GQL_URL" "{ Patient(id: \"$PID\") { name(fhirpath: \"use = 'official'\") { use family } } }"
[[ "$STATUS" == "200" ]] || fail "fhirpath field arg → $STATUS"
echo "$BODY" | grep -q '"family":"Garcia"' && ok "fhirpath field filter applied per-field"

# ---------------------------------------------------------------------------
say "10. History query — instance version history via PatientHistory"
gql "$GQL_URL" "query {
  PatientHistory(id: \"$PID\", _count: 5) {
    total
    entry {
      fullUrl
      resource { id meta { versionId } name { family } }
      request { method url }
      response { status etag }
    }
  }
}"
[[ "$STATUS" == "200" ]] || fail "PatientHistory → $STATUS"
echo "$BODY" | grep -q '"total"' && ok "PatientHistory returned versioned entries"

# ---------------------------------------------------------------------------
say "11. Instance-level \$graphql — resource fields available at the query root"
STATUS="$(curl -s -X POST -o "$BODY_FILE" -w '%{http_code}' -H "$CT" \
  --data-binary '{"query": "{ name { family given } gender birthDate }"}' \
  "$BASE_URL/Patient/$PID/\$graphql")"
BODY="$(cat "$BODY_FILE")"
[[ "$STATUS" == "200" ]] || fail "instance \$graphql → $STATUS"
echo "$BODY" | grep -q '"gender":"female"' && ok "POST /Patient/$PID/\$graphql resolved root fields"

# ---------------------------------------------------------------------------
say "12. Mutation — PatientUpdate (version bumps to 2)"
gql "$GQL_URL" "mutation {
  PatientUpdate(id: \"$PID\", res: {
    resourceType: \"Patient\"
    id: \"$PID\"
    name: [{ use: \"official\" family: \"Garcia-Lopez\" given: [\"Maria\", \"Elena\"] }]
    gender: \"female\"
  }) {
    id
    meta { versionId }
    name { family }
  }
}"
[[ "$STATUS" == "200" ]] || fail "PatientUpdate → $STATUS"
echo "$BODY" | grep -q '"versionId":"2"' && ok "PatientUpdate bumped versionId to 2"

# ---------------------------------------------------------------------------
say "13. GraphQL errors ride in the 'errors' array with HTTP 200 (not 4xx)"
gql "$GQL_URL" "{ Patient(id: \"$PID\") { notAFhirField } }"
[[ "$STATUS" == "200" ]] || fail "expected HTTP 200 for a GraphQL validation error, got $STATUS"
echo "$BODY" | grep -q '"errors"' && ok "Unknown field reported in errors[] (HTTP still 200)"

# ---------------------------------------------------------------------------
say "14. Mutation — PatientDelete returns true"
gql "$GQL_URL" "mutation { PatientDelete(id: \"$PID\") }"
[[ "$STATUS" == "200" ]] || fail "PatientDelete → $STATUS"
echo "$BODY" | grep -q '"PatientDelete":true' && ok "PatientDelete returned true"

printf '\n\033[1;32mAll GraphQL examples completed.\033[0m\n'
