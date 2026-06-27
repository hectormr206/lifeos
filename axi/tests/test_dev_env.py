"""Tests for persistent dev environments (axi.dev_env) and the keep_worktree
engine mode in axi.dev_director.

External calls (Claude subprocess, pytest subprocess, VT-3B HTTP, systemd-run)
are mocked. A real throwaway git repo exercises the worktree path.
"""
from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest

from axi import dev_director, dev_env, dev_run
from axi.dev_director import DirectorLoopResult, run_director_loop
from tests.test_dev_director import _make_repo  # reuse the real-repo helper

_LOOP_KWARGS = dict(test_command="tests/ -q", venv_python="/fake/python")


# ---------------------------------------------------------------------------
# Engine: keep_worktree mode (the foundation of a persistent environment)
# ---------------------------------------------------------------------------


def _impl_claude(worktree, instruction, timeout, env, **_kw):
    (Path(worktree) / "impl.py").write_text("# impl\n")
    return ("done", 0.01, 2, False, None)


def test_keep_worktree_persists_and_returns_path(tmp_path):
    """keep_worktree=True leaves the worktree on disk under worktree_parent and
    reports its path; nothing is committed or pushed."""
    repo = _make_repo(tmp_path)
    wt_parent = tmp_path / "envs" / "env1"

    with patch.object(dev_director, "_run_claude", side_effect=_impl_claude), \
         patch.object(dev_director, "_run_tests", return_value=(True, "5 passed")), \
         patch.object(dev_director, "_review", return_value=("DONE", True)), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"):
        result = run_director_loop(
            "Add feature", str(repo), max_rounds=2, _branch_id="keepwt",
            keep_worktree=True, worktree_parent=str(wt_parent), **_LOOP_KWARGS,
        )

    assert result.ok and result.done, result.error
    assert result.worktree_path
    wt = Path(result.worktree_path)
    assert wt.is_dir()                       # NOT cleaned up
    assert (wt / "impl.py").exists()         # Claude's edits survive on disk
    assert str(wt).startswith(str(wt_parent))


def test_default_mode_cleans_worktree_and_reports_no_path(tmp_path):
    """Default (patch) mode deletes the worktree and leaves worktree_path empty."""
    repo = _make_repo(tmp_path)
    seen: dict = {}

    def claude(worktree, instruction, timeout, env, **_kw):
        seen["wt"] = worktree
        return _impl_claude(worktree, instruction, timeout, env)

    with patch.object(dev_director, "_run_claude", side_effect=claude), \
         patch.object(dev_director, "_run_tests", return_value=(True, "ok")), \
         patch.object(dev_director, "_review", return_value=("DONE", True)), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"):
        result = run_director_loop(
            "Add feature", str(repo), max_rounds=1, _branch_id="cleanwt", **_LOOP_KWARGS,
        )

    assert result.worktree_path == ""
    assert not Path(seen["wt"]).exists()     # cleaned up


def test_keep_worktree_resume_reuses_existing(tmp_path):
    """A second run with the same branch id + worktree_parent reuses the existing
    worktree instead of failing on `git worktree add` (the env resume path)."""
    repo = _make_repo(tmp_path)
    wt_parent = tmp_path / "envs" / "env2"
    patches = lambda: (  # noqa: E731
        patch.object(dev_director, "_run_claude", side_effect=_impl_claude),
        patch.object(dev_director, "_run_tests", return_value=(True, "ok")),
        patch.object(dev_director, "_review", return_value=("DONE", True)),
        patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"),
    )

    def run_once():
        ps = patches()
        for p in ps:
            p.start()
        try:
            return run_director_loop(
                "g", str(repo), max_rounds=1, _branch_id="reuse",
                keep_worktree=True, worktree_parent=str(wt_parent), **_LOOP_KWARGS,
            )
        finally:
            for p in ps:
                p.stop()

    r1 = run_once()
    r2 = run_once()
    assert r1.ok, r1.error
    assert r2.ok, r2.error                   # did NOT fail on the existing worktree
    assert r1.worktree_path == r2.worktree_path


# ---------------------------------------------------------------------------
# dev_env: create / list / get
# ---------------------------------------------------------------------------


class _OkProc:
    returncode = 0
    stdout = ""
    stderr = ""


@pytest.fixture
def env_dir(tmp_path, monkeypatch):
    """Point both dev_run and the detached entry at a throwaway state dir."""
    d = tmp_path / "dev-runs"
    monkeypatch.setattr(dev_run, "_state_dir", lambda: d)
    from axi import _dev_run_entry
    monkeypatch.setattr(_dev_run_entry, "_state_path", lambda rid: d / rid / "state.json")
    return d


def test_create_env_writes_state_and_launches(env_dir, monkeypatch):
    monkeypatch.setattr(dev_env, "_generate_meta", lambda g: ("Mi título", "Una descripción"))
    launched: dict = {}

    def fake_run(cmd, **kw):
        launched["cmd"] = cmd
        return _OkProc()

    with patch("axi.dev_env.subprocess.run", side_effect=fake_run):
        env_id = dev_env.create_env("agregá un kanban a salud")

    assert env_id
    state = dev_run.get_run(env_id)
    assert state["kind"] == "env"
    assert state["title"] == "Mi título"
    assert state["description"] == "Una descripción"
    assert state["goal"] == "agregá un kanban a salud"
    assert state["status"] == "running"
    assert state["branch_id"]
    assert state["worktree_path"] is None
    # Reuses the SAME detached entry as ephemeral dev-runs.
    assert "systemd-run" in launched["cmd"]
    assert "axi._dev_run_entry" in launched["cmd"]


