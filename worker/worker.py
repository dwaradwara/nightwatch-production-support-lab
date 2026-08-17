from datetime import datetime, timezone
import json
import logging
import os
import time

import pika
from prometheus_client import Counter, Gauge, Histogram, start_http_server


SERVICE_NAME = os.getenv("SERVICE_NAME", "nightwatch-worker")
APP_ENV = os.getenv("APP_ENV", "dev")
APP_VERSION = os.getenv("APP_VERSION", "dev")
METRICS_PORT = int(os.getenv("WORKER_METRICS_PORT", "9100"))
QUEUE_NAME = os.getenv("RABBITMQ_QUEUE", "nightwatch-jobs")

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
job_duration = Histogram(
    "nightwatch_worker_job_duration_seconds",
    "Background job processing duration",
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


def process(ch, method, properties, body):
    started = time.perf_counter()
    request_id = None
    if properties and properties.headers:
        request_id = properties.headers.get("x-request-id") or properties.headers.get("X-Request-ID")

    try:
        log_event(
            "info",
            "job_started",
            queue=QUEUE_NAME,
            request_id=request_id,
            delivery_tag=method.delivery_tag,
        )

        # Simulated background work. Phase 2 will replace this with a real customer workflow.
        time.sleep(1)

        ch.basic_ack(delivery_tag=method.delivery_tag)
        jobs_processed.labels(result="success").inc()
        log_event(
            "info",
            "job_completed",
            queue=QUEUE_NAME,
            request_id=request_id,
            delivery_tag=method.delivery_tag,
        )
    except Exception as exc:
        jobs_processed.labels(result="failure").inc()
        log_event(
            "error",
            "job_failed",
            queue=QUEUE_NAME,
            request_id=request_id,
            error_type=type(exc).__name__,
        )
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
        raise
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
        channel.basic_qos(prefetch_count=5)
        channel.basic_consume(queue=QUEUE_NAME, on_message_callback=process)

        worker_ready.set(1)
        log_event("info", "consumer_ready", queue=QUEUE_NAME)
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
