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
import re
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from axi.self_improve import changed_paths_from_patch

__all__ = [
    "classify_patch",
    "cleanup_orphans",
    "is_valid_run_id",
    "preview_run",
    "reap_expired",
    "stop_preview",
]

log = logging.getLogger("axi.dev_preview")

# Server-generated run_ids are strftime("%Y%m%d-%H%M%S") + "-" + uuid4().hex[:6]
# (see dev_run._run_id). Anything else must be rejected BEFORE a client-supplied
# run_id flows into a git branch name, a worktree path, or a systemd unit name —
# no path traversal (../), no shell/git metacharacters, no wrong shape.
_RUN_ID_RE = re.compile(r"^\d{8}-\d{6}-[0-9a-f]{6}$")


def is_valid_run_id(run_id) -> bool:
    """True only if ``run_id`` matches the exact server-generated shape.

    Security gate: endpoints MUST reject a non-matching id with HTTP 400 before
    it reaches ``preview_run`` / ``stop_preview`` (branch / worktree / unit name).
    """
    return isinstance(run_id, str) and _RUN_ID_RE.match(run_id) is not None

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
            # Wall-clock birth time — the TTL reaper ages the preview from here.
            "started_at": time.time(),
        }
        with _LOCK:
            _PREVIEWS[run_id] = entry
    # Lazily arm the background TTL reaper on the first successful preview —
    # outside _OP_LOCK so a slow start never blocks the operation.
    _start_reaper()
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


# ===========================================================================
# Phase 4: hardening
#
# (1) TTL auto-teardown — a forgotten or crashed preview can't leak a worktree
#     + running systemd unit forever. A background daemon reaper ages each
#     preview from its ``started_at`` and tears down anything past the TTL.
# (2) Startup orphan cleanup — a crash/restart of THIS process leaves the
#     registry empty but the systemd unit + worktree still around. On dashboard
#     startup we sweep any ``axi-preview-inst-*`` unit and ``axi/preview/*``
#     worktree/branch left behind by a previous process.
# ===========================================================================

# Default max lifetime of a preview instance before it is auto-stopped. Mirrors
# the config default in config_schema.py (``dev_preview_ttl_s`` = 1800).
_DEFAULT_TTL_S = 1800

# Systemd unit prefix and git branch prefix that mark an ephemeral preview.
# Kept in sync with start_instance_for_worktree(unit_prefix="axi-preview-inst")
# and the branch name computed in preview_run ("axi/preview/<run_id>").
_UNIT_PREFIX = "axi-preview-inst"
_BRANCH_PREFIX = "axi/preview/"
# The throwaway worktree lives inside a tempfile dir named "axi-preview-wt-*"
# (tempfile.mkdtemp(prefix="axi-preview-wt-")); the worktree dir itself is
# "axi-preview-<run_id[:12]>".
_WT_PARENT_PREFIX = "axi-preview-wt-"
_WT_DIR_PREFIX = "axi-preview-"

# Reaper wiring. The thread is lazy (armed on first preview_run), idempotent to
# start, and a daemon so it never blocks interpreter shutdown. Tests set
# _REAPER_ENABLED = False and exercise reap_expired() directly.
_REAPER_ENABLED = True
_reaper_thread: threading.Thread | None = None
_reaper_lock = threading.Lock()
_reaper_stop = threading.Event()


def _current_ttl() -> int:
    """Configured preview TTL in seconds, degrading to the default on any error."""
    try:
        from axi import config as _config  # noqa: PLC0415

        return int(_config.get("dev_preview_ttl_s", _DEFAULT_TTL_S))
    except Exception:  # noqa: BLE001
        return _DEFAULT_TTL_S


