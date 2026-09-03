# INC-018 Evidence Index — RabbitMQ Publish Failure

This evidence index maps the retained screenshots from the RabbitMQ publish-failure exercise to the specific claims made in the incident report.

## Selected visual evidence

| Evidence file | What it supports | Strength |
|---|---|---|
| `01-rabbitmq-stopped-queue-health-503.png` | RabbitMQ was intentionally stopped and the queue-health endpoint returned HTTP 503 with RabbitMQ marked unhealthy. | Strong |
| `02-api-partial-success-publish-failed.png` | A ticket-create request returned `ServiceUnavailable` while the application reported `ticket created but background processing could not be queued`, `processing_status = publish_failed`, and `ticket_id = 4`. | Strong |
| `03-db-persisted-ticket-and-recovery.png` | PostgreSQL confirmed ticket `id = 4` existed with `processing_status = publish_failed`; RabbitMQ was restarted; readiness returned HTTP 200 with PostgreSQL, RabbitMQ, and Redis healthy. | Very strong |

## Claims supported by the evidence

- The failure was isolated to RabbitMQ rather than PostgreSQL or Redis.
- The database write succeeded even though the client-visible request returned a 503 response.
- The application retained the affected ticket with an explicit failed-processing state instead of silently losing it.
- Recovery was validated by restarting RabbitMQ and confirming full readiness returned to HTTP 200.

## Evidence boundary

These screenshots were captured from the local NIGHTWATCH training environment on 2026-08-19. They are portfolio evidence for a simulated lab incident, not proof of employer production incident ownership.
