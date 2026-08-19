# INC-018 — RabbitMQ Outage / Partial Ticket Processing Failure

**Project:** NIGHTWATCH Production Support Lab  
**Environment:** Docker Compose / Flask API / PostgreSQL / RabbitMQ / Worker  
**Severity:** SEV2 — simulated asynchronous processing outage  
**Status:** Resolved  
**Type:** Message Queue / Partial Failure / Data Consistency

## Customer Report

A customer submits a new support ticket and receives a service-unavailable response even though the ticket appears to have been created.

The customer-facing symptom is confusing because the API request is not a complete failure: the database write succeeds, but the background event cannot be published to RabbitMQ.

## Impact

New tickets can be persisted in PostgreSQL while asynchronous processing is unavailable.

This creates a partial-success state:

`HTTP request -> PostgreSQL insert succeeds -> RabbitMQ publish fails -> API returns 503`

The affected ticket remains stored with:

`processing_status = publish_failed`

A client that blindly retries after the 503 could create a duplicate logical request unless idempotency or reconciliation controls are present.

## Healthy Baseline

The API readiness endpoint returned:

```text
HTTP/1.1 200 OK
postgresql: healthy
rabbitmq: healthy
redis: healthy
status: ready
```

This established that the application and all required dependencies were healthy before fault injection.

## Fault Injection

RabbitMQ was stopped intentionally:

```powershell
docker stop nightwatch-rabbit
```

The dedicated queue health endpoint then returned:

```text
HTTP/1.1 503 SERVICE UNAVAILABLE
{"error":"gaierror","queue":"rabbitmq","status":"unhealthy"}
```

This isolated the dependency failure to RabbitMQ while PostgreSQL and Redis remained available.

## Application Reproduction

A ticket creation request was submitted with:

- Customer ID: `OPSFORGE-018`
- Title: `INC-018 RabbitMQ outage test`
- Severity: `SEV2`

The API returned:

```text
ServiceUnavailable
{"error":"ticket created but background processing could not be queued","processing_status":"publish_failed","ticket_id":4}
```

The response confirmed that the API recognized a partial failure rather than treating the database insert and queue publish as one successful operation.

## Database Evidence

PostgreSQL was queried directly for ticket ID 4.

Result:

```text
 id | title                         | severity | status | processing_status | customer_id
----+-------------------------------+----------+--------+-------------------+-------------
  4 | INC-018 RabbitMQ outage test  | SEV2     | Open   | publish_failed    | OPSFORGE-018
```

This proved that the ticket had already been committed even though the client received a 503 response.

## Investigation

### 1. Verified Healthy Baseline

`/health/ready` returned HTTP 200 with PostgreSQL, RabbitMQ, and Redis healthy.

Result:

`Full dependency baseline healthy`

### 2. Stopped RabbitMQ Only

The RabbitMQ container was stopped without changing PostgreSQL or Redis.

Result:

`Controlled single-dependency outage`

### 3. Verified Queue-Specific Failure

`/queue-health` returned HTTP 503 and identified RabbitMQ as unhealthy.

Result:

`Message-queue layer isolated`

### 4. Submitted a New Ticket

The API accepted and persisted the ticket before attempting the background event publish.

The RabbitMQ publish failed and the API returned a service-unavailable response.

Result:

`Partial transaction failure reproduced`

### 5. Inspected PostgreSQL State

The newly created ticket existed in the database with `processing_status = publish_failed`.

Result:

`Database commit succeeded despite client-visible failure`

## Root Cause

RabbitMQ was unavailable when the API attempted to publish the `ticket.created` background event.

The application workflow intentionally performs the PostgreSQL insert before queue publication. Because these operations do not share one atomic transaction, the database write can succeed independently of the RabbitMQ publish.

The API detects the publish exception, marks the stored ticket as `publish_failed`, and returns HTTP 503.

## Resolution

RabbitMQ was restarted:

```powershell
docker start nightwatch-rabbit
```

The API readiness endpoint was then rechecked.

Recovery result:

```text
HTTP/1.1 200 OK
postgresql: healthy
rabbitmq: healthy
redis: healthy
status: ready
```

The service dependency chain was fully restored.

## Layer Isolation

| Layer | Result |
|---|---|
| Flask API process | Running |
| PostgreSQL | Healthy |
| Redis | Healthy |
| RabbitMQ before fault | Healthy |
| RabbitMQ during fault | Unhealthy |
| Queue health endpoint | HTTP 503 |
| Ticket database insert | Successful |
| Background event publish | Failed |
| Ticket processing state | `publish_failed` |
| Client response | HTTP 503 |
| Readiness after RabbitMQ restart | HTTP 200 |

## Customer Update — Investigation

We confirmed that ticket creation reached the application and that the database remained available. The failure is isolated to the background-processing queue rather than the core API or PostgreSQL.

## Customer Update — Root Cause Identified

The ticket was saved successfully, but RabbitMQ was unavailable when the application attempted to queue the background event. The ticket was retained with a failed-processing marker so it can be identified for recovery instead of being silently lost.

## Customer Update — Resolved

RabbitMQ connectivity was restored and application readiness returned to normal. The affected ticket remains identifiable in PostgreSQL through its `publish_failed` processing state.

## Preventive Actions

- Alert on RabbitMQ dependency health and publish failures.
- Monitor the count of tickets in `publish_failed` state.
- Add a reconciliation or replay mechanism for failed event publication.
- Use idempotency keys for client-facing create operations to prevent duplicate logical tickets after retries.
- Correlate API request IDs with queue event IDs and worker logs.
- Document partial-success behavior in API support runbooks.
- Test dependency-specific failure modes rather than relying only on liveness checks.
- Consider an outbox pattern when stronger database-to-message consistency is required.

## Support Skills Demonstrated

- RabbitMQ outage diagnosis
- Dependency health isolation
- HTTP 503 analysis
- PostgreSQL state verification
- Partial-success and data-consistency troubleshooting
- Asynchronous workflow analysis
- Failure-state design validation
- Recovery verification
- Root cause analysis
- Customer-facing incident communication

> This incident was intentionally reproduced in a self-built training environment. It is portfolio evidence and not employer production experience.
