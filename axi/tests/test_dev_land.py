"""Tests for dev_land — Landing Gate (Slice 2)."""
from __future__ import annotations

import json
import subprocess
import types
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient


# ---------------------------------------------------------------------------
# Dashboard client fixture (mirrors test_data_view.py)
# ---------------------------------------------------------------------------


@pytest.fixture
def client(monkeypatch):
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    return TestClient(dashboard.app)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _fake_config(overrides: dict):
    """Return a tiny object whose .get(key, default) reads from overrides."""
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
# Unit tests — dev_land.land_run
# ---------------------------------------------------------------------------


def test_land_run_no_run(tmp_path, monkeypatch):
    """land_run returns ok=False when run_id not found."""
    from axi import dev_land
    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: None,
        _state_path=lambda rid: tmp_path / "state.json",
        _write_state_file=lambda p, s: None,
    ))
    result = dev_land.land_run("nonexistent-run-id")
    assert result["ok"] is False
    assert "not found" in result["error"]


def test_land_run_not_done(tmp_path, monkeypatch):
    """land_run returns ok=False when run status is not 'done'."""
    from axi import dev_land
    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: {"run_id": rid, "goal": "Fix foo", "status": "running"},
        _state_path=lambda rid: tmp_path / "state.json",
        _write_state_file=lambda p, s: None,
    ))
    result = dev_land.land_run("some-run")
    assert result["ok"] is False
    assert "not approvable" in result["error"]
    assert "running" in result["error"]


def test_land_run_no_patch(tmp_path, monkeypatch):
    """land_run returns ok=False when no .patch file exists."""
    from axi import dev_land
    run_id = "testrun-001"
    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: {"run_id": rid, "goal": "Fix foo", "status": "done"},
        _state_path=lambda rid: tmp_path / "state.json",
        _write_state_file=lambda p, s: None,
    ))
    monkeypatch.setattr("axi.dev_land.config", _fake_config({
        "dev_director_repo": str(tmp_path / "repo"),
        "dev_director_results_dir": str(tmp_path / "empty-results"),
    }))
    result = dev_land.land_run(run_id)
    assert result["ok"] is False
    assert "no patch" in result["error"]


def test_land_run_happy_path(tmp_path, monkeypatch):
    """Happy path: done run + real patch file → correct git calls + state written."""
    from axi import dev_land

    run_id = "20260626-120000-abc123"

    # Create a real (non-empty) patch file
    results_dir = tmp_path / "dev-results"
    results_dir.mkdir()
    patch_file = results_dir / f"{run_id}-20260626120000.patch"
    patch_file.write_text("--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n-old\n+new\n")

    # State tracking
    written_states: list[dict] = []
    state_json_path = tmp_path / "state.json"

    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: {"run_id": rid, "goal": "Fix foo bar", "status": "done"},
        _state_path=lambda rid: state_json_path,
        _write_state_file=lambda p, s: written_states.append(dict(s)),
    ))
    monkeypatch.setattr("axi.dev_land.config", _fake_config({
        "dev_director_repo": str(tmp_path / "repo"),
        "dev_director_results_dir": str(results_dir),
    }))

    # Track subprocess calls
    subprocess_calls: list[list[str]] = []

    def fake_subprocess_run(cmd, **kwargs):
        subprocess_calls.append(list(cmd))
        check = kwargs.get("check", False)
        proc = _make_proc(returncode=0)
        if check and proc.returncode != 0:
            raise Exception("check failed")
        return proc

    monkeypatch.setattr("axi.dev_land.subprocess.run", fake_subprocess_run)

    # Track worktree calls
    create_calls: list = []
    cleanup_calls: list = []

    def fake_create_worktree(repo_path, worktree_path, branch):
        create_calls.append((repo_path, worktree_path, branch))
        return True, ""

    def fake_cleanup_worktree(repo_path, worktree_path, branch, tmp_parent):
        cleanup_calls.append((repo_path, worktree_path, branch, tmp_parent))

    monkeypatch.setattr("axi.dev_land._create_worktree", fake_create_worktree)
    monkeypatch.setattr("axi.dev_land._cleanup_worktree", fake_cleanup_worktree)

    result = dev_land.land_run(run_id)

    assert result["ok"] is True, result
    assert result["branch"] == f"axi/land/{run_id}"
    assert result["pushed"] is True

    # Verify git commands were called (apply, commit, push)
    all_cmds = [" ".join(c) for c in subprocess_calls]
    assert any("git apply" in c for c in all_cmds), f"no git apply in {all_cmds}"
    assert any("git commit" in c for c in all_cmds), f"no git commit in {all_cmds}"
    assert any("git push" in c for c in all_cmds), f"no git push in {all_cmds}"

    # SAFETY: no merge to main, no systemctl
    for cmd_str in all_cmds:
        assert "merge" not in cmd_str.lower(), f"unexpected merge: {cmd_str}"
        assert "systemctl" not in cmd_str.lower(), f"unexpected systemctl: {cmd_str}"
        if "push" in cmd_str:
            assert "main" not in cmd_str and "master" not in cmd_str, f"pushed to main/master: {cmd_str}"

    # Verify cleanup was called
    assert len(cleanup_calls) == 1, "cleanup_worktree must be called exactly once"

    # Verify state written correctly
    assert len(written_states) == 1
    s = written_states[0]
    assert s["status"] == "landed"
    assert s["landed_branch"] == f"axi/land/{run_id}"
    assert "landed_at" in s
    assert s["push_ok"] is True


