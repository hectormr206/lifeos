"""Persistent dev environments — the controlled "Desarrollo" workspace.

An *environment* is a long-lived git worktree where Axi (VT-3B directing Claude
Code) builds a requested change. Unlike an ephemeral dev_run — which extracts a
patch and destroys its worktree — an environment PERSISTS so you can launch it in
isolation, test it, keep iterating with Axi, and only then deploy. The worktree
lives in a durable directory and survives daemon restarts.

This module is a thin layer over the SAME detached-execution machinery as
dev_run (shared state dir, systemd launch, poll/resume, notify) and the SAME
director loop (run_director_loop, here in keep_worktree mode). Environments are
distinguished from ephemeral runs by ``kind == "env"`` in their state.json — not
by a parallel system. The sacred invariant is unchanged: the engine never
commits, pushes, or merges; deploy is a separate, explicit, user-driven step.

Public surface:
    create_env(goal)   → env_id   (non-blocking; launches a detached director)
    list_envs()        → list of env state dicts (newest first)
    get_env(env_id)    → state dict | None
    card_status(state) → coarse display status for a UI card
"""
from __future__ import annotations

import logging
import os
import subprocess
from datetime import datetime, timezone
from uuid import uuid4

from axi import dev_run  # reuse: state dir, launch cmd, notify, state IO

log = logging.getLogger("axi.dev_env")

ENV_KIND = "env"

# Coarse status shown on a card, derived from the internal lifecycle status.
# Internal statuses come from the shared poll/entry machinery (running,
# waiting_quota, interrupted, needs_human, error) plus the env-only terminal
# "ready" (built + tests green + VT-3B approved, awaiting your test/deploy).
_CARD_STATUS = {
    "running": "developing",
    "interrupted": "developing",
    "waiting_quota": "developing",
    "ready": "ready",
    "needs_human": "needs_human",
    "error": "error",
    "deploying": "deploying",
    "deployed": "deployed",
    "rejected": "rejected",
}


def card_status(state: dict) -> str:
    """Map the internal lifecycle status to a coarse card status for the UI."""
    return _CARD_STATUS.get(state.get("status", ""), "developing")


# ---------------------------------------------------------------------------
# Title / description generation (best-effort, never blocks creation)
# ---------------------------------------------------------------------------

_META_SYSTEM = (
    "Sos el asistente que resume objetivos de desarrollo para tarjetas de UI. "
    "Te dan un objetivo y devolvés DOS líneas, sin nada más:\n"
    "TITULO: <título corto, máximo 6 palabras, sin punto final>\n"
    "DESCRIPCION: <una frase de máximo 140 caracteres que explique de qué trata>"
)


def _meta_timeout() -> float:
    from axi import config  # noqa: PLC0415
    return float(config.get("dev_env_meta_timeout_s", 8.0))


def _director_port() -> int:
    from axi import config  # noqa: PLC0415
    return int(config.get("dev_director_port", 8082))


def _fallback_meta(goal: str) -> tuple[str, str]:
    """Deterministic title/description from the goal text — used when the model
    is unavailable or returns junk. Never fails."""
    words = goal.strip().split()
    title = " ".join(words[:6]) if words else "Nuevo ambiente"
    if len(title) > 60:
        title = title[:57].rstrip() + "…"
    desc = goal.strip().replace("\n", " ")
    if len(desc) > 140:
        desc = desc[:139].rstrip() + "…"
    return title, desc


