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
from axi.model_params_schema import (
    SCHEMA,
    ParamSpec,
    by_key as _spec_by_key,
    is_applicable,
    validate_value,
)

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


def _entry_to_active_dict(entry: ModelEntry, overrides: dict | None = None) -> dict:
    """Build the active_model.json payload for `entry`.

    With `overrides=None` or an empty dict for this entry, the payload is
    BYTE-IDENTICAL to the historical behavior (entry.extra_args verbatim,
    entry.ctx/entry.ngl). With overrides present, we apply them on top of
    the baseline via `merge_extra_args`.
    """
    paths = expected_paths(entry)
    entry_overrides = (overrides or {}).get(entry.id, {}) if overrides else {}
    if entry_overrides:
        ctx_val = int(entry_overrides.get("ctx", entry.ctx))
        ngl_val = int(entry_overrides.get("ngl", entry.ngl))
        merged_args = merge_extra_args(entry, entry_overrides)
    else:
        ctx_val = entry.ctx
        ngl_val = entry.ngl
        merged_args = list(entry.extra_args)
    out = {
        "id": entry.id,
        "gguf": str(paths["gguf"]),
        "ctx": ctx_val,
        "ngl": ngl_val,
        "extra_args": merged_args,
    }
    if "mmproj" in paths:
        out["mmproj"] = str(paths["mmproj"])
    return out


# ────────────────────────── overrides + params ─────────────────────


def overrides_path() -> Path:
    return _state_dir() / "model_overrides.json"


def load_overrides() -> dict[str, dict]:
    p = overrides_path()
    if not p.exists():
        return {}
    try:
        data = json.loads(p.read_text())
        if not isinstance(data, dict):
            return {}
        # Only keep dict-of-dict shape; ignore anything stale.
        return {k: v for k, v in data.items() if isinstance(v, dict)}
    except (json.JSONDecodeError, OSError):
        return {}


def save_overrides(overrides: dict[str, dict]) -> Path:
    p = overrides_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(overrides, indent=2, sort_keys=True))
    tmp.replace(p)
    return p


def effective_params(entry: ModelEntry, overrides: dict | None = None) -> dict:
    """Resolve the effective value of every applicable knob for `entry`.

    Order (lowest → highest priority):
      1. ParamSpec.default
      2. entry.param_defaults (if present)
      3. overrides[entry.id]
    """
    out: dict = {}
    entry_param_defaults = getattr(entry, "param_defaults", {}) or {}
    entry_overrides = (overrides or {}).get(entry.id, {}) if overrides else {}
    for spec in SCHEMA:
        if not is_applicable(spec, entry):
            continue
        if spec.key == "ctx":
            value: object = entry.ctx
        elif spec.key == "ngl":
            value = entry.ngl
        else:
            value = spec.default
        if spec.key in entry_param_defaults:
            value = entry_param_defaults[spec.key]
        if spec.key in entry_overrides:
            value = entry_overrides[spec.key]
        out[spec.key] = value
    return out


def _spec_consumes_token(spec: ParamSpec, token: str) -> bool:
    """True if `token` could be the flag/start-of-flag claimed by spec."""
    return token in spec.cli_flags


def _strip_managed_flags(
    args: list[str], specs_to_strip: list[ParamSpec]
) -> list[str]:
    """Remove every token claimed by any spec in `specs_to_strip`.

    Value-flags (pattern contains "{value}") consume 2 tokens.
    Multi-token bool patterns like "-fa on" consume 2 tokens.
    Single-token bool flags (e.g. "--cpu-moe") consume 1 token.
    """
    # Build a map: claimed-flag-token -> how many tokens to drop.
    drop_count: dict[str, int] = {}
    for spec in specs_to_strip:
        if not spec.extra_args_pattern or not spec.cli_flags:
            continue
        pattern = spec.extra_args_pattern
        if "{value}" in pattern:
            consume = 2
        else:
            # Bool flag. May be single-token ("--mlock") or multi-token
            # ("-fa on"). Count tokens in the pattern.
            consume = len(pattern.split())
        for flag in spec.cli_flags:
            drop_count[flag] = consume
    out: list[str] = []
    i = 0
    while i < len(args):
        tok = args[i]
        if tok in drop_count:
            i += drop_count[tok]
            continue
        out.append(tok)
        i += 1
    return out


