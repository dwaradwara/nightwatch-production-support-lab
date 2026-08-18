# OPSFORGE QW-002 — Worker Processing Failure / Retry

QW-002 trains L2 diagnosis of a partial asynchronous failure where RabbitMQ is healthy, the worker consumer is present, and a valid durable message is being delivered, but the worker cannot complete its processing operation and therefore nacks/requeues the same event.

> OPSFORGE is a simulated production-support training and portfolio environment. This is not a commercial production incident.

## Customer symptom

```text
POST /api/tickets             -> 201
processing_status             -> queued
GET /health/ready             -> 200
GET /queue-health             -> 200
RabbitMQ broker              -> healthy
RabbitMQ consumers           -> 1
worker                       -> healthy/running
same request ID              -> repeated job_failed
message                      -> repeatedly requeued
```

This is intentionally different from QW-001. In QW-001 no consumer exists. In QW-002 the consumer is alive and receives the message repeatedly, but the processing operation fails.

It is also intentionally different from QW-004. The QW-002 message is valid and can succeed after a transient processing condition clears. QW-004 will model a permanently failing poison message that must not be requeued forever.

## Controlled fault

The exercise does **not** modify worker source code.

A temporary ticket-scoped PostgreSQL trigger rejects only the worker update that would move the QW-002 incident ticket from `queued` to `processed`. The trigger waits briefly and raises a controlled exception while a fault-control flag is enabled.

The API can still insert the ticket and publish `ticket.created`. PostgreSQL remains generally reachable, Redis remains healthy, RabbitMQ remains healthy, and the worker remains connected as a consumer. The same message therefore cycles through:

```text
RabbitMQ delivery
  -> worker job_started
  -> database processing exception
  -> worker job_failed
  -> basic_nack(requeue=True)
  -> same durable message delivered again
```

## Required L2 evidence

Before recovery L2 must prove:

- the ticket-create request returned HTTP 201;
- the affected ticket remains `processing_status=queued`;
- RabbitMQ still reports one consumer;
- the queue still contains the affected message in ready or unacknowledged state;
- the same request ID produces at least three `job_failed` entries;
- the worker error contains the controlled processing exception;
- no `job_completed` exists for the request while the fault remains active;
- API readiness remains HTTP 200;
- queue-health remains HTTP 200;
- PostgreSQL `SELECT 1` succeeds;
- Redis returns `PONG`;
- `rabbitmq-diagnostics ping` succeeds;
- worker failure metrics are captured.

This evidence rejects consumer loss, broker outage, publish failure, and a broad database/cache outage.

## Recovery boundary

QW-002 uses `RUN-WORKER-PROCESSING-FAILURE`.

Once evidence proves a valid message is repeatedly failing because of a known transient processing condition, the exercise disables only that controlled condition. It does **not** restart or recreate the worker, API, RabbitMQ, PostgreSQL, or Redis.

The already-running consumer must receive the same requeued message and complete it naturally.

If the condition cannot be safely cleared, the failure continues after the expected remediation, or the event itself is malformed/unsupported, L2 must escalate rather than allow unlimited requeue. That permanent-failure case belongs to QW-004.

## Recovery success criteria

QW-002 is resolved only when:

1. the original request ID has at least three earlier `job_failed` events;
2. the same request ID later has exactly one `job_completed` event;
3. the original ticket becomes `processing_status=processed`;
4. queue total, ready, and unacknowledged counts return to zero;
5. RabbitMQ consumer count remains one;
6. worker container identity is unchanged;
7. API container identity is unchanged;
8. API, PostgreSQL, Redis, and RabbitMQ remain healthy.

A restart that happens to clear the symptom does not satisfy this exercise.

## Executable controller

```bash
bash scripts/qw_incident_002.sh exercise
```

Evidence is written to:

```text
.opsforge/evidence/qw-002/
```

## Operational records

- `INC-1302`
- `L2N-1302`
- `RUN-WORKER-PROCESSING-FAILURE`

## Dedicated CI

The existing `.github/workflows/queue-worker-incidents.yml` runs QW-001 and QW-002 as independent jobs so the new scenario cannot hide a regression in missing-consumer handling.

## Measured proof

Measured CI values will be recorded here only after the first complete QW-002 run succeeds. The documentation-complete commit will then receive a fresh exact-head validation cycle before merge.