def _generate_meta(goal: str) -> tuple[str, str]:
    """Ask VT-3B for a short title + one-line description. Best-effort: on any
    failure (model down, timeout, unparseable) fall back to goal-derived text."""
    try:
        from axi.dev_director import _call_vt3b  # noqa: PLC0415
        raw = _call_vt3b(
            _META_SYSTEM, goal.strip(),
            port=_director_port(), max_tokens=200, timeout=_meta_timeout(),
        )
    except Exception as exc:  # noqa: BLE001
        log.info("env meta generation failed (%s) — using fallback", exc)
        return _fallback_meta(goal)

    title, desc = "", ""
    for line in raw.splitlines():
        s = line.strip()
        low = s.lower()
        if low.startswith("titulo:") or low.startswith("título:"):
            title = s.split(":", 1)[1].strip()
        elif low.startswith("descripcion:") or low.startswith("descripción:"):
            desc = s.split(":", 1)[1].strip()
    if not title or not desc:
        return _fallback_meta(goal)
    # Trim to card limits.
    if len(title) > 60:
        title = title[:57].rstrip() + "…"
    if len(desc) > 140:
        desc = desc[:139].rstrip() + "…"
    return title, desc


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def create_env(goal: str) -> str:
    """Create a persistent dev environment and launch its director (detached).

    Returns the env_id immediately; the build runs in the background. The card's
    title/description are generated up front (best-effort) so it shows something
    meaningful right away.
    """
    env_id = dev_run._run_id()  # noqa: SLF001 — shared id scheme
    unit = dev_run._unit_name(env_id)  # noqa: SLF001
    branch_id = uuid4().hex[:8]
    title, description = _generate_meta(goal)
    now = datetime.now(timezone.utc).isoformat()

    state: dict = {
        "run_id": env_id,          # shared key so dev_run poll/entry work as-is
        "kind": ENV_KIND,
        "goal": goal,
        "title": title,
        "description": description,
        "branch_id": branch_id,
        "branch": None,            # filled by the entry once the worktree exists
        "worktree_path": None,     # filled by the entry (persistent worktree)
        "status": "running",
        "started_at": now,
        "created_at": now,
        "unit": unit,
        "rounds_done": 0,
        "session_id": None,
        "result": None,
        "resume_at": None,
        "error": None,
        "resumes_done": 0,
    }
    state_path = dev_run._state_path(env_id)  # noqa: SLF001
    dev_run._write_state_file(state_path, state)  # noqa: SLF001

    cmd = dev_run._build_launch_cmd(env_id)  # noqa: SLF001 — same detached entry
    try:
        subprocess.run(cmd, check=True, capture_output=True, timeout=30)
    except Exception as exc:  # noqa: BLE001
        log.error("systemd-run launch failed for env_id=%s: %s", env_id, exc)
        state["status"] = "error"
        state["error"] = str(exc)
        dev_run._write_state_file(state_path, state)  # noqa: SLF001
        dev_run._notify("Axi dev", f"No se pudo lanzar el ambiente: {exc}")  # noqa: SLF001

    return env_id


def list_envs() -> list[dict]:
    """Return all environment state dicts (kind == 'env'), newest first."""
    envs = [s for s in dev_run.list_runs() if s.get("kind") == ENV_KIND]
    # run_id starts with a UTC timestamp, so reverse-lexicographic == newest first.
    envs.sort(key=lambda s: s.get("run_id", ""), reverse=True)
    return envs


def get_env(env_id: str) -> dict | None:
    """Return a single environment's state, or None if not found / not an env."""
    state = dev_run.get_run(env_id)
    if state is None or state.get("kind") != ENV_KIND:
        return None
    return state


