#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# paito FHIR Server — Subscriptions (R5 Backport) demo
#
# Exercises the FHIR Subscription lifecycle managed over REST, plus the
# SubscriptionTopic registry and CDC-driven event pipeline. The stack for this
# example (docker-compose.subscriptions.yml) runs PostgreSQL (CDC source) +
# RabbitMQ (event broker) with SUBSCRIPTION_ENABLED=true and BROKER_DRIVER=rabbitmq.
#
# Endpoints and payloads are derived from the go-fhir-server subscription REST
# suite (test/http/subscription-patient-create.http) and the subscription module
# source (built-in topics, $status operation, canFilterBy validation).
#
# The rest-hook endpoints below point at an unreachable host on purpose: this
# script demonstrates the deterministic, server-side REST lifecycle (create /
# read / $status / search / update / delete) and the event pipeline — not a live
# webhook receiver. Actual delivery to a real endpoint is shown in the docs.
#
# Start the stack first (see README), then:  bash run.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

B="\033[1m"; G="\033[32m"; Y="\033[33m"; C="\033[36m"; N="\033[0m"
header() { printf "\n${B}${C}=== %s ===${N}\n" "$1"; }
ok()     { printf "${G}OK${N}  %s\n" "$1"; }
info()   { printf "${B}--> %s${N}\n" "$1"; }
note()   { printf "${Y}note${N} %s\n" "$1"; }

# curl helper: METHOD URL [BODY-FILE]. Sets RESP_STATUS + RESP_BODY.
req() {
  local method=$1 url=$2 file=${3:-}
  local args=(-s -X "$method" -o /tmp/paito-sub.out -w '%{http_code}')
  [[ -n "$file" ]] && args+=(-H "Content-Type: application/fhir+json" --data-binary "@$file")
  RESP_STATUS=$(curl "${args[@]}" "$url")
  RESP_BODY=$(cat /tmp/paito-sub.out)
}

json_get() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null || true; }

# ─────────────────────────────────────────────────────────────────────────────
header "0. Readiness — server reachable"
for i in $(seq 1 30); do
  S=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$BASE_URL/metadata" 2>/dev/null || echo 000)
  [[ "$S" == "200" ]] && break
  [[ $i -eq 30 ]] && { echo "server not reachable at $BASE_URL"; exit 1; }
  sleep 1
done
ok "server reachable at $BASE_URL"

# ─────────────────────────────────────────────────────────────────────────────
header "1. Create a rest-hook Subscription (R4 criteria: Patient?)"
info "POST /Subscription  (criteria='Patient?', channel=rest-hook)"
req POST "$BASE_URL/Subscription" "$DIR/subscription-rest-hook.json"
echo "  HTTP $RESP_STATUS"
SUB_ID=$(echo "$RESP_BODY" | json_get "d.get('id','')")
[[ "$RESP_STATUS" == "201" || "$RESP_STATUS" == "200" ]] && ok "Subscription/$SUB_ID created"
echo "  status: $(echo "$RESP_BODY" | json_get "d.get('status')")"

# ─────────────────────────────────────────────────────────────────────────────
header "2. Read the Subscription back"
info "GET /Subscription/$SUB_ID"
req GET "$BASE_URL/Subscription/$SUB_ID"
echo "  HTTP $RESP_STATUS"
echo "  channel.type: $(echo "$RESP_BODY" | json_get "d.get('channel',{}).get('type')")"
echo "  channel.endpoint: $(echo "$RESP_BODY" | json_get "d.get('channel',{}).get('endpoint')")"
ok "resource fetched"

# ─────────────────────────────────────────────────────────────────────────────
header "3. Query subscription state — \$status operation"
info "GET /Subscription/$SUB_ID/\$status"
req GET "$BASE_URL/Subscription/$SUB_ID/\$status"
echo "  HTTP $RESP_STATUS"
# R4 returns an OperationOutcome carrying status/channel/errors/events;
# R5 returns a SubscriptionStatus resource.
echo "  resourceType: $(echo "$RESP_BODY" | json_get "d.get('resourceType')")"
echo "$RESP_BODY" | head -c 400; echo
[[ "$RESP_STATUS" == "200" ]] && ok "\$status returned the subscription state"

# ─────────────────────────────────────────────────────────────────────────────
header "4. Create a filtered Subscription (criteria: Observation?category=vital-signs)"
info "POST /Subscription  (only vital-signs Observations)"
req POST "$BASE_URL/Subscription" "$DIR/subscription-filtered.json"
echo "  HTTP $RESP_STATUS"
SUB2_ID=$(echo "$RESP_BODY" | json_get "d.get('id','')")
[[ "$RESP_STATUS" == "201" || "$RESP_STATUS" == "200" ]] && ok "Subscription/$SUB2_ID created (filtered)"

