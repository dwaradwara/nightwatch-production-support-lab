# Runbook Template

A runbook describes an approved operational response, not a substitute for diagnosis.

## Required sections

- Runbook ID and title
- Trigger / symptom pattern
- Preconditions
- Evidence to collect before action
- Diagnostic steps
- Approved mitigation steps
- Explicit actions that are out of scope
- Expected telemetry during recovery
- Customer-path validation steps
- Observation period
- Escalation boundary
- Related incidents/problems/changes

## Rule

Do not execute a runbook because one keyword matches. Confirm the preconditions and fault domain first. If evidence contradicts the runbook assumptions, stop and investigate or escalate.
