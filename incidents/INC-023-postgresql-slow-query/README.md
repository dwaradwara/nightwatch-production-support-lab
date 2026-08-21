\# INC-023 — PostgreSQL Slow Query / Latency Investigation



\## Summary



A controlled long-running PostgreSQL query was introduced in the NIGHTWATCH lab to validate slow-query diagnosis without simulating a full database outage.



The query remained active for an extended period and was identified through `pg\_stat\_activity`. During the incident, PostgreSQL continued responding to new queries and application readiness remained healthy.



This demonstrated the difference between a slow individual session and a database-wide availability failure.



\## Baseline



Before the incident:



\* PostgreSQL was healthy.

\* Application readiness returned HTTP 200.

\* No suspicious long-running client query was present.

\* `track\_activity\_query\_size` was configured at 1 kB.

\* `pg\_stat\_statements` was not installed, so investigation relied on `pg\_stat\_activity`.



\## Failure Injection



A tagged long-running query was started:



```text

SET application\_name='opsforge-inc023-slow';

SELECT pg\_sleep(60);

```



\## Observed Symptoms



`pg\_stat\_activity` showed:



```text

pid                = 27865

application\_name   = opsforge-inc023-slow

state              = active

wait\_event\_type    = Timeout

wait\_event         = PgSleep

runtime            ≈ 15 seconds

```



The session was clearly identifiable by its application name.



\## Investigation



\### 1. Verified the Slow Session



The long-running query was visible in `pg\_stat\_activity` with:



\* active state

\* explicit application name

\* measurable runtime

\* identifiable wait event



\### 2. Verified Database Availability



A separate query succeeded:



```text

SELECT now();

```



This confirmed PostgreSQL itself remained responsive.



\### 3. Verified Application Readiness



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



\### 4. Distinguished Session-Level Latency From Service Failure



The incident was isolated to one long-running session.



The database and application continued serving other requests normally.



\## Root Cause



The observed latency was caused by a deliberately long-running PostgreSQL session.



The database was not unavailable and no infrastructure dependency had failed.



The condition was limited to a single query.



\## Resolution



The long-running query completed naturally.



A follow-up check confirmed:



```text

0 rows

```



for:



```text

application\_name = opsforge-inc023-slow

```



Application readiness remained HTTP 200 after the session completed.



\## Preventive Actions



\* Monitor long-running queries using `pg\_stat\_activity`.

\* Track query runtime and application name.

\* Configure appropriate `statement\_timeout` values.

\* Consider enabling `pg\_stat\_statements` for historical query analysis.

\* Alert on queries exceeding expected execution thresholds.

\* Distinguish database availability from query-level latency.

\* Use application names to improve session attribution.

\* Investigate repeated slow-query patterns before they become capacity incidents.



\## Support Skills Demonstrated



\* PostgreSQL slow-query diagnosis

\* `pg\_stat\_activity` analysis

\* Wait-event interpretation

\* Session-level troubleshooting

\* Database availability verification

\* Query runtime analysis

\* Application readiness correlation

\* Root-cause isolation

\* Production-style latency investigation



> This incident was intentionally reproduced in a self-built training environment. It is portfolio evidence and not employer production experience.



