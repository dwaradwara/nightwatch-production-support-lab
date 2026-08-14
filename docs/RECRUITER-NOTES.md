# Recruiter Notes

## 30-second project summary

NIGHTWATCH is a self-built production-support troubleshooting lab built around a containerized Python service stack. Instead of demonstrating tools in isolation, it starts with a customer-facing symptom, establishes a healthy baseline, isolates the failing layer using logs, metrics, traces, direct health checks, and dependency-specific evidence, applies a targeted fix, and verifies recovery through the original path.

The environment covers Nginx, Flask, PostgreSQL, Redis, RabbitMQ, Docker networking, Kubernetes, Prometheus/Grafana, Loki/Alloy, OpenTelemetry/Tempo, TLS, browser CORS behavior, and GitHub Actions.

## What to look at first

1. **Main README** — current architecture, selected incidents, observability stack, and PostgreSQL reliability improvement.
2. **Incident Casebook** — broader troubleshooting examples and RCAs.
3. **INC-015** — Nginx 502 caused by Docker DNS / service-resolution failure while the backend remained healthy.
4. **INC-016** — TLS certificate hostname mismatch isolated from certificate trust.
5. **INC-017** — API healthy in curl but browser blocked by CORS preflight; reproduced in Chrome DevTools and fixed in Nginx.
6. **GitHub Actions** — automated Python validation and API/worker Docker builds.

## Strongest examples

- Diagnosed an Nginx `502` by proving the backend returned HTTP 200 directly, then tracing the customer-facing failure to an invalid Docker service hostname in the proxy configuration.
- Reproduced a TLS hostname mismatch with a trusted certificate, inspected CN/SAN behavior, replaced the certificate with the correct SAN, validated Nginx configuration, and restored HTTPS.
- Reproduced a browser-only CORS failure where curl returned HTTP 200 but Chrome blocked the request. Used OPTIONS preflight requests and Chrome DevTools to identify missing CORS headers, then configured Nginx for the explicit frontend origin and verified browser recovery.
- Diagnosed an unexpected `/api/tickets` HTTP 500 from application logs as `psycopg.errors.UndefinedTable`, confirmed the PostgreSQL instance had no application tables, identified missing persistent storage as the reason container recreation removed database state, then added a named volume plus repeatable schema initialization and seed data.
- Used PostgreSQL `pg_stat_activity` to identify a blocking session causing API timeouts and terminated only the blocker rather than restarting the database.
- Distinguished RabbitMQ backlog states using `messages_ready`, `messages_unacknowledged`, and consumer counts.
- Diagnosed a Kubernetes Service with a healthy Pod but no backend EndpointSlice because the Service selector did not match Pod labels.
- Correlated service health through Prometheus/Grafana metrics, centralized Loki logs, and OpenTelemetry/Tempo traces.

## Scope

This is a self-built lab, not a claim of commercial production ownership. Its purpose is to demonstrate practical troubleshooting habits, layered diagnosis, evidence collection, safe recovery choices, technical documentation, and customer-facing incident communication relevant to L2 Technical Support, Application Support, Product Support, Production Support, and junior SRE/NOC-adjacent roles.

## Resume-ready wording

**NIGHTWATCH — Production Support Engineering Lab**

- Built a Docker-based support environment spanning Nginx, Flask, PostgreSQL, RabbitMQ, Redis, Prometheus/Grafana, Loki/Alloy, OpenTelemetry/Tempo, Kubernetes and GitHub Actions.
- Reproduced and diagnosed failures across HTTP `500/502`, Docker networking and service discovery, PostgreSQL schema/persistence and lock contention, queue backlogs, TLS hostname validation, browser CORS preflight, and Kubernetes service routing.
- Used direct health checks, application/proxy logs, Chrome DevTools, `pg_stat_activity`, RabbitMQ queue counters, Prometheus metrics, distributed traces and Kubernetes EndpointSlices to isolate root causes before applying targeted recovery actions.
- Added persistent PostgreSQL storage and repeatable schema initialization, validated Nginx/TLS/CORS changes before deployment, and documented incident evidence, RCA, recovery steps and customer updates.

## Interview explanation

A concise explanation:

> “I built NIGHTWATCH because I wanted support practice that starts with a symptom instead of a tutorial instruction. I deliberately break one layer, test the customer-facing path, establish what is still healthy, use logs, metrics, traces or dependency-specific evidence to narrow the fault, fix only the failing layer, and then verify recovery through the original path. Recent examples include an Nginx 502 caused by Docker DNS, a TLS hostname mismatch, and a browser CORS failure where the API worked in curl but Chrome rejected the preflight response. During one baseline check I also found that recreating PostgreSQL had wiped the schema because the service had no persistent volume, so I added persistent storage and repeatable initialization rather than applying a one-off database fix.”
