# FHIR as Code (GitOps)

**What it is** — FHIR as Code manages FHIR resources **declaratively from a
directory** (your Git repo) instead of by hand via the REST API. On startup the
server reconciles every `*.json` file under `gitops.path` into the store: each
resource is upserted by id and tagged `http://gofhir.io/fhir/gitops|<name>`, and
— optionally — resources that disappeared from the repo are pruned. The repo is
the source of truth, so conformance/config resources (StructureDefinition,
ValueSet, CodeSystem, SearchParameter, ConceptMap, …) are reproducible,
reviewable via PR, and revertible via `git revert`. This is the top-level
`gitops:` block and is **distinct** from `admin.gitops`, which reconciles OAuth
clients and IG packages.

**When to use it**

- Ship curated ValueSets, CodeSystems, SearchParameters, and profiles as
  version-controlled files that deploy identically to every environment.
- Make config changes go through pull-request review and `git revert`, not
  ad-hoc REST writes.
- Run several independent repos/teams against one server, each owning only what
  it declares (per-source tracking), with no cross-source or cross-tenant
  clobbering.
- Continuously converge a running server toward the repo (poll- or event-based
  hot-reload), pruning removed resources safely.

**Launch**

```bash
docker compose -f docker-compose.gitops.yml up -d

# readiness check
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3500/fhir/r4/metadata   # -> 200
```

The compose mounts `config/gitops.yaml` (via `CONFIG_PATH`) and the repo
directory `config/gitops-repo/ → /app/fhir-resources`. On boot the server logs
`GitOps reconcile complete  path=… applied=3 pruned=0 errors=0`.

**Examples**

```bash
# 1. A resource declared in the repo was applied at startup (no REST write)
curl -s -o /dev/null -w '%{http_code}\n' \
  http://localhost:3500/fhir/r4/CodeSystem/paito-local-lab
# -> 200
```

```bash
# 2. It carries the owning-source tag (per-source ownership)
curl -s http://localhost:3500/fhir/r4/ValueSet/paito-marital-status \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print([t for t in d["meta"]["tag"] if t["system"]=="http://gofhir.io/fhir/gitops"])'
# -> [{'system': 'http://gofhir.io/fhir/gitops', 'code': 'paito-repo'}]
```

```bash
# 3. List everything this source manages via a _tag token search
curl -s 'http://localhost:3500/fhir/r4/ValueSet?_tag=http://gofhir.io/fhir/gitops|paito-repo' \
  | python3 -c 'import sys,json;b=json.load(sys.stdin);print("total:",b.get("total"))'
# -> total: 1
```

```bash
# 4. Anti-clobber: a hand-authored resource is NOT GitOps-managed
curl -s -X PUT http://localhost:3500/fhir/r4/Patient/hand-authored-1 \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/20-fhir-as-code/patient.json \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("gitops tags:",[t for t in d.get("meta",{}).get("tag",[]) if t["system"]=="http://gofhir.io/fhir/gitops"])'
# -> gitops tags: []   (GitOps will never prune or clobber it)
```

```bash
# 5. Prune is ownership-guarded. Delete a file from the repo on the host,
#    wait for the next reconcile (watchIntervalSeconds), then:
rm config/gitops-repo/valueset-marital-status.json
sleep 12
curl -s -o /dev/null -w '%{http_code}\n' \
  http://localhost:3500/fhir/r4/ValueSet/paito-marital-status
# -> 410 Gone   (the owner pruned its own resource)
```

Reset everything (drop the store + volumes) with
`docker compose -f docker-compose.gitops.yml down -v`.

**Configuration**

The container reads the mounted `config/gitops.yaml`. The keys under `gitops:`
(most also have a single-source env var override):

| Config key | Env var (inline source) | Default | Meaning |
| --- | --- | --- | --- |
| `gitops.enabled` | `GITOPS_ENABLED` | `false` | Activate FHIR-resource reconciliation (opt-in). |
| `gitops.path` | `GITOPS_PATH` | — | Directory of `*.json` resource files (recursive; symlinks skipped). |
| `gitops.name` | `GITOPS_NAME` | `default` | Source identity = ownership tag code; scopes adopt/prune per source. |
| `gitops.tenant` | `GITOPS_TENANT` | — | Target tenant; manifest scoped per `(name, tenant)`. |
| `gitops.reconcileOnStart` | — | `true` | Apply the directory once at startup. |
| `gitops.prune` | — | `false` | Delete managed resources removed from the repo (ownership-guarded). |
| `gitops.adoptExisting` | `GITOPS_ADOPT_EXISTING` | `false` | Take ownership of a pre-existing non-GitOps resource on id collision. |
| `gitops.allowEmptyRepo` | `GITOPS_ALLOW_EMPTY_REPO` | `false` | Permit prune when the directory loads to zero resources. |
| `gitops.maxPrune` | — | `0` | Cap deletions per run (`0` = unlimited); a larger prune aborts. |
| `gitops.watch` | `GITOPS_WATCH` | `false` | Event-driven hot-reload via fsnotify (instant, debounced). |
| `gitops.watchIntervalSeconds` | — | `0` | Periodic safety re-sync every N seconds (independent of `watch`). |
| `gitops.sources[]` | — | — | List of independent sources for one server; when set, the inline fields are ignored. |

Notes:

- **Opt-in.** `gitops.enabled` is `false` by default; this compose sets it `true`.
- **Multiple sources.** Use `gitops.sources[]` (each with its own `name`/`path`/
  `prune`/`tenant`) to reconcile several repos from one server without collisions.
  `sources[]` and per-source keys have **no** env-var override — use the mounted
  YAML.
- **Safety.** No silent adoption (id collision with a non-GitOps resource is
  skipped unless `adoptExisting`), no mass deletion on an empty repo (unless
  `allowEmptyRepo`), bounded prune (`maxPrune`), cross-source and cross-tenant
  isolation, no symlink following, and every reconcile emits an audit event.

**References**

- go-fhir-server site docs: `site/content/en/docs/deployment/fhir-as-code.md`
- go-fhir-server admin/GitOps (OAuth clients + IG packages): `site/content/en/docs/admin-system/gitops.md`
- Proven e2e test this example is derived from: `scripts/e2e-gitops-smoke.sh`
