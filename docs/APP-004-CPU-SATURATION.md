# APP-004 — API CPU Saturation and Resource Degradation

APP-004 is a controlled Phase 6 Deep Incident Domains exercise for diagnosing customer-visible latency caused by CPU contention inside an otherwise healthy API runtime.

> OPSFORGE is a simulated production-support training and portfolio environment. This is not a commercial production incident.

## Customer symptom

```text
POST /api/tickets             -> 201
GET /api/tickets/<id>         -> 200 but materially slower
GET /health/ready             -> 200
PostgreSQL / Redis / RabbitMQ -> healthy
Release version               -> unchanged
API image / container / PID   -> unchanged
```

The critical distinction is that this incident is neither an outage nor another code/config/dependency fault. The same release, image, container, main API process, and fixed CPU budget remain in place throughout baseline, degradation, and recovery.

## Controlled fault

The controller establishes a fixed `0.25` CPU budget for the API **before** the healthy baseline. That budget remains unchanged for the rest of the exercise.

After a normal ticket-detail latency baseline is captured, the controller starts twelve temporary `opsforge_app004_cpu_burn.py` processes inside the already-running API container. They consume the shared CPU budget and force the cgroup to throttle runnable work. No application code, release image, runtime configuration, database/cache/queue state, or proxy configuration is changed.

The incident is therefore controlled resource contention inside the runtime, not a quota change during the fault window.

## Required L2 evidence

Before mitigation, L2 must prove:

- the customer path is available but slower rather than returning a hard error,
- repeated ticket-detail samples show a material p95 increase from the healthy baseline,
- the same fixed CPU budget was in place before and during degradation,
- API release version, image ID, container ID, and main process PID remain unchanged,
- `/health/ready`, PostgreSQL, Redis, RabbitMQ, Nginx, and container health remain healthy,
- `docker top` identifies the unexpected CPU-consuming processes,
- cgroup `cpu.stat` shows `nr_throttled` and `throttled_usec` increasing during the degraded window,
- one degraded-window X-Request-ID appears in Nginx and API logs,
- Loki and Tempo contain the same request correlation.

That evidence rejects dependency outage, downstream timeout, release regression, malformed runtime configuration, proxy failure, and blind capacity speculation.

## Why repeated latency samples matter

APP-004 does not diagnose performance from one request. The controller collects 25 ticket-detail samples for each state:

1. healthy baseline,
2. degraded CPU-contention window,
3. recovered state.

It computes min, median, p95, and max for each sample set. The exercise gate requires the degraded p95 to be at least `0.04` seconds and at least `1.5x` the baseline p95. Recovery must reduce p95 below `80%` of the degraded value.

The absolute threshold is only an exercise gate; the important operational method is comparison against the same service under the same fixed resource budget.

## Resource proof

The controller records:

- Docker `NanoCpus` for the API resource budget,
- API image ID,
- API container ID,
- main API process PID,
- `docker top` process inventory,
- cgroup `cpu.stat` before and during the fault,
- `nr_throttled` delta,
- `throttled_usec` delta.

The incident requires throttling counters to increase while the unexpected CPU processes are present.

## Recovery boundary

APP-004 does not restart or redeploy the API. L2 terminates only the confirmed runaway CPU workload.

Recovery is complete only when:

1. the CPU-burn processes are gone,
2. recovered ticket-read p95 is materially below degraded p95,
3. API release, image, container, main PID, and CPU budget are unchanged,
4. the original ticket-detail request still returns HTTP 200,
5. readiness and core dependency health remain healthy,
6. the complete OPSFORGE customer/release verification passes.

This creates stronger evidence than a generic restart because the same runtime recovers after only the offending workload is removed.

## Preventive follow-up

APP-004 also creates a legitimate observability follow-up. Phase 4 intentionally deferred container CPU/memory telemetry until a concrete incident justified it. This incident provides that justification: L2 can diagnose the exercise with Docker/cgroup evidence, while L3/platform ownership should consider whether container CPU metrics, throttling alerts, and dashboard visibility should be added as a separate preventive change.

That preventive work is not silently bundled into the incident fix; it remains an explicit follow-up so diagnosis, mitigation, and prevention stay distinct.

## Operational records

- `INC-1204`
- `L2N-1204`
- `L3E-1204`
- `RUN-APP-CPU-SATURATION`

## Executable controller

- `scripts/app_incident_004.sh`

## CI gate

- `.github/workflows/application-incidents.yml`

APP-004 remains under validation until Support Operations validation, APP-001 through APP-004 application-incident regression coverage, existing database deep incidents, and the full NIGHTWATCH OPSFORGE staging/production/rollback pipeline all pass on one exact branch head.
