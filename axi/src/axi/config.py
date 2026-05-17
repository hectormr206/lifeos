"""Per-user runtime configuration for Axi.

Loaded from `~/.config/axi/config.json`. Created with defaults if missing.
Everything that should be modifiable later from the dashboard lives here.

Schema and validation live in `axi.config_schema`. This module is the
file-I/O + cache layer; the schema is the source of truth for defaults,
types, bounds, and JSON Schema generation.
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any

from axi import config_schema
from axi.config_schema import ConfigError  # re-export for callers

log = logging.getLogger("axi.config")

CONFIG_DIR = Path(
    os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))
) / "axi"
CONFIG_PATH = CONFIG_DIR / "config.json"


def _default_dict() -> dict[str, Any]:
    return config_schema.defaults()


# Back-compat: some callers / tests import `DEFAULTS` directly. Keep it as
# a snapshot of schema defaults so external imports keep working.
DEFAULTS: dict[str, Any] = _default_dict()

_cache: dict[str, Any] | None = None


def _load() -> dict[str, Any]:
    global _cache
    if _cache is not None:
        return _cache
    if not CONFIG_PATH.exists():
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        defaults = _default_dict()
        CONFIG_PATH.write_text(
            json.dumps(defaults, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        _cache = defaults
        log.info("created default config at %s", CONFIG_PATH)
        return _cache
    try:
        data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        log.warning("could not read %s: %s — using defaults", CONFIG_PATH, e)
        _cache = _default_dict()
        return _cache
    # Lenient: unknown keys preserved, bad values fall back to defaults with
    # a warning event. The daemon must never fail to start because of one
    # corrupted field.
    _cache = config_schema.lenient_load(data if isinstance(data, dict) else {})
    return _cache


def get(key: str, default: Any = None) -> Any:
    return _load().get(key, default)


def save(values: dict[str, Any]) -> dict[str, Any]:
    """Strict save: validates `values` against the schema, writes to disk.

    Raises `ConfigError` on the first invalid field. The on-disk file is
    NOT modified if validation fails.
    """
    global _cache
    validated = config_schema.load_validated(values)
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(
        json.dumps(validated, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    _cache = validated
    return validated


def reload() -> dict[str, Any]:
    """Force the next `get()` to re-read from disk."""
    global _cache
    _cache = None
    return _load()
