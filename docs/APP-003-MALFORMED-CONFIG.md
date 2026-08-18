# APP-003 — Malformed Application Configuration

APP-003 is a controlled Phase 6 Deep Incident Domains exercise for diagnosing a customer-facing application failure caused by an invalid runtime configuration value while the deployed release image and core infrastructure remain healthy.

> OPSFORGE is a simulated production-support training and portfolio environment. This is not a commercial production incident.

## Customer symptom

```text
POST /api/tickets             -> 201
GET /api/tickets/<id>         -> 500
GET /health/ready             -> 200
PostgreSQL / Redis / RabbitMQ -> healthy
Release version               -> unchanged
API image ID                  -> unchanged
```

The critical distinction is that the application image is not changed. The same APP-003 image succeeds with its valid default configuration, then fails after the runtime receives `APP003_TICKET_EVENT_LIMIT=not-a-number`.

## Controlled fault

The APP-003 exercise image installs a test-only ticket-detail configuration guard. `APP003_TICKET_EVENT_LIMIT` must be an integer from 1 through 200 and controls how many ticket events may be returned by the exercise wrapper.

The normal exercise image defaults to a valid value of `50`. The incident controller creates a temporary Compose override and recreates only the API runtime with the malformed value `not-a-number`. The base Compose file and release image are not changed.

Because Nginx resolves the Docker service name when its configuration is loaded, the controller reloads the unchanged Nginx configuration after API recreation so the proxy refreshes the backend address. This is service-discovery housekeeping, not a proxy configuration fix.

## Required L2 evidence

Before mitigation, L2 must prove:

- the same APP-003 release/image returns HTTP 200 before the configuration injection,
- ticket creation still succeeds,
- ticket-detail read returns HTTP 500 after the malformed setting is applied,
- `/health/ready`, PostgreSQL, Redis, and RabbitMQ remain healthy,
- release identity remains unchanged,
- API image ID is identical before the configuration change and during the failure,
- the effective API container environment contains `APP003_TICKET_EVENT_LIMIT=not-a-number`,
- the response identifies an invalid application configuration rather than a proxy or dependency error,
- the same X-Request-ID appears in Nginx and API logs,
- API logs contain a structured `configuration_error` naming the setting and invalid value,
- Tempo and Loki contain the same failing request correlation.

That evidence rejects a code/release regression, database/cache/queue outage, proxy-generated 500, and missing customer data.

## Recovery boundary

APP-003 does not roll back the application image and does not change healthy database, cache, queue, or proxy configuration. The malformed runtime value is corrected to a supported integer and the API is recreated on the same release image.

Recovery is complete only when:

1. the effective runtime value is a supported integer,
2. the API image ID remains identical to the pre-incident image,
3. `/version` still reports the same release,
4. the original ticket-detail request returns HTTP 200,
5. readiness and core dependency health remain healthy,
6. the complete OPSFORGE customer/release verification passes.

## Operational records

- `INC-1203`
- `L2N-1203`
- `L3E-1203`
- `RUN-APP-MALFORMED-CONFIG`

## Executable controller

- `scripts/app_incident_003.sh`

## CI gate

- `.github/workflows/application-incidents.yml`

APP-003 remains under validation until Support Operations validation, APP-001 through APP-003 application-incident regression coverage, existing database deep incidents, and the full NIGHTWATCH OPSFORGE staging/production/rollback pipeline all pass on one exact branch head.
