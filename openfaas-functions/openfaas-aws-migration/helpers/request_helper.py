"""Light request parsing utilities for handler-style payloads."""

from __future__ import annotations

from typing import Any


def extract_body_dict(payload: Any) -> dict[str, Any]:
    """Normalize incoming payload to a dict (OpenFaaS often passed JSON object)."""
    if payload is None:
        return {}
    if isinstance(payload, dict):
        return payload
    return {"raw": payload}
