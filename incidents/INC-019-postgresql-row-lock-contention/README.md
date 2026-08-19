# INC-019 — PostgreSQL Row-Lock Contention

**Project:** NIGHTWATCH Production Support Lab  
**Environment:** Docker Compose / PostgreSQL / PowerShell  
**Severity:** SEV2 — simulated database contention affecting request completion  
**Status:** Resolved  
**Type:** PostgreSQL / Lock Contention / Transaction Blocking

## Customer Report

A customer reports that a write operation appears to hang even though PostgreSQL is running and basic database health checks succeed.

## Impact

The database remained reachable, but one transaction held a row lock on `customer_activity.id = 84` while a second session attempted to update the same row.

The second session became blocked waiting on a PostgreSQL lock. This models a production condition where the service is technically online while one request path experiences severe latency or timeout risk.

## Healthy Baseline

Before injection, the target row was confirmed present and writable.

A baseline update completed successfully:

```text
UPDATE 1
```

A global blocked-session check returned zero blocked sessions.

```text
INC-019 baseline healthy: target row writable and no blocked sessions.
```

## Incident Injection

Two named PostgreSQL sessions were created:

- `opsforge-inc019-blocker`
- `opsforge-inc019-waiter`

The blocker began a transaction and updated the target row without committing immediately.

The waiter then attempted to update the same row and entered a lock wait.

## Diagnostic Evidence

PostgreSQL session inspection identified the blocked and blocking backends.

Measured evidence from the validated exercise:

```text
blocked_pid  = 7095
blocked_app  = opsforge-inc019-waiter
blocked_state = active
wait_event_type = Lock
wait_event = transactionid

blocker_pid  = 7081
blocker_app  = opsforge-inc019-blocker
blocker_state = active
```

The blocker transaction age was approximately:

```text
00:00:00.705422
```

The waiter query was the competing `UPDATE customer_activity ...` statement, while the blocker query belonged to the open transaction that had already modified the same row.

## Investigation

### 1. Verified Database Availability

PostgreSQL remained reachable throughout the incident.

This ruled out a database outage.

### 2. Verified the Failure Was a Lock Wait

`pg_stat_activity` showed the waiter as active with:

```text
wait_event_type = Lock
wait_event = transactionid
```

This demonstrated that the query was not CPU-bound, network-bound, or waiting on I/O.

### 3. Identified the Exact Blocker

`pg_blocking_pids()` was used against the waiter session to return the backend responsible for the block.

This mapped:

```text
waiter PID 7095 -> blocker PID 7081
```

### 4. Correlated Both Sessions by Application Name

Named `application_name` values made the simulated application sessions easy to distinguish from unrelated database activity.

## Root Cause

An open PostgreSQL transaction had already updated the target row and continued holding the row-level lock.

A second transaction attempted to update the same row and could not proceed until the first transaction completed.

The visible symptom was a hanging or delayed write even though PostgreSQL remained fully reachable.

## Resolution

The blocker was not terminated blindly.

The recovery process first proved the blocker relationship using `pg_blocking_pids()`, captured the exact blocker PID, and then terminated only that evidence-matched backend with `pg_terminate_backend()`.

After the blocker was terminated:

- the blocked waiter was released,
- the competing write completed,
- the simulated incident sessions disappeared,
- the target row became writable again.

## Recovery Validation

The post-recovery update returned:

```text
UPDATE 1
```

The runner completed with:

```text
INC-019 exercise verified: live row-lock contention captured, blocker identified with pg_blocking_pids(), targeted backend terminated, waiter released, and write path recovered.
```

## Layer Isolation

| Layer | Result |
|---|---|
| PostgreSQL process | Healthy |
| Database connectivity | Healthy |
| Target row baseline write | Successful |
| Waiter session | Active but blocked |
| Wait type | Lock |
| Wait event | transactionid |
| Blocking backend identified | Yes |
| Recovery action | Targeted `pg_terminate_backend()` |
| Waiter released after mitigation | Yes |
| Post-recovery target write | Successful |

## Operational Risk

This class of incident is dangerous because broad health checks can remain green while customer requests stall.

If not diagnosed correctly, support teams may restart the database or application unnecessarily instead of identifying the exact blocking transaction.

Long-lived blockers can also cause:

- request timeouts,
- queue buildup,
- connection-pool pressure,
- cascading latency,
- repeated client retries.

## Customer Update — Investigation

The database service is online, but one write path is waiting on a PostgreSQL lock. We are tracing the blocking transaction rather than treating this as a database outage.

## Customer Update — Root Cause Identified

A long-running transaction is holding the row needed by the affected write. The blocked request and blocker have been correlated at the PostgreSQL backend level.

## Customer Update — Resolved

The evidence-matched blocking backend was terminated. The waiting transaction was released and subsequent writes completed normally.

## Preventive Actions

- Track long-running and open transactions.
- Set appropriate transaction and statement timeouts.
- Expose database wait-event metrics and blocked-session counts.
- Include `application_name` in database connection configuration for easier correlation.
- Alert on sustained lock waits rather than only database availability.
- Avoid broad database restarts when a targeted blocker can be identified safely.
- Review application transaction boundaries and commit/rollback behavior.
- Use `pg_stat_activity`, `pg_locks`, and `pg_blocking_pids()` during lock investigations.

## Support Skills Demonstrated

- PostgreSQL lock troubleshooting
- `pg_stat_activity` analysis
- `pg_blocking_pids()` diagnosis
- Transaction and row-lock reasoning
- Wait-event interpretation
- Targeted backend recovery
- Production-safe evidence gathering
- Root cause analysis
- Recovery validation
- Customer-facing incident communication

> This incident was intentionally reproduced in a self-built training environment. It is portfolio evidence and not employer production experience.
