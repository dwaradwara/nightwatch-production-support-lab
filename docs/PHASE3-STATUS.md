# OPSFORGE Phase 3 Status

Phase 3 is complete and CI-validated on August 17, 2026.

## Validation evidence

GitHub Actions run #44 (`32048533432`) completed successfully with the `validate-delivery` job green end to end.

The validated release path was:

```text
versioned image build
    -> isolated staging deployment
    -> schema/customer/observability verification
    -> staging acceptance
    -> production deployment
    -> production post-deploy verification
    -> record last-good release
```

The accepted release in the validation run was:

```text
git-b980324068e6
```

## Rollback exercise

The same workflow built a controlled regression candidate:

```text
git-b980324068e6-regression
```

The candidate deliberately preserved GET-based readiness while rejecting the customer ticket-creation POST with HTTP 500.

Observed sequence:

1. PostgreSQL, Redis, RabbitMQ and API readiness remained healthy.
2. `/version` identified the regression candidate as running in production.
3. The schema compatibility gate passed.
4. Customer ticket creation returned HTTP 500.
5. Post-deploy verification rejected the candidate.
6. Promotion logic selected the recorded last-good production release `git-b980324068e6`.
7. Production was redeployed with the last-good release.
8. The complete release verification gate passed after rollback.
9. An additional independent production verification passed again.

Rollback history recorded:

```text
2026-08-17T17:07:48Z  production  git-b980324068e6-regression  git-b980324068e6
```

This evidence demonstrates the Phase 3 operating rule:

> A release is not healthy merely because its containers and readiness endpoints are healthy. Customer-path verification is required before production acceptance.

## Delivered capabilities

- Git-derived versioned application images
- OCI-style version/revision labels
- ignored local release manifests and deployment state under `.opsforge/`
- isolated staging and production Compose project/container/network/port identities
- schema compatibility gate
- reusable build, deploy, verify, promote, rollback and teardown scripts
- release identity verification through `/version`
- full Phase 2 customer journey as a post-deployment gate
- request correlation across logs and Tempo during release verification
- worker/RabbitMQ and synthetic-customer health verification
- Prometheus and Grafana validation during release acceptance
- recorded last-good production release
- automatic rollback after a rejected production candidate
- mandatory full verification after rollback

## Explicit boundaries

Phase 3 intentionally does not claim more than it implements:

- versioned images are local to the simulation; they are not yet published to a commercial image registry
- `db/schema-contract.sql` is a deployment compatibility gate, not a complete migration framework
- `.opsforge/` models local deployment state and is not a distributed deployment database
- the rejected release is controlled regression testing, not a real commercial production outage

Operational design and commands are documented in `docs/DELIVERY-PIPELINE.md`.
