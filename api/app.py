from datetime import datetime, timezone
import json
import logging
import os
import time
import uuid

from flask import Flask, g, jsonify, request
from opentelemetry import trace
import pika
import psycopg
from psycopg.rows import dict_row
from prometheus_client import Counter, Gauge, Histogram
from prometheus_flask_exporter import PrometheusMetrics
import redis


SERVICE_NAME = os.getenv("SERVICE_NAME", "nightwatch-api")
APP_ENV = os.getenv("APP_ENV", "dev")
APP_VERSION = os.getenv("APP_VERSION", "dev")
QUEUE_NAME = os.getenv("RABBITMQ_QUEUE", "nightwatch-jobs")
VALID_SEVERITIES = {"SEV1", "SEV2", "SEV3", "SEV4"}
VALID_STATUSES = {"Open", "Investigating", "Resolved"}

app = Flask(__name__)
metrics = PrometheusMetrics(app)

app_info = Gauge(
    "nightwatch_app_info",
    "Static NIGHTWATCH application metadata",
    ["service", "environment", "version"],
)
app_info.labels(service=SERVICE_NAME, environment=APP_ENV, version=APP_VERSION).set(1)

dependency_up = Gauge(
    "nightwatch_dependency_up",
    "Whether an API dependency is currently reachable",
    ["dependency"],
)
dependency_checks = Counter(
    "nightwatch_dependency_checks_total",
    "Dependency health checks by result",
    ["dependency", "result"],
)
dependency_latency = Histogram(
    "nightwatch_dependency_latency_seconds",
    "Latency observed while checking API dependencies",
    ["dependency", "operation"],
)
db_query_duration = Histogram(
    "nightwatch_db_query_duration_seconds",
    "Application database query duration",
    ["operation"],
)
ticket_events_published = Counter(
    "nightwatch_ticket_events_published_total",
    "Ticket background events published by result",
    ["result"],
)
ticket_publish_duration = Histogram(
    "nightwatch_ticket_publish_duration_seconds",
    "Time spent publishing ticket events to RabbitMQ",
)

logger = logging.getLogger("nightwatch.api")
logger.setLevel(logging.INFO)
logger.handlers.clear()
handler = logging.StreamHandler()
handler.setFormatter(logging.Formatter("%(message)s"))
logger.addHandler(handler)
logger.propagate = False


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


cache = redis.Redis(
    host=os.getenv("REDIS_HOST", "nightwatch-redis"),
    port=int(os.getenv("REDIS_PORT", "6379")),
    decode_responses=True,
    socket_connect_timeout=2,
    socket_timeout=2,
)


def get_db():
    return psycopg.connect(
        host=os.getenv("DB_HOST", "nightwatch-db"),
        dbname=os.getenv("DB_NAME", "nightwatch"),
        user=os.getenv("DB_USER", "nightwatch"),
        password=os.getenv("DB_PASSWORD", ""),
        port=int(os.getenv("DB_PORT", "5432")),
        connect_timeout=3,
        row_factory=dict_row,
    )


def get_rabbitmq_connection():
    credentials = pika.PlainCredentials(
        os.getenv("RABBITMQ_USER", "nightwatch"),
        os.getenv("RABBITMQ_PASSWORD", ""),
    )
    return pika.BlockingConnection(
        pika.ConnectionParameters(
            host=os.getenv("RABBITMQ_HOST", "nightwatch-rabbit"),
            credentials=credentials,
            heartbeat=30,
            blocked_connection_timeout=5,
            connection_attempts=3,
            retry_delay=1,
        )
    )


def get_customer_id():
    customer_id = request.headers.get("X-Customer-ID", "").strip()
    if not customer_id or len(customer_id) > 100:
        return None
    return customer_id


def check_database():
    started = time.perf_counter()
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
        dependency_up.labels(dependency="postgresql").set(1)
        dependency_checks.labels(dependency="postgresql", result="success").inc()
    except Exception:
        dependency_up.labels(dependency="postgresql").set(0)
        dependency_checks.labels(dependency="postgresql", result="failure").inc()
        raise
    finally:
        dependency_latency.labels(dependency="postgresql", operation="health_check").observe(
            time.perf_counter() - started
        )


def check_cache():
    started = time.perf_counter()
    try:
        cache.ping()
        dependency_up.labels(dependency="redis").set(1)
        dependency_checks.labels(dependency="redis", result="success").inc()
    except Exception:
        dependency_up.labels(dependency="redis").set(0)
        dependency_checks.labels(dependency="redis", result="failure").inc()
        raise
    finally:
        dependency_latency.labels(dependency="redis", operation="ping").observe(
            time.perf_counter() - started
        )


