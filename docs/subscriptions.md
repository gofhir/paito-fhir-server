# Subscriptions (R5 Backport + Event Brokers)

**What it is** — paito implements FHIR **Subscriptions** using the
[R5 Backport IG](http://hl7.org/fhir/uv/subscriptions-backport/) pattern on R4. Resource
changes are captured via PostgreSQL Change Data Capture (CDC), matched against
`SubscriptionTopic` definitions (7 built-ins plus any you register), evaluated against
per-subscription filters, and delivered to subscribers over a notification channel
(`rest-hook`, `websocket`, or `email`). Between the CDC source and the delivery engine
sits a pluggable event broker — **NATS** (embedded), **RabbitMQ**, or **Kafka**.

**When to use it**

- Push notifications to an integration engine or downstream app when Patients,
  Encounters, Observations, Conditions, or MedicationRequests change.
- Topic-based (R5) subscriptions that narrow delivery with `canFilterBy` filters
  (e.g. only a given patient's Observations, or only `status=finished` Encounters).
- Fan resource-change events into an existing messaging fabric (RabbitMQ AMQP, Kafka
  streams/replay) for event-driven pipelines.
- Real-time WebSocket push to browser/desktop clients.

> **Requires PostgreSQL.** Subscriptions rely on the `fhir_resource_events` CDC table
> (PostgreSQL triggers). MongoDB is not supported for subscriptions. The channel engine
> (`rest-hook`, `websocket`, `email`) and all three brokers are implemented.

## Launch

The bundled [`docker-compose.subscriptions.yml`](../docker-compose.subscriptions.yml)
runs PostgreSQL (CDC) + RabbitMQ (broker) with the subscription engine enabled:

```bash
docker compose -f docker-compose.subscriptions.yml up -d

# readiness check
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
```

- FHIR API: `http://localhost:3500/fhir/r4`
- Admin API: `http://localhost:3501`
- RabbitMQ Management UI: `http://localhost:15672` (guest/guest)

To use a different broker, change `BROKER_DRIVER` (see Configuration). NATS is embedded —
no extra container needed; Kafka needs its own broker container.

## Examples

Runnable end-to-end: [`examples/12-subscriptions/`](../examples/12-subscriptions/) — start
the stack, then `bash run.sh`.

**1. Create a rest-hook Subscription (R4 criteria).** The `criteria` is a search string;
`Patient?` matches every Patient change.

```bash
curl -X POST http://localhost:3500/fhir/r4/Subscription \
  -H 'Content-Type: application/fhir+json' \
  -d '{
    "resourceType": "Subscription",
    "status": "requested",
    "reason": "Monitor patient changes",
    "criteria": "Patient?",
    "channel": {
      "type": "rest-hook",
      "endpoint": "https://client.example.org/notify",
      "payload": "application/fhir+json",
      "header": ["Authorization: Bearer my-webhook-token"]
    }
  }'
# → 201 Created; the engine activates it immediately (lifecycle hook).
```

**2. Filtered criteria — only vital-signs Observations.**

```bash
curl -X POST http://localhost:3500/fhir/r4/Subscription \
  -H 'Content-Type: application/fhir+json' \
  -d '{
    "resourceType": "Subscription",
    "status": "requested",
    "criteria": "Observation?category=vital-signs",
    "channel": { "type": "rest-hook",
      "endpoint": "https://client.example.org/obs", "payload": "application/fhir+json" }
  }'
# → 201 Created; only vital-signs Observation changes are delivered.
```

**3. Query subscription state — `$status` operation.**

```bash
curl http://localhost:3500/fhir/r4/Subscription/<id>/\$status
# R4 → OperationOutcome with diagnostics: status=active, channel=rest-hook, errors=0, events=N
# R5 → SubscriptionStatus { type: "query-status", status, topic, eventsSinceSubscriptionStart }
```

**4. Register a SubscriptionTopic over REST (R5 Backport).** Topics become available to
subscriptions immediately — no restart. `canFilterBy` declares which filters subscribers
may apply.

```bash
curl -X POST http://localhost:3500/fhir/r4/SubscriptionTopic \
  -H 'Content-Type: application/fhir+json' \
  -d '{
    "resourceType": "SubscriptionTopic",
    "url": "https://example.org/SubscriptionTopic/vital-signs",
    "title": "New Vital-Signs Observation",
    "status": "active",
    "resourceTrigger": [
      { "resource": "Observation", "supportedInteraction": ["create", "update"] }
    ],
    "canFilterBy": [
      { "resource": "Observation", "filterParameter": "patient" },
      { "resource": "Observation", "filterParameter": "code" }
    ]
  }'
# → 201 Created; a stored topic with the same url overrides a built-in one.
```

**5. Subscribe to a topic (R5-shape, filtered).** On an R5 server the `topic` + `filterBy`
fields drive matching. A `filterBy` whose `(resourceType, filterParameter)` is not declared
in the topic's `canFilterBy` sets the subscription to `status=error`.

```bash
curl -X POST http://localhost:3500/fhir/r4/Subscription \
  -H 'Content-Type: application/fhir+json' \
  -d '{
    "resourceType": "Subscription",
    "status": "requested",
    "topic": "https://example.org/SubscriptionTopic/vital-signs",
    "channelType": { "code": "rest-hook" },
    "endpoint": "https://client.example.org/vitals",
    "content": "full-resource",
    "filterBy": [
      { "resourceType": "Observation", "filterParameter": "patient", "value": "Patient/123" }
    ]
  }'
```

**6. Built-in topics** (always available; reference them by canonical URL):

| Topic URL | Resource | Interactions |
|-----------|----------|--------------|
| `http://hl7.org/SubscriptionTopic/patient-changes` | Patient | create, update, delete |
| `http://hl7.org/SubscriptionTopic/encounter-changes` | Encounter | create, update, delete |
| `http://hl7.org/SubscriptionTopic/observation-changes` | Observation | create, update, delete |
| `http://hl7.org/SubscriptionTopic/condition-changes` | Condition | create, update, delete |
| `http://hl7.org/SubscriptionTopic/medicationrequest-changes` | MedicationRequest | create, update, delete |
| `http://hl7.org/SubscriptionTopic/encounter-start` | Encounter | create |
| `http://hl7.org/SubscriptionTopic/all-resource-changes` | * (wildcard) | create, update, delete |

**7. Deactivate / search / delete.**

```bash
curl http://localhost:3500/fhir/r4/Subscription?status=active     # search
curl -X PUT http://localhost:3500/fhir/r4/Subscription/<id> \
  -H 'Content-Type: application/fhir+json' -d '{ ... "status": "off" ... }'   # disable
curl -X DELETE http://localhost:3500/fhir/r4/Subscription/<id>    # remove
```

## Configuration

Environment variables (exact names from `internal/config/config_env.go`):

| Env var | Applies to | Example / default | Description |
|---------|-----------|-------------------|-------------|
| `SUBSCRIPTION_ENABLED` | engine | `true` | Activate the subscription engine (default off). |
| `SUBSCRIPTION_POLL_INTERVAL` | engine | `1s` | CDC poll cadence. |
| `SUBSCRIPTION_BATCH_SIZE` | engine | `100` | Max events processed per poll cycle. |
| `SUBSCRIPTION_EMAIL_SMTP_HOST` | email channel | — | SMTP host for the email channel. |
| `SUBSCRIPTION_EMAIL_SMTP_PORT` | email channel | `587` | SMTP port. |
| `SUBSCRIPTION_EMAIL_FROM` | email channel | — | From address for notifications. |
| `SUBSCRIPTION_EMAIL_USERNAME` | email channel | — | SMTP auth username. |
| `SUBSCRIPTION_EMAIL_PASSWORD` | email channel | — | SMTP auth password. |
| `BROKER_DRIVER` | broker | `nats` \| `rabbitmq` \| `kafka` | Event broker implementation. |
| `BROKER_INCLUDE_PAYLOAD` | broker | `false` | Include the resource payload in broker events. |
| `BROKER_PUBLISH_TIMEOUT` | broker | `2s` | Publish timeout. |
| `BROKER_NATS_STORE_DIR` | NATS | (empty = in-memory) | JetStream store dir for embedded NATS. |
| `BROKER_NATS_MAX_PAYLOAD` | NATS | `1048576` | Max NATS message size (bytes). |
| `BROKER_RABBITMQ_URL` | RabbitMQ | `amqp://guest:guest@rabbitmq:5672/` | AMQP connection URL. |
| `BROKER_RABBITMQ_EXCHANGE` | RabbitMQ | `fhir.events` | Exchange name. |
| `BROKER_RABBITMQ_EXCHANGE_TYPE` | RabbitMQ | `topic` | Exchange type. |
| `BROKER_RABBITMQ_DURABLE` | RabbitMQ | `true` | Persist queues/messages to disk. |
| `BROKER_KAFKA_BROKERS` | Kafka | `localhost:19092` | Comma-separated bootstrap brokers. |
| `BROKER_KAFKA_TOPIC_PREFIX` | Kafka | `fhir-events` | Kafka topic name. |
| `BROKER_KAFKA_NUM_PARTITIONS` | Kafka | `3` | Partition count. |
| `BROKER_KAFKA_REPLICATION_FACTOR` | Kafka | `1` | Replication factor. |
| `BROKER_KAFKA_REQUIRED_ACKS` | Kafka | `1` | Producer acks (`-1` = all replicas). |
| `STORAGE_DRIVER` | storage | `postgres` | Must be `postgres` — subscriptions need CDC triggers. |

Notification channels supported: `rest-hook` (HTTP POST), `websocket` (R5 bind flow),
`email` (SMTP). Delivery retries up to `maxRetries` (default 3) consecutive failures
before the subscription transitions to `status=error`; a successful retry resets the
counter. In multi-tenant deployments, subscriptions and topics are scoped per tenant.

## References

- go-fhir-server docs — Subscriptions overview: `site/content/en/docs/subscriptions/_index.md`
- go-fhir-server docs — Topics (`SubscriptionTopic`, `canFilterBy`): `site/content/en/docs/subscriptions/topics.md`
- go-fhir-server docs — Channels (rest-hook, websocket, heartbeat, retry): `site/content/en/docs/subscriptions/channels.md`
- go-fhir-server docs — Brokers (NATS / RabbitMQ / Kafka): `site/content/en/docs/subscriptions/brokers.md`
- go-fhir-server docs — Configuration + PostgreSQL schema: `site/content/en/docs/subscriptions/configuration.md`
- go-fhir-server docs — Subscription module reference: `site/content/en/docs/modules/subscription/_index.md`
- FHIR R5 Subscriptions Backport IG: http://hl7.org/fhir/uv/subscriptions-backport/
