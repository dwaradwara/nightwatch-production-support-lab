# NIGHTWATCH OPSFORGE — Operating Model

OPSFORGE converts NIGHTWATCH from a collection of troubleshooting exercises into a simulated production-operations environment for L2 / Application Support Engineering.

> This is a training and portfolio environment. It is intentionally designed to model production practices, but it must never be presented as commercial production experience.

## Mission

Operate one coherent SaaS-style system through its full lifecycle:

`code -> test -> build -> deploy -> observe -> detect -> triage -> mitigate -> recover -> RCA -> prevention`

The project is successful only when the operator can explain and troubleshoot the system without relying on a known root cause.

## Core rule

Do not change a component until evidence points to that component.

Restarts, rollbacks, configuration edits, database changes, and infrastructure changes are recovery actions — not diagnostic shortcuts.

## Production topology

```text
Synthetic client / browser
          |
          v
      DNS / TLS
          |
          v
        Nginx
          |
          v
      NIGHTWATCH API
       /     |      \
      v      v       v
PostgreSQL  Redis  RabbitMQ
                     |
                     v
                   Worker
                     |
                     v
             Mock external service

Observability plane
-------------------
Prometheus  -> metrics
Grafana     -> dashboards
Loki/Alloy  -> centralized logs
Tempo/OTel  -> traces

Delivery plane
--------------
Git -> GitHub Actions -> image build -> staging -> validation -> production -> health verification / rollback
```

## Environment model

OPSFORGE uses three logical environments.

### DEV

Purpose: local development and fast validation.

Allowed:
- source edits
- local debugging
- disposable data
- deliberate fault injection

Not considered production evidence by itself.

### STAGING

Purpose: release validation before production.

Required before promotion:
- automated tests pass
- container images build successfully
- database migration validation passes
- readiness checks pass
- synthetic transaction passes
- no critical alert is firing

### PRODUCTION

Purpose: stable simulated customer-facing environment.

Rules:
- no casual direct edits
- changes require a change record
- deployment must identify a version
- rollback path must exist before deployment
- recovery must be validated from the customer path
- incidents are documented with timestamps and evidence

## Service catalog

| Service | Function | Primary dependency | Typical failure signal |
|---|---|---|---|
| Nginx | public HTTP/HTTPS entry point | API | 502/504, TLS or routing failure |
| API | synchronous application requests | PostgreSQL, Redis | 5xx, latency, dependency errors |
| PostgreSQL | persistent transactional data | storage | slow queries, locks, connection exhaustion |
| Redis | cache / fast dependency | memory | cache errors, timeouts |
| RabbitMQ | asynchronous queue | storage / worker | queue depth, publish/consume failures |
| Worker | background processing | RabbitMQ | backlog, failed jobs, missing consumer |
| Prometheus | metrics collection | service exporters | missing/stale metrics |
| Loki/Alloy | centralized logging | Docker logs | missing logs / ingestion failures |
| Tempo/OTel | distributed tracing | API instrumentation | missing traces / broken correlation |

## L2 responsibility boundary

OPSFORGE must train both technical troubleshooting and operational judgment.

### L1

Expected to:
- capture customer symptom
- identify affected user/feature
- record timestamps
- collect basic reproduction details
- perform approved first-line checks
- escalate with evidence

### L2 — operator role

Expected to:
- determine scope and business impact
- assign/confirm severity
- reproduce where possible
- correlate logs, metrics, traces, request IDs, and recent changes
- form and test hypotheses
- apply approved mitigation
- rollback a bad release when warranted
- validate service restoration
- communicate status
- escalate to development/DBA/cloud when ownership or permissions require it
- create RCA, problem record, runbook, or monitoring improvement when appropriate

### L3 / Development

Expected to:
- own code-level defects requiring source changes
- provide permanent fixes when an operational workaround is insufficient

### DBA / Cloud / Security

Expected to:
- own privileged specialist actions outside the simulated L2 permission boundary

An incident is not considered poorly handled merely because L2 escalates it. Escalating with strong evidence is correct behavior when the fault is outside L2 ownership.

