"""
Tests for axi.dev_agent — the Axi autonomous developer (podman sandbox).

Strategy:
- propose_code_changes uses podman for containment in production.
  Tests use the `_runner` parameter to bypass the real podman invocation so no
  network calls, no podman dependency (except the explicit containment probe
  tests), and no API key are needed.
- A real throwaway git repository is created per test as the `repo_path`, so
  the genuine `git worktree add` / `git diff` machinery is exercised end to end.
- The coroutine is driven with `asyncio.run`, so pytest-asyncio is not needed.

All identifiers, comments, and docstrings are English by project convention.
"""
from __future__ import annotations

import asyncio
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

import claude_agent_sdk as sdk

from axi import dev_agent


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_repo(tmp_path: Path) -> str:
    """Create a real, minimal git repo and return its path."""
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
    (repo / "README.md").write_text("hello\n")
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True, env=env)
    subprocess.run(
        ["git", "commit", "-q", "-m", "init"], cwd=repo, check=True, env=env
    )
    return str(repo)


def _assistant_with_tool(name: str, tool_input: dict) -> sdk.AssistantMessage:
    return sdk.AssistantMessage(
        content=[sdk.ToolUseBlock(id="t1", name=name, input=tool_input)],
        model="claude-test",
    )


def _result_message(
    *,
    is_error: bool = False,
    cost: float | None = 0.0123,
    turns: int = 3,
    result: str | None = "done",
    errors: list[str] | None = None,
) -> sdk.ResultMessage:
    return sdk.ResultMessage(
        subtype="success",
        duration_ms=10,
        duration_api_ms=5,
        is_error=is_error,
        num_turns=turns,
        session_id="sess",
        total_cost_usd=cost,
        result=result,
        errors=errors,
    )


def _make_fake_runner(messages, *, write_file=None, captured=None):
    """
    Build a fake _runner callable for testing propose_code_changes.

    The fake runner writes an output JSON that matches what the real
    _dev_agent_runner.py would write, simulating the SDK run result.
    Optionally writes a file into the worktree to simulate the agent editing
    code (for diff tests). Records the parsed input JSON in `captured`.

    Signature matches the _runner hook: (input_json_path, output_json_path).
    input_json_path points to a temp file outside the worktree.
    output_json_path points to <worktree>/out.json.
    """
    def _runner(input_json_path, output_json_path):
        with open(input_json_path) as f:
            inp = json.load(f)
        if captured is not None:
            captured["input"] = inp
        if write_file is not None and inp.get("worktree_path"):
            rel, content = write_file
            target = Path(inp["worktree_path"]) / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        # Simulate SDK results by processing fake messages
        tool_calls = []
        summary = ""
        cost_usd = 0.0
        num_turns = 0
        is_error = False
        errors = []
        blocked: list[str] = []
        for msg in messages:
            if isinstance(msg, sdk.AssistantMessage):
                for block in msg.content:
                    if isinstance(block, sdk.ToolUseBlock):
                        tool_calls.append(
                            {"tool": block.name,
                             "input_summary": str(block.input)[:200]}
                        )
            elif isinstance(msg, sdk.ResultMessage):
                summary = msg.result or ""
                cost_usd = msg.total_cost_usd or 0.0
                num_turns = msg.num_turns
                is_error = msg.is_error
                if msg.errors:
                    errors.extend(msg.errors)
        result = {
            "summary": summary,
            "cost_usd": cost_usd,
            "num_turns": num_turns,
            "is_error": is_error,
            "errors": errors,
            "tool_calls": tool_calls,
            "blocked_tool_attempts": blocked,
        }
        with open(output_json_path, "w") as f:
            json.dump(result, f)

    return _runner


def _run(coro):
    return asyncio.run(coro)


# ---------------------------------------------------------------------------
# 1. worktree created on axi-dev/ branch
# ---------------------------------------------------------------------------


def test_worktree_created_on_axi_dev_branch(tmp_path):
    repo = _make_repo(tmp_path)
    captured: dict = {}
    runner = _make_fake_runner([_result_message()], captured=captured)

    proposal = _run(
        dev_agent.propose_code_changes(
            "do work", repo, _branch_id="abc123", _runner=runner
        )
    )

    assert proposal.branch == "axi-dev/abc123"
    # The worktree path in the input JSON has the branch id in it.
    assert "axi-dev-abc123" in captured["input"]["worktree_path"]
    # proposal.ok: the runner succeeded
    assert proposal.ok is True


