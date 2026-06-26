"""
Axi dev-director — VT-3B directs Claude Code, reviews the result.

run_director_round() orchestrates a single director round:
  1. VT-3B produces a specific coding instruction for the given goal.
  2. Claude Code executes the instruction in an isolated git worktree.
  3. VT-3B reviews the resulting diff and decides DONE / NOT DONE.
  4. The worktree is cleaned up unconditionally; nothing is committed or pushed.

run_director_loop() extends this to multiple rounds sharing ONE worktree so
changes accumulate. Corrective instructions are generated from reviewer feedback.
Nothing is ever committed or pushed.

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
import urllib.request
from dataclasses import dataclass, field
from uuid import uuid4

log = logging.getLogger("axi.dev_director")

# ---------------------------------------------------------------------------
# Regex patterns for stripping VT-3B reasoning artefacts
# ---------------------------------------------------------------------------

# <think>...</think> blocks — may be multiple, may span newlines.
_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL)

# Unclosed <think> — VibeThinker-3B sometimes runs out of tokens mid-thought,
# leaving a `<think>` with no closing tag. Strip from the tag to end of string
# so raw reasoning never leaks into the instruction/review.
_THINK_UNCLOSED_RE = re.compile(r"<think>.*", re.DOTALL)

# \boxed{...} — single-level brace match (does not handle nested braces, but
# that is sufficient for the structured outputs VT-3B emits).
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

# git pathspecs that exclude build/cache artifacts from the captured diff. When
# Claude Code runs in the worktree it generates noise (__pycache__, *.pyc, the
# gentle-ai .atl/ skill registry, pytest caches, etc.) that pollutes the diff and
# the review. The ":(exclude,glob)" magic makes "**" match nested paths. This only
# filters what the diff DISPLAYS — nothing is committed (the worktree is thrown away).
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


# ---------------------------------------------------------------------------
# VT-3B HTTP helper
# ---------------------------------------------------------------------------


def _call_vt3b(
    system: str,
    user: str,
    *,
    port: int = 8082,
    max_tokens: int = 2000,
) -> str:
    """POST to OpenAI-compat endpoint, strip <think>...</think> and \\boxed{...}, return content."""
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

    with urllib.request.urlopen(req) as resp:
        body = json.loads(resp.read().decode())

    content: str = body["choices"][0]["message"]["content"]

    # Strip <think>...</think> blocks (closed first, then any unclosed remainder).
    content = _THINK_RE.sub("", content)
    content = _THINK_UNCLOSED_RE.sub("", content)

    # Strip \boxed{...} wrappers, keeping the inner text.
    content = _BOXED_RE.sub(r"\1", content)

    return content.strip()


# ---------------------------------------------------------------------------
# Internal helpers (used by both run_director_round and run_director_loop)
# ---------------------------------------------------------------------------


def _create_worktree(repo_path: str, worktree_path: str, branch_name: str) -> tuple[bool, str]:
    """Create a git worktree on a new branch. Returns (ok, error_message)."""
    result = subprocess.run(
        ["git", "worktree", "add", worktree_path, "-b", branch_name],
        cwd=repo_path,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return False, f"git worktree add failed: {result.stderr.strip()}"
    return True, ""


def _run_claude(
    worktree_path: str,
    instruction: str,
    timeout: float,
    env: dict,
) -> tuple[str, float, int, bool]:
    """Run claude CLI with the given instruction. Returns (summary, cost_usd, num_turns, is_error)."""
    proc = subprocess.run(
        [
            "claude",
            "-p", instruction,
            "--output-format", "json",
            "--permission-mode", "bypassPermissions",
        ],
        cwd=worktree_path,
        timeout=timeout,
        capture_output=True,
        text=True,
        env=env,
    )
    summary = ""
    cost = 0.0
    turns = 0
    is_error = False
    try:
        out = json.loads(proc.stdout)
        summary = out.get("result", "")
        cost = float(out.get("total_cost_usd", 0.0))
        turns = int(out.get("num_turns", 0))
        is_error = bool(out.get("is_error", False))
    except (json.JSONDecodeError, ValueError, TypeError):
        is_error = proc.returncode != 0
    return summary, cost, turns, is_error


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


def _review(goal: str, diff: str, port: int, max_tokens: int) -> tuple[str, bool]:
    """Ask VT-3B to review the diff. Returns (review_text, done)."""
    review_user = f"Goal: {goal}\n\nDiff:\n{diff[:8000]}"
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
# Director round (single pass)
# ---------------------------------------------------------------------------


def run_director_round(
    goal: str,
    repo_path: str,
    *,
    director_port: int = 8082,
    claude_timeout: float = 600.0,
    max_director_tokens: int = 2000,
    max_review_tokens: int = 4000,
    _branch_id: str | None = None,
) -> DirectorResult:
    """One director round: VT-3B instructs → Claude Code codes → VT-3B reviews → return result (never commit)."""

    branch_id = _branch_id or uuid4().hex[:8]
    branch_name = f"axi-dev/{branch_id}"

    # Defaults for the result fields in case of early exit.
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

    # ── Guard: claude CLI must be available ──────────────────────────────────
    if shutil.which("claude") is None:
        return DirectorResult(
            **_defaults,
            ok=False,
            error="claude CLI not found on PATH",
        )

    tmp_parent = tempfile.mkdtemp(prefix="axi-dir-wt-")
    worktree_path = os.path.join(tmp_parent, f"axi-dev-{branch_id}")

    try:
        # Step 1: VT-3B produces a coding instruction.
        instruction = _call_vt3b(
            _DIRECTOR_SYSTEM,
            f"Goal: {goal}",
            port=director_port,
            max_tokens=max_director_tokens,
        )
        _defaults["instruction"] = instruction

        # Step 2: Create an isolated git worktree on a fresh branch.
        ok, err = _create_worktree(repo_path, worktree_path, branch_name)
        if not ok:
            return DirectorResult(**_defaults, ok=False, error=err)

        # Step 3: Run Claude Code with the instruction.
        env = os.environ.copy()
        summary, cost, turns, is_error = _run_claude(worktree_path, instruction, claude_timeout, env)

        if is_error:
            return DirectorResult(
                **{**_defaults, "instruction": instruction},
                claude_summary=summary,
                claude_cost_usd=cost,
                claude_num_turns=turns,
                ok=False,
                error="claude reported is_error=true",
            )

        # Step 4: Stage all changes and capture the diff.
        diff, changed_files = _stage_and_diff(worktree_path)

        # Step 5: VT-3B reviews the diff.
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
        # Always clean up the worktree and branch — never commit or push.
        _cleanup_worktree(repo_path, worktree_path, branch_name, tmp_parent)


# ---------------------------------------------------------------------------
# Director loop (multi-round, shared worktree)
# ---------------------------------------------------------------------------


def run_director_loop(
    goal: str,
    repo_path: str,
    *,
    max_rounds: int = 4,
    director_port: int = 8082,
    claude_timeout: float = 600.0,
    max_director_tokens: int = 2000,
    max_review_tokens: int = 4000,
    _branch_id: str | None = None,
) -> DirectorLoopResult:
    """
    Multi-round director loop sharing ONE worktree so changes accumulate.

    Round 1 uses a direct instruction from the goal. Subsequent rounds use
    corrective instructions generated from the reviewer's feedback on the
    accumulated diff. Nothing is ever committed or pushed; the worktree is
    deleted in the finally block regardless of outcome.
    """
    max_rounds = max(_MIN_ROUNDS_FLOOR, min(max_rounds, _MAX_ROUNDS_CEILING))

    branch_id = _branch_id or uuid4().hex[:8]
    branch_name = f"axi-dev/{branch_id}"

    rounds: list[DirectorRoundInfo] = []
    total_cost = 0.0
    total_turns = 0

    def _early_exit(*, done: bool, ok: bool, error: str | None = None) -> DirectorLoopResult:
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
        )

    # ── Guard: claude CLI must be available ──────────────────────────────────
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

    tmp_parent = tempfile.mkdtemp(prefix="axi-dir-loop-")
    worktree_path = os.path.join(tmp_parent, f"axi-dev-{branch_id}")

    try:
        # Create ONE shared worktree for all rounds.
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

        # Round 1 instruction comes directly from the goal.
        instruction = _call_vt3b(
            _DIRECTOR_SYSTEM,
            f"Goal: {goal}",
            port=director_port,
            max_tokens=max_director_tokens,
        )

        env = os.environ.copy()

        for round_idx in range(max_rounds):
            summary, cost, turns, is_error = _run_claude(
                worktree_path, instruction, claude_timeout, env
            )
            total_cost += cost
            total_turns += turns

            if is_error:
                rounds.append(DirectorRoundInfo(
                    round_index=round_idx,
                    instruction=instruction,
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
            review_text, review_done = _review(goal, diff, director_port, max_review_tokens)

            rounds.append(DirectorRoundInfo(
                round_index=round_idx,
                instruction=instruction,
                diff=diff,
                changed_files=changed_files,
                claude_summary=summary,
                claude_cost_usd=cost,
                claude_num_turns=turns,
                review_done=review_done,
                review_feedback=review_text,
            ))

            if review_done:
                return _early_exit(done=True, ok=True)

            # Generate a corrective instruction for the next round (if any remain).
            if round_idx + 1 < max_rounds:
                corrective_user = (
                    f"Goal: {goal}\n\n"
                    f"Accumulated diff so far:\n{diff[:8000]}\n\n"
                    f"Reviewer feedback: {review_text}"
                )
                instruction = _call_vt3b(
                    _CORRECTIVE_SYSTEM,
                    corrective_user,
                    port=director_port,
                    max_tokens=max_director_tokens,
                )

        return _early_exit(done=False, ok=True)

    except Exception as exc:  # noqa: BLE001
        log.exception("dev_director loop failed: %s", exc)
        return _early_exit(done=False, ok=False, error=str(exc))

    finally:
        # Always clean up — never commit or push.
        _cleanup_worktree(repo_path, worktree_path, branch_name, tmp_parent)