## Incident lifecycle

Every serious OPSFORGE incident follows this sequence:

1. Detect or receive escalation.
2. Acknowledge.
3. Establish customer and business impact.
4. Assign severity.
5. Establish last-known-good state and recent changes.
6. Reproduce where safe.
7. Inspect telemetry before changing the system.
8. Build ranked hypotheses.
9. Test the highest-value hypothesis.
10. Mitigate to restore service.
11. Validate recovery through the public/customer path.
12. Monitor for recurrence.
13. Record root cause when known.
14. Create corrective/preventive actions.
15. Update runbook, alert, test, or architecture where needed.

## Severity model

Severity is based on customer/business impact, not how technically interesting the failure is.

| Severity | Definition | Example | Target acknowledgement |
|---|---|---|---|
| P1 | critical service unavailable or major business function broadly blocked | login unavailable for all customers, transaction path down | 5 min |
| P2 | major degradation or important function unavailable for a significant subset | severe API latency, worker backlog affecting many customers | 15 min |
| P3 | limited impact with workaround or non-critical function affected | report export failing, notification delays | 30 min |
| P4 | low-impact defect, question, or maintenance item | cosmetic issue, documentation request | business queue |

These targets are training objectives, not claims about an employer SLA.

## Service objectives

Initial training SLOs:

- Availability: >= 99.9% during scheduled simulation windows
- API p95 latency: < 500 ms under baseline load
- HTTP 5xx rate: < 1% under baseline load
- Synthetic critical journey: >= 99% success during scheduled simulation windows

These values may be revised after baseline load testing establishes realistic system capacity.

## Evidence standard

A serious incident must preserve enough evidence that another engineer can understand what happened.

Minimum evidence:
- incident ID and severity
- first observed timestamp
- customer-facing symptom
- affected component or feature
- public-path reproduction
- relevant logs
- relevant metrics
- trace/request ID when applicable
- recent change/deployment correlation
- mitigation or rollback action
- recovery validation
- root cause or clearly stated unresolved cause
- prevention/follow-up action

## Operational records

OPSFORGE will maintain distinct records for:

- `INC` — incident
- `PRB` — recurring/systemic problem
- `CHG` — planned change
- `RUN` — runbook
- `DR` — disaster-recovery exercise

Example lifecycle:

`INC-024 -> recurring pattern -> PRB-006 -> CHG-031 -> permanent fix -> monitoring/runbook update`

## Observability standard

The operator should answer three different questions using three signals:

- Metrics: **What changed and when?**
- Logs: **What failed and what did the component report?**
- Traces: **Where did a request spend time or fail across the request path?**

OPSFORGE will add correlation IDs so one customer transaction can be followed across proxy, API, worker, and telemetry where technically practical.

## Change-management standard

Production changes require:
- change ID
- reason
- affected services
- risk assessment
- implementation steps
- validation steps
- rollback steps
- expected telemetry
- result

A deployment that merely finishes is not considered successful. Customer-path and service-health validation must pass.

## Failure-injection standard

Faults should become progressively less obvious.

Early exercises may declare the target domain. Mature exercises should reveal only the customer symptom and telemetry available to the operator.

Target fault classes include:
- bad deployment
- failed schema migration
- missing/inefficient index
- database lock contention
- database connection exhaustion
- Redis outage or latency
- RabbitMQ backlog
- worker crash/stall
- bad Nginx upstream
- TLS identity/expiry failure
- DNS resolution failure
- disk/resource exhaustion
- memory pressure
- slow external dependency
- secret/configuration mismatch
- observability blind spot
- multi-layer cascading failure

## Definition of done

A component is not "done" because it starts successfully.

It is done when the operator can answer:

1. Why does this component exist?
2. What depends on it?
3. What are its normal health signals?
4. How does it fail?
5. How is failure detected?
6. How is failure distinguished from upstream/downstream failures?
7. What is the safe mitigation?
8. How is recovery validated?
9. What requires escalation?
10. What prevents recurrence?

OPSFORGE is complete only when unknown incidents can be handled through this operating model without knowing the injected root cause in advance.
