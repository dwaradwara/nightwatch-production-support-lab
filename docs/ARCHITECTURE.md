# NIGHTWATCH Architecture

NIGHTWATCH is intentionally small enough to run locally but layered enough to reproduce the kinds of dependency failures that appear in L2 / application-support work.

## Request path

```text
Client
  |
  v
Nginx :8080
  |
  v
Flask API :8000
  |---- PostgreSQL :5432
  |---- Redis :6379
  |---- RabbitMQ :5672 ---> Worker
  |
  |---- /metrics ----------> Prometheus :9090 ---> Grafana
  |---- Docker logs -------> Alloy ------> Loki :3100 ---> Grafana
  |---- OTLP traces ---------------------> Tempo :4318 ---> Grafana
```

## Why the layers matter

A customer-facing `500`, `502`, timeout, or unavailable endpoint can originate from very different layers. NIGHTWATCH keeps those layers separate so diagnosis can proceed from symptom to component instead of jumping immediately to restarts.

### Reverse proxy

Nginx is the public entry point. Its job is to route requests to `nightwatch-api:8000`. Misconfigured hostnames, ports, or container-network membership can therefore break the production endpoint while the API itself remains healthy.

### API

The Flask API exposes health, dependency-health, application, and metrics endpoints. PostgreSQL and Redis are deliberately external dependencies rather than embedded state.

### PostgreSQL

The database supports incidents involving authentication, availability, schema compatibility, and lock contention. `pg_stat_activity` is used to distinguish database-server health from session-level blocking.

### RabbitMQ + worker

The queue layer demonstrates asynchronous failure modes. Queue counters distinguish a missing consumer from a connected consumer that is stuck with unacknowledged work.

### Redis

Redis is used as a separate cache dependency so a cache outage can be isolated from API-process and database health.

## Observability

NIGHTWATCH uses all three core signals.

### Metrics

Prometheus scrapes the Flask `/metrics` endpoint every five seconds. Grafana is used for the API-status panel and alerting.

### Logs

Grafana Alloy discovers Docker containers through the Docker socket and forwards their logs to Loki with a `service_name` label. Grafana Explore provides centralized investigation rather than requiring individual `docker logs` commands for every service.

### Traces

The API runs through `opentelemetry-instrument` and exports OTLP traces to Tempo. This provides request-level timing and spans for Flask endpoints such as `GET /api/tickets`.

## Kubernetes exercise

Kubernetes is kept as a separate incident domain. The NIGHTWATCH API image is loaded into a Kind cluster and exposed through a Service. The K8S-001 exercise intentionally creates a Service-selector/Pod-label mismatch, producing a healthy Pod with no Service backend EndpointSlice.

## CI

GitHub Actions validates the Python application and builds both Docker images on pushes and pull requests to `main`. This catches syntax/dependency/build breakage before changes are treated as usable lab state.

## Operating principle

The project is built around one rule:

> Do not change a component until evidence points to that component.

That means checking the public path, direct backend path, container state, logs, database errors, queue counters, metrics, traces, labels, selectors, and EndpointSlices as appropriate before recovery actions are applied.
