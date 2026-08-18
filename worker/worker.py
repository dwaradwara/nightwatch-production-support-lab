from datetime import datetime, timezone
import json
import logging
import os
import time

import pika
import psycopg
from prometheus_client import Counter, Gauge, Histogram, start_http_server


SERVICE_NAME = os.getenv("SERVICE_NAME", "nightwatch-worker")
APP_ENV = os.getenv("APP_ENV", "dev")
APP_VERSION = os.getenv("APP_VERSION", "dev")
METRICS_PORT = int(os.getenv("WORKER_METRICS_PORT", "9100"))
QUEUE_NAME = os.getenv("RABBITMQ_QUEUE", "nightwatch-jobs")
QUARANTINE_QUEUE = os.getenv("RABBITMQ_QUARANTINE_QUEUE", f"{QUEUE_NAME}.quarantine")
MAX_RETRIES = int(os.getenv("WORKER_MAX_RETRIES", "5"))
RETRY_HEADER = "x-opsforge-retry-count"

logger = logging.getLogger("nightwatch.worker")
logger.setLevel(logging.INFO)
logger.handlers.clear()
handler = logging.StreamHandler()
handler.setFormatter(logging.Formatter("%(message)s"))
logger.addHandler(handler)
logger.propagate = False

worker_ready = Gauge(
    "nightwatch_worker_ready",
    "Whether the worker is connected to RabbitMQ and registered as a consumer",
)
rabbitmq_connection_up = Gauge(
    "nightwatch_worker_rabbitmq_connection_up",
    "Whether the worker currently has a RabbitMQ connection",
)
jobs_processed = Counter(
    "nightwatch_worker_jobs_processed_total",
    "Background jobs processed by result",
    ["result"],
)
jobs_retried = Counter(
    "nightwatch_worker_jobs_retried_total",
    "Background job deliveries republished for another processing attempt",
)
jobs_quarantined = Counter(
    "nightwatch_worker_jobs_quarantined_total",
    "Background jobs moved to the durable quarantine queue after exhausting retries",
)
job_duration = Histogram(
    "nightwatch_worker_job_duration_seconds",
    "Background job processing duration",
)
worker_db_duration = Histogram(
    "nightwatch_worker_db_operation_duration_seconds",
    "Worker database operation duration",
    ["operation"],
)


def log_event(level, event, **fields):
    payload = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "level": level.upper(),
        "service": SERVICE_NAME,
        "environment": APP_ENV,
        "version": APP_VERSION,
        "event": event,
        **fields,
    }
    getattr(logger, level)(json.dumps(payload, separators=(",", ":"), default=str))


def get_db():
    return psycopg.connect(
        host=os.getenv("DB_HOST", "nightwatch-db"),
        dbname=os.getenv("DB_NAME", "nightwatch"),
        user=os.getenv("DB_USER", "nightwatch"),
        password=os.getenv("DB_PASSWORD", ""),
        port=int(os.getenv("DB_PORT", "5432")),
        connect_timeout=3,
    )


def retry_count(properties):
    headers = dict(properties.headers or {}) if properties else {}
    value = headers.get(RETRY_HEADER, 0)
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return 0


def republish_properties(properties, headers):
    return pika.BasicProperties(
        delivery_mode=(properties.delivery_mode if properties and properties.delivery_mode else 2),
        content_type=(properties.content_type if properties and properties.content_type else "application/json"),
        message_id=(properties.message_id if properties else None),
        correlation_id=(properties.correlation_id if properties else None),
        headers=headers,
    )


def publish_retry(ch, properties, body, next_retry, exc):
    headers = dict(properties.headers or {}) if properties else {}
    headers[RETRY_HEADER] = next_retry
    headers["x-opsforge-last-error-type"] = type(exc).__name__
    ch.basic_publish(
        exchange="",
        routing_key=QUEUE_NAME,
        body=body,
        properties=republish_properties(properties, headers),
        mandatory=True,
    )


def publish_quarantine(ch, properties, body, attempts, exc):
    headers = dict(properties.headers or {}) if properties else {}
    headers[RETRY_HEADER] = attempts
    headers["x-opsforge-quarantine-reason"] = type(exc).__name__
    headers["x-opsforge-original-queue"] = QUEUE_NAME
    ch.basic_publish(
        exchange="",
        routing_key=QUARANTINE_QUEUE,
        body=body,
        properties=republish_properties(properties, headers),
        mandatory=True,
    )


