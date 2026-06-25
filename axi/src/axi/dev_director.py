"""
Axi dev-director — VT-3B directs Claude Code, reviews the result.

run_director_round() orchestrates a single director round:
  1. VT-3B produces a specific coding instruction for the given goal.
  2. Claude Code executes the instruction in an isolated git worktree.
  3. VT-3B reviews the resulting diff and decides DONE / NOT DONE.
  4. The worktree is cleaned up unconditionally; nothing is committed or pushed.

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


# ---------------------------------------------------------------------------
# Result dataclass
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
# Director round
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
        wt_result = subprocess.run(
            ["git", "worktree", "add", worktree_path, "-b", branch_name],
            cwd=repo_path,
            capture_output=True,
            text=True,
        )
        if wt_result.returncode != 0:
            return DirectorResult(
                **_defaults,
                ok=False,
                error=f"git worktree add failed: {wt_result.stderr.strip()}",
            )

        # Step 3: Run Claude Code with the instruction.
        env = os.environ.copy()
        proc = subprocess.run(
            [
                "claude",
                "-p", instruction,
                "--output-format", "json",
                "--permission-mode", "bypassPermissions",
            ],
            cwd=worktree_path,
            timeout=claude_timeout,
            capture_output=True,
            text=True,
            env=env,
        )

        # Parse Claude's JSON output (best-effort).
        claude_summary = ""
        claude_cost_usd = 0.0
        claude_num_turns = 0
        claude_is_error = False
        try:
            out = json.loads(proc.stdout)
            claude_summary = out.get("result", "")
            claude_cost_usd = float(out.get("total_cost_usd", 0.0))
            claude_num_turns = int(out.get("num_turns", 0))
            claude_is_error = bool(out.get("is_error", False))
        except (json.JSONDecodeError, ValueError, TypeError):
            claude_is_error = proc.returncode != 0

        if claude_is_error:
            return DirectorResult(
                **{**_defaults, "instruction": instruction},
                claude_summary=claude_summary,
                claude_cost_usd=claude_cost_usd,
                claude_num_turns=claude_num_turns,
                ok=False,
                error="claude reported is_error=true",
            )

        # Step 4: Stage all changes and capture the diff.
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
        diff = diff_proc.stdout[: 200 * 1024]
        changed_files = [f for f in names_proc.stdout.splitlines() if f.strip()]

        # Step 5: VT-3B reviews the diff.
        review_user = f"Goal: {goal}\n\nDiff:\n{diff[:8000]}"
        review_text = _call_vt3b(
            _REVIEWER_SYSTEM,
            review_user,
            port=director_port,
            max_tokens=max_review_tokens,
        )

        # Parse review: "DONE" iff the lowercased text starts with "done" and
        # does NOT start with "not done".
        review_lower = review_text.lower().strip()
        review_done = review_lower.startswith("done") and not review_lower.startswith(
            "not done"
        )

        return DirectorResult(
            goal=goal,
            instruction=instruction,
            branch=branch_name,
            diff=diff,
            changed_files=changed_files,
            claude_summary=claude_summary,
            claude_cost_usd=claude_cost_usd,
            claude_num_turns=claude_num_turns,
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
