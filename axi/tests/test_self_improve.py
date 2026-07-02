"""Tests for axi.self_improve — pure scheduling gate + enforced dev-engine guard.

All logic here is pure; the land-guard tests mock git/push exactly like
test_dev_land.py (never touch a real origin).
"""
from __future__ import annotations

import json
import types
from datetime import datetime
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from axi import self_improve as si


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _dt(hour: int) -> datetime:
    return datetime(2026, 7, 2, hour, 0, 0)


def _fake_config(overrides: dict):
    class _Cfg:
        def get(self, key, default=None):
            return overrides.get(key, default)
    return _Cfg()


def _make_proc(returncode: int = 0, stdout: str = "", stderr: str = "") -> MagicMock:
    p = MagicMock()
    p.returncode = returncode
    p.stdout = stdout
    p.stderr = stderr
    return p


# ---------------------------------------------------------------------------
# should_fire_self_improve
# ---------------------------------------------------------------------------


def _base_kwargs(**over):
    kw = dict(
        now=_dt(3),
        enabled=True,
        on_battery=False,
        target_hour=3,
        last_fired_date=None,
        today="2026-07-02",
    )
    kw.update(over)
    return kw


def test_fires_when_all_conditions_hold():
    assert si.should_fire_self_improve(**_base_kwargs()) is True


def test_blocked_when_disabled():
    assert si.should_fire_self_improve(**_base_kwargs(enabled=False)) is False


def test_blocked_on_battery():
    assert si.should_fire_self_improve(**_base_kwargs(on_battery=True)) is False


def test_blocked_on_hour_mismatch():
    assert si.should_fire_self_improve(**_base_kwargs(now=_dt(4))) is False


def test_blocked_same_day_refire():
    assert si.should_fire_self_improve(
        **_base_kwargs(last_fired_date="2026-07-02")
    ) is False


def test_fires_when_last_fired_was_a_different_day():
    assert si.should_fire_self_improve(
        **_base_kwargs(last_fired_date="2026-07-01")
    ) is True


@pytest.mark.parametrize("flip", ["enabled", "on_battery", "hour", "same_day"])
def test_each_condition_alone_blocks(flip):
    kw = _base_kwargs()
    if flip == "enabled":
        kw["enabled"] = False
    elif flip == "on_battery":
        kw["on_battery"] = True
    elif flip == "hour":
        kw["now"] = _dt(2)
    elif flip == "same_day":
        kw["last_fired_date"] = "2026-07-02"
    assert si.should_fire_self_improve(**kw) is False


# ---------------------------------------------------------------------------
# violates_dev_engine_guard
# ---------------------------------------------------------------------------


def test_guard_flags_protected_paths():
    changed = [
        "axi/src/axi/dev_director.py",
        "lifeos/src/lifeos/health/ingestion.py",
        "axi/src/axi/dev_land.py",
    ]
    offenders = si.violates_dev_engine_guard(changed)
    assert offenders == [
        "axi/src/axi/dev_director.py",
        "axi/src/axi/dev_land.py",
    ]


def test_guard_empty_for_innocuous_paths():
    changed = [
        "lifeos/src/lifeos/health/ingestion.py",
        "axi/tests/test_something.py",
        "README.md",
    ]
    assert si.violates_dev_engine_guard(changed) == []


def test_guard_matches_absolute_paths():
    changed = ["/home/x/LifeOS/lifeos/axi/src/axi/self_improve.py"]
    assert si.violates_dev_engine_guard(changed) == changed


def test_guard_handles_empty_input():
    assert si.violates_dev_engine_guard([]) == []
    assert si.violates_dev_engine_guard(None) == []


# ---------------------------------------------------------------------------
# changed_paths_from_patch
# ---------------------------------------------------------------------------