def check_rabbitmq():
    started = time.perf_counter()
    connection = None
    try:
        connection = get_rabbitmq_connection()
        dependency_up.labels(dependency="rabbitmq").set(1)
        dependency_checks.labels(dependency="rabbitmq", result="success").inc()
    except Exception:
        dependency_up.labels(dependency="rabbitmq").set(0)
        dependency_checks.labels(dependency="rabbitmq", result="failure").inc()
        raise
    finally:
        if connection and connection.is_open:
            connection.close()
        dependency_latency.labels(dependency="rabbitmq", operation="connect").observe(
            time.perf_counter() - started
        )


def publish_ticket_event(ticket):
    started = time.perf_counter()
    connection = None
    try:
        connection = get_rabbitmq_connection()
        channel = connection.channel()
        channel.queue_declare(queue=QUEUE_NAME, durable=True)
        channel.confirm_delivery()

        payload = json.dumps(ticket, separators=(",", ":"))
        published = channel.basic_publish(
            exchange="",
            routing_key=QUEUE_NAME,
            body=payload,
            properties=pika.BasicProperties(
                delivery_mode=2,
                content_type="application/json",
                message_id=ticket["event_id"],
                headers={"x-request-id": ticket["request_id"]},
            ),
            mandatory=True,
        )
        if published is False:
            raise RuntimeError("RabbitMQ did not confirm ticket event")

        dependency_up.labels(dependency="rabbitmq").set(1)
        ticket_events_published.labels(result="success").inc()
    except Exception:
        dependency_up.labels(dependency="rabbitmq").set(0)
        ticket_events_published.labels(result="failure").inc()
        raise
    finally:
        if connection and connection.is_open:
            connection.close()
        ticket_publish_duration.observe(time.perf_counter() - started)


@app.before_request
def start_request_context():
    incoming_request_id = request.headers.get("X-Request-ID", "").strip()
    g.request_id = incoming_request_id or str(uuid.uuid4())
    g.request_started = time.perf_counter()

    current_span = trace.get_current_span()
    if current_span.is_recording():
        current_span.set_attribute("nightwatch.request_id", g.request_id)
        current_span.set_attribute("nightwatch.environment", APP_ENV)
        current_span.set_attribute("nightwatch.version", APP_VERSION)


@app.after_request
def finish_request_context(response):
    request_id = getattr(g, "request_id", "unknown")
    started = getattr(g, "request_started", time.perf_counter())
    duration_ms = round((time.perf_counter() - started) * 1000, 2)

    response.headers["X-Request-ID"] = request_id
    log_event(
        "info",
        "http_request",
        request_id=request_id,
        method=request.method,
        path=request.path,
        status=response.status_code,
        duration_ms=duration_ms,
        remote_addr=request.headers.get("X-Forwarded-For", request.remote_addr),
    )
    return response


@app.get("/health")
@app.get("/health/live")
def liveness():
    return jsonify(
        service=SERVICE_NAME,
        environment=APP_ENV,
        version=APP_VERSION,
        status="healthy",
        check="liveness",
    )


@app.get("/health/ready")
def readiness():
    dependencies = {}
    ready = True

    checks = (
        ("postgresql", check_database),
        ("redis", check_cache),
        ("rabbitmq", check_rabbitmq),
    )
    for name, check in checks:
        try:
            check()
            dependencies[name] = "healthy"
        except Exception as exc:
            ready = False
            dependencies[name] = f"unhealthy:{type(exc).__name__}"

    status_code = 200 if ready else 503
    return (
        jsonify(
            service=SERVICE_NAME,
            environment=APP_ENV,
            version=APP_VERSION,
            status="ready" if ready else "not_ready",
            check="readiness",
            dependencies=dependencies,
        ),
        status_code,
    )


@app.get("/version")
def version():
    return jsonify(service=SERVICE_NAME, environment=APP_ENV, version=APP_VERSION)


@app.get("/db-health")
def db_health():
    try:
        check_database()
        return jsonify(database="postgresql", status="healthy")
    except Exception as exc:
        return jsonify(database="postgresql", status="unhealthy", error=type(exc).__name__), 503


@app.get("/cache-health")
def cache_health():
    try:
        check_cache()
        return jsonify(cache="redis", status="healthy")
    except Exception as exc:
        return jsonify(cache="redis", status="unhealthy", error=type(exc).__name__), 503


@app.get("/queue-health")
def queue_health():
    try:
        check_rabbitmq()
        return jsonify(queue="rabbitmq", status="healthy")
    except Exception as exc:
        return jsonify(queue="rabbitmq", status="unhealthy", error=type(exc).__name__), 503


