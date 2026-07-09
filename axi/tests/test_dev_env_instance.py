"""Tests for axi.dev_env_instance — the isolated test-instance launcher.

systemd-run / systemctl and port binding are mocked; a tmp dir stands in for
the worktree. No real services are launched.
"""
from __future__ import annotations

import json
import socket
from pathlib import Path
from unittest.mock import patch

import pytest

from axi import dev_env_instance, dev_run


class _OkProc:
    returncode = 0
    stdout = ""
    stderr = ""


@pytest.fixture
def inst_env(tmp_path, monkeypatch):
    """Throwaway state dir + patched config knobs + a fake real config to copy."""
    d = tmp_path / "dev-runs"
    monkeypatch.setattr(dev_run, "_state_dir", lambda: d)
    monkeypatch.setattr(dev_env_instance, "_worktree_root_dir", lambda: str(tmp_path / "dev-envs"))
    monkeypatch.setattr(dev_env_instance, "_venv_python", lambda: "/fake/venv/python")
    monkeypatch.setattr(dev_env_instance, "_port_range", lambda: (9000, 5))
    monkeypatch.setattr(dev_env_instance, "_seed_from_real", lambda: False)
    real_cfg = tmp_path / "realconfig.json"
    real_cfg.write_text(json.dumps({
        "dashboard_port": 8081,
        "nano_endpoint": "http://127.0.0.1:8090",
        "secret_flag": True,
    }))
    monkeypatch.setattr(dev_env_instance, "_real_config_path", lambda: real_cfg)
    # Keep tests hermetic — don't copy the machine's real TLS certs.
    monkeypatch.setattr(dev_env_instance, "_copy_tls_certs", lambda *a, **k: None)
    return d


def _make_ready_env(env_id: str, worktree: str, instance: dict | None = None) -> None:
    Path(worktree, "axi", "src").mkdir(parents=True, exist_ok=True)
    state = {
        "run_id": env_id, "kind": "env", "goal": "g", "title": "T",
        "status": "ready", "worktree_path": worktree, "branch": "axi/env/x",
    }
    if instance is not None:
        state["instance"] = instance
    dev_run._write_state_file(dev_run._state_path(env_id), state)


# ---------------------------------------------------------------------------
# start_instance
# ---------------------------------------------------------------------------


def test_start_instance_launches_with_isolation(inst_env, tmp_path, monkeypatch):
    env_id = "20260627-100000-abc123"
    worktree = str(tmp_path / "wt")
    _make_ready_env(env_id, worktree)
    monkeypatch.setattr(dev_env_instance, "_find_free_port", lambda b, c: 9003)

    launched: dict = {}

    def fake_run(cmd, **kw):
        launched["cmd"] = cmd
        return _OkProc()

    with patch("axi.dev_env_instance.subprocess.run", side_effect=fake_run):
        res = dev_env_instance.start_instance(env_id)

    assert res["ok"], res
    inst = res["instance"]
    assert inst["port"] == 9003
    assert inst["url"] == "https://127.0.0.1:9003"  # HTTPS via copied mkcert certs
    assert inst["status"] == "running"

    cmd = launched["cmd"]
    assert "systemd-run" in cmd and "axi.dashboard" in cmd
    assert "/fake/venv/python" in cmd
    # All isolation knobs are passed.
    assert any(c.startswith("--setenv=XDG_STATE_HOME=") for c in cmd)
    assert any(c.startswith("--setenv=LIFEOS_STATE_DIR=") for c in cmd)
    assert any(c.startswith("--setenv=XDG_CONFIG_HOME=") for c in cmd)
    pp = [c for c in cmd if c.startswith("--setenv=PYTHONPATH=")][0]
    assert f"{worktree}/axi/src" in pp and f"{worktree}/lifeos/src" in pp

    # Isolated config: real values preserved, port overridden so it shares the
    # running model servers but binds on its own port.
    # element is "--setenv=XDG_CONFIG_HOME=<path>" → path is after the 2nd '='
    cfg_home = [c for c in cmd if c.startswith("--setenv=XDG_CONFIG_HOME=")][0].split("=", 2)[2]
    cfg = json.loads((Path(cfg_home) / "axi" / "config.json").read_text())
    assert cfg["dashboard_port"] == 9003
    # Bind the SAME host as the real dashboard (0.0.0.0) so the instance is
    # reachable from the phone/LAN, not forced to localhost-only.
    assert cfg["dashboard_host"] == "0.0.0.0"
    assert cfg["secret_flag"] is True
    assert cfg["nano_endpoint"] == "http://127.0.0.1:8090"

    # Persisted to env state.
    assert dev_run.get_run(env_id)["instance"]["port"] == 9003


def test_start_instance_unknown_env(inst_env):
    assert dev_env_instance.start_instance("nope")["ok"] is False


