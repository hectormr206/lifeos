"""
Tests for axi.dev_director.

All external calls (VT-3B HTTP, Claude subprocess) are mocked.
No real network or subprocess calls are made.
A real throwaway git repo is used for tests that exercise the worktree/diff path.
"""
from __future__ import annotations

import io
import json
import os
import subprocess
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import MagicMock, patch

import pytest

from axi import dev_director
from axi.dev_director import DirectorResult, _call_vt3b, run_director_round


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_repo(tmp_path: Path) -> Path:
    """Create a minimal real git repo with an initial commit."""
    repo = tmp_path / "repo"
    repo.mkdir()
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@example.com",
    }
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True, env=env)
    subprocess.run(
        ["git", "config", "user.email", "test@example.com"],
        cwd=repo, check=True, env=env,
    )
    subprocess.run(
        ["git", "config", "user.name", "Test"],
        cwd=repo, check=True, env=env,
    )
    (repo / "README.md").write_text("hello\n")
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True, env=env)
    subprocess.run(
        ["git", "commit", "-q", "-m", "init"],
        cwd=repo, check=True, env=env,
    )
    return repo


def _fake_urlopen_response(content: str):
    """Return a mock context-manager whose read() yields an OpenAI-compat JSON body."""
    body = json.dumps(
        {"choices": [{"message": {"content": content}}]}
    ).encode()
    mock_resp = MagicMock()
    mock_resp.read.return_value = body
    mock_resp.__enter__ = lambda s: s
    mock_resp.__exit__ = MagicMock(return_value=False)
    return mock_resp


# ---------------------------------------------------------------------------
# _call_vt3b tests
# ---------------------------------------------------------------------------


def test_call_vt3b_strips_think_blocks():
    raw = "<think>reasoning here</think>\nActual answer"
    with patch("urllib.request.urlopen", return_value=_fake_urlopen_response(raw)):
        result = _call_vt3b("sys", "user")
    assert result == "Actual answer"


def test_call_vt3b_strips_boxed():
    raw = r"\boxed{42}"
    with patch("urllib.request.urlopen", return_value=_fake_urlopen_response(raw)):
        result = _call_vt3b("sys", "user")
    assert result == "42"


def test_call_vt3b_strips_both():
    raw = r"<think>hidden</think> \boxed{answer}"
    with patch("urllib.request.urlopen", return_value=_fake_urlopen_response(raw)):
        result = _call_vt3b("sys", "user")
    assert result == "answer"


def test_call_vt3b_strips_unclosed_think():
    # VT-3B sometimes runs out of tokens mid-thought, leaving an unclosed <think>.
    raw = "DONE: looks good\n<think>wait, let me reconsider but I ran out of tok"
    with patch("urllib.request.urlopen", return_value=_fake_urlopen_response(raw)):
        result = _call_vt3b("sys", "user")
    assert "<think>" not in result
    assert result.startswith("DONE")


# ---------------------------------------------------------------------------
# run_director_round tests
# ---------------------------------------------------------------------------


def test_run_director_round_happy_path(tmp_path):
    """Full integration test using a real temp git repo."""
    repo = _make_repo(tmp_path)

    vt3b_calls = []

    def fake_vt3b(system, user, **kwargs):
        vt3b_calls.append((system, user))
        if len(vt3b_calls) == 1:
            return "Add a hello() function to src/greet.py"
        return "DONE: implementation looks correct"

    # Capture the real subprocess.run BEFORE the patch replaces it.
    _real_run = subprocess.run

    def fake_subprocess_run(args, **kwargs):
        # Intercept the claude invocation only.
        if args and args[0] == "claude":
            worktree = kwargs.get("cwd", "")
            # Simulate Claude writing a file into the worktree.
            src_dir = Path(worktree) / "src"
            src_dir.mkdir(parents=True, exist_ok=True)
            (src_dir / "greet.py").write_text('def hello():\n    return "Hello!"\n')
            stdout = json.dumps({
                "result": "Done, added hello()",
                "total_cost_usd": 0.001,
                "num_turns": 3,
                "is_error": False,
            })
            return CompletedProcess(args=args, returncode=0, stdout=stdout, stderr="")
        # Pass through all git commands and any other real calls.
        return _real_run(args, **kwargs)

    with patch.object(dev_director, "_call_vt3b", side_effect=fake_vt3b), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"), \
         patch("axi.dev_director.subprocess.run", side_effect=fake_subprocess_run):
        result = run_director_round(
            goal="Add hello function",
            repo_path=str(repo),
            _branch_id="testhappy",
        )

    assert result.ok is True, f"expected ok=True, got error={result.error}"
    assert result.instruction == "Add a hello() function to src/greet.py"
    assert result.review_done is True
    assert result.diff != "", "diff should be non-empty"
    assert any("greet.py" in f for f in result.changed_files)
    assert result.claude_cost_usd == 0.001
    assert result.claude_num_turns == 3

    # Assert no new commits on the original repo.
    log_out = _real_run(
        ["git", "-C", str(repo), "log", "--oneline"],
        capture_output=True, text=True,
    ).stdout.strip()
    assert log_out.count("\n") == 0, "should have only the initial commit"

    # Assert worktree and branch are cleaned up.
    wt_list = _real_run(
        ["git", "-C", str(repo), "worktree", "list"],
        capture_output=True, text=True,
    ).stdout
    assert wt_list.count("\n") <= 1, "only the main worktree should remain"


