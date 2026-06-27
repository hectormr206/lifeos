"""
Tests for axi.dev_director.

All external calls (VT-3B HTTP, Claude subprocess, pytest subprocess) are mocked.
No real network or subprocess calls are made in the loop tests.
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
from axi.dev_director import (
    DirectorResult,
    DirectorLoopResult,
    _call_vt3b,
    _compose_goal_instruction,
    run_director_round,
    run_director_loop,
    _CORRECTIVE_SYSTEM,
    _MAX_ROUNDS_CEILING,
    _MIN_ROUNDS_FLOOR,
)


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


_LOOP_KWARGS = dict(test_command="tests/ -q", venv_python="/fake/python")


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

    _real_run = subprocess.run

    def fake_subprocess_run(args, **kwargs):
        if args and args[0] == "claude":
            worktree = kwargs.get("cwd", "")
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

    log_out = _real_run(
        ["git", "-C", str(repo), "log", "--oneline"],
        capture_output=True, text=True,
    ).stdout.strip()
    assert log_out.count("\n") == 0, "should have only the initial commit"

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
    """The captured diff must exclude __pycache__, *.pyc and .atl/ junk."""
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
    assert any("greet.py" in f for f in result.changed_files), result.changed_files
    assert not any(".pyc" in f for f in result.changed_files), result.changed_files
    assert not any("__pycache__" in f for f in result.changed_files), result.changed_files
    assert not any(f.startswith(".atl") for f in result.changed_files), result.changed_files
    assert "__pycache__" not in result.diff
    assert ".atl/skill-registry" not in result.diff


# ---------------------------------------------------------------------------
# run_director_loop tests
# ---------------------------------------------------------------------------


def test_loop_stops_on_done(tmp_path):
    """Loop stops as soon as tests pass AND review returns DONE; rounds_used reflects early stop."""
    repo = _make_repo(tmp_path)

    claude_call_count = 0

    def fake_run_claude(worktree, instruction, timeout, env, **_kw):
        nonlocal claude_call_count
        claude_call_count += 1
        (Path(worktree) / f"file{claude_call_count}.py").write_text("# impl\n")
        return ("done", 0.01, 2, False, None)

    review_calls = 0

    def fake_review(goal, diff, port, max_tokens, test_result=None):
        nonlocal review_calls
        review_calls += 1
        if review_calls == 1:
            return ("NOT DONE: missing tests", False)
        return ("DONE: implementation is complete", True)

    with patch.object(dev_director, "_run_claude", side_effect=fake_run_claude), \
         patch.object(dev_director, "_run_tests", return_value=(True, "5 passed")), \
         patch.object(dev_director, "_review", side_effect=fake_review), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"):
        result = run_director_loop(
            "Add feature with tests", str(repo), max_rounds=4, _branch_id="loopdone",
            **_LOOP_KWARGS,
        )

    assert result.ok is True, result.error
    assert result.done is True
    assert result.rounds_used == 2
    assert len(result.rounds) == 2
    assert result.rounds[1].review_done is True
    assert result.total_cost_usd > 0
    assert result.tests_passed is True
    assert result.needs_human is False


def test_loop_runs_max_rounds(tmp_path):
    """Loop runs at most max_rounds when reviewer never says DONE."""
    repo = _make_repo(tmp_path)
    max_r = 3

    with patch.object(dev_director, "_run_claude", return_value=("done", 0.01, 2, False, None)), \
         patch.object(dev_director, "_run_tests", return_value=(False, "FAILED: 1 error")), \
         patch.object(dev_director, "_review", return_value=("NOT DONE: incomplete", False)), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"):
        result = run_director_loop(
            "Some goal", str(repo), max_rounds=max_r, _branch_id="loopmaxr",
            **_LOOP_KWARGS,
        )

    assert result.ok is True, result.error
    assert result.done is False
    assert result.rounds_used == max_r
    assert len(result.rounds) == max_r
    assert all(not r.review_done for r in result.rounds)
    assert result.needs_human is True


def test_loop_corrective_instruction(tmp_path):
    """Corrective round embeds prior VT-3B feedback in the /goal instruction."""
    repo = _make_repo(tmp_path)

    feedback = "you forgot to add error handling"
    claude_instructions: list[str] = []

    def fake_run_claude(worktree, instruction, timeout, env, **_kw):
        claude_instructions.append(instruction)
        (Path(worktree) / f"file{len(claude_instructions)}.py").write_text("# impl\n")
        return ("done", 0.01, 2, False, None)

    review_calls = 0

    def fake_review(goal, diff, port, max_tokens, test_result=None):
        nonlocal review_calls
        review_calls += 1
        if review_calls == 1:
            return (f"NOT DONE: {feedback}", False)
        return ("DONE: now complete", True)

    with patch.object(dev_director, "_run_claude", side_effect=fake_run_claude), \
         patch.object(dev_director, "_run_tests", return_value=(True, "passed")), \
         patch.object(dev_director, "_review", side_effect=fake_review), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"):
        result = run_director_loop(
            "Build handler with error handling", str(repo), max_rounds=2, _branch_id="loopcorr",
            **_LOOP_KWARGS,
        )

    assert result.done is True
    assert len(claude_instructions) == 2
    # Round 1: no prior feedback — instruction starts with /goal, feedback absent
    assert claude_instructions[0].startswith("/goal")
    assert feedback not in claude_instructions[0]
    # Round 2: embeds VT-3B feedback from round 1
    assert claude_instructions[1].startswith("/goal")
    assert feedback in claude_instructions[1]


def test_loop_claude_error_stops(tmp_path):
    """If claude reports is_error mid-loop, the loop stops and returns ok=False."""
    repo = _make_repo(tmp_path)

    with patch.object(dev_director, "_run_claude", return_value=("error msg", 0.0, 0, True, None)), \
         patch.object(dev_director, "_run_tests", return_value=(True, "passed")), \
         patch.object(dev_director, "_review", return_value=("DONE", True)), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"):
        result = run_director_loop(
            "Any goal", str(repo), max_rounds=4, _branch_id="looperr",
            **_LOOP_KWARGS,
        )

    assert result.ok is False
    assert result.error is not None
    assert "is_error" in result.error
    assert result.done is False
    assert result.rounds_used == 1


def test_loop_cleanup_no_commit(tmp_path):
    """Cleanup (worktree remove + branch delete) fires; no git commit or push."""
    repo = _make_repo(tmp_path)
    _real_run = subprocess.run
    all_subprocess_calls: list[list[str]] = []

    def tracking_subprocess_run(args, **kwargs):
        all_subprocess_calls.append(list(args))
        return _real_run(args, **kwargs)

    review_calls = 0

    def fake_review(goal, diff, port, max_tokens, test_result=None):
        nonlocal review_calls
        review_calls += 1
        if review_calls < 2:
            return ("NOT DONE: needs more", False)
        return ("DONE: complete", True)

    with patch.object(dev_director, "_run_claude", return_value=("done", 0.01, 2, False, None)), \
         patch.object(dev_director, "_run_tests", return_value=(True, "5 passed")), \
         patch.object(dev_director, "_review", side_effect=fake_review), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"), \
         patch("axi.dev_director.subprocess.run", side_effect=tracking_subprocess_run):
        result = run_director_loop(
            "goal", str(repo), max_rounds=2, _branch_id="loopclean",
            **_LOOP_KWARGS,
        )

    assert result.ok is True

    joined = [" ".join(c) for c in all_subprocess_calls]
    assert any("worktree" in s and "remove" in s for s in joined), "missing worktree remove"
    assert any("branch" in s and "-D" in s for s in joined), "missing branch -D"

    def _is_git_verb(calls: list[list[str]], verb: str) -> bool:
        return any(c[0] == "git" and len(c) > 1 and c[1] == verb for c in calls)

    assert not _is_git_verb(all_subprocess_calls, "commit"), (
        f"unexpected git commit: {all_subprocess_calls}"
    )
    assert not _is_git_verb(all_subprocess_calls, "push"), (
        f"unexpected git push: {all_subprocess_calls}"
    )


def test_loop_max_rounds_clamped(tmp_path):
    """max_rounds is clamped to [_MIN_ROUNDS_FLOOR, _MAX_ROUNDS_CEILING]."""
    repo = _make_repo(tmp_path)

    with patch.object(dev_director, "_run_claude", return_value=("done", 0.0, 1, False, None)), \
         patch.object(dev_director, "_run_tests", return_value=(False, "FAILED")), \
         patch.object(dev_director, "_review", return_value=("NOT DONE: incomplete", False)), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"):
        result_low = run_director_loop(
            "goal", str(repo), max_rounds=0, _branch_id="clamplo",
            **_LOOP_KWARGS,
        )

    assert result_low.rounds_used == _MIN_ROUNDS_FLOOR, (
        f"expected {_MIN_ROUNDS_FLOOR} rounds with max_rounds=0, got {result_low.rounds_used}"
    )

    with patch.object(dev_director, "_run_claude", return_value=("done", 0.0, 1, False, None)), \
         patch.object(dev_director, "_run_tests", return_value=(False, "FAILED")), \
         patch.object(dev_director, "_review", return_value=("NOT DONE: incomplete", False)), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"):
        result_high = run_director_loop(
            "goal", str(repo), max_rounds=99, _branch_id="clamphi",
            **_LOOP_KWARGS,
        )

    assert result_high.rounds_used == _MAX_ROUNDS_CEILING, (
        f"expected {_MAX_ROUNDS_CEILING} rounds with max_rounds=99, got {result_high.rounds_used}"
    )


# ---------------------------------------------------------------------------
# New tests for Slice 1 features
# ---------------------------------------------------------------------------


def test_success_tests_green_approved(tmp_path):
    """tests_passed=True and needs_human=False when tests pass and VT-3B approves."""
    repo = _make_repo(tmp_path)

    with patch.object(dev_director, "_run_claude", return_value=("done", 0.01, 2, False, None)), \
         patch.object(dev_director, "_run_tests", return_value=(True, "5 passed")), \
         patch.object(dev_director, "_review", return_value=("DONE: looks good", True)), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"):
        result = run_director_loop(
            "Add feature", str(repo), max_rounds=3, _branch_id="succtest",
            **_LOOP_KWARGS,
        )

    assert result.done is True
    assert result.tests_passed is True
    assert result.needs_human is False
    assert result.escalation_reason == ""


def test_escalation_tests_fail_every_round(tmp_path):
    """needs_human=True with test-failure diagnosis when tests never pass."""
    repo = _make_repo(tmp_path)

    with patch.object(dev_director, "_run_claude", return_value=("done", 0.01, 2, False, None)), \
         patch.object(dev_director, "_run_tests", return_value=(False, "FAILED: 3 errors")), \
         patch.object(dev_director, "_review", return_value=("NOT DONE", False)), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"):
        result = run_director_loop(
            "Build X", str(repo), max_rounds=2, _branch_id="esctest",
            **_LOOP_KWARGS,
        )

    assert result.needs_human is True
    assert result.done is False
    reason_lower = result.escalation_reason.lower()
    assert "test" in reason_lower, f"Expected 'test' in escalation_reason: {result.escalation_reason}"
    assert result.tests_passed is False


def test_escalation_vt3b_keeps_rejecting(tmp_path):
    """needs_human=True with VT-3B-rejection diagnosis when tests pass but reviewer never approves."""
    repo = _make_repo(tmp_path)

    with patch.object(dev_director, "_run_claude", return_value=("done", 0.01, 2, False, None)), \
         patch.object(dev_director, "_run_tests", return_value=(True, "5 passed")), \
         patch.object(dev_director, "_review", return_value=("NOT DONE: semantics wrong", False)), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"):
        result = run_director_loop(
            "Build X", str(repo), max_rounds=2, _branch_id="escvt3b",
            **_LOOP_KWARGS,
        )

    assert result.needs_human is True
    assert result.done is False
    # Escalation reason must mention reviewer/VT-3B disagreement
    assert "VT-3B" in result.escalation_reason or "reviewer" in result.escalation_reason.lower()


def test_goal_instruction_contains_goal_and_slash_goal():
    """`_compose_goal_instruction` builds a /goal instruction with test command embedded."""
    instruction = _compose_goal_instruction("add a feature", "tests/ -q")
    assert instruction.startswith("/goal")
    assert "add a feature" in instruction
    assert "tests/ -q" in instruction

    # With feedback: feedback appears after the base instruction
    instruction_fb = _compose_goal_instruction(
        "add a feature", "tests/ -q", feedback="needs error handling"
    )
    assert instruction_fb.startswith("/goal")
    assert "needs error handling" in instruction_fb
    # Base goal and test command still present
    assert "add a feature" in instruction_fb
    assert "tests/ -q" in instruction_fb


def test_run_tests_sets_pythonpath_and_cwd(tmp_path):
    """_run_tests prepends <worktree>/axi/src to PYTHONPATH and sets cwd to <worktree>/axi."""
    from axi.dev_director import _run_tests

    worktree = str(tmp_path / "my-worktree")
    Path(worktree).mkdir()
    (Path(worktree) / "axi").mkdir()

    captured: dict = {}

    def fake_subprocess_run(cmd, **kwargs):
        captured["cmd"] = list(cmd)
        captured["env"] = dict(kwargs.get("env", {}))
        captured["cwd"] = kwargs.get("cwd", "")
        return CompletedProcess(args=cmd, returncode=0, stdout="1 passed", stderr="")

    env = {"PATH": "/usr/bin", "HOME": "/home/user"}

    with patch("axi.dev_director.subprocess.run", side_effect=fake_subprocess_run):
        passed, output = _run_tests(
            worktree, env, "tests/ -q", "/fake/python", timeout=60
        )

    assert passed is True
    expected_src = os.path.join(worktree, "axi", "src")
    assert expected_src in captured["env"]["PYTHONPATH"]
    assert captured["cwd"] == os.path.join(worktree, "axi")
    assert captured["cmd"][0] == "/fake/python"
    assert "-m" in captured["cmd"]
    assert "pytest" in captured["cmd"]


def test_cleanup_runs_on_escalation(tmp_path):
    """_cleanup_worktree is called even when the loop escalates to needs_human."""
    repo = _make_repo(tmp_path)
    cleanup_calls: list = []
    _orig_cleanup = dev_director._cleanup_worktree

    def tracking_cleanup(*args, **kwargs):
        cleanup_calls.append(args)
        return _orig_cleanup(*args, **kwargs)

    with patch.object(dev_director, "_run_claude", return_value=("done", 0.0, 1, False, None)), \
         patch.object(dev_director, "_run_tests", return_value=(False, "FAILED")), \
         patch.object(dev_director, "_review", return_value=("NOT DONE", False)), \
         patch.object(dev_director, "_cleanup_worktree", side_effect=tracking_cleanup), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"):
        result = run_director_loop(
            "Any goal", str(repo), max_rounds=1, _branch_id="escclean",
            **_LOOP_KWARGS,
        )

    assert result.needs_human is True
    assert len(cleanup_calls) == 1, "cleanup must run exactly once even on escalation"


# ---------------------------------------------------------------------------
# Slice 1.5b: session_id capture + resume flag
# ---------------------------------------------------------------------------


def test_dev_director_session_id_captured():
    """_run_claude extracts session_id from JSON; DirectorLoopResult carries it."""
    from axi.dev_director import _run_claude

    captured_args: list = []

    def fake_subprocess_run(args, **kwargs):
        captured_args.extend(args)
        stdout = json.dumps({
            "result": "all done",
            "session_id": "sess-abc123",
            "total_cost_usd": 0.01,
            "num_turns": 2,
            "is_error": False,
        })
        return CompletedProcess(args=list(args), returncode=0, stdout=stdout, stderr="")

    with patch("axi.dev_director.subprocess.run", side_effect=fake_subprocess_run), \
         patch("axi.dev_director._claude_resilience_flags", return_value=([], {})):
        summary, cost, turns, is_error, session_id = _run_claude("/tmp", "instr", 60.0, {})

    assert session_id == "sess-abc123"
    assert is_error is False
    assert summary == "all done"


def test_dev_director_session_id_in_loop_result(tmp_path):
    """run_director_loop passes session_id through to DirectorLoopResult.session_id."""
    repo = _make_repo(tmp_path)

    def fake_run_claude(worktree, instruction, timeout, env, *, resume_session_id=None):
        return ("done", 0.01, 2, False, "sess-loop-xyz")

    with patch.object(dev_director, "_run_claude", side_effect=fake_run_claude), \
         patch.object(dev_director, "_run_tests", return_value=(True, "passed")), \
         patch.object(dev_director, "_review", return_value=("DONE: ok", True)), \
         patch("axi.dev_director.shutil.which", return_value="/usr/bin/claude"):
        result = run_director_loop(
            "Any goal", str(repo), max_rounds=1, _branch_id="sessloop",
            **_LOOP_KWARGS,
        )

    assert result.session_id == "sess-loop-xyz"


def test_dev_director_resume_adds_flag():
    """When resume_session_id is passed to _run_claude, --resume appears in argv."""
    from axi.dev_director import _run_claude

    captured_args: list = []

    def fake_subprocess_run(args, **kwargs):
        captured_args.extend(args)
        stdout = json.dumps({
            "result": "resumed",
            "session_id": "sess-new",
            "total_cost_usd": 0.0,
            "num_turns": 1,
            "is_error": False,
        })
        return CompletedProcess(args=list(args), returncode=0, stdout=stdout, stderr="")

    with patch("axi.dev_director.subprocess.run", side_effect=fake_subprocess_run), \
         patch("axi.dev_director._claude_resilience_flags", return_value=([], {})):
        _run_claude("/tmp", "instr", 60.0, {}, resume_session_id="old-sess-id")

    assert "--resume" in captured_args
    idx = captured_args.index("--resume")
    assert captured_args[idx + 1] == "old-sess-id"