def test_list_and_get_envs_filter_by_kind(env_dir, monkeypatch):
    monkeypatch.setattr(dev_env, "_generate_meta", lambda g: ("T", "D"))
    with patch("axi.dev_env.subprocess.run", return_value=_OkProc()):
        e1 = dev_env.create_env("goal one")
        e2 = dev_env.create_env("goal two")
    # An ephemeral patch run sharing the same dir must NOT show up as an env.
    dev_run._write_state_file(
        dev_run._state_path("patchrun"),
        {"run_id": "patchrun", "kind": "patch", "status": "done"},
    )

    ids = [e["run_id"] for e in dev_env.list_envs()]
    assert e1 in ids and e2 in ids
    assert "patchrun" not in ids
    assert dev_env.get_env("patchrun") is None     # not an environment
    assert dev_env.get_env(e1)["run_id"] == e1
    assert dev_env.get_env("nope") is None


def test_create_env_launch_failure_marks_error(env_dir, monkeypatch):
    monkeypatch.setattr(dev_env, "_generate_meta", lambda g: ("T", "D"))
    with patch("axi.dev_env.subprocess.run", side_effect=RuntimeError("no systemd")), \
         patch.object(dev_env.dev_run, "_notify"):
        env_id = dev_env.create_env("goal")
    state = dev_run.get_run(env_id)
    assert state["status"] == "error"
    assert "no systemd" in state["error"]


# ---------------------------------------------------------------------------
# dev_env: title/description generation
# ---------------------------------------------------------------------------


def test_generate_meta_parses_two_lines():
    raw = "TITULO: Export CSV finanzas\nDESCRIPCION: Permite exportar movimientos a CSV"
    with patch("axi.dev_director._call_vt3b", return_value=raw):
        title, desc = dev_env._generate_meta("exportar a csv")
    assert title == "Export CSV finanzas"
    assert desc == "Permite exportar movimientos a CSV"


def test_generate_meta_fallback_on_model_failure():
    with patch("axi.dev_director._call_vt3b", side_effect=RuntimeError("down")):
        title, desc = dev_env._generate_meta("agregá soporte de export a CSV en finanzas")
    assert title                       # goal-derived, non-empty
    assert "export" in desc.lower()


def test_generate_meta_fallback_on_unparseable():
    with patch("axi.dev_director._call_vt3b", return_value="garbage with no labels"):
        title, desc = dev_env._generate_meta("hacer algo concreto y útil")
    assert title and desc              # fell back, did not crash


def test_card_status_mapping():
    assert dev_env.card_status({"status": "running"}) == "developing"
    assert dev_env.card_status({"status": "interrupted"}) == "developing"
    assert dev_env.card_status({"status": "ready"}) == "ready"
    assert dev_env.card_status({"status": "needs_human"}) == "needs_human"
    assert dev_env.card_status({"status": "error"}) == "error"
    assert dev_env.card_status({"status": "weird"}) == "developing"


# ---------------------------------------------------------------------------
# Detached entry: env path drives keep_worktree and marks "ready"
# ---------------------------------------------------------------------------


def test_entry_env_path_keeps_worktree_and_marks_ready(env_dir):
    from axi import _dev_run_entry
    env_id = "20260627-000000-aaaaaa"
    dev_run._write_state_file(
        dev_run._state_path(env_id),
        {
            "run_id": env_id, "kind": "env", "goal": "g", "title": "T",
            "branch_id": "bid123", "status": "running", "session_id": None,
            "worktree_path": None, "branch": None,
        },
    )

    captured: dict = {}

    def fake_loop(goal, repo_path, **kw):
        captured.update(kw)
        return DirectorLoopResult(
            goal=goal, branch="axi/env/bid123", rounds=[], final_diff="diff",
            final_changed_files=[], done=True, rounds_used=1, total_cost_usd=0.1,
            total_claude_turns=2, ok=True, tests_passed=True,
            worktree_path="/tmp/envs/env/axi-dev-bid123", session_id="sess1",
        )

    with patch("axi.dev_director.run_director_loop", side_effect=fake_loop), \
         patch.object(_dev_run_entry, "_notify"):
        _dev_run_entry.main(env_id)

    assert captured["keep_worktree"] is True
    assert captured["worktree_parent"].endswith(env_id)
    assert captured["_branch_id"] == "bid123"

    final = dev_run.get_run(env_id)
    assert final["status"] == "ready"
    assert final["worktree_path"] == "/tmp/envs/env/axi-dev-bid123"
    assert final["branch"] == "axi/env/bid123"
    assert final["session_id"] == "sess1"


def test_entry_env_needs_human_still_records_worktree(env_dir):
    from axi import _dev_run_entry
    env_id = "20260627-000001-bbbbbb"
    dev_run._write_state_file(
        dev_run._state_path(env_id),
        {
            "run_id": env_id, "kind": "env", "goal": "g", "title": "T",
            "branch_id": "bid999", "status": "running", "session_id": None,
            "worktree_path": None, "branch": None,
        },
    )

    def fake_loop(goal, repo_path, **kw):
        return DirectorLoopResult(
            goal=goal, branch="axi/env/bid999", rounds=[], final_diff="",
            final_changed_files=[], done=False, rounds_used=3, total_cost_usd=0.2,
            total_claude_turns=6, ok=True, tests_passed=False, needs_human=True,
            escalation_reason="VT-3B no aprobó", worktree_path="/tmp/wt-bid999",
        )

    with patch("axi.dev_director.run_director_loop", side_effect=fake_loop), \
         patch.object(_dev_run_entry, "_notify"):
        _dev_run_entry.main(env_id)

    final = dev_run.get_run(env_id)
    assert final["status"] == "needs_human"
    # The worktree is still recorded so the user can inspect it.
    assert final["worktree_path"] == "/tmp/wt-bid999"
    assert final["branch"] == "axi/env/bid999"
