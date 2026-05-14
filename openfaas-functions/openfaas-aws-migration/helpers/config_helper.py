"""Load Config.yaml and expose simple getenv helpers for deployment values."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import yaml

# Default path next to the app when running from project root or container WORKDIR
_CONFIG_PATH = Path(__file__).resolve().parent.parent / "Config.yaml"
_cached_config: dict[str, Any] | None = None


def get_env(key: str, default: str | None = None) -> str | None:
    """Read a string from the process environment (ECS/task injects these)."""
    return os.getenv(key, default)


def load_app_config(path: Path | str | None = None) -> dict[str, Any]:
    """Load static application YAML (non-secrets). Safe to call repeatedly; result is cached."""
    global _cached_config
    if _cached_config is not None and path is None:
        return _cached_config

    cfg_path = Path(path) if path else _CONFIG_PATH
    with cfg_path.open(encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    if path is None:
        _cached_config = data
    return data


def get_config_value(key_path: str, default: Any = None) -> Any:
    """
    Dot-path lookup in loaded app config, e.g. 'application.name' or 'features.enable_debug_mode'.
    """
    parts = key_path.split(".")
    node: Any = load_app_config()
    for part in parts:
        if not isinstance(node, dict) or part not in node:
            return default
        node = node[part]
    return node
