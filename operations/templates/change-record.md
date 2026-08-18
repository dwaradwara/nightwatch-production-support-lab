# Change Record Template

## Required fields

- Change ID: `CHG-####`
- Title and reason
- Linked incident/problem when applicable
- Affected services
- Risk and blast radius
- Implementation plan
- Validation plan
- Rollback plan
- Approval status
- Maintenance window when applicable
- Expected telemetry during/after change
- Actual result

## Rule

A change is not successful because deployment completed. It is successful only after customer-path and service-health validation pass. If validation fails, execute the documented rollback rather than improvising a new production fix.
