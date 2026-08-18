#!/usr/bin/env python3
"""Validate OPSFORGE support-operation records without third-party dependencies."""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

SEVERITIES = {"P1", "P2", "P3", "P4"}
INCIDENT_STATUSES = {
    "New",
    "Acknowledged",
    "Investigating",
    "Mitigating",
    "Monitoring",
    "Escalated",
    "Resolved",
    "Closed",
}
ACK_TARGET_MINUTES = {"P1": 5, "P2": 15, "P3": 30, "P4": 240}
PREFIXES = {
    "incident": "INC",
    "l1_escalation": "L1E",
    "l2_notes": "L2N",
    "l3_escalation": "L3E",
    "change": "CHG",
    "problem": "PRB",
    "handover": "HOV",
    "runbook": "RUN",
}


def fail(errors: list[str], path: Path, message: str) -> None:
    errors.append(f"{path}: {message}")


def require(record: dict[str, Any], fields: list[str], errors: list[str], path: Path) -> None:
    for field in fields:
        if field not in record:
            fail(errors, path, f"missing required field '{field}'")
            continue
        value = record[field]
        if value is None or value == "" or value == []:
            fail(errors, path, f"required field '{field}' is empty")


def parse_time(value: str, errors: list[str], path: Path, field: str) -> datetime | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        fail(errors, path, f"field '{field}' must be an ISO-8601 timestamp")
        return None


def validate_common(record: dict[str, Any], errors: list[str], path: Path) -> None:
    require(record, ["record_type", "id", "created_at", "owner"], errors, path)
    record_type = record.get("record_type")
    if record_type not in PREFIXES:
        fail(errors, path, f"unsupported record_type '{record_type}'")
        return

    expected_prefix = PREFIXES[record_type]
    record_id = str(record.get("id", ""))
    if not re.fullmatch(rf"{expected_prefix}-[A-Z0-9-]+", record_id):
        fail(errors, path, f"id '{record_id}' must start with {expected_prefix}-")

    if record.get("created_at"):
        parse_time(str(record["created_at"]), errors, path, "created_at")


def validate_incident(record: dict[str, Any], errors: list[str], path: Path) -> None:
    require(
        record,
        [
            "title",
            "severity",
            "status",
            "service",
            "source",
            "detected_at",
            "customer_impact",
            "scope",
            "timeline",
            "evidence",
        ],
        errors,
        path,
    )
    severity = record.get("severity")
    status = record.get("status")
    if severity not in SEVERITIES:
        fail(errors, path, f"severity must be one of {sorted(SEVERITIES)}")
    if status not in INCIDENT_STATUSES:
        fail(errors, path, f"invalid incident status '{status}'")

    detected = parse_time(str(record.get("detected_at", "")), errors, path, "detected_at")
    acknowledged_value = record.get("acknowledged_at")
    acknowledged = None
    if acknowledged_value:
        acknowledged = parse_time(str(acknowledged_value), errors, path, "acknowledged_at")

    if status != "New" and acknowledged is None:
        fail(errors, path, "acknowledged_at is required once an incident leaves New")

    if detected and acknowledged and severity in ACK_TARGET_MINUTES:
        elapsed_minutes = (acknowledged - detected).total_seconds() / 60
        if elapsed_minutes < 0:
            fail(errors, path, "acknowledged_at cannot be before detected_at")
        target = ACK_TARGET_MINUTES[severity]
        if elapsed_minutes > target and not record.get("sla_breach_reason"):
            fail(
                errors,
                path,
                f"acknowledgement exceeded {severity} target of {target} minutes; add sla_breach_reason",
            )

    if not isinstance(record.get("timeline"), list):
        fail(errors, path, "timeline must be a list")
    if not isinstance(record.get("evidence"), list):
        fail(errors, path, "evidence must be a list")


def validate_l1_escalation(record: dict[str, Any], errors: list[str], path: Path) -> None:
    require(
        record,
        [
            "incident_id",
            "symptom",
            "first_observed_at",
            "affected_feature",
            "checks_performed",
            "missing_information",
            "disposition",
        ],
        errors,
        path,
    )
    parse_time(str(record.get("first_observed_at", "")), errors, path, "first_observed_at")
    if record.get("disposition") == "needs_clarification" and not record.get("missing_information"):
        fail(errors, path, "needs_clarification requires missing_information")


