# INC-023 — PostgreSQL Slow Query / Latency Investigation

## Summary

A controlled long-running PostgreSQL query was introduced in the NIGHTWATCH lab to validate session-level latency diagnosis without simulating a full database outage.

The query remained active for an extended period and was identified through `pg_stat_activity`. During the incident, PostgreSQL continued responding to new queries and application readiness remained healthy.

This demonstrated the difference between one long-running session and a database-wide availability failure.

## Baseline

Before the incident:

- PostgreSQL was healthy.
- Application readiness returned HTTP 200.
- No suspicious long-running client query was present.
- `track_activity_query_size` was configured at 1 kB.
- `pg_stat_statements` was not installed, so investigation relied on `pg_stat_activity`.

## Failure Injection

A tagged long-running query was started:

```sql
SET application_name = 'opsforge-inc023-slow';
SELECT pg_sleep(60);
```

The application-name tag was used only to identify the controlled test session during investigation.

## Observed Symptoms

`pg_stat_activity` showed:

```text
pid                = 27865
application_name   = opsforge-inc023-slow
state              = active
wait_event_type    = Timeout
wait_event         = PgSleep
runtime            ≈ 15 seconds
```

The session was clearly identifiable by its application name.

## Investigation

### 1. Verified the long-running session

The query was visible in `pg_stat_activity` with an active state, explicit application name, measurable runtime, and identifiable wait event.

### 2. Verified database availability

A separate query succeeded:

```sql
SELECT now();
```

This confirmed PostgreSQL itself remained responsive.

### 3. Verified application readiness

The application readiness endpoint returned:

```text
HTTP/1.1 200 OK
```

with:

```text
postgresql = healthy
rabbitmq   = healthy
redis      = healthy
```

This ruled out a database-wide outage.

### 4. Distinguished session-level latency from service failure

The incident was isolated to one long-running session. The database and application continued serving other requests normally.

## Root Cause

The observed latency was caused by a deliberately long-running PostgreSQL session. The database was not unavailable and no infrastructure dependency had failed.

This lab scenario demonstrates the investigation method for a long-running session; it does not claim a real query-planning or indexing defect.

## Resolution

The long-running query completed naturally.

A follow-up check confirmed zero matching sessions for:

```text
application_name = opsforge-inc023-slow
```

Application readiness remained HTTP 200 after the session completed.

## Preventive Actions

- Monitor long-running queries using `pg_stat_activity`.
- Track query runtime and application name.
- Configure appropriate `statement_timeout` values.
- Consider enabling `pg_stat_statements` for historical query analysis.
- Alert on queries exceeding expected execution thresholds.
- Distinguish database availability from query-level latency.
- Use application names to improve session attribution.
- Investigate repeated slow-query patterns before they become capacity incidents.

## Support Skills Demonstrated

- PostgreSQL long-running-session diagnosis
- `pg_stat_activity` analysis
- Wait-event interpretation
- Session-level troubleshooting
- Database availability verification
- Query runtime analysis
- Application readiness correlation
- Root-cause isolation

> This incident was intentionally reproduced in a self-built training environment. It is portfolio evidence and not employer production experience.
