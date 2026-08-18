# APP-003 — Malformed Application Configuration

APP-003 is a validated controlled Phase 6 Deep Incident Domains exercise for diagnosing a customer-facing application failure caused by an invalid runtime configuration value while the deployed release image and core infrastructure remain healthy.

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

## Measured validation evidence

The first complete validation cycle measured:

- customer ticket-detail response: HTTP `500`
- customer request duration: `0.002383` seconds
- failing request ID: `3193e2011b21efe5c31e4bf5b1f029ba`
- affected ticket ID: `5`
- exercise release: `app003-ab254e0f08`
- API image ID: `sha256:5effe45c1be87cf477bd5829544bed9ea36ccf52c7b770f81e99d674048ee1a1`
- API image unchanged after configuration injection: `true`
- PostgreSQL: healthy
- Redis: healthy
- RabbitMQ: healthy
- malformed configuration: `APP003_TICKET_EVENT_LIMIT=not-a-number`
- expected contract: integer `1-200`
- Nginx request correlation: confirmed
- API request correlation: confirmed
- structured `configuration_error`: confirmed
- Tempo correlation: confirmed
- Loki correlation: confirmed
- corrected configuration: `APP003_TICKET_EVENT_LIMIT=25`
- recovered API image ID: unchanged
- application code rollback required: `false`
- original ticket after recovery: HTTP `200`
- complete customer/release verification after recovery: passed

The release tag above was generated from the pull-request merge ref for that validation run. The decisive evidence is that the API image digest remained identical before the malformed runtime value, during the failure, and after recovery.

## Recovery boundary

APP-003 does not roll back the application image and does not change healthy database, cache, queue, or proxy configuration. The malformed runtime value is corrected to a supported integer and the API is recreated on the same release image.

Recovery is complete only when:

1. the effective runtime value is a supported integer,
2. the API image ID remains identical to the pre-incident image,
3. `/version` still reports the same release,
4. the original ticket-detail request returns HTTP 200,
5. readiness and core dependency health remain healthy,
6. the complete OPSFORGE customer/release verification passes.

All six recovery conditions were satisfied in the validated run.

## Operational records

- `INC-1203`
- `L2N-1203`
- `L3E-1203`
- `RUN-APP-MALFORMED-CONFIG`

## Executable controller

- `scripts/app_incident_003.sh`

## CI gate

- `.github/workflows/application-incidents.yml`

The implementation validation cycle passed Support Operations #32, Application Incidents #5, Deep Incidents #20, and NIGHTWATCH OPSFORGE CI #88. A documentation-closure commit changes the branch head, so the same four classes of checks must pass again on the exact final merge candidate before PR #15 is merged.
