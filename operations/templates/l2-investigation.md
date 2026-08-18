# L2 Investigation Notes Template

## Impact assessment

- What customer/business function is affected?
- How many customers or what scope is known?
- What still works?
- Confirm/adjust severity with evidence.

## Last-known-good and change context

- First observed timestamp
- Last known good timestamp
- Recent deployment/change/configuration event
- Affected version/environment

## Hypotheses

For every hypothesis record:

- hypothesis
- evidence supporting it
- evidence against it
- test performed
- result: `unverified | supported | rejected | confirmed`

## Actions

For every action record:

- exact action
- reason/evidence
- risk/blast radius
- expected signal if successful
- actual outcome

## Current assessment

State the most likely fault domain, current customer impact, mitigation state, and next decision. Do not write "fixed" until recovery is validated through the customer path.
