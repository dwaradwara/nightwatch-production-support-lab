# INC-017 — Browser CORS / Preflight Failure

**Project:** NIGHTWATCH Production Support Lab  
**Environment:** Docker Compose / Nginx / Flask API / PostgreSQL / Chrome DevTools  
**Severity:** SEV2 — simulated customer-facing browser integration failure  
**Status:** Resolved  
**Type:** CORS / Browser Security / Reverse Proxy

## Customer Report

A customer reports that the NIGHTWATCH API works when tested directly, but their browser-based application cannot load ticket data.

The frontend displays:

`REQUEST FAILED: TypeError: Failed to fetch`

## Impact

The API itself remained operational, but browser clients could not consume it from a different origin.

Affected flow:

`http://localhost:3001` ? `http://localhost:8080/api/tickets`

Direct API clients such as curl could retrieve data successfully, while the browser blocked the cross-origin request.

## Healthy API Baseline

Direct API request:

`curl.exe -i http://localhost:8080/api/tickets`

Result:

`HTTP/1.1 200 OK`

The API returned all three ticket records successfully.

This confirmed:

- Nginx was reachable.
- The API service was running.
- PostgreSQL connectivity was working.
- The `/api/tickets` route was operational.
- The failure was specific to browser-based access.

## Preflight Investigation

A browser-style CORS preflight request was simulated:

`OPTIONS /api/tickets`

Headers included:

- `Origin: http://localhost:3001`
- `Access-Control-Request-Method: GET`
- `Access-Control-Request-Headers: Authorization`

Initial response:

`HTTP/1.1 200 OK`

However, the response did not contain the required CORS headers:

- `Access-Control-Allow-Origin`
- `Access-Control-Allow-Methods`
- `Access-Control-Allow-Headers`

The server supported the OPTIONS method but had no valid CORS policy for the frontend origin.

## Browser Reproduction

A small frontend application was served from:

`http://localhost:3001`

The page attempted to fetch:

`http://localhost:8080/api/tickets`

with an `Authorization` header.

Chrome DevTools reported:

`Access to fetch at 'http://localhost:8080/api/tickets' from origin 'http://localhost:3001' has been blocked by CORS policy`

The browser also reported that no:

`Access-Control-Allow-Origin`

header was present.

The application displayed:

`REQUEST FAILED: TypeError: Failed to fetch`

## Investigation

### 1. Verified Backend API

Direct curl requests returned HTTP 200 and valid JSON.

Result:

`API healthy`

### 2. Verified Frontend Availability

The test frontend was served successfully on port 3001.

Result:

`Frontend healthy`

### 3. Tested Browser Preflight

The OPTIONS request reached Nginx and returned a response.

Result:

`Network path healthy`

### 4. Inspected CORS Response Headers

Required cross-origin headers were absent.

Result:

`CORS policy missing`

### 5. Reproduced Failure in Chrome

Chrome DevTools confirmed that the browser blocked the request before the frontend could access the API response.

Result:

`Browser security layer identified as failure point`

## Root Cause

Nginx did not return the CORS headers required for requests originating from:

`http://localhost:3001`

Although the API and OPTIONS endpoint were reachable, the browser rejected the request because the server did not explicitly allow the frontend origin, HTTP method, and Authorization header.

## Resolution

Nginx was configured to allow the specific frontend origin:

`http://localhost:3001`

The following CORS policy was added to both HTTP and HTTPS proxy locations:

- Allowed Origin: `http://localhost:3001`
- Allowed Methods: `GET, OPTIONS`
- Allowed Headers: `Authorization, Content-Type`
- Response variation: `Vary: Origin`

OPTIONS preflight requests were handled directly by Nginx with:

`HTTP 204 No Content`

The configuration was validated using:

`nginx -t`

before deployment.

## Preflight Recovery Validation

After the fix, the same OPTIONS request returned:

`HTTP/1.1 204 No Content`

with:

`Access-Control-Allow-Origin: http://localhost:3001`

`Access-Control-Allow-Methods: GET, OPTIONS`

`Access-Control-Allow-Headers: Authorization, Content-Type`

`Vary: Origin`

The preflight was now valid.

## Browser Recovery Validation

The frontend was refreshed and the same **Load Tickets** action was repeated.

The browser successfully loaded all three ticket objects.

Chrome DevTools showed no CORS errors.

The frontend displayed:

- Customer API returning 502
- Database latency investigation
- Worker queue processing delay

The browser integration was fully restored.

## Layer Isolation

| Layer | Result |
|---|---|
| Frontend server | Healthy |
| Nginx reachability | Healthy |
| API endpoint | HTTP 200 |
| PostgreSQL | Healthy |
| OPTIONS request reachability | Healthy |
| CORS response headers before fix | Missing |
| Browser cross-origin request before fix | Blocked |
| Preflight after fix | HTTP 204 |
| CORS headers after fix | Correct |
| Browser request after fix | Successful |

## Customer Update — Investigation

We confirmed that the API itself was healthy and returning data successfully. The issue only occurred when the service was accessed from the browser-based frontend.

## Customer Update — Root Cause Identified

The browser was blocking the request because the API gateway did not return the required CORS headers for the frontend origin and Authorization header.

## Customer Update — Resolved

The proxy CORS policy was updated and validated. Browser preflight requests now complete successfully, and the frontend can retrieve ticket data normally.

## Preventive Actions

- Define explicit allowed origins instead of using unrestricted wildcard CORS.
- Validate OPTIONS preflight responses during frontend integration testing.
- Test browser-based API access in addition to curl/Postman testing.
- Include Authorization and Content-Type headers in CORS validation.
- Use Chrome DevTools Network and Console when browser behavior differs from direct API tests.
- Validate proxy configuration with `nginx -t` before deployment.
- Add automated CORS integration tests for supported frontend origins.
- Document expected frontend origins and permitted request headers.

## Support Skills Demonstrated

- Browser vs API client troubleshooting
- CORS diagnostics
- OPTIONS preflight analysis
- Chrome DevTools investigation
- HTTP header analysis
- Nginx reverse-proxy configuration
- API troubleshooting
- Layer-by-layer fault isolation
- Root cause analysis
- Recovery validation
- Customer-facing incident communication

> This incident was intentionally reproduced in a self-built training environment. It is portfolio evidence and not employer production experience.
