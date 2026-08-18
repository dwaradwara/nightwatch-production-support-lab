# NIGHTWATCH OPSFORGE — Phase 6 Application Incidents

Phase 6 application incidents train L2 diagnosis when the platform is reachable but deployed application behavior is wrong, a downstream interaction violates the customer-path contract, runtime configuration is malformed, or resource contention degrades a still-available service. The goal is to distinguish application defects, dependency behavior, configuration failures, and resource saturation from database, cache, queue, proxy, and deployment failures before changing components.

> OPSFORGE is a simulated production-support training and portfolio environment. These are controlled exercises, not commercial production incidents.

## Application incident sequence

1. APP-001 — release-specific API HTTP 500 regression — complete
2. APP-002 — downstream dependency timeout — complete
3. APP-003 — malformed application configuration — complete
4. APP-004 — API CPU saturation / resource degradation — complete

**Application subdomain status: COMPLETE — August 18, 2026.**

Phase 6 itself remains in progress because queue/worker, proxy/network/security, delivery, and remaining database exercises are separate domains in the roadmap. Phase 7 later removes the root-cause labels and turns validated incidents into blind scenarios.

## APP-001 — release-specific ticket-read HTTP 500

Customer symptom:

```text
POST /api/tickets             -> 201
GET /api/tickets/<id>         -> 500
GET /health/ready             -> 200
PostgreSQL / Redis / RabbitMQ -> healthy
```

The controlled bad image is created at build time with `ticket-read-api-500`. Only the API image is modified for this application fault; Nginx does not generate the response. The normal source tree remains fault-free when the release is built without that mode.

### Required L2 evidence

L2 must prove all of the following before rollback:

- affected release identity from `/version`
- customer ticket creation still succeeds
- the persisted ticket row exists in PostgreSQL
- PostgreSQL, Redis, RabbitMQ, and API readiness remain healthy
- customer ticket detail read returns HTTP 500
- the edge-owned failing request ID appears in Nginx and API logs
- API logs contain the runtime exception in the ticket-read handler
- Tempo contains the failing request correlation
- Loki contains centralized logs for the same request

The conclusion is therefore a release-specific application failure, not a dependency outage, missing data, or proxy-generated 500.

### Recovery boundary

APP-001 does not hot-edit code in a running container. Once the release-specific defect is proven and a known-good release is available, L2 rolls the simulated environment back to the known-good release.

Recovery is not complete until:

1. `/version` reports the known-good release,
2. the original ticket detail read returns HTTP 200,
3. the original persisted ticket is still intact,
4. the complete OPSFORGE customer/release verification passes,
5. an L3 escalation package retains the bad version, request ID, reproduction, logs/traces, and requested engineering action.

Operational records:

- `INC-1201`
- `L2N-1201`
- `L3E-1201`
- `RUN-APP-RELEASE-ROLLBACK`

Executable controller:

- `scripts/app_incident_001.sh`

## APP-002 — reachable downstream dependency exceeds timeout budget

Customer symptom:

```text
POST /api/tickets             -> 201
GET /api/tickets/<id>         -> 504 in ~1 second
GET /health/ready             -> 200
PostgreSQL / Redis / RabbitMQ -> healthy
Direct dependency probe       -> 200 in ~3 seconds
```

APP-002 adds a test-only dependency hook only to the controlled exercise image. A temporary HTTP dependency is attached to the staging Docker network and intentionally responds in approximately three seconds while the application timeout budget is one second.

### Required L2 evidence

L2 must prove all of the following before assigning fault ownership:

- affected release identity from `/version`
- ticket creation still succeeds
- the customer ticket-detail request returns HTTP 504 near the configured one-second timeout
- PostgreSQL, Redis, RabbitMQ, Nginx, and API readiness remain healthy
- the downstream service is reachable directly and returns HTTP 200 with a larger probe timeout
- measured direct dependency latency is above the application timeout budget
- the same edge-owned request ID appears in Nginx and API logs
- API logs contain a structured `dependency_timeout` event for `app002-policy-service`
- Tempo and Loki contain the same request correlation

The conclusion is slow-but-reachable downstream behavior, not a hard outage, proxy timeout, database failure, or generic application crash.

### Measured proof

The validated run produced:

- ticket-detail response: HTTP `504` in `1.004487` seconds
- failing request ID: `f53a1ddf27c93c9f52ce499cd226ef2e`
- affected ticket ID: `6`
- direct dependency response: HTTP `200` in `3.015` seconds
- API dependency timeout budget: `1.0` second
- PostgreSQL / Redis / RabbitMQ: healthy
- Nginx / API / Loki / Tempo correlation: confirmed
- recovered dependency latency: `0.063` seconds
- original ticket after recovery: HTTP `200`
- API redeploy required: no
- full customer/release verification after recovery: passed

