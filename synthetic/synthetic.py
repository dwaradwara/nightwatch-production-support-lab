from datetime import datetime, timezone
import json
import logging
import os
import time
import uuid
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from prometheus_client import Counter, Gauge, Histogram, start_http_server


SERVICE_NAME = "nightwatch-synthetic"
BASE_URL = os.getenv("SYNTHETIC_BASE_URL", "http://nightwatch-nginx").rstrip("/")
CUSTOMER_ID = os.getenv("SYNTHETIC_CUSTOMER_ID", "synthetic-customer")
METRICS_PORT = int(os.getenv("SYNTHETIC_METRICS_PORT", "9200"))
INTERVAL_SECONDS = float(os.getenv("SYNTHETIC_INTERVAL_SECONDS", "15"))
TIMEOUT_SECONDS = float(os.getenv("SYNTHETIC_TIMEOUT_SECONDS", "15"))

journeys_total = Counter(
    "nightwatch_synthetic_journeys_total",
    "Synthetic customer journeys by result",
    ["result"],
)
journey_duration = Histogram(
    "nightwatch_synthetic_journey_duration_seconds",
    "End-to-end synthetic ticket journey duration",
)
customer_path_up = Gauge(
    "nightwatch_synthetic_customer_path_up",
    "Whether the latest synthetic customer journey succeeded",
)
last_success = Gauge(
    "nightwatch_synthetic_last_success_timestamp_seconds",
    "Unix timestamp of the latest successful synthetic journey",
)

logger = logging.getLogger("nightwatch.synthetic")
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
        "event": event,
        **fields,
    }
    getattr(logger, level)(json.dumps(payload, separators=(",", ":"), default=str))


def request_json(method, path, body=None):
    payload = None
    headers = {"X-Customer-ID": CUSTOMER_ID}
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = Request(f"{BASE_URL}{path}", data=payload, headers=headers, method=method)
    with urlopen(req, timeout=5) as response:
        response_body = json.loads(response.read().decode("utf-8"))
        request_id = response.headers.get("X-Request-ID")
        return response.status, response_body, request_id


def run_journey():
    started = time.perf_counter()
    synthetic_id = str(uuid.uuid4())
    title = f"OPSFORGE synthetic customer {synthetic_id[:8]}"
    request_id = None
    ticket_id = None

    try:
        status, ticket, request_id = request_json(
            "POST",
            "/api/tickets",
            {"title": title, "severity": "SEV4"},
        )
        if status != 201:
            raise RuntimeError(f"ticket creation returned HTTP {status}")

        ticket_id = int(ticket["id"])
        if ticket.get("customer_id") != CUSTOMER_ID:
            raise RuntimeError("created ticket did not preserve customer identity")

        deadline = time.monotonic() + TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            _, current, _ = request_json("GET", f"/api/tickets/{ticket_id}")
            processed_event = any(
                event.get("event_type") == "ticket.processed"
                for event in current.get("events", [])
            )
            if current.get("processing_status") == "processed" and processed_event:
                break
            time.sleep(0.5)
        else:
            raise TimeoutError(
                f"ticket {ticket_id} did not reach processed state within {TIMEOUT_SECONDS}s"
            )

        update_status, updated, _ = request_json(
            "PATCH",
            f"/api/tickets/{ticket_id}",
            {"status": "Resolved"},
        )
        if update_status != 200 or updated.get("status") != "Resolved":
            raise RuntimeError("ticket update did not return Resolved state")

        _, final_state, _ = request_json("GET", f"/api/tickets/{ticket_id}")
        status_event = any(
            event.get("event_type") == "ticket.status_updated"
            and event.get("details", {}).get("status") == "Resolved"
            for event in final_state.get("events", [])
        )
        if final_state.get("status") != "Resolved" or not status_event:
            raise RuntimeError("final ticket state did not persist the customer update")

        elapsed = time.perf_counter() - started
        journeys_total.labels(result="success").inc()
        journey_duration.observe(elapsed)
        customer_path_up.set(1)
        last_success.set(time.time())
        log_event(
            "info",
            "synthetic_journey_succeeded",
            customer_id=CUSTOMER_ID,
            ticket_id=ticket_id,
            request_id=request_id,
            duration_ms=round(elapsed * 1000, 2),
        )
    except (HTTPError, URLError, TimeoutError, RuntimeError, KeyError, ValueError) as exc:
        elapsed = time.perf_counter() - started
        journeys_total.labels(result="failure").inc()
        journey_duration.observe(elapsed)
        customer_path_up.set(0)
        log_event(
            "error",
            "synthetic_journey_failed",
            customer_id=CUSTOMER_ID,
            ticket_id=ticket_id,
            request_id=request_id,
            duration_ms=round(elapsed * 1000, 2),
            error_type=type(exc).__name__,
            error=str(exc),
        )


def main():
    customer_path_up.set(0)
    start_http_server(METRICS_PORT)
    log_event(
        "info",
        "synthetic_monitor_started",
        base_url=BASE_URL,
        customer_id=CUSTOMER_ID,
        interval_seconds=INTERVAL_SECONDS,
        timeout_seconds=TIMEOUT_SECONDS,
        metrics_port=METRICS_PORT,
    )

    while True:
        cycle_started = time.monotonic()
        run_journey()
        elapsed = time.monotonic() - cycle_started
        time.sleep(max(0.0, INTERVAL_SECONDS - elapsed))


if __name__ == "__main__":
    main()