def test_changed_paths_from_git_patch():
    patch = (
        "diff --git a/axi/src/axi/dev_director.py b/axi/src/axi/dev_director.py\n"
        "index abc..def 100644\n"
        "--- a/axi/src/axi/dev_director.py\n"
        "+++ b/axi/src/axi/dev_director.py\n"
        "@@ -1 +1 @@\n-old\n+new\n"
        "diff --git a/foo.py b/foo.py\n"
        "--- a/foo.py\n"
        "+++ b/foo.py\n"
        "@@ -1 +1 @@\n-x\n+y\n"
    )
    assert si.changed_paths_from_patch(patch) == [
        "axi/src/axi/dev_director.py",
        "foo.py",
    ]


def test_changed_paths_handles_deletion():
    patch = (
        "diff --git a/gone.py b/gone.py\n"
        "deleted file mode 100644\n"
        "--- a/gone.py\n"
        "+++ /dev/null\n"
    )
    assert si.changed_paths_from_patch(patch) == ["gone.py"]


# ---------------------------------------------------------------------------
# append_outcome_log
# ---------------------------------------------------------------------------


def test_append_outcome_log_writes_jsonl(tmp_path):
    rec = si.build_outcome_record(
        run_id="r1", started_at="2026-07-02T03:00:00", goal="g" * 500,
        status="started",
    )
    si.append_outcome_log(tmp_path, rec)
    si.append_outcome_log(tmp_path, si.build_outcome_record(
        run_id="r1", started_at="2026-07-02T03:00:00", goal="x",
        status="landed", changed_paths=["foo.py"],
    ))
    lines = (tmp_path / "self_improve_log.jsonl").read_text().splitlines()
    assert len(lines) == 2
    first = json.loads(lines[0])
    assert first["run_id"] == "r1"
    assert first["status"] == "started"
    assert len(first["goal"]) == 200  # truncated
    assert first["guard_blocked"] is False
    second = json.loads(lines[1])
    assert second["changed_paths"] == ["foo.py"]


def test_append_outcome_log_never_raises(monkeypatch):
    # A non-writable / bogus dir must not raise.
    si.append_outcome_log("/proc/nonexistent-cannot-write-zzz", {"x": 1})


# ---------------------------------------------------------------------------
# Land guard enforcement (dev_land) — mock git/push, never touch real origin
# ---------------------------------------------------------------------------


def _patch_touching(paths: list[str]) -> str:
    chunks = []
    for p in paths:
        chunks.append(
            f"diff --git a/{p} b/{p}\n--- a/{p}\n+++ b/{p}\n@@ -1 +1 @@\n-old\n+new\n"
        )
    return "".join(chunks)


def _setup_land(tmp_path, monkeypatch, *, origin: str, patch_paths: list[str]):
    from axi import dev_land

    run_id = "20260702-030000-abc123"
    results_dir = tmp_path / "dev-results"
    results_dir.mkdir()
    (results_dir / f"{run_id}-ts.patch").write_text(_patch_touching(patch_paths))

    written_states: list[dict] = []
    state_json_path = tmp_path / "state.json"

    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: {
            "run_id": rid, "goal": "improve", "status": "done",
            "origin": origin, "started_at": "2026-07-02T03:00:00+00:00",
        },
        _state_path=lambda rid: state_json_path,
        _write_state_file=lambda p, s: written_states.append(dict(s)),
    ))
    monkeypatch.setattr("axi.dev_land.config", _fake_config({
        "dev_director_repo": str(tmp_path / "repo"),
        "dev_director_results_dir": str(results_dir),
        "dev_run_state_dir": str(tmp_path / "runs"),
    }))

    subprocess_calls: list[list[str]] = []

    def fake_subprocess_run(cmd, **kwargs):
        subprocess_calls.append(list(cmd))
        return _make_proc(returncode=0)

    monkeypatch.setattr("axi.dev_land.subprocess.run", fake_subprocess_run)

    create_calls: list = []
    cleanup_calls: list = []
    monkeypatch.setattr("axi.dev_land._create_worktree",
                        lambda *a: (create_calls.append(a) or (True, "")))
    monkeypatch.setattr("axi.dev_land._cleanup_worktree",
                        lambda *a: cleanup_calls.append(a))

    return dev_land, run_id, {
        "written_states": written_states,
        "subprocess_calls": subprocess_calls,
        "create_calls": create_calls,
        "cleanup_calls": cleanup_calls,
        "state_dir": tmp_path / "runs",
    }