### Recovery boundary

APP-002 does not increase the timeout during the incident and does not restart healthy services. The simulated downstream service is restored to normal latency while the same API release stays deployed.

Recovery is not complete until:

1. direct downstream latency is below the one-second application timeout budget,
2. the original ticket detail read returns HTTP 200,
3. the API release identity remains unchanged,
4. readiness and core dependency health remain healthy,
5. the complete OPSFORGE customer/release verification passes.

Operational records:

- `INC-1202`
- `L2N-1202`
- `L3E-1202`
- `RUN-APP-DEPENDENCY-TIMEOUT`

Executable controller:

- `scripts/app_incident_002.sh`

Detailed operator note:

- `docs/APP-002-DEPENDENCY-TIMEOUT.md`

## APP-003 — malformed runtime application configuration

Customer symptom:

```text
POST /api/tickets             -> 201
GET /api/tickets/<id>         -> 500
GET /health/ready             -> 200
PostgreSQL / Redis / RabbitMQ -> healthy
Release version               -> unchanged
API image ID                  -> unchanged
```

APP-003 uses a configuration-aware exercise image with a valid default `APP003_TICKET_EVENT_LIMIT=50`. The incident controller then applies a temporary runtime-only Compose override containing `APP003_TICKET_EVENT_LIMIT=not-a-number` and recreates the API using the exact same image.

### Required L2 evidence

L2 must prove all of the following before mitigation:

- the same APP-003 release/image returns HTTP 200 before the runtime configuration change
- ticket creation still succeeds after the change
- customer ticket-detail read returns HTTP 500
- PostgreSQL, Redis, RabbitMQ, Nginx, and API readiness remain healthy
- release identity is unchanged
- API image ID is identical before fault injection and during the failure
- effective container environment contains `APP003_TICKET_EVENT_LIMIT=not-a-number`
- the failing X-Request-ID appears in Nginx and API logs
- API logs contain a structured `configuration_error` for the malformed key/value
- Tempo and Loki contain the same failing request correlation

The conclusion is malformed runtime application configuration, not a release-image regression, dependency outage, proxy-generated 500, or missing customer data.

### Measured proof

The first complete validation cycle produced:

- ticket-detail response: HTTP `500` in `0.002383` seconds
- failing request ID: `3193e2011b21efe5c31e4bf5b1f029ba`
- affected ticket ID: `5`
- exercise release: `app003-ab254e0f08`
- API image ID: `sha256:5effe45c1be87cf477bd5829544bed9ea36ccf52c7b770f81e99d674048ee1a1`
- API image unchanged after malformed runtime configuration: confirmed
- malformed setting: `APP003_TICKET_EVENT_LIMIT=not-a-number`
- expected setting contract: integer `1-200`
- PostgreSQL / Redis / RabbitMQ: healthy
- Nginx / API request correlation: confirmed
- structured `configuration_error`: confirmed
- Loki / Tempo correlation: confirmed
- corrected setting: `APP003_TICKET_EVENT_LIMIT=25`
- recovered API image ID: unchanged
- application code rollback required: no
- original ticket after recovery: HTTP `200`
- full customer/release verification after recovery: passed

The `app003-ab254e0f08` identifier is the release tag generated from the pull-request merge ref during the first validation cycle; the key proof is that the exact API image ID remained identical before fault injection, during failure, and after recovery.

### Recovery boundary

APP-003 does not roll back application code. L2 corrects only the malformed runtime setting to a supported integer and recreates the API using the same image. Nginx configuration is not changed; it is reloaded only to refresh Docker service resolution after the API container recreation.

Recovery is not complete until:

1. the effective runtime value is valid,
2. the API image ID remains unchanged,
3. `/version` reports the same release,
4. the original ticket-detail read returns HTTP 200,
5. readiness and core dependency health remain healthy,
6. the complete OPSFORGE customer/release verification passes.

Operational records:

- `INC-1203`
- `L2N-1203`
- `L3E-1203`
- `RUN-APP-MALFORMED-CONFIG`

Executable controller:

- `scripts/app_incident_003.sh`

Detailed operator note:

- `docs/APP-003-MALFORMED-CONFIG.md`

## APP-004 — API CPU saturation / resource degradation

Customer symptom:

```text
POST /api/tickets             -> 201
GET /api/tickets/<id>         -> 200 but materially slower
GET /health/ready             -> 200
PostgreSQL / Redis / RabbitMQ -> healthy
Release / image / container   -> unchanged
Main API PID / CPU budget     -> unchanged
```

