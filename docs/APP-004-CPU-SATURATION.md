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

## Measured proof

The first complete validation cycle produced the following evidence on release `app004-24cdd186bf`:

### Healthy baseline — 25 ticket-detail reads

- minimum: `0.013715` seconds
- median: `0.017087` seconds
- p95: `0.024907` seconds
- maximum: `0.025642` seconds

### CPU-degraded window — 25 ticket-detail reads

- minimum: `0.483196` seconds
- median: `0.685175` seconds
- p95: `0.992542` seconds
- maximum: `1.087918` seconds
- representative customer request: HTTP `200` in `0.671380` seconds
- request ID: `2fd964902ac97341938241389a1d920a`
- affected ticket ID: `5`

The degraded p95 was approximately `39.85x` the healthy baseline p95 while the endpoint continued returning HTTP 200.

### Resource and runtime identity

- API CPU budget: `250000000` NanoCpus (`0.25` CPU)
- controlled runaway processes: `12`
- API image ID: `sha256:6853cc80311acf95b5332ce0ff37c166c0f418bf5f88ff102ddfcce03eb4724b`
- API container ID: `4010a89b9810e3ecfb1bfe3c9bff6cb4902f4815ac6889ad153f6204026ac392`
- main API PID: `4500`
- release / image / container / main PID / CPU budget unchanged during degradation: confirmed
- PostgreSQL / Redis / RabbitMQ / API health: healthy
- `nr_throttled` increase during degraded window: `446`
- `throttled_usec` increase during degraded window: `168122576`
- Nginx / API / Loki / Tempo request correlation: confirmed

### Recovered state — 25 ticket-detail reads

- minimum: `0.013316` seconds
- median: `0.013810` seconds
- p95: `0.032273` seconds
- maximum: `0.088917` seconds
- recovery-window throttled-time increase: `60712` microseconds
- original ticket after recovery: HTTP `200`
- release / image / container / main PID / CPU budget unchanged: confirmed
- API restart required: no
- application redeploy required: no
- resource-limit change required: no
- full customer/release verification: passed

The recovery p95 was about `96.75%` lower than the degraded p95. Recovery came from terminating only the identified runaway workload, not from restarting or replacing the API runtime.

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

APP-004 creates a legitimate observability follow-up. Phase 4 intentionally deferred container CPU/memory telemetry until a concrete incident justified it. This incident provides that justification: L2 can diagnose the exercise with Docker/cgroup evidence, while L3/platform ownership should consider container CPU metrics, CPU-throttling alerts, and dashboard visibility as a separate preventive change.

That preventive work is not silently bundled into the incident fix; diagnosis, mitigation, and prevention remain separate operational steps.

## Operational records

- `INC-1204`
- `L2N-1204`
- `L3E-1204`
- `RUN-APP-CPU-SATURATION`

## Executable controller

- `scripts/app_incident_004.sh`

## CI gate

- `.github/workflows/application-incidents.yml`

## First validation cycle

Implementation head `33c5bbf37b2d520d1c8215d4d1a61c61efbe6cd9` passed:

- `OPSFORGE Support Operations` #36
- `OPSFORGE Deep Incidents` #23, re-proving DB-001 through DB-004
- `OPSFORGE Application Incidents` #8, re-proving APP-001 through APP-004
- `NIGHTWATCH OPSFORGE CI` #92, including staging promotion, production promotion, controlled bad-release rejection, rollback, independent recovery verification, and cleanup

APP-004 is complete in scope. The documentation-complete branch head must pass the same four gates again before merge.