def test_start_instance_without_worktree(inst_env):
    env_id = "20260627-100001-def456"
    dev_run._write_state_file(
        dev_run._state_path(env_id),
        {"run_id": env_id, "kind": "env", "status": "running", "worktree_path": None},
    )
    res = dev_env_instance.start_instance(env_id)
    assert res["ok"] is False
    assert "worktree" in res["error"]


def test_start_instance_already_running_reattaches(inst_env, tmp_path, monkeypatch):
    env_id = "20260627-100002-ghi789"
    worktree = str(tmp_path / "wt2")
    inst = {"status": "running", "unit": dev_env_instance._unit_name(env_id),
            "port": 9001, "url": "http://127.0.0.1:9001"}
    _make_ready_env(env_id, worktree, instance=inst)
    monkeypatch.setattr(dev_env_instance, "_unit_active", lambda u: True)

    with patch("axi.dev_env_instance.subprocess.run", side_effect=AssertionError("must not relaunch")):
        res = dev_env_instance.start_instance(env_id)
    assert res["ok"] and res["already"] is True
    assert res["instance"]["port"] == 9001


def test_start_instance_no_free_port(inst_env, tmp_path, monkeypatch):
    env_id = "20260627-100003-jkl000"
    worktree = str(tmp_path / "wt3")
    _make_ready_env(env_id, worktree)
    monkeypatch.setattr(dev_env_instance, "_find_free_port", lambda b, c: None)
    res = dev_env_instance.start_instance(env_id)
    assert res["ok"] is False and "free port" in res["error"]


# ---------------------------------------------------------------------------
# stop_instance / instance_status
# ---------------------------------------------------------------------------


def test_stop_instance_marks_stopped(inst_env, tmp_path):
    env_id = "20260627-100004-mno111"
    worktree = str(tmp_path / "wt4")
    unit = dev_env_instance._unit_name(env_id)
    _make_ready_env(env_id, worktree, instance={"status": "running", "unit": unit, "port": 9002})

    calls: dict = {}

    def fake_run(cmd, **kw):
        calls["cmd"] = cmd
        return _OkProc()

    with patch("axi.dev_env_instance.subprocess.run", side_effect=fake_run):
        res = dev_env_instance.stop_instance(env_id)

    assert res["ok"]
    assert "stop" in calls["cmd"] and unit in calls["cmd"]
    assert dev_run.get_run(env_id)["instance"]["status"] == "stopped"


def test_instance_status_reconciles_with_systemctl(inst_env, tmp_path, monkeypatch):
    env_id = "20260627-100005-pqr222"
    worktree = str(tmp_path / "wt5")
    unit = dev_env_instance._unit_name(env_id)
    _make_ready_env(env_id, worktree, instance={"status": "running", "unit": unit, "port": 9004})
    # Unit is actually dead now → status should reconcile to "stopped".
    monkeypatch.setattr(dev_env_instance, "_unit_active", lambda u: False)
    info = dev_env_instance.instance_status(env_id)
    assert info["status"] == "stopped"
    assert dev_run.get_run(env_id)["instance"]["status"] == "stopped"


def test_instance_status_none_when_never_launched(inst_env, tmp_path):
    env_id = "20260627-100006-stu333"
    worktree = str(tmp_path / "wt6")
    _make_ready_env(env_id, worktree)  # no instance key
    assert dev_env_instance.instance_status(env_id) is None


# ---------------------------------------------------------------------------
# start_instance_for_worktree / stop_instance_for_worktree (preview path)
# ---------------------------------------------------------------------------


def test_start_instance_for_worktree_uses_preview_prefix(inst_env, tmp_path, monkeypatch):
    """The worktree variant launches an isolated instance WITHOUT touching
    dev_env: no get_env call, preview unit prefix, own port, url returned."""
    worktree = str(tmp_path / "preview-wt")
    Path(worktree, "axi", "src").mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(dev_env_instance, "_find_free_port", lambda b, c: 9010)
    # Fail loudly if the worktree path ever tries to resolve an env.
    import axi.dev_env as _de
    monkeypatch.setattr(_de, "get_env", lambda *a, **k: (_ for _ in ()).throw(
        AssertionError("start_instance_for_worktree must not call get_env")))

    launched: dict = {}

    def fake_run(cmd, **kw):
        launched["cmd"] = cmd
        return _OkProc()

    inst_id = "20260627-200000-prev01"
    with patch("axi.dev_env_instance.subprocess.run", side_effect=fake_run):
        res = dev_env_instance.start_instance_for_worktree(inst_id, worktree)

    assert res["ok"], res
    inst = res["instance"]
    assert inst["unit"] == f"axi-preview-inst-{inst_id}"
    assert inst["port"] == 9010
    assert inst["url"] == "https://127.0.0.1:9010"
    assert inst["status"] == "running"

    cmd = launched["cmd"]
    assert f"--unit=axi-preview-inst-{inst_id}" in cmd
    pp = [c for c in cmd if c.startswith("--setenv=PYTHONPATH=")][0]
    assert f"{worktree}/axi/src" in pp and f"{worktree}/lifeos/src" in pp


