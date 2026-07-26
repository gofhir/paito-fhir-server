# 27 - Observability (OpenTelemetry + Grafana stack)

This example drives normal FHIR traffic against the server and then shows the
resulting telemetry landing in the OpenTelemetry / Grafana backends. Every FHIR
request emits a **distributed trace** (stored in Tempo), **metrics** (remote-written
to Prometheus) and a **structured log line** (pushed to Loki), all originating from
the server's built-in `internal/observability` package via a single OTLP export to
the OpenTelemetry Collector. `run.sh` creates a Patient and a referencing
Observation, fires a burst of reads/searches plus one deliberate 404, waits for the
Collector's 5s batch window to flush, then queries Prometheus (host `:9090`) and
inspects Tempo/Loki inside their containers to prove the three signals arrived.

## How to run

```bash
# from the repo root — start the full observability stack
docker compose -f docker-compose.observability.yml up -d

# wait for the FHIR server, then run the demo
bash examples/27-observability/run.sh
```

Then open Grafana at http://localhost:3000 (admin / admin). Grafana starts with no
datasources in this stack, so add three (Connections > Data sources) pointing at the
internal URLs `http://prometheus:9090`, `http://tempo:3200`, `http://loki:3100`, and
use **Explore** to browse traces, metrics and logs. Prometheus is directly reachable
at http://localhost:9090 with no setup.
