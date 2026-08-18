import os
import socket
import time
import urllib.request

from flask import g, jsonify


DEPENDENCY_NAME = "app002-policy-service"
DEFAULT_URL = "http://app002-slow:8080/policy"
DEFAULT_TIMEOUT_SECONDS = 1.0


def _is_timeout(exc):
    reason = getattr(exc, "reason", None)
    return (
        isinstance(exc, (TimeoutError, socket.timeout))
        or isinstance(reason, (TimeoutError, socket.timeout))
        or "timed out" in str(exc).lower()
    )


def _dependency_probe(log_event):
    url = os.getenv("APP002_DEPENDENCY_URL", DEFAULT_URL)
    timeout_seconds = float(
        os.getenv("APP002_DEPENDENCY_TIMEOUT_SECONDS", str(DEFAULT_TIMEOUT_SECONDS))
    )
    started = time.perf_counter()

    try:
        with urllib.request.urlopen(url, timeout=timeout_seconds) as response:
            response.read()
            status_code = response.getcode()
        elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
        log_event(
            "info",
            "dependency_call_succeeded",
            request_id=g.request_id,
            dependency=DEPENDENCY_NAME,
            operation="ticket_read_policy_check",
            status_code=status_code,
            timeout_seconds=timeout_seconds,
            elapsed_ms=elapsed_ms,
        )
        return None
    except Exception as exc:
        elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
        if not _is_timeout(exc):
            log_event(
                "error",
                "dependency_call_failed",
                request_id=g.request_id,
                dependency=DEPENDENCY_NAME,
                operation="ticket_read_policy_check",
                timeout_seconds=timeout_seconds,
                elapsed_ms=elapsed_ms,
                error_type=type(exc).__name__,
            )
            raise

        log_event(
            "error",
            "dependency_timeout",
            request_id=g.request_id,
            dependency=DEPENDENCY_NAME,
            operation="ticket_read_policy_check",
            timeout_seconds=timeout_seconds,
            elapsed_ms=elapsed_ms,
            error_type=type(exc).__name__,
        )
        return (
            jsonify(
                error="downstream dependency timed out",
                dependency=DEPENDENCY_NAME,
                timeout_seconds=timeout_seconds,
            ),
            504,
        )


def install(namespace):
    app = namespace["app"]
    log_event = namespace["log_event"]
    original_get_ticket = app.view_functions["get_ticket"]

    def app002_get_ticket(ticket_id):
        timeout_response = _dependency_probe(log_event)
        if timeout_response is not None:
            return timeout_response
        return original_get_ticket(ticket_id)

    app002_get_ticket.__name__ = original_get_ticket.__name__
    app.view_functions["get_ticket"] = app002_get_ticket
