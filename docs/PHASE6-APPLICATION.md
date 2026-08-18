# NIGHTWATCH OPSFORGE — Phase 6 Application Incidents

Phase 6 application incidents train L2 diagnosis when the platform is reachable but deployed application behavior is wrong. The goal is to distinguish application defects from database, cache, queue, proxy, and deployment failures before changing components.

> OPSFORGE is a simulated production-support training and portfolio environment. These are controlled exercises, not commercial production incidents.

## Application incident sequence

1. APP-001 — release-specific API HTTP 500 regression
2. APP-002 — dependency timeout
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

Dedicated CI:

- `.github/workflows/application-incidents.yml`

## Definition of done for APP-001

APP-001 is complete only when one final branch head passes:

- Support Operations record validation
- APP-001 controlled bad release build
- APP-001 customer failure and evidence correlation
- rollback to known-good release
- original-customer-read recovery
- complete customer/release verification after rollback
- existing PostgreSQL deep-incident regressions
- full NIGHTWATCH OPSFORGE staging -> production -> rejected-candidate -> rollback -> independent recovery verification
