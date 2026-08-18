# OPSFORGE QW-001 — RabbitMQ Consumer Missing

QW-001 begins the Phase 6 Queue / Worker incident domain. It trains L2 diagnosis of a partial-service failure where the synchronous API and RabbitMQ broker remain healthy, but durable background work stops progressing because the worker consumer disappears.

> OPSFORGE is a simulated production-support training and portfolio environment. This is not a commercial production incident.

## Customer symptom

```text
POST /api/tickets             -> 201
processing_status             -> queued
GET /health/ready             -> 200
GET /queue-health             -> 200
PostgreSQL / Redis / RabbitMQ -> healthy
RabbitMQ consumers            -> 0
RabbitMQ messages_ready       -> >= 1
worker                        -> stopped
```

This is intentionally different from a broker outage. The API can still publish durable events and RabbitMQ retains them. The failure is loss of the consumer that performs asynchronous ticket processing.

## Baseline

The controller first proves a healthy asynchronous path:

1. API readiness is healthy.
2. The worker container is healthy.
3. `nightwatch-jobs` has one consumer.
4. A baseline ticket is created through the API.
5. The worker processes it to `processing_status=processed`.
6. The queue returns to zero ready messages.

This establishes that the same images and environment can complete the customer workflow before fault injection.

## Controlled fault

QW-001 stops only the worker container. It does not stop or reconfigure RabbitMQ, PostgreSQL, Redis, or the API.

After consumer count reaches zero, the controller creates another ticket. The API returns HTTP 201 because the durable publish succeeds, but the ticket remains `queued` and RabbitMQ retains at least one ready message with no consumer available.

## Required L2 evidence

Before recovery L2 must prove:

- ticket creation still returns HTTP 201;
- the affected ticket remains `processing_status=queued`;
- RabbitMQ reports `messages_ready >= 1`;
- RabbitMQ reports `messages_unacknowledged = 0`;
- RabbitMQ reports `consumers = 0`;
- `/health/ready` remains HTTP 200;
- `/queue-health` remains HTTP 200;
- PostgreSQL `SELECT 1` succeeds;
- Redis returns `PONG`;
- `rabbitmq-diagnostics ping` succeeds;
- the worker runtime is stopped;
- the ticket request ID appears in API logs but not worker logs before recovery.

That evidence rejects broker failure, publish failure, database failure, cache failure, and an in-flight slow worker job.

## Recovery boundary

QW-001 reuses the Phase 5 `RUN-WORKER-RECOVERY` runbook instead of creating a duplicate procedure.

Once evidence isolates the issue to a missing consumer, L2 starts **only the existing worker container**. QW-001 explicitly proves that the worker container ID is unchanged before and after recovery, so this is a targeted process recovery rather than a redeployment.

L2 must not restart PostgreSQL, Redis, RabbitMQ, or the API to solve this incident.

Escalation is the correct outcome when:

- the worker immediately exits again;
- consumer count does not recover after the approved worker-only start;
- worker logs show a code/configuration exception;
- RabbitMQ connectivity from the worker remains broken while broker health is normal;
- repeated consumer loss indicates the existing worker reliability problem requires permanent engineering action.

## Recovery success criteria

QW-001 is resolved only when:

1. RabbitMQ consumer count returns to one;
2. the ready-message backlog drains;
3. the original affected ticket reaches `processing_status=processed`;
4. the original request ID appears in a worker `job_completed` log;
5. the customer can read the original ticket successfully;
6. the worker container identity is unchanged;
7. the API container identity is unchanged;
8. API, PostgreSQL, and RabbitMQ health remain healthy.

Starting a container is not sufficient recovery evidence; the already queued customer work must complete.

## Executable controller

```bash
bash scripts/qw_incident_001.sh exercise
```

Evidence is written to:

```text
.opsforge/evidence/qw-001/
```

## Operational records

- `INC-1301`
- `L2N-1301`
- existing runbook: `RUN-WORKER-RECOVERY`

## Dedicated CI

- `.github/workflows/queue-worker-incidents.yml`

The workflow builds the normal API and worker images, starts an isolated environment, executes the incident, uploads evidence even when a gate fails, and removes the isolated environment after the run.