def test_land_run_patch_apply_failure(tmp_path, monkeypatch):
    """Both --index and --3way fail → cleanup called, ok=False."""
    from axi import dev_land

    run_id = "20260626-fail-abc"
    results_dir = tmp_path / "dev-results"
    results_dir.mkdir()
    patch_file = results_dir / f"{run_id}-ts.patch"
    patch_file.write_text("bad patch content")

    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: {"run_id": rid, "goal": "Do something", "status": "done"},
        _state_path=lambda rid: tmp_path / "state.json",
        _write_state_file=lambda p, s: None,
    ))
    monkeypatch.setattr("axi.dev_land.config", _fake_config({
        "dev_director_repo": str(tmp_path / "repo"),
        "dev_director_results_dir": str(results_dir),
    }))

    def fake_subprocess_run(cmd, **kwargs):
        return _make_proc(returncode=1, stderr="patch error")

    monkeypatch.setattr("axi.dev_land.subprocess.run", fake_subprocess_run)

    cleanup_calls: list = []
    monkeypatch.setattr("axi.dev_land._create_worktree", lambda *a: (True, ""))
    monkeypatch.setattr("axi.dev_land._cleanup_worktree", lambda *a: cleanup_calls.append(a))

    result = dev_land.land_run(run_id)

    assert result["ok"] is False
    assert "patch did not apply" in result["error"]
    assert len(cleanup_calls) == 1, "cleanup_worktree must be called even on failure"


# ---------------------------------------------------------------------------
# Unit tests — dev_land.merge_run (Feature B — human merge to main)
# ---------------------------------------------------------------------------


def _patch_merge_env(monkeypatch, tmp_path, *, status, landed_branch="axi/land/run-1",
                     written_states=None, target_branch="main"):
    """Wire dev_land for a merge_run test: state store + config + worktree stubs.

    Returns (create_calls, cleanup_calls). Subprocess is patched separately by
    each test so merge/conflict behavior can differ.
    """
    from axi import dev_land

    if written_states is None:
        written_states = []

    run_state = {"run_id": "run-1", "goal": "Fix foo", "status": status}
    if landed_branch is not None:
        run_state["landed_branch"] = landed_branch

    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: dict(run_state),
        _state_path=lambda rid: tmp_path / "state.json",
        _write_state_file=lambda p, s: written_states.append(dict(s)),
    ))
    monkeypatch.setattr("axi.dev_land.config", _fake_config({
        "dev_director_repo": str(tmp_path / "repo"),
        "dev_env_deploy_target_branch": target_branch,
    }))

    create_calls: list = []
    cleanup_calls: list = []
    monkeypatch.setattr("axi.dev_land._create_worktree",
                        lambda repo, wt, br: create_calls.append((repo, wt, br)) or (True, ""))
    monkeypatch.setattr("axi.dev_land._cleanup_worktree",
                        lambda *a: cleanup_calls.append(a))
    return create_calls, cleanup_calls, written_states