def process(ch, method, properties, body):
    started = time.perf_counter()
    request_id = None
    event_id = None
    ticket_id = None
    event_type = None
    if properties and properties.headers:
        request_id = properties.headers.get("x-request-id") or properties.headers.get("X-Request-ID")

    try:
        event = json.loads(body)
        event_id = str(event["event_id"])
        event_type = str(event["event_type"])
        ticket_id = int(event["ticket_id"])
        request_id = request_id or event.get("request_id")

        log_event(
            "info",
            "job_started",
            queue=QUEUE_NAME,
            request_id=request_id,
            event_id=event_id,
            ticket_id=ticket_id,
            event_type=event_type,
            retry_count=retry_count(properties),
            delivery_tag=method.delivery_tag,
        )

        if event_type != "ticket.created":
            raise ValueError(f"unsupported event type: {event_type}")

        with worker_db_duration.labels(operation="ticket_process").time():
            with get_db() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        INSERT INTO ticket_events (
                            event_id, ticket_id, event_type, request_id, details
                        )
                        VALUES (%s, %s, %s, %s, %s::jsonb)
                        ON CONFLICT (event_id) DO NOTHING
                        """,
                        (
                            event_id,
                            ticket_id,
                            "ticket.processed",
                            request_id,
                            json.dumps({"source_event": event_type}),
                        ),
                    )
                    cur.execute(
                        """
                        UPDATE tickets
                        SET processing_status = 'processed', processed_at = NOW()
                        WHERE id = %s
                        """,
                        (ticket_id,),
                    )
                    if cur.rowcount != 1:
                        raise RuntimeError(f"ticket {ticket_id} does not exist")

        ch.basic_ack(delivery_tag=method.delivery_tag)
        jobs_processed.labels(result="success").inc()
        log_event(
            "info",
            "job_completed",
            queue=QUEUE_NAME,
            request_id=request_id,
            event_id=event_id,
            ticket_id=ticket_id,
            delivery_tag=method.delivery_tag,
        )
    except Exception as exc:
        current_retry = retry_count(properties)
        jobs_processed.labels(result="failure").inc()
        log_event(
            "error",
            "job_failed",
            queue=QUEUE_NAME,
            request_id=request_id,
            event_id=event_id,
            ticket_id=ticket_id,
            event_type=event_type,
            retry_count=current_retry,
            max_retries=MAX_RETRIES,
            error_type=type(exc).__name__,
            error=str(exc),
        )

        if current_retry < MAX_RETRIES:
            next_retry = current_retry + 1
            try:
                publish_retry(ch, properties, body, next_retry, exc)
                ch.basic_ack(delivery_tag=method.delivery_tag)
                jobs_retried.inc()
                log_event(
                    "warning",
                    "job_retry_scheduled",
                    queue=QUEUE_NAME,
                    request_id=request_id,
                    event_id=event_id,
                    ticket_id=ticket_id,
                    retry_count=next_retry,
                    max_retries=MAX_RETRIES,
                    error_type=type(exc).__name__,
                )
            except Exception as publish_exc:
                log_event(
                    "error",
                    "job_retry_publish_failed",
                    queue=QUEUE_NAME,
                    request_id=request_id,
                    retry_count=current_retry,
                    error_type=type(publish_exc).__name__,
                    error=str(publish_exc),
                )
                ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
        else:
            try:
                publish_quarantine(ch, properties, body, current_retry, exc)
                ch.basic_ack(delivery_tag=method.delivery_tag)
                jobs_quarantined.inc()
                log_event(
                    "error",
                    "job_quarantined",
                    queue=QUEUE_NAME,
                    quarantine_queue=QUARANTINE_QUEUE,
                    request_id=request_id,
                    event_id=event_id,
                    ticket_id=ticket_id,
                    attempts=current_retry + 1,
                    retries=current_retry,
                    max_retries=MAX_RETRIES,
                    error_type=type(exc).__name__,
                    error=str(exc),
                )
            except Exception as quarantine_exc:
                log_event(
                    "error",
                    "job_quarantine_publish_failed",
                    queue=QUEUE_NAME,
                    quarantine_queue=QUARANTINE_QUEUE,
                    request_id=request_id,
                    error_type=type(quarantine_exc).__name__,
                    error=str(quarantine_exc),
                )
                ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
    finally:
        job_duration.observe(time.perf_counter() - started)


def main():
    worker_ready.set(0)
    rabbitmq_connection_up.set(0)
    start_http_server(METRICS_PORT)
    log_event("info", "metrics_server_started", port=METRICS_PORT)

    credentials = pika.PlainCredentials(
        os.getenv("RABBITMQ_USER", "nightwatch"),
        os.getenv("RABBITMQ_PASSWORD", ""),
    )

    connection = None
    try:
        connection = pika.BlockingConnection(
            pika.ConnectionParameters(
                host=os.getenv("RABBITMQ_HOST", "nightwatch-rabbit"),
                credentials=credentials,
                heartbeat=30,
                blocked_connection_timeout=10,
                connection_attempts=5,
                retry_delay=2,
            )
        )
        rabbitmq_connection_up.set(1)

        channel = connection.channel()
        channel.queue_declare(queue=QUEUE_NAME, durable=True)
        channel.queue_declare(queue=QUARANTINE_QUEUE, durable=True)
        channel.confirm_delivery()
        channel.basic_qos(prefetch_count=5)
        channel.basic_consume(queue=QUEUE_NAME, on_message_callback=process)

        worker_ready.set(1)
        log_event(
            "info",
            "consumer_ready",
            queue=QUEUE_NAME,
            quarantine_queue=QUARANTINE_QUEUE,
            max_retries=MAX_RETRIES,
        )
        channel.start_consuming()
    except Exception as exc:
        worker_ready.set(0)
        rabbitmq_connection_up.set(0)
        log_event("error", "worker_stopped", error_type=type(exc).__name__, error=str(exc))
        raise
    finally:
        worker_ready.set(0)
        rabbitmq_connection_up.set(0)
        if connection and connection.is_open:
            connection.close()


if __name__ == "__main__":
    main()
