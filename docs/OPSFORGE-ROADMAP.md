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

Status: implemented and CI-validated on August 17, 2026; merged to `main` on August 18, 2026.

Goal: support evidence-driven diagnosis.

Delivered capabilities:
- stable API RED metrics and dependency latency/availability signals
- PostgreSQL telemetry through a pinned exporter
- Redis telemetry through a pinned exporter
- RabbitMQ per-object queue metrics for queue depth, consumers, and message state
- worker processing/error/latency metrics
- Prometheus recording rules for customer/API/database/queue/worker views
- Prometheus detection rules for customer-path failure, API errors/latency, dependency failure, long DB transactions, Redis failure, queue backlog, and worker failures
- provisioned `OPSFORGE L2 Operations` Grafana dashboard
- centralized Loki view for API/worker/Nginx logs
- Tempo request correlation using the same edge-owned request ID
- reduced Alloy Docker discovery latency so newly deployed containers become searchable quickly
- release-gate validation for telemetry targets, rules, Loki correlation, Tempo correlation, and Grafana provisioning

Exit criteria:
- operator can correlate customer symptom across metrics, logs, and traces

Operational design is documented in `docs/OBSERVABILITY.md`.

## Phase 5 — Support Operations

Status: implemented and CI-validated on August 18, 2026.

Goal: model the L2 job rather than just the technology.

Delivered capabilities:
- machine-checkable operational records under `operations/records/`
- support-record validator with severity/status/acknowledgement and record-specific requirements
- severity-aware L2 incident queue view
- dedicated `OPSFORGE Support Operations` GitHub Actions workflow
- incident template
- L1 escalation template
- L2 investigation notes template
- change record template
- problem record template
- shift handover template
- escalation-to-development template
- runbook template

Validated exercises:
- `INC-1001` + `L1E-1001`: insufficient L1 report requiring specific scope/evidence clarification
- `INC-1002` + `L2N-1002`: issue mitigated by L2 using a worker-only approved action without code change
- `INC-1003` + `L3E-1003`: issue correctly escalated to development with version, reproduction, request ID, telemetry, troubleshooting, suspected component, and requested action
- `INC-1002` + `INC-1004` -> `PRB-1001` -> `CHG-1001`: recurring incidents promoted to problem management and a controlled permanent-change path
- `HOV-20260818-A`: shift continuity with open incidents, risk, pending change, and next actions
- `RUN-WORKER-RECOVERY`: evidence-gated worker recovery with an explicit L2 escalation boundary

Validation evidence:
- support-specific CI validates 11 operational records and renders both active and historical incident queues
- the complete existing OPSFORGE staging -> production -> rejected-candidate -> rollback -> independent recovery-verification pipeline also passes with Phase 5 present

Exit criteria:
- operational records fail CI when structurally incomplete or inconsistent
- queue makes severity, ownership, status, and acknowledgement state visible
- L2 can distinguish missing intake evidence from a diagnosable incident
- a safe L2 mitigation is separated from code-level escalation
- recurring incidents flow into problem/change management
- shift handover and runbook boundaries preserve operational context between engineers
- the full technical production-simulation contract remains green

Operational design and exercise semantics are documented in `docs/SUPPORT-OPERATIONS.md`.

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
