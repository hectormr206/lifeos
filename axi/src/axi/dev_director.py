"""
Axi dev-director — Claude Code self-iterates via /goal; VT-3B does semantic review.

run_director_round() is a single-pass helper (VT-3B-directed, legacy path).
run_director_loop() is the main multi-round loop:
  1. Compose a /goal instruction so Claude self-iterates to green tests.
  2. Run the test suite in the worktree (PYTHONPATH-isolated from live install).
  3. VT-3B reviews the diff *semantically* (does it satisfy the goal?).
  4. Stop when tests pass AND VT-3B approves; otherwise refine + retry.
  5. The worktree is cleaned up unconditionally; nothing is ever committed or pushed.

Only stdlib is used for HTTP (urllib.request).
"""
from __future__ import annotations

import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from uuid import uuid4

log = logging.getLogger("axi.dev_director")

# ---------------------------------------------------------------------------
# Regex patterns for stripping VT-3B reasoning artefacts
# ---------------------------------------------------------------------------

_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL)
_THINK_UNCLOSED_RE = re.compile(r"<think>.*", re.DOTALL)
_BOXED_RE = re.compile(r"\\boxed\{([^{}]*)\}")

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

_DIRECTOR_SYSTEM = (
    "You are a senior software engineer directing an AI coding agent. "
    "Given a goal, produce ONE specific, actionable coding instruction for Claude Code. "
    "Include: what file/function to target, the expected behavior, edge cases to handle, "
    "and that tests must be added. Be concise and precise. Output only the instruction."
)

_REVIEWER_SYSTEM = (
    "You are a code reviewer. Given a goal and a git diff, decide if the implementation "
    "is correct and complete. Start your answer with 'DONE' if satisfied, or 'NOT DONE' "
    "if there are issues, followed by a brief reason."
)

_CORRECTIVE_SYSTEM = (
    "You are a senior software engineer directing an AI coding agent on a corrective pass. "
    "The previous coding attempt was reviewed and found incomplete or incorrect. "
    "Given the goal, the accumulated diff from the previous attempt, and the reviewer's "
    "specific feedback, produce ONE specific, actionable corrective coding instruction "
    "for Claude Code. Address the reviewer's concerns directly. Be concise and precise. "
    "Output only the instruction."
)

_DIFF_EXCLUDE_PATHSPECS = [
    ".",
    ":(exclude,glob)**/__pycache__/**",
    ":(exclude,glob)**/*.pyc",
    ":(exclude,glob)**/*.pyo",
    ":(exclude,glob).atl/**",
    ":(exclude,glob)**/.pytest_cache/**",
    ":(exclude,glob)**/.mypy_cache/**",
    ":(exclude,glob)**/.ruff_cache/**",
    ":(exclude,glob)**/node_modules/**",
    ":(exclude,glob)**/*.egg-info/**",
    ":(exclude,glob)**/.DS_Store",
]

_MAX_ROUNDS_CEILING = 8
_MIN_ROUNDS_FLOOR = 1

# ---------------------------------------------------------------------------
# Result dataclasses
# ---------------------------------------------------------------------------


@dataclass
class DirectorResult:
    goal: str
    instruction: str
    branch: str
    diff: str
    changed_files: list[str]
    claude_summary: str
    claude_cost_usd: float
    claude_num_turns: int
    review_done: bool
    review_feedback: str
    ok: bool
    error: str | None = None


@dataclass
class DirectorRoundInfo:
    round_index: int
    instruction: str
    diff: str
    changed_files: list[str]
    claude_summary: str
    claude_cost_usd: float
    claude_num_turns: int
    review_done: bool
    review_feedback: str


@dataclass
class DirectorLoopResult:
    goal: str
    branch: str
    rounds: list[DirectorRoundInfo]
    final_diff: str
    final_changed_files: list[str]
    done: bool
    rounds_used: int
    total_cost_usd: float
    total_claude_turns: int
    ok: bool
    error: str | None = None
    tests_passed: bool = False
    needs_human: bool = False
    escalation_reason: str = ""
    session_id: str | None = None
    # Filesystem path of the worktree. Empty unless keep_worktree=True (the
    # persistent-environment mode) — in patch mode the worktree is deleted, so
    # there is nothing to point at.
    worktree_path: str = ""


