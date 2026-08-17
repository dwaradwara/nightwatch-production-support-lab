# NIGHTWATCH OPSFORGE — Build Roadmap

This roadmap prioritizes operational depth over adding technologies.

## Phase 0 — Foundation

Goal: establish the production operating model before modifying architecture.

Deliverables:
- operating model and L2 responsibility boundary
- severity model
- service objectives
- incident/change/problem/runbook record types
- definition of done
- dedicated OPSFORGE branch

Exit criteria:
- architecture changes can be judged against explicit operational requirements

## Phase 1 — Stable Production Baseline

Goal: make the existing Compose stack predictable, versioned, and diagnosable.

Planned work:
- separate configuration from secrets
- add explicit service health checks
- add startup/readiness dependency logic
- remove unnecessary host port exposure
- pin container image versions where practical
- define application/version metadata
- add structured API logs and request correlation ID
- validate persistent database behavior
- define normal baseline metrics

Exit criteria:
- clean start from zero state
- all required services reach known health state
- public path passes
- dependencies are independently testable
- one request can be correlated through logs/traces

## Phase 2 — Customer Journey and Business Model

Status: implemented and CI-validated on August 17, 2026.

Goal: make failures map to customer/business impact rather than generic endpoints.

Delivered capabilities:
- identify a simulated customer with `X-Customer-ID`
- create a customer-owned ticket
- read a customer-owned ticket
- update ticket support status
- enqueue a durable background ticket event
- process the event with the RabbitMQ worker
- persist worker processing evidence and final ticket state
- run a continuous synthetic customer journey
- correlate the create request across Nginx, API, RabbitMQ metadata, worker logs, and Tempo

Exit criteria:
- a repeatable critical transaction can distinguish "server up" from "service usable"

Evidence and operational semantics are documented in `docs/CUSTOMER-JOURNEY.md`.

## Phase 3 — Delivery Pipeline

Status: implemented and CI-validated on August 17, 2026.

Goal: model safe change delivery and evidence-based rollback.

Delivered capabilities:
- Git-derived versioned application images
- staging and production runtime isolation using separate Compose projects, container prefixes, networks, and host ports
- schema compatibility validation before release acceptance
- reusable build, deploy, verify, promote, rollback, and teardown procedures
- release/environment identity verification through `/version`
- full customer journey as a staging and production deployment gate
- request/log/trace/worker/queue/synthetic/Prometheus/Grafana verification during release acceptance
- local current/previous/candidate release state and rollback history
- controlled release-regression build for rollback drills
- automatic production rollback to the recorded last-good release when post-deploy customer validation fails
- mandatory complete verification after rollback

Validated flow:

`branch -> validation -> versioned build -> staging -> customer/observability gate -> production -> post-deploy gate -> accept or rollback -> recovery verification`

Key exercise completed:
- accepted release `git-b980324068e6`
- controlled candidate `git-b980324068e6-regression` retained readiness but broke customer ticket creation with HTTP 500
- candidate was rejected
- production was restored to `git-b980324068e6`
- complete post-rollback verification and an independent second verification passed

Exit criteria:
- one release can be promoted through staging to production with defensible verification
- a customer-impacting candidate can be rejected even when infrastructure health remains green
- rollback restores the recorded last-good release and proves recovery from the customer path

Operational design is documented in `docs/DELIVERY-PIPELINE.md`; validation evidence is recorded in `docs/PHASE3-STATUS.md`.

## Phase 4 — Production Observability

Goal: support evidence-driven diagnosis.

Metrics:
- request count and rate
- HTTP status/error rate
- p50/p95/p99 latency
- dependency latency/error metrics
- PostgreSQL connections/query indicators
- Redis availability
- RabbitMQ queue depth
- worker processing/error metrics
- container/resource signals where practical

Logs:
- timestamp
- severity
- service
- request/correlation ID
- endpoint/job identifier
- meaningful error context

Traces:
- incoming API request
- meaningful dependency spans where available

Exit criteria:
- operator can correlate customer symptom across metrics, logs, and traces

## Phase 5 — Support Operations

Goal: model the L2 job rather than just the technology.

Deliverables:
- incident template
- L1 escalation template
- L2 investigation notes
- change record template
- problem record template
- shift handover template
- escalation-to-development template
- runbook template

Exercises include:
- insufficient L1 report requiring scope clarification
- issue correctly escalated to L3
- issue mitigated by L2 without code change
- recurring incidents promoted to a problem record

## Phase 6 — Deep Incident Domains

Goal: build depth in the highest-value production-support areas.

### Database
- slow query / missing index
- lock contention
- long-running transaction
- connection exhaustion
- failed/incompatible migration
- backup/restore validation

### Application
- 500 regression
- dependency timeout
- malformed configuration
- resource degradation

### Queue / worker
- consumer missing
- processing failure/retry
- queue backlog
- poison job scenario

### Proxy/network/security
- upstream failure
- DNS
- TLS
- CORS
- secret mismatch

### Delivery
- broken build
- broken deployment
- unhealthy release
- rollback

Exit criteria:
- incident response uses customer impact, telemetry, hypothesis testing, mitigation, validation, and follow-up

## Phase 7 — Fault Injection and Blind Scenarios

Goal: remove the unrealistic advantage of knowing the root cause.

Planned design:
- scenario activation separated from operator instructions
- scenario ID hidden during exercise
- only customer/L1 symptom initially revealed
- telemetry remains genuine
- scenario includes reset/recovery mechanism

Performance tracked:
- time to acknowledge
- time to form useful hypothesis
- time to mitigate/restore
- unnecessary changes/restarts
- escalation quality
- evidence quality

Exit criteria:
- operator can solve unknown single-fault incidents consistently

## Phase 8 — Disaster Recovery

Goal: practice recovery, not merely backup creation.

Exercises:
- restore database from backup
- measure recovery time
- identify data-loss window
- verify schema/data/application
- record RTO/RPO outcome

## Phase 9 — Multi-Layer Final Scenarios

Goal: diagnose cascading or correlated failures.

Examples:
- bad release creates N+1 query -> DB saturation -> API latency -> queue growth -> customer failures
- external dependency slowdown -> worker backlog -> resource growth -> partial service degradation

Operator receives only:

`Production degraded; customers affected.`

Exit criteria:
- independently execute incident lifecycle from impact assessment through postmortem

## Phase 10 — Hiring Evidence

Goal: expose engineering judgment without making recruiters reverse-engineer the repository.

Deliverables:
- clear root README
- architecture diagram
- service catalog and SLO summary
- 6–10 strongest incident case studies
- one disaster-recovery case study
- one failed-deployment/rollback case study
- measurable operational outcomes where defensible
- concise recruiter-facing project summary

## Scope control

Do not add a technology simply because it appears in job descriptions.

New technology requires a concrete operational reason. The default is to deepen the existing stack.

Specifically avoid premature expansion into:
- large microservice architectures
- multiple clouds
- Kafka without a real requirement
- Jenkins in addition to GitHub Actions without a real requirement
- Terraform before the current system has a meaningful infrastructure lifecycle to codify
- Kubernetes as the primary platform before the Compose production model is understood end to end

The project exists to train production-support judgment, not maximize tool count.
