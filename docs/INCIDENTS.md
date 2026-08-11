# NIGHTWATCH Incident Casebook

This document highlights the incidents that best demonstrate the troubleshooting approach used in NIGHTWATCH. The emphasis is on evidence-driven diagnosis: verify the symptom, isolate the failing layer, collect evidence, make the smallest corrective change, and verify recovery from the user-facing path.

---

## INC-NW-002 — API container failure behind a healthy proxy

**Customer symptom**  
Production API returned `502 Bad Gateway` through Nginx.

**Evidence collected**
- Direct request to the API on port `8000` failed.
- `docker ps -a` showed `nightwatch-api` had exited with code `137`.
- Docker state confirmed the container was not running.
- Docker event history showed the container received termination/kill signals before exiting.

**Diagnosis**  
Nginx was still available, but its backend application container was no longer running. The failure was therefore below the reverse-proxy layer.

**Root cause**  
The API container had been terminated, leaving Nginx with no reachable upstream application process.

**Recovery**
```powershell
docker start nightwatch-api
```

**Verification**
- `docker ps` showed the API container running again.
- `curl http://localhost:8000/health` returned `200 OK`.
- `curl http://localhost:8080/health` returned `200 OK` through Nginx.

**Support takeaway**  
A `502` does not automatically mean Nginx itself is broken. Verify the proxy, backend process, container state, and direct backend path separately.

---

## INC-NW-003 — Healthy API, broken Nginx upstream

**Customer symptom**  
Production endpoint returned `502 Bad Gateway`, while the API itself returned `200 OK` when called directly.

**Evidence collected**
- `curl http://localhost:8000/health` returned `200 OK`.
- Nginx error logs showed `connect() failed (111: Connection refused) while connecting to upstream`.
- Nginx configuration showed the upstream pointing to `127.0.0.1:8000` or an invalid backend port instead of the API container service name.

**Diagnosis**  
The application was healthy. The fault was isolated to reverse-proxy routing.

**Root cause**  
Inside the Nginx container, `127.0.0.1` refers to the Nginx container itself, not the separate API container. A wrong port produced the same customer-facing `502` symptom.

**Recovery**
```nginx
proxy_pass http://nightwatch-api:8000;
```

The Nginx configuration was validated and reloaded.

**Verification**
```powershell
curl.exe -i http://localhost:8080/health
```
returned `HTTP/1.1 200 OK`.

**Support takeaway**  
Direct backend health plus proxy failure is a strong signal to inspect upstream configuration, DNS/service discovery, network membership, and target port before touching the application.

---

## DB-001 — PostgreSQL authentication failure

**Customer symptom**  
Database-backed API endpoint returned `500 Internal Server Error`.

**Evidence collected**
- API traceback originated from `psycopg.connect()`.
- PostgreSQL returned `FATAL: password authentication failed for user "nightwatch"`.
- The database container itself was running and accepting connections.

**Diagnosis**  
The database was available, but the application could not authenticate. This ruled out a database outage and Docker network failure.

**Root cause**  
The password expected by the API did not match the PostgreSQL role credential.

**Recovery**  
The lab database credential was restored to match the application configuration. The project was later cleaned so service credentials are supplied through environment variables instead of being committed in source code.

**Verification**
- `/db-health` returned `200 OK` with PostgreSQL reported healthy.
- `/api/tickets` returned the expected ticket records.

**Support takeaway**  
`Connection refused`, DNS resolution failure, and authentication failure are different classes of database incident. The exact driver/database error should determine the next diagnostic step.

---

## DB-003 — API timeout caused by a blocking database lock

**Customer symptom**  
`/api/tickets` stopped responding and timed out after three seconds.

**Evidence collected**
```powershell
curl.exe --max-time 3 http://localhost:8080/api/tickets
```
returned an operation timeout.

`pg_stat_activity` showed:
- one session holding an `ACCESS EXCLUSIVE` lock on `tickets` while sleeping,
- the API query waiting on a `Lock` / `relation` event,
- the diagnostic session itself.