# ---------------------------------------------------------------------------
# 2. worktree removed in finally (happy path)
# ---------------------------------------------------------------------------


def test_worktree_removed_in_finally(tmp_path):
    repo = _make_repo(tmp_path)
    captured: dict = {}
    runner = _make_fake_runner([_result_message()], captured=captured)

    _run(dev_agent.propose_code_changes("work", repo, _branch_id="rm01",
                                        _runner=runner))

    worktree_path = captured["input"]["worktree_path"]
    assert not os.path.exists(worktree_path)
    # `git worktree list` must not reference the path anymore.
    out = subprocess.run(
        ["git", "worktree", "list"], cwd=repo, capture_output=True, text=True
    )
    assert "axi-dev-rm01" not in out.stdout


# ---------------------------------------------------------------------------
# 3. worktree removed on runner error
# ---------------------------------------------------------------------------


def test_worktree_removed_on_sdk_error(tmp_path):
    repo = _make_repo(tmp_path)
    captured: dict = {}

    def _boom(input_json_path, output_json_path):
        with open(input_json_path) as f:
            inp = json.load(f)
        captured["worktree_path"] = inp["worktree_path"]
        raise RuntimeError("kaboom")

    proposal = _run(
        dev_agent.propose_code_changes("work", repo, _branch_id="err01",
                                       _runner=_boom)
    )

    assert proposal.ok is False
    assert "runner error" in (proposal.error or "").lower() or "kaboom" in (proposal.error or "")
    assert not os.path.exists(captured["worktree_path"])


# ---------------------------------------------------------------------------
# 4. options/config passed to runner input JSON
# ---------------------------------------------------------------------------


def test_options_passed_to_sdk(tmp_path):
    repo = _make_repo(tmp_path)
    captured: dict = {}
    runner = _make_fake_runner([_result_message()], captured=captured)

    _run(
        dev_agent.propose_code_changes(
            "task text",
            repo,
            max_budget_usd=0.25,
            max_turns=5,
            model="claude-sonnet",
            _branch_id="opt01",
            _runner=runner,
        )
    )

    inp = captured["input"]
    assert inp["task"] == "task text"
    assert inp["max_budget_usd"] == 0.25
    assert inp["max_turns"] == 5
    assert inp["model"] == "claude-sonnet"
    # No can_use_tool in the JSON (it's runner internals now)
    assert "can_use_tool" not in inp


# ---------------------------------------------------------------------------
# 5. diff and changed files captured
# ---------------------------------------------------------------------------


def test_diff_and_changed_files_captured(tmp_path):
    repo = _make_repo(tmp_path)
    runner = _make_fake_runner(
        [_result_message()],
        write_file=("src/new_feature.py", "print('hi')\n"),
    )

    proposal = _run(
        dev_agent.propose_code_changes("add feature", repo, _branch_id="diff01",
                                       _runner=runner)
    )

    assert proposal.ok is True
    assert "src/new_feature.py" in proposal.changed_files
    assert "new_feature.py" in proposal.diff
    assert "print('hi')" in proposal.diff


# ---------------------------------------------------------------------------
# 6. tool calls extracted
# ---------------------------------------------------------------------------


def test_tool_calls_extracted(tmp_path):
    repo = _make_repo(tmp_path)
    messages = [
        _assistant_with_tool("Read", {"file_path": "README.md"}),
        _assistant_with_tool("Edit", {"file_path": "README.md", "old": "a"}),
        _result_message(),
    ]
    runner = _make_fake_runner(messages)

    proposal = _run(
        dev_agent.propose_code_changes("edit", repo, _branch_id="tc01",
                                       _runner=runner)
    )

    assert len(proposal.tool_calls) == 2
    assert proposal.tool_calls[0]["tool"] == "Read"
    assert proposal.tool_calls[1]["tool"] == "Edit"
    assert "README.md" in proposal.tool_calls[0]["input_summary"]


# ---------------------------------------------------------------------------
# 7. cost and turns from runner output
# ---------------------------------------------------------------------------


def test_cost_and_turns_from_result_message(tmp_path):
    repo = _make_repo(tmp_path)
    runner = _make_fake_runner(
        [_result_message(cost=0.4242, turns=7, result="all good")]
    )

    proposal = _run(
        dev_agent.propose_code_changes("x", repo, _branch_id="ct01",
                                       _runner=runner)
    )

    assert proposal.cost_usd == 0.4242
    assert proposal.num_turns == 7
    assert proposal.summary == "all good"