def reap_expired(*, now=None, ttl=None, stop_fn=None, cleanup_fn=None) -> list[str]:
    """Tear down and drop every preview older than the TTL; return reaped run_ids.

    Ages each entry from its ``started_at`` against ``ttl`` (both injectable for
    tests; defaults read ``time.time()`` and the ``dev_preview_ttl_s`` config).
    Runs under ``_OP_LOCK`` so it never interleaves with preview_run/stop_preview.
    Best-effort — teardown of one entry never blocks reaping the rest.
    """
    from axi import dev_director, dev_env_instance  # noqa: PLC0415

    stop_fn = stop_fn or dev_env_instance.stop_unit
    cleanup_fn = cleanup_fn or dev_director._cleanup_worktree  # noqa: SLF001
    if now is None:
        now = time.time()
    if ttl is None:
        ttl = _current_ttl()

    reaped: list[str] = []
    with _OP_LOCK:
        with _LOCK:
            expired = [
                (rid, entry)
                for rid, entry in _PREVIEWS.items()
                if now - float(entry.get("started_at", now)) > ttl
            ]
            for rid, _entry in expired:
                _PREVIEWS.pop(rid, None)
        for rid, entry in expired:
            _teardown_entry(entry, stop_fn=stop_fn, cleanup_fn=cleanup_fn)
            reaped.append(rid)
    if reaped:
        log.info("preview reaper: tore down expired previews %s (ttl=%ss)", reaped, ttl)
    return reaped


def _reaper_loop() -> None:
    """Wake periodically and reap expired previews. Never raises out."""
    while not _reaper_stop.is_set():
        interval = max(1, min(60, _current_ttl()))
        if _reaper_stop.wait(interval):
            break
        try:
            reap_expired()
        except Exception as exc:  # noqa: BLE001 — the reaper must never die
            log.info("preview reaper: reap_expired failed (%s)", exc)


def _start_reaper() -> None:
    """Start the background TTL reaper once. Idempotent; never raises out."""
    global _reaper_thread
    if not _REAPER_ENABLED:
        return
    try:
        with _reaper_lock:
            if _reaper_thread is not None and _reaper_thread.is_alive():
                return
            _reaper_stop.clear()
            _reaper_thread = threading.Thread(
                target=_reaper_loop, name="axi-preview-reaper", daemon=True
            )
            _reaper_thread.start()
    except Exception as exc:  # noqa: BLE001
        log.info("preview reaper: failed to start (%s)", exc)


# --- startup orphan cleanup -------------------------------------------------


def _default_list_preview_units() -> list[str]:
    """Return systemd --user unit names matching the preview prefix. Best-effort."""
    names: set[str] = set()
    for args in (
        ["systemctl", "--user", "list-units", "--all", "--no-legend", "--plain",
         f"{_UNIT_PREFIX}-*"],
        ["systemctl", "--user", "list-unit-files", "--no-legend", "--plain",
         f"{_UNIT_PREFIX}-*"],
    ):
        try:
            res = subprocess.run(args, capture_output=True, text=True, timeout=15)
        except Exception:  # noqa: BLE001
            continue
        for line in (res.stdout or "").splitlines():
            parts = line.split()
            if parts and parts[0].startswith(_UNIT_PREFIX):
                names.add(parts[0])
    return sorted(names)


def _default_list_preview_worktrees(repo: str) -> list[dict]:
    """Parse ``git worktree list --porcelain`` into [{path, branch}]. Best-effort."""
    out: list[dict] = []
    try:
        res = subprocess.run(
            ["git", "-C", repo, "worktree", "list", "--porcelain"],
            capture_output=True, text=True, timeout=15,
        )
    except Exception:  # noqa: BLE001
        return out
    cur: dict | None = None
    for line in (res.stdout or "").splitlines():
        if line.startswith("worktree "):
            if cur is not None:
                out.append(cur)
            cur = {"path": line[len("worktree "):].strip(), "branch": ""}
        elif line.startswith("branch ") and cur is not None:
            ref = line[len("branch "):].strip()
            cur["branch"] = ref.replace("refs/heads/", "")
    if cur is not None:
        out.append(cur)
    return out


def _default_remove_worktree(repo: str, path: str) -> None:
    subprocess.run(
        ["git", "-C", repo, "worktree", "remove", "--force", path],
        capture_output=True, timeout=15,
    )


