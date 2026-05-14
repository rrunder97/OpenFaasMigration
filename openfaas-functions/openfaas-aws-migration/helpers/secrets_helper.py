"""Placeholder for AWS Secrets Manager — wire boto3 and cache in production."""

from __future__ import annotations

import logging
import os

logger = logging.getLogger(__name__)


def get_secret(secret_name: str, default: str | None = None) -> str | None:
    """
    Return secret value. For local dev, fall back to env var matching the logical name.
    Example: secret_name 'secops_api_token' -> SECOPS_API_TOKEN env.
    """
    env_key = secret_name.upper()
    from_env = os.getenv(env_key)
    if from_env:
        return from_env
    logger.debug("secrets_helper placeholder: would fetch %s from Secrets Manager", secret_name)
    return default
