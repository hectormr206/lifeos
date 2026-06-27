"""Detached, state-tracked dev runs.

Each run is launched as a systemd transient unit so it survives daemon restarts.
State lives in a per-run state.json under dev_run_state_dir.

Public surface:
    start_dev_run(goal)      → run_id   (non-blocking)
    poll_dev_runs()          → list of transition dicts
    reattach_dev_runs()      → list of transition dicts  (call at startup)
    list_runs()              → list of state dicts
    get_run(run_id)          → state dict | None
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

log = logging.getLogger("axi.dev_run")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _state_dir() -> Path:
    from axi import config  # noqa: PLC0415
    return Path(os.path.expanduser(config.get("dev_run_state_dir", "~/LifeOS/dev-runs")))


def _venv_python() -> str:
    from axi import config  # noqa: PLC0415
    return os.path.expanduser(
        config.get("dev_director_venv_python", "~/LifeOS/lifeos/axi/.venv/bin/python")
    )


def _max_resumes() -> int:
    from axi import config  # noqa: PLC0415
    return int(config.get("dev_run_max_resumes", 5))


def _max_wall_clock_s() -> int:
    from axi import config  # noqa: PLC0415
    return int(config.get("dev_run_max_wall_clock_s", 21600))


def _unit_name(run_id: str) -> str:
    return f"axi-dev-{run_id}"


def _run_id() -> str:
    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    return f"{ts}-{uuid4().hex[:6]}"


def _state_path(run_id: str) -> Path:
    return _state_dir() / run_id / "state.json"


def _read_state(run_id: str) -> dict | None:
    p = _state_path(run_id)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except Exception:  # noqa: BLE001
        return None


def _write_state_file(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2))


def _notify(title: str, body: str) -> None:
    try:
        from axi.output import notify  # noqa: PLC0415
        notify(title, body, timeout_ms=6000)
    except Exception:  # noqa: BLE001
        pass


def _build_launch_cmd(run_id: str) -> list[str]:
    return [
        "systemd-run", "--user", "--collect",
        f"--unit={_unit_name(run_id)}",
        _venv_python(), "-m", "axi._dev_run_entry", run_id,
    ]


def _relaunch_run(state: dict) -> bool:
    """Fire systemd-run for an existing run (resume). Returns True on success."""
    run_id = state["run_id"]
    cmd = _build_launch_cmd(run_id)
    try:
        subprocess.run(cmd, check=True, capture_output=True, timeout=30)
        return True
    except Exception as exc:  # noqa: BLE001
        log.warning("relaunch failed for run_id=%s: %s", run_id, exc)
        return False


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def start_dev_run(goal: str) -> str:
    """Create state.json and launch the run as a detached systemd unit. Non-blocking."""
    run_id = _run_id()
    unit = _unit_name(run_id)
    state: dict = {
        "run_id": run_id,
        "goal": goal,
        "status": "running",
        "started_at": datetime.now(timezone.utc).isoformat(),
        "unit": unit,
        "rounds_done": 0,
        "session_id": None,
        "result": None,
        "resume_at": None,
        "error": None,
        "resumes_done": 0,
    }
    state_path = _state_path(run_id)
    _write_state_file(state_path, state)

    cmd = _build_launch_cmd(run_id)
    try:
        subprocess.run(cmd, check=True, capture_output=True, timeout=30)
    except Exception as exc:  # noqa: BLE001
        log.error("systemd-run launch failed for run_id=%s: %s", run_id, exc)
        state["status"] = "error"
        state["error"] = str(exc)
        _write_state_file(state_path, state)
        _notify("Axi dev", f"No se pudo lanzar la tarea: {exc}")

    return run_id


def poll_dev_runs() -> list[dict]:
    """Check all active runs; resume interrupted/waiting ones. Returns transition list."""
    state_dir = _state_dir()
    if not state_dir.exists():
        return []

    transitions: list[dict] = []
    now = datetime.now(timezone.utc)
    max_wall = _max_wall_clock_s()
    max_res = _max_resumes()

    for run_dir in sorted(state_dir.iterdir()):
        if not run_dir.is_dir():
            continue
        state_file = run_dir / "state.json"
        if not state_file.exists():
            continue
        try:
            state = json.loads(state_file.read_text())
        except Exception:  # noqa: BLE001
            continue

        run_id = state.get("run_id", run_dir.name)
        status = state.get("status", "")
        if status not in ("running", "waiting_quota"):
            continue

        # Wall-clock guard (applies to both statuses)
        started_at_str = state.get("started_at")
        if started_at_str:
            try:
                started_at = datetime.fromisoformat(started_at_str)
                if (now - started_at).total_seconds() > max_wall:
                    try:
                        subprocess.run(
                            ["systemctl", "--user", "stop", _unit_name(run_id)],
                            capture_output=True, timeout=10,
                        )
                    except Exception:  # noqa: BLE001
                        pass
                    state["status"] = "needs_human"
                    state_file.write_text(json.dumps(state, indent=2))
                    _notify(
                        "Axi dev ⚠",
                        f"La tarea tardó demasiado y fue cancelada: {state.get('goal', '')[:80]}",
                    )
                    transitions.append({
                        "run_id": run_id,
                        "status": "needs_human",
                        "transition": "wall_clock_exceeded",
                    })
                    continue
            except Exception:  # noqa: BLE001
                pass

        if status == "waiting_quota":
            resume_at_str = state.get("resume_at")
            transition = None
            if resume_at_str:
                try:
                    resume_at = datetime.fromisoformat(resume_at_str)
                    if now >= resume_at:
                        if _relaunch_run(state):
                            state["status"] = "running"
                            state["resumes_done"] = state.get("resumes_done", 0) + 1
                            state_file.write_text(json.dumps(state, indent=2))
                            transition = "quota_resumed"
                except Exception:  # noqa: BLE001
                    pass
            transitions.append({"run_id": run_id, "status": state["status"], "transition": transition})
            continue

        # status == "running": check systemctl
        try:
            is_active_proc = subprocess.run(
                ["systemctl", "--user", "is-active", _unit_name(run_id)],
                capture_output=True, text=True, timeout=10,
            )
            unit_active = is_active_proc.stdout.strip() == "active"
        except Exception:  # noqa: BLE001
            unit_active = True  # assume still active on check failure

        if unit_active:
            transitions.append({"run_id": run_id, "status": "running", "transition": None})
            continue

        # Unit dead, state still "running" → interrupted
        resumes_done = state.get("resumes_done", 0)
        if resumes_done >= max_res:
            state["status"] = "needs_human"
            state_file.write_text(json.dumps(state, indent=2))
            _notify(
                "Axi dev ⚠",
                f"La tarea fue interrumpida demasiadas veces: {state.get('goal', '')[:80]}",
            )
            transitions.append({
                "run_id": run_id,
                "status": "needs_human",
                "transition": "max_resumes_exhausted",
            })
            continue

        state["status"] = "interrupted"
        state_file.write_text(json.dumps(state, indent=2))

        if _relaunch_run(state):
            state["status"] = "running"
            state["resumes_done"] = resumes_done + 1
            state_file.write_text(json.dumps(state, indent=2))
            transition = "resumed"
        else:
            transition = "relaunch_failed"

        transitions.append({"run_id": run_id, "status": state["status"], "transition": transition})

    return transitions


def list_runs() -> list[dict]:
    """Return all run state dicts, sorted by directory name (chronological)."""
    state_dir = _state_dir()
    if not state_dir.exists():
        return []
    runs = []
    for run_dir in sorted(state_dir.iterdir()):
        if not run_dir.is_dir():
            continue
        state_file = run_dir / "state.json"
        if state_file.exists():
            try:
                runs.append(json.loads(state_file.read_text()))
            except Exception:  # noqa: BLE001
                pass
    return runs


def get_run(run_id: str) -> dict | None:
    """Return the state dict for a single run, or None if not found."""
    return _read_state(run_id)


def reattach_dev_runs() -> list[dict]:
    """Poll once at daemon startup to resume any runs that were active before restart."""
    try:
        return poll_dev_runs()
    except Exception as exc:  # noqa: BLE001
        log.warning("reattach_dev_runs failed: %s", exc)
        return []
