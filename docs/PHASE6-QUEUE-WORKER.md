# NIGHTWATCH OPSFORGE — Phase 6 Queue / Worker Incidents

The Queue / Worker domain trains L2 diagnosis of asynchronous customer-impact failures. The key operational distinction is that HTTP success and broker reachability do not guarantee durable work is being consumed, acknowledged, retried safely, or drained at a sustainable rate.

> OPSFORGE is a simulated production-support training and portfolio environment. These exercises are not commercial production incidents.

## Domain sequence

1. QW-001 — consumer missing — complete
2. QW-002 — processing failure / retry — complete
3. QW-003 — queue backlog — complete
4. QW-004 — poison job

**Queue / Worker domain status: IN PROGRESS.** QW-001 through QW-003 are complete; QW-004 remains.

Phase 7 later removes the root-cause labels and turns validated incidents into blind scenarios.

## QW-001 — consumer missing

Customer-facing behavior:

```text
Ticket create                -> HTTP 201
Ticket processing            -> remains queued
API readiness                -> healthy
RabbitMQ broker              -> healthy
RabbitMQ ready messages      -> accumulate
RabbitMQ unacknowledged      -> 0
RabbitMQ consumers           -> 0
Worker                       -> stopped
```

### Diagnostic objective

L2 must distinguish a missing consumer from:

- RabbitMQ outage;
- event publish failure;
- PostgreSQL or Redis outage;
- a slow in-flight worker job;
- an API failure.

The proof uses the same customer event across API state, PostgreSQL ticket state, RabbitMQ queue counters, worker runtime state, and request-ID logs.

### Measured QW-001 proof

`OPSFORGE Queue Worker Incidents` run #1 proved:

- healthy baseline queue: `messages_ready=0`, `messages_unacknowledged=0`, `consumers=1`
- worker-only stop reduced consumer count to `0`
- incident ticket creation still returned HTTP `201`
- affected ticket ID: `5`
- affected request ID: `9d9cabe6-02d2-4c30-9b93-ae2841ad3ee7`
- affected ticket remained `processing_status=queued`
- incident queue state: `messages_ready=1`, `messages_unacknowledged=0`, `consumers=0`
- API readiness remained HTTP `200`
- queue-health remained HTTP `200`
- PostgreSQL `SELECT 1` returned `1`
- Redis returned `PONG`
- RabbitMQ diagnostic ping succeeded
- worker-only recovery restored `consumers=1`
- ready backlog returned to `0`
- the original affected ticket reached `processing_status=processed`
- the worker container ID was unchanged before and after recovery
- the API container ID was unchanged
- correlated worker `job_completed` evidence was captured for the original request
- 33 evidence files were retained

The durable lesson is that broker health and HTTP success did not prove asynchronous service usability; queue state plus consumer count and the customer ticket state identified the missing worker consumer.

### Mitigation objective

QW-001 deliberately reuses `RUN-WORKER-RECOVERY` from Phase 5. The exercise starts only the existing worker container after evidence confirms zero consumers and a healthy broker. It does not restart healthy dependencies or redeploy application images.

Recovery is not declared until the original queued ticket becomes processed and the worker log contains correlated `job_completed` evidence.

Detailed operator note:

- `docs/QW-001-CONSUMER-MISSING.md`

Executable controller:

- `scripts/qw_incident_001.sh`

Operational records:

- `INC-1301`
- `L2N-1301`
- `RUN-WORKER-RECOVERY` (existing Phase 5 runbook)

## QW-002 — processing failure / retry

Customer-facing behavior:

```text
Ticket create                -> HTTP 201
Ticket processing            -> remains queued
API readiness                -> healthy
RabbitMQ broker              -> healthy
RabbitMQ consumers           -> 1
Worker                       -> running/healthy
Same request ID              -> repeated job_failed
Message                      -> nack/requeue loop while fault exists
```

### Diagnostic objective

L2 must distinguish a processing failure from:

- QW-001 consumer loss;
- RabbitMQ outage;
- event publish failure;
- broad PostgreSQL or Redis outage;
- a permanently malformed poison message.

The controlled fault is a temporary ticket-scoped PostgreSQL trigger that rejects only the worker update from `queued` to `processed`. Worker source code is unchanged. The worker remains connected to RabbitMQ, repeatedly receives the same valid event, logs `job_failed`, and issues `basic_nack(..., requeue=True)`.

Required proof includes at least three correlated failures for one request ID, one live consumer, the message remaining in ready/unacknowledged state, healthy API/dependency checks, and no `job_completed` while the transient fault remains active.

### Mitigation objective

QW-002 uses `RUN-WORKER-PROCESSING-FAILURE`. L2 clears only the confirmed transient processing condition and leaves the healthy worker consumer running. Recovery is complete only when the **same request ID** later produces exactly one `job_completed`, the original ticket becomes `processed`, and queue depth returns to zero without worker/API restart or redeployment.

A permanently failing or malformed event must not be treated as a valid retry case; that belongs to QW-004 poison-message handling.

Detailed operator note:

- `docs/QW-002-PROCESSING-FAILURE-RETRY.md`

Executable controller:

- `scripts/qw_incident_002.sh`