def validate_l2_notes(record: dict[str, Any], errors: list[str], path: Path) -> None:
    require(record, ["incident_id", "impact_assessment", "hypotheses", "actions", "current_assessment"], errors, path)
    if not isinstance(record.get("hypotheses"), list):
        fail(errors, path, "hypotheses must be a list")
    if not isinstance(record.get("actions"), list):
        fail(errors, path, "actions must be a list")


def validate_l3_escalation(record: dict[str, Any], errors: list[str], path: Path) -> None:
    require(
        record,
        [
            "incident_id",
            "business_impact",
            "first_observed_at",
            "affected_version",
            "reproduction",
            "evidence",
            "steps_already_performed",
            "suspected_component",
            "requested_action",
        ],
        errors,
        path,
    )
    if not record.get("evidence"):
        fail(errors, path, "L3 escalation must include evidence")
    if not record.get("steps_already_performed"):
        fail(errors, path, "L3 escalation must list completed troubleshooting")


def validate_change(record: dict[str, Any], errors: list[str], path: Path) -> None:
    require(
        record,
        [
            "title",
            "reason",
            "affected_services",
            "risk",
            "implementation_plan",
            "validation_plan",
            "rollback_plan",
            "approval_status",
        ],
        errors,
        path,
    )
    if record.get("approval_status") not in {"Draft", "Approved", "Rejected", "Completed", "RolledBack"}:
        fail(errors, path, "invalid approval_status")


def validate_problem(record: dict[str, Any], errors: list[str], path: Path) -> None:
    require(
        record,
        ["title", "linked_incidents", "pattern", "business_impact", "workaround", "corrective_action", "status"],
        errors,
        path,
    )
    linked = record.get("linked_incidents", [])
    if not isinstance(linked, list) or len(linked) < 2:
        fail(errors, path, "problem record must link at least two incidents")


def validate_handover(record: dict[str, Any], errors: list[str], path: Path) -> None:
    require(
        record,
        ["shift_start", "shift_end", "service_health", "open_incidents", "scheduled_changes", "risks", "next_actions"],
        errors,
        path,
    )
    start = parse_time(str(record.get("shift_start", "")), errors, path, "shift_start")
    end = parse_time(str(record.get("shift_end", "")), errors, path, "shift_end")
    if start and end and end <= start:
        fail(errors, path, "shift_end must be after shift_start")


def validate_runbook(record: dict[str, Any], errors: list[str], path: Path) -> None:
    require(
        record,
        ["title", "trigger", "preconditions", "diagnostic_steps", "mitigation_steps", "validation_steps", "escalation_boundary"],
        errors,
        path,
    )


VALIDATORS = {
    "incident": validate_incident,
    "l1_escalation": validate_l1_escalation,
    "l2_notes": validate_l2_notes,
    "l3_escalation": validate_l3_escalation,
    "change": validate_change,
    "problem": validate_problem,
    "handover": validate_handover,
    "runbook": validate_runbook,
}


def validate_file(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"{path}: invalid JSON: {exc}"]

    if not isinstance(record, dict):
        return [f"{path}: top-level JSON value must be an object"]

    validate_common(record, errors, path)
    validator = VALIDATORS.get(record.get("record_type"))
    if validator:
        validator(record, errors, path)
    return errors


def main() -> int:
    roots = [Path(arg) for arg in sys.argv[1:]] or [Path("operations/records")]
    files: list[Path] = []
    for root in roots:
        if root.is_dir():
            files.extend(sorted(root.rglob("*.json")))
        elif root.suffix == ".json":
            files.append(root)
        else:
            print(f"No JSON records found at {root}", file=sys.stderr)
            return 2

    if not files:
        print("No operational JSON records found", file=sys.stderr)
        return 2

    errors: list[str] = []
    for path in files:
        errors.extend(validate_file(path))

    if errors:
        print("OPSFORGE support-record validation FAILED", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"OPSFORGE support-record validation PASSED: {len(files)} record(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
