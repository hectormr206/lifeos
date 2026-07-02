"""Tests for axi.dev_run and axi._dev_run_entry.

All subprocess calls, systemctl checks, and notify calls are mocked.
tmp_path is used as the state dir — never ~/LifeOS.
"""
from __future__ import annotations

import json
import sys
import types
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from subprocess import CalledProcessError, CompletedProcess
from unittest.mock import MagicMock, call, patch

import pytest

import axi.dev_run as dev_run_mod
import axi._dev_run_entry as entry_mod


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _fake_config(state_dir: Path, **overrides):
    defaults = {
        "dev_run_state_dir": str(state_dir),
        "dev_run_poll_interval_s": 300,
        "dev_run_max_wall_clock_s": 21600,
        "dev_run_quota_wait_default_s": 3600,
        "dev_run_max_resumes": 5,
        "dev_run_round_timeout_s": 3600,
        "dev_director_repo": "~/LifeOS/lifeos",
        "dev_director_max_rounds": 3,
        "dev_director_test_command": "tests/ -q",
        "dev_director_venv_python": "~/.venv/bin/python",
        "dev_director_branch_prefix": "axi/self-build",
        "dev_director_results_dir": "~/LifeOS/dev-results",
    }
    defaults.update(overrides)

    def _get(key, default=None):
        return defaults.get(key, default)

    return _get


@dataclass
class FakeLoopResult:
    goal: str = "test goal"
    branch: str = "axi/self-build/abc"
    rounds: list = field(default_factory=list)
    final_diff: str = "diff --git a/foo.py\n+pass\n"
    final_changed_files: list = field(default_factory=lambda: ["foo.py"])
    done: bool = True
    rounds_used: int = 1
    total_cost_usd: float = 0.01
    total_claude_turns: int = 3
    ok: bool = True
    error: str | None = None
    tests_passed: bool = True
    needs_human: bool = False
    escalation_reason: str = ""
    session_id: str | None = "sess-abc"


def _write_state(state_dir: Path, run_id: str, state: dict) -> Path:
    p = state_dir / run_id / "state.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(state))
    return p


def _read_state(state_dir: Path, run_id: str) -> dict:
    return json.loads((state_dir / run_id / "state.json").read_text())


def _base_state(run_id: str = "run-001", **overrides) -> dict:
    s = {
        "run_id": run_id,
        "goal": "test goal",
        "status": "running",
        "started_at": datetime.now(timezone.utc).isoformat(),
        "unit": f"axi-dev-{run_id}",
        "rounds_done": 0,
        "session_id": None,
        "result": None,
        "resume_at": None,
        "error": None,
        "resumes_done": 0,
    }
    s.update(overrides)
    return s


# ---------------------------------------------------------------------------
# dev_run.start_dev_run tests
# ---------------------------------------------------------------------------


def test_start_dev_run_writes_state_and_launches(tmp_path):
    """start_dev_run writes state.json and invokes systemd-run with correct args."""
    launched: list = []

    def fake_subprocess_run(cmd, **kwargs):
        launched.append(list(cmd))
        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    with patch("axi.config.get", side_effect=_fake_config(tmp_path / "runs")), \
         patch("axi.dev_run.subprocess.run", side_effect=fake_subprocess_run):
        run_id = dev_run_mod.start_dev_run("build feature X")

    assert run_id is not None

    state = _read_state(tmp_path / "runs", run_id)
    assert state["status"] == "running"
    assert state["goal"] == "build feature X"
    assert state["resumes_done"] == 0
    assert state["session_id"] is None

    assert len(launched) == 1
    cmd = launched[0]
    assert "systemd-run" in cmd
    assert "--user" in cmd
    assert "--collect" in cmd
    assert f"--unit=axi-dev-{run_id}" in cmd
    assert "-m" in cmd
    assert "axi._dev_run_entry" in cmd
    assert run_id in cmd


