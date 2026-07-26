# Custom Operations (extension point)

**What it is** — paito exposes a dynamic operations framework: FHIR operations
(`$name`) are registered at startup and driven by an `OperationDefinition`
resource. Each registered operation is served as a FHIR resource under
`/OperationDefinition/<id>`, advertised in the server `CapabilityStatement`
(`/metadata`), and invocable at `POST /$name`. paito ships a reference custom
operation, **`$example-echo`**, as a copy-paste template: enable it, exercise it,
then replace it with your own Go handler for real use. Custom operations are
wired in Go code at startup — they are **not** created over REST.

**When to use it**

- Expose domain-specific server behavior behind a standard FHIR `$operation`.
- Ship an `OperationDefinition` so clients can discover an operation's parameters
  and canonical URL.
- Prototype the operation contract (request/response shape, error path) before
  writing the production handler.
- Learn the Handler / ResourceHandler pattern from a minimal working example.

## Launch

`$example-echo` is enabled via `operations.exampleEcho: true`, which has no
environment-variable mapping, so this stack mounts a small overlay config
(`config/custom-operations.yaml`) and selects it with `CONFIG_PATH`.

```bash
docker compose -f docker-compose.custom-operations.yml up -d

# Readiness check (expect HTTP 200)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3500/fhir/r4/metadata
```

## Examples

All calls target the FHIR base `http://localhost:3500/fhir/r4`.

**1. The operation is served as a FHIR resource**

```bash
curl -s http://localhost:3500/fhir/r4/OperationDefinition/example-echo
```

Expected: `200` with an `OperationDefinition` whose `code` is `example-echo` and
`url` is `https://gofhir.dev/OperationDefinition/example-echo`.

**2. The operation is declared in the CapabilityStatement**

```bash
curl -s http://localhost:3500/fhir/r4/metadata | grep example-echo
```

Expected: the `rest.operation` array advertises `example-echo` with its
`definition` pointing to the canonical URL above.

**3. Invoke with a raw resource body plus a query parameter**

```bash
curl -s -X POST \
  -H 'Content-Type: application/fhir+json' \
  --data-binary '{"resourceType":"Patient","id":"p1","name":[{"family":"Custom"}]}' \
  'http://localhost:3500/fhir/r4/$example-echo?note=hello'
```

Expected: `200` with a `Parameters` resource that echoes the input Patient under
an `echo` parameter and the `note` string (`hello`) under a `note` parameter.

**4. Invoke with the general FHIR `Parameters` input form**

```bash
curl -s -X POST \
  -H 'Content-Type: application/fhir+json' \
  --data-binary '{"resourceType":"Parameters","parameter":[{"name":"resource","resource":{"resourceType":"Patient","id":"p2"}},{"name":"note","valueString":"wrapped"}]}' \
  'http://localhost:3500/fhir/r4/$example-echo'
```

Expected: `200`; the server unwraps the `Parameters` body and returns
`Parameters` echoing `Patient/p2` and `note = wrapped`.

**5. Error path — empty body**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H 'Content-Type: application/fhir+json' \
  'http://localhost:3500/fhir/r4/$example-echo'
```

Expected: `400` with an `OperationOutcome` in the body.

See [`examples/08-custom-operations/`](../examples/08-custom-operations/) for the
runnable `run.sh` covering all of the above.

## Configuration

| Config key (YAML) | Env var | Values | Purpose |
|---|---|---|---|
| `operations.exampleEcho` | *(none — YAML only)* | `true` / `false` (default `false`) | Registers the reference custom operation `$example-echo` |
| *(selects the overlay file)* | `CONFIG_PATH` | path, default `configs/config.yaml` | Points the server at the mounted config that enables the operation |
| `storage.driver` | `STORAGE_DRIVER` | `postgres`, `mongodb`, `sqlite`, `mysql`, `sqlserver` | Backend used by the server |
| — | `POSTGRES_HOST` / `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | strings | Postgres connection for this stack |
| `fhir.version` | `FHIR_VERSION` | `R4` | FHIR release |

Because environment variables have the highest precedence, the storage settings
above override the mounted overlay file, which only enables the operation.

## References

- Developer guide — Adding FHIR Operations:
  `site/content/en/docs/developer/adding-operations.md`
- FHIR API — Extensibility:
  `site/content/en/docs/fhir-api/extensibility.md`
- FHIR API — Operations reference:
  `site/content/en/docs/fhir-api/operations-reference.md`
