# OPSFORGE DB-004 — PostgreSQL Connection Exhaustion

DB-004 trains diagnosis of PostgreSQL client-slot saturation. The exercise intentionally keeps PostgreSQL running while ordinary non-superuser application connections fail, so L2 must distinguish connection-capacity exhaustion from a database process outage.

> This is a simulated production-support exercise, not a commercial production incident.

## Scenario

The isolated DB-004 environment temporarily reduces `max_connections` to a small controlled value. A dedicated non-superuser role (`opsforge_app`) then opens named sessions until every ordinary application slot is consumed.

Pool session prefix:

`opsforge-db004-pool-*`

A separate application probe then attempts a new connection and must fail with a PostgreSQL connection-slot exhaustion error. The administrative `nightwatch` role retains access through PostgreSQL's reserved superuser slots so L2 can investigate the live server.

## Why this is different from DB-002 and DB-003

- DB-002: a connected transaction waits on a lock.
- DB-003: a connected session remains idle in an open transaction.
- DB-004: a new ordinary client cannot establish a PostgreSQL session at all because ordinary connection capacity is consumed.

A green PostgreSQL process or successful administrative query therefore does not prove that the application can acquire a database connection.

## Required diagnosis

Before mitigation L2 must prove:

1. PostgreSQL is still reachable through the reserved administrative path.
2. `max_connections` and reserved-connection settings are captured.
3. The ordinary application slot budget is calculated from those settings.
4. `pg_stat_activity` shows the named simulated pool consuming that budget.
5. A separate non-superuser application probe reproduces the connection-slot exhaustion error.
6. The incident is not being misdiagnosed as authentication, network, lock contention, or slow-query behavior.
7. The exact pool session selected for mitigation is known and approved.

## Automated exercise

`scripts/db_incident_004.sh exercise` performs:

```text
prove normal application connection
    ↓
reduce max_connections in isolated DB-004 database
    ↓
create non-superuser application role
    ↓
fill all ordinary connection slots with named pool sessions
    ↓
prove fresh application connection fails
    ↓
capture settings + pg_stat_activity + reserved admin proof
    ↓
select one evidence-matched pool backend
    ↓
approved targeted pg_terminate_backend()
    ↓
prove fresh application connection succeeds
    ↓
clean remaining simulated sessions
    ↓
restore isolated max_connections override
```

## Lowest-blast-radius recovery

The exercise deliberately releases only one ordinary slot first. If one targeted termination restores a new application connection, broad session termination or PostgreSQL restart would be unnecessary and harder to justify.

Changing `max_connections` is also not treated as an incident-time quick fix. Raising it can increase memory/resource pressure and normally requires DBA/capacity review.

## Evidence artifacts

The job records evidence including:

- baseline and incident `max_connections`
- calculated ordinary slot budget
- pool session count
- connection settings
- `pg_stat_activity` session inventory
- failed ordinary application probe
- successful reserved administrative probe
- targeted recovery PID/application name
- `pg_terminate_backend()` result
- successful post-recovery application probe
- remaining pool-session count
- restored configuration value

## Completion criteria

DB-004 passes only when:

- ordinary application slots are demonstrably saturated,
- a new ordinary application connection fails for the expected PostgreSQL capacity reason,
- administrative diagnosis remains possible,
- one named simulated pool backend is targeted,
- a fresh ordinary application connection succeeds after that single slot is released,
- PostgreSQL stays reachable,
- the isolated connection-limit override is restored.

The durable lesson is not "kill sessions." It is: prove the capacity boundary, identify the consumer, use the smallest safe mitigation, and prove customer-facing connection acquisition has recovered.
