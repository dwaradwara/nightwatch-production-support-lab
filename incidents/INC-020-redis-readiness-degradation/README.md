# INC-020 — Redis Readiness Degradation

## Summary

A controlled Redis outage was introduced to validate how NIGHTWATCH behaves when a non-primary dependency becomes unavailable.

The outage caused application readiness checks to fail with HTTP 503 while normal ticket-read traffic continued returning HTTP 200. This demonstrated partial service degradation rather than a complete application outage.

## Impact

- `/health/ready` returned HTTP 503.
- Readiness requests experienced approximately 15–17 seconds of latency while Redis connectivity attempts timed out.
- Ticket-read endpoints continued serving HTTP 200.
- PostgreSQL-backed application data remained available.
- The application process itself remained operational.

## Baseline

Before the incident:

- PostgreSQL: healthy
- RabbitMQ: healthy
- Redis: healthy
- `/health/ready`: HTTP 200
- Application status: `ready`

## Failure Injection

Redis was intentionally stopped:

```text
docker stop nightwatch-redis
```

## Observed Symptoms

During the outage:

```text
GET /health/ready HTTP/1.1 503
```

Repeated readiness checks returned HTTP 503 with response times of approximately 15–17 seconds.

At the same time, normal ticket traffic remained functional:

```text
GET /api/tickets/<id> HTTP/1.1 200
```

This confirmed that Redis failure degraded dependency readiness without causing full loss of the ticket-read path.

## Investigation

### 1. Verified application availability

The API continued responding to business requests. This ruled out a total API or Nginx outage.

### 2. Verified readiness failure

`/health/ready` consistently returned HTTP 503. The readiness check correctly detected that one required dependency was unavailable.

### 3. Isolated Redis

PostgreSQL-backed ticket reads continued returning HTTP 200 while readiness failed. This indicated that Redis was not required for the tested read path but was included in readiness dependency validation.

### 4. Identified timeout behavior

Readiness requests took approximately 15–17 seconds during the Redis outage. This showed that Redis connection failure was not failing fast and introduced additional readiness latency.

## Root Cause

Redis was intentionally unavailable. The application readiness endpoint treats Redis as a required dependency, so readiness transitioned to HTTP 503 when Redis could not be reached.

The tested ticket-read path remained available because it did not require Redis to return the requested PostgreSQL-backed data.

## Resolution

Redis was restarted:

```text
docker start nightwatch-redis
```

After Redis connectivity was restored:

- `/health/ready` returned HTTP 200.
- Ticket-read endpoints continued returning HTTP 200.
- Readiness latency returned to normal levels.

## Preventive Actions

- Alert separately on Redis dependency failures and application readiness failures.
- Use shorter Redis connection and health-check timeouts where appropriate.
- Distinguish liveness, readiness, and business-endpoint availability in monitoring.
- Document which application paths require Redis and which can operate without it.
- Re-evaluate whether Redis should be treated as a hard readiness dependency for all workloads.
- Monitor readiness latency in addition to readiness status.
- Add degraded-mode dashboards showing dependency health alongside business endpoint success rates.

## Support Skills Demonstrated

- Redis dependency troubleshooting
- HTTP 503 analysis
- Readiness vs application availability analysis
- Partial-service degradation diagnosis
- Dependency isolation
- Timeout analysis
- Recovery validation
- Production-style incident reasoning

> This incident was intentionally reproduced in a self-built training environment. It is portfolio evidence and not employer production experience.