# ---------------------------------------------------------------------------
# 8. SDK missing returns ok=False
# ---------------------------------------------------------------------------


def test_sdk_missing_returns_ok_false(tmp_path, monkeypatch):
    repo = _make_repo(tmp_path)

    # Force the lazy `import claude_agent_sdk` inside the function to fail.
    import builtins

    real_import = builtins.__import__

    def _fake_import(name, *args, **kwargs):
        if name == "claude_agent_sdk":
            raise ImportError("no sdk")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", _fake_import)

    proposal = _run(
        dev_agent.propose_code_changes("x", repo, _branch_id="missing01")
    )

    assert proposal.ok is False
    assert "claude-agent-sdk not installed" in (proposal.error or "")
    # No worktree should have been created.
    out = subprocess.run(
        ["git", "worktree", "list"], cwd=repo, capture_output=True, text=True
    )
    assert "missing01" not in out.stdout


# ---------------------------------------------------------------------------
# 9. PreToolUse hook returns correct hookSpecificOutput shape (C5 fix)
# ---------------------------------------------------------------------------


def test_pretooluse_hook_deny_shape():
    """The runner's PreToolUse hook returns the correct hookSpecificOutput shape."""
    from axi import _dev_agent_runner as runner

    hook = runner._make_pre_tool_use_hook([])

    # Dangerous: rm must deny
    out = asyncio.run(
        hook({"tool_name": "Bash", "tool_input": {"command": "rm -rf /"}}, None, None)
    )
    assert "hookSpecificOutput" in out
    hso = out["hookSpecificOutput"]
    assert hso["hookEventName"] == "PreToolUse"
    assert hso["permissionDecision"] == "deny"
    assert "permissionDecisionReason" in hso

    # Safe command: allow
    out2 = asyncio.run(
        hook({"tool_name": "Bash", "tool_input": {"command": "ls -a"}}, None, None)
    )
    hso2 = out2["hookSpecificOutput"]
    assert hso2["permissionDecision"] == "allow"


# ---------------------------------------------------------------------------
# 10. safety hook denies dangerous Bash (new hook shape via runner module)
# ---------------------------------------------------------------------------


def test_safety_hook_denies_dangerous_bash():
    """The runner's hook blocks rm, git commit, and allows safe commands."""
    from axi import _dev_agent_runner as runner

    blocked = []
    hook = runner._make_pre_tool_use_hook(blocked)

    out = asyncio.run(
        hook({"tool_name": "Bash", "tool_input": {"command": "rm -rf /"}}, None, None)
    )
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"

    out2 = asyncio.run(
        hook(
            {"tool_name": "Bash", "tool_input": {"command": "git commit -m x"}},
            None,
            None,
        )
    )
    assert out2["hookSpecificOutput"]["permissionDecision"] == "deny"

    out3 = asyncio.run(
        hook(
            {"tool_name": "Bash", "tool_input": {"command": "cat README.md"}},
            None,
            None,
        )
    )
    assert out3["hookSpecificOutput"]["permissionDecision"] == "allow"


# ---------------------------------------------------------------------------
# 11. is_error from runner output flows to ok=False
# ---------------------------------------------------------------------------


def test_is_error_from_result_message(tmp_path):
    repo = _make_repo(tmp_path)
    runner = _make_fake_runner(
        [_result_message(is_error=True, errors=["boom1", "boom2"])]
    )

    proposal = _run(
        dev_agent.propose_code_changes("x", repo, _branch_id="ierr01",
                                       _runner=runner)
    )

    assert proposal.ok is False
    assert "boom1" in (proposal.error or "")
    assert "boom2" in (proposal.error or "")


# ---------------------------------------------------------------------------
# 12. injectable branch id
# ---------------------------------------------------------------------------


def test_injectable_branch_id(tmp_path):
    repo = _make_repo(tmp_path)
    runner = _make_fake_runner([_result_message()])

    proposal = _run(
        dev_agent.propose_code_changes(
            "x", repo, _branch_id="my-custom-id", _runner=runner
        )
    )

    assert proposal.branch == "axi-dev/my-custom-id"

    # And without an injected id, a random 8-char hex id is generated.
    runner2 = _make_fake_runner([_result_message()])
    p2 = _run(dev_agent.propose_code_changes("x", repo, _runner=runner2))
    assert p2.branch.startswith("axi-dev/")
    suffix = p2.branch.split("/", 1)[1]
    assert len(suffix) == 8