**Diagnosis**  
The API process and PostgreSQL server were both running. The request was blocked inside the database by another session.

**Root cause**  
A transaction held an exclusive table lock long enough to block the API query.

**Recovery**  
The blocking backend PID was identified from `pg_stat_activity` and only that session was terminated using `pg_terminate_backend()`.

**Verification**
```powershell
curl.exe -i http://localhost:8080/api/tickets
```
returned `HTTP/1.1 200 OK` and the ticket data.

**Support takeaway**  
Restarting PostgreSQL would have recovered the symptom but destroyed useful evidence and interrupted unrelated sessions. Identify and remove the blocker instead of restarting the whole service by default.

---

## MQ-001 — RabbitMQ queue backlog with no consumer

**Customer symptom**  
Background jobs accumulated and were not being processed.

**Evidence collected**
```powershell
docker exec nightwatch-rabbit rabbitmqctl list_queues name messages_ready consumers
```
showed the `nightwatch-jobs` queue with queued messages and `0` consumers.

**Diagnosis**  
RabbitMQ itself was healthy and had accepted the messages. The missing component was the worker/consumer.

**Root cause**  
The NIGHTWATCH worker was stopped, so there was no consumer attached to the queue.

**Recovery**
```powershell
docker start nightwatch-worker
```

**Verification**  
Queue inspection showed a consumer attached and the backlog drained as the worker logged each job being processed.

A related test paused the worker while a consumer remained connected. RabbitMQ then showed messages as **unacknowledged**, demonstrating the difference between:
- no consumer / messages ready, and
- a connected but stuck consumer / messages unacknowledged.

**Support takeaway**  
Queue depth alone is not enough. Compare `messages_ready`, `messages_unacknowledged`, and `consumers` to distinguish producer, broker, and consumer-side failures.

---

## K8S-001 — Pod healthy, Kubernetes Service unreachable

**Customer symptom**  
The application Pod was `Running` and `Ready`, but the Kubernetes Service had no usable backend.

**Evidence collected**
```powershell
kubectl get pods --show-labels
kubectl get svc nightwatch-api-svc
kubectl get endpointslice -l kubernetes.io/service-name=nightwatch-api-svc
```

The Pod label was:
```text
app=nightwatch-api
```

The Service selector had been changed to:
```text
app=broken-selector
```

The EndpointSlice showed no backend endpoint.

**Diagnosis**  
The workload itself was healthy. Kubernetes could not associate the Service with the Pod because the selector did not match the Pod labels.

**Root cause**  
Service-to-Pod routing failure caused by a selector/label mismatch.

**Recovery**
```powershell
kubectl set selector service/nightwatch-api-svc app=nightwatch-api
```

**Verification**
- EndpointSlice repopulated with the Pod endpoint.
- An in-cluster curl request to the Service returned the API health response successfully.

**Support takeaway**  
`Pod Running` does not mean `Service reachable`. For Kubernetes routing incidents, inspect Pod readiness and labels, Service selectors, and EndpointSlices as separate layers.

---

## Evidence still to add

The written RCA is useful, but screenshots make the project materially stronger. The best evidence set is small and selective rather than a dump of every terminal command.

For each incident above, keep **1–2 screenshots maximum** showing the decisive evidence, for example:

| Incident | Best screenshot evidence |
|---|---|
| INC-NW-002 | API container `Exited (137)` + successful health check after restart |
| INC-NW-003 | Nginx upstream error/config + recovered `200 OK` |
| DB-001 | PostgreSQL authentication failure traceback + recovered DB health |
| DB-003 | `pg_stat_activity` lock/wait evidence + successful request after terminating blocker |
| MQ-001 | RabbitMQ queue with backlog/0 consumers + worker processing/drained queue |
| K8S-001 | Pod labels + EndpointSlice with no endpoint, then restored endpoint |

Store final screenshots under a simple structure such as:

```text
docs/
  evidence/
    nw-002/
    nw-003/
    db-001/
    db-003/
    mq-001/
    k8s-001/
```

The objective is not to prove that commands were typed. The objective is to make the diagnostic reasoning visible.