# INC-021 — Worker Outage and Queue Backlog

## Summary

A worker outage was discovered while RabbitMQ remained healthy.

The `nightwatch-jobs` queue accumulated 114 ready messages with zero active consumers. The API and broker remained available, but asynchronous ticket-processing work could not progress because the worker process was not running.

Restarting the worker restored the consumer connection and drained the backlog to zero.

## Impact

- RabbitMQ remained healthy.
- Worker container was not running.
- `nightwatch-jobs` accumulated 114 ready messages.
- Queue consumer count dropped to zero.
- Asynchronous jobs were delayed.
- Messages remained safely queued rather than being lost.
- API availability was not directly affected.

## Observed State

RabbitMQ queue inspection showed:

```text
name             messages_ready  messages_unacknowledged  consumers
nightwatch-jobs  114             0                        0
```

The worker container was absent from the running container list while RabbitMQ remained healthy. This isolated the failure to the consumer/worker layer rather than the message broker.

## Investigation

### 1. Verified RabbitMQ availability

RabbitMQ remained running and healthy. This ruled out a broker outage.

### 2. Verified worker state

The worker container was not running. This explained why no consumer was attached to the queue.

### 3. Inspected queue depth

The queue contained 114 ready messages with zero unacknowledged messages and zero consumers. This indicated that messages were waiting safely in RabbitMQ and had not been delivered to a worker.

### 4. Distinguished producer from consumer failure

Because messages were present in the queue, producers were still capable of publishing work. The failure was therefore isolated to the consumer side.

## Root Cause

The NIGHTWATCH worker process was not running. With no active consumer connected to RabbitMQ, newly published jobs accumulated in the `nightwatch-jobs` queue.

RabbitMQ continued storing the messages successfully, preventing message loss.

## Resolution

The worker container was restarted:

```text
docker start nightwatch-worker
```

After restart, the worker reconnected to RabbitMQ and began processing the accumulated jobs.

Worker logs showed repeated:

```text
job_started
job_completed
```

## Recovery Verification

After recovery:

```text
name             messages_ready  messages_unacknowledged  consumers
nightwatch-jobs  0               0                        1
```

The backlog drained completely and one active consumer remained connected. This confirmed successful worker recovery and queue processing.

## Preventive Actions

- Alert when RabbitMQ consumer count drops to zero.
- Alert on sustained growth of `messages_ready`.
- Monitor queue depth and message age together.
- Add worker container health and restart monitoring.
- Configure an appropriate Docker restart policy for the worker.
- Distinguish broker health from consumer health in dashboards.
- Track worker processing throughput and failure rate.
- Alert when backlog growth exceeds normal processing capacity.
- Document worker recovery and queue-drain procedures in the support runbook.

## Support Skills Demonstrated

- RabbitMQ queue diagnosis
- Worker/consumer outage isolation
- Queue backlog analysis
- Producer vs consumer failure differentiation
- Asynchronous processing troubleshooting
- Docker container recovery
- Message durability validation
- Queue-drain verification
- Production-style incident reasoning

> This incident was observed and reproduced in a self-built training environment. It is portfolio evidence and not employer production experience.
