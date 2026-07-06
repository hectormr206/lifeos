"""Landing gate for Axi self-build dev runs.

Applies a completed run's patch to an isolated branch and pushes it to origin
for human review.  This module is the ONLY place that interacts with git push.

SAFETY CONTRACT: The autonomous engine NEVER merges to main or restarts services
on its own. Landing only pushes a review branch axi/land/<run_id>. Merging to
main (merge_run) and deploying (deploy_run) are SEPARATE, EXPLICITLY
HUMAN-TRIGGERED actions invoked only from the /dev dashboard, each gated by run
state (landed -> merged -> deployed). No autonomous code path calls merge_run or
deploy_run.

Concretely, the landing step (land_run):
- Never touches the live working tree or the currently-checked-out branch.
- Never restarts services (systemctl, uvicorn, etc.).
- Only pushes a NEW review branch `axi/land/<run_id>` to origin.
  The local worktree + branch are deleted immediately after push.

merge_run (human, state 'landed' -> 'merged') merges the already-pushed review
branch into the target branch in an ISOLATED worktree and pushes it; it never
touches the live working tree and never restarts services. deploy_run (human,
state 'merged' -> 'deployed') triggers the detached, self-guarding local install
(git pull --ff-only + restart) on the live repo.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path

from axi import config
from axi import dev_env
from axi import dev_run as _dr
from axi import self_improve as _si
from axi.dev_director import _cleanup_worktree, _create_worktree


# Per-run in-process locks serialize the read→act→write of the irreversible
# merge/deploy actions. Because the endpoints now run these in a worker thread
# (asyncio.to_thread), a double-click/double-submit can otherwise race and cause
# a double-merge or a lost-update. The guard dict protects lock creation itself.
_run_locks_guard = threading.Lock()
_run_locks: dict[str, threading.Lock] = {}


def _lock_for(run_id: str) -> threading.Lock:
    with _run_locks_guard:
        lock = _run_locks.get(run_id)
        if lock is None:
            lock = threading.Lock()
            _run_locks[run_id] = lock
        return lock


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


def merge_run(run_id: str) -> dict:
    """Merge a landed run's review branch into the target branch (HUMAN action).

    Only valid from state ``landed``. On success the run advances to ``merged``.
    Returns a dict with ``ok`` (bool) plus ``merged_into`` on success, or
    ``error`` on failure.  Never raises.  Never restarts services.
    """
    try:
        return _merge_run(run_id)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)}


def deploy_run(run_id: str) -> dict:
    """Trigger the local install for a merged run (HUMAN action).

    Only valid from state ``merged``. On success the run advances to
    ``deployed``.  Returns a dict with ``ok`` (bool) plus ``deploy_triggered_ok``
    on success, or ``error`` on failure.  Never raises.
    """
    try:
        return _deploy_run(run_id)
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


def _merge_run(run_id: str) -> dict:
    # Serialize the whole read→act→write for this run so a double-submit cannot
    # double-merge (the endpoints run this in a worker thread via to_thread).
    with _lock_for(run_id):
        return _merge_run_locked(run_id)


def _merge_run_locked(run_id: str) -> dict:
    # a. Load state; REQUIRE 'landed' (else no side effect at all).
    state = _dr.get_run(run_id)
    if state is None:
        return {"ok": False, "error": "run not found"}
    status = state.get("status", "")
    if status != "landed":
        return {"ok": False, "error": "run not in 'landed' state"}

    landed_branch = state.get("landed_branch")
    if not landed_branch:
        return {"ok": False, "error": "no landed_branch recorded"}

    target_branch = str(config.get("dev_env_deploy_target_branch", "main"))
    dev_director_repo = os.path.expanduser(
        config.get("dev_director_repo", "~/LifeOS/lifeos")
    )

    # b. Isolated worktree on a throwaway branch. We reset it to the freshly
    # fetched target and merge on top — we NEVER `git checkout <target>` because
    # the target branch is already checked out in the live repo worktree (that
    # would fail), and we push HEAD:<target> without ever touching the live tree.
    tmp_parent = tempfile.mkdtemp(prefix="axi-merge-wt-")
    worktree_path = os.path.join(tmp_parent, f"axi-merge-{run_id[:12]}")
    merge_branch = f"axi/merge/{run_id}"

    ok, err = _create_worktree(dev_director_repo, worktree_path, merge_branch)
    if not ok:
        try:
            import shutil
            shutil.rmtree(tmp_parent, ignore_errors=True)
        except Exception:  # noqa: BLE001
            pass
        return {"ok": False, "error": f"could not create worktree: {err}"}

    push_ok = False
    # Timeouts bound EVERY git call so a hung network/lock never freezes the
    # dashboard. Network ops (fetch/push) get a longer bound than local ops.
    _NET_TIMEOUT = 30
    _LOCAL_TIMEOUT = 15
    try:
        try:
            # c. Fetch origin so target and the review branch are up to date.
            subprocess.run(
                ["git", "fetch", "origin"],
                cwd=worktree_path, capture_output=True, text=True, check=True,
                timeout=_NET_TIMEOUT,
            )
            # d. Base the merge on the latest origin/<target>. --hard only moves
            # the throwaway merge branch; the live worktree is untouched.
            subprocess.run(
                ["git", "reset", "--hard", f"origin/{target_branch}"],
                cwd=worktree_path, capture_output=True, text=True, check=True,
                timeout=_LOCAL_TIMEOUT,
            )
            # e. Merge the already-reviewed, already-pushed landing branch.
            # NEVER force.
            merge_result = subprocess.run(
                ["git", "merge", "--no-edit", f"origin/{landed_branch}"],
                cwd=worktree_path, capture_output=True, text=True,
                timeout=_LOCAL_TIMEOUT,
            )
            if merge_result.returncode != 0:
                # Conflict / non-zero: abort, keep state 'landed', push nothing.
                subprocess.run(
                    ["git", "merge", "--abort"],
                    cwd=worktree_path, capture_output=True, text=True,
                    timeout=_LOCAL_TIMEOUT,
                )
                # FIX 6: surface the conflicting paths from stderr, not a bare label.
                detail = (merge_result.stderr or "").strip()[:800]
                err_msg = "merge conflict"
                if detail:
                    err_msg = f"merge conflict: {detail}"
                _log_outcome(state, status="merge_failed")
                return {"ok": False, "error": err_msg}

            # f. Fast-forward push the merged history to the target branch.
            push_result = subprocess.run(
                ["git", "push", "origin", f"HEAD:{target_branch}"],
                cwd=worktree_path, capture_output=True, text=True,
                timeout=_NET_TIMEOUT,
            )
            push_ok = push_result.returncode == 0
            if not push_ok:
                _log_outcome(state, status="merge_failed")
                return {"ok": False,
                        "error": f"push to {target_branch} failed: {push_result.stderr.strip()}"}
        except subprocess.TimeoutExpired as exc:
            # A git call hung. Treat as failure, best-effort abort, keep state
            # 'landed' so the human can retry. No partial advance.
            step = "git"
            try:
                cmd = exc.cmd
                if isinstance(cmd, (list, tuple)) and len(cmd) > 1:
                    step = str(cmd[1])
                elif isinstance(cmd, str):
                    step = cmd
            except Exception:  # noqa: BLE001
                pass
            try:
                subprocess.run(
                    ["git", "merge", "--abort"],
                    cwd=worktree_path, capture_output=True, text=True,
                    timeout=_LOCAL_TIMEOUT,
                )
            except Exception:  # noqa: BLE001
                pass
            _log_outcome(state, status="merge_failed")
            return {"ok": False, "error": f"git timeout: {step}"}
    finally:
        _cleanup_worktree(dev_director_repo, worktree_path, merge_branch, tmp_parent)

    # g. Advance state → 'merged'. Re-read fresh state and patch only the new
    # fields to avoid clobbering a concurrent update (lost-update guard).
    fresh = _dr.get_run(run_id) or state
    fresh["status"] = "merged"
    fresh["merged_at"] = datetime.now(timezone.utc).isoformat()
    fresh["merged_into"] = target_branch
    fresh["merge_push_ok"] = push_ok
    _dr._write_state_file(_dr._state_path(run_id), fresh)

    _log_outcome(fresh, status="merged")

    return {"ok": True, "merged_into": target_branch, "pushed": push_ok}


def _deploy_run(run_id: str) -> dict:
    # Serialize read→act→write for this run (see _merge_run).
    with _lock_for(run_id):
        return _deploy_run_locked(run_id)


def _deploy_run_locked(run_id: str) -> dict:
    # a. Load state; REQUIRE 'merged' (else no side effect).
    state = _dr.get_run(run_id)
    if state is None:
        return {"ok": False, "error": "run not found"}
    status = state.get("status", "")
    if status != "merged":
        return {"ok": False, "error": "run not in 'merged' state"}

    dev_director_repo = os.path.expanduser(
        config.get("dev_director_repo", "~/LifeOS/lifeos")
    )

    # b. Reuse the shared, detached, self-guarding local install (git pull
    # --ff-only + restart services). It is fire-and-forget: a True result means
    # the install job was TRIGGERED, not that it finished installing.
    triggered = False
    deploy_error = None
    try:
        triggered = bool(dev_env._trigger_local_install(dev_director_repo))
        if not triggered:
            deploy_error = "local install trigger returned False"
    except Exception as exc:  # noqa: BLE001
        deploy_error = f"local install trigger raised: {exc}"

    # Re-read fresh state and patch only the new fields (lost-update guard).
    fresh = _dr.get_run(run_id) or state

    if not triggered:
        # FIX 2: do NOT advance to 'deployed' on a failed trigger. Staying
        # 'merged' keeps the Deploy button visible so the human can retry.
        fresh["deploy_triggered_ok"] = False
        fresh["deploy_error"] = deploy_error
        _dr._write_state_file(_dr._state_path(run_id), fresh)
        _log_outcome(fresh, status="deploy_failed")
        return {"ok": False, "error": deploy_error or "deploy trigger failed"}

    # c. Advance state → 'deployed' only on a genuine trigger.
    fresh["status"] = "deployed"
    fresh["deployed_at"] = datetime.now(timezone.utc).isoformat()
    fresh["deploy_triggered_ok"] = True
    fresh.pop("deploy_error", None)
    _dr._write_state_file(_dr._state_path(run_id), fresh)

    _log_outcome(fresh, status="deployed")

    return {"ok": True, "deploy_triggered_ok": True}