def test_start_dev_run_launch_failure(tmp_path):
    """If subprocess.run raises, state.json status becomes 'error'."""
    def boom(cmd, **kwargs):
        raise CalledProcessError(1, cmd, stderr="systemd unavailable")

    with patch("axi.config.get", side_effect=_fake_config(tmp_path / "runs")), \
         patch("axi.dev_run.subprocess.run", side_effect=boom), \
         patch("axi.dev_run._notify"):
        run_id = dev_run_mod.start_dev_run("failing goal")

    state = _read_state(tmp_path / "runs", run_id)
    assert state["status"] == "error"
    assert state["error"] is not None


# ---------------------------------------------------------------------------
# _dev_run_entry.main tests
# ---------------------------------------------------------------------------


def test_dev_run_entry_success(tmp_path):
    """Successful loop → status='done', patch saved, notify called."""
    state_dir = tmp_path / "runs"
    run_id = "run-success"
    results_dir = tmp_path / "results"
    _write_state(state_dir, run_id, _base_state(run_id))

    loop_result = FakeLoopResult(done=True, ok=True, session_id="sess-done")
    notified: list = []

    def fake_notify(title, body, **_kw):
        notified.append(title)

    cfg = _fake_config(state_dir, **{"dev_director_results_dir": str(results_dir)})

    with patch("axi.config.get", side_effect=cfg), \
         patch("axi.dev_director.run_director_loop", return_value=loop_result), \
         patch("axi._dev_run_entry._notify", side_effect=fake_notify):
        entry_mod.main(run_id)

    state = _read_state(state_dir, run_id)
    assert state["status"] == "done"
    assert state["session_id"] == "sess-done"

    patches = list(results_dir.glob("*.patch"))
    assert len(patches) == 1

    assert any("✓" in t or "dev" in t.lower() for t in notified)


def test_dev_run_entry_needs_human(tmp_path):
    """loop.needs_human=True → status='needs_human', notify called."""
    state_dir = tmp_path / "runs"
    run_id = "run-nh"
    _write_state(state_dir, run_id, _base_state(run_id))

    loop_result = FakeLoopResult(ok=True, done=False, needs_human=True,
                                  escalation_reason="tests never passed", session_id=None)
    notified: list = []

    with patch("axi.config.get", side_effect=_fake_config(state_dir)), \
         patch("axi.dev_director.run_director_loop", return_value=loop_result), \
         patch("axi._dev_run_entry._notify", side_effect=lambda t, b, **_: notified.append(t)):
        entry_mod.main(run_id)

    state = _read_state(state_dir, run_id)
    assert state["status"] == "needs_human"
    assert len(notified) == 1


def test_dev_run_entry_quota_error(tmp_path):
    """loop.ok=False with 'usage limit' in error → status='waiting_quota', no failure notify."""
    state_dir = tmp_path / "runs"
    run_id = "run-quota"
    _write_state(state_dir, run_id, _base_state(run_id))

    loop_result = FakeLoopResult(ok=False, done=False,
                                  error="Claude usage limit resets at midnight",
                                  session_id="sess-quota")
    notified: list = []

    with patch("axi.config.get", side_effect=_fake_config(state_dir)), \
         patch("axi.dev_director.run_director_loop", return_value=loop_result), \
         patch("axi._dev_run_entry._notify", side_effect=lambda t, b, **_: notified.append(t)):
        entry_mod.main(run_id)

    state = _read_state(state_dir, run_id)
    assert state["status"] == "waiting_quota"
    assert state["resume_at"] is not None
    assert state["session_id"] == "sess-quota"
    assert len(notified) == 0, "no failure notify expected for quota wait"


def test_dev_run_entry_unexpected_exception(tmp_path):
    """If run_director_loop raises, status='error' and notify is called."""
    state_dir = tmp_path / "runs"
    run_id = "run-exc"
    _write_state(state_dir, run_id, _base_state(run_id))

    notified: list = []

    with patch("axi.config.get", side_effect=_fake_config(state_dir)), \
         patch("axi.dev_director.run_director_loop", side_effect=RuntimeError("boom")), \
         patch("axi._dev_run_entry._notify", side_effect=lambda t, b, **_: notified.append(t)):
        entry_mod.main(run_id)

    state = _read_state(state_dir, run_id)
    assert state["status"] == "error"
    assert "boom" in (state["error"] or "")
    assert len(notified) == 1


