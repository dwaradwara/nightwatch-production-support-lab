# INC-020 Evidence Index — Redis Readiness Degradation

This evidence index records what was retained from the Redis readiness exercise and what should **not** be overstated.

## Retained visual evidence

| Evidence file | What it supports | Strength |
|---|---|---|
| `01-initial-script-validation-failed.png` | The first Redis readiness exercise runner was executed, but the validation failed with `Redis health after outage expected HTTP 503 but got 0`. | Debugging evidence only |

## Correct interpretation

The retained screenshot does **not** prove a completed Redis outage scenario. It proves that the initial automation/test harness failed while validating the expected Redis readiness behavior.

That failure is still useful because it shows an engineering-support reality: sometimes the investigation exposes a problem in the validation script or test environment before the actual service behavior can be trusted.

## Do not claim from this screenshot

- Do not claim this screenshot proves Redis was successfully isolated as the final root cause.
- Do not claim this screenshot proves `/health/ready` returned HTTP 503 because of Redis.
- Do not claim this screenshot proves ticket-read traffic stayed healthy during Redis outage.

## Acceptable claim

This screenshot can support the statement:

> The initial Redis readiness exercise exposed a validation issue in the incident automation, where the runner expected HTTP 503 but received status `0`; the exercise required correction before final behavior could be relied on.

## Evidence boundary

The retained screenshot was captured from the local NIGHTWATCH training environment on 2026-08-19. It is debugging evidence for a simulated lab exercise, not final proof of completed production-style incident recovery.
