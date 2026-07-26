# Bundles

**What it is** — Paito processes FHIR R4 [Bundle](https://hl7.org/fhir/R4/bundle.html)
resources at the system-level endpoint. It handles the write-oriented types
(`transaction`, `batch`, `document`, `message`) and produces the read-oriented
types (`searchset`). `transaction` bundles are fully ACID: all entries succeed or
the whole thing rolls back, with `urn:uuid` forward references resolved to
server-assigned IDs. `batch` bundles process each entry independently, allowing
partial success. No extra configuration is required — bundle processing is on by
default with the base stack.

**When to use it**

- **Transaction** — write several inter-linked resources atomically (e.g. a
  Patient plus its Observations/Encounter), where a single failure must undo
  everything.
- **Batch** — submit many independent writes in one round-trip and accept
  per-entry success/failure.
- **Document** — persist a clinical document (Composition + supporting resources)
  verbatim as an immutable, retrievable `Bundle`.
- **Message** — dispatch an event/message (MessageHeader-led) through the
  `$process-message` operation.
- **Searchset** — the Bundle you receive back from any GET search.
- **Collection** — note that clients cannot POST one; it is rejected.

**Launch**

```bash
# Base stack (PostgreSQL + paito) — bundle processing needs nothing extra:
docker compose -f docker-compose.yml up -d

# Readiness check:
curl -s http://localhost:3500/fhir/r4/metadata | head -c 200
```

**Examples**

All examples target the base URL `http://localhost:3500/fhir/r4`. Bundles are
POSTed to the base path (`/`); message bundles go to `$process-message`.

1. Transaction — atomic Patient + Observation with a `urn:uuid` forward reference.
   The response is a `transaction-response` and the `urn:uuid` is rewritten to
   `Patient/<id>`:

   ```bash
   curl -s -X POST http://localhost:3500/fhir/r4/ \
     -H 'Content-Type: application/fhir+json' \
     --data-binary @examples/03-bundles/bundle-transaction.json
   # → 200; Bundle.type=transaction-response; each entry.response.status "201 Created"
   ```

2. Transaction rollback — a bundle whose second entry has an invalid gender fails
   entirely; the first (valid) entry is NOT persisted:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:3500/fhir/r4/ \
     -H 'Content-Type: application/fhir+json' \
     --data-binary @examples/03-bundles/bundle-transaction-invalid.json
   # → 400 OperationOutcome
   curl -s 'http://localhost:3500/fhir/r4/Patient?family=TX-Should-NOT-Persist'
   # → searchset with total: 0  (rolled back)
   ```

3. Batch — one valid + one invalid entry; the batch returns 200 and the valid
   entry still persists (partial success):

   ```bash
   curl -s -X POST http://localhost:3500/fhir/r4/ \
     -H 'Content-Type: application/fhir+json' \
     --data-binary @examples/03-bundles/bundle-batch.json
   # → 200; Bundle.type=batch-response; entry[0]=201 Created, entry[1]=422 Unprocessable Entity
   ```

4. Document — stored verbatim as a Bundle resource (requires `Bundle.identifier`
   and `timestamp`), then independently retrievable:

   ```bash
   curl -s -X POST http://localhost:3500/fhir/r4/ \
     -H 'Content-Type: application/fhir+json' \
     --data-binary @examples/03-bundles/bundle-document.json
   # → 200; Bundle.type=document; response has a server-assigned Bundle id
   curl -s 'http://localhost:3500/fhir/r4/Bundle?type=document'
   # → searchset containing the stored document
   ```

5. Message — dispatched through `$process-message` (not the base path); the
   response is a `message` bundle whose MessageHeader reports `code: ok`:

   ```bash
   curl -s -X POST 'http://localhost:3500/fhir/r4/$process-message' \
     -H 'Content-Type: application/fhir+json' \
     --data-binary @examples/03-bundles/bundle-message.json
   # → 200; Bundle.type=message; MessageHeader.response.code=ok
   ```

6. Searchset — the Bundle returned by any GET search; a no-match search still
   returns `total: 0` with a `self` link:

   ```bash
   curl -s 'http://localhost:3500/fhir/r4/Patient'
   # → 200; Bundle.type=searchset; link[relation=self] present
   ```

7. Collection — rejected on POST (a collection has no request semantics):

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:3500/fhir/r4/ \
     -H 'Content-Type: application/fhir+json' \
     --data-binary @examples/03-bundles/bundle-collection.json
   # → 400 OperationOutcome (mentions the rejected type)
   ```

Run all of the above end-to-end with `bash examples/03-bundles/run.sh`.

**Configuration**

Bundle processing works out of the box. The only bundle-specific knob controls the
PostgreSQL isolation level used for transaction bundles.

| Env var | Config key | Values | Default | Description |
|---------|-----------|--------|---------|-------------|
| `POSTGRES_TX_ISOLATION_LEVEL` | `database.postgres.txIsolationLevel` | `serializable`, `repeatable_read` | `serializable` | Isolation level for transaction bundles. `serializable` gives the strongest consistency (may roll back conflicting concurrent transactions with HTTP 409); `repeatable_read` reduces contention under high concurrent load. Both guarantee ACID atomicity. |

Standard stack env vars (`STORAGE_DRIVER`, `POSTGRES_HOST`, `POSTGRES_USER`,
`POSTGRES_PASSWORD`, `POSTGRES_DB`, `FHIR_VERSION`) apply as in the base
`docker-compose.yml`.

**References**

- go-fhir-server docs: `site/content/en/docs/fhir-api/bundles.md` (Bundle Processing)
- go-fhir-server docs: `site/content/en/docs/fhir-api/bundle-signatures.md` (Bundle signatures)
- go-fhir-server docs: `site/content/en/docs/fhir-api/messaging.md` (`$process-message`)
- FHIR R4 spec: https://hl7.org/fhir/R4/bundle.html · https://hl7.org/fhir/R4/http.html#transaction