def test_merge_run_rejects_when_not_landed(tmp_path, monkeypatch):
    """merge_run refuses any status != 'landed' with NO git side effect."""
    from axi import dev_land

    _c, _cl, written = _patch_merge_env(monkeypatch, tmp_path, status="done")

    subprocess_calls: list = []
    monkeypatch.setattr("axi.dev_land.subprocess.run",
                        lambda cmd, **kw: subprocess_calls.append(list(cmd)) or _make_proc(0))

    result = dev_land.merge_run("run-1")

    assert result["ok"] is False
    assert "landed" in result["error"]
    # No git calls at all, no state write.
    assert subprocess_calls == []
    assert written == []


def test_merge_run_missing_landed_branch(tmp_path, monkeypatch):
    """merge_run errors when the run has no recorded landed_branch."""
    from axi import dev_land

    _c, _cl, written = _patch_merge_env(monkeypatch, tmp_path, status="landed",
                                        landed_branch=None)

    subprocess_calls: list = []
    monkeypatch.setattr("axi.dev_land.subprocess.run",
                        lambda cmd, **kw: subprocess_calls.append(list(cmd)) or _make_proc(0))

    result = dev_land.merge_run("run-1")
    assert result["ok"] is False
    assert subprocess_calls == []


def test_merge_run_happy_path(tmp_path, monkeypatch):
    """From 'landed': merges landed_branch, pushes target, state → 'merged'."""
    from axi import dev_land

    create_calls, cleanup_calls, written = _patch_merge_env(
        monkeypatch, tmp_path, status="landed",
        landed_branch="axi/land/run-1", target_branch="main")

    subprocess_calls: list = []

    def fake_run(cmd, **kwargs):
        subprocess_calls.append(list(cmd))
        return _make_proc(returncode=0)

    monkeypatch.setattr("axi.dev_land.subprocess.run", fake_run)

    result = dev_land.merge_run("run-1")

    assert result["ok"] is True, result
    all_cmds = [" ".join(c) for c in subprocess_calls]

    # Merged the recorded landed branch (fetched from origin).
    assert any("merge" in c and "origin/axi/land/run-1" in c for c in all_cmds), all_cmds
    # NEVER a force merge / force push.
    for c in all_cmds:
        assert "--force" not in c and "-f " not in (c + " "), c
    # Pushed to the configured target branch.
    push_cmds = [c for c in all_cmds if "push" in c]
    assert push_cmds, all_cmds
    assert any("HEAD:main" in c for c in push_cmds), push_cmds
    # Cleanup always runs.
    assert len(cleanup_calls) == 1

    # State recorded.
    s = written[-1]
    assert s["status"] == "merged"
    assert s["merged_into"] == "main"
    assert "merged_at" in s
    assert s["merge_push_ok"] is True


