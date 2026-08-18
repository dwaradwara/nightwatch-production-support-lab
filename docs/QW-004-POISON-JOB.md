# OPSFORGE QW-004 — Poison Job

QW-004 trains L2 handling of permanently invalid asynchronous work. The RabbitMQ broker is healthy, the worker consumer is present, and valid jobs continue to complete, but one event can never satisfy the worker contract without correction.

> OPSFORGE is a simulated production-support training and portfolio environment. This is not a commercial production incident.

## Customer symptom

```text
Affected ticket               -> remains queued
RabbitMQ broker               -> healthy
RabbitMQ consumers            -> 1
Worker                        -> healthy/running
Poison request                -> deterministic job_failed attempts
Healthy requests              -> continue to job_completed
Retry budget                  -> bounded
Poison message                -> durable quarantine after exhaustion
```

This is intentionally different from the earlier Queue/Worker incidents:

- QW-001: no consumer exists.
- QW-002: the consumer is live and a valid event fails transiently, then succeeds after the condition clears.
- QW-003: processing succeeds but throughput is lower than arrival rate, so backlog grows.
- QW-004: one event is permanently incompatible and must stop consuming retry capacity.

## Platform reliability change

Before QW-004, the worker used `basic_nack(..., requeue=True)` for every exception. A permanently invalid message could therefore hot-loop forever.

QW-004 adds:

- configurable bounded retries (`WORKER_MAX_RETRIES`, default `5`);
- a retry header `x-opsforge-retry-count`;
- publisher-confirmed republish before acknowledging the failed delivery;
- durable quarantine queue `nightwatch-jobs.quarantine`;
- retry and quarantine Prometheus counters;
- structured `job_retry_scheduled` and `job_quarantined` events;
- preservation of request ID, message ID, ticket ID, failure type, and retry metadata.

The main queue declaration remains compatible with the API. Quarantine is application-managed rather than introduced by changing the main queue's RabbitMQ declaration arguments.

## Controlled fault

The exercise creates one real synthetic ticket row in `queued` state and publishes a durable event that references that ticket but deliberately uses:

```text
event_type=ticket.unsupported
```

The worker can parse the event and identify the ticket, but the event type permanently violates the supported worker contract.

The controller then creates additional valid tickets through the normal API. A valid QW-004 incident requires those healthy tickets to reach `processed` through the same worker while the poison request exhausts its retry budget and moves to quarantine.

## Required L2 evidence

Before remediation, L2 must capture:

- worker/API runtime identities;
- one live RabbitMQ consumer;
- configured retry ceiling;
- one poison request ID and event ID;
- exactly `max_retries + 1` correlated `job_failed` attempts;
- exactly `max_retries` `job_retry_scheduled` events;
- exactly one `job_quarantined` event;
- zero poison `job_completed` events before replay;
- affected ticket still `queued`;
- healthy control tickets all `processed`;
- main queue drained while quarantine contains exactly one message;
- API readiness HTTP 200;
- queue-health HTTP 200;
- PostgreSQL `SELECT 1` success;
- Redis `PONG`;
- RabbitMQ diagnostic ping success;
- worker retry/quarantine metrics.

The critical distinction is that **retrying is no longer treated as recovery when the same failure is deterministic and permanent**.

## Quarantine and escalation boundary

QW-004 uses `RUN-WORKER-POISON-JOB` and `L3E-1304`.

L2 may isolate permanently failing work and preserve evidence. L2 must not invent a producer/application contract correction in real operations when ownership is unclear.

The safe default for an unknown poison message is:

1. stop infinite retry through bounded quarantine;
2. preserve payload and headers;
3. confirm healthy work continues;
4. inspect the quarantined message;
5. escalate the producer/application contract defect;
6. replay only after a documented correction is approved.

## Controlled recovery

For this lab exercise the root cause is deliberately known. The recovery controller reads exactly one quarantined message, verifies its request ID and unsupported event type, corrects only:

```text
ticket.unsupported -> ticket.created
```

It then resets retry state, preserves correlation metadata, republishes the corrected event once to the main queue, and acknowledges the quarantined copy only after confirmed publish.

No worker/API restart, RabbitMQ restart, queue purge, or application redeployment is used.

## Recovery success criteria

QW-004 is resolved only when:

1. the poison request quarantines exactly once;
2. valid control work completed while poison work was isolated;
3. quarantine inspection proves the expected permanent contract defect;
4. corrected replay produces exactly one `job_completed` for the poison request;
5. the original affected ticket becomes `processed`;
6. main and quarantine queues return to zero;
7. RabbitMQ still reports one consumer;
8. worker/API container identities remain unchanged;
9. API, PostgreSQL, Redis, and RabbitMQ remain healthy.

## Executable controller

```bash
bash scripts/qw_incident_004.sh exercise
```

Evidence is written to:

```text
.opsforge/evidence/qw-004/
```

## Operational records

- `INC-1304`
- `L2N-1304`
- `L3E-1304`
- `RUN-WORKER-POISON-JOB`

## Dedicated CI

`OPSFORGE Queue Worker Incidents` runs QW-001 through QW-004 independently. Because QW-004 introduces bounded retry behavior into the worker, QW-002 is explicitly run with a high retry ceiling so its transient-failure semantics remain under test rather than being accidentally converted into a poison-message case.

## Measured proof

`OPSFORGE Queue Worker Incidents` run #11 proved the QW-004 runtime path on the implementation head:

- configured worker retry ceiling: `5`;
- poison ticket ID: `5`;
- poison request ID: `aa283c66-5262-4c43-b41c-bc72ade37655`;
- poison event ID: `22aaf9ec-4f35-40ec-a1c3-9854eef9029f`;
- deliberately invalid event type: `ticket.unsupported`;
- correlated poison outcomes before remediation: `6` `job_failed`, `5` `job_retry_scheduled`, `1` `job_quarantined`, `0` `job_completed`;
- the affected ticket remained `processing_status=queued` while quarantined;
- main queue after isolation: `0` messages, `0` ready, `0` unacknowledged, `1` consumer;
- quarantine after isolation: `1` message, `1` ready, `0` unacknowledged;
- three healthy control tickets all reached `processed` through the same worker while the poison event was isolated;
- API readiness and queue-health remained HTTP `200`;
- PostgreSQL `SELECT 1` returned `1`;
- Redis returned `PONG`;
- RabbitMQ diagnostic ping succeeded;
- controlled remediation verified the quarantined request and changed only `ticket.unsupported` to `ticket.created` before one confirmed replay;
- after replay the original poison ticket reached `processed`;
- final poison outcomes: `6` failures, `5` scheduled retries, `1` quarantine, exactly `1` completion;
- final main queue: `0 / 0 / 0` with `1` consumer;
- final quarantine queue: `0 / 0 / 0`;
- worker container remained `5c0fdd7868cb1e02dd0a8e2c7ac1567511737d2ca6726fe1b87747c7ec8e11fe`;
- API container remained `cd7380ddc7c60749b88b02619f907863355c2b2362ddd61d21373af4800653e4`;
- no worker/API restart, RabbitMQ restart, queue purge, or application redeployment was used;
- `51` evidence files were retained.

The durable lesson is that **a deterministic message-specific failure must stop consuming live retry capacity**. Bounded retry, durable quarantine, preserved correlation evidence, healthy-work proof, ownership escalation, and controlled replay provide a safer L2 response than infinite requeue or broad service restarts.
