"""Pure classifier for previewing autonomous (self-improve) changes.

Given a git patch, decide whether the change is *internal* (logic/tests only),
*external* (touches a rendered/frontend surface), or *ambiguous* (touches the
dashboard handler module without a clear render signal, so the UI should offer
both a code view and a rendered view).

Pure: no I/O, no config, no subprocess. Never raises — a garbage or empty
patch degrades to ``internal`` with no external paths.
"""

from __future__ import annotations

import logging
import os
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path

from axi.self_improve import changed_paths_from_patch

__all__ = ["classify_patch", "preview_run", "stop_preview"]

log = logging.getLogger("axi.dev_preview")

# Path segments that mark a frontend / rendered surface. Matched robustly so a
# path counts whether or not the diff reports the ``axi/src/axi/`` prefix
# (mirrors the endswith-style matching of ``violates_dev_engine_guard``).
_EXTERNAL_PREFIXES: tuple[str, ...] = (
    "axi/src/axi/templates/",
    "axi/src/axi/static/",
)
# Suffix fragments to catch paths reported without the repo prefix.
_EXTERNAL_SEGMENTS: tuple[str, ...] = (
    "src/axi/templates/",
    "src/axi/static/",
    "templates/",
    "static/",
)

# Signals in a dashboard.py patch body that mean it changes a rendered page.
_RENDER_SIGNALS: tuple[str, ...] = ("TemplateResponse", "HTMLResponse", '.html"', ".html'")


def _norm(path: str) -> str:
    return str(path or "").replace("\\", "/").lstrip("./")


def _is_external_path(path: str) -> bool:
    norm = _norm(path)
    if any(norm.startswith(p) for p in _EXTERNAL_PREFIXES):
        return True
    return any(seg in norm for seg in _EXTERNAL_SEGMENTS)


def _touches_dashboard(path: str) -> bool:
    norm = _norm(path)
    return norm == "dashboard.py" or norm.endswith("/dashboard.py")


def _patch_body_lines(patch_text: str) -> list[str]:
    """Return added/removed content lines, excluding the +++/--- file headers."""
    out: list[str] = []
    for line in (patch_text or "").splitlines():
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("+") or line.startswith("-"):
            out.append(line)
    return out


def classify_patch(patch_text: str) -> dict:
    """Classify a git patch for autonomous-change preview.

    Returns ``{"kind", "external_paths", "reason"}`` where ``kind`` is one of
    ``"internal" | "external" | "ambiguous"``. Pure and total — never raises.
    """
    try:
        changed = changed_paths_from_patch(patch_text or "")
    except Exception:  # noqa: BLE001 — classifier must never raise
        changed = []

    external_paths = [p for p in changed if _is_external_path(p)]
    if external_paths:
        return {
            "kind": "external",
            "external_paths": external_paths,
            "reason": "Toca templates/ o static/",
        }

    if any(_touches_dashboard(p) for p in changed):
        body = "\n".join(_patch_body_lines(patch_text or ""))
        if any(sig in body for sig in _RENDER_SIGNALS):
            return {
                "kind": "external",
                "external_paths": [],
                "reason": "Cambia un handler que renderiza una página",
            }
        return {
            "kind": "ambiguous",
            "external_paths": [],
            "reason": "dashboard.py tocado sin señal de render — se ofrecen ambas vistas",
        }

    return {
        "kind": "internal",
        "external_paths": [],
        "reason": "Solo lógica/tests internos",
    }


# ===========================================================================
# Phase 2: ephemeral preview orchestrator
#
# Materialize a dev run's patch into a THROWAWAY worktree, launch an isolated
# dashboard instance from it, and hand back a URL. Everything is torn down on
# stop — no orphaned worktree or systemd unit on any path.
#
# Only ONE preview is kept alive at a time in this phase (previewing a
# different run tears the prior one down first). Full concurrency/TTL is a
# later phase.
# ===========================================================================

# run_id -> {worktree, branch, tmp_parent, repo, instance_id, unit, port, url}
# _LOCK guards the quick registry dict reads/writes (the dashboard serves from a
# thread pool). _OP_LOCK serializes the WHOLE preview_run / stop_preview body so
# the locate→create→apply→start→register sequence is atomic w.r.t. other preview
# ops — a double-click or two tabs can never each spin up an untracked worktree
# + systemd unit. Preview is a rare human action, so serializing is correct and
# matches the "one preview at a time" invariant. Lock order is always
# _OP_LOCK → _LOCK (never the reverse), so no deadlock.
_PREVIEWS: dict[str, dict] = {}
_LOCK = threading.Lock()
_OP_LOCK = threading.Lock()


def _default_apply_patch(worktree_path: str, patch_path) -> tuple[bool, str]:
    """Apply a patch into the worktree index, with a --3way fallback.

    Mirrors the apply sequence in ``dev_land._land_run``. Returns (ok, error).
    """
    result = subprocess.run(
        ["git", "apply", "--index", str(patch_path)],
        cwd=worktree_path, capture_output=True, text=True,
    )
    if result.returncode != 0:
        result = subprocess.run(
            ["git", "apply", "--3way", str(patch_path)],
            cwd=worktree_path, capture_output=True, text=True,
        )
        if result.returncode != 0:
            return False, result.stderr.strip()
    return True, ""


