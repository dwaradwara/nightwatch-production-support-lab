# INC-015 — DNS / Service-Resolution Failure

**Project:** NIGHTWATCH Production Support Lab  
**Environment:** Docker Compose / Nginx / Python API  
**Severity:** SEV2 — simulated customer-facing service outage  
**Status:** Resolved  
**Type:** DNS / Service Discovery / Reverse Proxy

## Customer Report

Customers report that the NIGHTWATCH API is unavailable. Requests that normally succeed are returning HTTP 502 Bad Gateway.

## Impact

Requests through the normal customer-facing Nginx endpoint failed.

- Customer path: `http://localhost:8080/health`
- Expected: HTTP 200
- Actual during incident: HTTP 502 Bad Gateway
- Direct backend API remained healthy.

## Healthy Baseline

Before introducing the incident:

`curl.exe -i http://localhost:8080/health`

Result:

`HTTP/1.1 200 OK`

Response:

`{"service":"nightwatch-api","status":"healthy"}`

This confirmed the full path was healthy before the failure:

Client ? Nginx ? API

## Incident Trigger

The Nginx upstream service hostname was changed from the valid Docker service name:

`nightwatch-api`

to the invalid hostname:

`nightwatch-api-broken`

Docker's internal DNS resolver `127.0.0.11` was used for runtime name resolution.

## Investigation

### 1. Reproduced the customer problem

Request:

`curl.exe -i http://localhost:8080/health`

Result:

`HTTP/1.1 502 Bad Gateway`

The issue was confirmed from the customer-facing endpoint.

### 2. Checked Nginx logs

Command:

`docker logs nightwatch-nginx --tail 20`

Relevant error:

`nightwatch-api-broken could not be resolved (3: Host not found)`

The corresponding `/health` request returned HTTP 502.

This shifted the investigation toward upstream name resolution rather than an application failure.

### 3. Tested the backend directly

Request:

`curl.exe -i http://localhost:8000/health`

Result:

`HTTP/1.1 200 OK`

Response:

`{"service":"nightwatch-api","status":"healthy"}`

This proved that the application itself was still running and healthy.

### 4. Verified Docker service-name resolution

Valid service:

`docker exec nightwatch-nginx getent hosts nightwatch-api`

Result:

`172.22.0.8 nightwatch-api nightwatch-api`

Invalid service:

`docker exec nightwatch-nginx getent hosts nightwatch-api-broken`

Result:

No DNS result.

This confirmed the failure was isolated to service discovery / DNS resolution.

## Root Cause

Nginx was configured with an invalid Docker upstream hostname:

`nightwatch-api-broken`

Because the hostname did not exist in Docker's internal DNS, Nginx could not resolve the backend service and returned HTTP 502 to clients.

The backend API itself remained healthy throughout the incident.

## Resolution

Restored the correct Nginx upstream configuration using:

`nightwatch-api:8000`

Then rebuilt and recreated the Nginx service.

## Recovery Validation

After restoration:

`curl.exe -i http://localhost:8080/health`

Result:

`HTTP/1.1 200 OK`

Response:

`{"service":"nightwatch-api","status":"healthy"}`

Customer traffic was successfully restored.

## Layer Isolation

| Layer | Result |
|---|---|
| Client ? Nginx | Healthy |
| Nginx process | Healthy |
| Backend API | Healthy |
| Valid Docker service DNS | Healthy |
| Invalid upstream DNS | Failed |
| Customer request during incident | HTTP 502 |
| Customer request after recovery | HTTP 200 |

## Customer Update — Investigation

We reproduced the API availability issue and confirmed requests through the external service path were returning HTTP 502. The backend application remained healthy, and investigation was narrowed to communication between the reverse proxy and upstream service.

## Customer Update — Root Cause Identified

The issue was isolated to an upstream service-name resolution failure in the proxy configuration. The application itself remained operational. We are restoring the correct service configuration and validating traffic.

## Customer Update — Resolved

The upstream service configuration has been corrected and end-to-end validation is complete. Requests are again returning HTTP 200 successfully.

## Preventive Actions

- Validate upstream hostnames before deployment.
- Run `nginx -t` as part of configuration validation.
- Add automated end-to-end health checks through the customer-facing proxy.
- Monitor Nginx 5xx responses and DNS/upstream-resolution errors.
- Include configuration-diff review before proxy changes.
- Keep direct backend health checks available to distinguish application failures from proxy/network failures.

## Support Skills Demonstrated

- HTTP 502 troubleshooting
- Nginx reverse-proxy diagnostics
- Docker networking
- Docker internal DNS / service discovery
- Runtime configuration verification
- Log analysis
- Layer-by-layer fault isolation
- Direct backend health testing
- Root cause analysis
- Recovery validation
- Customer-facing incident communication

> This incident was intentionally reproduced in a self-built training environment. It is portfolio evidence and not employer production experience.