def test_merge_run_conflict_aborts_and_stays_landed(tmp_path, monkeypatch):
    """Merge conflict → abort, state STAYS 'landed', no push to target."""
    from axi import dev_land

    _c, cleanup_calls, written = _patch_merge_env(
        monkeypatch, tmp_path, status="landed", landed_branch="axi/land/run-1")

    subprocess_calls: list = []

    def fake_run(cmd, **kwargs):
        subprocess_calls.append(list(cmd))
        # The actual merge fails; abort and everything else succeed.
        if cmd[:2] == ["git", "merge"] and "--abort" not in cmd:
            return _make_proc(returncode=1, stderr="CONFLICT (content)")
        return _make_proc(returncode=0)

    monkeypatch.setattr("axi.dev_land.subprocess.run", fake_run)

    result = dev_land.merge_run("run-1")

    assert result["ok"] is False
    assert "conflict" in result["error"].lower()
    # FIX 6: conflicting-path diagnostics from stderr are surfaced.
    assert "CONFLICT (content)" in result["error"]
    all_cmds = [" ".join(c) for c in subprocess_calls]
    # merge --abort was issued.
    assert any("merge --abort" in c for c in all_cmds), all_cmds
    # NO push to the target branch happened.
    assert not any("push" in c for c in all_cmds), all_cmds
    # State never advanced to 'merged'.
    assert all(s.get("status") != "merged" for s in written)
    assert len(cleanup_calls) == 1


# ---------------------------------------------------------------------------
# Unit tests — dev_land.deploy_run (Feature B — human deploy / local install)
# ---------------------------------------------------------------------------


def test_deploy_run_rejects_when_not_merged(tmp_path, monkeypatch):
    """deploy_run refuses status != 'merged'; _trigger_local_install NOT called."""
    from axi import dev_land
    import axi.dev_env as _real_de

    written: list = []
    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: {"run_id": rid, "goal": "G", "status": "landed"},
        _state_path=lambda rid: tmp_path / "state.json",
        _write_state_file=lambda p, s: written.append(dict(s)),
    ))

    install_calls: list = []
    monkeypatch.setattr(_real_de, "_trigger_local_install",
                        lambda repo: install_calls.append(repo) or True)

    result = dev_land.deploy_run("run-1")
    assert result["ok"] is False
    assert "merged" in result["error"]
    assert install_calls == []
    assert written == []


def test_deploy_run_happy_path(tmp_path, monkeypatch):
    """From 'merged': triggers local install ONCE with the configured repo."""
    from axi import dev_land
    import axi.dev_env as _real_de

    written: list = []
    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: {"run_id": rid, "goal": "G", "status": "merged"},
        _state_path=lambda rid: tmp_path / "state.json",
        _write_state_file=lambda p, s: written.append(dict(s)),
    ))
    repo = str(tmp_path / "live-repo")
    monkeypatch.setattr("axi.dev_land.config", _fake_config({
        "dev_director_repo": repo,
    }))

    install_calls: list = []
    monkeypatch.setattr(_real_de, "_trigger_local_install",
                        lambda r: install_calls.append(r) or True)

    result = dev_land.deploy_run("run-1")

    assert result["ok"] is True, result
    assert install_calls == [repo]
    s = written[-1]
    assert s["status"] == "deployed"
    assert "deployed_at" in s
    assert s["deploy_triggered_ok"] is True


def test_cannot_deploy_directly_from_landed(tmp_path, monkeypatch):
    """State-machine gate: 'landed' cannot deploy — must merge first."""
    from axi import dev_land
    import axi.dev_env as _real_de

    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: {"run_id": rid, "goal": "G", "status": "landed",
                             "landed_branch": "axi/land/run-1"},
        _state_path=lambda rid: tmp_path / "state.json",
        _write_state_file=lambda p, s: None,
    ))
    install_calls: list = []
    monkeypatch.setattr(_real_de, "_trigger_local_install",
                        lambda repo: install_calls.append(repo) or True)

    result = dev_land.deploy_run("run-1")
    assert result["ok"] is False
    assert install_calls == []


# ---------------------------------------------------------------------------
# FIX 1 — resilience: git subprocess timeouts must not strand a run
# ---------------------------------------------------------------------------