def _default_delete_branch(repo: str, branch: str) -> None:
    subprocess.run(
        ["git", "-C", repo, "branch", "-D", branch],
        capture_output=True, timeout=15,
    )


def _is_preview_worktree(path: str, branch: str) -> bool:
    if branch.startswith(_BRANCH_PREFIX):
        return True
    base = os.path.basename(path.rstrip("/"))
    return base.startswith(_WT_DIR_PREFIX)


def cleanup_orphans(
    *,
    list_units_fn=None,
    stop_fn=None,
    list_worktrees_fn=None,
    remove_worktree_fn=None,
    delete_branch_fn=None,
    rmtree_fn=None,
    repo=None,
    config_mod=None,
) -> dict:
    """Tear down preview artifacts left behind by a previous process.

    Stops every ``axi-preview-inst-*`` systemd user unit and removes every
    ``axi/preview/*`` worktree + branch (plus the ``axi-preview-wt-*`` temp
    parents). Every I/O dependency is injectable for unit tests. Best-effort:
    never raises, returns ``{units_stopped, worktrees_removed, branches_deleted}``.
    """
    from axi import dev_env_instance  # noqa: PLC0415

    list_units_fn = list_units_fn or _default_list_preview_units
    stop_fn = stop_fn or dev_env_instance.stop_unit
    list_worktrees_fn = list_worktrees_fn or _default_list_preview_worktrees
    remove_worktree_fn = remove_worktree_fn or _default_remove_worktree
    delete_branch_fn = delete_branch_fn or _default_delete_branch
    rmtree_fn = rmtree_fn or (lambda p: shutil.rmtree(p, ignore_errors=True))
    if repo is None:
        try:
            from axi import config as _config  # noqa: PLC0415

            cfg = config_mod or _config
            repo = os.path.expanduser(cfg.get("dev_director_repo", "~/LifeOS/lifeos"))
        except Exception:  # noqa: BLE001
            repo = os.path.expanduser("~/LifeOS/lifeos")

    units_stopped = 0
    worktrees_removed = 0
    branches_deleted = 0

    # (a) systemd units
    try:
        units = list_units_fn() or []
    except Exception:  # noqa: BLE001
        units = []
    for unit in units:
        if not isinstance(unit, str) or not unit.startswith(_UNIT_PREFIX):
            continue
        try:
            stop_fn(unit)
            units_stopped += 1
        except Exception as exc:  # noqa: BLE001
            log.info("cleanup_orphans: stop failed for %s (%s)", unit, exc)

    # (b) worktrees / branches / temp parents
    try:
        worktrees = list_worktrees_fn(repo) or []
    except Exception:  # noqa: BLE001
        worktrees = []
    tmp_parents: set[str] = set()
    for wt in worktrees:
        try:
            path = str(wt.get("path") or "")
            branch = str(wt.get("branch") or "")
        except Exception:  # noqa: BLE001
            continue
        if not path or not _is_preview_worktree(path, branch):
            continue
        try:
            remove_worktree_fn(repo, path)
            worktrees_removed += 1
        except Exception as exc:  # noqa: BLE001
            log.info("cleanup_orphans: worktree remove failed for %s (%s)", path, exc)
        if branch.startswith(_BRANCH_PREFIX):
            try:
                delete_branch_fn(repo, branch)
                branches_deleted += 1
            except Exception as exc:  # noqa: BLE001
                log.info("cleanup_orphans: branch delete failed for %s (%s)", branch, exc)
        parent = os.path.dirname(path.rstrip("/"))
        if os.path.basename(parent).startswith(_WT_PARENT_PREFIX):
            tmp_parents.add(parent)

    for parent in tmp_parents:
        try:
            rmtree_fn(parent)
        except Exception as exc:  # noqa: BLE001
            log.info("cleanup_orphans: rmtree failed for %s (%s)", parent, exc)

    summary = {
        "units_stopped": units_stopped,
        "worktrees_removed": worktrees_removed,
        "branches_deleted": branches_deleted,
    }
    if any(summary.values()):
        log.info("cleanup_orphans swept previous-process preview artifacts: %s", summary)
    return summary
