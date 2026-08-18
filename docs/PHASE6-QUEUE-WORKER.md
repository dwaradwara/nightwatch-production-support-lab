# NIGHTWATCH OPSFORGE — Phase 6 Queue / Worker Incidents

The Queue / Worker domain trains L2 diagnosis of asynchronous customer-impact failures. The key operational distinction is that HTTP success and broker reachability do not guarantee durable work is being consumed, acknowledged, retried safely, or drained at a sustainable rate.

> OPSFORGE is a simulated production-support training and portfolio environment. These exercises are not commercial production incidents.

## Domain sequence

1. QW-001 — consumer missing
2. QW-002 — processing failure / retry
3. QW-003 — queue backlog
4. QW-004 — poison job

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

## Definition of done for QW-001

QW-001 is complete only when one exact branch head passes:

- Support Operations validation for the new incident records;
- QW-001 controlled queue/worker workflow;
- existing database deep-incident regressions;
- existing application-incident regressions;
- full NIGHTWATCH OPSFORGE staging -> production -> controlled bad-release rejection -> rollback -> independent recovery verification.

The queue/worker domain remains in progress until QW-002 through QW-004 are completed.
