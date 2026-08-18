#!/usr/bin/env python3
"""Render the OPSFORGE incident queue from machine-checkable operation records."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

SEVERITY_ORDER = {"P1": 0, "P2": 1, "P3": 2, "P4": 3}
ACK_TARGET_MINUTES = {"P1": 5, "P2": 15, "P3": 30, "P4": 240}
TERMINAL = {"Resolved", "Closed"}


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def load_incidents(root: Path) -> list[dict[str, Any]]:
    incidents: list[dict[str, Any]] = []
    for path in sorted(root.glob("INC-*.json")):
        record = json.loads(path.read_text(encoding="utf-8"))
        if record.get("record_type") == "incident":
            incidents.append(record)
    return incidents


def ack_state(record: dict[str, Any], now: datetime) -> str:
    if record.get("acknowledged_at"):
        detected = parse_time(record["detected_at"])
        acknowledged = parse_time(record["acknowledged_at"])
        elapsed = int((acknowledged - detected).total_seconds() // 60)
        target = ACK_TARGET_MINUTES[record["severity"]]
        return f"ACK {elapsed}m/{target}m"

    if record.get("status") in TERMINAL:
        return "ACK unknown"

    detected = parse_time(record["detected_at"])
    target = ACK_TARGET_MINUTES[record["severity"]]
    due = detected + timedelta(minutes=target)
    remaining = int((due - now).total_seconds() // 60)
    if remaining >= 0:
        return f"ACK due {remaining}m"
    return f"ACK OVERDUE {abs(remaining)}m"


def main() -> int:
    parser = argparse.ArgumentParser(description="Show OPSFORGE L2 incident queue")
    parser.add_argument("--records", default="operations/records", help="record directory")
    parser.add_argument("--all", action="store_true", help="include resolved/closed incidents")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    args = parser.parse_args()

    incidents = load_incidents(Path(args.records))
    if not args.all:
        incidents = [item for item in incidents if item.get("status") not in TERMINAL]

    incidents.sort(
        key=lambda item: (
            SEVERITY_ORDER.get(item.get("severity"), 99),
            parse_time(item["detected_at"]),
        )
    )

    if args.json:
        print(json.dumps(incidents, indent=2))
        return 0

    now = datetime.now(timezone.utc)
    print("NIGHTWATCH OPSFORGE — L2 INCIDENT QUEUE")
    print("=" * 104)
    if not incidents:
        print("No matching incidents")
        return 0

    print(f"{'ID':<10} {'SEV':<4} {'STATUS':<14} {'OWNER':<16} {'ACK':<18} TITLE")
    print("-" * 104)
    for item in incidents:
        print(
            f"{item['id']:<10} "
            f"{item['severity']:<4} "
            f"{item['status']:<14} "
            f"{item['owner']:<16} "
            f"{ack_state(item, now):<18} "
            f"{item['title']}"
        )

    print("\nPriority is based on customer/business impact; technical complexity does not determine severity.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