def _render_param(spec: ParamSpec, value: object) -> list[str]:
    """Render a single param's CLI tokens for the merged args list."""
    if not spec.extra_args_pattern:
        return []
    if spec.kind == "bool":
        return spec.extra_args_pattern.split() if bool(value) else []
    if "{value}" in spec.extra_args_pattern:
        flag, _, _ = spec.extra_args_pattern.partition(" {value}")
        return [flag, str(value)]
    # Single-token flag without {value}; only emit if truthy.
    return [spec.extra_args_pattern] if value else []


def merge_extra_args(entry: ModelEntry, entry_overrides: dict) -> list[str]:
    """Apply overrides to `entry.extra_args` and return the merged list.

    Strategy: for every overridden knob that maps to CLI tokens, strip its
    flag (and value, if any) from the baseline, then append the rendered
    override at the end. This keeps all UNTOUCHED baseline flags exactly
    as they were (preserving order, sentinel flags like "-a Qwen3.6-…",
    "-Cr 0-15", etc), so the byte-identical guarantee holds for any flag
    we do not manage.
    """
    if not entry_overrides:
        return list(entry.extra_args)
    touched_specs: list[ParamSpec] = []
    for key in entry_overrides:
        spec = _spec_by_key(key)
        if spec is None:
            continue
        if spec.extra_args_pattern is None:
            continue  # ctx/ngl handled at top-level
        if not is_applicable(spec, entry):
            continue
        touched_specs.append(spec)
    stripped = _strip_managed_flags(list(entry.extra_args), touched_specs)
    appended: list[str] = []
    for spec in touched_specs:
        try:
            value = validate_value(spec, entry_overrides[spec.key])
        except ValueError:
            continue  # invalid → fall back to baseline (already stripped)
        appended.extend(_render_param(spec, value))
    return stripped + appended


def build_extra_args(entry: ModelEntry, effective: dict) -> list[str]:
    """Render the full set of effective params to a CLI args list.

    Used by tests and the UI preview to show what would be passed to
    llama-server if every applicable knob were set by the user. Does NOT
    preserve baseline-only flags (sentinels, -Cr, -a, etc.) — that is the
    job of `merge_extra_args`, which is what set_active actually uses.
    """
    out: list[str] = []
    for spec in SCHEMA:
        if not is_applicable(spec, entry):
            continue
        if spec.extra_args_pattern is None:
            continue
        if spec.key not in effective:
            continue
        out.extend(_render_param(spec, effective[spec.key]))
    return out


def write_active(entry: ModelEntry, overrides: dict | None = None) -> Path:
    """Write active_model.json atomically (tmp + rename) so a partial write
    can never poison the wrapper. Does NOT restart llama-server.

    When `overrides` is None we still load the on-disk overrides file so
    activating an entry from any code path picks up the user's tweaks.
    Pass `overrides={}` explicitly to force a baseline (no-overrides) write.
    """
    if overrides is None:
        overrides = load_overrides()
    p = active_model_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(_entry_to_active_dict(entry, overrides), indent=2))
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
    "build_extra_args",
    "by_id",
    "catalog",
    "catalog_status",
    "download",
    "effective_params",
    "expected_paths",
    "get_active_id",
    "is_installed",
    "load_overrides",
    "merge_extra_args",
    "model_dir",
    "models_dir",
    "overrides_path",
    "read_active",
    "save_overrides",
    "set_active",
    "wait_for_llama_health",
    "write_active",
]