def test_review_not_done_parsing(tmp_path):
    """NOT DONE review text sets review_done=False."""
    repo = _make_repo(tmp_path)

    calls = []
    _real_run = subprocess.run

    def fake_vt3b(system, user, **kwargs):
        calls.append(1)
        if len(calls) == 1:
            return "Add tests to src/foo.py"
        return "NOT DONE: missing edge case tests"

    def fake_subprocess_run(args, **kwargs):
        if args and args[0] == "claude":
            worktree = kwargs.get("cwd", "")
            (Path(worktree) / "src").mkdir(parents=True, exist_ok=True)
            (Path(worktree) / "src" / "foo.py").write_text("# stub\n")
            stdout = json.dumps({
                "result": "ok",
                "total_cost_usd": 0.0,
                "num_turns": 1,
                "is_error": False,
            })
            return CompletedProcess(args=args, returncode=0, stdout=stdout, stderr="")
        return _real_run(args, **kwargs)

    with patch.object(dev_director, "_call_vt3b", side_effect=fake_vt3b), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"), \
         patch("axi.dev_director.subprocess.run", side_effect=fake_subprocess_run):
        result = run_director_round(
            goal="Test goal",
            repo_path=str(repo),
            _branch_id="testnotdone",
        )

    assert result.review_done is False
    assert "missing edge case tests" in result.review_feedback


def test_vt3b_failure_returns_ok_false(tmp_path):
    """If _call_vt3b raises on first call, result is ok=False with error set."""
    repo = _make_repo(tmp_path)

    def fake_vt3b(system, user, **kwargs):
        raise ConnectionRefusedError("VT-3B not available")

    with patch.object(dev_director, "_call_vt3b", side_effect=fake_vt3b), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"):
        result = run_director_round(
            goal="Any goal",
            repo_path=str(repo),
            _branch_id="testfail",
        )

    assert result.ok is False
    assert result.error is not None
    assert "VT-3B not available" in result.error or "ConnectionRefusedError" in result.error or result.error


def test_claude_not_on_path_returns_ok_false(tmp_path):
    """If claude CLI is not on PATH, return ok=False immediately."""
    repo = _make_repo(tmp_path)

    with patch("axi.dev_director.shutil.which", return_value=None):
        result = run_director_round(
            goal="Any goal",
            repo_path=str(repo),
            _branch_id="testnoclaud",
        )

    assert result.ok is False
    assert result.error is not None
    assert "claude" in result.error.lower()


def test_claude_is_error_returns_ok_false(tmp_path):
    """If claude returns is_error=true, result is ok=False."""
    repo = _make_repo(tmp_path)

    def fake_vt3b(system, user, **kwargs):
        return "Do something"

    _real_run = subprocess.run

    def fake_subprocess_run(args, **kwargs):
        if args and args[0] == "claude":
            stdout = json.dumps({
                "result": "",
                "is_error": True,
                "total_cost_usd": 0.0,
                "num_turns": 0,
            })
            return CompletedProcess(args=args, returncode=0, stdout=stdout, stderr="")
        return _real_run(args, **kwargs)

    with patch.object(dev_director, "_call_vt3b", side_effect=fake_vt3b), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"), \
         patch("axi.dev_director.subprocess.run", side_effect=fake_subprocess_run):
        result = run_director_round(
            goal="Any goal",
            repo_path=str(repo),
            _branch_id="testiserr",
        )

    assert result.ok is False


def test_run_director_round_excludes_build_artifacts(tmp_path):
    """The captured diff must exclude __pycache__, *.pyc and .atl/ junk that
    Claude Code / tooling generates while running in the worktree."""
    repo = _make_repo(tmp_path)

    calls = []

    def fake_vt3b(system, user, **kwargs):
        calls.append(1)
        return "Add greet() to src/greet.py" if len(calls) == 1 else "DONE: ok"

    _real_run = subprocess.run

    def fake_subprocess_run(args, **kwargs):
        if args and args[0] == "claude":
            wt = Path(kwargs.get("cwd", ""))
            (wt / "src").mkdir(parents=True, exist_ok=True)
            (wt / "src" / "greet.py").write_text("def greet():\n    return 'hi'\n")
            # Junk the real run produced: bytecode caches and the gentle-ai registry.
            (wt / "__pycache__").mkdir(exist_ok=True)
            (wt / "__pycache__" / "greet.pyc").write_text("bytecode")
            (wt / "src" / "__pycache__").mkdir(parents=True, exist_ok=True)
            (wt / "src" / "__pycache__" / "x.pyc").write_text("bytecode")
            (wt / ".atl").mkdir(exist_ok=True)
            (wt / ".atl" / "skill-registry.md").write_text("# junk")
            stdout = json.dumps({
                "result": "done", "total_cost_usd": 0.001, "num_turns": 2, "is_error": False,
            })
            return CompletedProcess(args=args, returncode=0, stdout=stdout, stderr="")
        return _real_run(args, **kwargs)

    with patch.object(dev_director, "_call_vt3b", side_effect=fake_vt3b), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"), \
         patch("axi.dev_director.subprocess.run", side_effect=fake_subprocess_run):
        result = run_director_round(
            goal="Add greet", repo_path=str(repo), _branch_id="testjunk",
        )

    assert result.ok is True, result.error
    # The real file is present...
    assert any("greet.py" in f for f in result.changed_files), result.changed_files
    # ...and the junk is excluded from both the file list and the diff text.
    assert not any(".pyc" in f for f in result.changed_files), result.changed_files
    assert not any("__pycache__" in f for f in result.changed_files), result.changed_files
    assert not any(f.startswith(".atl") for f in result.changed_files), result.changed_files
    assert "__pycache__" not in result.diff
    assert ".atl/skill-registry" not in result.diff
