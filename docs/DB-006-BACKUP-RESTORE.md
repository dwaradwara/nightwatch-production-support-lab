# OPSFORGE DB-006 — PostgreSQL Backup / Restore Validation

DB-006 trains recovery from confirmed logical data loss. The exercise is intentionally designed so PostgreSQL and API readiness can remain healthy while customer-visible ticket history disappears. The objective is to prove that operational health checks and successful HTTP responses are not substitutes for business-data integrity checks.

> This is a simulated production-support exercise. It does not represent commercial production recovery experience.

## Status

**COMPLETED — August 18, 2026.** DB-006 closes the PostgreSQL/database subtrack of OPSFORGE Phase 6. Phase 6 itself remains in progress because the application, queue/worker, proxy/network/security, and delivery incident domains are separate workstreams.

## Scenario

The isolated NIGHTWATCH environment starts with:

- a valid ticket schema,
- at least the three deterministic seed tickets,
- a deterministic ticket fingerprint,
- the 100,000-row `customer_activity` workload,
- healthy PostgreSQL and API readiness,
- a healthy `/api/tickets` read path.

DB-006 then creates a PostgreSQL custom-format logical backup using `pg_dump -Fc`.

Before any destructive exercise step, the backup is:

1. checked for non-zero size,
2. hashed with SHA-256,
3. inspected with `pg_restore --list`,
4. restored into a separate clean validation database,
5. checked with `db/schema-contract.sql`,
6. compared with the baseline ticket count,
7. compared with the baseline deterministic ticket fingerprint,
8. compared with the baseline `customer_activity` row count.

Only a backup that passes those checks is eligible for simulated primary recovery.

## Incident injection

The exercise performs controlled logical loss of the ticket domain:

```sql
TRUNCATE TABLE ticket_events, tickets RESTART IDENTITY CASCADE;
```

This deliberately leaves the PostgreSQL process, schema, and unrelated `customer_activity` workload intact.

Expected incident state:

```text
PostgreSQL reachable     YES
schema contract          PASS
/health/ready            HTTP 200
/api/tickets             HTTP 200
customer ticket rows     0
customer_activity rows   100000
```

This is a business-data incident, not a database-process outage.

## L2 diagnosis

L2 must establish all of the following before restore:

- customer-visible ticket data is actually missing,
- PostgreSQL is still reachable,
- the schema contract remains valid,
- unrelated database data remains present,
- the candidate backup checksum matches its retained record,
- the backup catalog contains the required table data,
- the independent validation restore matches the approved recovery point.

A green readiness endpoint is therefore evidence only for dependency reachability, not for business-data correctness.

## Recovery

For this isolated exercise only:

1. stop API writes,
2. terminate sessions attached to the exercise database,
3. drop and recreate the logical primary database,
4. restore from the already-validated custom-format backup,
5. start the API,
6. run full recovery validation.

The restore is modeled as an approved simulated database operation.

## Recovery validation

DB-006 is not considered recovered until all of the following pass:

- `db/schema-contract.sql`,
- baseline ticket row count comparison,
- baseline ticket fingerprint comparison,
- baseline `customer_activity` count comparison,
- `/health/ready` HTTP 200,
- `/api/tickets` HTTP 200 with the restored row count,
- PostgreSQL readiness,
- a transactional write/rollback probe that proves write capability without changing restored data.

The workflow also records clean-validation and primary-restore durations as CI exercise evidence. These timings are not production RTO claims.

## Measured CI evidence

`OPSFORGE DB-006 Backup Restore` run #3 on branch head `ebfceeec77c613fba0a3f74a23cbe160fcde18c7` proved:

- baseline ticket count: `3`
- baseline `/health/ready`: HTTP `200`
- baseline `/api/tickets`: HTTP `200`
- baseline `customer_activity`: `100000` rows
- custom-format backup size: `1,131,089` bytes
- backup SHA-256: `aaedbd4ff1dd6bf1cc1d6cec5ba7264b4389b3bafc8a07439877e95b6db7a85d`
- clean validation restore duration: `499 ms`
- validation ticket count: `3`
- validation ticket fingerprint: `b0f15cd8c39e9016ad3687ffde1388a4`
- validation `customer_activity`: `100000` rows
- incident ticket count: `0`
- incident `/health/ready`: HTTP `200`
- incident `/api/tickets`: HTTP `200` with an empty list
- incident `customer_activity`: `100000` rows
- backup checksum after incident matched the retained SHA-256 exactly
- primary restore duration: `417 ms`
- recovered ticket count: `3`
- recovered ticket fingerprint: `b0f15cd8c39e9016ad3687ffde1388a4`
- recovered `customer_activity`: `100000` rows
- recovered `/health/ready`: HTTP `200`
- recovered `/api/tickets`: HTTP `200` with `3` tickets
- transactional insert/rollback probe completed and ticket count remained `3`
- PostgreSQL accepted connections after recovery
- 35 evidence files were uploaded

The measured restore durations are CI exercise timings only. They are not production RTO measurements.

## What this exercise does not claim

DB-006 does **not** model or claim experience with:

- PostgreSQL physical/base backups,
- WAL archiving,
- point-in-time recovery,
- streaming-replica promotion,
- managed-service snapshots,
- encrypted off-site backup custody,
- retention/legal hold policy,
- cross-region disaster recovery.

Those require separate architecture, access controls, and recovery procedures.

## Files

- `scripts/db_incident_006.sh` — scenario controller
- `operations/records/INC-1106.json` — incident lifecycle
- `operations/records/L2N-1106.json` — L2 hypotheses/actions
- `operations/records/RUN-DB-BACKUP-RESTORE.json` — evidence-gated runbook
- `.github/workflows/db006-backup-restore.yml` — isolated CI proof

## Definition of done

DB-006 is complete only when CI proves, on one exact branch head:

```text
healthy baseline
→ backup creation
→ checksum/catalog validation
→ clean validation restore
→ logical ticket-data loss
→ evidence-based diagnosis
→ controlled primary restore
→ schema/data/API/write validation
→ support-record validation
→ DB-001 through DB-004 regression validation
→ full OPSFORGE staging/production/rollback regression
```