def _teardown_entry(entry: dict, *, stop_fn, cleanup_fn) -> None:
    """Stop the instance and remove the worktree + branch for one entry.

    Best-effort on every step — never raises, so teardown always completes.
    Stops by the EXACT unit name that start returned and stored (``entry["unit"]``),
    never a recomputed prefix, so teardown can't drift from what was launched."""
    try:
        stop_fn(entry["unit"])
    except Exception as exc:  # noqa: BLE001
        log.info("preview teardown: stop failed for %s (%s)", entry.get("unit"), exc)
    try:
        cleanup_fn(entry["repo"], entry["worktree"], entry["branch"], entry["tmp_parent"])
    except Exception as exc:  # noqa: BLE001
        log.info("preview teardown: worktree cleanup failed (%s)", exc)


def _teardown_all(*, stop_fn, cleanup_fn) -> None:
    """Tear down every active preview and clear the registry."""
    with _LOCK:
        entries = list(_PREVIEWS.values())
        _PREVIEWS.clear()
    for entry in entries:
        _teardown_entry(entry, stop_fn=stop_fn, cleanup_fn=cleanup_fn)


def preview_run(
    run_id: str,
    *,
    create_worktree=None,
    apply_patch=None,
    start_instance_fn=None,
    cleanup_fn=None,
    stop_fn=None,
    config_mod=None,
) -> dict:
    """Preview a dev run's patch in an ephemeral, isolated dashboard instance.

    Locates the run's newest ``<run_id>-*.patch``, creates a throwaway worktree
    based on the dev repo (so it contains both ``axi/`` and ``lifeos/`` for
    PYTHONPATH), applies the patch, and launches an isolated instance from it.

    Idempotent: if this run already has a live preview, returns it unchanged.
    Only one preview lives at a time — a different active preview is torn down
    first. On any failure the worktree is cleaned up; nothing is orphaned.

    Returns ``{"ok": True, "url", "port", "run_id"}`` or
    ``{"ok": False, "error"}``. Never raises.
    """
    from axi import dev_director, dev_env_instance  # noqa: PLC0415
    from axi import config as _config  # noqa: PLC0415

    create_worktree = create_worktree or dev_director._create_worktree  # noqa: SLF001
    apply_patch = apply_patch or _default_apply_patch
    start_instance_fn = start_instance_fn or dev_env_instance.start_instance_for_worktree
    cleanup_fn = cleanup_fn or dev_director._cleanup_worktree  # noqa: SLF001
    stop_fn = stop_fn or dev_env_instance.stop_unit
    cfg = config_mod or _config

    # Serialize the entire operation: two concurrent calls (double-click, two
    # tabs, retry) must never both create a worktree + launch an instance.
    with _OP_LOCK:
        # Idempotent: a live preview for this exact run is returned as-is.
        with _LOCK:
            existing = _PREVIEWS.get(run_id)
        if existing:
            return {
                "ok": True, "url": existing["url"], "port": existing["port"],
                "run_id": run_id, "already": True,
            }

        # Locate + validate the requested run's patch FIRST, BEFORE retiring any
        # prior preview — a stale/invalid run_id must not tear down a good one.
        results_dir = Path(os.path.expanduser(
            cfg.get("dev_director_results_dir", "~/LifeOS/dev-results")
        ))
        patches = sorted(results_dir.glob(f"{run_id}-*.patch")) if results_dir.exists() else []
        if not patches or patches[-1].stat().st_size == 0:
            return {"ok": False, "error": "no patch for run"}
        patch_path = patches[-1]

        # Target is known-good → now retire any OTHER active preview (one at a time).
        _teardown_all(stop_fn=stop_fn, cleanup_fn=cleanup_fn)

        repo = os.path.expanduser(cfg.get("dev_director_repo", "~/LifeOS/lifeos"))
        tmp_parent = tempfile.mkdtemp(prefix="axi-preview-wt-")
        worktree_path = os.path.join(tmp_parent, f"axi-preview-{run_id[:12]}")
        branch = f"axi/preview/{run_id}"

        ok, err = create_worktree(repo, worktree_path, branch)
        if not ok:
            # Worktree was never registered — just drop the temp dir.
            shutil.rmtree(tmp_parent, ignore_errors=True)
            return {"ok": False, "error": f"could not create worktree: {err}"}

        ok, err = apply_patch(worktree_path, patch_path)
        if not ok:
            cleanup_fn(repo, worktree_path, branch, tmp_parent)
            return {"ok": False, "error": "patch did not apply"}

        res = start_instance_fn(run_id, worktree_path)
        if not res.get("ok"):
            cleanup_fn(repo, worktree_path, branch, tmp_parent)
            return {"ok": False, "error": res.get("error", "instance start failed")}

        inst = res["instance"]
        entry = {
            "worktree": worktree_path,
            "branch": branch,
            "tmp_parent": tmp_parent,
            "repo": repo,
            "instance_id": run_id,
            "unit": inst.get("unit"),
            "port": inst.get("port"),
            "url": inst.get("url"),
        }
        with _LOCK:
            _PREVIEWS[run_id] = entry
        return {"ok": True, "url": inst.get("url"), "port": inst.get("port"), "run_id": run_id}


def stop_preview(run_id: str, *, stop_fn=None, cleanup_fn=None) -> dict:
    """Stop a run's preview: kill the instance, remove the worktree + branch,
    drop the registry entry. Idempotent (unknown run_id → no-op). Never raises.
    """
    from axi import dev_director, dev_env_instance  # noqa: PLC0415

    stop_fn = stop_fn or dev_env_instance.stop_unit
    cleanup_fn = cleanup_fn or dev_director._cleanup_worktree  # noqa: SLF001

    with _OP_LOCK:
        with _LOCK:
            entry = _PREVIEWS.pop(run_id, None)
        if entry is None:
            return {"ok": True}
        _teardown_entry(entry, stop_fn=stop_fn, cleanup_fn=cleanup_fn)
        return {"ok": True}
