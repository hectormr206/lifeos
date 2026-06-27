"""Isolated test-instance launcher for dev environments.

Launches an environment's worktree dashboard on its OWN port, pointed at
THROWAWAY databases, so you can interact with the new version of LifeOS without
touching your real data. Model servers (brain, VT-3B, whisper, nano, embeddings)
are SHARED via the copied config — they rarely change and re-running them per
environment would waste VRAM.

Isolation knobs (verified against the app's path resolution):
  XDG_STATE_HOME   → axi DBs (memory.db, events.db) + key + locks  (throwaway)
  LIFEOS_STATE_DIR → lifeos domain DBs                              (throwaway)
  XDG_CONFIG_HOME  → axi config.json: a COPY of the real one with the port
                     overridden, so real model URLs / keys / flags carry over
  PYTHONPATH       → the worktree's axi/src + lifeos/src (its code shadows the
                     live editable install — same trick the test runner uses)

The real daemon socket is deliberately NOT shared: the isolated instance's voice
path stays inert so it can never reach the real daemon (which would write to
real data). This is the dashboard-web isolation level the user chose.

Public surface:
    start_instance(env_id)  → {"ok", "instance"|"error"}
    stop_instance(env_id)   → {"ok"}
    instance_status(env_id) → {"status", "port", "url", ...} | None
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import socket
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from axi import dev_env, dev_run

log = logging.getLogger("axi.dev_env_instance")


# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------


def _venv_python() -> str:
    from axi import config  # noqa: PLC0415
    return os.path.expanduser(
        config.get("dev_director_venv_python", "~/LifeOS/lifeos/axi/.venv/bin/python")
    )


def _worktree_root_dir() -> str:
    from axi import config  # noqa: PLC0415
    return os.path.expanduser(config.get("dev_env_worktree_dir", "~/LifeOS/dev-envs"))


def _port_range() -> tuple[int, int]:
    from axi import config  # noqa: PLC0415
    base = int(config.get("dev_env_instance_port_base", 8092))
    count = int(config.get("dev_env_instance_port_count", 24))
    return base, count


def _seed_from_real() -> bool:
    from axi import config  # noqa: PLC0415
    return bool(config.get("dev_env_instance_seed_from_real", False))


def _real_config_path() -> Path:
    cfg_home = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config"
    )
    return Path(cfg_home) / "axi" / "config.json"


def _real_axi_state_dir() -> Path:
    state_home = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return Path(state_home) / "axi"


def _real_lifeos_state_dir() -> Path:
    return Path(
        os.environ.get("LIFEOS_STATE_DIR")
        or os.path.join(os.path.expanduser("~"), ".local", "state", "lifeos")
    )


def _unit_name(env_id: str) -> str:
    return f"axi-env-inst-{env_id}"


def _instance_root(env_id: str) -> Path:
    # Sibling of the env's worktree: <worktree_dir>/<env_id>/instance
    return Path(_worktree_root_dir()) / env_id / "instance"


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------


def _find_free_port(base: int, count: int) -> int | None:
    """Return the first bindable 127.0.0.1 port in [base, base+count), or None."""
    for port in range(base, base + count):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    return None


def _unit_active(unit: str) -> bool:
    if not unit:
        return False
    try:
        proc = subprocess.run(
            ["systemctl", "--user", "is-active", unit],
            capture_output=True, text=True, timeout=10,
        )
        return proc.stdout.strip() == "active"
    except Exception:  # noqa: BLE001
        return False


def _save_instance(env_id: str, instance: dict | None) -> None:
    state = dev_run.get_run(env_id)
    if state is None:
        return
    state["instance"] = instance
    dev_run._write_state_file(dev_run._state_path(env_id), state)  # noqa: SLF001


def _seed_isolated_dbs(state_home: Path, lifeos_state: Path) -> None:
    """Copy the real (encrypted) DBs + keys into the isolated dirs so the
    instance tests against actual data. The copies are throwaway; the real DBs
    are never opened by the instance. Best-effort — a missing DB is skipped."""
    real_axi = _real_axi_state_dir()
    dest_axi = state_home / "axi"
    dest_axi.mkdir(parents=True, exist_ok=True)
    for name in ("memory.db", "memory.key", "events.db"):
        src = real_axi / name
        if src.exists():
            try:
                shutil.copy2(src, dest_axi / name)
            except OSError as exc:  # noqa: PERF203
                log.info("seed: could not copy %s (%s)", name, exc)

    real_lifeos = _real_lifeos_state_dir()
    lifeos_state.mkdir(parents=True, exist_ok=True)
    if real_lifeos.is_dir():
        for src in real_lifeos.glob("*.db"):
            try:
                shutil.copy2(src, lifeos_state / src.name)
            except OSError as exc:  # noqa: PERF203
                log.info("seed: could not copy %s (%s)", src.name, exc)
        for src in real_lifeos.glob("*.key"):
            try:
                shutil.copy2(src, lifeos_state / src.name)
            except OSError as exc:  # noqa: PERF203
                log.info("seed: could not copy %s (%s)", src.name, exc)


def _build_isolated_config(cfg_home: Path, port: int) -> None:
    """Write an isolated config.json: a copy of the real one with the dashboard
    port/host overridden so the instance binds elsewhere but keeps real model
    URLs, keys, and feature flags (so it shares the running model servers)."""
    real_cfg = _real_config_path()
    cfg: dict = {}
    if real_cfg.exists():
        try:
            cfg = json.loads(real_cfg.read_text())
        except Exception:  # noqa: BLE001
            cfg = {}
    cfg["dashboard_port"] = port
    cfg["dashboard_host"] = "127.0.0.1"
    axi_cfg_dir = cfg_home / "axi"
    axi_cfg_dir.mkdir(parents=True, exist_ok=True)
    (axi_cfg_dir / "config.json").write_text(
        json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8"
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def start_instance(env_id: str) -> dict:
    """Launch (or re-attach to) the environment's isolated test dashboard.

    Returns {"ok": True, "instance": {...}, "already": bool} or
    {"ok": False, "error": "..."}. Never raises.
    """
    env = dev_env.get_env(env_id)
    if env is None:
        return {"ok": False, "error": "environment not found"}
    worktree = env.get("worktree_path")
    if not worktree or not os.path.isdir(worktree):
        return {"ok": False, "error": "environment has no worktree yet"}

    existing = env.get("instance") or {}
    if existing.get("status") == "running" and _unit_active(existing.get("unit", "")):
        return {"ok": True, "instance": existing, "already": True}

    port = _find_free_port(*_port_range())
    if port is None:
        return {"ok": False, "error": "no free port in the configured range"}

    root = _instance_root(env_id)
    state_home = root / "state"
    cfg_home = root / "config"
    lifeos_state = root / "lifeos"
    for d in (state_home, lifeos_state):
        d.mkdir(parents=True, exist_ok=True)

    try:
        _build_isolated_config(cfg_home, port)
        if _seed_from_real():
            _seed_isolated_dbs(state_home, lifeos_state)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"could not prepare isolated dirs: {exc}"}

    pythonpath = f"{worktree}/axi/src:{worktree}/lifeos/src"
    unit = _unit_name(env_id)
    cmd = [
        "systemd-run", "--user", "--collect", f"--unit={unit}",
        f"--setenv=XDG_STATE_HOME={state_home}",
        f"--setenv=XDG_CONFIG_HOME={cfg_home}",
        f"--setenv=LIFEOS_STATE_DIR={lifeos_state}",
        f"--setenv=PYTHONPATH={pythonpath}",
        f"--working-directory={worktree}",
        _venv_python(), "-m", "axi.dashboard",
    ]
    try:
        subprocess.run(cmd, check=True, capture_output=True, timeout=30)
    except Exception as exc:  # noqa: BLE001
        log.error("instance launch failed for env_id=%s: %s", env_id, exc)
        return {"ok": False, "error": f"launch failed: {exc}"}

    instance = {
        "status": "running",
        "port": port,
        "unit": unit,
        "url": f"http://127.0.0.1:{port}",
        "dir": str(root),
        "started_at": datetime.now(timezone.utc).isoformat(),
    }
    _save_instance(env_id, instance)
    return {"ok": True, "instance": instance, "already": False}


def stop_instance(env_id: str) -> dict:
    """Stop the environment's isolated test dashboard. Idempotent; never raises."""
    env = dev_env.get_env(env_id)
    if env is None:
        return {"ok": False, "error": "environment not found"}
    instance = env.get("instance") or {}
    unit = instance.get("unit") or _unit_name(env_id)
    try:
        subprocess.run(
            ["systemctl", "--user", "stop", unit],
            capture_output=True, timeout=15,
        )
    except Exception as exc:  # noqa: BLE001
        log.info("stop_instance: systemctl stop failed for %s (%s)", unit, exc)
    if instance:
        instance["status"] = "stopped"
        _save_instance(env_id, instance)
    return {"ok": True}


def instance_status(env_id: str) -> dict | None:
    """Return the (refreshed) instance info for an environment, or None if it has
    never been launched. Reconciles the stored status against systemctl."""
    env = dev_env.get_env(env_id)
    if env is None:
        return None
    instance = env.get("instance")
    if not instance:
        return None
    active = _unit_active(instance.get("unit", ""))
    new_status = "running" if active else "stopped"
    if instance.get("status") != new_status:
        instance["status"] = new_status
        _save_instance(env_id, instance)
    return instance
