# NIGHTWATCH OPSFORGE — L2 Support Operations

Phase 5 adds an operating system around the technical platform. The objective is to practice the decisions an L2 / Application Support Engineer makes before, during, and after a production incident.

> OPSFORGE is a simulated production-support training environment. Records in this directory are exercises and portfolio evidence, not commercial production tickets.

## What Phase 5 changes

Earlier phases made NIGHTWATCH deployable, observable, and recoverable. Phase 5 defines how an operator receives work, classifies impact, records evidence, chooses an action, escalates when necessary, and transfers knowledge between shifts.

The core workflow is:

`customer/L1/alert -> incident intake -> impact/scope -> severity -> acknowledge -> investigate -> mitigate or escalate -> validate recovery -> problem/change/runbook follow-up -> handover/close`

## Machine-checkable records

Operational records live in `operations/records/` as JSON. They are validated by:

```bash
python scripts/validate_operations.py operations/records
```

The validator checks record identity, required evidence fields, incident status/severity, acknowledgement timestamps, training SLA targets, escalation packages, change rollback plans, recurring-problem linkage, handover windows, and runbook structure.

A malformed or incomplete operational record fails the dedicated GitHub Actions workflow rather than becoming silent portfolio documentation.

## L2 incident queue

Render the active queue:

```bash
python scripts/support_queue.py
```

Render active and resolved history:

```bash
python scripts/support_queue.py --all
```

The queue sorts by severity first and shows acknowledgement state. It intentionally states that severity is driven by customer/business impact, not technical complexity.

## Training acknowledgement objectives

| Severity | Simulated acknowledgement target | Typical impact |
|---|---:|---|
| P1 | 5 min | critical service broadly unavailable |
| P2 | 15 min | major customer-impacting degradation |
| P3 | 30 min | limited degradation or workaround available |
| P4 | 240 min | low-impact defect/question/maintenance item |

These are OPSFORGE training objectives, not claims about any employer's SLA.

## Record types

- `INC` — incident and customer impact timeline
- `L1E` — L1 to L2 escalation/intake package
- `L2N` — L2 hypotheses, evidence, actions, and assessment
- `L3E` — evidence package for development/specialist escalation
- `PRB` — recurring/systemic problem record
- `CHG` — controlled implementation/validation/rollback record
- `HOV` — shift handover
- `RUN` — approved operational runbook

Templates live in `operations/templates/`.

## Current exercises

### 1. Insufficient L1 report — `INC-1001` + `L1E-1001`

Initial symptom: the customer says the ticket page is not working.

Correct L2 behavior is **not** to restart the API. The escalation is missing customer scope, failure timestamp, HTTP/error information, request ID, reproducibility, and change context. The linked L1 record explicitly requests those items.

Training objective: establish scope before diagnosis.

### 2. L2-owned mitigation — `INC-1002` + `L2N-1002`

Ticket submission works but asynchronous processing stalls. Evidence shows:

- API remains healthy
- RabbitMQ accepts messages
- queue depth grows
- consumer count reaches zero
- worker throughput reaches zero
- worker logs show a connection interruption before exit

The approved low-blast-radius response is to restart **only the worker**, then prove consumer registration, queue drain, worker throughput, and synthetic-customer recovery.

Training objective: evidence-driven mitigation without unnecessary service restarts or code changes.

### 3. Correct L3 escalation — `INC-1003` + `L3E-1003`

Ticket creation returns HTTP 500 after a release while read/readiness/dependency health remains normal. Logs and tracing isolate the fault to the create-ticket application path.

No safe L2 operational fix remains. The escalation package includes business impact, version, reproduction, request ID, telemetry, troubleshooting already performed, suspected component, and a specific request for development action.

Training objective: escalation is a successful L2 outcome when the issue is outside the operational ownership boundary.

### 4. Incident -> problem -> change — `INC-1002`, `INC-1004`, `PRB-1001`, `CHG-1001`

A second worker-consumer outage has the same signature as the first. L2 restores service with the existing runbook, but the repeat occurrence is promoted to a problem record rather than being treated as another isolated incident.

`PRB-1001` links the recurring incidents, records the workaround, and points to `CHG-1001` for a permanent resilience change with staging validation and rollback requirements.

Training objective: incident management restores service; problem/change management reduces recurrence.

## Shift continuity

`HOV-20260818-A` demonstrates a handover that includes:

- current service health
- open incidents
- scheduled/pending changes
- known recurrence risk
- explicit next actions

The incoming engineer should be able to resume work without reconstructing the previous shift from chat messages or memory.

## Runbook discipline

`RUN-WORKER-RECOVERY` is deliberately constrained. It requires evidence that the broker and API are healthy and that the worker consumer is actually absent before a worker restart is allowed.

It also states what **not** to restart and defines the escalation boundary for recurring/code/configuration failures.

A runbook is an approved response to a confirmed fault pattern; it is not permission to skip diagnosis.

## Phase 5 definition of done

Phase 5 is complete when:

1. operational records are machine-checkable in CI;
2. the incident queue exposes priority/status/acknowledgement state;
3. an insufficient L1 report is rejected for specific missing evidence;
4. one incident is safely mitigated by L2 without code change;
5. one incident is correctly escalated with a complete evidence package;
6. recurring incidents become a problem record and controlled change;
7. shift handover and runbook boundaries are explicit;
8. the full existing OPSFORGE delivery/rollback pipeline still passes with the support-operations layer present.
