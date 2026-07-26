# 20 · FHIR as Code (GitOps)

Demonstrates **declarative FHIR resources**: the files under
`config/gitops-repo/` (a `CodeSystem`, a `ValueSet`, and a `SearchParameter`)
are reconciled into the store **on startup** — no REST writes. Each is upserted
by id and tagged with its owning source (`http://gofhir.io/fhir/gitops|paito-repo`),
so ownership is tracked **per source** and prune is ownership-guarded. The script
also shows the safety boundary: a hand-authored resource created via the API
carries **no** GitOps tag, so it is never clobbered or pruned.

## How to run

```bash
# 1. Launch the server with the GitOps reconciler ON
docker compose -f docker-compose.gitops.yml up -d

# 2. Run the demo (waits for /metadata, then exercises the reconciled resources)
bash examples/20-fhir-as-code/run.sh
```

Override the target with `BASE_URL=… bash examples/20-fhir-as-code/run.sh`.

**Try prune live:** delete `config/gitops-repo/valueset-marital-status.json` on
the host, wait ~10 s (`watchIntervalSeconds: 10`), then
`curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3500/fhir/r4/ValueSet/paito-marital-status`
returns `410 Gone` — the owner pruned its own resource. Restore the file and it
comes back on the next pass. Reset everything with
`docker compose -f docker-compose.gitops.yml down -v`.
