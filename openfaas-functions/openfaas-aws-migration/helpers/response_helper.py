"""Simple success/error shapes for JSON responses."""

from __future__ import annotations

from typing import Any


def success(data: dict[str, Any] | None = None) -> dict[str, Any]:
    out = {"ok": True}
    if data:
        out.update(data)
    return out


def error(message: str, code: str | None = None, extra: dict[str, Any] | None = None) -> dict[str, Any]:
    body: dict[str, Any] = {"ok": False, "error": message}
    if code:
        body["code"] = code
    if extra:
        body.update(extra)
    return body


def success_response(data: dict[str, Any] | None = None) -> dict[str, Any]:
    """Migration-friendly alias for older handler naming."""
    return success(data)


def error_response(
    message: str,
    code: str | None = None,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Migration-friendly alias for older handler naming."""
    return error(message, code=code, extra=extra)
