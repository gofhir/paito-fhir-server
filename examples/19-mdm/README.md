# 19 - Master Data Management (MDM)

This example walks the full MDM operation surface of paito FHIR Server: it POSTs
identical and near-duplicate Patients and shows the engine auto-create golden
records and classify links (`MATCH` / `POSSIBLE_MATCH`), then exercises every
steward operation — `$mdm-query-links`, `$mdm-bulk-import`, `$mdm-create-link`,
`$mdm-update-link`, `$mdm-link-history`, `$mdm-submit`, `$mdm-calibrate`
(Fellegi-Sunter proposal), `$mdm-not-duplicate`, `$mdm-duplicate-golden-resources`,
`$mdm-merge-golden-resources` and `$mdm-clear`. It is derived from the proven
end-to-end suite `test/e2e/mdm_phase2_localhost_test.go` in go-fhir-server. MDM
requires the **PostgreSQL** backend.

## How to run

```bash
# 1. Start the MDM stack (paito + postgres, MDM enabled)
docker compose -f docker-compose.mdm.yml up -d

# 2. Wait until the FHIR API is ready
curl -sf http://localhost:3500/fhir/r4/metadata >/dev/null && echo ready

# 3. Run the demo (needs: curl, jq)
cd examples/19-mdm
bash run.sh
```

Each run uses a fresh `X-Tenant-ID` (`demo-mdm-<timestamp>`) so successive runs
never collide. Override with `BASE_URL=... TENANT=... bash run.sh`.