def reject_env(env_id: str) -> dict:
    """Discard an environment: stop its test instance, remove the worktree +
    branch (local only) + the env directory, and mark it rejected. Never raises.

    Like the rest of the engine this never touches main and never deletes a
    remote branch — it only cleans up the throwaway worktree it created.
    """
    state = get_env(env_id)
    if state is None:
        return {"ok": False, "error": "environment not found"}

    # Stop the isolated test instance first (best-effort).
    try:
        from axi import dev_env_instance  # noqa: PLC0415
        dev_env_instance.stop_instance(env_id)
    except Exception as exc:  # noqa: BLE001
        log.info("reject_env: stop_instance failed for %s (%s)", env_id, exc)

    worktree_path = state.get("worktree_path")
    branch = state.get("branch") or ""
    if worktree_path:
        try:
            from axi import config  # noqa: PLC0415
            from axi.dev_director import _cleanup_worktree  # noqa: PLC0415
            repo = os.path.expanduser(config.get("dev_director_repo", "~/LifeOS/lifeos"))
            env_dir = os.path.join(
                os.path.expanduser(config.get("dev_env_worktree_dir", "~/LifeOS/dev-envs")),
                env_id,
            )
            # Removes the worktree, deletes the LOCAL branch, prunes, and rmtrees
            # the whole env directory (worktree + isolated instance dirs).
            _cleanup_worktree(repo, worktree_path, branch, env_dir)
        except Exception as exc:  # noqa: BLE001
            log.warning("reject_env: worktree cleanup failed for %s (%s)", env_id, exc)

    state["status"] = "rejected"
    state["instance"] = None
    state["worktree_path"] = None
    dev_run._write_state_file(dev_run._state_path(env_id), state)  # noqa: SLF001
    return {"ok": True}


def _deploy_target() -> str:
    from axi import config  # noqa: PLC0415
    return str(config.get("dev_env_deploy_target_branch", "main"))


def deploy_env(env_id: str) -> dict:
    """Land a tested environment's change on the production branch (default main).

    Applies ONLY the environment's diff (what Axi built, not the experimental
    base it branched from) onto a fresh checkout of origin/<target>, commits, and
    pushes directly to <target>. No PR: the isolated-instance test IS the review
    gate for solo work. Never raises.

    Returns {ok, pushed, target, restart_hint} or {ok: False, error}. A patch
    that does not apply usually means <target> is behind the branch the env was
    built on — the one-time sync is needed first.
    """
    state = get_env(env_id)
    if state is None:
        return {"ok": False, "error": "environment not found"}
    worktree = state.get("worktree_path")
    if not worktree or not os.path.isdir(worktree):
        return {"ok": False, "error": "environment has no worktree to deploy"}

    target = _deploy_target()

    # Stop the isolated instance before we deploy.
    try:
        from axi import dev_env_instance  # noqa: PLC0415
        dev_env_instance.stop_instance(env_id)
    except Exception as exc:  # noqa: BLE001
        log.info("deploy_env: stop_instance failed for %s (%s)", env_id, exc)

    try:
        return _deploy_env(env_id, state, worktree, target)
    except Exception as exc:  # noqa: BLE001
        log.exception("deploy_env failed for %s", env_id)
        return {"ok": False, "error": str(exc)}


