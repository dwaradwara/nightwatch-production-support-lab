# OPSFORGE Customer Journey Contract

Phase 2 defines the first customer-facing transaction that OPSFORGE treats as a business-health signal.

The purpose is simple: healthy containers do not prove that a customer can use the service. The critical journey must complete across the synchronous API path and the asynchronous worker path.

## Simulated customer identity

Customer-specific API operations use:

```text
X-Customer-ID: <customer-id>
```

This is deliberately **identification, not authentication**. It exists to model customer ownership and customer-scoped reads/updates without pretending that the lab contains a production identity provider or authorization system.

A missing or invalid `X-Customer-ID` causes customer-specific operations to return HTTP 400.

## Critical customer transaction

```text
identified customer
      |
      v
POST /api/tickets
      |
      v
PostgreSQL: ticket persisted as Open / queued
      |
      v
RabbitMQ: durable ticket.created event
      |
      v
worker consumes event
      |
      v
PostgreSQL: ticket.processed event + processing_status=processed
      |
      v
GET /api/tickets/:id confirms async outcome
      |
      v
PATCH /api/tickets/:id -> Resolved
      |
      v
PostgreSQL: ticket.status_updated event
      |
      v
GET /api/tickets/:id confirms final customer-visible state
```

The transaction is considered successful only when the same identified customer can create, read, asynchronously process, update, and read back the final ticket state.

## Ticket state model

Business status and background-processing status are intentionally separate.

### Business status

Supported values:

- `Open`
- `Investigating`
- `Resolved`

This represents the customer-visible/support lifecycle.

### Processing status

Important values:

- `queued` — ticket persistence succeeded and the API is attempting/has completed queue publication
- `processed` — worker consumed the event and committed the processing outcome to PostgreSQL
- `publish_failed` — ticket persistence succeeded but RabbitMQ publication failed
- `seeded` — repository seed data; not a live customer transaction

Separating these states matters. A ticket can exist in PostgreSQL while its asynchronous workflow is broken.

## Persistent event evidence

OPSFORGE currently records these event types:

### `ticket.created`

Transport event published by the API to RabbitMQ. The message contains:

- event ID
- ticket ID
- simulated customer ID
- edge request ID
- event timestamp

### `ticket.processed`

Persistent event written by the worker after consuming `ticket.created`.

The worker only acknowledges the RabbitMQ message after the database transaction succeeds. Its event insertion is keyed by the original event ID and uses conflict handling so redelivery does not create duplicate processing records.

### `ticket.status_updated`

Persistent event written by the API when the identified customer changes the support status, for example from `Open` to `Resolved`.

## Correlation contract

Nginx owns the canonical edge request ID.

For the create operation, the correlation path is:

```text
HTTP X-Request-ID
      |
      v
Nginx structured log
      |
      v
API structured log
      |
      +----> Tempo API span attribute: nightwatch.request_id
      |
      v
RabbitMQ message header: x-request-id
      |
      v
worker structured log
```

CI requires the same create-request ID to exist in Nginx, API, and worker logs and to be searchable in Tempo for the API request.

The worker is not yet independently OpenTelemetry-instrumented, so the asynchronous boundary is correlated through message metadata and structured logs rather than a distributed worker span. That limitation is explicit.

## Synthetic customer

The `nightwatch-synthetic` service continuously runs the full identified-customer journey:

1. create a SEV4 ticket
2. verify returned customer ownership
3. poll the customer-scoped ticket until background processing reaches `processed`
4. require a persisted `ticket.processed` event
5. update the ticket to `Resolved`
6. read it again
7. require the final status and `ticket.status_updated` event

Synthetic metrics include:

```text
nightwatch_synthetic_customer_path_up
nightwatch_synthetic_journeys_total
nightwatch_synthetic_journey_duration_seconds
nightwatch_synthetic_last_success_timestamp_seconds
```

Normal expectation for the latest customer-path signal:

```text
nightwatch_synthetic_customer_path_up = 1
```

## Operational interpretation

A green infrastructure health check and a red synthetic customer signal is a service incident, not a healthy system.

Examples:

- API readiness `200`, worker healthy, synthetic path `0`: investigate the business transaction rather than restarting healthy infrastructure blindly.
- ticket `publish_failed`: PostgreSQL create succeeded but RabbitMQ publication failed; investigate API-to-RabbitMQ connectivity, credentials, queue availability, or broker behavior.
- ticket remains `queued`: publication may have succeeded but processing did not complete; inspect RabbitMQ consumer count, queue depth, worker logs, worker DB connectivity, and processing metrics.
- `processed` succeeds but PATCH/read fails: asynchronous processing is healthy; focus on the customer-facing API/update path and database operation evidence.
- customer receives 404 for another customer's ticket: expected customer-scoping behavior, not data loss.

## Known reliability boundary

Ticket persistence and RabbitMQ publication are not atomic.

The API currently:

1. commits the ticket as `queued`
2. publishes the RabbitMQ event
3. changes the ticket to `publish_failed` when publication fails

There is no transactional outbox, automatic retry scheduler, or reconciliation worker yet.

That is a deliberate visible limitation. OPSFORGE will use it later for delivery/reliability and incident exercises rather than claiming exactly-once delivery or hiding the failure mode.

## Browser contract

Nginx CORS configuration currently permits the simulated browser origin to use:

```text
GET, POST, PATCH, OPTIONS
```

and request headers:

```text
Authorization, Content-Type, X-Customer-ID
```

CI validates the corresponding browser preflight before validating the customer transaction.

## Phase 2 exit criteria

Phase 2 is complete only when CI proves in one running environment that:

- PostgreSQL, Redis, and RabbitMQ readiness is green
- browser preflight supports the customer workflow
- an identified customer can create a ticket through Nginx
- the ticket is persisted with correct customer ownership
- the API publishes the background event
- RabbitMQ has an active worker consumer
- the worker processes the event and commits the outcome
- the identified customer can read the processed ticket
- the identified customer can update it to `Resolved`
- the final read contains the persisted update event
- the create request ID is correlated across Nginx, API, worker logs, and Tempo
- Prometheus receives API, worker, RabbitMQ, and synthetic business telemetry
- the continuous synthetic customer path reports success
- the Phase 1 baseline observability gates remain green

A passing container build alone does not satisfy this phase.
