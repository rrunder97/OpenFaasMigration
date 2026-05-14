"""Basic logging setup aligned with LOG_LEVEL from the environment."""

from __future__ import annotations

import logging

from helpers.config_helper import get_env


def setup_logging(name: str | None = None) -> logging.Logger:
    level_name = (get_env("LOG_LEVEL") or "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    return logging.getLogger(name or __name__)


def get_logger(name: str | None = None) -> logging.Logger:
    """Migration-friendly alias for older handler imports."""
    return setup_logging(name)