Operational records:

- `INC-1302`
- `L2N-1302`
- `RUN-WORKER-PROCESSING-FAILURE`

### Measured QW-002 proof

`OPSFORGE Queue Worker Incidents` run #4 proved:

- healthy baseline: `messages=0`, `messages_ready=0`, `messages_unacknowledged=0`, `consumers=1`
- incident ticket ID: `5`
- incident request ID: `56e6af9b-ed42-475d-9da1-1f03f4ce909b`
- ticket remained `processing_status=queued` while the transient processing fault was active
- the required minimum of `3` correlated failures was observed before diagnosis completed
- complete worker logs contained `13` correlated `job_failed` events for the same request
- incident queue snapshot: `messages=1`, `messages_ready=0`, `messages_unacknowledged=1`, `consumers=1`
- API readiness remained HTTP `200`
- queue-health remained HTTP `200`
- PostgreSQL `SELECT 1` returned `1`
- Redis returned `PONG`
- RabbitMQ diagnostic ping succeeded
- after clearing only the transient condition, the same request produced exactly `1` `job_completed`
- the original ticket became `processing_status=processed`
- post-recovery queue: `messages=0`, `messages_ready=0`, `messages_unacknowledged=0`, `consumers=1`
- worker and API container identities were unchanged
- no worker restart or application redeployment was used
- 36 evidence files were retained

The durable lesson is that **a live consumer does not prove successful processing**. Request-level failure correlation, queue state, and worker metrics distinguish transient processing failure from missing-consumer and broker-outage scenarios.

## QW-003 — queue backlog

Customer-facing behavior:

```text
Ticket create                -> HTTP 201
API readiness                -> healthy
RabbitMQ broker              -> healthy
RabbitMQ consumers           -> 1
Worker                       -> running/healthy
Worker outcomes              -> successful
Queue depth                  -> grows across arrival batches
Tail tickets                 -> remain queued
```

### Diagnostic objective

L2 must distinguish a throughput backlog from:

- QW-001 consumer loss;
- QW-002 processing failure/retry;
- RabbitMQ outage;
- publish failure;
- a broad database/cache outage;
- a single poison message.

The controlled fault is a temporary `600 ms` ticket-scoped processing delay. Worker code is unchanged. Three fast batches of ten tickets are published while one consumer continues successfully processing earlier events.

Required proof includes queue growth across all three samples, one consumer throughout, zero correlated failures, some correlated completions while backlog remains, healthy dependencies, and a later progress sample showing the queue shrinking but still non-zero after arrivals stop.

### Mitigation objective

QW-003 uses `RUN-WORKER-BACKLOG`. L2 disables only the confirmed temporary throughput constraint and leaves the healthy worker and dependencies running. Recovery is complete only when the entire original backlog drains, all controlled tickets become `processed`, and every request has exactly one completion with zero failures.

A sustained real-capacity mismatch that persists after transient constraints are removed should be escalated for approved worker scaling or performance remediation rather than blind restarts or queue purges.

Detailed operator note:

- `docs/QW-003-QUEUE-BACKLOG.md`

Executable controller:

- `scripts/qw_incident_003.sh`

Operational records:

- `INC-1303`
- `L2N-1303`
- `RUN-WORKER-BACKLOG`

### Measured QW-003 proof

`OPSFORGE Queue Worker Incidents` run #7 proved:

- healthy baseline: `messages=0`, `messages_ready=0`, `messages_unacknowledged=0`, `consumers=1`
- `30` tickets were published in `4.534 s` (`~6.617/s`)
- controlled processing delay: `0.60 s`
- queue depth grew `8 -> 16 -> 24` across the three arrival batches
- queue composition at peak: `19` ready, `5` unacknowledged, `1` consumer
- database progress across samples: `2/8`, `4/16`, then `7/23` processed/queued
- after arrivals stopped, queue depth fell from `24` to `19` while still non-zero, proving continued progress rather than a stuck worker
- progress snapshot: `14` ready, `5` unacknowledged, `1` consumer
- API readiness and queue-health remained HTTP `200`
- PostgreSQL `SELECT 1`, Redis `PONG`, and RabbitMQ ping all succeeded
- during diagnosis: `0` correlated failures and `15` correlated completions
- tail ticket ID `34` remained queued during the incident
- removing only the throughput delay drained the remaining backlog in `1.648 s`
- post-recovery queue returned to `0/0/0` with `1` consumer
- all `30/30` controlled tickets reached `processed`
- final correlated outcomes: `0` failures and `30` completions
- worker and API container identities were unchanged
- `133` evidence files were retained

The durable lesson is that **a live, successful consumer can still be under-capacity**. Queue trend plus completion progress distinguishes throughput saturation from worker failure.

## Definition of done for the Queue / Worker incidents

Each QW incident is complete only when one exact branch head passes:

- Support Operations validation for its operational records;
- the Queue / Worker workflow with all completed QW incidents;
- existing database deep-incident regressions;
- existing application-incident regressions;
- full NIGHTWATCH OPSFORGE staging -> production -> controlled bad-release rejection -> rollback -> independent recovery verification.

The queue/worker domain remains in progress until QW-001 through QW-004 are completed.
