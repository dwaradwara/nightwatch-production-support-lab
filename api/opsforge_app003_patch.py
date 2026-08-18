import os

from flask import g, jsonify


CONFIG_KEY = "APP003_TICKET_EVENT_LIMIT"
DEFAULT_EVENT_LIMIT = 50
MIN_EVENT_LIMIT = 1
MAX_EVENT_LIMIT = 200


def _load_event_limit(log_event):
    raw_value = os.getenv(CONFIG_KEY, str(DEFAULT_EVENT_LIMIT)).strip()
    try:
        event_limit = int(raw_value)
        if not MIN_EVENT_LIMIT <= event_limit <= MAX_EVENT_LIMIT:
            raise ValueError("value outside supported range")
    except (TypeError, ValueError) as exc:
        log_event(
            "error",
            "configuration_error",
            request_id=g.request_id,
            config_key=CONFIG_KEY,
            supplied_value=raw_value,
            expected=f"integer {MIN_EVENT_LIMIT}-{MAX_EVENT_LIMIT}",
            error_type=type(exc).__name__,
        )
        return None, (
            jsonify(
                error="application configuration invalid",
                configuration=CONFIG_KEY,
            ),
            500,
        )

    return event_limit, None


def install(namespace):
    app = namespace["app"]
    log_event = namespace["log_event"]
    original_get_ticket = app.view_functions["get_ticket"]

    def app003_get_ticket(ticket_id):
        event_limit, error_response = _load_event_limit(log_event)
        if error_response is not None:
            return error_response

        result = original_get_ticket(ticket_id)
        if isinstance(result, tuple):
            return result

        payload = result.get_json(silent=True)
        if isinstance(payload, dict) and isinstance(payload.get("events"), list):
            payload["events"] = payload["events"][-event_limit:]
            return jsonify(payload)
        return result

    app003_get_ticket.__name__ = original_get_ticket.__name__
    app.view_functions["get_ticket"] = app003_get_ticket
