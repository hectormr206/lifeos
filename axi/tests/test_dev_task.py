"""Tests for axi.dev_task.run_dev_task.

All external calls (run_director_loop, git, speak, notify) are mocked.
tmp_path is used for workspace and results dirs — never ~/LifeOS.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from axi import dev_task


# ── helpers ──────────────────────────────────────────────────────────────────

@dataclass
class FakeDirectorLoopResult:
    goal: str = "test goal"
    branch: str = "axi-dev-abc"
    rounds: list = field(default_factory=list)
    final_diff: str = "diff --git a/foo.py b/foo.py\n+def foo(): pass\n"
    final_changed_files: list = field(default_factory=lambda: ["foo.py"])
    done: bool = True
    rounds_used: int = 2
    total_cost_usd: float = 0.0042
    total_claude_turns: int = 5
    ok: bool = True
    error: str | None = None
    tests_passed: bool = True
    needs_human: bool = False
    escalation_reason: str = ""


def _make_fake_loop(result: FakeDirectorLoopResult):
    def _fake(goal, repo_path, *, max_rounds=3, **_kw):
        return result
    return _fake


def _fake_config(workspace: Path, results: Path, max_rounds: int = 3):
    def _get(key, default=None):
        if key == "dev_director_repo":
            return str(workspace)
        if key == "dev_director_results_dir":
            return str(results)
        if key == "dev_director_max_rounds":
            return max_rounds
        return default
    return _get


# ── test: successful run writes patch file ───────────────────────────────────

def test_run_dev_task_writes_patch_and_returns_summary(tmp_path):
    workspace = tmp_path / "ws"
    results = tmp_path / "results"
    fake_result = FakeDirectorLoopResult()

    with patch("axi.config.get", side_effect=_fake_config(workspace, results)), \
         patch("axi.dev_director.run_director_loop", side_effect=_make_fake_loop(fake_result)), \
         patch("axi.dev_task._ensure_git_repo"):
        summary = dev_task.run_dev_task("test goal")

    assert results.exists()
    patches = list(results.glob("*.patch"))
    assert len(patches) == 1, f"expected 1 .patch file, got {patches}"
    patch_content = patches[0].read_text()
    assert "def foo()" in patch_content

    assert "DONE" in summary
    assert "2" in summary          # rounds_used
    assert str(patches[0]) in summary
    assert "foo.py" in summary


def test_run_dev_task_creates_results_dir(tmp_path):
    workspace = tmp_path / "ws"
    results = tmp_path / "new-results-dir"
    assert not results.exists()

    with patch("axi.config.get", side_effect=_fake_config(workspace, results)), \
         patch("axi.dev_director.run_director_loop",
               side_effect=_make_fake_loop(FakeDirectorLoopResult())), \
         patch("axi.dev_task._ensure_git_repo"):
        dev_task.run_dev_task("test goal")

    assert results.exists()


# ── test: ok=False returns error summary ─────────────────────────────────────

def test_run_dev_task_handles_ok_false(tmp_path):
    workspace = tmp_path / "ws"
    results = tmp_path / "results"
    fake_result = FakeDirectorLoopResult(ok=False, error="VT-3B not available", done=False)

    with patch("axi.config.get", side_effect=_fake_config(workspace, results)), \
         patch("axi.dev_director.run_director_loop", side_effect=_make_fake_loop(fake_result)), \
         patch("axi.dev_task._ensure_git_repo"):
        summary = dev_task.run_dev_task("failing goal")

    assert "Error" in summary
    assert "VT-3B not available" in summary


# ── test: empty final_diff still writes file (notes it) ──────────────────────

def test_run_dev_task_empty_diff(tmp_path):
    workspace = tmp_path / "ws"
    results = tmp_path / "results"
    fake_result = FakeDirectorLoopResult(final_diff="", final_changed_files=[])

    with patch("axi.config.get", side_effect=_fake_config(workspace, results)), \
         patch("axi.dev_director.run_director_loop", side_effect=_make_fake_loop(fake_result)), \
         patch("axi.dev_task._ensure_git_repo"):
        summary = dev_task.run_dev_task("empty goal")

    patches = list(results.glob("*.patch"))
    assert len(patches) == 1
    assert patches[0].read_text() == ""


# ── test: never raises on unexpected exception ────────────────────────────────

def test_run_dev_task_never_raises(tmp_path):
    workspace = tmp_path / "ws"
    results = tmp_path / "results"

    def _boom(*_a, **_kw):
        raise RuntimeError("unexpected internal error")

    with patch("axi.config.get", side_effect=_fake_config(workspace, results)), \
         patch("axi.dev_director.run_director_loop", side_effect=_boom), \
         patch("axi.dev_task._ensure_git_repo"):
        summary = dev_task.run_dev_task("any goal")

    assert "Error" in summary
    assert "unexpected internal error" in summary


# ── test: MAX RONDAS when done=False ─────────────────────────────────────────

def test_run_dev_task_max_rounds_not_done(tmp_path):
    workspace = tmp_path / "ws"
    results = tmp_path / "results"
    fake_result = FakeDirectorLoopResult(done=False, rounds_used=3)

    with patch("axi.config.get", side_effect=_fake_config(workspace, results)), \
         patch("axi.dev_director.run_director_loop", side_effect=_make_fake_loop(fake_result)), \
         patch("axi.dev_task._ensure_git_repo"):
        summary = dev_task.run_dev_task("test goal")

    assert "MAX RONDAS" in summary


# ── test: slug is filesystem-safe ────────────────────────────────────────────

def test_make_slug_safe():
    slug = dev_task._make_slug("función que suma/resta números!")  # noqa: SLF001
    assert "/" not in slug
    assert "!" not in slug
    assert len(slug) <= 40


def test_make_slug_truncates():
    long_goal = "a" * 100
    slug = dev_task._make_slug(long_goal)  # noqa: SLF001
    assert len(slug) <= 40


# ── test: ensure_git_repo creates repo with initial commit ───────────────────

def test_ensure_git_repo_creates_if_missing(tmp_path):
    repo = tmp_path / "new-repo"
    assert not repo.exists()
    dev_task._ensure_git_repo(repo)  # noqa: SLF001
    assert (repo / ".git").exists()
    assert (repo / "README.md").exists()
    # Verify at least one commit exists
    import subprocess
    result = subprocess.run(
        ["git", "-C", str(repo), "log", "--oneline"],
        capture_output=True, text=True,
    )
    assert result.returncode == 0
    assert result.stdout.strip(), "expected at least one commit"


def test_ensure_git_repo_idempotent(tmp_path):
    repo = tmp_path / "existing-repo"
    dev_task._ensure_git_repo(repo)  # noqa: SLF001
    # calling again must not raise
    dev_task._ensure_git_repo(repo)  # noqa: SLF001
    assert (repo / ".git").exists()
