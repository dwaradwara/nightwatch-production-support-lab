# INC-016 — TLS Certificate Hostname Mismatch

**Project:** NIGHTWATCH Production Support Lab  
**Environment:** Docker Compose / Nginx / HTTPS / Python API  
**Severity:** SEV2 — simulated customer-facing HTTPS access failure  
**Status:** Resolved  
**Type:** TLS / Certificate Validation / Reverse Proxy

## Customer Report

Customers report that the NIGHTWATCH HTTPS endpoint cannot establish a secure connection when using the expected service hostname.

## Impact

The HTTPS endpoint was reachable, but certificate validation failed for the hostname used by the client.

- Customer hostname: `nightwatch.local`
- HTTPS endpoint: `https://nightwatch.local:8443/health`
- Expected: successful TLS validation and HTTP 200
- Actual during incident: TLS certificate hostname mismatch
- Backend API remained healthy.

## Healthy TLS Baseline

A certificate was first generated for:

`wrong-host.local`

Certificate details:

- Common Name: `wrong-host.local`
- Subject Alternative Name: `DNS:wrong-host.local`

The certificate was explicitly trusted by curl and the matching hostname was resolved locally to `127.0.0.1`.

Request:

`curl.exe --cacert .\tls\nightwatch.crt --resolve wrong-host.local:8443:127.0.0.1 -i https://wrong-host.local:8443/health`

Result:

`HTTP/1.1 200 OK`

Response:

`{"service":"nightwatch-api","status":"healthy"}`

This proved that:

- the certificate could be trusted,
- the TLS listener was working,
- Nginx HTTPS was healthy,
- the backend API was reachable.

## Incident Reproduction

The same trusted certificate was then used while requesting a different hostname:

`nightwatch.local`

Command:

`curl.exe --cacert .\tls\nightwatch.crt --resolve nightwatch.local:8443:127.0.0.1 -v https://nightwatch.local:8443/health`

Result:

TLS validation failed.

Relevant curl output:

`connection hostname (nightwatch.local) did not match against certificate name (wrong-host.local)`

and:

`curl: (60) ... failed to match connection hostname`

## Investigation

### 1. Confirmed Network Reachability

The client successfully reached:

`127.0.0.1:8443`

This ruled out a basic TCP connectivity failure.

### 2. Confirmed Certificate Trust

The certificate was explicitly supplied using:

`--cacert .\tls\nightwatch.crt`

The same certificate successfully validated when the request used its matching hostname:

`wrong-host.local`

This ruled out an untrusted-certificate problem.

### 3. Compared Requested Hostname With Certificate Identity

Requested hostname:

`nightwatch.local`

Certificate CN/SAN:

`wrong-host.local`

The hostname used by the client was not present in the certificate Subject Alternative Name.

### 4. Confirmed Backend Health

The same Nginx and backend path returned HTTP 200 when certificate hostname validation succeeded.

This isolated the failure to the TLS certificate hostname-validation layer rather than the application.

## Root Cause

The Nginx HTTPS listener was presenting a certificate issued for:

`wrong-host.local`

while customers were connecting using:

`nightwatch.local`

Because `nightwatch.local` was not present in the certificate SAN, the TLS client correctly rejected the connection.

## Resolution

Generated a replacement certificate with:

- Common Name: `nightwatch.local`
- Subject Alternative Name: `DNS:nightwatch.local`

Nginx was updated to use:

`/etc/nginx/tls/nightwatch-fixed.crt`

and:

`/etc/nginx/tls/nightwatch-fixed.key`

The corrected Nginx configuration was validated before deployment using `nginx -t`.

## Recovery Validation

After deploying the corrected certificate:

`curl.exe --cacert .\tls\nightwatch-fixed.crt --resolve nightwatch.local:8443:127.0.0.1 -i https://nightwatch.local:8443/health`

Result:

`HTTP/1.1 200 OK`

Response:

`{"service":"nightwatch-api","status":"healthy"}`

The HTTPS customer path was fully restored.

## Layer Isolation

| Layer | Result |
|---|---|
| TCP reachability to 8443 | Healthy |
| Nginx HTTPS listener | Healthy |
| Certificate trust | Healthy |
| Backend API | Healthy |
| TLS hostname validation | Failed |
| Corrected certificate hostname | Healthy |
| Final customer request | HTTP 200 |

## Customer Update — Investigation

We reproduced the HTTPS connection failure and confirmed that the service itself remained reachable. The issue was narrowed to TLS certificate validation rather than application availability or network connectivity.

## Customer Update — Root Cause Identified

The certificate presented by the service was valid for a different hostname than the one customers were using. The connection was therefore being rejected during hostname verification.

## Customer Update — Resolved

A replacement certificate matching the customer-facing hostname was deployed and validated. HTTPS requests are now completing successfully and returning HTTP 200.

## Preventive Actions

- Ensure all customer-facing hostnames are present in certificate SAN entries.
- Validate certificate CN/SAN before deployment.
- Add automated TLS hostname-verification checks.
- Monitor certificate expiry and certificate identity.
- Validate HTTPS endpoints using the real customer hostname after certificate changes.
- Keep certificate trust failures and hostname mismatch failures separate during troubleshooting.
- Run `nginx -t` before applying TLS configuration changes.

## Support Skills Demonstrated

- TLS / HTTPS troubleshooting
- Certificate CN and SAN validation
- Certificate trust vs hostname verification
- curl verbose TLS diagnostics
- Nginx HTTPS configuration
- Docker port and volume configuration
- Layer-by-layer fault isolation
- Root cause analysis
- Recovery validation
- Customer-facing incident communication

> This incident was intentionally reproduced in a self-built training environment. It is portfolio evidence and not employer production experience.
