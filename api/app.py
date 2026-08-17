from datetime import datetime, timezone
import json
import logging
import os
import time
import uuid

from flask import Flask, g, jsonify, request
from opentelemetry import trace
import psycopg
from psycopg.rows import dict_row
from prometheus_client import Counter, Gauge, Histogram
from prometheus_flask_exporter import PrometheusMetrics
import redis


SERVICE_NAME = os.getenv("SERVICE_NAME", "nightwatch-api")
APP_ENV = os.getenv("APP_ENV", "dev")
APP_VERSION = os.getenv("APP_VERSION", "dev")

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

    try:
        check_database()
        dependencies["postgresql"] = "healthy"
    except Exception as exc:
        ready = False
        dependencies["postgresql"] = f"unhealthy:{type(exc).__name__}"

    try:
        check_cache()
        dependencies["redis"] = "healthy"
    except Exception as exc:
        ready = False
        dependencies["redis"] = f"unhealthy:{type(exc).__name__}"

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


@app.get("/api/tickets")
def tickets():
    with db_query_duration.labels(operation="tickets_list").time():
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, title, severity, status FROM tickets ORDER BY id"
                )
                rows = cur.fetchall()

    return jsonify(rows)


if __name__ == "__main__":
    log_event("info", "service_start", port=8000)
    app.run(host="0.0.0.0", port=8000)
