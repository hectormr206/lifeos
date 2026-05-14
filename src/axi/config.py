"""Per-user runtime configuration for Axi.

Loaded from `~/.config/axi/config.json`. Created with defaults if missing.
Everything that should be modifiable later from the dashboard lives here.
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any

log = logging.getLogger("axi.config")

CONFIG_DIR = Path(
    os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))
) / "axi"
CONFIG_PATH = CONFIG_DIR / "config.json"

DEFAULTS: dict[str, Any] = {
    "timezone": "America/Mexico_City",
    "language": "es-MX",
    "user_name": "Héctor",
    "tts_enabled": True,
    "vision_enabled": True,
    "fact_extraction_enabled": True,
    # Meeting mode tuning
    "meeting_silence_rms": 0.015,         # skip chunks below this RMS — 0.005 was too permissive for BT monitor noise
    "meeting_window_minutes": 15,          # hierarchical summary window size
    "meeting_keep_raw_audio": True,        # set False to delete .wav after transcription
    "meeting_incremental_transcribe": True,
    "meeting_transcribe_poll_s": 30,       # background transcribe thread interval
}

_cache: dict[str, Any] | None = None


def _load() -> dict[str, Any]:
    global _cache
    if _cache is not None:
        return _cache
    if not CONFIG_PATH.exists():
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        CONFIG_PATH.write_text(json.dumps(DEFAULTS, ensure_ascii=False, indent=2), encoding="utf-8")
        _cache = dict(DEFAULTS)
        log.info("created default config at %s", CONFIG_PATH)
        return _cache
    try:
        data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        merged = dict(DEFAULTS)
        merged.update(data if isinstance(data, dict) else {})
        _cache = merged
    except (OSError, json.JSONDecodeError) as e:
        log.warning("could not read %s: %s — using defaults", CONFIG_PATH, e)
        _cache = dict(DEFAULTS)
    return _cache


def get(key: str, default: Any = None) -> Any:
    return _load().get(key, default)
