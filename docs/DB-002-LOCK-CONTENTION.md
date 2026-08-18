# OPSFORGE DB-002 — PostgreSQL Lock Contention

DB-002 trains evidence-driven diagnosis of a blocked write. The exercise uses real PostgreSQL row locking and separate named database sessions; it does not fake the blocked customer transaction with an application sleep.

> This is a simulated production-support exercise, not a commercial production incident.

## Scenario

A holder transaction updates one `customer_activity` row and keeps the transaction open. A second session attempts to update the same row and becomes blocked.

The blocking session uses application name:

`opsforge-db002-holder`

The waiting session uses:

`opsforge-db002-waiter`

The customer-side operation is a normal PostgreSQL `UPDATE`. Its delay comes from the real row lock held by the other transaction.

## Required diagnosis

Before any recovery action, L2 must prove all of the following:

1. PostgreSQL is still reachable.
2. The waiter exists in `pg_stat_activity`.
3. `wait_event_type` is `Lock`.
4. `pg_blocking_pids(waiter_pid)` identifies the holder PID.
5. The holder is the expected application transaction.
6. `pg_locks` evidence is captured for both sessions.
7. The blocker is safe to terminate under the simulated approval boundary.

The incident should not be diagnosed as connection exhaustion, missing index, or database outage merely because a write is slow.

## Automated exercise

`scripts/db_incident_002.sh exercise` performs the complete controlled flow:

```text
prove normal write
    ↓
start holder transaction
    ↓
start waiting customer update
    ↓
waiter enters Lock wait
    ↓
capture pg_stat_activity + pg_blocking_pids + pg_locks
    ↓
resolve exact holder/waiter backend PIDs
    ↓
approved targeted pg_terminate_backend(holder)
    ↓
waiting UPDATE completes
    ↓
confirm zero remaining lock waiters
    ↓
run independent follow-up write
```

The holder uses `pg_sleep()` only to keep the transaction open for diagnosis. The waiting customer update itself is genuinely blocked on PostgreSQL locking.

## Evidence artifacts

The DB-002 job records:

- `baseline-target-count.txt`
- `baseline-update.txt`
- `holder-session.log`
- `waiter-session.log`
- `blocker-map.txt`
- `lock-inventory.txt`
- `session-pids.txt`
- `recovery-action.txt`
- `post-recovery-blocked-count.txt`
- `post-recovery-update.txt`

The evidence artifact is uploaded by the `OPSFORGE Deep Incidents` workflow even if the exercise fails.

## Recovery boundary

The correct recovery is not `docker restart db` and not "kill the oldest transaction."

The simulated approved action terminates only the backend proven to block the customer write. In a commercial environment, authorization may depend on session ownership, workload criticality, migration/backup/replication state, business impact, and DBA/change policy.

Escalate rather than terminate when:

- blocker ownership is unknown,
- the blocker is a migration or maintenance task,
- replication/backup safety is uncertain,
- multiple or recursive blockers are present,
- deadlock behavior is observed,
- the same contention repeatedly returns,
- the blocked workload cannot be safely released within L2 authority.

## Operational records

- `INC-1102`
- `L2N-1102`
- `RUN-DB-LOCK-CONTENTION`

## Definition of done

DB-002 is complete only when CI proves:

- baseline row update succeeds,
- a real waiter enters `wait_event_type=Lock`,
- blocker/waiter relationship is resolved with `pg_blocking_pids()`,
- lock inventory is retained,
- only the confirmed blocker is terminated,
- the previously waiting update completes,
- no exercise lock waiter remains,
- an independent post-recovery write succeeds,
- support-operation records remain valid,
- DB-001 still passes,
- full OPSFORGE release/rollback CI remains green.
