# 14 — Messaging (`$process-message`)

Demonstrates the FHIR R4 messaging paradigm on Paito. A `Bundle` of type
`message` is POSTed to `/fhir/r4/$process-message`; the server validates the
envelope (MessageHeader cardinalities), validates the Bundle against its declared
`meta.profile`, checks `MessageDefinition` focus cardinalities, then dispatches
to a `MessageProcessor`. This example uses the shipped **reference processor**
(`persistReference: true`), which persists each focus resource and replies
`response.code = "ok"`; it also shows envelope rejection (`400`), profile/focus
violations (`fatal-error`), and **async** delivery (`202` + `Content-Location`
poll). Requires `python3` for parsing reply Bundles.

## How to run

```bash
# From the repo root — this compose mounts config/messaging.yaml to enable messaging
docker compose -f docker-compose.messaging.yml up -d

# Wait until ready
curl -s http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

# Run the examples
bash examples/14-messaging/run.sh

# Tear down
docker compose -f docker-compose.messaging.yml down -v
```

Override the target with `BASE_URL`, e.g.
`BASE_URL=http://localhost:3500/fhir/r4 bash examples/14-messaging/run.sh`.