# ---------------------------------------------------------------------------
# dev_run.poll_dev_runs tests
# ---------------------------------------------------------------------------


def test_poll_running_unit_active(tmp_path):
    """If the systemd unit is active, status is unchanged."""
    state_dir = tmp_path / "runs"
    run_id = "run-active"
    _write_state(state_dir, run_id, _base_state(run_id))

    def fake_subprocess_run(cmd, **kwargs):
        if "is-active" in cmd:
            return CompletedProcess(args=cmd, returncode=0, stdout="active\n", stderr="")
        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    with patch("axi.config.get", side_effect=_fake_config(state_dir)), \
         patch("axi.dev_run.subprocess.run", side_effect=fake_subprocess_run):
        transitions = dev_run_mod.poll_dev_runs()

    state = _read_state(state_dir, run_id)
    assert state["status"] == "running"
    assert len(transitions) == 1
    assert transitions[0]["transition"] is None


def test_poll_running_unit_dead_first_resume(tmp_path):
    """Unit dead + state='running' + resumes_done=0 → interrupted then relaunched."""
    state_dir = tmp_path / "runs"
    run_id = "run-dead"
    _write_state(state_dir, run_id, _base_state(run_id, session_id="sess-x", resumes_done=0))

    launched: list = []

    def fake_subprocess_run(cmd, **kwargs):
        if "is-active" in cmd:
            return CompletedProcess(args=cmd, returncode=1, stdout="inactive\n", stderr="")
        if "systemd-run" in cmd:
            launched.append(list(cmd))
            return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")
        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    with patch("axi.config.get", side_effect=_fake_config(state_dir)), \
         patch("axi.dev_run.subprocess.run", side_effect=fake_subprocess_run):
        transitions = dev_run_mod.poll_dev_runs()

    state = _read_state(state_dir, run_id)
    assert state["status"] == "running"
    assert state["resumes_done"] == 1
    assert len(launched) == 1
    assert run_id in launched[0]

    assert len(transitions) == 1
    assert transitions[0]["transition"] == "resumed"


def test_poll_running_unit_dead_max_resumes_exhausted(tmp_path):
    """resumes_done >= max_resumes → status='needs_human', no relaunch."""
    state_dir = tmp_path / "runs"
    run_id = "run-maxres"
    _write_state(state_dir, run_id, _base_state(run_id, resumes_done=5))

    launched: list = []
    notified: list = []

    def fake_subprocess_run(cmd, **kwargs):
        if "is-active" in cmd:
            return CompletedProcess(args=cmd, returncode=1, stdout="inactive\n", stderr="")
        if "systemd-run" in cmd:
            launched.append(cmd)
        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    with patch("axi.config.get", side_effect=_fake_config(state_dir)), \
         patch("axi.dev_run.subprocess.run", side_effect=fake_subprocess_run), \
         patch("axi.dev_run._notify", side_effect=lambda t, b: notified.append(t)):
        transitions = dev_run_mod.poll_dev_runs()

    state = _read_state(state_dir, run_id)
    assert state["status"] == "needs_human"
    assert len(launched) == 0
    assert len(notified) == 1
    assert transitions[0]["transition"] == "max_resumes_exhausted"


