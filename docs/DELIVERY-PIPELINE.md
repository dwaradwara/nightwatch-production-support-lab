# OPSFORGE Phase 3 — Delivery Pipeline

Phase 3 models safe application change delivery rather than treating a successful image build as a successful production release.

## Release flow

```text
branch / pull request
        |
        v
static validation
        |
        v
versioned container images
        |
        v
STAGING deployment
        |
        v
schema compatibility + customer journey + observability verification
        |
        v
staging acceptance
        |
        v
PRODUCTION deployment
        |
        v
post-deploy verification
        |
   +----+----+
   |         |
 success   failure
   |         |
   v         v
record     rollback to
last-good  last-good
```

A release is not considered successful because Docker Compose returned successfully. It must pass the customer-facing transaction introduced in Phase 2.

## Release identity

CI derives a release version from the Git commit SHA, for example:

```text
git-0123456789ab
```

The four application-owned images use the same release version:

```text
nightwatch-api:<version>
nightwatch-worker:<version>
nightwatch-nginx:<version>
nightwatch-synthetic:<version>
```

The build script also adds OCI-style revision/version labels and writes a local release manifest under `.opsforge/releases/`.

Mutable deployment state is deliberately not committed to Git.

## Environment separation

The same Compose definition is parameterized into two logical runtime environments.

### Staging

- Compose project: `opsforge-staging`
- container prefix: `nightwatch-staging`
- network: `nightwatch-staging-net`
- public HTTP port: `18080`
- API metadata: `environment=staging`

### Production

- Compose project: `opsforge-production`
- container prefix: `nightwatch-production`
- network: `nightwatch-production-net`
- public HTTP port: `8080`
- API metadata: `environment=production`

Host ports for API diagnostics, RabbitMQ management, Prometheus, Loki, Tempo, and Grafana are also separated so the environments can be represented independently on one Docker host.

Service DNS aliases such as `nightwatch-api` remain stable inside each isolated network. This preserves application configuration while allowing environment-specific containers and networks.

## Deployment scripts

### Build

```bash
bash scripts/build_release.sh <version>
```

Controlled rollback drill image:

```bash
bash scripts/build_release.sh <version> ticket-create-500
```

The fault mode is a training hook. It produces an Nginx image that continues to pass GET-based liveness/readiness traffic but rejects POST requests with HTTP 500. It is never enabled by a normal release build.

### Deploy

```bash
bash scripts/deploy_release.sh staging <version>
bash scripts/deploy_release.sh production <version>
```

Deployment selects already-built versioned images and does not rebuild them.

### Verify

```bash
bash scripts/verify_release.sh staging <version>
bash scripts/verify_release.sh production <version>
```

The verification gate checks:

- PostgreSQL, Redis, and RabbitMQ readiness
- `/version` environment and release identity
- database schema compatibility
- browser CORS contract
- ticket create -> async worker processing -> read -> update -> final read
- Nginx/API/worker request-ID correlation
- Tempo correlation for the originating API request
- worker consumer registration
- synthetic customer success in Prometheus
- application version telemetry in Prometheus
- Grafana health and provisioned Prometheus/Loki/Tempo data sources

### Promote

```bash
bash scripts/promote_release.sh production <version>
```

Promotion records a release as current only after post-deploy verification succeeds.

Local runtime state is stored under:

```text
.opsforge/state/
```

Important records include:

- `<environment>.current` — verified current release
- `<environment>.previous` — previous verified release
- `<environment>.candidate` — version currently being evaluated
- `rollback-history.tsv` — controlled rollback evidence

## Schema compatibility gate

`db/schema-contract.sql` performs zero-row queries against every table/column required by the current API and worker and verifies the required ticket-event index exists.

This is not a full migration framework. It is a deployment compatibility gate that prevents the pipeline from calling an environment healthy when the application schema contract is missing.

A true forward/backward migration strategy will be expanded in later database/change exercises.

## Rollback behavior

If a production candidate fails post-deploy verification and a current verified production version exists, `promote_release.sh` invokes:

```bash
bash scripts/rollback_release.sh production <last-good-version>
```

Rollback is not complete when old containers merely start. The restored release must pass the complete release verification gate again.

Only then is rollback recorded as successful.

## CI rollback drill

The CI pipeline performs two different activities.

### Normal promotion

1. build the Git-derived release
2. deploy it to staging
3. run the complete release verification gate
4. retire the staging test environment
5. deploy the same release tag to production
6. run post-deploy production verification
7. record it as the last-good production release

### Controlled failed deployment

1. build a second release tag with the `ticket-create-500` training fault
2. deploy it to production
3. readiness and version checks remain available
4. customer ticket creation returns HTTP 500
5. post-deploy verification rejects the candidate
6. promotion logic identifies the last-good release
7. production is redeployed with the last-good tag
8. the complete verification gate must pass again
9. rollback history must show bad candidate -> restored release

This demonstrates an important production-support rule:

> Infrastructure health does not prove a release is safe for customers.

## L2 interpretation

During a real release incident, an L2/Application Support engineer should be able to establish:

- what version is running
- what changed
- whether the failure began after deployment
- whether readiness is green while the customer journey is red
- whether the issue is isolated to one environment
- whether rollback is safer than continued diagnosis during customer impact
- which version is known good
- whether recovery is proven from the public customer path

The rollback drill exists to train that decision process, not merely to demonstrate a shell command.

## Explicit boundaries

- Images are versioned locally in the simulation; Phase 3 does not yet publish them to a commercial container registry.
- The schema contract is a compatibility gate, not a complete migration framework.
- Release state in `.opsforge/` simulates deployment state on one operator host; it is not a distributed deployment database.
- The controlled regression is intentional fault injection and must never be represented as a real production outage.

These boundaries keep the project accurate while preserving realistic deployment and rollback behavior.
