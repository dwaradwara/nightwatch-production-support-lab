from flask import Flask, jsonify
import psycopg
from psycopg.rows import dict_row
import redis
from prometheus_flask_exporter import PrometheusMetrics
import os


app = Flask(__name__)
metrics = PrometheusMetrics(app)

cache = redis.Redis(
    host=os.getenv("REDIS_HOST", "nightwatch-redis"),
    port=int(os.getenv("REDIS_PORT", "6379")),
    decode_responses=True
)

@app.get("/cache-health")
def cache_health():
    cache.ping()
    return jsonify(cache="redis", status="healthy")


def get_db():
    return psycopg.connect(
        host=os.getenv("DB_HOST", "nightwatch-db"),
        dbname=os.getenv("DB_NAME", "nightwatch"),
        user=os.getenv("DB_USER", "nightwatch"),
        password=os.getenv("DB_PASSWORD", ""),
        port=int(os.getenv("DB_PORT", "5432")),
        row_factory=dict_row
    )

@app.get("/health")
def health():
    return jsonify(service="nightwatch-api", status="healthy")


@app.get("/db-health")
def db_health():
    with get_db() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
    return jsonify(database="postgresql", status="healthy")


@app.get("/api/tickets")
def tickets():
    with get_db() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, title, severity, status FROM tickets ORDER BY id"
            )
            rows = cur.fetchall()

    return jsonify(rows)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)