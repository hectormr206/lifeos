"""
Axi autonomous developer — podman-based sandbox.

propose_code_changes() delegates a coding task to a Claude agent running in an
isolated git worktree AND inside a rootless podman container, captures the
resulting diff, and returns a structured CodeProposal. It never commits or
pushes.

Safety is enforced in depth:
  - The Claude SDK runs in a subprocess inside a podman container:
      * FS isolation: only the worktree (/work:Z, writable), the runner script
        (/runner.py:ro), and the input JSON (/in.json:ro) are mounted. /home
        is NOT mounted — SSH keys, .env files, etc. are invisible.
      * Env scrubbing: podman inherits NO host env vars except ANTHROPIC_API_KEY
        (passed via `-e ANTHROPIC_API_KEY`).
      * User namespace: --userns=keep-id so the mounted worktree is writable
        by the container user without requiring root.
      * Network is allowed (needed for API calls) but /home secrets are absent.
  - Inside the container, _dev_agent_runner.py configures:
      * disallowed_tools removes WebSearch/WebFetch from the model context.
      * permission_mode="dontAsk" auto-denies non-allowed tools.
      * A PreToolUse hook blocks dangerous Bash patterns using the correct
        hookSpecificOutput shape (C5 fix).
  - Fail-closed: if the sandbox config is disabled, podman is unavailable, or
    the axi-coder image is missing, returns ok=False immediately — the agent
    never runs uncontained.

The worktree is always torn down in a finally block.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
import uuid
from dataclasses import dataclass

from axi import config

log = logging.getLogger("axi.dev_agent")

# Bash command patterns the safety gate must block unconditionally.
# Also used by _dev_agent_runner.py (which imports these directly, or
# duplicates them for standalone operation inside the container).
_BLOCKLIST_RE = re.compile(
    r"git\s+(push|reset\s+--hard|clean\s+-f)|\brm\s+|\bgit\s+commit\b|\bcurl\b|\bwget\b|\.(env|credentials|secrets)\b",
    re.IGNORECASE,
)

_BLOCKED_TOOLS = {"WebSearch", "WebFetch"}

# Secret file patterns to unstage after `git add -A` in the worktree.
_SECRET_PATTERNS = [
    ".env",
    ".credentials",
    ".secrets",
    "*.key",
    "*.pem",
    "*.p12",
    "*.pfx",
]


@dataclass
class CodeProposal:
    task: str
    branch: str
    diff: str
    changed_files: list[str]
    summary: str
    cost_usd: float
    num_turns: int
    tool_calls: list[dict]
    blocked_tool_attempts: list[str]
    ok: bool
    error: str | None = None


def _is_dangerous(tool_name: str, tool_input: dict) -> bool:
    """Return True if this tool call should be blocked by the safety gate."""
    if tool_name in _BLOCKED_TOOLS:
        return True
    if tool_name == "Bash":
        command = ""
        if isinstance(tool_input, dict):
            command = tool_input.get("command", "") or tool_input.get("cmd", "")
        if _BLOCKLIST_RE.search(str(command)):
            return True
    return False


def _filter_staged_secrets(worktree_path: str) -> None:
    """
    Unstage known secret file patterns from the worktree index.

    Called after `git add -A` to prevent secrets from appearing in the diff
    or being accidentally committed. Best-effort: errors are silently ignored.
    """
    for pattern in _SECRET_PATTERNS:
        try:
            subprocess.run(
                ["git", "-C", worktree_path, "reset", "HEAD", "--", pattern],
                capture_output=True,
            )
        except Exception:
            pass


def build_podman_argv(
    *,
    worktree_path: str,
    runner_path: str,
    input_json_path: str,
    image: str,
    podman_path: str = "podman",
    api_key_env: str = "ANTHROPIC_API_KEY",
) -> list[str]:
    """
    Build the podman argv for running _dev_agent_runner.py inside a container.

    This is a pure function: no I/O, no side effects, no state changes.
    The caller is responsible for actually invoking the result.

    Isolation properties:
    - Three mounts only: worktree (writable), runner script (ro), input JSON (ro).
    - /home is NOT mounted — SSH keys, .env files, etc. are invisible.
    - Environment: only ANTHROPIC_API_KEY is passed from the host (via -e KEY form).
    - --userns=keep-id: host UID maps into container so worktree is writable.
    - --rm: container is removed after exit.
    - Network is NOT blocked (needed for Claude API calls).

    Parameters
    ----------
    worktree_path:
        Absolute path to the git worktree the agent operates in.
        Mounted writable at /work inside the container.
    runner_path:
        Absolute path to _dev_agent_runner.py on the host.
        Mounted read-only at /runner.py inside the container.
    input_json_path:
        Absolute path to the input JSON file on the host.
        Mounted read-only at /in.json inside the container.
    image:
        Podman image to run (e.g. "localhost/axi-coder:latest").
    podman_path:
        Path to the podman binary.
    api_key_env:
        Name of the environment variable to forward from the host.
    """
    return [
        podman_path, "run", "--rm", "--userns=keep-id",
        "-v", f"{worktree_path}:/work:Z",
        "-v", f"{runner_path}:/runner.py:ro",
        "-v", f"{input_json_path}:/in.json:ro",
        "-e", api_key_env,
        "-w", "/work",
        image,
        "python3", "/runner.py", "/in.json", "/work/out.json",
    ]


async def propose_code_changes(
    task: str,
    repo_path: str,
    *,
    max_budget_usd: float = 0.50,
    max_turns: int = 8,
    model: str | None = None,
    _branch_id: str | None = None,
    _runner=None,
) -> "CodeProposal":
    """
    Delegate a coding task to a Claude agent in an isolated git worktree.

    The agent runs inside a rootless podman container (see module docstring).
    Returns a CodeProposal with the diff of proposed changes. Never commits or
    pushes. Never raises for operational failures — returns ok=False with error
    set instead.

    Parameters
    ----------
    task:
        The coding task description passed to the agent.
    repo_path:
        Absolute path to the git repository root.
    max_budget_usd:
        Hard cost cap in USD for a single run.
    max_turns:
        Maximum agentic turns for a single run.
    model:
        Claude model override. None uses the SDK default.
    _branch_id:
        Testing hook: deterministic branch suffix instead of random UUID.
    _runner:
        Testing hook: callable(input_json_path, output_json_path) → None.
        When set, bypasses podman subprocess invocation and the pre-flight
        sandbox check so unit tests work without podman installed.
    """
    # Lazy import — module is importable even if the SDK is not installed.
    try:
        import claude_agent_sdk  # noqa: F401
    except ImportError:
        return CodeProposal(
            task=task,
            branch="",
            diff="",
            changed_files=[],
            summary="",
            cost_usd=0.0,
            num_turns=0,
            tool_calls=[],
            blocked_tool_attempts=[],
            ok=False,
            error="claude-agent-sdk not installed — run: uv add claude-agent-sdk",
        )

    _image = config.get("dev_agent_image", "localhost/axi-coder:latest")

    # ── Fail-closed sandbox guard ──────────────────────────────────────────
    # The agent MUST run in a podman sandbox. The pre-flight check is skipped
    # only when _runner is provided (unit-test hook). In production, all three
    # checks must pass or we refuse to run uncontained.
    if _runner is None:
        _fail_error = (
            "podman sandbox/image unavailable; refusing to run uncontained"
        )

        # Check 1: sandbox must be enabled in config.
        if not config.get("dev_agent_sandbox", True):
            return CodeProposal(
                task=task,
                branch="",
                diff="",
                changed_files=[],
                summary="",
                cost_usd=0.0,
                num_turns=0,
                tool_calls=[],
                blocked_tool_attempts=[],
                ok=False,
                error=_fail_error,
            )

        # Check 2: podman binary must be installed.
        _podman_bin = shutil.which("podman")
        if not _podman_bin:
            return CodeProposal(
                task=task,
                branch="",
                diff="",
                changed_files=[],
                summary="",
                cost_usd=0.0,
                num_turns=0,
                tool_calls=[],
                blocked_tool_attempts=[],
                ok=False,
                error=_fail_error,
            )

        # Check 3: the axi-coder image must exist locally.
        img_check = subprocess.run(
            [_podman_bin, "image", "exists", _image],
            capture_output=True,
        )
        if img_check.returncode != 0:
            return CodeProposal(
                task=task,
                branch="",
                diff="",
                changed_files=[],
                summary="",
                cost_usd=0.0,
                num_turns=0,
                tool_calls=[],
                blocked_tool_attempts=[],
                ok=False,
                error=_fail_error,
            )
    else:
        _podman_bin = shutil.which("podman") or "podman"

    branch_id = _branch_id or uuid.uuid4().hex[:8]
    branch_name = f"axi-dev/{branch_id}"

    # Use a temp dir as the parent for the worktree.
    tmp_parent = tempfile.mkdtemp(prefix="axi-wt-")
    worktree_path = os.path.join(tmp_parent, f"axi-dev-{branch_id}")

    # Input JSON lives OUTSIDE the worktree so it doesn't appear in the diff
    # and is not accidentally staged.
    input_json_path: str | None = None

    try:
        # Create the isolated worktree on a fresh branch.
        result = subprocess.run(
            ["git", "worktree", "add", worktree_path, "-b", branch_name],
            cwd=repo_path,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return CodeProposal(
                task=task,
                branch=branch_name,
                diff="",
                changed_files=[],
                summary="",
                cost_usd=0.0,
                num_turns=0,
                tool_calls=[],
                blocked_tool_attempts=[],
                ok=False,
                error=f"git worktree add failed: {result.stderr.strip()}",
            )

        # Write the input JSON for the runner to a temp file OUTSIDE the
        # worktree so it is not tracked by git and won't appear in the diff.
        input_data = {
            "task": task,
            "worktree_path": worktree_path,
            "max_budget_usd": max_budget_usd,
            "max_turns": max_turns,
            "model": model,
            "anthropic_api_key": os.environ.get("ANTHROPIC_API_KEY", ""),
        }
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as tf:
            json.dump(input_data, tf)
            input_json_path = tf.name

        # Output JSON is written by the runner to /work/out.json inside the
        # container, which maps to <worktree>/out.json on the host.
        output_json_path = os.path.join(worktree_path, "out.json")

        # ── Invoke the runner (real podman or test hook) ───────────────────
        try:
            if _runner is not None:
                # Test hook: call directly (bypasses podman subprocess).
                _runner(input_json_path, output_json_path)
            else:
                # Production path: run inside podman container.
                runner_path = _resolve_runner_path()
                argv = build_podman_argv(
                    worktree_path=worktree_path,
                    runner_path=runner_path,
                    input_json_path=input_json_path,
                    image=_image,
                    podman_path=_podman_bin,
                )
                proc = subprocess.run(
                    argv,
                    capture_output=True,
                    text=True,
                    env=os.environ,
                )
                if proc.returncode != 0:
                    return CodeProposal(
                        task=task,
                        branch=branch_name,
                        diff="",
                        changed_files=[],
                        summary="",
                        cost_usd=0.0,
                        num_turns=0,
                        tool_calls=[],
                        blocked_tool_attempts=[],
                        ok=False,
                        error=(
                            f"podman runner failed (exit {proc.returncode}): "
                            f"{proc.stderr[:500]}"
                        ),
                    )
        except Exception as runner_err:
            return CodeProposal(
                task=task,
                branch=branch_name,
                diff="",
                changed_files=[],
                summary="",
                cost_usd=0.0,
                num_turns=0,
                tool_calls=[],
                blocked_tool_attempts=[],
                ok=False,
                error=f"runner error: {runner_err}",
            )

        # Read the output JSON written by the runner.
        try:
            with open(output_json_path) as f:
                run_result = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError) as e:
            return CodeProposal(
                task=task,
                branch=branch_name,
                diff="",
                changed_files=[],
                summary="",
                cost_usd=0.0,
                num_turns=0,
                tool_calls=[],
                blocked_tool_attempts=[],
                ok=False,
                error=f"runner output missing/invalid: {e}",
            )

        tool_calls: list[dict] = run_result.get("tool_calls", [])
        blocked_tool_attempts: list[str] = run_result.get("blocked_tool_attempts", [])
        summary = run_result.get("summary", "")
        cost_usd = run_result.get("cost_usd", 0.0)
        num_turns = run_result.get("num_turns", 0)
        is_error = run_result.get("is_error", False)
        result_errors: list[str] = run_result.get("errors", [])

        # Capture the diff from the parent process (staged so new files show up).
        # Unstage out.json so the runner output artifact is excluded from the diff.
        # Filter out secret files before diffing.
        subprocess.run(
            ["git", "-C", worktree_path, "add", "-A"],
            capture_output=True,
        )
        # Exclude the runner output file from the diff — it is an artifact,
        # not a code change authored by the agent.
        subprocess.run(
            ["git", "-C", worktree_path, "reset", "out.json"],
            capture_output=True,
        )
        _filter_staged_secrets(worktree_path)

        diff_result = subprocess.run(
            ["git", "-C", worktree_path, "diff", "--cached"],
            capture_output=True,
            text=True,
        )
        names_result = subprocess.run(
            ["git", "-C", worktree_path, "diff", "--cached", "--name-only"],
            capture_output=True,
            text=True,
        )
        # Cap diff at 200 KB to prevent pathological output.
        diff = diff_result.stdout[:200_000]
        changed_files = [f for f in names_result.stdout.splitlines() if f.strip()]

        ok = not is_error
        error = "; ".join(result_errors) if result_errors else None

        # Best-effort audit log.
        try:
            from axi import events  # noqa: PLC0415

            events.log_event(
                source="dev_agent",
                level="info",
                message=(
                    f"dev_agent run: branch={branch_name} ok={ok} "
                    f"cost={cost_usd:.4f} turns={num_turns}"
                ),
                data={
                    "task": task[:200],
                    "branch": branch_name,
                    "cost_usd": cost_usd,
                    "num_turns": num_turns,
                    "tool_calls": len(tool_calls),
                    "blocked": len(blocked_tool_attempts),
                    "ok": ok,
                },
            )
        except Exception:
            pass

        return CodeProposal(
            task=task,
            branch=branch_name,
            diff=diff,
            changed_files=changed_files,
            summary=summary,
            cost_usd=cost_usd,
            num_turns=num_turns,
            tool_calls=tool_calls,
            blocked_tool_attempts=blocked_tool_attempts,
            ok=ok,
            error=error,
        )

    finally:
        # Always remove the worktree, even on error.
        try:
            subprocess.run(
                ["git", "worktree", "remove", "--force", worktree_path],
                cwd=repo_path,
                capture_output=True,
            )
        except Exception:
            pass
        # Best-effort branch cleanup (branch ref persists even after worktree removal).
        try:
            subprocess.run(
                ["git", "-C", repo_path, "branch", "-D", branch_name],
                capture_output=True,
            )
        except Exception:
            pass
        # Prune stale worktree entries.
        try:
            subprocess.run(
                ["git", "-C", repo_path, "worktree", "prune"],
                capture_output=True,
            )
        except Exception:
            pass
        try:
            shutil.rmtree(tmp_parent, ignore_errors=True)
        except Exception:
            pass
        # Remove the temp input JSON written outside the worktree.
        if input_json_path is not None:
            try:
                os.unlink(input_json_path)
            except Exception:
                pass


def _resolve_runner_path() -> str:
    """Return the absolute path to _dev_agent_runner.py."""
    return os.path.join(os.path.dirname(__file__), "_dev_agent_runner.py")


def propose_code_changes_sync(task: str, repo_path: str, **kwargs) -> "CodeProposal":
    """Synchronous wrapper around propose_code_changes for non-async callers."""
    return asyncio.run(propose_code_changes(task, repo_path, **kwargs))
