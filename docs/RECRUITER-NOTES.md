# Recruiter Notes

## 30-second project summary

NIGHTWATCH is a production-support troubleshooting lab built around a containerized Python service stack. Rather than demonstrating tools in isolation, it reproduces customer-facing incidents across Nginx, Docker networking, PostgreSQL, RabbitMQ, Redis, Kubernetes, and observability tooling, then documents the evidence used to isolate and recover each failure.

## What to look at first

1. **[Incident Casebook](INCIDENTS.md)** — strongest troubleshooting examples and RCAs.
2. **[Architecture](ARCHITECTURE.md)** — request flow, dependencies, and observability path.
3. **GitHub Actions** — automated Python validation and API/worker Docker builds.
4. **Failure injectors** — reproducible reverse-proxy/container incidents without exposing the fault before investigation.

## Strongest examples

- Diagnosed Nginx `502` failures by separating proxy health from direct backend health and inspecting the actual configured upstream.
- Used PostgreSQL `pg_stat_activity` to identify a blocking session causing API timeouts, then terminated only the blocker rather than restarting the database.
- Distinguished RabbitMQ backlog states using `messages_ready`, `messages_unacknowledged`, and consumer counts.
- Diagnosed a Kubernetes Service with a healthy Pod but no backend EndpointSlice because the Service selector did not match Pod labels.
- Correlated service health through Prometheus/Grafana metrics, centralized Loki logs, and OpenTelemetry/Tempo traces.

## Scope

This is a lab, not a claim of commercial production ownership. Its purpose is to demonstrate practical troubleshooting habits, layered diagnosis, evidence collection, safe recovery choices, and technical documentation relevant to L2 Technical Support, Application Support, Product Support, Production Support, and junior SRE/NOC-adjacent roles.

## Resume-ready wording

**NIGHTWATCH — Production Support Engineering Lab**

- Built a Docker-based support lab spanning Nginx, Flask, PostgreSQL, RabbitMQ, Redis, Prometheus/Grafana, Loki/Alloy, OpenTelemetry/Tempo, Kubernetes and GitHub Actions.
- Reproduced and diagnosed application incidents including `500/502` errors, container/network failures, PostgreSQL authentication and lock contention, queue backlogs, cache outages and Kubernetes Service routing failures.
- Used logs, health endpoints, `pg_stat_activity`, RabbitMQ queue counters, Prometheus metrics, distributed traces and Kubernetes EndpointSlices to isolate root causes before applying targeted recovery actions.
- Added automated CI validation and Docker image builds, externalized application credentials through environment variables, and documented incident RCAs and verification steps.

## Interview explanation

A concise way to explain the project:

> “I built NIGHTWATCH because I wanted support practice that starts with a symptom rather than a tutorial instruction. I deliberately break one layer, investigate the customer-facing path, narrow the fault using direct health checks, logs or dependency-specific evidence, fix only the failing layer, and then verify recovery through the original path. The most useful incidents were a PostgreSQL lock that caused an API timeout, a healthy Kubernetes Pod with a broken Service selector, and Nginx 502s where the API itself was still healthy.”
