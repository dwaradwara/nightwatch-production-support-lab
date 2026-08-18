# OPSFORGE QW-003 — Queue Backlog

QW-003 trains L2 diagnosis of an asynchronous capacity problem where RabbitMQ is healthy, the worker consumer is present, and jobs are completing successfully, but incoming work arrives faster than the worker can process it.

> OPSFORGE is a simulated production-support training and portfolio environment. This is not a commercial production incident.

## Customer symptom

```text
POST /api/tickets             -> 201
API readiness                 -> healthy
RabbitMQ broker               -> healthy
RabbitMQ consumers            -> 1
Worker                        -> healthy/running
Worker outcomes               -> successful
Queue depth                   -> increasing
Tail tickets                  -> remain queued
```

This is intentionally different from QW-001 and QW-002:

- QW-001 has no consumer.
- QW-002 has a live consumer but repeated processing failures and requeue.
- QW-003 has a live consumer and successful processing, but insufficient throughput.

QW-004 will later model a permanently failing poison message.

## Controlled fault

Worker source code is unchanged.

A temporary PostgreSQL trigger adds a `600 ms` delay only when QW-003 incident tickets are moved from `queued` to `processed`. The worker continues to process each event successfully, but its effective service rate falls below the controlled arrival rate.

The controller publishes three fast batches of ten tickets. Queue depth is sampled after every batch. A valid QW-003 incident requires:

1. queue depth after batch 1 is already non-trivial;
2. batch 2 queue depth is greater than batch 1;
3. batch 3 queue depth is greater than batch 2 and reaches at least 15 messages;
4. after arrivals stop, the same consumer makes progress and queue depth decreases but remains non-zero;
5. correlated worker failures remain zero.

This proves a throughput mismatch rather than a stopped worker.

## Required L2 evidence

Before mitigation, L2 must capture:

- healthy one-consumer baseline;
- arrival volume and approximate publish rate;
- three queue-depth samples showing growth;
- ticket processing-state counts after each batch;
- a later progress sample proving successful processing continues;
- one live consumer throughout;
- zero correlated `job_failed` events for the QW-003 requests;
- at least one correlated `job_completed` while backlog remains;
- a tail ticket still in `queued` state;
- API readiness HTTP 200;
- queue-health HTTP 200;
- PostgreSQL `SELECT 1` success;
- Redis `PONG`;
- RabbitMQ diagnostic ping success;
- worker metrics;
- worker and API runtime identities.

A single queue-depth snapshot is not sufficient. The exercise requires evidence over time.

## Recovery boundary

QW-003 uses `RUN-WORKER-BACKLOG`.

Once evidence confirms the backlog is caused by the known temporary throughput constraint, L2 disables only that constraint. The worker, API, RabbitMQ, PostgreSQL, and Redis remain running.

The exercise does **not** allow:

- restarting a healthy worker to make the graph look better;
- purging durable customer work;
- recreating containers;
- changing application images;
- increasing capacity without evidence and approval.

In a real sustained-capacity incident, if demand still exceeds service rate after obvious transient constraints are removed, L2 should escalate for approved worker scaling or performance remediation.

## Recovery success criteria

QW-003 is resolved only when:

1. the queue returns to zero total/ready/unacknowledged messages;
2. RabbitMQ still reports one consumer;
3. every controlled QW-003 ticket reaches `processed`;
4. every incident request has exactly one correlated `job_completed` and zero `job_failed` events;
5. worker container identity is unchanged;
6. API container identity is unchanged;
7. customer read of the tail ticket succeeds;
8. API, PostgreSQL, Redis, and RabbitMQ remain healthy;
9. the backlog drain duration is captured.

## Executable controller

```bash
bash scripts/qw_incident_003.sh exercise
```

Evidence is written to:

```text
.opsforge/evidence/qw-003/
```

## Operational records

- `INC-1303`
- `L2N-1303`
- `RUN-WORKER-BACKLOG`

## Dedicated CI

The existing `OPSFORGE Queue Worker Incidents` workflow runs QW-001, QW-002, and QW-003 independently. QW-003 cannot be merged if the earlier queue/worker scenarios regress.

## Measured proof

`OPSFORGE Queue Worker Incidents` run #7 proved:

- healthy baseline: `messages=0`, `messages_ready=0`, `messages_unacknowledged=0`, `consumers=1`
- controlled workload: `30` tickets published in `4.534 s`
- approximate arrival rate: `6.617 tickets/s`
- controlled processing delay: `0.60 s` per QW-003 processed-state update
- queue sample 1: `8` messages (`3` ready, `5` unacknowledged, `1` consumer)
- queue sample 2: `16` messages (`11` ready, `5` unacknowledged, `1` consumer)
- queue sample 3: `24` messages (`19` ready, `5` unacknowledged, `1` consumer)
- database processing counts progressed from `2 processed / 8 queued` to `4 / 16` to `7 / 23`
- after arrivals stopped, queue depth fell from `24` to `19` while remaining non-zero, proving continued worker progress
- progress snapshot: `14` ready, `5` unacknowledged, `1` consumer
- API readiness remained HTTP `200`
- queue-health remained HTTP `200`
- PostgreSQL `SELECT 1` returned `1`
- Redis returned `PONG`
- RabbitMQ diagnostic ping succeeded
- incident worker outcome summary: `0` correlated failures and `15` correlated completions while backlog remained
- tail ticket ID `34` remained `processing_status=queued` during diagnosis
- disabling only the controlled delay drained the remaining backlog in `1.648 s`
- post-recovery queue: `0` total, `0` ready, `0` unacknowledged, `1` consumer
- all `30/30` controlled tickets reached `processed`
- final correlated outcomes: `0` failures and `30` completions
- worker container identity remained unchanged
- API container identity remained unchanged
- `133` evidence files were retained

The measured lesson is that the queue was growing **while successful processing continued**. Queue trend, arrival rate, completion progress, and consumer state identified a throughput-capacity mismatch without misclassifying the worker as down or failing.
