"""Small shared utilities."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any


def safe_str(value: Any) -> str:
    return "" if value is None else str(value)


def create_ecs_timestamp() -> str:
    """Return a simple UTC timestamp string for request lifecycle logging."""
    return datetime.now(timezone.utc).isoformat()
