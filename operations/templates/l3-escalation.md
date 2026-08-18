# L2 → L3 / Development Escalation Template

Escalation is a correct L2 outcome when the fault is outside the approved operational boundary.

## Required package

- Linked incident ID and severity
- Customer/business impact
- First observed timestamp
- Affected environment and version
- Exact reproduction steps
- Request/correlation IDs
- Relevant logs/metrics/traces
- Recent change/deployment correlation
- Troubleshooting already performed
- Hypotheses rejected and why
- Suspected component/code path
- Mitigation/rollback attempted and outcome
- Why no safe L2 fix remains
- Specific requested action from L3/development

A weak escalation says: "API is broken."

A strong escalation says what fails, when it started, who is affected, what version is involved, what evidence isolates the fault, what L2 already tested, and what specialist action is required.