# ---------------------------------------------------------------------------
# T1 — build_podman_argv structure (pure unit test, no subprocess)
# ---------------------------------------------------------------------------


def test_build_podman_argv_structure(tmp_path):
    """build_podman_argv returns argv with required podman isolation flags."""
    worktree = str(tmp_path / "worktree")
    runner_p = "/fake/src/axi/_dev_agent_runner.py"
    input_json = "/tmp/axi-input-abc.json"
    image = "localhost/axi-coder:latest"

    argv = dev_agent.build_podman_argv(
        worktree_path=worktree,
        runner_path=runner_p,
        input_json_path=input_json,
        image=image,
    )

    # Basic shape checks
    assert argv[0] == "podman"
    assert "run" in argv
    assert "--rm" in argv
    assert "--userns=keep-id" in argv

    # Worktree mount: <worktree>:/work:Z
    assert "-v" in argv
    worktree_mount = f"{worktree}:/work:Z"
    assert worktree_mount in argv

    # Runner mount: <runner>:/runner.py:ro
    runner_mount = f"{runner_p}:/runner.py:ro"
    assert runner_mount in argv

    # Input JSON mount: <input>:/in.json:ro
    input_mount = f"{input_json}:/in.json:ro"
    assert input_mount in argv

    # Only three -v mounts — count pairs
    v_indices = [i for i, a in enumerate(argv) if a == "-v"]
    assert len(v_indices) == 3, f"Expected exactly 3 -v mounts, got {len(v_indices)}"

    # Check each mount is one of the three expected ones
    expected_mounts = {worktree_mount, runner_mount, input_mount}
    actual_mounts = {argv[i + 1] for i in v_indices}
    assert actual_mounts == expected_mounts

    # ANTHROPIC_API_KEY passed as consecutive pair -e ANTHROPIC_API_KEY
    assert "-e" in argv
    e_idx = argv.index("-e")
    assert argv[e_idx + 1] == "ANTHROPIC_API_KEY"

    # Working directory set to /work
    assert "-w" in argv
    w_idx = argv.index("-w")
    assert argv[w_idx + 1] == "/work"

    # Image appears in argv
    assert image in argv

    # argv ends with the runner command
    assert argv[-4:] == ["python3", "/runner.py", "/in.json", "/work/out.json"]

    # No stray host paths outside the three mounts
    mount_values = {argv[i + 1] for i in v_indices}
    for mount in mount_values:
        host_part = mount.split(":")[0]
        assert host_part in {worktree, runner_p, input_json}, (
            f"Unexpected host path in mount: {host_part}"
        )


# ---------------------------------------------------------------------------
# T1b — build_podman_argv respects custom podman_path and api_key_env
# ---------------------------------------------------------------------------


def test_build_podman_argv_custom_params(tmp_path):
    """Custom podman_path and api_key_env are reflected in argv."""
    argv = dev_agent.build_podman_argv(
        worktree_path="/wt",
        runner_path="/run.py",
        input_json_path="/in.json",
        image="myimage:v1",
        podman_path="/usr/local/bin/podman",
        api_key_env="MY_KEY",
    )
    assert argv[0] == "/usr/local/bin/podman"
    e_idx = argv.index("-e")
    assert argv[e_idx + 1] == "MY_KEY"
    assert "myimage:v1" in argv


# ---------------------------------------------------------------------------
# T2 — Real podman containment probes (integration tests)
# ---------------------------------------------------------------------------

# Skip condition: podman not installed OR axi-coder image not available.
_PODMAN_AVAILABLE = (
    shutil.which("podman") is not None
    and subprocess.run(
        ["podman", "image", "exists", "localhost/axi-coder:latest"],
        capture_output=True,
    ).returncode == 0
)
_PODMAN_SKIP = pytest.mark.skipif(
    not _PODMAN_AVAILABLE,
    reason="podman/axi-coder image not available — skip containment probe",
)