def test_start_instance_for_worktree_never_seeds_real_dbs(inst_env, tmp_path, monkeypatch):
    """A preview runs UNREVIEWED autonomous code — it must NEVER get seeded
    copies of the real DBs/keys, even if the global seed flag is ON."""
    worktree = str(tmp_path / "preview-wt-seed")
    Path(worktree, "axi", "src").mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(dev_env_instance, "_find_free_port", lambda b, c: 9020)
    # Global flag ON — the preview path must still refuse to seed.
    monkeypatch.setattr(dev_env_instance, "_seed_from_real", lambda: True)

    seeded: dict = {"called": False}
    monkeypatch.setattr(
        dev_env_instance, "_seed_isolated_dbs",
        lambda *a, **k: seeded.__setitem__("called", True),
    )

    with patch("axi.dev_env_instance.subprocess.run", side_effect=lambda cmd, **kw: _OkProc()):
        res = dev_env_instance.start_instance_for_worktree("seed-guard", worktree)

    assert res["ok"], res
    assert seeded["called"] is False  # seeding was skipped for the preview path


def test_start_instance_for_worktree_missing_path(inst_env, tmp_path):
    res = dev_env_instance.start_instance_for_worktree("x", str(tmp_path / "nope"))
    assert res["ok"] is False


def test_start_instance_for_worktree_no_free_port(inst_env, tmp_path, monkeypatch):
    worktree = str(tmp_path / "preview-wt2")
    Path(worktree, "axi", "src").mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(dev_env_instance, "_find_free_port", lambda b, c: None)
    res = dev_env_instance.start_instance_for_worktree("y", worktree)
    assert res["ok"] is False and "free port" in res["error"]


def test_stop_instance_for_worktree_stops_preview_unit(inst_env):
    inst_id = "20260627-200001-prev02"
    calls: dict = {}

    def fake_run(cmd, **kw):
        calls["cmd"] = cmd
        return _OkProc()

    with patch("axi.dev_env_instance.subprocess.run", side_effect=fake_run):
        res = dev_env_instance.stop_instance_for_worktree(inst_id)

    assert res["ok"]
    assert "stop" in calls["cmd"]
    assert f"axi-preview-inst-{inst_id}" in calls["cmd"]


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def test_find_free_port_returns_bindable_port():
    port = dev_env_instance._find_free_port(8092, 24)
    assert port is not None
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", port))  # confirm it is actually free
    finally:
        s.close()


def test_seed_copies_real_dbs(tmp_path, monkeypatch):
    real_axi = tmp_path / "real" / "axi"
    real_axi.mkdir(parents=True)
    (real_axi / "memory.db").write_bytes(b"enc-memory")
    (real_axi / "memory.key").write_text("deadbeef")
    real_lifeos = tmp_path / "real" / "lifeos"
    real_lifeos.mkdir(parents=True)
    (real_lifeos / "lifeos.db").write_bytes(b"enc-lifeos")
    (real_lifeos / "lifeos.key").write_text("cafe")

    monkeypatch.setattr(dev_env_instance, "_real_axi_state_dir", lambda: real_axi)
    monkeypatch.setattr(dev_env_instance, "_real_lifeos_state_dir", lambda: real_lifeos)

    state_home = tmp_path / "iso" / "state"
    lifeos_state = tmp_path / "iso" / "lifeos"
    dev_env_instance._seed_isolated_dbs(state_home, lifeos_state)

    assert (state_home / "axi" / "memory.db").read_bytes() == b"enc-memory"
    assert (state_home / "axi" / "memory.key").read_text() == "deadbeef"
    assert (lifeos_state / "lifeos.db").read_bytes() == b"enc-lifeos"
    assert (lifeos_state / "lifeos.key").read_text() == "cafe"


def test_launch_instance_marks_isolated_instance(monkeypatch, tmp_path):
    """Every isolated instance carries AXI_ISOLATED_INSTANCE so the dashboard it
    runs skips the preview orphan-sweep (which would otherwise stop its own unit)."""
    captured = {}

    def fake_run(cmd, **kw):
        captured["cmd"] = cmd
        class R:
            returncode = 0
            stdout = ""
            stderr = ""
        return R()

    import axi.dev_env_instance as di
    monkeypatch.setattr(di.subprocess, "run", fake_run)
    monkeypatch.setattr(di, "_find_free_port", lambda *a, **k: 8092)
    monkeypatch.setattr(di, "_build_isolated_config", lambda *a, **k: None)
    monkeypatch.setattr(di, "_copy_tls_certs", lambda *a, **k: None)
    monkeypatch.setattr(di, "_prepare_isolated_dirs", lambda *a, **k: (str(tmp_path), str(tmp_path), str(tmp_path)), raising=False)
    wt = tmp_path / "wt"; wt.mkdir()
    di.start_instance_for_worktree("20260101-000000-abcdef", str(wt))
    assert any("AXI_ISOLATED_INSTANCE=1" in str(a) for a in captured.get("cmd", [])), captured.get("cmd")
