# NIGHTWATCH Production Support Lab

NIGHTWATCH is a self-built production-support environment used to reproduce, investigate, resolve, and document realistic application and infrastructure failures.

The focus is not feature development. It is troubleshooting: establish a healthy baseline, reproduce the symptom, collect evidence, isolate the failing layer, apply a controlled fix, and verify recovery.

> All incidents are intentionally reproduced in a training environment. This repository is portfolio evidence, not employer production experience.

---

## 90-second hiring-manager review

If you only review a few cases, start here:

1. [INC-018 — RabbitMQ publish failure](./incidents/INC-018-rabbitmq-publish-failure/README.md): partial success, HTTP 503, persistent database state, duplicate-retry risk.
2. [INC-019 — PostgreSQL row-lock contention](./incidents/INC-019-postgresql-row-lock-contention/README.md): blocking-session identification with `pg_stat_activity` and `pg_blocking_pids()`.
3. [INC-021 — Worker outage and queue backlog](./incidents/INC-021-worker-queue-backlog/README.md): healthy broker, zero consumers, 114 queued jobs, recovery and queue-drain validation.
4. [INC-022 — PostgreSQL connection exhaustion](./incidents/INC-022-postgresql-connection-exhaustion/README.md): database process healthy but new clients rejected because connection capacity was exhausted.
5. [INC-024 — Storage pressure / ENOSPC](./incidents/INC-024-storage-pressure-enospc/README.md): controlled filesystem exhaustion and risk-aware recovery testing.

These cases show the main capability this project is intended to demonstrate: distinguishing the visible symptom from the actual failing layer.

---

## Investigation model

```text
Symptom
  -> Reproduce
  -> Establish baseline
  -> Logs / metrics / traces / database state
  -> Isolate the failing layer
  -> Root cause
  -> Smallest safe fix
  -> Recovery validation
  -> RCA / prevention
```

A 502 does not automatically mean the backend is down. A healthy broker does not mean consumers are running. A running PostgreSQL process does not mean new sessions can connect or every transaction can make forward progress.

---

## Architecture

```text
Browser / API Client
        |
        v
      Nginx
   HTTP / HTTPS
        |
        v
     Flask API
        |
   +----+---------+
   |      |       |
PostgreSQL Redis RabbitMQ
                  |
                Worker

Observability
--------------------------------
Prometheus -> Metrics
Grafana    -> Dashboards
Loki       -> Logs
Tempo      -> Traces
Alloy      -> Telemetry collection
OpenTelemetry instrumentation
```

The stack runs locally with Docker Compose.

For more detail, see [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md).

---

## Incident portfolio

| Incident | Failure investigated | Main support signal |
|---|---|---|
| [INC-015](./incidents/INC-015-dns-service-resolution/README.md) | Docker DNS / service-resolution failure | Backend healthy directly while Nginx returned 502 |
| [INC-016](./incidents/INC-016-tls-hostname-mismatch/README.md) | TLS hostname mismatch | Trust succeeded but SAN/hostname verification failed |
| [INC-017](./incidents/INC-017-cors-preflight-failure/README.md) | Browser CORS / preflight failure | API worked with curl while browser request was blocked |
| [INC-018](./incidents/INC-018-rabbitmq-publish-failure/README.md) | RabbitMQ publish failure | PostgreSQL write succeeded before asynchronous publish failed |
| [INC-019](./incidents/INC-019-postgresql-row-lock-contention/README.md) | PostgreSQL row-lock contention | Waiter mapped to the exact blocking backend |
| [INC-020](./incidents/INC-020-redis-readiness-degradation/README.md) | Redis readiness degradation | Readiness failed while tested business reads remained available |
| [INC-021](./incidents/INC-021-worker-queue-backlog/README.md) | Worker outage / queue backlog | 114 ready messages, zero consumers, broker healthy |
| [INC-022](./incidents/INC-022-postgresql-connection-exhaustion/README.md) | PostgreSQL connection exhaustion | New clients rejected while PostgreSQL remained running |
| [INC-023](./incidents/INC-023-postgresql-slow-query/README.md) | Long-running PostgreSQL session | Session-level latency isolated from database-wide availability |
| [INC-024](./incidents/INC-024-storage-pressure-enospc/README.md) | Filesystem capacity exhaustion | ENOSPC reproduced in an isolated disposable filesystem |

