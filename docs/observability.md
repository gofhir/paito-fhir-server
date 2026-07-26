# Observability (OpenTelemetry + Grafana stack)

**What it is** — A complete, standards-based observability pipeline built on
OpenTelemetry. The paito FHIR server emits three signals — distributed **traces**,
**metrics**, and structured **logs** — through a single OTLP export to an
OpenTelemetry Collector, which fans them out to purpose-built backends: **Tempo**
for traces, **Prometheus** for metrics, and **Loki** for logs. **Grafana** ties them
together for querying and correlation. All telemetry is off by default and enabled
through `OTEL_*` environment variables.

**When to use it**

- Trace a single FHIR request end to end (HTTP handling, storage query, validation, terminology, search indexing) to find latency hot spots.
- Watch request rate, latency percentiles and error rate over time in Prometheus/Grafana.
- Aggregate and search structured JSON logs across restarts and correlate a log line back to its trace.
- Run a demo-grade Grafana + Tempo + Prometheus + Loki stack next to the server without wiring it yourself.

## Launch

The stack is defined in [`docker-compose.observability.yml`](../docker-compose.observability.yml)
(paito + postgres + otel-collector + tempo + loki + prometheus + grafana). Collector,
Tempo, Loki and Prometheus read their config from the mounted files in
[`config/`](../config) (`otel-collector.yaml`, `tempo.yaml`, `loki.yaml`, `prometheus.yaml`).

```bash
docker compose -f docker-compose.observability.yml up -d

# readiness check
curl -s http://localhost:3500/fhir/r4/metadata | head -c 200
```

Host-exposed endpoints: FHIR API `:3500`, Admin `:3501`, OTLP gRPC/HTTP `:4317`/`:4318`,
Prometheus `:9090`, Grafana `:3000` (admin / admin). Tempo (`:3200`) and Loki (`:3100`)
are reachable only on the internal Docker network.

## Examples

Full runnable script: [`examples/27-observability/run.sh`](../examples/27-observability/run.sh).

Generate traffic — each request produces a trace, metrics and a log line:

```bash
# Create a Patient (201). Every FHIR call is instrumented automatically.
curl -s -X POST http://localhost:3500/fhir/r4/Patient \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/27-observability/patient.json
# -> 201 Created, a new Patient with a server-assigned id and a matching trace in Tempo
```

```bash
# A deliberate miss produces an error span and an error-level log.
curl -s -o /dev/null -w '%{http_code}\n' \
  http://localhost:3500/fhir/r4/Patient/does-not-exist-xyz
# -> 404
```

Metrics — Prometheus receives them via the Collector's remote_write exporter:

```bash
# target_info carries the service.name resource attribute.
curl -s 'http://localhost:9090/api/v1/query?query=target_info{service_name="paito-fhir-server"}'
# -> {"status":"success",...,"metric":{"service_name":"paito-fhir-server",...}}

# List the metric names that arrived from the server.
curl -s 'http://localhost:9090/api/v1/label/__name__/values'
# -> {"status":"success","data":["http_server_...","target_info",...]}
```

Traces — Tempo is internal, so query it from inside its container:

```bash
docker exec paito-tempo \
  wget -qO- 'http://localhost:3200/api/search?tags=service.name%3Dpaito-fhir-server&limit=5'
# -> {"traces":[{"traceID":"...","rootServiceName":"paito-fhir-server",...}]}
```

Logs — Loki is internal; list labels and query recent lines:

```bash
docker exec paito-loki wget -qO- 'http://localhost:3100/loki/api/v1/labels'
# -> {"status":"success","data":["exporter","service_name",...]}
```

Grafana — open http://localhost:3000 (admin / admin). This stack ships Grafana
without provisioned datasources; add three under **Connections > Data sources**
pointing at `http://prometheus:9090`, `http://tempo:3200`, `http://loki:3100`, then
use **Explore** to browse each signal.

## Configuration

All telemetry is disabled unless the `OTEL_*` variables are set. Names come from the
server's env → config map (`internal/config/config_env.go`).

| Env var | config.yaml path | Default | Purpose |
|---|---|---|---|
| `OTEL_TRACING_ENABLED` | `observability.tracing.enabled` | `false` | Enable distributed tracing |
| `OTEL_TRACING_EXPORTER` | `observability.tracing.exporter` | `otlp` | `otlp` or `stdout` |
| `OTEL_TRACING_ENDPOINT` | `observability.tracing.endpoint` | `localhost:4317` | OTLP gRPC endpoint of the Collector |
| `OTEL_TRACING_SERVICE_NAME` | `observability.tracing.serviceName` | `gofhir-server` | Service name attached to traces |
| `OTEL_METRICS_ENABLED` | `observability.metrics.enabled` | `false` | Enable metrics export |
| `OTEL_METRICS_PORT` | `observability.metrics.port` | `9090` | In-process Prometheus metrics port |
| `OTEL_LOGS_ENABLED` | `observability.logs.enabled` | `false` | Enable structured log export |
| `OTEL_LOGS_EXPORTER` | `observability.logs.exporter` | `otlp` | `otlp` or `stdout` |
| `OTEL_LOGS_ENDPOINT` | `observability.logs.endpoint` | `localhost:4317` | OTLP gRPC endpoint for logs |

In `docker-compose.observability.yml` the paito service enables all three signals and
points them at the Collector (`OTEL_TRACING_ENDPOINT` / `OTEL_LOGS_ENDPOINT` =
`otel-collector:4317`, `OTEL_TRACING_SERVICE_NAME=paito-fhir-server`). The Collector
then forwards traces to Tempo (OTLP gRPC), logs to Loki, and metrics to Prometheus via
remote write — see [`config/otel-collector.yaml`](../config/otel-collector.yaml).

For a collector-free local setup, set the exporters to `stdout` to print traces and
logs to the console.

## References

- go-fhir-server site docs: `site/content/en/docs/deployment/observability.md`
- Module docs: `site/content/en/docs/modules/observability/_index.md`
- Collector / backend configs: `config/otel-collector.yaml`, `config/tempo.yaml`, `config/loki.yaml`, `config/prometheus.yaml`
