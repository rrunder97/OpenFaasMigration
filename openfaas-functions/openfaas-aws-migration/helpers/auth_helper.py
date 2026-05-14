"""Token validation placeholder — replace with your IdP/JWT or API key logic."""

from __future__ import annotations

import logging

logger = logging.getLogger(__name__)


def validate_bearer_token(token: str | None) -> bool:
    """
    Example: return True if token is non-empty.
    Replace with signature verification, introspection, etc.
    """
    if not token:
        logger.warning("missing bearer token")
        return False
    # Placeholder: accept any non-empty string
    return True