def test_merge_run_push_timeout_stays_landed(tmp_path, monkeypatch):
    """A TimeoutExpired on push → failure, best-effort abort, state STAYS 'landed'."""
    from axi import dev_land

    _c, cleanup_calls, written = _patch_merge_env(
        monkeypatch, tmp_path, status="landed", landed_branch="axi/land/run-1")

    subprocess_calls: list = []

    def fake_run(cmd, **kwargs):
        subprocess_calls.append(list(cmd))
        if cmd[:2] == ["git", "push"]:
            raise subprocess.TimeoutExpired(cmd, kwargs.get("timeout", 30))
        return _make_proc(returncode=0)

    monkeypatch.setattr("axi.dev_land.subprocess.run", fake_run)

    result = dev_land.merge_run("run-1")

    assert result["ok"] is False
    assert "timeout" in result["error"].lower()
    assert "push" in result["error"]
    all_cmds = [" ".join(c) for c in subprocess_calls]
    # Best-effort abort on timeout.
    assert any("merge --abort" in c for c in all_cmds), all_cmds
    # State never advanced to 'merged'.
    assert all(s.get("status") != "merged" for s in written)
    # Cleanup always runs.
    assert len(cleanup_calls) == 1


def test_merge_run_git_calls_have_timeouts(tmp_path, monkeypatch):
    """Every git subprocess.run in _merge_run passes a timeout= bound."""
    from axi import dev_land

    _patch_merge_env(monkeypatch, tmp_path, status="landed",
                     landed_branch="axi/land/run-1")

    seen_timeouts: list = []

    def fake_run(cmd, **kwargs):
        seen_timeouts.append(kwargs.get("timeout"))
        return _make_proc(returncode=0)

    monkeypatch.setattr("axi.dev_land.subprocess.run", fake_run)
    dev_land.merge_run("run-1")

    assert seen_timeouts, "no git calls made"
    assert all(t is not None for t in seen_timeouts), seen_timeouts


# ---------------------------------------------------------------------------
# FIX 2 — reliability: deploy must not advance to 'deployed' on trigger failure
# ---------------------------------------------------------------------------


def _patch_deploy_env(monkeypatch, tmp_path, *, status="merged"):
    from axi import dev_land
    written: list = []
    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: {"run_id": rid, "goal": "G", "status": status},
        _state_path=lambda rid: tmp_path / "state.json",
        _write_state_file=lambda p, s: written.append(dict(s)),
    ))
    monkeypatch.setattr("axi.dev_land.config", _fake_config({
        "dev_director_repo": str(tmp_path / "live-repo"),
    }))
    return written


def test_deploy_trigger_false_stays_merged(tmp_path, monkeypatch):
    """Trigger returns False → status stays 'merged', ok False, install was called."""
    from axi import dev_land
    import axi.dev_env as _real_de

    written = _patch_deploy_env(monkeypatch, tmp_path)
    install_calls: list = []
    monkeypatch.setattr(_real_de, "_trigger_local_install",
                        lambda r: install_calls.append(r) or False)

    result = dev_land.deploy_run("run-1")

    assert result["ok"] is False
    assert install_calls, "install must have been attempted"
    assert all(s.get("status") != "deployed" for s in written)
    s = written[-1]
    assert s["status"] == "merged"
    assert s["deploy_triggered_ok"] is False
    assert s.get("deploy_error")


def test_deploy_trigger_raises_stays_merged(tmp_path, monkeypatch):
    """Trigger raises → status stays 'merged', ok False."""
    from axi import dev_land
    import axi.dev_env as _real_de

    written = _patch_deploy_env(monkeypatch, tmp_path)
    install_calls: list = []

    def boom(r):
        install_calls.append(r)
        raise RuntimeError("systemd-run exploded")

    monkeypatch.setattr(_real_de, "_trigger_local_install", boom)

    result = dev_land.deploy_run("run-1")

    assert result["ok"] is False
    assert install_calls, "install must have been attempted"
    assert all(s.get("status") != "deployed" for s in written)
    s = written[-1]
    assert s["status"] == "merged"
    assert s["deploy_triggered_ok"] is False
    assert s.get("deploy_error")