def test_self_improve_run_touching_dev_engine_is_refused(tmp_path, monkeypatch):
    dev_land, run_id, ctx = _setup_land(
        tmp_path, monkeypatch,
        origin="self_improve",
        patch_paths=["axi/src/axi/dev_director.py"],
    )
    result = dev_land.land_run(run_id)

    assert result["ok"] is False
    assert result["guard_blocked"] is True
    assert result["offenders"] == ["axi/src/axi/dev_director.py"]
    assert "motor de desarrollo" in result["error"]

    # No worktree, no git commands, no push.
    assert ctx["create_calls"] == []
    all_cmds = [" ".join(c) for c in ctx["subprocess_calls"]]
    assert all("push" not in c for c in all_cmds)

    # State marked blocked; outcome log written.
    assert ctx["written_states"][-1]["guard_blocked"] is True
    log_lines = (ctx["state_dir"] / "self_improve_log.jsonl").read_text().splitlines()
    assert json.loads(log_lines[-1])["status"] == "blocked"


def test_user_run_touching_dev_engine_is_allowed(tmp_path, monkeypatch):
    dev_land, run_id, ctx = _setup_land(
        tmp_path, monkeypatch,
        origin="user",
        patch_paths=["axi/src/axi/dev_director.py"],
    )
    result = dev_land.land_run(run_id)

    assert result["ok"] is True, result
    assert result["branch"] == f"axi/land/{run_id}"
    # Guard not applied → worktree created + push attempted.
    assert len(ctx["create_calls"]) == 1
    all_cmds = [" ".join(c) for c in ctx["subprocess_calls"]]
    assert any("git push" in c for c in all_cmds)


def test_self_improve_run_innocuous_files_lands(tmp_path, monkeypatch):
    dev_land, run_id, ctx = _setup_land(
        tmp_path, monkeypatch,
        origin="self_improve",
        patch_paths=["lifeos/src/lifeos/health/ingestion.py"],
    )
    result = dev_land.land_run(run_id)

    assert result["ok"] is True, result
    assert len(ctx["create_calls"]) == 1
    all_cmds = [" ".join(c) for c in ctx["subprocess_calls"]]
    assert any("git push" in c for c in all_cmds)
    # Landed outcome logged.
    log_lines = (ctx["state_dir"] / "self_improve_log.jsonl").read_text().splitlines()
    assert json.loads(log_lines[-1])["status"] == "landed"


# ---------------------------------------------------------------------------
# start_dev_run origin tag
# ---------------------------------------------------------------------------


def test_start_dev_run_default_origin_is_user(tmp_path):
    import axi.dev_run as dev_run_mod
    from subprocess import CompletedProcess

    def cfg(key, default=None):
        return {"dev_run_state_dir": str(tmp_path / "runs")}.get(key, default)

    def fake_run(cmd, **kw):
        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    with patch("axi.config.get", side_effect=cfg), \
         patch("axi.dev_run.subprocess.run", side_effect=fake_run):
        run_id = dev_run_mod.start_dev_run("do X")

    state = json.loads((tmp_path / "runs" / run_id / "state.json").read_text())
    assert state["origin"] == "user"


def test_start_dev_run_self_improve_origin_recorded(tmp_path):
    import axi.dev_run as dev_run_mod
    from subprocess import CompletedProcess

    def cfg(key, default=None):
        return {"dev_run_state_dir": str(tmp_path / "runs")}.get(key, default)

    def fake_run(cmd, **kw):
        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    with patch("axi.config.get", side_effect=cfg), \
         patch("axi.dev_run.subprocess.run", side_effect=fake_run):
        run_id = dev_run_mod.start_dev_run("nightly", origin="self_improve")

    state = json.loads((tmp_path / "runs" / run_id / "state.json").read_text())
    assert state["origin"] == "self_improve"
