"""Manager for downloading, activating, and inspecting catalog models.

State is split across two roots:

  ~/LifeOS/models/<entry_id>/         # downloaded weights (per-entry dir)
  ~/.local/state/axi/active_model.json  # one source of truth for llama-server

Activating an entry writes the JSON, then restarts llama-server.service so
the new args (via axi-llama-launch) come up. The legacy Qwen3.6 entry uses
the historical paths under `~/LifeOS/models/Qwen3.6-35B-A3B/` — we never
move those files.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from axi.models_catalog import CATALOG, ModelEntry, ModelFile, by_id, catalog

log = logging.getLogger("axi.models")

LLAMA_HEALTH_URL = "http://127.0.0.1:8080/health"
LEGACY_QWEN_ID = "qwen36-35b-a3b"
LEGACY_QWEN_DIR_NAME = "Qwen3.6-35B-A3B"


# ────────────────────────── paths ───────────────────────────────


def models_dir() -> Path:
    """Root for downloaded model bundles."""
    return Path.home() / "LifeOS" / "models"


def model_dir(entry: ModelEntry) -> Path:
    """Per-entry directory. The legacy Qwen entry keeps its historical name
    so we never touch the 22 GB on-disk file."""
    if entry.id == LEGACY_QWEN_ID:
        return models_dir() / LEGACY_QWEN_DIR_NAME
    return models_dir() / entry.id


def expected_path(entry: ModelEntry, mf: ModelFile) -> Path:
    return model_dir(entry) / mf.local_name


def expected_paths(entry: ModelEntry) -> dict[str, Path]:
    """Map of {'gguf': path, 'mmproj': path?} for activation/inspection."""
    out: dict[str, Path] = {}
    for f in entry.files:
        if f.kind in out:
            continue
        out[f.kind] = expected_path(entry, f)
    return out


def is_installed(entry: ModelEntry) -> bool:
    """True iff every file in the bundle exists on disk."""
    return all(expected_path(entry, f).exists() for f in entry.files)


# ────────────────────────── active-model state ────────────────────


def _state_dir() -> Path:
    root = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(root) / "axi"


def active_model_path() -> Path:
    return _state_dir() / "active_model.json"


def read_active() -> dict | None:
    p = active_model_path()
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def get_active_id() -> str | None:
    data = read_active()
    return data.get("id") if data else None


def _entry_to_active_dict(entry: ModelEntry) -> dict:
    paths = expected_paths(entry)
    out = {
        "id": entry.id,
        "gguf": str(paths["gguf"]),
        "ctx": entry.ctx,
        "ngl": entry.ngl,
        "extra_args": list(entry.extra_args),
    }
    if "mmproj" in paths:
        out["mmproj"] = str(paths["mmproj"])
    return out


def write_active(entry: ModelEntry) -> Path:
    """Write active_model.json atomically (tmp + rename) so a partial write
    can never poison the wrapper. Does NOT restart llama-server."""
    p = active_model_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(_entry_to_active_dict(entry), indent=2))
    tmp.replace(p)
    return p


# ────────────────────────── download ─────────────────────────────


ProgressCb = Callable[[int, int, float], None]


def download(entry: ModelEntry, *, progress_cb: ProgressCb | None = None) -> None:
    """Download every file in the bundle into `model_dir(entry)`.

    Skips files already present (idempotent). Uses HF_TOKEN if exported, but
    only public repos are in the catalog so a token is not required.
    Raises on the first failing file — partial downloads stay on disk so a
    retry resumes via the HF cache layer.
    """
    if entry.id == LEGACY_QWEN_ID:
        # Legacy entry: files are bundled with the original install. If the
        # paths exist we're done; otherwise refuse to download because the
        # files would need to come from a different source than the catalog.
        if is_installed(entry):
            if progress_cb:
                progress_cb(len(entry.files), len(entry.files), 100.0)
            return
        raise FileNotFoundError(
            f"legacy entry {entry.id} files missing on disk; this entry is "
            f"not auto-downloadable. Reinstall the original 22GB bundle "
            f"at {model_dir(entry)} manually."
        )

    from huggingface_hub import hf_hub_download  # local import → testable

    dest = model_dir(entry)
    dest.mkdir(parents=True, exist_ok=True)
    total = len(entry.files)
    token = os.environ.get("HF_TOKEN")

    for idx, f in enumerate(entry.files):
        out_path = expected_path(entry, f)
        if out_path.exists():
            if progress_cb:
                progress_cb(idx + 1, total, 100.0)
            continue
        if progress_cb:
            progress_cb(idx, total, 0.0)
        try:
            downloaded = hf_hub_download(
                repo_id=f.repo_id,
                filename=f.filename,
                local_dir=str(dest),
                token=token,
            )
        except Exception as e:  # noqa: BLE001
            log.exception("hf_hub_download failed for %s/%s", f.repo_id, f.filename)
            raise
        # hf_hub_download returns the final path; if it differs from where
        # we expect (e.g. dest_relname rename), copy/symlink into place.
        final = Path(downloaded)
        if final != out_path and not out_path.exists():
            try:
                out_path.parent.mkdir(parents=True, exist_ok=True)
                if not out_path.exists():
                    out_path.symlink_to(final)
            except OSError:
                # Fall back to copy.
                import shutil
                shutil.copyfile(final, out_path)
        if progress_cb:
            progress_cb(idx + 1, total, 100.0)


# ────────────────────────── activate ──────────────────────────────


def _systemctl_restart_llama() -> None:
    """Restart llama-server.service via the user systemd manager."""
    subprocess.run(
        ["systemctl", "--user", "restart", "llama-server.service"],
        check=True,
        timeout=30,
    )


def wait_for_llama_health(timeout: float = 60.0, url: str | None = None) -> bool:
    """Poll the llama-server /health endpoint until 200 OK or timeout."""
    import urllib.request

    target = url or LLAMA_HEALTH_URL
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


def set_active(entry: ModelEntry, *, restart: bool = True, wait_health: bool = True) -> bool:
    """Make `entry` the active model.

    Steps:
      1. Refuse if files missing.
      2. Write active_model.json atomically.
      3. systemctl --user restart llama-server.service.
      4. Wait for /health.

    Returns True iff health came back within the timeout. Tests inject
    restart=False / wait_health=False to skip the side effects.
    """
    if not is_installed(entry):
        raise FileNotFoundError(
            f"entry {entry.id} is not installed; call download() first"
        )
    write_active(entry)
    if restart:
        _systemctl_restart_llama()
    if wait_health:
        return wait_for_llama_health()
    return True


# ────────────────────────── snapshot for API ───────────────────


@dataclass
class CatalogStatus:
    """Per-entry status suitable for JSON serialization in /api/models."""

    entry: ModelEntry
    installed: bool
    is_active: bool

    def to_dict(self) -> dict:
        return {
            "id": self.entry.id,
            "name": self.entry.name,
            "family": self.entry.family,
            "params": self.entry.params,
            "features": list(self.entry.features),
            "description": self.entry.description,
            "vram_estimate_gb": self.entry.vram_estimate_gb,
            "ctx": self.entry.ctx,
            "installed": self.installed,
            "is_active": self.is_active,
            "notes": self.entry.notes,
        }


def catalog_status() -> list[CatalogStatus]:
    active = get_active_id()
    return [
        CatalogStatus(
            entry=e,
            installed=is_installed(e),
            is_active=(e.id == active),
        )
        for e in catalog()
    ]


__all__ = [
    "CATALOG",
    "CatalogStatus",
    "active_model_path",
    "by_id",
    "catalog",
    "catalog_status",
    "download",
    "expected_paths",
    "get_active_id",
    "is_installed",
    "model_dir",
    "models_dir",
    "read_active",
    "set_active",
    "wait_for_llama_health",
    "write_active",
]
