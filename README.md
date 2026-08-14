# NIGHTWATCH Production Support Lab

NIGHTWATCH is a self-built production support environment where I reproduce, investigate, resolve, and document realistic application and infrastructure incidents.

The focus is troubleshooting: establish a healthy baseline, isolate the failing layer, use evidence instead of assumptions, apply a controlled fix, and verify recovery.

> All incidents are intentionally reproduced in a training environment. This repository is portfolio evidence, not employer production experience.

---

## What NIGHTWATCH demonstrates

Typical investigation flow:

`Symptom -> Reproduce -> Baseline -> Logs / Metrics / Traces -> Isolate layer -> Root cause -> Fix -> Recovery validation -> RCA`

The environment intentionally contains multiple layers so the visible symptom is not always where the actual fault exists.

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
   +----+-----+
   |          |
PostgreSQL   Redis
              |
           RabbitMQ
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

---

## Selected incidents

### INC-015 - Docker DNS / Service Resolution Failure

A healthy API returned HTTP 200 directly while Nginx returned HTTP 502.

Nginx logs showed that the configured upstream hostname could not be resolved inside the Docker network.

The incident isolated the failure to Docker DNS / service discovery rather than the application process.

**Demonstrated:** HTTP 502 troubleshooting, Nginx logs, Docker networking, service discovery, direct backend health checks, RCA and recovery validation.

[View INC-015](./incidents/INC-015-dns-service-resolution/README.md)

---

### INC-016 - TLS Certificate Hostname Mismatch

HTTPS failed when the client hostname did not match the certificate Subject Alternative Name.

Certificate trust and hostname verification were tested separately so the failure could be identified specifically as an identity mismatch rather than an untrusted certificate.

A corrected certificate containing `nightwatch.local` in the SAN was deployed and HTTPS recovered successfully.

**Demonstrated:** TLS diagnostics, CN/SAN inspection, trust vs hostname validation, curl verbose output, Nginx HTTPS configuration and recovery testing.

[View INC-016](./incidents/INC-016-tls-hostname-mismatch/README.md)

---

### INC-017 - Browser CORS / Preflight Failure

The `/api/tickets` endpoint returned HTTP 200 through curl, while the browser frontend failed with `TypeError: Failed to fetch`.

Chrome DevTools showed that the browser blocked the request because the preflight response did not contain the required CORS headers.

Nginx was updated to explicitly allow the frontend origin, GET/OPTIONS methods, and Authorization/Content-Type headers.

Recovery validation showed:

```text
OPTIONS preflight -> HTTP 204
Access-Control-Allow-Origin -> http://localhost:3001
Browser fetch -> successful
Chrome DevTools -> no CORS errors
```

**Demonstrated:** browser vs API troubleshooting, Chrome DevTools, OPTIONS preflight analysis, HTTP headers, CORS configuration, Nginx and recovery validation.

[View INC-017](./incidents/INC-017-cors-preflight-failure/README.md)

---

## PostgreSQL persistence and schema recovery

During baseline testing for INC-017, `/api/tickets` unexpectedly returned HTTP 500 both through Nginx and directly from the API.

Application logs showed:

```text
psycopg.errors.UndefinedTable: relation "tickets" does not exist
```

Database inspection showed zero application tables.

The PostgreSQL container had no persistent data volume, so recreating the container had removed the database state.

The environment was corrected with:

- a persistent PostgreSQL named volume
- repeatable `db/init.sql` schema initialization
- seed ticket data

After PostgreSQL was recreated, the expected table and records were present and `/api/tickets` returned HTTP 200.

---

## Observability

NIGHTWATCH uses multiple telemetry signals during troubleshooting:

- **Prometheus** - metrics
- **Grafana** - dashboards
- **Loki** - centralized logs
- **Tempo** - distributed traces
- **Grafana Alloy** - telemetry and log collection
- **OpenTelemetry** - API instrumentation

The investigation model is simple:

```text
Metrics -> What changed?
Logs    -> What failed?
Traces  -> Where did the request fail?
```

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

GitHub Actions runs validation on pushes and pull requests to `main`, including:

- Python environment setup
- API dependency installation
- Python syntax validation
- NIGHTWATCH API Docker build
- NIGHTWATCH worker Docker build

---

## Support skills demonstrated

- Incident reproduction and triage
- REST API troubleshooting
- HTTP status and header analysis
- Nginx reverse-proxy diagnostics
- PostgreSQL troubleshooting
- Docker networking and service discovery
- TLS / HTTPS troubleshooting
- CORS and browser troubleshooting
- Chrome DevTools investigation
- Metrics, logs and distributed tracing
- Root cause analysis
- Recovery validation
- Technical documentation
- Customer-facing incident communication
- Git-based change management

---

## Why this project exists

A 502 does not automatically mean the backend is down.

An HTTP 200 OPTIONS response does not automatically mean CORS is valid.

A trusted TLS certificate does not automatically mean its hostname is correct.

A running PostgreSQL container does not automatically mean its expected schema exists.

NIGHTWATCH is built around investigating those distinctions.
