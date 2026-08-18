# NIGHTWATCH OPSFORGE — Phase 6 Database Incidents

Phase 6 deepens incident diagnosis inside the existing production-support simulator. It does not add database technologies for resume breadth; it creates repeatable failure states that require evidence, hypothesis testing, recovery control, and validation.

> OPSFORGE is a simulated production-support training and portfolio environment. These exercises are not commercial production incidents.

## Database incident sequence

Planned domain order:

1. DB-001 — slow query / missing supporting index
2. DB-002 — lock contention
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

The exercise must produce three independent plan artifacts:

- `baseline-plan.txt` — expected index-backed plan
- `incident-plan.txt` — expected sequential-scan plan after injection
- `recovered-plan.txt` — index-backed plan after approved recovery

It also captures:

- deterministic workload row count
- index inventory before and after the incident
- `pg_stat_activity` state during diagnosis
- relation size
- recovered query result count

The scenario controller is `scripts/db_incident_001.sh`.

### Incident lifecycle

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

### L2 decision boundary

The intended skill is diagnosis and evidence quality, not unrestricted DDL.

L2 should establish:

- actual customer/query scope
- database reachability
- whether locks or broader saturation explain the symptom
- whether the expected index exists
- whether the planner actually regressed to a sequential scan
- whether a recent change explains the missing object

Recreating the index is modeled as an approved simulated change. In a commercial environment, production DDL may require DBA/development/change authority depending on access policy, table size, replication topology, maintenance risk, and organizational controls.

### Recovery is not index creation alone

DB-001 is not considered recovered until:

1. the index is visible again,
2. planner statistics are refreshed,
3. `EXPLAIN (ANALYZE, BUFFERS)` shows an index-backed plan,
4. the customer query returns the expected 20 rows,
5. incident evidence is retained for review.

Restarting PostgreSQL is explicitly not part of this runbook.

## Automated proof

`.github/workflows/deep-incidents.yml` creates an isolated PostgreSQL environment and runs:

```text
baseline
→ inject
→ diagnose
→ recover
→ verify
```

The workflow uploads the DB-001 evidence directory even when a scenario gate fails, and removes the isolated database volume after the run.

Operational records:

- `INC-1101` — incident lifecycle
- `L2N-1101` — hypothesis and action record
- `RUN-DB-MISSING-INDEX` — evidence-gated recovery procedure

## Definition of done for DB-001

DB-001 is complete when CI proves all of the following in one run:

- baseline table contains the deterministic workload
- baseline plan references `idx_customer_activity_customer_time`
- incident injection removes that index
- incident diagnosis proves a sequential scan
- diagnostic database state is captured before remediation
- approved recovery recreates the index and refreshes statistics
- recovered plan references the supporting index again
- query output remains correct
- operational records pass the Phase 5 support-record validator
- existing full OPSFORGE staging/production/rollback CI remains green
