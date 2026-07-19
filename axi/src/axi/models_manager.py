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
# VibeThinker-3B reasoning sibling (port 8082, managed by llama-vt.service).
LLAMA_VT_HEALTH_URL = "http://127.0.0.1:8082/health"
LEGACY_QWEN_ID = "qwen36-35b-a3b"
LEGACY_QWEN_DIR_NAME = "Qwen3.6-35B-A3B"

# ───────────── per-task role_configs snapshot (from the model audit) ─────────
#
# The bench harness measures, PER TASK (role), the best sampling+thinking
# config for each model and stores it in each audit row's
# ``recipe.role_configs``. When a model is set active we snapshot ITS
# role_configs into active_model.json so brain.py can route every internal job
# to its best measured config with zero runtime classification. This is a
# READ of scripts/bench/results/model_audit.jsonl (never a write).

# Hardware/VRAM tier whose measured configs we snapshot (the laptop's tier).
_AUDIT_TIER = "vram12"

# Catalog entry id → audit label, for the few ids that differ from the label
# the bench harness records (most match verbatim).
_AUDIT_LABEL_BY_ID: dict[str, str] = {
    "gemma4-e2b-it": "gemma4-e2b",
    "qwen36-35b-a3b": "qwen36-35b",
}


def _audit_label(entry_id: str) -> str:
    """Map a catalog entry id to its model-audit label."""
    return _AUDIT_LABEL_BY_ID.get(entry_id, entry_id)


def role_configs_for(entry_id: str, tier: str = _AUDIT_TIER) -> dict:
    """Return the measured ``role_configs`` for ``entry_id`` at ``tier``, or {}.

    Read-only best-effort snapshot source: reads the audit jsonl via
    :mod:`axi.bench_audit`. Prefers the requested ``tier`` but falls back to any
    tier that carries role_configs for the same label, so a model measured only
    on another tier still routes. Never raises — missing data yields ``{}`` and
    the brain simply keeps its engine defaults.
    """
    try:
        from axi import bench_audit  # lazy: read-only audit access
        rows = bench_audit.load_audit_rows(
            bench_audit.results_dir() / "model_audit.jsonl"
        )
        label = _audit_label(entry_id)

        def _rc(row: dict) -> dict | None:
            recipe = row.get("recipe")
            if not isinstance(recipe, dict):
                return None
            rc = recipe.get("role_configs")
            return rc if isinstance(rc, dict) and rc else None

        # Preferred tier first.
        for row in rows:
            if row.get("label") == label and row.get("tier") == tier:
                rc = _rc(row)
                if rc:
                    return rc
        # Any tier with role_configs for this label.
        for row in rows:
            if row.get("label") == label:
                rc = _rc(row)
                if rc:
                    return rc
    except Exception:  # noqa: BLE001 — snapshot is best-effort, never fatal
        log.warning("role_configs snapshot failed for %s", entry_id, exc_info=True)
    return {}


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


def active_vt_model_path() -> Path:
    """Path to the active VT (VibeThinker-3B) state file.

    Mirrors active_model_path() but for the reasoning sibling (port 8082).
    Written by write_active_vt(); read by axi-vt-launch on start.
    """
    return _state_dir() / "active_vt_model.json"


def read_active_vt() -> dict | None:
    """Read active_vt_model.json; returns None if missing or corrupt."""
    p = active_vt_model_path()
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def get_active_vt_id() -> str | None:
    """Return the id field from active_vt_model.json, or None."""
    data = read_active_vt()
    return data.get("id") if data else None


def write_active_vt(entry: ModelEntry) -> Path:
    """Write active_vt_model.json atomically (tmp + rename).

    Mirrors write_active() but targets the VT state file (port 8082).
    Does NOT restart llama-vt.service — the caller owns the restart.
    """
    paths = expected_paths(entry)
    out: dict = {
        "id": entry.id,
        "gguf": str(paths["gguf"]),
        "ctx": entry.ctx,
        "ngl": entry.ngl,
        "port": 8082,
        "extra_args": list(entry.extra_args),
    }
    # mmproj is optional; VibeThinker-3B has none.
    if "mmproj" in paths:
        out["mmproj"] = str(paths["mmproj"])
    # Consistency with the primary brain: snapshot the VT model's measured
    # per-task configs too (additive; empty audit → key omitted).
    role_configs = role_configs_for(entry.id)
    if role_configs:
        out["role_configs"] = role_configs
    p = active_vt_model_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(out, indent=2))
    tmp.replace(p)
    return p


