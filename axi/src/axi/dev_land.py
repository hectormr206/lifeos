"""Landing gate for Axi self-build dev runs.

Applies a completed run's patch to an isolated branch and pushes it to origin
for human review.  This module is the ONLY place that interacts with git push.

SAFETY CONTRACT (never violated):
- Never touches the live working tree or the currently-checked-out branch.
- Never merges to main / master / any running branch.
- Never restarts services (systemctl, uvicorn, etc.).
- Only pushes a NEW review branch `axi/land/<run_id>` to origin.
  The local worktree + branch are deleted immediately after push.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from axi import config
from axi import dev_run as _dr
from axi import self_improve as _si
from axi.dev_director import _cleanup_worktree, _create_worktree


def _log_outcome(state: dict, *, status: str, changed_paths=None,
                 guard_blocked: bool = False) -> None:
    """Best-effort JSONL outcome log for self-improve-origin runs only."""
    if state.get("origin") != "self_improve":
        return
    try:
        state_dir = os.path.expanduser(
            config.get("dev_run_state_dir", "~/LifeOS/dev-runs")
        )
        _si.append_outcome_log(
            state_dir,
            _si.build_outcome_record(
                run_id=state.get("run_id", ""),
                started_at=state.get("started_at"),
                goal=state.get("goal", ""),
                status=status,
                changed_paths=changed_paths,
                guard_blocked=guard_blocked,
            ),
        )
    except Exception:  # noqa: BLE001
        pass


def land_run(run_id: str) -> dict:
    """Apply the patch for a done dev run to an isolated branch and push to origin.

    Returns a dict with ``ok`` (bool), plus ``branch`` and ``pushed`` on success,
    or ``error`` (str) on failure.  Never raises.
    """
    try:
        return _land_run(run_id)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)}


def reject_run(run_id: str) -> dict:
    """Mark a dev run as rejected (keep the .patch file as a record).

    Returns ``{ok: True}`` on success or ``{ok: False, error: str}`` on failure.
    Never raises.
    """
    try:
        return _reject_run(run_id)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)}


# ---------------------------------------------------------------------------
# Private implementation
# ---------------------------------------------------------------------------


def _land_run(run_id: str) -> dict:
    # a. Load run state
    state = _dr.get_run(run_id)
    if state is None:
        return {"ok": False, "error": "run not found"}
    status = state.get("status", "")
    if status != "done":
        return {"ok": False, "error": f"run not approvable (status={status})"}

    # b. Locate patch
    results_dir = Path(os.path.expanduser(
        config.get("dev_director_results_dir", "~/LifeOS/dev-results")
    ))
    patches = sorted(results_dir.glob(f"{run_id}-*.patch")) if results_dir.exists() else []
    if not patches or patches[-1].stat().st_size == 0:
        return {"ok": False, "error": "no patch"}
    patch_path = patches[-1]

    # b2. ENFORCED dev-engine guard — only for self-improve-origin runs.
    # A nightly self-improvement run must never land changes to the autonomous
    # dev engine itself. A user-initiated run editing the engine is still allowed.
    origin = state.get("origin", "user")
    changed_paths = _si.changed_paths_from_patch(patch_path.read_text())
    if origin == "self_improve":
        offenders = _si.violates_dev_engine_guard(changed_paths)
        if offenders:
            reason = (
                "Bloqueado: un run de auto-mejora intentó modificar el motor de "
                "desarrollo (" + ", ".join(offenders) + "). No se hizo push."
            )
            state["status"] = "needs_human"
            state["guard_blocked"] = True
            state["guard_offenders"] = offenders
            _dr._write_state_file(_dr._state_path(run_id), state)
            _log_outcome(state, status="blocked", changed_paths=changed_paths,
                         guard_blocked=True)
            return {"ok": False, "error": reason, "guard_blocked": True,
                    "offenders": offenders}

    # c. Create isolated worktree
    dev_director_repo = os.path.expanduser(
        config.get("dev_director_repo", "~/LifeOS/lifeos")
    )
    tmp_parent = tempfile.mkdtemp(prefix="axi-land-wt-")
    worktree_path = os.path.join(tmp_parent, f"axi-land-{run_id[:12]}")
    branch = f"axi/land/{run_id}"

    ok, err = _create_worktree(dev_director_repo, worktree_path, branch)
    if not ok:
        # Clean up tmp dir (worktree wasn't fully created, so skip git cleanup)
        try:
            import shutil
            shutil.rmtree(tmp_parent, ignore_errors=True)
        except Exception:  # noqa: BLE001
            pass
        return {"ok": False, "error": f"could not create worktree: {err}"}

    try:
        # d. Apply patch
        apply_result = subprocess.run(
            ["git", "apply", "--index", str(patch_path)],
            cwd=worktree_path,
            capture_output=True,
            text=True,
        )
        if apply_result.returncode != 0:
            # Try --3way fallback
            apply_result = subprocess.run(
                ["git", "apply", "--3way", str(patch_path)],
                cwd=worktree_path,
                capture_output=True,
                text=True,
            )
            if apply_result.returncode != 0:
                stderr = apply_result.stderr.strip()
                return {"ok": False, "error": f"patch did not apply: {stderr}"}

        # e. Commit
        goal_first_line = state.get("goal", "").splitlines()[0][:72]
        commit_msg = f"axi: {goal_first_line}\n\nApplied from dev run {run_id}."
        subprocess.run(
            ["git", "commit", "-m", commit_msg],
            cwd=worktree_path,
            capture_output=True,
            text=True,
            check=True,
        )

        # f. Push
        push_result = subprocess.run(
            ["git", "push", "-u", "origin", branch],
            cwd=worktree_path,
            capture_output=True,
            text=True,
        )
        push_ok = push_result.returncode == 0

    finally:
        # g. Always cleanup worktree (local branch deleted; remote branch persists)
        _cleanup_worktree(dev_director_repo, worktree_path, branch, tmp_parent)

    # h. Update state.json
    state["status"] = "landed"
    state["landed_branch"] = branch
    state["landed_at"] = datetime.now(timezone.utc).isoformat()
    state["push_ok"] = push_ok
    state_path = _dr._state_path(run_id)
    _dr._write_state_file(state_path, state)

    # h2. Best-effort observability for self-improve runs that landed.
    _log_outcome(state, status="landed", changed_paths=changed_paths,
                 guard_blocked=False)

    # i. Return success
    return {"ok": True, "branch": branch, "pushed": push_ok}


def _reject_run(run_id: str) -> dict:
    state = _dr.get_run(run_id)
    if state is None:
        return {"ok": False, "error": "run not found"}
    state["status"] = "rejected"
    state_path = _dr._state_path(run_id)
    _dr._write_state_file(state_path, state)
    return {"ok": True}
