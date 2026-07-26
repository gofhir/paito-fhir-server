# GraphQL API

**What it is** — paito exposes a [GraphQL](https://graphql.org/) API alongside the
REST API, following the [FHIR R4 GraphQL specification](https://hl7.org/fhir/R4/graphql.html).
The GraphQL schema is **generated dynamically from the loaded FHIR
StructureDefinitions** — every resource type, field, and search parameter is
derived from the definitions, nothing is hardcoded. It supports reads,
`List`/`Connection` searches, CRUD + patch mutations, inline reference
resolution, directives, per-field `fhirpath` filtering, history queries, and
optional WebSocket subscriptions. The transport is **opt-in** (disabled by
default) and mounted at the server root (`/graphql`), plus a FHIR
`$graphql` operation at type and instance level.

**When to use it**

- Fetch exactly the fields you need in one round trip (no over-fetching).
- Resolve `Reference` targets inline (`resource { ... }`) instead of `_include` or extra requests.
- Cursor-paginate large result sets with the `Connection` API.
- Traverse instance relationships (`PatientHistory`, reverse references) from a single query root.
- Build tooling against a live, introspectable schema (GraphQL Playground UI).

**Launch**

GraphQL is off by default, so use the graphql compose (it sets `GRAPHQL_ENABLED=true`):

```bash
docker compose -f docker-compose.graphql.yml up -d

# readiness check (REST capability statement)
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
```

The dedicated endpoint is at the root (`POST http://localhost:3500/graphql`); a
browser `GET` on the same URL serves the interactive Playground.

**Examples**

1. Introspect the schema roots:

```bash
curl -s -X POST http://localhost:3500/graphql -H 'Content-Type: application/json' \
  -d '{"query":"{ __schema { queryType { name } mutationType { name } } }"}'
# → {"data":{"__schema":{"queryType":{"name":"Query"},"mutationType":{"name":"Mutation"}}}}
```

2. Create a Patient with a mutation:

```bash
curl -s -X POST http://localhost:3500/graphql -H 'Content-Type: application/json' \
  -d '{"query":"mutation { PatientCreate(res: { resourceType: \"Patient\" name: [{ family: \"Garcia\" given: [\"Maria\"] }] gender: \"female\" }) { id meta { versionId } name { family } } }"}'
# → {"data":{"PatientCreate":{"id":"<id>","meta":{"versionId":"1"},"name":[{"family":"Garcia"}]}}}
```

3. Read a single resource, selecting only the fields you need:

```bash
curl -s -X POST http://localhost:3500/graphql -H 'Content-Type: application/json' \
  -d '{"query":"{ Patient(id: \"<id>\") { id gender birthDate name { family given } } }"}'
# → {"data":{"Patient":{"id":"<id>","gender":"female","birthDate":"1990-05-15","name":[{"family":"Garcia","given":["Maria"]}]}}}
```

4. Search with the List API (Bundle-shaped result):

```bash
curl -s -X POST http://localhost:3500/graphql -H 'Content-Type: application/json' \
  -d '{"query":"{ PatientList(name: \"Garcia\", gender: \"female\", _count: 10) { total entry { resource { id name { family } } } } }"}'
# → {"data":{"PatientList":{"total":1,"entry":[{"resource":{"id":"<id>","name":[{"family":"Garcia"}]}}]}}}
```

5. Cursor pagination with the Connection API:

```bash
curl -s -X POST http://localhost:3500/graphql -H 'Content-Type: application/json' \
  -d '{"query":"{ PatientConnection(name: \"Garcia\", _count: 10) { count offset pagesize edges { mode score resource { id } } next } }"}'
# → edges[] plus an opaque `next` cursor ("gql:name=Garcia&_count=10&_offset=10")
```

6. Resolve a reference inline (DataLoader batches + deduplicates):

```bash
curl -s -X POST http://localhost:3500/graphql -H 'Content-Type: application/json' \
  -d '{"query":"{ Patient(id: \"<id>\") { managingOrganization { reference resource { ... on Organization { name address { city } } } } } }"}'
# → the referenced Organization is loaded inside the same response
```

7. Instance-level `$graphql` — the resource itself is the query root:

```bash
curl -s -X POST 'http://localhost:3500/fhir/r4/Patient/<id>/$graphql' \
  -H 'Content-Type: application/json' \
  -d '{"query": "{ name { family given } gender birthDate }"}'
# → {"data":{"name":[{"family":"Garcia","given":["Maria"]}],"gender":"female","birthDate":"1990-05-15"}}
```

8. GraphQL errors ride in `errors` with HTTP `200` (they are **not** converted to a 4xx OperationOutcome):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:3500/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ Patient(id: \"<id>\") { notAField } }"}'
# → 200   (the body carries {"errors":[{"message":"Cannot query field \"notAField\" ..."}]})
```

Response format: both `/graphql` and the `$graphql` operation return the **raw
GraphQL document** (`{"data": ..., "errors": [...]}`) with
`Content-Type: application/json` — it is **not** wrapped in a `Parameters`
resource. Only invocation-level failures (missing `query`, schema unavailable,
query-limit exceeded) return a FHIR `OperationOutcome`.

**Configuration**

GraphQL is disabled by default. Enable and tune it with these env vars
(names from `internal/config/config_env.go`, mapping to `transports.graphql.*`):

| Env var | Config key | Description | Default |
|---------|-----------|-------------|---------|
| `GRAPHQL_ENABLED` | `transports.graphql.enabled` | Mount the `/graphql` endpoint + `$graphql` operation | `false` |
| `GRAPHQL_PLAYGROUND` | `transports.graphql.playground` | Serve the Playground UI on `GET /graphql` | `false` |
| `GRAPHQL_INTROSPECTION` | `transports.graphql.introspection` | Allow `__schema` / `__type` introspection queries | `false` |
| `GRAPHQL_COMPLEXITY_LIMIT` | `transports.graphql.complexityLimit` | Max query complexity score (`0` = unlimited) | `1000` |
| `GRAPHQL_MAX_DEPTH` | `transports.graphql.maxDepth` | Max query nesting depth (`0` = unlimited) | `10` |
| `GRAPHQL_TIMEOUT` | `transports.graphql.timeout` | Per-query execution timeout (Go duration, e.g. `30s`) | `30s` |
| `GRAPHQL_SUBSCRIPTIONS` | `transports.graphql.subscriptions` | Enable WebSocket subscriptions (requires a broker) | `false` |

Complexity costs: scalar field = 1, object field = 2 + children, search
(`List`/`Connection`) = 8 + children. For production, set both
`GRAPHQL_PLAYGROUND=false` and `GRAPHQL_INTROSPECTION=false` to prevent schema
discovery. Subscriptions additionally require a configured event broker (NATS or
RabbitMQ) and are not enabled by the base graphql compose.

**References**

- go-fhir-server site docs: `site/content/en/docs/fhir-api/graphql.md` (`/docs/fhir-api/graphql/`)
- [FHIR R4 GraphQL specification](https://hl7.org/fhir/R4/graphql.html)
- [FHIR R4 `$graphql` operation](https://hl7.org/fhir/R4/resource-operation-graphql.html)
- Runnable examples: `examples/17-graphql/`
