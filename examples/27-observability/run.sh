#!/usr/bin/env bash
# ==============================================================================
# Observability demo — generate FHIR traffic, then confirm telemetry landed in
# the OpenTelemetry / Grafana stack (Tempo traces, Prometheus metrics, Loki logs).
#
# Launch the stack first:
#   docker compose -f docker-compose.observability.yml up -d
#
# Then run:
#   bash run.sh
#
# Host-reachable endpoints from the observability compose:
#   - FHIR API   http://localhost:3500/fhir/r4
#   - Admin API  http://localhost:3501
#   - Prometheus http://localhost:9090
#   - Grafana    http://localhost:3000   (admin / admin)
# Tempo (:3200) and Loki (:3100) run on the internal Docker network only, so this
# script queries them via `docker exec` into their containers.
# ==============================================================================
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3500/fhir/r4}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
TEMPO_CONTAINER="${TEMPO_CONTAINER:-paito-tempo}"
LOKI_CONTAINER="${LOKI_CONTAINER:-paito-loki}"
SERVICE_NAME="paito-fhir-server"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

hr()  { printf '\n\033[1;36m=== %s ===\033[0m\n' "$1"; }
ok()  { printf '\033[32m OK\033[0m %s\n' "$1"; }
info(){ printf '\033[33m  ~\033[0m %s\n' "$1"; }

# ------------------------------------------------------------------------------
hr "0. Readiness — CapabilityStatement"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/metadata")
[ "$code" = "200" ] && ok "GET /metadata -> $code" || { echo "server not ready ($code)"; exit 1; }

# ------------------------------------------------------------------------------
hr "1. Generate traffic — each request emits a trace, metrics and logs"

# Create a Patient (POST -> 201). Capture the assigned id.
PID=$(curl -s -X POST "$BASE_URL/Patient" \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @"$SCRIPT_DIR/patient.json" \
  | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
[ -n "$PID" ] && ok "POST /Patient -> Patient/$PID" || { echo "create failed"; exit 1; }

# Create an Observation that references the Patient.
sed "s#PATIENT_REFERENCE#Patient/$PID#" "$SCRIPT_DIR/observation.json" > "$SCRIPT_DIR/.observation.tmp.json"
OID=$(curl -s -X POST "$BASE_URL/Observation" \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @"$SCRIPT_DIR/.observation.tmp.json" \
  | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
rm -f "$SCRIPT_DIR/.observation.tmp.json"
[ -n "$OID" ] && ok "POST /Observation -> Observation/$OID" || info "observation create returned no id"

# A burst of reads / searches so the metric counters and trace list fill up.
for i in $(seq 1 8); do
  curl -s -o /dev/null "$BASE_URL/Patient/$PID"
  curl -s -o /dev/null "$BASE_URL/Patient?family=Telemetry"
  curl -s -o /dev/null "$BASE_URL/Observation?subject=Patient/$PID"
  curl -s -o /dev/null "$BASE_URL/Observation?code=http://loinc.org|8867-4"
done
ok "Drove 8x read + 3 searches to build up telemetry"

# One deliberate 404 to produce an error span / error-level log.
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/Patient/does-not-exist-xyz")
ok "GET /Patient/does-not-exist-xyz -> $code (error span + log)"

info "Waiting ~8s for the OTel Collector batch window (5s) to flush..."
sleep 8

# ------------------------------------------------------------------------------
hr "2. METRICS — Prometheus (host :9090)"
# Metrics travel Patio -> OTLP -> Collector -> remote_write -> Prometheus.
# target_info carries the service.name resource attribute.
target=$(curl -s "$PROM_URL/api/v1/query?query=target_info%7Bservice_name%3D%22$SERVICE_NAME%22%7D")
if echo "$target" | grep -q "$SERVICE_NAME"; then
  ok "Prometheus has target_info for service_name=\"$SERVICE_NAME\""
else
  info "target_info not visible yet: $target"
fi

# List a sample of metric names that arrived via remote write.
names=$(curl -s "$PROM_URL/api/v1/label/__name__/values")
count=$(echo "$names" | grep -oE '"[a-zA-Z_:][a-zA-Z0-9_:]*"' | wc -l | tr -d ' ')
ok "Prometheus knows $count metric names"
echo "$names" | grep -oE '"(http[^"]*|rpc[^"]*|target_info)"' | head -10 || true

# ------------------------------------------------------------------------------
hr "3. TRACES — Tempo (internal :3200, via docker exec)"
if command -v docker >/dev/null 2>&1; then
  traces=$(docker exec "$TEMPO_CONTAINER" \
    wget -qO- "http://localhost:3200/api/search?tags=service.name%3D$SERVICE_NAME&limit=5" 2>/dev/null || true)
  if echo "$traces" | grep -q traceID; then
    ok "Tempo returned recent traces for $SERVICE_NAME"
    echo "$traces" | grep -oE '"traceID":"[^"]+"' | head -5
  else
    info "No traces returned yet (Tempo may still be ingesting): $traces"
  fi
else
  info "docker not on PATH — open Grafana Explore > Tempo to view traces"
fi

# ------------------------------------------------------------------------------
hr "4. LOGS — Loki (internal :3100, via docker exec)"
if command -v docker >/dev/null 2>&1; then
  labels=$(docker exec "$LOKI_CONTAINER" \
    wget -qO- "http://localhost:3100/loki/api/v1/labels" 2>/dev/null || true)
  ok "Loki label names: $labels"
  # Query the last 5 minutes of log lines that carry the exporter label.
  end=$(date +%s)000000000
  start=$(( $(date +%s) - 300 ))000000000
  logs=$(docker exec "$LOKI_CONTAINER" \
    wget -qO- "http://localhost:3100/loki/api/v1/query_range?query=%7Bexporter%3D%22OTLP%22%7D&start=$start&end=$end&limit=5" 2>/dev/null || true)
  if echo "$logs" | grep -q '"values"'; then
    ok "Loki returned log lines exported from the FHIR server"
  else
    info "No log lines via {exporter=\"OTLP\"} yet — inspect labels above in Grafana Explore > Loki"
  fi
else
  info "docker not on PATH — open Grafana Explore > Loki to view logs"
fi

# ------------------------------------------------------------------------------
hr "Done"
echo "Grafana: http://localhost:3000  (admin / admin)"
echo "First add three datasources (Connections > Data sources) pointing at the"
echo "internal service URLs, then use Explore:"
echo "  Prometheus  ->  http://prometheus:9090   (PromQL over the metrics above)"
echo "  Tempo       ->  http://tempo:3200        (search by service.name=$SERVICE_NAME)"
echo "  Loki        ->  http://loki:3100         (LogQL over the FHIR server logs)"
echo "Prometheus UI (no setup needed): $PROM_URL"
