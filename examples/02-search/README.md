# 02 — Search (all parameters & modifiers)

This example exercises the full FHIR R4 search surface of the paito FHIR server:
string / token / date / reference / quantity / composite parameters, the `:exact`,
`:contains` and `:not` modifiers, `_include` / `_revinclude`, chained search and
`_has` (reverse chaining), `_sort`, `_count` cursor/offset paging with `link[next]`,
and result shaping with `_summary` / `_elements`. It seeds 3 Patients (born 1985,
1990, 1995) and one heart-rate Observation, then runs the searches against them.
The requests are derived directly from the proven `e2e-smoke.sh` and
`e2e-advanced-smoke.sh` scripts.

## How to run

```bash
# From the repo root — search works out of the box on the base stack (Postgres, no auth):
docker compose -f docker-compose.yml up -d

# Wait for readiness, then run the examples:
curl -fsS http://localhost:3500/fhir/r4/metadata >/dev/null && bash examples/02-search/run.sh
```

Override the target with `BASE_URL=http://host:3500/fhir/r4 bash examples/02-search/run.sh`.
The seed step uses `If-None-Exist`, so re-running does not create duplicates.