def test_poll_waiting_quota_resume_time_reached(tmp_path):
    """waiting_quota + resume_at in the past → unit relaunched."""
    state_dir = tmp_path / "runs"
    run_id = "run-quota-ready"
    past_time = (datetime.now(timezone.utc) - timedelta(seconds=10)).isoformat()
    _write_state(state_dir, run_id, _base_state(
        run_id, status="waiting_quota", resume_at=past_time, resumes_done=1,
    ))

    launched: list = []

    def fake_subprocess_run(cmd, **kwargs):
        if "systemd-run" in cmd:
            launched.append(list(cmd))
            return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")
        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    with patch("axi.config.get", side_effect=_fake_config(state_dir)), \
         patch("axi.dev_run.subprocess.run", side_effect=fake_subprocess_run):
        transitions = dev_run_mod.poll_dev_runs()

    state = _read_state(state_dir, run_id)
    assert state["status"] == "running"
    assert state["resumes_done"] == 2
    assert len(launched) == 1
    assert transitions[0]["transition"] == "quota_resumed"


def test_poll_wall_clock_exceeded(tmp_path):
    """started_at very old → status='needs_human', systemctl stop called."""
    state_dir = tmp_path / "runs"
    run_id = "run-old"
    ancient = (datetime.now(timezone.utc) - timedelta(hours=8)).isoformat()
    _write_state(state_dir, run_id, _base_state(run_id, started_at=ancient))

    stop_calls: list = []
    notified: list = []

    def fake_subprocess_run(cmd, **kwargs):
        if "stop" in cmd:
            stop_calls.append(list(cmd))
        return CompletedProcess(args=cmd, returncode=0, stdout="active\n", stderr="")

    with patch("axi.config.get", side_effect=_fake_config(state_dir)), \
         patch("axi.dev_run.subprocess.run", side_effect=fake_subprocess_run), \
         patch("axi.dev_run._notify", side_effect=lambda t, b: notified.append(t)):
        transitions = dev_run_mod.poll_dev_runs()

    state = _read_state(state_dir, run_id)
    assert state["status"] == "needs_human"
    assert any("stop" in " ".join(c) for c in stop_calls)
    assert len(notified) == 1
    assert transitions[0]["transition"] == "wall_clock_exceeded"


# ---------------------------------------------------------------------------
# dev_director session_id + resume (cross-module verification)
# ---------------------------------------------------------------------------


def test_dev_director_session_id_captured():
    """_run_claude captures session_id from JSON; returned as 5th element."""
    from axi.dev_director import _run_claude

    def fake_subprocess_run(cmd, **kwargs):
        stdout = json.dumps({
            "result": "done",
            "session_id": "sess-capture-test",
            "total_cost_usd": 0.02,
            "num_turns": 4,
            "is_error": False,
        })
        return CompletedProcess(args=list(cmd), returncode=0, stdout=stdout, stderr="")

    with patch("axi.dev_director.subprocess.run", side_effect=fake_subprocess_run), \
         patch("axi.dev_director._claude_resilience_flags", return_value=([], {})), \
         patch("axi.config.get", side_effect=lambda k, d=None: False if k == "dev_agent_sandbox" else d):
        summary, cost, turns, is_error, session_id = _run_claude("/tmp", "do stuff", 60.0, {})

    assert session_id == "sess-capture-test"
    assert is_error is False


def test_dev_director_resume_adds_flag():
    """resume_session_id → --resume <id> in the claude subprocess argv."""
    from axi.dev_director import _run_claude

    captured: list = []

    def fake_subprocess_run(cmd, **kwargs):
        captured.extend(cmd)
        stdout = json.dumps({
            "result": "ok",
            "session_id": "sess-new",
            "total_cost_usd": 0.0,
            "num_turns": 1,
            "is_error": False,
        })
        return CompletedProcess(args=list(cmd), returncode=0, stdout=stdout, stderr="")

    with patch("axi.dev_director.subprocess.run", side_effect=fake_subprocess_run), \
         patch("axi.dev_director._claude_resilience_flags", return_value=([], {})), \
         patch("axi.config.get", side_effect=lambda k, d=None: False if k == "dev_agent_sandbox" else d):
        _run_claude("/tmp", "instr", 60.0, {}, resume_session_id="old-sess-42")

    assert "--resume" in captured
    idx = captured.index("--resume")
    assert captured[idx + 1] == "old-sess-42"
