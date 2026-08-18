# APP-002 — Downstream Dependency Timeout

APP-002 is a controlled Phase 6 Deep Incident Domains exercise for diagnosing a customer-facing application timeout when the downstream service is still reachable.

> OPSFORGE is a simulated production-support training and portfolio environment. This is not a commercial production incident.

## Customer symptom

```text
POST /api/tickets             -> 201
GET /api/tickets/<id>         -> 504 in ~1 second
GET /health/ready             -> 200
PostgreSQL / Redis / RabbitMQ -> healthy
Direct downstream probe       -> 200 in ~3 seconds
```

The important distinction is that the downstream service is not down. It responds successfully, but slower than the API's one-second dependency timeout budget.

## Controlled fault

The APP-002 release mode installs a test-only ticket-read dependency hook. The exercise attaches a temporary HTTP service to the staging Docker network with approximately three seconds of response latency. The API calls that service with a one-second timeout.

The temporary dependency is part of the incident harness only; it is not a new permanent NIGHTWATCH production component.

## Required L2 evidence

Before mitigation, L2 must prove:

- the affected release identity,
- ticket creation still succeeds,
- customer ticket-detail read returns HTTP 504,
- the failing request duration aligns with the one-second application timeout,
- PostgreSQL, Redis, RabbitMQ, Nginx, and readiness remain healthy,
- a direct dependency probe returns HTTP 200 when allowed more than one second,
- direct dependency latency is materially above the application timeout budget,
- the same X-Request-ID appears in Nginx and API logs,
- API logs contain a structured `dependency_timeout` event for `app002-policy-service`,
- Tempo and Loki contain the same failing request correlation.

That evidence rejects a hard dependency outage, database problem, proxy-generated timeout, or generic application crash.

## Measured validation evidence

The validated APP-002 run measured:

- customer ticket-detail response: HTTP `504`
- customer request duration: `1.004487` seconds
- failing request ID: `f53a1ddf27c93c9f52ce499cd226ef2e`
- affected ticket ID: `6`
- direct downstream response: HTTP `200`
- direct downstream latency during incident: `3.015` seconds
- application dependency timeout budget: `1.0` second
- PostgreSQL: healthy
- Redis: healthy
- RabbitMQ: healthy
- Nginx/API request correlation: confirmed
- structured dependency-timeout log: confirmed
- Tempo correlation: confirmed
- Loki correlation: confirmed

After the simulated dependency returned to normal latency, the direct dependency probe measured `0.063` seconds. The same application release remained deployed, the original ticket-detail request returned HTTP `200`, and the complete OPSFORGE customer/release verification passed. No API redeploy was required for recovery.

## Recovery boundary

APP-002 does not increase timeout values during the incident and does not restart healthy infrastructure. The simulated downstream dependency is restored to normal response latency while the same application release remains deployed.

Recovery is complete only when:

1. the direct dependency probe is below the one-second application timeout budget,
2. the original ticket-detail request returns HTTP 200,
3. the API release identity is unchanged,
4. readiness and core dependency health remain healthy,
5. the complete OPSFORGE customer/release verification passes.

## Operational records

- `INC-1202`
- `L2N-1202`
- `L3E-1202`
- `RUN-APP-DEPENDENCY-TIMEOUT`

## Executable controller

- `scripts/app_incident_002.sh`

## CI gate

- `.github/workflows/application-incidents.yml`

APP-002 is complete when the documentation-complete branch head passes the application-specific gate, Support Operations validation, existing deep-incident regressions, and the full NIGHTWATCH OPSFORGE staging/production/rollback pipeline.
