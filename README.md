# NIGHTWATCH — Production Support Engineering Lab

NIGHTWATCH is a hands-on production support lab built around one idea: **start with the customer-facing symptom, isolate the failing layer, collect evidence, make the smallest safe recovery change, and verify restoration through the original path.**

It is designed for practical L2 Technical Support, Application Support, Production Support, Product Support and junior SRE/NOC-adjacent troubleshooting—not as a claim of commercial production ownership.

## Start here

- **[Incident Casebook](docs/INCIDENTS.md)** — six strongest investigations with symptom, evidence, root cause, recovery and verification.
- **[Architecture](docs/ARCHITECTURE.md)** — request path, dependencies and observability design.
- **[Recruiter Notes](docs/RECRUITER-NOTES.md)** — 30-second summary, strongest examples and interview/resume wording.
- **[GitHub Actions CI](.github/workflows/ci.yml)** — Python validation plus API and worker image builds.

## Architecture

```text
Client
  |
  v
Nginx :8080
  |
  v
Flask API :8000
  |---- PostgreSQL
  |---- Redis
  |---- RabbitMQ ---> Worker
  |
  |---- metrics ---> Prometheus ---> Grafana
  |---- logs ------> Alloy ---> Loki ---> Grafana
  |---- traces ----> OpenTelemetry ---> Tempo ---> Grafana

Kubernetes / Kind is used separately for Service-to-Pod routing incidents.
```

## What this project demonstrates

- Reverse-proxy and upstream troubleshooting with Nginx
- Docker lifecycle, networking and service discovery diagnosis
- Flask health checks and dependency-specific failures
- PostgreSQL authentication, availability, lock contention and schema mismatch investigation
- RabbitMQ backlog and consumer-state diagnosis
- Redis dependency troubleshooting
- Prometheus metrics, Grafana dashboards and alerting
- Centralized Docker logging with Grafana Alloy + Loki
- OpenTelemetry tracing with Tempo
- Kubernetes Service/Pod/EndpointSlice diagnosis
- GitHub Actions CI and Docker image validation

## Strong incident set

| Incident | Customer symptom | Root cause / diagnosis |
|---|---|---|
| INC-NW-002 | API unavailable / `502` | API container terminated; proxy remained available |
| INC-NW-003 | `502` while direct API returned `200` | Nginx upstream pointed to the wrong host/port |
| DB-001 | DB-backed endpoint returned `500` | PostgreSQL authentication mismatch |
| DB-003 | API request timed out | Query blocked by an `ACCESS EXCLUSIVE` database lock |
| MQ-001 | Jobs accumulated | Worker absent/stuck; diagnosed using queue and consumer counters |
| K8S-001 | Pod healthy, Service unreachable | Service selector did not match Pod labels; no usable EndpointSlice |

Additional exercises covered Docker network disconnection, PostgreSQL availability and schema mismatch, Redis outage recovery, and RabbitMQ ready-vs-unacknowledged message states.

See **[docs/INCIDENTS.md](docs/INCIDENTS.md)** for the detailed investigations.

## Investigation method

```text
Customer symptom
    ↓
Reproduce / verify impact
    ↓
Identify the failing layer
    ↓
Collect logs, state, metrics or dependency evidence
    ↓
Form a root-cause hypothesis
    ↓
Apply the smallest safe corrective action
    ↓
Verify recovery through the original customer-facing path
```

A key principle throughout the project is **not to restart a component just because it is involved in the request path**. For example, a database lock incident was recovered by identifying and terminating only the blocking backend session rather than restarting PostgreSQL.

## Observability

NIGHTWATCH combines all three main observability signals:

- **Metrics:** Prometheus scrapes Flask metrics and Grafana provides service-state visualization and alerting.
- **Logs:** Alloy discovers Docker containers and forwards centralized logs to Loki for investigation in Grafana Explore.
- **Traces:** OpenTelemetry instrumentation exports OTLP traces from the Flask API to Tempo, allowing request spans such as `GET /api/tickets` to be inspected.

## Run the stack

A Docker Compose definition is included to make the service layout reproducible:

```bash
docker compose up -d --build
```

Primary local endpoints:

```text
Nginx/API       http://localhost:8080
Direct API      http://localhost:8000
Prometheus      http://localhost:9090
Loki            http://localhost:3100
Tempo           http://localhost:3200
RabbitMQ UI     http://localhost:15672
```

The API exposes:

- `/health` — API process health
- `/db-health` — PostgreSQL connectivity
- `/cache-health` — Redis connectivity
- `/api/tickets` — DB-backed application endpoint
- `/metrics` — Prometheus metrics

The Docker Compose file uses explicit **lab-only** credentials to make local startup reproducible; application source code itself reads credentials from environment variables rather than hard-coding them.

## Repository structure

```text
.github/workflows/ci.yml    CI validation and Docker builds
api/                        Flask API
worker/                     RabbitMQ consumer
nginx/                      Reverse-proxy configuration
prometheus/                 Metrics scrape configuration
alloy/                      Docker log collection
loki/                       Centralized log storage configuration
tempo/                      Trace storage / OTLP receiver configuration
docs/INCIDENTS.md           Incident casebook
docs/ARCHITECTURE.md        Architecture notes
docs/RECRUITER-NOTES.md     Recruiter/interview summary
docker-compose.yml          Reproducible local stack
inject-nw001.ps1            Failure injection
inject-nw002.ps1            Failure injection
inject-nw003.ps1            Failure injection
inject-nw004.ps1            Failure injection
```

## CI

GitHub Actions runs for pushes and pull requests to `main` and performs:

1. Repository checkout
2. Python 3.13 setup
3. API dependency installation
4. Python syntax validation
5. NIGHTWATCH API Docker build
6. NIGHTWATCH worker Docker build

The initial public workflow completed successfully.

## Why this exists

NIGHTWATCH was built to practice support engineering as a diagnostic discipline rather than as a collection of tool tutorials. The project deliberately creates situations where the visible symptom is one layer away from the actual fault—for example a healthy application behind a broken proxy, a healthy Kubernetes Pod behind a Service with no endpoints, or a healthy database process containing a session-level blocker.

## Tech stack

`Python` · `Flask` · `Docker` · `Docker Compose` · `Nginx` · `PostgreSQL` · `RabbitMQ` · `Redis` · `Prometheus` · `Grafana` · `Grafana Alloy` · `Loki` · `OpenTelemetry` · `Tempo` · `Kubernetes` · `Kind` · `GitHub Actions` · `PowerShell`