def _deploy_env(env_id: str, state: dict, worktree: str, target: str) -> dict:
    import shutil  # noqa: PLC0415
    import subprocess  # noqa: PLC0415
    import tempfile  # noqa: PLC0415
    from datetime import datetime, timezone  # noqa: PLC0415
    from pathlib import Path  # noqa: PLC0415
    from axi import config  # noqa: PLC0415
    from axi.dev_director import _cleanup_worktree  # noqa: PLC0415

    repo = os.path.expanduser(config.get("dev_director_repo", "~/LifeOS/lifeos"))

    # 1. The environment's diff — just what Axi built, vs the worktree's base.
    diff_proc = subprocess.run(
        ["git", "-C", worktree, "diff", "HEAD"],
        capture_output=True, text=True, timeout=30,
    )
    diff = diff_proc.stdout
    if not diff.strip():
        return {"ok": False, "error": "no changes to deploy"}

    # 2. Make sure we have the latest target.
    subprocess.run(["git", "-C", repo, "fetch", "origin", target],
                   capture_output=True, text=True, timeout=60)

    tmp_parent = tempfile.mkdtemp(prefix="axi-deploy-wt-")
    wt = os.path.join(tmp_parent, f"axi-deploy-{env_id[:12]}")
    # Detached checkout of origin/<target> — no leftover branch to clean up.
    add = subprocess.run(
        ["git", "-C", repo, "worktree", "add", "--detach", wt, f"origin/{target}"],
        capture_output=True, text=True,
    )
    if add.returncode != 0:
        shutil.rmtree(tmp_parent, ignore_errors=True)
        return {"ok": False, "error": f"could not check out origin/{target}: {add.stderr.strip()}"}

    patch_path = os.path.join(tmp_parent, "env.patch")
    Path(patch_path).write_text(diff)
    pushed = False
    try:
        applied = subprocess.run(["git", "-C", wt, "apply", "--index", patch_path],
                                 capture_output=True, text=True)
        if applied.returncode != 0:
            applied = subprocess.run(["git", "-C", wt, "apply", "--3way", patch_path],
                                     capture_output=True, text=True)
            if applied.returncode != 0:
                return {
                    "ok": False,
                    "error": (f"patch did not apply onto {target} (likely {target} is behind the "
                              f"branch this env was built on — run the one-time sync first): "
                              f"{applied.stderr.strip()[:300]}"),
                }
        title = (state.get("title") or state.get("goal", "")).splitlines()[0][:72]
        commit_msg = f"{title}\n\nDeployed from Axi environment {env_id}."
        subprocess.run(["git", "-C", wt, "commit", "-m", commit_msg],
                       capture_output=True, text=True, check=True)
        push = subprocess.run(["git", "-C", wt, "push", "origin", f"HEAD:{target}"],
                              capture_output=True, text=True)
        pushed = push.returncode == 0
        push_err = push.stderr.strip()
    finally:
        _cleanup_worktree(repo, wt, "", tmp_parent)

    if not pushed:
        return {"ok": False, "error": f"push to {target} failed: {push_err[:300]}"}

    state["status"] = "deployed"
    state["deployed_at"] = datetime.now(timezone.utc).isoformat()
    state["deployed_target"] = target
    state["instance"] = None
    dev_run._write_state_file(dev_run._state_path(env_id), state)  # noqa: SLF001

    return {
        "ok": True,
        "pushed": True,
        "target": target,
        "restart_hint": (
            f"Desplegado a {target}. En la laptop (corriendo {target}): "
            f"git pull && systemctl --user restart axi-dashboard axi-voice"
        ),
    }


def iterate_env(env_id: str, prompt: str) -> dict:
    """Refine an existing environment: relaunch the director on the SAME worktree
    with a new instruction, resuming Claude's session so it keeps the context of
    what it already built. Never raises.

    Reuses the whole engine: keep_worktree (the worktree persists), the stable
    branch id (the director reuses the existing worktree), and the saved
    session_id (the detached entry passes it as resume_session_id).
    """
    state = get_env(env_id)
    if state is None:
        return {"ok": False, "error": "environment not found"}
    if not prompt or not prompt.strip():
        return {"ok": False, "error": "prompt required"}
    if not state.get("worktree_path"):
        return {"ok": False, "error": "environment has no worktree yet"}

    # Stop the isolated instance so it isn't serving stale code while we rebuild.
    try:
        from axi import dev_env_instance  # noqa: PLC0415
        dev_env_instance.stop_instance(env_id)
    except Exception as exc:  # noqa: BLE001
        log.info("iterate_env: stop_instance failed for %s (%s)", env_id, exc)

    history = state.get("goal_history") or []
    history.append(state.get("goal", ""))
    state["goal_history"] = history
    state["goal"] = prompt.strip()
    state["status"] = "running"
    state["error"] = None
    state["resume_at"] = None
    state["instance"] = None
    dev_run._write_state_file(dev_run._state_path(env_id), state)  # noqa: SLF001

    cmd = dev_run._build_launch_cmd(env_id)  # noqa: SLF001 — same detached entry
    try:
        subprocess.run(cmd, check=True, capture_output=True, timeout=30)
    except Exception as exc:  # noqa: BLE001
        log.error("iterate launch failed for env_id=%s: %s", env_id, exc)
        state["status"] = "error"
        state["error"] = str(exc)
        dev_run._write_state_file(dev_run._state_path(env_id), state)  # noqa: SLF001
        return {"ok": False, "error": str(exc)}
    return {"ok": True}
