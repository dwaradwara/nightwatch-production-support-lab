# NIGHTWATCH OPSFORGE — Phase 6 Database Incidents

Phase 6 deepens incident diagnosis inside the existing production-support simulator. It does not add database technologies for resume breadth; it creates repeatable failure states that require evidence, hypothesis testing, recovery control, and validation.

> OPSFORGE is a simulated production-support training and portfolio environment. These exercises are not commercial production incidents.

## Database incident sequence

1. DB-001 — slow query / missing supporting index — complete
2. DB-002 — lock contention — under validation
3. DB-003 — long-running transaction
4. DB-004 — connection exhaustion
5. DB-005 — failed or incompatible migration
6. DB-006 — backup/restore validation

The exercises become progressively less guided. Phase 7 later removes the root-cause label entirely.

## DB-001 — missing supporting index

### Business query

`customer_activity` represents a high-volume customer activity/history workload. The deterministic seed contains 100,000 rows across 5,000 customers.

Normal query:

```sql
SELECT id, event_type, payload, occurred_at
FROM customer_activity
WHERE customer_id = 'customer-0042'
ORDER BY occurred_at DESC
LIMIT 20;
```

Normal supporting index:

```sql
CREATE INDEX idx_customer_activity_customer_time
ON customer_activity (customer_id, occurred_at DESC);
```

The incident removes that supporting index. PostgreSQL remains reachable, so a simple health check does not identify the degradation.

### Evidence contract

The exercise produces three independent plan artifacts:

- `baseline-plan.txt` — expected index-backed plan
- `incident-plan.txt` — expected sequential-scan plan after injection
- `recovered-plan.txt` — index-backed plan after approved recovery

It also captures deterministic workload row count, index inventory, `pg_stat_activity`, relation size, and recovered query result count.

The scenario controller is `scripts/db_incident_001.sh`.

### First measured CI result

`OPSFORGE Deep Incidents` run #1 produced the following evidence on August 18, 2026:

| State | Plan evidence | Execution time | Buffer / row evidence |
|---|---|---:|---|
| Baseline | `Bitmap Index Scan on idx_customer_activity_customer_time` | 0.300 ms | 20 result rows; 23 heap/index buffers plus 3 reads in the main scan path |
| Incident | `Seq Scan on customer_activity` | 11.398 ms | 99,980 rows removed by filter; 2,774 shared buffers touched |
| Recovered | `Bitmap Index Scan on idx_customer_activity_customer_time` | 0.256 ms | expected 20-row result restored |

In that CI run, the incident query took about **38×** the indexed baseline execution time while PostgreSQL remained available. The exact timing is environment-specific; the durable evidence is the plan change, the rows filtered, and the much larger buffer footprint.

The incident relation occupied about 24 MB in the isolated CI environment.

### DB-001 lifecycle

```text
indexed baseline
    ↓
remove supporting index
    ↓
customer query plan regresses
    ↓
capture database state
    ↓
EXPLAIN (ANALYZE, BUFFERS)
    ↓
confirm missing index + sequential scan
    ↓
approved simulated database change
    ↓
CREATE INDEX CONCURRENTLY + ANALYZE
    ↓
repeat EXPLAIN
    ↓
validate returned data
```

The intended skill is diagnosis and evidence quality, not unrestricted DDL. Recreating the index is modeled as an approved simulated change. Restarting PostgreSQL is explicitly not part of the runbook.

Operational records:

- `INC-1101`
- `L2N-1101`
- `RUN-DB-MISSING-INDEX`

## DB-002 — lock contention

### Business symptom

`customer_account_state` models a small transaction-sensitive customer state row. The incident does not make PostgreSQL unavailable. Instead, one open transaction holds the row lock while a second transaction tries to update the same customer and waits.

That creates a different diagnostic pattern from DB-001:

```text
PostgreSQL reachable
        ↓
customer update does not complete
        ↓
wait_event_type = Lock
        ↓
identify waiter PID
        ↓
pg_blocking_pids(waiter_pid)
        ↓
identify exact blocker PID + transaction
        ↓
inspect pg_locks / transaction age / query
        ↓
approved targeted recovery
        ↓
waiting update completes
```

### Controlled sessions

DB-002 creates two explicitly tagged PostgreSQL sessions:

- `opsforge-db002-blocker` — opens a transaction, updates `customer-0042`, and keeps the transaction open
- `opsforge-db002-waiter` — attempts a second update to the same row and should enter a PostgreSQL `Lock` wait

The `application_name` tags are part of the safety contract. The recovery action refuses to act unless the expected simulated blocker is present.

### Evidence contract

The scenario controller `scripts/db_incident_002.sh` separates five actions:

```text
baseline
→ inject
→ diagnose
→ recover
→ verify
```

Evidence includes:

- database reachability while the transaction is blocked
- `pg_stat_activity` for blocker and waiter
- waiter `wait_event_type` / `wait_event`
- `pg_blocking_pids` waiter-to-blocker mapping
- `pg_locks` rows for both sessions
- blocker PID, application name, transaction age, and query text captured before recovery
- targeted termination result
- post-recovery customer row state
- proof that no DB-002 exercise sessions remain

### L2 decision boundary

The lesson is not “kill blocking PIDs.” L2 must first establish:

1. the database is reachable,
2. the affected operation is actually waiting on a lock,
3. the exact waiter and blocker relationship,
4. blocker transaction age and query context,
5. whether the blocker belongs to an expected deployment, migration, maintenance operation, or business transaction,
6. whether termination is authorized.

In DB-002, `pg_terminate_backend` is permitted only because the target is the explicitly tagged simulated blocker and the exercise models an approved recovery. In a commercial environment, a production transaction may need DBA/application-owner approval because termination can roll back business work.

Restarting PostgreSQL is intentionally not a recovery step for this scoped lock incident.

### Recovery proof

DB-002 is not considered recovered merely because the blocker disappeared. Verification must prove:

- the waiter left the lock-wait state,
- the waiting update completed,
- the expected `Investigating` customer state was committed,
- no exercise blocker/waiter sessions remain,
- PostgreSQL stayed reachable without restart,
- the fixture can be returned to `Normal` for the next exercise.

Operational records:

- `INC-1102`
- `L2N-1102`
- `RUN-DB-LOCK-CONTENTION`

## Automated proof

`.github/workflows/deep-incidents.yml` runs DB-001 and DB-002 as separate isolated jobs. Each job gets its own Compose project, PostgreSQL volume, evidence directory, and teardown.

The deep-incident workflow is only one gate. Phase 6 database changes must also keep:

- Phase 5 support-record validation green
- the complete OPSFORGE staging → production → rejected-candidate → rollback → recovery pipeline green

## Definition of done for DB-002

DB-002 is complete when CI proves all of the following in one run:

- baseline target row is writable and no exercise sessions remain
- blocker transaction acquires the target row lock
- waiter transaction enters a PostgreSQL `Lock` wait
- database remains reachable during the incident
- `pg_blocking_pids` maps the waiter to the intended blocker
- `pg_locks` evidence is captured before remediation
- recovery targets only the proven simulated blocker
- waiting update completes after lock release
- no exercise sessions remain after recovery
- operational records pass the support validator
- existing full OPSFORGE delivery/rollback CI remains green