@app.get("/api/tickets")
def tickets():
    with db_query_duration.labels(operation="tickets_list").time():
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT id, title, severity, status, processing_status,
                           customer_id, request_id, created_at, processed_at
                    FROM tickets
                    ORDER BY id
                    """
                )
                rows = cur.fetchall()

    return jsonify(rows)


@app.post("/api/tickets")
def create_ticket():
    payload = request.get_json(silent=True) or {}
    title = str(payload.get("title", "")).strip()
    severity = str(payload.get("severity", "")).strip().upper()
    customer_id = get_customer_id()

    if customer_id is None:
        return jsonify(error="X-Customer-ID header is required and must be 1-100 characters"), 400
    if not title or len(title) > 200:
        return jsonify(error="title must contain 1-200 characters"), 400
    if severity not in VALID_SEVERITIES:
        return jsonify(error="severity must be one of SEV1, SEV2, SEV3, SEV4"), 400

    request_id = g.request_id
    with db_query_duration.labels(operation="ticket_create").time():
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO tickets (
                        title, severity, status, processing_status, customer_id, request_id
                    )
                    VALUES (%s, %s, 'Open', 'queued', %s, %s)
                    RETURNING id, title, severity, status, processing_status,
                              customer_id, request_id, created_at, processed_at
                    """,
                    (title, severity, customer_id, request_id),
                )
                ticket = cur.fetchone()

    event_id = str(uuid.uuid4())
    event = {
        "event_id": event_id,
        "event_type": "ticket.created",
        "ticket_id": ticket["id"],
        "customer_id": customer_id,
        "request_id": request_id,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }

    try:
        publish_ticket_event(event)
    except Exception as exc:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE tickets SET processing_status = 'publish_failed' WHERE id = %s",
                    (ticket["id"],),
                )
        log_event(
            "error",
            "ticket_event_publish_failed",
            request_id=request_id,
            customer_id=customer_id,
            ticket_id=ticket["id"],
            event_id=event_id,
            error_type=type(exc).__name__,
        )
        return (
            jsonify(
                error="ticket created but background processing could not be queued",
                ticket_id=ticket["id"],
                processing_status="publish_failed",
            ),
            503,
        )

    with get_db() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, title, severity, status, processing_status,
                       customer_id, request_id, created_at, processed_at
                FROM tickets
                WHERE id = %s
                """,
                (ticket["id"],),
            )
            ticket = cur.fetchone()

    log_event(
        "info",
        "ticket_created",
        request_id=request_id,
        customer_id=customer_id,
        ticket_id=ticket["id"],
        event_id=event_id,
        severity=severity,
    )
    return jsonify(ticket), 201


@app.get("/api/tickets/<int:ticket_id>")
def get_ticket(ticket_id):
    customer_id = get_customer_id()
    if customer_id is None:
        return jsonify(error="X-Customer-ID header is required and must be 1-100 characters"), 400

    with db_query_duration.labels(operation="ticket_get").time():
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT id, title, severity, status, processing_status,
                           customer_id, request_id, created_at, processed_at
                    FROM tickets
                    WHERE id = %s AND customer_id = %s
                    """,
                    (ticket_id, customer_id),
                )
                ticket = cur.fetchone()
                if ticket is None:
                    return jsonify(error="ticket not found"), 404

                cur.execute(
                    """
                    SELECT event_id, event_type, request_id, details, created_at
                    FROM ticket_events
                    WHERE ticket_id = %s
                    ORDER BY created_at
                    """,
                    (ticket_id,),
                )
                events = cur.fetchall()

    ticket["events"] = events
    return jsonify(ticket)


@app.patch("/api/tickets/<int:ticket_id>")
def update_ticket(ticket_id):
    customer_id = get_customer_id()
    if customer_id is None:
        return jsonify(error="X-Customer-ID header is required and must be 1-100 characters"), 400

    payload = request.get_json(silent=True) or {}
    status = str(payload.get("status", "")).strip()
    if status not in VALID_STATUSES:
        return jsonify(error="status must be one of Open, Investigating, Resolved"), 400

    request_id = g.request_id
    event_id = str(uuid.uuid4())

    with db_query_duration.labels(operation="ticket_update").time():
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE tickets
                    SET status = %s
                    WHERE id = %s AND customer_id = %s
                    RETURNING id, title, severity, status, processing_status,
                              customer_id, request_id, created_at, processed_at
                    """,
                    (status, ticket_id, customer_id),
                )
                ticket = cur.fetchone()
                if ticket is None:
                    return jsonify(error="ticket not found"), 404

                cur.execute(
                    """
                    INSERT INTO ticket_events (
                        event_id, ticket_id, event_type, request_id, details
                    )
                    VALUES (%s, %s, 'ticket.status_updated', %s, %s::jsonb)
                    """,
                    (
                        event_id,
                        ticket_id,
                        request_id,
                        json.dumps({"status": status}),
                    ),
                )

    log_event(
        "info",
        "ticket_updated",
        request_id=request_id,
        customer_id=customer_id,
        ticket_id=ticket_id,
        event_id=event_id,
        status=status,
    )
    return jsonify(ticket)


if __name__ == "__main__":
    log_event("info", "service_start", port=8000)
    app.run(host="0.0.0.0", port=8000)
