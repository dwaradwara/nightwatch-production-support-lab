# NIGHTWATCH OPSFORGE — Phase 6 Application Incidents

Phase 6 application incidents train L2 diagnosis when the platform is reachable but deployed application behavior is wrong or a downstream interaction violates the customer-path contract. The goal is to distinguish application defects, dependency behavior, and runtime configuration failures from database, cache, queue, proxy, and deployment failures before changing components.

> OPSFORGE is a simulated production-support training and portfolio environment. These are controlled exercises, not commercial production incidents.

## Application incident sequence

1. APP-001 — release-specific API HTTP 500 regression — complete
2. APP-002 — downstream dependency timeout — complete
3. APP-003 — malformed application configuration — under validation
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

## Dedicated CI

- `.github/workflows/application-incidents.yml`

## Definition of done

An application incident is complete only when one exact final branch head passes:

- Support Operations record validation
- its controlled application-incident workflow
- existing Phase 6 deep-incident regressions
- complete customer/release recovery validation
- full NIGHTWATCH OPSFORGE staging -> production -> rejected-candidate -> rollback -> independent recovery verification
