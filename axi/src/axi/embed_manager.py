"""Manager for the embed llama-server instance.

Mirrors nano_manager.py exactly, swapping NANO_ constants for EMBED_,
port 8090 → 8091, and service name llama-nano.service → llama-embed.service.

State files:
  ~/.local/state/axi/active_embed_model.json   active model config for the launcher

SYNC NOTE: The DEFAULT dict here is intentionally duplicated in the launcher
script (axi/scripts/axi-embed-launch DEFAULT dict). The launcher cannot import
Python packages, so duplication is unavoidable. THIS module is AUTHORITATIVE —
any change to the default config MUST be mirrored in the launcher.

Default model = Qwen3-Embedding-4B (PROVISIONAL — Slice-0 Spanish eval will
confirm or swap; the model path is configurable via active_embed_model.json so
swapping is a config-only change, no code edit needed).
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import time
from pathlib import Path

log = logging.getLogger("axi.embed_manager")

EMBED_HEALTH_URL = "http://127.0.0.1:8091/health"
EMBED_DEFAULT_ID = "qwen3-embedding-4b"

# ────────────────────────── default payload ──────────────────────────

# SYNC NOTE: Mirrored in axi/scripts/axi-embed-launch DEFAULT dict.
# axi-embed-launch CANNOT import Python packages — duplication is unavoidable.
# THIS function is AUTHORITATIVE.
def _make_default() -> dict:
    home = str(Path.home())
    return {
        "id": EMBED_DEFAULT_ID,
        "gguf": f"{home}/LifeOS/models/qwen3-embedding-4b/Qwen3-Embedding-4B-Q4_K_M.gguf",
        # Embedding models use --pooling last, NOT --jinja.
        # ctx 512 is sufficient for most passage/query pairs.
        "ctx": 512,
        "ngl": 0,  # CPU-only; CUDA_VISIBLE_DEVICES="" is set by the systemd unit
        "port": 8091,
        "extra_args": [
            "-t", "4",
            "--no-mmap",
        ],
    }


DEFAULT_EMBED: dict = _make_default()


# ────────────────────────── paths ────────────────────────────────────


def _state_dir() -> Path:
    root = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(root) / "axi"


def active_embed_model_path() -> Path:
    return _state_dir() / "active_embed_model.json"


# ────────────────────────── active-model state ───────────────────────


def read_active_embed() -> dict | None:
    p = active_embed_model_path()
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def get_active_embed_id() -> str | None:
    data = read_active_embed()
    return data.get("id") if data else None


# ────────────────────────── health + restart ─────────────────────────


def restart_embed_service() -> None:
    """Restart llama-embed.service via systemctl --user."""
    from axi import obs
    obs.managed_systemctl(
        "restart", "llama-embed.service",
        caller="embed_manager",
        reason="embed model swap",
        check=True,
        timeout=30,
    )


def wait_for_embed_health(timeout: float = 60.0, url: str | None = None) -> bool:
    """Poll /health until 200 OK or timeout. Returns False when service is down."""
    import urllib.request

    target = url or EMBED_HEALTH_URL
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(target, timeout=2) as r:
                if r.status == 200:
                    return True
        except Exception:  # noqa: BLE001
            pass
        time.sleep(1.0)
    return False


__all__ = [
    "DEFAULT_EMBED",
    "EMBED_DEFAULT_ID",
    "EMBED_HEALTH_URL",
    "active_embed_model_path",
    "get_active_embed_id",
    "read_active_embed",
    "restart_embed_service",
    "wait_for_embed_health",
]