# ---------------------------------------------------------------------------
# VT-3B HTTP helper
# ---------------------------------------------------------------------------


def _call_vt3b(
    system: str,
    user: str,
    *,
    port: int = 8082,
    max_tokens: int = 2000,
    timeout: float | None = None,
    retry_deadline: float = 90.0,
) -> str:
    """POST to OpenAI-compat endpoint, strip <think>...</think> and \\boxed{...}, return content.

    *timeout* (seconds) bounds each HTTP attempt; None keeps urllib's global
    default. *retry_deadline* (seconds) keeps retrying TRANSPORT errors (VT
    unreachable) up to that long, so an in-progress dev-run survives VT briefly
    disappearing — e.g. relocating GPU->CPU on game-mode entry, or a restart.
    Callers that must not block — e.g. generating an environment's title at
    creation — pass retry_deadline=0 (and a small timeout) to fail fast.
    """
    payload = json.dumps(
        {
            "model": "VibeThinker-3B",
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "max_tokens": max_tokens,
        }
    ).encode()

    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    # Retry transport errors up to retry_deadline so an in-progress dev-run is
    # NOT killed when VT briefly disappears (relocating GPU->CPU for game mode,
    # or restarting). urllib's URLError is an OSError subclass, so OSError covers
    # connection-refused / timeout / transport. A 200 with malformed JSON raises
    # ValueError below — NOT retried (that's a real error).
    _deadline = time.monotonic() + max(0.0, retry_deadline)
    _delay = 1.0
    while True:
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = json.loads(resp.read().decode())
            break
        except OSError as e:
            if time.monotonic() >= _deadline:
                raise
            log.info(
                "VT call failed (%s) — retrying in %.1fs (VT may be relocating to CPU)",
                e, _delay,
            )
            time.sleep(_delay)
            _delay = min(_delay * 1.6, 8.0)

    content: str = body["choices"][0]["message"]["content"]
    content = _THINK_RE.sub("", content)
    content = _THINK_UNCLOSED_RE.sub("", content)
    content = _BOXED_RE.sub(r"\1", content)
    return content.strip()


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _compose_goal_instruction(goal: str, test_command: str, feedback: str | None = None) -> str:
    """Build the /goal instruction for Claude Code's self-iteration loop."""
    base = (
        f"/goal {goal} — Criterio de éxito: la funcionalidad pedida está implementada "
        f"Y `{test_command}` pasa en verde."
    )
    if feedback:
        return f"{base}\n\nFeedback anterior (incorporar):\n{feedback}"
    return base


