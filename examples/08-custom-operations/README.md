# 08 — Custom Operations (extension point)

This example demonstrates paito's custom-operation extension point using the
shipped reference operation **`$example-echo`**. It walks the full lifecycle:
the operation is *defined* by an `OperationDefinition` served as a FHIR resource
(`GET /OperationDefinition/example-echo`), *declared* in the server's
`CapabilityStatement` (`GET /metadata`), and *invocable* over HTTP
(`POST /$example-echo`) — both with a raw resource body plus a query parameter
and with the general FHIR `Parameters` input form. It also shows the error path
where an empty body returns a `400 OperationOutcome`. `$example-echo` is a
template meant to be replaced by your own Go handler for real use.

## How to run

```bash
# From the repo root — start the stack with the custom-operations overlay
docker compose -f docker-compose.custom-operations.yml up -d

# Run the examples
bash examples/08-custom-operations/run.sh
```

Override the target with `BASE_URL` if needed, e.g.
`BASE_URL=http://localhost:3500/fhir/r4 bash examples/08-custom-operations/run.sh`.
