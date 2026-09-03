# INC-019 Evidence Index — PostgreSQL Row-Lock Contention

This evidence index maps the retained screenshot from the PostgreSQL row-lock exercise to the specific claims made in the incident report.

## Selected visual evidence

| Evidence file | What it supports | Strength |
|---|---|---|
| `01-row-lock-blocker-waiter-recovery.png` | The exercise captured a blocked waiter session, identified the blocker, showed `wait_event_type = Lock` and `wait_event = transactionid`, used `pg_blocking_pids()` to identify the blocking backend, then verified the write path recovered. | Very strong |

## Claims supported by the evidence

- PostgreSQL was reachable while a specific write path was blocked.
- The issue was lock contention, not a database outage, network failure, or application crash.
- The blocker and waiter were correlated through named application sessions and backend PIDs.
- Recovery was targeted at the evidence-matched blocking backend rather than a broad database restart.
- The exercise ended with a successful post-recovery write validation.

## Evidence boundary

The screenshot was captured from the local NIGHTWATCH training environment on 2026-08-19. It is portfolio evidence for a simulated lab incident, not proof of employer production incident ownership.
