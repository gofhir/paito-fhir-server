# 17 — GraphQL API

Exercises paito's dynamically-generated GraphQL API: schema introspection, a
`PatientCreate` mutation (with an inline `managingOrganization` reference),
single-resource reads with field selection, the `List` and `Connection`
(cursor-paged) search APIs, inline reference resolution via DataLoader, the
`@first` directive, per-field `fhirpath` filtering, `PatientHistory` version
history, instance-level `POST /Patient/{id}/$graphql`, update/delete mutations,
and the fact that GraphQL execution errors ride in the `errors` array with
HTTP `200`. Every query mirrors an example from the go-fhir-server GraphQL
reference doc. The GraphQL endpoint lives at the server root (`/graphql`),
while REST seeding and `$graphql` use the `/fhir/r4` base.

## How to run

```bash
# from the repo root — GraphQL transport is OFF by default, so use the graphql compose
docker compose -f docker-compose.graphql.yml up -d

# wait for readiness, then drive the flow
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready
bash examples/17-graphql/run.sh
```

Open `http://localhost:3500/graphql` in a browser for the interactive GraphQL
Playground (enabled by `GRAPHQL_PLAYGROUND=true` in the compose file).

Override targets with `BASE_URL=... GQL_URL=... bash examples/17-graphql/run.sh`.
Tear down with `docker compose -f docker-compose.graphql.yml down -v`.