def _create_worktree(repo_path: str, worktree_path: str, branch_name: str) -> tuple[bool, str]:
    """Create a git worktree on a new branch. Returns (ok, error_message).

    Idempotent: if *worktree_path* already exists and is registered as a worktree
    (the persistent-environment resume case — keep_worktree left it on disk), it
    is reused as-is rather than re-created, since `git worktree add` would fail on
    an existing path/branch. Prior uncommitted edits in the worktree survive.
    """
    if os.path.isdir(worktree_path):
        listing = subprocess.run(
            ["git", "-C", repo_path, "worktree", "list", "--porcelain"],
            capture_output=True, text=True,
        )
        if listing.returncode == 0 and worktree_path in listing.stdout:
            return True, ""  # already a live worktree — reuse it
    result = subprocess.run(
        ["git", "worktree", "add", worktree_path, "-b", branch_name],
        cwd=repo_path,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return False, f"git worktree add failed: {result.stderr.strip()}"
    return True, ""


def _claude_resilience_flags() -> tuple[list[str], dict[str, str]]:
    """Flags + env that keep a long unattended headless run alive (verified vs
    the Claude Code docs). Returns (extra_argv, extra_env).

    NOTE: --bare is intentionally NOT used — it skips the credential/login state
    too, so a headless run reports "Not logged in" (verified live). The dev
    subprocess therefore loads the project CLAUDE.md, but auth works.

    - --max-turns / --max-budget-usd: hard runaway caps (turns + cost).
    - --fallback-model: auto-fallback when the primary model is overloaded.
    - CLAUDE_CODE_RETRY_WATCHDOG=1: retry 429/overload INDEFINITELY (capacity bursts).
    - CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0: remove the 10-min background wait cap.
    """
    from axi import config  # noqa: PLC0415
    max_turns = int(config.get("dev_director_max_turns", 60))
    max_budget = float(config.get("dev_director_max_budget_usd", 5.0))
    fallbacks = str(config.get("dev_director_fallback_models", "sonnet,haiku"))
    argv = [
        "--max-turns", str(max_turns),
        "--max-budget-usd", str(max_budget),
    ]
    if fallbacks.strip():
        argv += ["--fallback-model", fallbacks.strip()]
    extra_env = {
        "CLAUDE_CODE_RETRY_WATCHDOG": "1",
        "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS": "0",
    }
    return argv, extra_env


def _run_claude(
    worktree_path: str,
    instruction: str,
    timeout: float,
    env: dict,
    *,
    resume_session_id: str | None = None,
) -> tuple[str, float, int, bool, str | None]:
    """Run claude CLI with the given instruction.

    Returns (summary, cost_usd, num_turns, is_error, session_id).
    Pass resume_session_id to continue a prior Claude Code session.
    """
    extra_argv, extra_env = _claude_resilience_flags()
    run_env = {**env, **extra_env}
    resume_argv = ["--resume", resume_session_id] if resume_session_id else []
    proc = subprocess.run(
        [
            "claude",
            "-p", instruction,
            "--output-format", "json",
            "--permission-mode", "bypassPermissions",
            *resume_argv,
            *extra_argv,
        ],
        cwd=worktree_path,
        timeout=timeout,
        capture_output=True,
        text=True,
        env=run_env,
    )
    summary = ""
    cost = 0.0
    turns = 0
    is_error = False
    session_id: str | None = None
    try:
        out = json.loads(proc.stdout)
        summary = out.get("result", "")
        cost = float(out.get("total_cost_usd", 0.0))
        turns = int(out.get("num_turns", 0))
        is_error = bool(out.get("is_error", False))
        session_id = out.get("session_id") or None
    except (json.JSONDecodeError, ValueError, TypeError):
        is_error = proc.returncode != 0
    return summary, cost, turns, is_error, session_id


def _run_tests(
    worktree_path: str,
    env: dict,
    test_command: str,
    venv_python: str,
    timeout: int = 300,
) -> tuple[bool, str]:
    """Run the test suite with the worktree's src on PYTHONPATH.

    Prepends <worktree>/axi/src to PYTHONPATH so the editable live install is
    shadowed by the worktree's code. Returns (passed, combined_output).
    """
    test_env = dict(env)
    axi_src = os.path.join(worktree_path, "axi", "src")
    existing_pp = test_env.get("PYTHONPATH", "")
    test_env["PYTHONPATH"] = f"{axi_src}:{existing_pp}" if existing_pp else axi_src

    cmd = [os.path.expanduser(venv_python), "-m", "pytest"] + test_command.split()
    cwd = os.path.join(worktree_path, "axi")
    try:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            env=test_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            text=True,
        )
        output = proc.stdout or ""
    except subprocess.TimeoutExpired:
        return False, f"Tests timed out after {timeout}s"
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)
    if len(output) > 3000:
        output = output[-3000:]
    return proc.returncode == 0, output