# ---------------------------------------------------------------------------
# FIX 3 — risk/reliability: double-submit / lost-update race
# ---------------------------------------------------------------------------


def test_merge_run_double_submit_rejected(tmp_path, monkeypatch):
    """Two sequential merges: first advances → second cleanly rejected by gate."""
    from axi import dev_land

    live_state = {"run_id": "run-1", "goal": "G", "status": "landed",
                  "landed_branch": "axi/land/run-1"}

    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: dict(live_state),
        _state_path=lambda rid: tmp_path / "state.json",
        _write_state_file=lambda p, s: live_state.update(s),
    ))
    monkeypatch.setattr("axi.dev_land.config", _fake_config({
        "dev_director_repo": str(tmp_path / "repo"),
        "dev_env_deploy_target_branch": "main",
    }))
    monkeypatch.setattr("axi.dev_land._create_worktree", lambda *a: (True, ""))
    monkeypatch.setattr("axi.dev_land._cleanup_worktree", lambda *a: None)

    push_count = {"n": 0}

    def fake_run(cmd, **kwargs):
        if cmd[:2] == ["git", "push"]:
            push_count["n"] += 1
        return _make_proc(returncode=0)

    monkeypatch.setattr("axi.dev_land.subprocess.run", fake_run)

    first = dev_land.merge_run("run-1")
    second = dev_land.merge_run("run-1")

    assert first["ok"] is True
    assert second["ok"] is False
    assert "landed" in second["error"]
    # Only ONE push to target — no double merge.
    assert push_count["n"] == 1
    assert live_state["status"] == "merged"


# ---------------------------------------------------------------------------
# FIX 5 — resilience: merge/deploy logged to the outcome trail
# ---------------------------------------------------------------------------


def test_merge_run_logs_outcome(tmp_path, monkeypatch):
    """_merge_run calls _log_outcome on success."""
    from axi import dev_land

    _patch_merge_env(monkeypatch, tmp_path, status="landed",
                     landed_branch="axi/land/run-1")
    monkeypatch.setattr("axi.dev_land.subprocess.run",
                        lambda cmd, **kw: _make_proc(returncode=0))

    log_calls: list = []
    monkeypatch.setattr("axi.dev_land._log_outcome",
                        lambda state, **kw: log_calls.append(kw.get("status")))

    dev_land.merge_run("run-1")
    assert "merged" in log_calls, log_calls


def test_deploy_run_logs_outcome(tmp_path, monkeypatch):
    """_deploy_run calls _log_outcome on success."""
    from axi import dev_land
    import axi.dev_env as _real_de

    _patch_deploy_env(monkeypatch, tmp_path)
    monkeypatch.setattr(_real_de, "_trigger_local_install", lambda r: True)

    log_calls: list = []
    monkeypatch.setattr("axi.dev_land._log_outcome",
                        lambda state, **kw: log_calls.append(kw.get("status")))

    dev_land.deploy_run("run-1")
    assert "deployed" in log_calls, log_calls


# ---------------------------------------------------------------------------
# API tests — merge / deploy endpoints
# ---------------------------------------------------------------------------


def test_api_merge_calls_merge_run(client, monkeypatch):
    """POST /api/dev-runs/{id}/merge calls dev_land.merge_run, returns result."""
    import axi.dev_run as _real_dr
    import axi.dev_land as _real_dl

    run_id = "merge-endpoint-run"
    monkeypatch.setattr(_real_dr, "get_run",
                        lambda rid: {"run_id": rid, "status": "landed", "goal": "G"})
    monkeypatch.setattr(_real_dl, "merge_run",
                        lambda rid: {"ok": True, "merged_into": "main"})

    r = client.post(f"/api/dev-runs/{run_id}/merge")
    assert r.status_code == 200
    assert r.json()["merged_into"] == "main"


