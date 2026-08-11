# NIGHTWATCH — Production Support Engineering Lab

NIGHTWATCH is a hands-on production support lab built to practice diagnosing failures across a small service stack instead of treating each tool as an isolated exercise.

The goal is simple: start from a customer-facing symptom, isolate the failing layer, collect evidence, identify the root cause, make the smallest safe recovery change, and verify service restoration.

## What this project demonstrates

- Reverse-proxy and upstream troubleshooting with Nginx
- Container lifecycle and Docker network diagnosis
- Flask API health checks and dependency failures
- PostgreSQL connectivity, authentication, locking, and schema mismatch investigation
- RabbitMQ backlog and consumer-state diagnosis
- Redis dependency health checks
- Prometheus metrics and Grafana dashboards/alerting
- Centralized Docker logs with Grafana Alloy and Loki
- Distributed tracing with OpenTelemetry and Tempo
- Kubernetes Service-to-Pod routing diagnosis
- GitHub Actions CI for syntax validation and Docker image builds

## Architecture

```text
Client
  |
  v
Nginx reverse proxy
  |
  v
Flask API -----------------> Redis
  |
  +------------------------> PostgreSQL
  |
  +------------------------> RabbitMQ ---> Worker
  |
  +-- metrics -------------> Prometheus ---> Grafana
  |
  +-- logs ----------------> Alloy ---> Loki ---> Grafana
  |
  +-- traces --------------> OpenTelemetry ---> Tempo ---> Grafana

Kubernetes is used separately to reproduce and troubleshoot Service/Pod routing failures.
```

## Incident work completed

| Incident | Symptom | Diagnosis / root cause | Recovery pattern |
|---|---|---|---|
| NW-001 | Production API unavailable | Docker network connectivity between proxy/API layers | Identify disconnected service and restore network membership |
| NW-002 | API unavailable / 502 | Backend process/container failure or broken upstream path | Confirm failing layer before restarting/reconnecting |
| NW-003 | 502 while API itself is healthy | Nginx upstream points to localhost or wrong backend target | Inspect Nginx logs/config and restore container-name upstream |
| NW-004 | 502 Bad Gateway | Wrong upstream port | Correct upstream port and reload Nginx |
| DB-001 | API returns 500 | PostgreSQL authentication failure | Inspect API traceback, correct credentials, verify DB health |
| DB-002 | DB-backed endpoint fails | PostgreSQL unavailable / hostname cannot resolve | Confirm DB container state and restore service |
| DB-003 | API request times out | PostgreSQL query blocked by an ACCESS EXCLUSIVE lock | Inspect `pg_stat_activity`, identify blocker, terminate only the blocking session |
| DB-004 | API returns 500 | Application query expects a column missing from current schema | Compare application query with schema and restore compatible column |
| MQ-001 | Jobs accumulate | Worker stopped; queue shows messages ready with zero consumers | Restore consumer and verify queue drains |
| MQ-002 | Consumer exists but work does not complete | Messages remain unacknowledged while worker is paused/stuck | Inspect ready/unacknowledged counts and recover consumer processing |
| CACHE-001 | Cache health endpoint fails | Redis unavailable | Verify dependency-specific failure, restore Redis, confirm 200 response |
| K8S-001 | Pod healthy but Service unreachable | Service selector does not match Pod labels; EndpointSlice has no usable endpoint | Correct selector and verify endpoint/service recovery |

The repository also includes PowerShell incident injectors for the reverse-proxy/container scenarios so failures can be reproduced without knowing the exact fault in advance.

## Investigation style

The exercises follow a production-support workflow rather than a restart-first workflow:

```text
Customer symptom
    ↓
Reproduce / verify impact
    ↓
Identify failing layer
    ↓
Collect logs, status, metrics or DB evidence
    ↓
Form root-cause hypothesis
    ↓
Apply smallest safe corrective action
    ↓
Verify recovery from the customer-facing endpoint
```

Examples include using Nginx error logs to distinguish proxy failures from backend failures, Docker state/events to inspect stopped containers, PostgreSQL `pg_stat_activity` to isolate a blocker, RabbitMQ queue counters to distinguish a missing consumer from a stuck consumer, and Kubernetes EndpointSlices to prove a Service selector mismatch.

## Repository structure

```text
.github/workflows/ci.yml    GitHub Actions CI
api/                        Flask API + Dockerfile
worker/                     RabbitMQ worker + Dockerfile
nginx/                      Reverse-proxy image/config
prometheus/                 Prometheus scrape configuration
alloy/                      Docker log collection configuration
loki/                       Loki configuration
tempo/                      Tempo tracing configuration
inject-nw001.ps1            Failure injection
inject-nw002.ps1            Failure injection
inject-nw003.ps1            Failure injection
inject-nw004.ps1            Failure injection
```

## API endpoints

The Flask service exposes small operational endpoints used during investigation:

- `/health` — API process health
- `/db-health` — PostgreSQL connectivity
- `/cache-health` — Redis connectivity
- `/api/tickets` — DB-backed application endpoint
- `/metrics` — Prometheus metrics exposed by `prometheus-flask-exporter`

Service credentials are read from environment variables rather than committed into the application source.

## Observability

NIGHTWATCH combines the three main observability signals:

**Metrics:** Prometheus scrapes the Flask metrics endpoint and Grafana visualizes service state. A basic API-down alert was configured against the Prometheus `up` signal.

**Logs:** Grafana Alloy discovers Docker containers, collects their logs, and forwards them to Loki. Grafana Explore is used to query service-specific error logs centrally.

**Traces:** The Flask API is instrumented with OpenTelemetry and exports OTLP traces to Tempo. Grafana can then show the request trace and individual spans for endpoints such as `GET /api/tickets`.

## CI

GitHub Actions runs on pushes and pull requests to `main` and currently performs:

1. Repository checkout
2. Python 3.13 setup
3. API dependency installation
4. Python syntax validation
5. NIGHTWATCH API Docker build
6. NIGHTWATCH worker Docker build

The first public workflow run completed successfully.

## Why I built this

I built NIGHTWATCH to strengthen practical L2 / Application Support / Production Support troubleshooting skills. The focus is not on claiming production scale; it is on demonstrating a repeatable diagnostic process across realistic failure modes involving proxies, containers, databases, queues, caches, observability tooling, and Kubernetes networking.

## Tech stack

`Python` · `Flask` · `Docker` · `Nginx` · `PostgreSQL` · `RabbitMQ` · `Redis` · `Prometheus` · `Grafana` · `Grafana Alloy` · `Loki` · `OpenTelemetry` · `Tempo` · `Kubernetes` · `Kind` · `GitHub Actions` · `PowerShell`
