# 12 — Subscriptions (R5 Backport + brokers)

This example demonstrates the paito server's FHIR **Subscriptions** engine: creating
rest-hook Subscriptions with R4 criteria, querying their state via the `$status`
operation, filtered criteria (`Observation?category=vital-signs`), searching the
subscription registry, managing a `SubscriptionTopic` over REST (R5 Backport IG,
including `canFilterBy`), and generating CDC events that flow to the configured event
broker (RabbitMQ). The subscription engine uses PostgreSQL as its Change Data Capture
source, so this stack always runs PostgreSQL plus a broker. Endpoints and payloads are
derived from the go-fhir-server subscription REST suite
(`test/http/subscription-patient-create.http`) and the subscription module source.

## How to run

Start the subscriptions stack (PostgreSQL + RabbitMQ, subscriptions + broker enabled):

```bash
docker compose -f docker-compose.subscriptions.yml up -d
# wait until ready:
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

bash run.sh
```

The RabbitMQ Management UI is available at http://localhost:15672 (guest/guest) — use it
to watch events published to the `fhir.events` exchange as the script creates resources.
Override the endpoint with `BASE_URL=http://localhost:3500/fhir/r4 bash run.sh` if you
mapped a different port.

See [`../../docs/subscriptions.md`](../../docs/subscriptions.md) for the full guide.
