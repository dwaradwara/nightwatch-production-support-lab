# L1 → L2 Escalation Template

L1 should provide enough evidence for L2 to establish scope before troubleshooting.

## Required information

- Linked incident ID
- Customer/account identifier when available
- Exact symptom in customer language
- First observed timestamp and timezone
- Affected feature / endpoint
- One customer or multiple customers
- Reproducibility
- HTTP status / application error / screenshot text
- Request or correlation ID when available
- Basic checks already performed
- Recent customer-side change if relevant
- Known workaround

## L2 disposition

Choose one:

- `accepted_for_investigation`
- `needs_clarification`
- `redirected_service_request`
- `duplicate_existing_incident`

When clarification is required, list the exact missing information rather than returning the ticket with a generic request for more details.