def test_api_merge_wrong_state_400(client, monkeypatch):
    """POST merge on a non-landed run → 400."""
    import axi.dev_run as _real_dr
    import axi.dev_land as _real_dl

    monkeypatch.setattr(_real_dr, "get_run",
                        lambda rid: {"run_id": rid, "status": "done", "goal": "G"})
    monkeypatch.setattr(_real_dl, "merge_run",
                        lambda rid: {"ok": False, "error": "run not in 'landed' state"})

    r = client.post("/api/dev-runs/x/merge")
    assert r.status_code == 400


def test_api_deploy_calls_deploy_run(client, monkeypatch):
    """POST /api/dev-runs/{id}/deploy calls dev_land.deploy_run, returns result."""
    import axi.dev_run as _real_dr
    import axi.dev_land as _real_dl

    run_id = "deploy-endpoint-run"
    monkeypatch.setattr(_real_dr, "get_run",
                        lambda rid: {"run_id": rid, "status": "merged", "goal": "G"})
    monkeypatch.setattr(_real_dl, "deploy_run",
                        lambda rid: {"ok": True, "deploy_triggered_ok": True})

    r = client.post(f"/api/dev-runs/{run_id}/deploy")
    assert r.status_code == 200
    assert r.json()["deploy_triggered_ok"] is True


def test_api_deploy_wrong_state_400(client, monkeypatch):
    """POST deploy on a non-merged run → 400."""
    import axi.dev_run as _real_dr
    import axi.dev_land as _real_dl

    monkeypatch.setattr(_real_dr, "get_run",
                        lambda rid: {"run_id": rid, "status": "landed", "goal": "G"})
    monkeypatch.setattr(_real_dl, "deploy_run",
                        lambda rid: {"ok": False, "error": "run not in 'merged' state"})

    r = client.post("/api/dev-runs/x/deploy")
    assert r.status_code == 400


# ---------------------------------------------------------------------------
# Unit tests — dev_land.reject_run
# ---------------------------------------------------------------------------


def test_reject_run_sets_rejected(tmp_path, monkeypatch):
    """reject_run sets status=rejected and returns ok=True."""
    from axi import dev_land

    written_states: list[dict] = []

    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: {"run_id": rid, "goal": "Some goal", "status": "done"},
        _state_path=lambda rid: tmp_path / "state.json",
        _write_state_file=lambda p, s: written_states.append(dict(s)),
    ))

    result = dev_land.reject_run("any-run-id")

    assert result == {"ok": True}
    assert len(written_states) == 1
    assert written_states[0]["status"] == "rejected"


def test_reject_run_not_found(tmp_path, monkeypatch):
    """reject_run returns ok=False when run not found."""
    from axi import dev_land

    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: None,
        _state_path=lambda rid: tmp_path / "state.json",
        _write_state_file=lambda p, s: None,
    ))

    result = dev_land.reject_run("ghost-run")
    assert result["ok"] is False
    assert "not found" in result["error"]


# ---------------------------------------------------------------------------
# API tests (dashboard routes)
# ---------------------------------------------------------------------------


def test_dev_page_renders(client):
    """GET /dev → 200 HTML."""
    r = client.get("/dev")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]


def test_api_list_dev_runs(client, monkeypatch):
    """GET /api/dev-runs returns list, newest first."""
    from axi import dashboard

    fake_runs = [
        {"run_id": "run-A", "goal": "First", "status": "done", "started_at": "2026-06-01T00:00:00+00:00", "rounds_done": 2},
        {"run_id": "run-B", "goal": "Second", "status": "running", "started_at": "2026-06-02T00:00:00+00:00", "rounds_done": 1},
    ]

    import types as _types
    import os as _os
    from pathlib import Path as _Path

    # Patch dev_run inside dashboard's scope via its lazy import path
    import axi.dev_run as _real_dr
    monkeypatch.setattr(_real_dr, "list_runs", lambda: fake_runs)

    # Patch config to point to a nonexistent results dir (no patches)
    monkeypatch.setattr(dashboard, "config", _fake_config({
        "dev_director_results_dir": "/tmp/nonexistent-axi-results-zzzz",
    }))

    r = client.get("/api/dev-runs")
    assert r.status_code == 200
    data = r.json()
    assert isinstance(data, list)
    # reversed → run-B first (newest index in reversed list)
    assert data[0]["run_id"] == "run-B"
    assert data[1]["run_id"] == "run-A"
    assert data[1]["has_patch"] is False


