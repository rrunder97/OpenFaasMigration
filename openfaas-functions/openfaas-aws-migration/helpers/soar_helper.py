"""Placeholder SOAR HTTP client — replace with real calls using SOAR_URL and token."""

from __future__ import annotations

import logging
from typing import Any

from helpers.config_helper import get_env

logger = logging.getLogger(__name__)


def soar_ping() -> dict[str, Any]:
    """Example stub: log intent to call SOAR; return metadata only."""
    url = get_env("SOAR_URL", "")
    logger.info("soar_helper: would POST/GET against %s", url or "(unset)")
    return {"soar": "stub", "url_configured": bool(url)}
