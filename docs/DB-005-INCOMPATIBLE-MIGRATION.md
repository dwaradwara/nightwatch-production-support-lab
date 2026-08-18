# OPSFORGE DB-005 — PostgreSQL Incompatible Migration

DB-005 trains diagnosis of an application/schema version mismatch after a database change. PostgreSQL remains reachable and the API readiness endpoint remains green, but the real ticket customer path fails because the running application and the migrated schema no longer agree on a required column name.

> This is a simulated production-support exercise, not a commercial production incident.

## Scenario

The currently deployed NIGHTWATCH API expects the `tickets.processing_status` column. The DB-005 forward migration is syntactically valid and commits successfully, but renames that column to `tickets.job_state` without deploying a compatible application release.

Expected incident state:

- PostgreSQL process is healthy.
- Redis and RabbitMQ remain healthy.
- `/health/ready` returns HTTP 200 because dependency connectivity succeeds.
- `/api/tickets` returns HTTP 500 because the running SQL still references `processing_status`.
- `db/schema-contract.sql` fails because the required application column is missing.
- ticket data remains unchanged because the migration is metadata-only.

This deliberately demonstrates why green readiness does not prove application/schema compatibility.

## Migration under test

Forward migration:

`db/incidents/db005-forward.sql`

It performs:

`ALTER TABLE tickets RENAME COLUMN processing_status TO job_state;`

Rollback migration:

`db/incidents/db005-rollback.sql`

It performs the exact reverse rename after the exercise proves that no ticket data changed.

Both scripts contain state guards so they refuse to overwrite an unexpected column state.

## Required diagnosis

Before recovery L2 must prove:

1. The customer path is actually failing.
2. API readiness is still healthy.
3. PostgreSQL is reachable independently.
4. The deployed API expects `processing_status`.
5. The current database exposes `job_state` instead.
6. `schema-contract.sql` fails on the missing application column.
7. API logs show the same database contract failure.
8. Ticket row count is unchanged.
9. A deterministic ticket-data fingerprint is unchanged when the renamed column is interpreted as the same value.
10. The reverse migration is therefore safe for this exercise.

## Automated exercise

Run:

```bash
bash scripts/db_incident_005.sh exercise
```

The controller performs:

1. baseline schema/customer/data validation;
2. forward incompatible migration;
3. green-readiness / broken-customer-path proof;
4. schema-contract and API-log diagnosis;
5. data-integrity comparison;
6. approved reverse migration;
7. post-recovery schema, customer-path, readiness, and data-integrity verification.

Evidence is written to:

`.opsforge/evidence/db-005/`

## Why rollback is valid here

The exercise uses a column rename only. No rows are deleted, inserted, transformed, or reinterpreted. Before rollback the controller requires the current ticket count and fingerprint to match the baseline.

If either comparison differs, rollback is refused.

That is an important operating boundary: **a migration being the cause does not automatically make reverse SQL the correct recovery**.

## When L2 must not auto-rollback

Stop and escalate when the change includes any of the following:

- dropped columns or tables;
- irreversible type conversions;
- transformed/backfilled values with new semantics;
- concurrent old/new application versions requiring different schemas;
- migration side effects outside the captured transaction;
- replication or backup/restore implications;
- unknown data drift after the change;
- a required roll-forward application release.

In those cases the correct outcome may be DBA/development escalation, a compensating migration, application roll-forward, or restore—not a blind reverse migration.

## Recovery success criteria

DB-005 is resolved only when:

- `processing_status` exists again and `job_state` does not;
- `db/schema-contract.sql` passes;
- `/health/ready` returns HTTP 200;
- `/api/tickets` returns HTTP 200;
- PostgreSQL remains reachable;
- ticket row count matches baseline;
- ticket fingerprint matches baseline.

A successful DDL command by itself is not recovery evidence.