APP-004 deploys a normal release with no application fault mode, establishes a fixed `0.25` CPU budget before the healthy baseline, then starts twelve controlled CPU-burning processes inside the already-running API container. The same resource budget stays in place throughout baseline, degradation, and recovery.

### Required L2 evidence

L2 must prove all of the following before mitigation:

- customer requests remain HTTP 200 while latency materially increases
- repeated samples establish a healthy baseline and degraded p95 rather than relying on one slow request
- API release, image ID, container ID, main process PID, and CPU budget remain unchanged
- PostgreSQL, Redis, RabbitMQ, Nginx, API readiness, and container health remain healthy
- process inspection identifies the unexpected CPU consumers
- cgroup `cpu.stat` shows increased `nr_throttled` and `throttled_usec`
- one degraded-window X-Request-ID appears in Nginx and API logs
- Tempo and Loki contain the same request correlation

The conclusion is CPU contention inside the API runtime, not a release regression, downstream timeout, malformed configuration, proxy failure, or dependency outage.

### Measured proof

The first complete validation cycle on release `app004-24cdd186bf` produced:

- baseline p95 across 25 reads: `0.024907` seconds
- degraded p95 across 25 reads: `0.992542` seconds
- degraded median: `0.685175` seconds
- degraded maximum: `1.087918` seconds
- degraded p95 increase: approximately `39.85x`
- representative degraded request: HTTP `200` in `0.671380` seconds
- degraded request ID: `2fd964902ac97341938241389a1d920a`
- affected ticket ID: `5`
- fixed API CPU budget: `0.25` CPU (`250000000` NanoCpus)
- controlled runaway processes: `12`
- API image ID: `sha256:6853cc80311acf95b5332ce0ff37c166c0f418bf5f88ff102ddfcce03eb4724b`
- API container ID: `4010a89b9810e3ecfb1bfe3c9bff6cb4902f4815ac6889ad153f6204026ac392`
- main API PID: `4500`
- release / image / container / PID / CPU budget unchanged: confirmed
- PostgreSQL / Redis / RabbitMQ / API health: healthy
- `nr_throttled` delta: `446`
- `throttled_usec` delta: `168122576`
- Nginx / API / Loki / Tempo correlation: confirmed
- recovered p95 across 25 reads: `0.032273` seconds
- recovery-window throttled-time delta: `60712` microseconds
- API restart required: no
- application redeploy required: no
- resource-limit change required: no
- original ticket after recovery: HTTP `200`
- full customer/release verification: passed

### Recovery boundary

APP-004 does not restart or redeploy the API and does not increase its CPU limit. L2 terminates only the confirmed runaway CPU workload.

Recovery is not complete until:

1. the CPU-burning processes are absent,
2. repeated ticket-read latency materially recovers,
3. release, image, container, main API PID, and CPU budget remain unchanged,
4. the original ticket-detail read returns HTTP 200,
5. readiness and core dependency health remain healthy,
6. the complete OPSFORGE customer/release verification passes.

Operational records:

- `INC-1204`
- `L2N-1204`
- `L3E-1204`
- `RUN-APP-CPU-SATURATION`

Executable controller:

- `scripts/app_incident_004.sh`

Detailed operator note:

- `docs/APP-004-CPU-SATURATION.md`

### Preventive follow-up

APP-004 supplies the concrete operational justification that Phase 4 previously lacked for container CPU/throttling telemetry. Adding container resource metrics, throttling alerts, and dashboard visibility should be handled as a separate preventive problem/change item rather than being disguised as incident recovery.

## Application-domain completion evidence

The implementation head `33c5bbf37b2d520d1c8215d4d1a61c61efbe6cd9` passed:

- `OPSFORGE Support Operations` #36
- `OPSFORGE Deep Incidents` #23, re-proving DB-001 through DB-004
- `OPSFORGE Application Incidents` #8, re-proving APP-001 through APP-004
- `NIGHTWATCH OPSFORGE CI` #92, including staging, production, controlled bad-release rejection, rollback, independent recovery verification, and cleanup

The documentation-complete branch head must pass the same four gates before merge.

## Dedicated CI

- `.github/workflows/application-incidents.yml`

## Definition of done

An application incident is complete only when one exact final branch head passes:

- Support Operations record validation
- its controlled application-incident workflow
- existing Phase 6 deep-incident regressions
- complete customer/release recovery validation
- full NIGHTWATCH OPSFORGE staging -> production -> rejected-candidate -> rollback -> independent recovery verification
