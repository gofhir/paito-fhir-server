# Validation, Profiles & Implementation Guides

**What it is** — Paito validates resources against their base FHIR
StructureDefinition and against any profile you point it at, via the FHIR
`$validate` operation. Profiles come from Implementation Guides (IGs) installed
from [packages.fhir.org](https://packages.fhir.org) — US Core, IPS, or any
custom `.tgz`. All rules are derived from the installed StructureDefinitions
(cardinality, invariants, terminology bindings, slicing, fixed/pattern values)
— nothing is hard-coded. `$validate` never persists the resource; it returns an
[OperationOutcome](https://hl7.org/fhir/R4/operationoutcome.html) whose issue
severities tell you whether the resource conforms.

**When to use it**

- Pre-flight checking resources against US Core / IPS / national IG profiles before ingestion.
- Enforcing required cardinality and invariants a profile adds on top of base FHIR.
- Checking `required`/`extensible` terminology bindings against installed ValueSets.
- Letting clients discover which profiles the server supports: by canonical with
  `GET /StructureDefinition?url=<canonical>` (optionally `|<version>`), or as a list
  from `/metadata` `rest.resource.supportedProfile[]`. A bare
  `GET /StructureDefinition` returns only profiles held in the resource store, not the
  contents of installed packages — see Profile Discovery below for why.
- CI/conformance gates that assert on `OperationOutcome.issue[]`.

## Launch

The compose file installs US Core 5.0.1 and IPS 1.1.0 at boot through the admin
GitOps reconciler (declared in `config/packages-validation-ig.yaml`).

```bash
docker compose -f docker-compose.validation-ig.yml up -d

# Readiness (first boot also downloads ~7 MB of IG packages)
curl -s http://localhost:3500/fhir/r4/metadata | jq -r '.software.name // .fhirVersion'
```

- FHIR API: `http://localhost:3500/fhir/r4`
- Admin API: `http://localhost:3501` (Bearer `paito-validation-key`)

Confirm the IGs installed:

```bash
curl -s -H "Authorization: Bearer paito-validation-key" \
  http://localhost:3501/api/packages | jq -r '.packages[] | "\(.name) \(.version)"'
# hl7.fhir.us.core 5.0.1
# hl7.fhir.uv.ips 1.1.0
```

## Examples

All examples use `BASE=http://localhost:3500/fhir/r4`. `$validate` always
returns HTTP `200`; look at issue severities, not the status code.

**1. Conforming US Core Patient → no errors**

```bash
curl -s -X POST "$BASE/Patient/\$validate" \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/05-validation-ig/patient-uscore-valid.json | jq '.issue'
```
Expected: only `information`/`warning` issues, zero `error`.

**2. Required cardinality from the profile (identifier 1..\*)**

```bash
curl -s -X POST "$BASE/Patient/\$validate" \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/05-validation-ig/patient-uscore-missing-identifier.json | jq '.issue'
```
Expected: an `error` whose expression is `Patient.identifier` (minimum required = 1).

**3. Profile invariant (us-core-6: family or given required)**

```bash
curl -s -X POST "$BASE/Patient/\$validate" \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/05-validation-ig/patient-uscore-badname.json | jq '.issue'
```
Expected: an `error` referencing constraint `us-core-6`.

**4. Required terminology binding (administrative-gender)**

```bash
curl -s -X POST "$BASE/Patient/\$validate" \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/05-validation-ig/patient-uscore-badgender.json | jq '.issue'
```
Expected: a `code-invalid` error referencing the bound administrative-gender ValueSet (`gender: "unicorn"`).

**5. Per-call `?profile=` override — same resource, two outcomes**

```bash
# Passes against IPS
curl -s -X POST "$BASE/Patient/\$validate?profile=http://hl7.org/fhir/uv/ips/StructureDefinition/Patient-uv-ips" \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/05-validation-ig/patient-minimal.json | jq '.issue'

# Same resource fails against US Core (missing identifier)
curl -s -X POST "$BASE/Patient/\$validate?profile=http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient" \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/05-validation-ig/patient-minimal.json | jq '.issue'
```
Expected: IPS → 0 errors; US Core → `Patient.identifier` error. The `?profile=`
param drives the target independent of `meta.profile`.

**6. `$validate` via the FHIR `Parameters` wrapper**

```bash
curl -s -X POST "$BASE/Patient/\$validate" \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/05-validation-ig/validate-parameters.json | jq '.issue'
```
Expected: same `Patient.identifier` error as the URL-param form.

**7. Discover installed profiles (standard FHIR REST)**

```bash
curl -s "$BASE/StructureDefinition?url=http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient" \
  | jq '.entry[0].resource | {id, type, baseDefinition}'

curl -s "$BASE/metadata" \
  | jq '.rest[0].resource[] | select(.type=="Patient") | {type, supportedProfile}'
```

## Configuration

The compose selects a mounted config file (`config/validation-ig.yaml`) because
GitOps IG installation is a config-file feature. The env vars below are the ones
the compose sets; the rest live in the mounted YAML.

| Env var / config key | Value | Purpose |
|----------------------|-------|---------|
| `CONFIG_PATH` | `/app/config/validation-ig.yaml` | Selects the mounted config file |
| `ADMIN_API_KEY` | `paito-validation-key` | Bearer key for the admin API (`/api/packages`) |
| `FHIR_PACKAGE_CACHE` | `/app/.fhir/packages` | Where downloaded IG `.tgz` files are cached (persisted volume) |
| `VALIDATION_ENABLED` | `true` (in YAML: `validation.enabled`) | Turns on the validation engine |
| `VALIDATION_MODE` | `enforced` (`validation.mode`) | Enforce profile rules |
| `VALIDATION_TERMINOLOGY_MODE` | `internal` (`validation.terminology.mode`) | Resolve bindings against the internal terminology service |
| `TERMINOLOGY_ENABLED` | `true` (`terminology.enabled`) | Enables binding checks; IGs supply their own ValueSet expansions |
| `admin.gitops.packagesPath` | `/app/config/packages-validation-ig.yaml` | Declarative IG list installed at boot (config only) |
| `admin.gitops.reconcileOnStart` | `true` | Install the listed IGs on startup |
| `packages.offline` | `false` | Allow download from packages.fhir.org on first boot |

You can also install IGs at runtime instead of (or in addition to) the boot
list, via the admin API:

```bash
curl -s -X POST http://localhost:3501/api/packages/install \
  -H "Authorization: Bearer paito-validation-key" \
  -H 'Content-Type: application/json' \
  -d '{"name":"hl7.fhir.us.core","version":"5.0.1"}'
```

## References

- [`$validate` Operation](https://github.com/gofhir/go-fhir-server/blob/main/site/content/en/docs/fhir-api/validate.md) — `site/content/en/docs/fhir-api/validate.md`
- [Validation](https://github.com/gofhir/go-fhir-server/blob/main/site/content/en/docs/fhir-api/validation.md) — `site/content/en/docs/fhir-api/validation.md`
- [Profile Discovery](https://github.com/gofhir/go-fhir-server/blob/main/site/content/en/docs/fhir-api/profile-discovery.md) — `site/content/en/docs/fhir-api/profile-discovery.md`
- FHIR R4: [Resource $validate](https://hl7.org/fhir/R4/resource-operation-validate.html) · [Profiling](https://hl7.org/fhir/R4/profiling.html)
- IGs: [US Core STU5.0.1](https://hl7.org/fhir/us/core/STU5.0.1/) · [IPS STU1.1](https://hl7.org/fhir/uv/ips/STU1.1/)
