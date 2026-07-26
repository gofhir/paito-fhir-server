# Messaging (`$process-message`)

**What it is** — Paito implements the FHIR R4 [messaging paradigm](https://hl7.org/fhir/R4/messaging.html) at the envelope level. You POST a `Bundle` of type `message` (whose first entry is a `MessageHeader`) to `/fhir/r4/$process-message`, and the server runs an ordered validation pipeline — envelope cardinalities, Bundle `meta.profile` validation, `MessageDefinition` focus cardinalities — before dispatching to a `MessageProcessor` that performs the application-specific work. The core server ships **no** processing logic by default: with no processor registered, `$process-message` replies `MessageHeader.response.code = "fatal-error"` (the honest "not processed" default) so a sender never assumes a message took effect when it did not.

**When to use it**
- Ingesting event-style messages (`patient-admit`, `lab-result`, ORU/ADT-equivalents) where a Bundle of related resources is delivered as one unit.
- Enforcing a messaging IG (IHE PMIR, NHS BaRS, Gematik) that supplies a Bundle profile and/or `MessageDefinition` as the declarative contract.
- Prototyping message intake with the shipped **reference processor**, which persists each focus resource through the FHIR service layer (auth, validation, audit all apply) and replies `ok`.
- Accepting messages asynchronously: `async=true` returns `202` + a `Content-Location` the client polls for the reply Bundle.

**Launch**

```bash
# Mounts config/messaging.yaml (enables the reference processor + async) via CONFIG_PATH
docker compose -f docker-compose.messaging.yml up -d

# Readiness check
curl -s http://localhost:3500/fhir/r4/metadata | head -c 200
```

**Examples** — base URL `http://localhost:3500/fhir/r4`. Full runnable script: `examples/14-messaging/run.sh`.

1. CapabilityStatement advertises messaging (present only when a processor is registered):

```bash
curl -s http://localhost:3500/fhir/r4/metadata | python3 -c 'import sys,json;print(json.load(sys.stdin).get("messaging"))'
# → [{"documentation": "GoFHIR receives FHIR messages via $process-message ..."}]
```

2. Envelope validation — a message missing `MessageHeader.source` (1..1) is rejected:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/14-messaging/message-no-source.json \
  'http://localhost:3500/fhir/r4/$process-message'
# → 400
```

3. Processing — a valid message returns `200`, `response.code = ok`, and the focus Patient is persisted:

```bash
curl -s -X POST -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/14-messaging/message-valid.json \
  'http://localhost:3500/fhir/r4/$process-message'
# → reply Bundle: MessageHeader.response.code = "ok"

curl -s 'http://localhost:3500/fhir/r4/Patient?identifier=urn:mrn|PAITO-SYNC' \
  | python3 -c 'import sys,json;print("total:",json.load(sys.stdin)["total"])'
# → total: 1
```

4. Bundle profile validation — install a strict profile, then a message that declares and violates it replies `fatal-error` and its focus is NOT persisted:

```bash
curl -s -X PUT -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/14-messaging/bundle-profile.json \
  http://localhost:3500/fhir/r4/StructureDefinition/PaitoMsgBundle

curl -s -X POST -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/14-messaging/message-bad-profile.json \
  'http://localhost:3500/fhir/r4/$process-message'
# → MessageHeader.response.code = "fatal-error" (Bundle.entry min 3 violated)
```

5. MessageDefinition focus validation — install a `MessageDefinition` (lab-result needs `Observation` 1..1); a lab-result message with no Observation replies `fatal-error`:

```bash
curl -s -X PUT -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/14-messaging/message-definition-lab.json \
  http://localhost:3500/fhir/r4/MessageDefinition/PaitoMDLab

curl -s -X POST -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/14-messaging/message-lab-no-focus.json \
  'http://localhost:3500/fhir/r4/$process-message'
# → MessageHeader.response.code = "fatal-error" (missing required focus)
```

6. Async delivery (**opt-in**, `async: true`) — kick off, capture `Content-Location`, poll:

```bash
CL=$(curl -s -D - -o /dev/null -X POST -H 'Content-Type: application/fhir+json' \
  --data-binary @examples/14-messaging/message-async.json \
  'http://localhost:3500/fhir/r4/$process-message?async=true' \
  | grep -i '^content-location' | tr -d '\r' | awk '{print $2}')
# → 202 Accepted, Content-Location: .../_asyncstatus/<job-id>

curl -s "http://localhost:3500/fhir/r4/_asyncstatus/${CL##*/_asyncstatus/}"
# → reply Bundle once ready: MessageHeader.response.code = "ok"
```

> With async disabled (default), `async=true` is declined with `422 Unprocessable Entity` and a `not-supported` OperationOutcome — the spec-conformant way to decline an unsupported optional value.

**Configuration** — the messaging paradigm has **no environment-variable mapping**; it is enabled through the mounted overlay `config/messaging.yaml` (selected via `CONFIG_PATH`). Keys:

| Config key (YAML) | Type | Default | Meaning |
|---|---|---|---|
| `messaging.processMessage.persistReference` | bool | `false` | Register the shipped reference `MessageProcessor` that persists every focus resource and replies `ok`. When `false`, every message replies `fatal-error` (honest default) and `/metadata` omits `messaging`. |
| `messaging.processMessage.events` | list | `[]` | Restrict the reference processor to these event keys (`"system|code"` or a bare event URI). Empty = catch-all. |
| `messaging.processMessage.async` | bool | `false` | Enable async delivery: `async=true` → `202` + `Content-Location` to poll. When `false`, `async=true` → `422`. |

Environment variables in the compose (`STORAGE_DRIVER`, `POSTGRES_*`, `FHIR_VERSION`, `AUTH_ENABLED`) configure storage/server and take precedence over the overlay file. `response-url` (push delivery) is not yet supported; the poll variant is used.

**References**
- go-fhir-server site docs: `site/content/en/docs/fhir-api/messaging.md`
- FHIR spec: [Messaging](https://hl7.org/fhir/R4/messaging.html), [`$process-message`](https://hl7.org/fhir/R4/messageheader-operation-process-message.html)
