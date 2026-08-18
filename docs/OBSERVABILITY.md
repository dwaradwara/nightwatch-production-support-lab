# OPSFORGE Production Observability

Phase 4 turns the NIGHTWATCH stack into an evidence-driven L2 investigation environment. The purpose is not to collect every possible metric. The purpose is to let an operator answer four questions quickly:

1. Are customers affected?
2. Is the API failing or slowing down?
3. Which dependency or data path is under pressure?
4. Is asynchronous work backing up or failing?

## Investigation order

Use the `OPSFORGE L2 Operations` Grafana dashboard from top to bottom rather than restarting services at random.

### 1. Confirm customer impact

Start with `nightwatch_synthetic_customer_path_up` and the synthetic journey history. This tests the complete create -> RabbitMQ -> worker -> database -> update path. A green container or `/health` endpoint is not sufficient evidence that the service is usable.

### 2. Inspect API RED signals

The dashboard exposes:

- request rate: `opsforge:http_requests:rate5m`
- 5xx rate: `opsforge:http_5xx:rate5m`
- 5xx ratio: `opsforge:http_5xx:ratio5m`
- p95 latency: `opsforge:http_request_duration_seconds:p95_5m`
- p99 latency: `opsforge:http_request_duration_seconds:p99_5m`

Interpret rate, errors and duration together. A high percentage based on almost no traffic is different from a high percentage during normal load.

## Dependency evidence

### PostgreSQL

`postgres_exporter` exposes server-side database state while the application continues to expose operation-level query duration.

High-value signals:

- `opsforge:postgres_connections`
- `opsforge:postgres_active_connections`
- `opsforge:postgres_max_transaction_seconds`
- `opsforge:postgres_locks`
- `nightwatch_db_query_duration_seconds{operation=...}`

A lock count or long transaction is an investigation signal, not proof of root cause. Correlate it with customer latency, application query duration, logs and request timing.

### Redis

`redis_exporter` provides an independent cache reachability signal through `redis_up`. The API also reports `nightwatch_dependency_up{dependency="redis"}` and dependency-check latency. Comparing the independent exporter with the application's view helps distinguish cache failure from application-side configuration or networking problems.

### RabbitMQ and worker

RabbitMQ is scraped through `/metrics/per-object` so the ticket queue can be diagnosed directly.

Key queue signals:

- `opsforge:rabbitmq_ready_messages`
- `opsforge:rabbitmq_unacked_messages`
- `opsforge:rabbitmq_consumers`

Worker signals:

- `opsforge:worker_success:rate5m`
- `opsforge:worker_failure:rate5m`
- `opsforge:worker_job_duration_seconds:p95_5m`

Useful patterns:

- ready messages rising + zero consumers -> consumer/worker availability hypothesis
- ready messages rising + consumers present + high job duration -> slow processing or downstream dependency hypothesis
- unacked messages rising -> jobs have been delivered but are taking too long or are stuck before acknowledgement
- worker failures rising -> inspect worker logs and the associated request/event identifiers

## Logs and traces

All Docker logs are collected by Alloy and stored in Loki. The L2 dashboard includes a live log panel for API, worker and Nginx containers.

The request-correlation workflow is:

```text
customer symptom
  -> X-Request-ID
  -> Nginx/API/worker logs in Loki
  -> Tempo search using nightwatch.request_id
  -> dependency/query/queue metrics for the same time window
```

This avoids treating metrics, logs and traces as separate demonstrations. They are different evidence sources for the same incident timeline.

## Recording and detection rules

Prometheus loads `prometheus/rules/opsforge-observability.yml`. Recording rules convert raw exporter/application metrics into stable OPSFORGE operator queries. Detection rules currently cover:

- synthetic customer journey failure
- high API 5xx ratio
- high API p95 latency
- application dependency failure
- PostgreSQL exporter/database failure
- long PostgreSQL transactions
- Redis failure
- RabbitMQ queue backlog
- worker processing failures

These rules create detection state inside Prometheus. Phase 4 intentionally does not add external paging or notification routing; escalation and notification behavior belongs to the support-operations model rather than being added as a disconnected tool.

## Simulated service objectives

The lab uses the following operating targets for practice:

- availability target: 99.9%
- API p95 target: below 500 ms
- 5xx target: below 1%

These are simulated NIGHTWATCH objectives, not historical commercial-production SLAs. Some alert thresholds are deliberately looser than the objective to reduce noise in a small synthetic environment. For example, the high-5xx alert activates at 5% for two minutes even though the operating target is below 1%.

## Release-gate requirements

A release is rejected if the Phase 4 observability layer is not usable. `scripts/verify_release.sh` now checks that:

- PostgreSQL, Redis and RabbitMQ Prometheus targets are queryable
- `pg_up` and `redis_up` report healthy dependencies
- PostgreSQL activity and the NIGHTWATCH queue are visible
- OPSFORGE recording/detection groups are loaded and healthy
- representative recording rules are evaluating
- centralized Loki logs contain the tested request ID
- Tempo can find the tested request ID
- Grafana has Prometheus, Loki and Tempo datasources
- the `OPSFORGE L2 Operations` dashboard is provisioned

## Boundaries

This is a simulated production-support environment. Exporters and dashboards model operational behavior; they do not represent commercial production traffic or production ownership. Container-level CPU/memory collection is intentionally deferred until a concrete incident exercise requires it. External alert notification and on-call routing are also deferred to the support-operations phase.