---

## Examples of layered troubleshooting

### Nginx 502 vs backend health

INC-015 verifies the API directly before blaming the application. The backend returned HTTP 200 while Nginx failed because the configured upstream hostname could not be resolved inside the Docker network.

### Browser failure vs API failure

INC-017 separates browser security behavior from API availability. `curl` succeeded, while Chrome DevTools exposed a failed preflight caused by missing CORS headers.

### API failure vs persistent state

INC-018 demonstrates partial failure. The ticket was committed to PostgreSQL before RabbitMQ publish failed, so an HTTP 503 did not mean "nothing happened." The stored state had to be checked before considering a retry.

### Database process health vs transaction progress

INC-019 uses PostgreSQL wait events and blocking-PID evidence to identify a specific blocking backend. Recovery targets the blocker instead of restarting the database.

### Broker health vs consumer health

INC-021 shows RabbitMQ healthy while the worker was absent. Queue depth increased to 114 messages with zero consumers; restarting the worker restored one consumer and drained the backlog to zero.

### Database health vs connection capacity

INC-022 shows PostgreSQL still running while new clients were rejected with `FATAL: sorry, too many clients already`. The problem was capacity, not a database crash.

---

## Observability

NIGHTWATCH uses multiple telemetry signals during troubleshooting:

- **Prometheus** — metrics
- **Grafana** — dashboards
- **Loki** — centralized logs
- **Tempo** — distributed traces
- **Grafana Alloy** — telemetry and log collection
- **OpenTelemetry** — API instrumentation

The investigation model is deliberately simple:

```text
Metrics -> What changed?
Logs    -> What failed?
Traces  -> Where did the request fail?
State   -> What actually happened to the data or dependency?
```

---

## PostgreSQL persistence and schema recovery

During baseline testing, `/api/tickets` returned HTTP 500 even though the API process itself was running.

Application logs showed:

```text
psycopg.errors.UndefinedTable: relation "tickets" does not exist
```

Inspection showed the application schema had disappeared because PostgreSQL had no persistent data volume. The environment was corrected with a named volume and repeatable schema initialization, then validated with restored tables, seed data, and HTTP 200 responses.

---

## Core stack

Python | Flask | PostgreSQL | Redis | RabbitMQ | Nginx | Docker | Docker Compose | Prometheus | Grafana | Loki | Tempo | Alloy | OpenTelemetry | GitHub Actions | PowerShell | Chrome DevTools

---

## Repository structure

```text
api/          Flask API
worker/       RabbitMQ consumer
nginx/        Reverse proxy and HTTPS configuration
db/           PostgreSQL schema initialization
frontend/     Browser integration / CORS test client
prometheus/   Metrics configuration
loki/         Centralized log configuration
tempo/        Trace storage configuration
alloy/        Telemetry collection
incidents/    Detailed incident investigations
docs/         Architecture and support documentation
```

---

## CI

GitHub Actions validates pushes and pull requests to `main`, including:

- Python environment setup
- API dependency installation
- Python syntax validation
- NIGHTWATCH API Docker build
- NIGHTWATCH worker Docker build

---

## Support skills demonstrated

- Incident reproduction and triage
- REST API and HTTP troubleshooting
- Nginx reverse-proxy diagnostics
- PostgreSQL sessions, locks, capacity and availability analysis
- RabbitMQ queue and worker troubleshooting
- Redis dependency troubleshooting
- Partial-failure and data-consistency reasoning
- Docker networking and service discovery
- TLS / HTTPS troubleshooting
- CORS and browser troubleshooting
- Linux filesystem and ENOSPC diagnosis
- Metrics, logs and distributed tracing
- Root-cause analysis and recovery validation
- Technical incident documentation
- Git-based change management

---

## Scope and honesty boundary

This lab supports claims of hands-on troubleshooting practice, evidence collection, incident reasoning, service recovery, and technical documentation.

It does **not** prove employer production ownership, on-call tenure, real customer SLA performance, or production incident volume. Those are intentionally not claimed.
