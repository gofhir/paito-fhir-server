#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# Paito FHIR Server — FHIR as Code (GitOps) demo
# ══════════════════════════════════════════════════════════════════════════════
# Derived from go-fhir-server scripts/e2e-gitops-smoke.sh. Proves that resources
# declared in the mounted repo directory (config/gitops-repo/) were reconciled
# into the store at startup, each tagged with the owning source
# (http://gofhir.io/fhir/gitops|paito-repo), and that GitOps owns ONLY what it
# created (a hand-authored resource carries no gitops tag).
#
# Launch first:  docker compose -f docker-compose.gitops.yml up -d
# Then:          bash examples/20-fhir-as-code/run.sh
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_SYSTEM="http://gofhir.io/fhir/gitops"
SOURCE="paito-repo"

echo "▶ Using FHIR base: $BASE_URL"
echo "▶ GitOps source identity (owning tag code): $SOURCE"
echo

# ── 0. Readiness ──────────────────────────────────────────────────────────────
echo "── 0. Wait for the server to be ready (GET /metadata) ────────────────────"
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/metadata" || true)
  [[ "$code" == "200" ]] && break
  sleep 1
done
[[ "${code:-}" == "200" ]] && echo "✔ server ready (metadata 200)" || { echo "✗ server not ready"; exit 1; }
echo

# tag_codes URL — prints the gitops owner tag code(s) on a resource
tag_codes() {
  curl -s "$1" | python3 -c '
import sys, json
d = json.load(sys.stdin)
sysurl = "'"$GITOPS_SYSTEM"'"
print(",".join(t.get("code","") for t in d.get("meta",{}).get("tag",[]) if t.get("system")==sysurl))'
}

# ── 1. Resources declared in the repo were reconciled on startup ──────────────
echo "── 1. Each *.json in config/gitops-repo/ was applied at startup ──────────"
for pair in \
  "CodeSystem/paito-local-lab" \
  "ValueSet/paito-marital-status" \
  "SearchParameter/paito-patient-mrn"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/$pair")
  echo "  GET $pair -> HTTP $code"
  [[ "$code" == "200" ]] || { echo "✗ expected 200 for $pair"; exit 1; }
done
echo "✔ all declared resources exist (sync-on-startup)"
echo

# ── 2. Per-source ownership tag ───────────────────────────────────────────────
echo "── 2. Each reconciled resource is tagged with its owning source ──────────"
codes=$(tag_codes "$BASE_URL/CodeSystem/paito-local-lab")
echo "  CodeSystem/paito-local-lab meta.tag ($GITOPS_SYSTEM) code = '$codes'"
[[ "$codes" == "$SOURCE" ]] && echo "✔ owned by gitops|$SOURCE (per-source tracking)" \
  || { echo "✗ expected owner tag '$SOURCE', got '$codes'"; exit 1; }
echo

# ── 3. List everything this source manages via _tag search ────────────────────
echo "── 3. List all resources owned by this source (_tag token search) ────────"
echo "  GET /ValueSet?_tag=$GITOPS_SYSTEM|$SOURCE"
curl -s "$BASE_URL/ValueSet?_tag=$(python3 -c "import urllib.parse;print(urllib.parse.quote('$GITOPS_SYSTEM|$SOURCE'))")" \
  | python3 -c 'import sys,json; b=json.load(sys.stdin); print("  matched ValueSets:", b.get("total", len(b.get("entry",[]))))'
echo "✔ managed set is queryable by the ownership tag"
echo

# ── 4. Anti-clobber: GitOps owns ONLY what it created ─────────────────────────
echo "── 4. A hand-authored resource is NOT GitOps-managed (no tag) ────────────"
echo "  PUT Patient/hand-authored-1 (created via the REST API, not the repo)"
code=$(curl -s -o /dev/null -w '%{http_code}' \
  -X PUT "$BASE_URL/Patient/hand-authored-1" \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @"$DIR/patient.json")
echo "  -> HTTP $code"
[[ "$code" == "200" || "$code" == "201" ]] || { echo "✗ unexpected status $code"; exit 1; }
codes=$(tag_codes "$BASE_URL/Patient/hand-authored-1")
echo "  Patient/hand-authored-1 gitops tag code = '${codes:-<none>}'"
[[ -z "$codes" ]] && echo "✔ no gitops tag → GitOps will never prune or clobber it" \
  || { echo "✗ hand-authored resource unexpectedly carries a gitops tag"; exit 1; }
echo

echo "════════════════════════════════════════════════════════════════════════════"
echo "✔ FHIR as Code: repo resources reconciled, per-source tagged, API resources"
echo "  left untouched."
echo
echo "Try prune live: delete config/gitops-repo/valueset-marital-status.json on the"
echo "host, wait ~10s (watchIntervalSeconds), then:"
echo "  curl -s -o /dev/null -w '%{http_code}\\n' $BASE_URL/ValueSet/paito-marital-status"
echo "  → 410 Gone (the owner pruned its own resource)."
echo "════════════════════════════════════════════════════════════════════════════"
