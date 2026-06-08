"""Manager for the nano llama-server model selection.

State files:
  ~/LifeOS/models/<entry_id>/           downloaded weights (per-entry dir)
  ~/.local/state/axi/active_nano_model.json   active model config for the launcher

The default (Qwen3.5-0.8B) preserves the historical path at
~/LifeOS/models/qwen35-0_8b/ so no existing files need to move.

Activating an entry writes active_nano_model.json then restarts
llama-nano.service (same pattern as models_manager for the brain).
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import time
from pathlib import Path

from axi.nano_catalog import NanoModelEntry, NanoModelFile, by_id, catalog

log = logging.getLogger("axi.nano_manager")

NANO_HEALTH_URL = "http://127.0.0.1:8090/health"
NANO_DEFAULT_ID = "qwen35-0_8b"


# ────────────────────────── default payload ──────────────────────────

# The default constant mirrors the exact args that llama-nano.service used
# to hardcode before this change, so a fresh install with no
# active_nano_model.json on disk behaves byte-identically.
#
# SYNC NOTE: This dict is intentionally duplicated in the launcher script
# (axi/scripts/axi-nano-launch DEFAULT dict). The launcher cannot import Python
# packages, so duplication is unavoidable. THIS function is AUTHORITATIVE — any
# change to the default config MUST be mirrored in the launcher.
def _make_default() -> dict:
    home = str(Path.home())
    return {
        "id": "qwen35-0_8b",
        "gguf": f"{home}/LifeOS/models/qwen35-0_8b/Qwen3.5-0.8B-Q4_K_M.gguf",
        # mmproj intentionally absent: the historical service unit never loaded it.
        # The runtime only calls /v1/chat/completions (text) — no vision.
        # Add "mmproj": "<path>" to active_nano_model.json to enable vision.
        "ctx": 4096,
        "ngl": 0,
        "port": 8090,
        "extra_args": [
            "-t", "4",
            "--no-mmap",
            "-np", "1",
            "-a", "Qwen3.5-0.8B-nano",
        ],
    }


DEFAULT_NANO: dict = _make_default()


# ────────────────────────── paths ────────────────────────────────────


def _state_dir() -> Path:
    root = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(root) / "axi"


def active_nano_model_path() -> Path:
    return _state_dir() / "active_nano_model.json"


def nano_models_dir() -> Path:
    """Root directory for nano model bundles."""
    return Path.home() / "LifeOS" / "models"


def nano_model_dir(entry: NanoModelEntry) -> Path:
    """Per-entry directory for a nano model bundle."""
    return nano_models_dir() / entry.id


def nano_expected_path(entry: NanoModelEntry, mf: NanoModelFile) -> Path:
    return nano_model_dir(entry) / mf.local_name


def nano_expected_paths(entry: NanoModelEntry) -> dict[str, Path]:
    """Map of {'gguf': path, 'mmproj': path?} for activation/inspection."""
    out: dict[str, Path] = {}
    for f in entry.files:
        if f.kind in out:
            continue
        out[f.kind] = nano_expected_path(entry, f)
    return out


def is_nano_installed(entry: NanoModelEntry) -> bool:
    """True iff every file in the bundle exists on disk."""
    return all(nano_expected_path(entry, f).exists() for f in entry.files)


# ────────────────────────── active-model state ───────────────────────


def read_active_nano() -> dict | None:
    p = active_nano_model_path()
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def get_active_nano_id() -> str | None:
    data = read_active_nano()
    return data.get("id") if data else None


def _entry_to_nano_dict(entry: NanoModelEntry) -> dict:
    """Build the active_nano_model.json payload for `entry`."""
    paths = nano_expected_paths(entry)
    out: dict = {
        "id": entry.id,
        "gguf": str(paths["gguf"]),
        "ctx": entry.ctx,
        "ngl": entry.ngl,  # always 0 for nano (CPU-only)
        "port": entry.port,
        "extra_args": list(entry.extra_args),
    }
    if "mmproj" in paths:
        out["mmproj"] = str(paths["mmproj"])
    return out


def write_active_nano(entry: NanoModelEntry) -> Path:
    """Write active_nano_model.json atomically (tmp + rename).

    Does NOT restart llama-nano.service — call set_active_nano() for that.
    """
    p = active_nano_model_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(_entry_to_nano_dict(entry), indent=2))
    tmp.replace(p)
    return p


# ────────────────────────── launcher args builder ────────────────────


def build_nano_launch_args(cfg: dict) -> list[str]:
    """Build the argv for llama-server from an active_nano_model.json dict.

    Mirrors axi-nano-launch exactly: --jinja, -c, -ngl, --host, --port are
    assembled from the config fields; extra_args holds model-specific tuning
    only (so none of those flags appear twice).
    """
    ngl = int(cfg.get("ngl", 0))
    ctx = int(cfg.get("ctx", 4096))
    port = str(cfg.get("port", 8090))
    args = ["/usr/bin/llama-server", "-m", cfg["gguf"]]
    if cfg.get("mmproj"):
        args += ["--mmproj", cfg["mmproj"]]
    args += [
        "-ngl", str(ngl),
        "--jinja",
        "-c", str(ctx),
        "--host", "127.0.0.1",
        "--port", port,
    ]
    args += list(cfg.get("extra_args", []))
    return args


# ────────────────────────── health + restart ─────────────────────────


def _systemctl_restart_nano() -> None:
    subprocess.run(
        ["systemctl", "--user", "restart", "llama-nano.service"],
        check=True,
        timeout=30,
    )


def wait_for_nano_health(timeout: float = 60.0, url: str | None = None) -> bool:
    """Poll /health until 200 OK or timeout."""
    import urllib.request

    target = url or NANO_HEALTH_URL
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


# ────────────────────────── activate ─────────────────────────────────


def set_active_nano(
    entry: NanoModelEntry,
    *,
    restart: bool = True,
    wait_health: bool = False,
) -> bool:
    """Make `entry` the active nano model.

    Steps:
      1. Refuse if files missing on disk.
      2. Write active_nano_model.json atomically.
      3. systemctl --user restart llama-nano.service (if restart=True).
      4. Optionally poll /health.

    Returns True on success. Tests pass restart=False to skip systemctl.
    wait_health defaults to False (nano is optional; callers that care
    about live status can pass True).
    """
    if not is_nano_installed(entry):
        raise FileNotFoundError(
            f"nano entry {entry.id} is not installed; call download first"
        )
    write_active_nano(entry)
    if restart:
        _systemctl_restart_nano()
    if wait_health:
        return wait_for_nano_health()
    return True


# ────────────────────────── catalog status ───────────────────────────


def nano_catalog_status() -> list[dict]:
    """Per-entry status list suitable for JSON serialization."""
    active_id = get_active_nano_id()
    result = []
    for e in catalog():
        result.append({
            "id": e.id,
            "name": e.name,
            "family": e.family,
            "params": e.params,
            "features": list(e.features),
            "description": e.description,
            "ctx": e.ctx,
            "port": e.port,
            "installed": is_nano_installed(e),
            "is_active": (e.id == active_id),
            "notes": e.notes,
        })
    return result


__all__ = [
    "DEFAULT_NANO",
    "NANO_DEFAULT_ID",
    "active_nano_model_path",
    "build_nano_launch_args",
    "by_id",
    "catalog",
    "get_active_nano_id",
    "is_nano_installed",
    "nano_catalog_status",
    "nano_expected_paths",
    "nano_model_dir",
    "nano_models_dir",
    "read_active_nano",
    "set_active_nano",
    "wait_for_nano_health",
    "write_active_nano",
    "_entry_to_nano_dict",
]