def _run_probe(worktree: str, runner: str, input_json: str, probe_cmd: str) -> subprocess.CompletedProcess:
    """
    Build podman argv for the given paths, replace the runner tail with a
    sh -c probe command, and execute it. Returns the CompletedProcess.
    """
    argv = dev_agent.build_podman_argv(
        worktree_path=worktree,
        runner_path=runner,
        input_json_path=input_json,
        image="localhost/axi-coder:latest",
    )
    # Replace last 4 elements (python3 /runner.py /in.json /work/out.json)
    # with a probe shell command.
    probe_argv = argv[:-4] + ["sh", "-c", probe_cmd]
    return subprocess.run(probe_argv, capture_output=True, text=True, timeout=30)


@pytest.fixture
def _podman_probe_paths(tmp_path):
    """Fixture providing real paths needed for podman probe tests."""
    worktree = str(tmp_path / "probe-worktree")
    os.makedirs(worktree, exist_ok=True)

    runner = dev_agent._resolve_runner_path()

    # Create a minimal input JSON file (mounted read-only; content unused by probes)
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False
    ) as tf:
        json.dump({"task": "probe", "worktree_path": worktree}, tf)
        input_json = tf.name

    yield worktree, runner, input_json

    # Cleanup
    try:
        os.unlink(input_json)
    except Exception:
        pass


@_PODMAN_SKIP
def test_t2a_ssh_absent_inside_container(_podman_probe_paths):
    """T2a: ~/.ssh must NOT be visible inside the container."""
    worktree, runner, input_json = _podman_probe_paths
    probe = 'test ! -e /home/$(id -un)/.ssh && echo ABSENT || echo PRESENT'
    result = _run_probe(worktree, runner, input_json, probe)
    assert "ABSENT" in result.stdout or result.returncode == 0 and "PRESENT" not in result.stdout, (
        f"Expected SSH dir to be absent inside container. stdout={result.stdout!r}"
    )


@_PODMAN_SKIP
def test_t2b_env_scrubbing(_podman_probe_paths):
    """T2b: FAKE_SECRET must be absent; ANTHROPIC_API_KEY must be present."""
    worktree, runner, input_json = _podman_probe_paths
    probe = 'echo "FAKE=${FAKE_SECRET:-ABSENT}"; echo "KEY=${ANTHROPIC_API_KEY:-ABSENT}"'

    env = {
        **os.environ,
        "FAKE_SECRET": "hunter2",
        "ANTHROPIC_API_KEY": "test-key-for-probe",
    }
    argv = dev_agent.build_podman_argv(
        worktree_path=worktree,
        runner_path=runner,
        input_json_path=input_json,
        image="localhost/axi-coder:latest",
    )
    probe_argv = argv[:-4] + ["sh", "-c", probe]
    result = subprocess.run(probe_argv, capture_output=True, text=True, timeout=30, env=env)

    assert "FAKE=ABSENT" in result.stdout, (
        f"FAKE_SECRET should be absent inside container. stdout={result.stdout!r}"
    )
    assert "KEY=test-key-for-probe" in result.stdout, (
        f"ANTHROPIC_API_KEY should be present inside container. stdout={result.stdout!r}"
    )


@_PODMAN_SKIP
def test_t2c_worktree_writable(_podman_probe_paths):
    """T2c: container must be able to write to /work, and host sees the file."""
    worktree, runner, input_json = _podman_probe_paths
    probe = "touch /work/probe_was_here && echo WRITTEN"
    result = _run_probe(worktree, runner, input_json, probe)

    assert result.returncode == 0, f"Probe failed. stderr={result.stderr!r}"
    assert "WRITTEN" in result.stdout, f"Expected WRITTEN in stdout. got={result.stdout!r}"
    assert os.path.exists(os.path.join(worktree, "probe_was_here")), (
        "File written inside container was not visible on host after exit"
    )


# ---------------------------------------------------------------------------
# T3 — fail-closed: sandbox disabled in config
# ---------------------------------------------------------------------------


