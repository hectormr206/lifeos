"""Tests for _ensure_nocow_dir — btrfs NoCoW startup safeguard.

These tests run in Strict TDD order:
  RED  → helper does not exist yet; each test MUST fail on import or attribute error.
  GREEN → helper added, tests pass.
  REFACTOR → cleanup only; tests remain green.

The fixture fresh_db (autouse) redirects STATE_DIR / DB_PATH to tmp_path, so
these tests never touch the production DB.
"""
from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import call, patch

import pytest

from axi import store


# ──────────────────────────────────────────────────────────────────────────────
# Task 1: _ensure_nocow_dir calls `chattr +C <dir>` via subprocess
# ──────────────────────────────────────────────────────────────────────────────

def test_ensure_nocow_dir_calls_chattr_on_existing_dir(tmp_path):
    """RED: _ensure_nocow_dir must invoke `chattr +C <dir>` when the dir exists.

    Discriminates: the helper must exist AND call chattr with the correct args.
    Fails now because `_ensure_nocow_dir` is not defined in store.py yet.
    """
    target = tmp_path / "state"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = subprocess.CompletedProcess([], 0)
        store._ensure_nocow_dir(target)

    # Must have been called at least once with chattr +C <dir>
    calls_with_chattr = [
        c for c in mock_run.call_args_list
        if c.args and len(c.args[0]) >= 3
        and c.args[0][0] == "chattr"
        and "+C" in c.args[0]
        and str(target) in [str(a) for a in c.args[0]]
    ]
    assert calls_with_chattr, (
        f"Expected subprocess.run to be called with ['chattr', '+C', '{target}'] "
        f"but got: {mock_run.call_args_list}"
    )


def test_ensure_nocow_dir_does_not_call_chattr_when_dir_missing(tmp_path):
    """RED: _ensure_nocow_dir must NOT call chattr when the directory does not exist.

    Discriminates: the helper must guard on directory existence, not blindly call chattr.
    """
    target = tmp_path / "nonexistent_state"
    # directory NOT created — must not call chattr

    with patch("subprocess.run") as mock_run:
        store._ensure_nocow_dir(target)

    chattr_calls = [
        c for c in mock_run.call_args_list
        if c.args and c.args[0] and c.args[0][0] == "chattr"
    ]
    assert not chattr_calls, (
        f"_ensure_nocow_dir should not call chattr on a non-existent dir, "
        f"but got: {mock_run.call_args_list}"
    )


# ──────────────────────────────────────────────────────────────────────────────
# Task 2: swallows ALL failures — startup must survive on non-btrfs / no chattr
# ──────────────────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("exc", [
    FileNotFoundError("chattr not found"),
    subprocess.CalledProcessError(1, ["chattr", "+C", "/tmp/x"]),
    OSError("Operation not supported"),
    PermissionError("Permission denied"),
])
def test_ensure_nocow_dir_swallows_subprocess_failure(tmp_path, exc):
    """RED: _ensure_nocow_dir must NOT raise when subprocess raises any error.

    Discriminates: a hard raise from chattr (non-btrfs, missing binary, permission)
    must be swallowed silently. Startup on ext4/xfs/tmpfs/CI must never fail.
    """
    target = tmp_path / "state"
    target.mkdir()

    with patch("subprocess.run", side_effect=exc):
        # Must not raise — any exception here is a test failure
        try:
            store._ensure_nocow_dir(target)
        except Exception as raised:
            pytest.fail(
                f"_ensure_nocow_dir raised {type(raised).__name__}({raised!r}) "
                f"on subprocess failure — startup must survive on non-btrfs."
            )


# ──────────────────────────────────────────────────────────────────────────────
# Task 3: _ensure_nocow_dir is called during _connect / init path after mkdir
# ──────────────────────────────────────────────────────────────────────────────

def test_ensure_nocow_dir_called_during_connect(tmp_path, monkeypatch):
    """RED: opening the store (via init_db/_connect path) must call _ensure_nocow_dir.

    Discriminates: hooking the init path proves the safeguard fires at startup,
    not just when called manually.

    fresh_db (autouse) has already called store.init_db() with the temp STATE_DIR.
    We close, reset, and re-drive the connect path here with a patched helper.
    """
    import threading

    # Point to a fresh subdir so _connect triggers STATE_DIR.mkdir + our hook
    new_state = tmp_path / "state_connect_test"
    monkeypatch.setattr(store, "STATE_DIR", new_state)
    monkeypatch.setattr(store, "DB_PATH", new_state / "memory.db")

    # Reset thread-local connection so _connect() runs fresh
    if hasattr(store._tl, "conn"):
        del store._tl.conn

    calls: list[Path] = []

    def _capture(path: Path) -> None:
        calls.append(path)

    with patch.object(store, "_ensure_nocow_dir", side_effect=_capture) as mock_helper:
        # init_db drives the connect path which calls STATE_DIR.mkdir + _ensure_nocow_dir
        store.init_db()

    assert mock_helper.called, (
        "_ensure_nocow_dir was never called during store init. "
        "It must be invoked right after STATE_DIR.mkdir in the _connect path."
    )
    # The path passed must be STATE_DIR (the directory, not the DB file)
    assert any(p == new_state for p in calls), (
        f"_ensure_nocow_dir was called but not with STATE_DIR ({new_state}). "
        f"Got: {calls}"
    )