def _stage_and_diff(worktree_path: str) -> tuple[str, list[str]]:
    """Stage all changes and return (diff_text, changed_file_list)."""
    subprocess.run(
        ["git", "-C", worktree_path, "add", "-A"],
        capture_output=True,
    )
    diff_proc = subprocess.run(
        ["git", "-C", worktree_path, "diff", "--cached", "--", *_DIFF_EXCLUDE_PATHSPECS],
        capture_output=True,
        text=True,
    )
    names_proc = subprocess.run(
        ["git", "-C", worktree_path, "diff", "--cached", "--name-only",
         "--", *_DIFF_EXCLUDE_PATHSPECS],
        capture_output=True,
        text=True,
    )
    diff = diff_proc.stdout[:200 * 1024]
    changed_files = [f for f in names_proc.stdout.splitlines() if f.strip()]
    return diff, changed_files


def _review(
    goal: str,
    diff: str,
    port: int,
    max_tokens: int,
    test_result: str | None = None,
) -> tuple[str, bool]:
    """Ask VT-3B for a semantic review of the diff. Returns (review_text, done)."""
    review_user = f"Goal: {goal}\n\nDiff:\n{diff[:8000]}"
    if test_result is not None:
        review_user += f"\n\nTest results:\n{test_result[:2000]}"
    review_text = _call_vt3b(
        _REVIEWER_SYSTEM,
        review_user,
        port=port,
        max_tokens=max_tokens,
    )
    review_lower = review_text.lower().strip()
    done = review_lower.startswith("done") and not review_lower.startswith("not done")
    return review_text, done


def _cleanup_worktree(
    repo_path: str,
    worktree_path: str,
    branch_name: str,
    tmp_parent: str,
) -> None:
    """Remove worktree, delete branch, prune, and remove the temp directory."""
    try:
        subprocess.run(
            ["git", "worktree", "remove", "--force", worktree_path],
            cwd=repo_path,
            capture_output=True,
        )
    except Exception:
        pass
    try:
        subprocess.run(
            ["git", "-C", repo_path, "branch", "-D", branch_name],
            capture_output=True,
        )
    except Exception:
        pass
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


# ---------------------------------------------------------------------------
# Director round (single pass, VT-3B-directed — legacy path)
# ---------------------------------------------------------------------------


def run_director_round(
    goal: str,
    repo_path: str,
    *,
    director_port: int = 8082,
    claude_timeout: float = 600.0,
    max_director_tokens: int = 2000,
    max_review_tokens: int = 4000,
    test_command: str = "",
    venv_python: str = "",
    test_timeout: int = 300,
    _branch_id: str | None = None,
) -> DirectorResult:
    """One director round: VT-3B instructs → Claude Code codes → VT-3B reviews → return result (never commit)."""

    branch_id = _branch_id or uuid4().hex[:8]
    branch_name = f"axi-dev/{branch_id}"

    _defaults: dict = dict(
        goal=goal,
        instruction="",
        branch=branch_name,
        diff="",
        changed_files=[],
        claude_summary="",
        claude_cost_usd=0.0,
        claude_num_turns=0,
        review_done=False,
        review_feedback="",
    )

    if shutil.which("claude") is None:
        return DirectorResult(
            **_defaults,
            ok=False,
            error="claude CLI not found on PATH",
        )

    tmp_parent = tempfile.mkdtemp(prefix="axi-dir-wt-")
    worktree_path = os.path.join(tmp_parent, f"axi-dev-{branch_id}")

    try:
        instruction = _call_vt3b(
            _DIRECTOR_SYSTEM,
            f"Goal: {goal}",
            port=director_port,
            max_tokens=max_director_tokens,
        )
        _defaults["instruction"] = instruction

        ok, err = _create_worktree(repo_path, worktree_path, branch_name)
        if not ok:
            return DirectorResult(**_defaults, ok=False, error=err)

        env = os.environ.copy()
        summary, cost, turns, is_error, _session_id = _run_claude(
            worktree_path, instruction, claude_timeout, env
        )

        if is_error:
            return DirectorResult(
                **{**_defaults, "instruction": instruction},
                claude_summary=summary,
                claude_cost_usd=cost,
                claude_num_turns=turns,
                ok=False,
                error="claude reported is_error=true",
            )

        diff, changed_files = _stage_and_diff(worktree_path)
        review_text, review_done = _review(goal, diff, director_port, max_review_tokens)

        return DirectorResult(
            goal=goal,
            instruction=instruction,
            branch=branch_name,
            diff=diff,
            changed_files=changed_files,
            claude_summary=summary,
            claude_cost_usd=cost,
            claude_num_turns=turns,
            review_done=review_done,
            review_feedback=review_text,
            ok=True,
        )

    except Exception as exc:  # noqa: BLE001
        log.exception("dev_director round failed: %s", exc)
        return DirectorResult(
            **_defaults,
            ok=False,
            error=str(exc),
        )

    finally:
        _cleanup_worktree(repo_path, worktree_path, branch_name, tmp_parent)