# ─────────────────────────────────────────────────────────────────────────────
header "5. Search subscriptions"
info "GET /Subscription?_summary=count"
req GET "$BASE_URL/Subscription?_summary=count"
echo "  HTTP $RESP_STATUS  total: $(echo "$RESP_BODY" | json_get "d.get('total')")"
ok "subscription registry is searchable"

# ─────────────────────────────────────────────────────────────────────────────
header "6. Manage a SubscriptionTopic over REST (R5 Backport)"
info "POST /SubscriptionTopic  (Observation trigger + canFilterBy patient/code/category)"
req POST "$BASE_URL/SubscriptionTopic" "$DIR/subscription-topic.json"
echo "  HTTP $RESP_STATUS"
if [[ "$RESP_STATUS" == "201" || "$RESP_STATUS" == "200" ]]; then
  TOPIC_ID=$(echo "$RESP_BODY" | json_get "d.get('id','')")
  ok "SubscriptionTopic/$TOPIC_ID registered (available to subscriptions immediately)"
  info "GET /SubscriptionTopic?url=https://example.org/SubscriptionTopic/vital-signs"
  req GET "$BASE_URL/SubscriptionTopic?url=https://example.org/SubscriptionTopic/vital-signs"
  echo "  HTTP $RESP_STATUS  total: $(echo "$RESP_BODY" | json_get "d.get('total')")"
else
  note "SubscriptionTopic type not installed on this server (HTTP $RESP_STATUS);"
  note "the 7 built-in topics still apply — see docs/subscriptions.md."
  TOPIC_ID=""
fi

# ─────────────────────────────────────────────────────────────────────────────
header "7. Generate CDC events (feed the broker)"
info "POST /Patient  -> emits a create event to the RabbitMQ 'fhir.events' exchange"
req POST "$BASE_URL/Patient" "$DIR/patient.json"
PID=$(echo "$RESP_BODY" | json_get "d.get('id','')")
ok "Patient/$PID created (HTTP $RESP_STATUS)"
info "POST /Observation (vital-signs) -> matches the filtered subscription's criteria"
req POST "$BASE_URL/Observation" "$DIR/observation-vitals.json"
OID=$(echo "$RESP_BODY" | json_get "d.get('id','')")
ok "Observation/$OID created (HTTP $RESP_STATUS)"
note "Inspect broker traffic in the RabbitMQ Management UI: http://localhost:15672 (guest/guest)."
note "rest-hook delivery targets an unreachable host here, so after maxRetries the"
note "subscription flips to status=error — expected for this offline demo."

# ─────────────────────────────────────────────────────────────────────────────
header "8. Deactivate a subscription (PUT status=off)"
info "PUT /Subscription/$SUB_ID  with status='off'"
python3 - "$DIR/subscription-rest-hook.json" "$SUB_ID" > /tmp/paito-sub-off.json <<'PY'
import json, sys
sub = json.load(open(sys.argv[1]))
sub["id"] = sys.argv[2]
sub["status"] = "off"
sub["reason"] = "Temporarily disabled"
json.dump(sub, open("/tmp/paito-sub-off.json", "w"))
PY
req PUT "$BASE_URL/Subscription/$SUB_ID" "/tmp/paito-sub-off.json"
echo "  HTTP $RESP_STATUS  status: $(echo "$RESP_BODY" | json_get "d.get('status')")"
[[ "$RESP_STATUS" == "200" ]] && ok "subscription disabled (status=off)"

# ─────────────────────────────────────────────────────────────────────────────
header "9. Cleanup — delete subscriptions and topic"
for id in "$SUB_ID" "$SUB2_ID"; do
  [[ -n "$id" ]] && { curl -s -o /dev/null -X DELETE "$BASE_URL/Subscription/$id"; echo "  deleted Subscription/$id"; }
done
[[ -n "${TOPIC_ID:-}" ]] && { curl -s -o /dev/null -X DELETE "$BASE_URL/SubscriptionTopic/$TOPIC_ID"; echo "  deleted SubscriptionTopic/$TOPIC_ID"; }
ok "cleanup done"

header "Done"
echo "Demonstrated: rest-hook Subscription create/read, \$status, filtered criteria,"
echo "              search, SubscriptionTopic REST management, CDC event generation"
echo "              (broker), status=off deactivation, and delete."
