# OPSFORGE DB-003 — PostgreSQL Long-Running Transaction

DB-003 trains evidence-driven diagnosis of a PostgreSQL session left `idle in transaction`. The database remains reachable and no customer lock waiter is required for detection, so the exercise teaches proactive transaction-risk handling rather than another outage/lock-contention scenario.

> This is a simulated production-support exercise, not a commercial production incident.

## Scenario

A named client session starts a transaction, performs an update, and then stops sending commands while leaving the transaction open.

Application name:

`opsforge-db003-idle-transaction`

The session is expected to appear in `pg_stat_activity` as:

- `state = 'idle in transaction'`
- non-null `xact_start`
- transaction age above the exercise threshold
- client wait context such as `ClientRead`

The session may retain locks/resources even though PostgreSQL health checks remain green.

## Why this is different from DB-002

DB-002 begins with a customer write already blocked by another transaction. DB-003 does not require a blocked waiter. L2 must recognize that a stale open transaction can be an operational risk before it becomes visible customer contention.

## Required diagnosis

Before recovery L2 must prove:

1. PostgreSQL is reachable.
2. The named session exists.
3. Its state is `idle in transaction`.
4. `xact_start` is present and transaction age exceeds the exercise threshold.
5. Application identity and last query are captured.
6. Locks held by the session are captured.
7. Lock-waiting sessions are checked separately rather than assumed.
8. The exact backend is approved for targeted termination.

Age alone is not sufficient reason to kill a production backend.

## Automated flow

`scripts/db_incident_003.sh exercise` runs:

```text
prove clean baseline
    ↓
open named transaction
    ↓
perform update
    ↓
client stops sending commands
    ↓
transaction becomes idle in transaction
    ↓
wait until age threshold is crossed
    ↓
capture pg_stat_activity + pg_locks
    ↓
prove exact session identity/state/age
    ↓
approved targeted pg_terminate_backend()
    ↓
verify session disappears
    ↓
verify independent write
    ↓
verify PostgreSQL reachability
```

The client-side delay is used only to leave a real PostgreSQL transaction open. The database state being diagnosed is genuine `idle in transaction` state.

## Evidence artifacts

The DB-003 CI job retains:

- `baseline-target-count.txt`
- `baseline-update.txt`
- `baseline-idle-transaction-count.txt`
- `long-transaction-session.log`
- `transaction-activity.txt`
- `transaction-locks.txt`
- `global-blocked-session-count.txt`
- `qualifying-session-count.txt`
- `recovery-target.txt`
- `recovery-action.txt`
- `post-recovery-session-count.txt`
- `post-recovery-update.txt`
- `post-recovery-db-health.txt`

## Recovery boundary

The exercise permits backend termination only when one session matches all of the controlled criteria: expected application name, `idle in transaction` state, non-null transaction start, and age above the exercise threshold.

In a commercial environment L2 may need DBA/application/change approval before terminating any session. Business ownership, transaction purpose, replication/maintenance implications, and recurrence must be considered.

Restarting PostgreSQL is explicitly not part of DB-003.

## Definition of done

DB-003 is complete when one final branch head proves:

- DB-001 still passes
- DB-002 still passes
- DB-003 creates a genuine idle-in-transaction session
- transaction state and age are captured before recovery
- held-lock evidence is captured
- targeted recovery removes only the evidence-matched session
- independent write and database-health verification pass afterward
- Phase 5 support records validate
- the full staging/production/bad-release/rollback OPSFORGE pipeline remains green