def test_api_get_dev_run_returns_diff(client, monkeypatch, tmp_path):
    """GET /api/dev-runs/{id} returns run dict + diff text."""
    from axi import dashboard
    import axi.dev_run as _real_dr

    run_id = "20260626-120000-xyz"
    results_dir = tmp_path / "dev-results"
    results_dir.mkdir()
    patch = results_dir / f"{run_id}-20260626.patch"
    patch.write_text("--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n")

    monkeypatch.setattr(_real_dr, "get_run", lambda rid: {"run_id": rid, "status": "done", "goal": "X"})
    monkeypatch.setattr(dashboard, "config", _fake_config({
        "dev_director_results_dir": str(results_dir),
    }))

    r = client.get(f"/api/dev-runs/{run_id}")
    assert r.status_code == 200
    d = r.json()
    assert d["run_id"] == run_id
    assert "--- a" in d["diff"]


def test_api_get_dev_run_not_found(client, monkeypatch):
    """GET /api/dev-runs/unknown → 404."""
    import axi.dev_run as _real_dr
    monkeypatch.setattr(_real_dr, "get_run", lambda rid: None)
    r = client.get("/api/dev-runs/unknown-run")
    assert r.status_code == 404


def test_api_approve_calls_land_run(client, monkeypatch):
    """POST /api/dev-runs/{id}/approve calls dev_land.land_run, returns result."""
    import axi.dev_run as _real_dr
    import axi.dev_land as _real_dl

    run_id = "approve-test-run"
    monkeypatch.setattr(_real_dr, "get_run", lambda rid: {"run_id": rid, "status": "done", "goal": "G"})
    monkeypatch.setattr(_real_dl, "land_run", lambda rid: {"ok": True, "branch": f"axi/land/{rid}", "pushed": True})

    r = client.post(f"/api/dev-runs/{run_id}/approve")
    assert r.status_code == 200
    d = r.json()
    assert d["ok"] is True
    assert d["branch"] == f"axi/land/{run_id}"


def test_api_approve_not_found_404(client, monkeypatch):
    """POST /api/dev-runs/unknown/approve → 404."""
    import axi.dev_run as _real_dr
    monkeypatch.setattr(_real_dr, "get_run", lambda rid: None)
    r = client.post("/api/dev-runs/unknown/approve")
    assert r.status_code == 404


def test_api_reject_calls_reject_run(client, monkeypatch):
    """POST /api/dev-runs/{id}/reject calls dev_land.reject_run."""
    import axi.dev_run as _real_dr
    import axi.dev_land as _real_dl

    run_id = "reject-test-run"
    monkeypatch.setattr(_real_dr, "get_run", lambda rid: {"run_id": rid, "status": "done", "goal": "G"})

    reject_calls: list = []
    monkeypatch.setattr(_real_dl, "reject_run", lambda rid: reject_calls.append(rid) or {"ok": True})

    r = client.post(f"/api/dev-runs/{run_id}/reject")
    assert r.status_code == 200
    assert r.json()["ok"] is True
    assert reject_calls == [run_id]


def test_api_reject_not_found_404(client, monkeypatch):
    """POST /api/dev-runs/unknown/reject → 404."""
    import axi.dev_run as _real_dr
    monkeypatch.setattr(_real_dr, "get_run", lambda rid: None)
    r = client.post("/api/dev-runs/unknown/reject")
    assert r.status_code == 404
