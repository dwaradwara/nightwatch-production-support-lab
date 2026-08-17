# OPSFORGE Phase 4 Status

Phase 4 is in implementation on branch `agent/opsforge-observability`.

Current scope under validation:

- PostgreSQL server metrics through `postgres_exporter`
- Redis metrics through `redis_exporter`
- RabbitMQ queue-level `/metrics/per-object` scraping
- Prometheus RED, database, queue and worker recording rules
- Prometheus detection rules for customer, API, dependency, database, queue and worker failures
- provisioned `OPSFORGE L2 Operations` Grafana dashboard
- centralized request-ID validation through Loki
- existing request-ID trace correlation through Tempo
- release-gate validation of targets, rules and dashboard provisioning

Phase 4 is not complete until the complete staging -> production -> rollback GitHub Actions workflow passes on the final branch head with the new observability checks enabled.
