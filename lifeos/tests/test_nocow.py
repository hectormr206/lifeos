"""Tests for ensure_nocow_dir — btrfs NoCoW startup safeguard in lifeos.

Strict TDD order:
  RED  → helper does not exist yet; each test MUST fail on import or AttributeError.
  GREEN → helper added and all stores hooked; tests pass.
  REFACTOR → cleanup only; tests remain green.

Task coverage:
  1. ensure_nocow_dir calls `chattr +C <dir>` via subprocess when dir exists.
  2. Swallows all failures (non-btrfs / missing chattr / PermissionError / etc.).
  3. Guard when dir missing — no chattr call, no raise.
  4. Each store's connect() calls ensure_nocow_dir (parametrized over all 9 stores).
"""
from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

# ── Task 1 & 2 & 3: helper in lifeos._common.nocow ──────────────────────────
from lifeos._common import nocow  # noqa: E402  — RED: module does not exist yet


# ──────────────────────────────────────────────────────────────────────────────
# Task 1: ensure_nocow_dir calls `chattr +C <dir>` via subprocess
# ──────────────────────────────────────────────────────────────────────────────

def test_ensure_nocow_dir_calls_chattr_on_existing_dir(tmp_path):
    """RED: ensure_nocow_dir must invoke `chattr +C <dir>` when the dir exists.

    Discriminator: helper must exist AND call subprocess with chattr +C + correct path.
    Fails now because lifeos._common.nocow does not exist.
    """
    target = tmp_path / "state"
    target.mkdir()

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = subprocess.CompletedProcess([], 0)
        nocow.ensure_nocow_dir(target)

    calls_with_chattr = [
        c for c in mock_run.call_args_list
        if c.args
        and len(c.args[0]) >= 3
        and c.args[0][0] == "chattr"
        and "+C" in c.args[0]
        and str(target) in [str(a) for a in c.args[0]]
    ]
    assert calls_with_chattr, (
        f"Expected subprocess.run to be called with ['chattr', '+C', '{target}'] "
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
    """RED: ensure_nocow_dir must NOT raise when subprocess raises any error.

    Discriminator: startup on ext4/xfs/tmpfs/CI must never fail — all exceptions
    from chattr must be swallowed and logged at DEBUG only.
    """
    target = tmp_path / "state"
    target.mkdir()

    with patch("subprocess.run", side_effect=exc):
        try:
            nocow.ensure_nocow_dir(target)
        except Exception as raised:
            pytest.fail(
                f"ensure_nocow_dir raised {type(raised).__name__}({raised!r}) "
                f"on subprocess failure — startup must survive on non-btrfs."
            )


# ──────────────────────────────────────────────────────────────────────────────
# Task 3: guard when dir missing — no call, no raise
# ──────────────────────────────────────────────────────────────────────────────

def test_ensure_nocow_dir_does_not_call_chattr_when_dir_missing(tmp_path):
    """RED: ensure_nocow_dir must NOT call chattr when the directory does not exist.

    Discriminator: the helper must guard on path.exists(), not blindly call chattr.
    """
    target = tmp_path / "nonexistent_state"
    # directory NOT created on purpose

    with patch("subprocess.run") as mock_run:
        nocow.ensure_nocow_dir(target)

    chattr_calls = [
        c for c in mock_run.call_args_list
        if c.args and c.args[0] and c.args[0][0] == "chattr"
    ]
    assert not chattr_calls, (
        f"ensure_nocow_dir should not call chattr on a non-existent dir, "
        f"but got: {mock_run.call_args_list}"
    )


def test_ensure_nocow_dir_does_not_raise_when_dir_missing(tmp_path):
    """RED: ensure_nocow_dir must not raise when dir does not exist (safe no-op)."""
    target = tmp_path / "nonexistent_state"

    try:
        nocow.ensure_nocow_dir(target)
    except Exception as raised:
        pytest.fail(
            f"ensure_nocow_dir raised {type(raised).__name__}({raised!r}) "
            f"when directory does not exist — must be a silent no-op."
        )


# ──────────────────────────────────────────────────────────────────────────────
# Task 4: each store's connect() calls ensure_nocow_dir
# Parametrized across all 9 stores — a missed store means its DB is unprotected.
# ──────────────────────────────────────────────────────────────────────────────

# (module_path, db_env_var, key_env_var)
# The helper is imported from lifeos._common.nocow — each store calls it after mkdir.
STORE_SPECS = [
    ("lifeos.store", "LIFEOS_DB_PATH", "LIFEOS_KEY_PATH"),
    ("lifeos.health.store", "LIFEOS_HEALTH_DB_PATH", "LIFEOS_HEALTH_KEY_PATH"),
    ("lifeos.finance.store", "LIFEOS_FINANCE_DB_PATH", "LIFEOS_FINANCE_KEY_PATH"),
    ("lifeos.exercise.store", "LIFEOS_EXERCISE_DB_PATH", "LIFEOS_EXERCISE_KEY_PATH"),
    ("lifeos.spirituality.store", "LIFEOS_SPIRIT_DB_PATH", "LIFEOS_SPIRIT_KEY_PATH"),
    ("lifeos.learning.store", "LIFEOS_LEARNING_DB_PATH", "LIFEOS_LEARNING_KEY_PATH"),
    ("lifeos.events.store", "LIFEOS_EVENTS_DB_PATH", "LIFEOS_EVENTS_KEY_PATH"),
    ("lifeos.posture.store", "LIFEOS_POSTURE_DB_PATH", "LIFEOS_POSTURE_KEY_PATH"),
    ("lifeos.relationships.store", "LIFEOS_REL_DB_PATH", "LIFEOS_REL_KEY_PATH"),
]


@pytest.mark.parametrize("module_path,db_env,key_env", STORE_SPECS,
                         ids=[s[0].split(".")[-2] if "." in s[0] else "main" for s in STORE_SPECS])
def test_store_connect_calls_ensure_nocow_dir(tmp_path, monkeypatch, module_path, db_env, key_env):
    """RED: every store's connect() must call ensure_nocow_dir after mkdir.

    Discriminator: proves the safeguard fires at the real connect() entrypoint for
    ALL 9 domain stores, not just the shared helper.

    Each store uses its own DB/KEY env vars so we redirect to tmp_path without
    touching the production directory.
    """
    import importlib

    state_dir = tmp_path / "state"
    state_dir.mkdir()

    db_file = state_dir / "test.db"
    key_file = state_dir / "test.key"

    monkeypatch.setenv(db_env, str(db_file))
    monkeypatch.setenv(key_env, str(key_file))
    # Also set LIFEOS_STATE_DIR so _default_dir() points to tmp (for main store)
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(state_dir))

    mod = importlib.import_module(module_path)

    called_paths: list[Path] = []

    def _capture(path: Path) -> None:
        called_paths.append(path)

    # Each store does `from lifeos._common.nocow import ensure_nocow_dir`, so the
    # name `ensure_nocow_dir` lives in the store module's own namespace. Patch it
    # there so our spy fires even though the function was imported by-name.
    with patch(f"{module_path}.ensure_nocow_dir", side_effect=_capture):
        mod.connect().close()

    assert called_paths, (
        f"{module_path}.connect() never called ensure_nocow_dir. "
        f"Add `ensure_nocow_dir(p.parent)` right after `p.parent.mkdir(...)` in connect()."
    )
    # Must have been called with the state directory (p.parent), not the DB file itself
    assert any(str(p).endswith(state_dir.name) or p == state_dir for p in called_paths), (
        f"ensure_nocow_dir was called but not with the state dir ({state_dir}). "
        f"Got: {called_paths}"
    )