# ---------------------------------------------------------------------------
# Director loop (multi-round, /goal inner loop + test gate)
# ---------------------------------------------------------------------------


def run_director_loop(
    goal: str,
    repo_path: str,
    *,
    max_rounds: int = 4,
    director_port: int = 8082,
    claude_timeout: float = 600.0,
    max_review_tokens: int = 4000,
    test_command: str = "tests/ -q",
    venv_python: str = "~/LifeOS/lifeos/axi/.venv/bin/python",
    test_timeout: int = 300,
    branch_prefix: str = "axi/self-build",
    resume_session_id: str | None = None,
    keep_worktree: bool = False,
    worktree_parent: str | None = None,
    _branch_id: str | None = None,
) -> DirectorLoopResult:
    """
    Multi-round loop: Claude self-iterates via /goal, tests run in the worktree,
    VT-3B does a semantic review. Stops when tests pass AND VT-3B approves.
    Escalates to needs_human=True if max_rounds is exhausted without success.
    Nothing is ever committed or pushed.

    Worktree lifecycle:
      - Patch mode (default): the worktree is created in a throwaway tempdir and
        deleted in the finally block; only the diff survives (DirectorLoopResult
        .final_diff). This is the ephemeral self-build path.
      - Persistent-environment mode (keep_worktree=True): the worktree is created
        under *worktree_parent* (a durable location the caller owns) and is NOT
        deleted — the caller can launch, test, iterate on, and eventually deploy
        it. DirectorLoopResult.worktree_path points at it. Re-entrant: a resume
        reuses the existing worktree (see _create_worktree). The invariant holds
        either way — this engine still never commits, pushes, or merges.
    """
    max_rounds = max(_MIN_ROUNDS_FLOOR, min(max_rounds, _MAX_ROUNDS_CEILING))

    branch_id = _branch_id or uuid4().hex[:8]
    branch_name = f"{branch_prefix.rstrip('/')}/{branch_id}"

    rounds: list[DirectorRoundInfo] = []
    total_cost = 0.0
    total_turns = 0
    tests_passed_ever = False
    last_tests_passed = False
    last_test_output = ""
    last_feedback: str | None = None
    latest_session_id: str | None = None

    def _early_exit(
        *,
        done: bool,
        ok: bool,
        error: str | None = None,
        tests_passed: bool = False,
        needs_human: bool = False,
        escalation_reason: str = "",
    ) -> DirectorLoopResult:
        final_diff = rounds[-1].diff if rounds else ""
        final_files = rounds[-1].changed_files if rounds else []
        return DirectorLoopResult(
            goal=goal,
            branch=branch_name,
            rounds=rounds,
            final_diff=final_diff,
            final_changed_files=final_files,
            done=done,
            rounds_used=len(rounds),
            total_cost_usd=total_cost,
            total_claude_turns=total_turns,
            ok=ok,
            error=error,
            tests_passed=tests_passed,
            needs_human=needs_human,
            escalation_reason=escalation_reason,
            session_id=latest_session_id,
            worktree_path=worktree_path if keep_worktree else "",
        )

    if shutil.which("claude") is None:
        return DirectorLoopResult(
            goal=goal,
            branch=branch_name,
            rounds=[],
            final_diff="",
            final_changed_files=[],
            done=False,
            rounds_used=0,
            total_cost_usd=0.0,
            total_claude_turns=0,
            ok=False,
            error="claude CLI not found on PATH",
        )

    # Persistent-environment mode puts the worktree in a durable, caller-owned
    # directory (so it survives across the test/iterate/deploy lifecycle and
    # daemon restarts). Patch mode uses a throwaway tempdir.
    if worktree_parent:
        tmp_parent = os.path.expanduser(worktree_parent)
        os.makedirs(tmp_parent, exist_ok=True)
    else:
        tmp_parent = tempfile.mkdtemp(prefix="axi-dir-loop-")
    worktree_path = os.path.join(tmp_parent, f"axi-dev-{branch_id}")

    try:
        ok, err = _create_worktree(repo_path, worktree_path, branch_name)
        if not ok:
            return DirectorLoopResult(
                goal=goal,
                branch=branch_name,
                rounds=[],
                final_diff="",
                final_changed_files=[],
                done=False,
                rounds_used=0,
                total_cost_usd=0.0,
                total_claude_turns=0,
                ok=False,
                error=err,
            )

        env = os.environ.copy()

        for round_idx in range(max_rounds):
            goal_instruction = _compose_goal_instruction(goal, test_command, last_feedback)

            round_resume = resume_session_id if round_idx == 0 else None
            summary, cost, turns, is_error, round_session_id = _run_claude(
                worktree_path, goal_instruction, claude_timeout, env,
                resume_session_id=round_resume,
            )
            if round_session_id:
                latest_session_id = round_session_id
            total_cost += cost
            total_turns += turns

            if is_error:
                rounds.append(DirectorRoundInfo(
                    round_index=round_idx,
                    instruction=goal_instruction,
                    diff="",
                    changed_files=[],
                    claude_summary=summary,
                    claude_cost_usd=cost,
                    claude_num_turns=turns,
                    review_done=False,
                    review_feedback="",
                ))
                return _early_exit(done=False, ok=False, error="claude reported is_error=true")

            diff, changed_files = _stage_and_diff(worktree_path)

            last_tests_passed, last_test_output = _run_tests(
                worktree_path, env, test_command, venv_python, test_timeout
            )
            if last_tests_passed:
                tests_passed_ever = True

            review_text, review_done = _review(
                goal, diff, director_port, max_review_tokens, test_result=last_test_output
            )
            last_feedback = review_text

            rounds.append(DirectorRoundInfo(
                round_index=round_idx,
                instruction=goal_instruction,
                diff=diff,
                changed_files=changed_files,
                claude_summary=summary,
                claude_cost_usd=cost,
                claude_num_turns=turns,
                review_done=review_done,
                review_feedback=review_text,
            ))

            if last_tests_passed and review_done:
                return _early_exit(done=True, ok=True, tests_passed=True)

        # Exhausted max_rounds — escalate with diagnosis
        if not tests_passed_ever:
            tail = last_test_output[-500:] if last_test_output else "(no output)"
            escalation_reason = (
                f"Tests did not pass after {max_rounds} rounds. "
                f"Last test output: {tail}"
            )
        else:
            escalation_reason = (
                f"Tests passed but VT-3B reviewer did not approve after {max_rounds} rounds. "
                f"Likely VT-3B too strict or diff is semantically incomplete per reviewer. "
                f"Last feedback: {last_feedback}"
            )

        return _early_exit(
            done=False,
            ok=True,
            tests_passed=last_tests_passed,
            needs_human=True,
            escalation_reason=escalation_reason,
        )

    except Exception as exc:  # noqa: BLE001
        log.exception("dev_director loop failed: %s", exc)
        return _early_exit(done=False, ok=False, error=str(exc))

    finally:
        # Persistent-environment mode keeps the worktree for the user to test,
        # iterate on, and deploy. Patch mode deletes it (only the diff matters).
        if not keep_worktree:
            _cleanup_worktree(repo_path, worktree_path, branch_name, tmp_parent)
