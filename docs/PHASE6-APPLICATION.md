# NIGHTWATCH OPSFORGE — Phase 6 Application Incidents

Phase 6 application incidents train L2 diagnosis when the platform is reachable but deployed application behavior is wrong or a downstream interaction violates the customer-path contract. The goal is to distinguish application defects and dependency behavior from database, cache, queue, proxy, and deployment failures before changing components.

> OPSFORGE is a simulated production-support training and portfolio environment. These are controlled exercises, not commercial production incidents.

## Application incident sequence

1. APP-001 — release-specific API HTTP 500 regression — complete
2. APP-002 — downstream dependency timeout — complete
3. APP-003 — malformed application configuration
4. APP-004 — resource degradation

Phase 7 later removes the root-cause label and turns these into blind scenarios.

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

## Dedicated CI

- `.github/workflows/application-incidents.yml`

## Definition of done

An application incident is complete only when one exact final branch head passes:

- Support Operations record validation
- its controlled application-incident workflow
- existing Phase 6 deep-incident regressions
- complete customer/release recovery validation
- full NIGHTWATCH OPSFORGE staging -> production -> rejected-candidate -> rollback -> independent recovery verification