def is_triad_active() -> bool:
    """Return True when the primary brain (port 8080) is qwen35-4b.

    The primary (active_model.json) is the single source of truth for which
    brain-set is resident. VT presence is a consequence of 4B being primary,
    not an independent fact — so we only check the primary id.

    Design decision (from sdd/brain-triad/design §1.4):
      EXACT logic = get_active_id() == "qwen35-4b".
      We do NOT also require active_vt_model.json to exist (that file is
      auto-created by axi-vt-launch on first VT start; requiring it would
      make this predicate flaky during transitions).
    """
    return get_active_id() == "qwen35-4b"


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
    # Snapshot this model's per-task measured configs so brain.py can route
    # each internal job to its best sampling+thinking. Additive: only present
    # when the audit actually has role_configs for the entry (byte-identical
    # for entries the audit never measured).
    role_configs = role_configs_for(entry.id)
    if role_configs:
        out["role_configs"] = role_configs
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

    from huggingface_hub import hf_hub_download, get_hf_file_metadata, hf_hub_url  # local import → testable
    import threading
    import time as _time

    dest = model_dir(entry)
    dest.mkdir(parents=True, exist_ok=True)
    total = len(entry.files)
    token = os.environ.get("HF_TOKEN")

    def _expected_size(f: ModelFile) -> int | None:
        """Fetch the file size from HF so we can show real % progress.
        Returns None if unknown — progress stays at 0% during that file."""
        try:
            url = hf_hub_url(repo_id=f.repo_id, filename=f.filename)
            meta = get_hf_file_metadata(url=url, token=token)
            return meta.size
        except Exception:  # noqa: BLE001
            return None

    for idx, f in enumerate(entry.files):
        out_path = expected_path(entry, f)
        if out_path.exists():
            if progress_cb:
                progress_cb(idx + 1, total, 100.0)
            continue
        if progress_cb:
            progress_cb(idx, total, 0.0)

        expected_size = _expected_size(f)

        # Spawn hf_hub_download in a worker thread so we can poll the
        # incomplete file's size on disk and fire progress_cb with real %.
        result: dict = {"path": None, "error": None}
        def _worker() -> None:
            try:
                result["path"] = hf_hub_download(
                    repo_id=f.repo_id,
                    filename=f.filename,
                    local_dir=str(dest),
                    token=token,
                )
            except Exception as e:  # noqa: BLE001
                result["error"] = e
        t = threading.Thread(target=_worker, daemon=True)
        t.start()

        # Poll the .incomplete file that huggingface_hub writes during
        # download. With `local_dir=...`, hf_hub_download stages the file
        # at `{dest}/.cache/huggingface/download/<sha>.incomplete` and
        # moves it to its final path only when complete. The sha is not
        # predictable, so we just glob the staging dir for the largest
        # .incomplete file and use that as our denominator.
        staging_dir = dest / ".cache" / "huggingface" / "download"
        while t.is_alive():
            _time.sleep(1.0)
            if expected_size and progress_cb:
                size_now = 0
                # 1) staging .incomplete (most common during active download)
                try:
                    if staging_dir.is_dir():
                        for p in staging_dir.glob("*.incomplete"):
                            try:
                                size_now = max(size_now, p.stat().st_size)
                            except OSError:
                                pass
                except OSError:
                    pass
                # 2) final filename (post-rename, before next iter)
                for cand in (out_path, dest / f.filename):
                    try:
                        if cand.exists():
                            size_now = max(size_now, cand.stat().st_size)
                    except OSError:
                        pass
                pct = min(99.5, 100.0 * size_now / expected_size) if size_now else 0.0
                progress_cb(idx, total, pct)
        t.join()

        if result["error"] is not None:
            log.exception("hf_hub_download failed for %s/%s",
                          f.repo_id, f.filename)
            raise result["error"]

        # hf_hub_download returns the final path; if it differs from where
        # we expect (e.g. dest_relname rename), copy/symlink into place.
        final = Path(result["path"])
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
    from axi import obs
    obs.managed_systemctl(
        "restart", "llama-server.service",
        caller="models_manager.set_active",
        reason="brain swap",
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
    "LLAMA_HEALTH_URL",
    "LLAMA_VT_HEALTH_URL",
    "active_model_path",
    "active_vt_model_path",
    "build_extra_args",
    "by_id",
    "catalog",
    "catalog_status",
    "download",
    "effective_params",
    "expected_paths",
    "get_active_id",
    "get_active_vt_id",
    "is_installed",
    "is_triad_active",
    "load_overrides",
    "merge_extra_args",
    "model_dir",
    "models_dir",
    "overrides_path",
    "read_active",
    "read_active_vt",
    "role_configs_for",
    "save_overrides",
    "set_active",
    "wait_for_llama_health",
    "write_active",
    "write_active_vt",
]


# ────────────────────────── CLI (for shell scripts) ────────────────


def _cli_main() -> None:
    """Minimal scriptable CLI used by axi-game-on / axi-game-off.

    Subcommands:
      get-active           Print current active model id to stdout (empty line if
                           none set). Exit 0.
      set-active <id>      Write active_model.json for the given catalog id WITHOUT
                           restarting llama-server (the caller owns the restart).
                           Exit 0 on success, 1 if id unknown in catalog.

    Usage (from scripts):
      python -m axi.models_manager get-active
      python -m axi.models_manager set-active gemma4-e2b-it
    """
    import sys

    args = sys.argv[1:]
    if not args:
        print("usage: python -m axi.models_manager <get-active|set-active> [id]",
              file=sys.stderr)
        sys.exit(1)

    subcmd = args[0]

    if subcmd == "get-active":
        current = get_active_id()
        print(current or "")
        sys.exit(0)

    elif subcmd == "set-active":
        if len(args) < 2:
            print("set-active requires a model id", file=sys.stderr)
            sys.exit(1)
        model_id = args[1]
        entry = by_id(model_id)
        if entry is None:
            print(f"error: model id '{model_id}' not found in catalog", file=sys.stderr)
            sys.exit(1)
        if not is_installed(entry):
            print(f"error: model '{model_id}' is not installed on disk; download it first",
                  file=sys.stderr)
            sys.exit(1)
        # write_active loads on-disk overrides automatically (overrides=None path).
        # Does NOT restart llama-server — the caller (game scripts) owns the restart.
        write_active(entry)
        print(f"active model set to: {model_id}")
        sys.exit(0)

    else:
        print(f"unknown subcommand: {subcmd}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    _cli_main()