def test_fail_closed_sandbox_disabled(tmp_path, monkeypatch):
    """If dev_agent_sandbox is False in config, propose_code_changes returns ok=False."""
    repo = _make_repo(tmp_path)
    called = []

    def _fake_runner(inp, out):
        called.append(True)

    # Monkeypatch config.get so dev_agent_sandbox returns False.
    from axi import config as _config
    original_get = _config.get

    def _patched_get(key, default=None):
        if key == "dev_agent_sandbox":
            return False
        return original_get(key, default)

    monkeypatch.setattr(_config, "get", _patched_get)

    proposal = _run(
        dev_agent.propose_code_changes(
            "task", repo, _branch_id="fc01", _runner=_fake_runner
        )
    )

    # _runner uses the test hook path; but fail-closed is checked first when
    # _runner is None. Since _runner is provided, pre-flight is skipped.
    # To test the config check properly, call WITHOUT _runner and mock subprocess.
    # The _runner hook bypasses pre-flight by design (test isolation).
    # Use a direct call without _runner to exercise the real pre-flight path:
    called2 = []
    real_run = subprocess.run

    def _track_run(args, **kwargs):
        if isinstance(args, list) and args and "podman" in str(args[0]):
            called2.append(args)
        return real_run(args, **kwargs)

    monkeypatch.setattr(subprocess, "run", _track_run)

    proposal2 = _run(
        dev_agent.propose_code_changes("task", repo, _branch_id="fc02")
    )
    assert proposal2.ok is False
    assert "refusing to run uncontained" in (proposal2.error or "")
    # Podman must NEVER have been called (check 1 must short-circuit before podman)
    podman_calls = [c for c in called2 if "podman" in str(c[0]) and "image" in c]
    assert len(podman_calls) == 0, f"Podman was called unexpectedly: {podman_calls}"


# ---------------------------------------------------------------------------
# T4 — fail-closed: image missing
# ---------------------------------------------------------------------------


def test_fail_closed_image_missing(tmp_path, monkeypatch):
    """If the axi-coder image is not available, propose_code_changes returns ok=False."""
    repo = _make_repo(tmp_path)

    from axi import config as _config
    original_get = _config.get

    # Sandbox is enabled, but the image check will fail.
    def _patched_get(key, default=None):
        if key == "dev_agent_sandbox":
            return True
        return original_get(key, default)

    monkeypatch.setattr(_config, "get", _patched_get)

    # Monkeypatch shutil.which to return a fake podman path.
    monkeypatch.setattr(shutil, "which", lambda name: "/usr/bin/podman" if name == "podman" else None)

    # Monkeypatch subprocess.run so "podman image exists" returns returncode=1.
    real_run = subprocess.run

    def _fake_run(args, **kwargs):
        if (
            isinstance(args, list)
            and len(args) >= 3
            and "podman" in str(args[0])
            and "image" in args
            and "exists" in args
        ):
            import subprocess as _sp
            return _sp.CompletedProcess(args=args, returncode=1, stdout="", stderr="")
        return real_run(args, **kwargs)

    monkeypatch.setattr(subprocess, "run", _fake_run)

    proposal = _run(
        dev_agent.propose_code_changes("task", repo, _branch_id="fc-img")
    )

    assert proposal.ok is False
    assert "refusing to run uncontained" in (proposal.error or "")


# ---------------------------------------------------------------------------
# T5 — diff excludes out.json
# ---------------------------------------------------------------------------


def test_diff_excludes_out_json(tmp_path):
    """out.json written by the runner must NOT appear in the captured diff."""
    repo = _make_repo(tmp_path)

    def _runner_writes_both(input_json_path, output_json_path):
        """Simulate runner: writes out.json AND a real code change."""
        with open(input_json_path) as f:
            inp = json.load(f)
        worktree = inp["worktree_path"]

        # Write a code file (should appear in diff)
        (Path(worktree) / "new_code.py").write_text("x = 1\n")

        # Write out.json result (should NOT appear in diff)
        result = {
            "summary": "done",
            "cost_usd": 0.01,
            "num_turns": 1,
            "is_error": False,
            "errors": [],
            "tool_calls": [],
            "blocked_tool_attempts": [],
        }
        with open(output_json_path, "w") as f:
            json.dump(result, f)

    proposal = _run(
        dev_agent.propose_code_changes("task", repo, _branch_id="outjson01",
                                       _runner=_runner_writes_both)
    )

    assert proposal.ok is True
    # new_code.py must be in the diff
    assert "new_code.py" in proposal.diff
    # out.json must NOT appear in the diff or changed_files
    assert "out.json" not in proposal.diff
    assert "out.json" not in proposal.changed_files


# ---------------------------------------------------------------------------
# T6 — C5 hook deny-shape (kept from original test suite, tests _dev_agent_runner)
# ---------------------------------------------------------------------------
# (Already covered by tests 9 and 10 above — no separate T6 needed.)
