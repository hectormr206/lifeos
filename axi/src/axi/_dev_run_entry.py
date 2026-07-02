"""Detached entrypoint for a dev run.

Invoked by systemd via:
    python -m axi._dev_run_entry <run_id>

Reads state.json, runs the director loop, and writes the terminal status back.
Never raises — all exceptions are caught and recorded as status="error".
"""
from __future__ import annotations

import json
import logging
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

log = logging.getLogger("axi._dev_run_entry")

_QUOTA_PHRASES = ("resets", "usage limit", "session limit")


def _state_path(run_id: str) -> Path:
    from axi import config  # noqa: PLC0415
    state_dir = Path(os.path.expanduser(config.get("dev_run_state_dir", "~/LifeOS/dev-runs")))
    return state_dir / run_id / "state.json"


def _write_state(path: Path, state: dict) -> None:
    path.write_text(json.dumps(state, indent=2))


def _notify(title: str, body: str) -> None:
    try:
        from axi.output import notify  # noqa: PLC0415
        notify(title, body, timeout_ms=6000)
    except Exception:  # noqa: BLE001
        pass


def _log_terminal(state: dict, status: str) -> None:
    """Best-effort outcome log for self-improve runs reaching a terminal state."""
    if state.get("origin") != "self_improve":
        return
    try:
        from axi import config  # noqa: PLC0415
        from axi import self_improve as _si  # noqa: PLC0415
        state_dir = os.path.expanduser(config.get("dev_run_state_dir", "~/LifeOS/dev-runs"))
        _si.append_outcome_log(
            state_dir,
            _si.build_outcome_record(
                run_id=state.get("run_id", ""),
                started_at=state.get("started_at"),
                goal=state.get("goal", ""),
                status=status,
            ),
        )
    except Exception:  # noqa: BLE001
        pass


def main(run_id: str) -> None:
    state_path = _state_path(run_id)
    if not state_path.exists():
        log.error("state.json not found for run_id=%s", run_id)
        return

    try:
        state = json.loads(state_path.read_text())
    except Exception as exc:  # noqa: BLE001
        log.error("failed to read state.json for run_id=%s: %s", run_id, exc)
        return

    goal = state.get("goal", "")
    # Persistent-environment runs (kind == "env") keep their worktree for the
    # user to test, iterate on, and deploy. Ephemeral runs (default) extract a
    # patch and the worktree is deleted. Same engine, same detached machinery.
    is_env = state.get("kind") == "env"

    try:
        from axi import config  # noqa: PLC0415
        from axi.dev_director import run_director_loop  # noqa: PLC0415

        repo_path = os.path.expanduser(config.get("dev_director_repo", "~/LifeOS/lifeos"))
        max_rounds = int(config.get("dev_director_max_rounds", 3))
        test_command = config.get("dev_director_test_command", "tests/test_dev_director.py -q")
        venv_python = os.path.expanduser(
            config.get("dev_director_venv_python", "~/LifeOS/lifeos/axi/.venv/bin/python")
        )
        claude_timeout = float(config.get("dev_run_round_timeout_s", 3600))
        quota_wait_s = int(config.get("dev_run_quota_wait_default_s", 3600))
        results_dir = Path(os.path.expanduser(
            config.get("dev_director_results_dir", "~/LifeOS/dev-results")
        ))

        resume_session_id: str | None = state.get("session_id") or None

        loop_kwargs: dict = dict(
            max_rounds=max_rounds,
            test_command=test_command,
            venv_python=venv_python,
            claude_timeout=claude_timeout,
            resume_session_id=resume_session_id,
        )
        if is_env:
            # Durable, env-scoped worktree directory + a stable branch id so a
            # resume reuses the SAME worktree instead of creating a new one.
            worktree_dir = os.path.expanduser(
                config.get("dev_env_worktree_dir", "~/LifeOS/dev-envs")
            )
            loop_kwargs.update(
                branch_prefix=config.get("dev_env_branch_prefix", "axi/env"),
                keep_worktree=True,
                worktree_parent=os.path.join(worktree_dir, run_id),
                _branch_id=state.get("branch_id"),
            )
        else:
            loop_kwargs["branch_prefix"] = config.get(
                "dev_director_branch_prefix", "axi/self-build"
            )

        loop = run_director_loop(goal, repo_path, **loop_kwargs)

        # Persist session_id so the next resume (quota-wait or crash-recovery) can continue
        if loop.session_id:
            state["session_id"] = loop.session_id
        state["rounds_done"] = loop.rounds_used
        # For environments, record where the worktree lives + its branch as soon
        # as we know them, even on non-success paths — the user can still inspect
        # a needs_human environment in its worktree.
        if is_env:
            if loop.worktree_path:
                state["worktree_path"] = loop.worktree_path
            if loop.branch:
                state["branch"] = loop.branch

        if not loop.ok:
            error_str = loop.error or ""
            if any(phrase in error_str.lower() for phrase in _QUOTA_PHRASES):
                state["status"] = "waiting_quota"
                state["resume_at"] = (
                    datetime.now(timezone.utc) + timedelta(seconds=quota_wait_s)
                ).isoformat()
                state["error"] = error_str
                _write_state(state_path, state)
                return

            state["status"] = "error"
            state["error"] = error_str
            _write_state(state_path, state)
            _log_terminal(state, "failed")
            _notify("Axi dev ✗", f"Error: {error_str[:200]}")
            return

        if loop.needs_human:
            state["status"] = "needs_human"
            state["result"] = loop.escalation_reason
            _write_state(state_path, state)
            _log_terminal(state, "needs_human")
            _notify("Axi dev ⚠", f"Requiere revisión: {loop.escalation_reason[:200]}")
            return

        if is_env:
            # The worktree IS the artifact — nothing to save, nothing cleaned up.
            # "ready" = built, tests green, VT-3B approved; awaiting your test/deploy.
            state["status"] = "ready"
            state["result"] = (
                f"Listo para probar en {loop.rounds_used} ronda(s). "
                f"Costo ${loop.total_cost_usd:.4f}."
            )
            _write_state(state_path, state)
            _notify("Axi dev ✓", f"Ambiente listo para probar: {state.get('title') or goal[:80]}")
            return

        # Ephemeral run success — save patch.
        if loop.final_diff:
            results_dir.mkdir(parents=True, exist_ok=True)
            ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
            patch_path = results_dir / f"{run_id}-{ts}.patch"
            patch_path.write_text(loop.final_diff)

        state["status"] = "done"
        state["result"] = (
            f"Done in {loop.rounds_used} round(s). Cost ${loop.total_cost_usd:.4f}."
        )
        _write_state(state_path, state)
        _notify("Axi dev ✓", f"Listo: {goal[:80]}")

    except Exception as exc:  # noqa: BLE001
        log.exception("_dev_run_entry failed for run_id=%s: %s", run_id, exc)
        try:
            state["status"] = "error"
            state["error"] = str(exc)
            _write_state(state_path, state)
            _log_terminal(state, "failed")
        except Exception:  # noqa: BLE001
            pass
        _notify("Axi dev ✗", f"Error inesperado: {str(exc)[:200]}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python -m axi._dev_run_entry <run_id>", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1])
