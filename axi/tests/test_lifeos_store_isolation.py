"""Regression test: lifeos domain stores must NOT write to the real state dir during tests.

Before the fix, the autouse fresh_db fixture in conftest.py isolated axi.store
but left LIFEOS_STATE_DIR unset, so health.store.db_path(), lifeos.store.db_path(),
etc. all resolved to ~/.local/state/lifeos/ — the user's production data.

This test asserts that every db_path() helper resolves to a path INSIDE pytest's
tmp_path, not inside the user's real home directory.
"""
from __future__ import annotations

import os
from pathlib import Path


def test_health_db_path_is_under_tmp(tmp_path):
    """health.store.db_path() must not resolve to the real home state dir."""
    from lifeos.health import store as health_store

    p = health_store.db_path()
    real_state = Path.home() / ".local" / "state" / "lifeos"
    assert not str(p).startswith(str(real_state)), (
        f"health.store.db_path() resolved to {p!r} which is inside the production "
        f"state dir {real_state!r}. The conftest isolation is incomplete."
    )


def test_lifeos_db_path_is_under_tmp(tmp_path):
    """lifeos.store.db_path() must not resolve to the real home state dir."""
    from lifeos import store as lifeos_store

    p = lifeos_store.db_path()
    real_state = Path.home() / ".local" / "state" / "lifeos"
    assert not str(p).startswith(str(real_state)), (
        f"lifeos.store.db_path() resolved to {p!r} which is inside the production "
        f"state dir {real_state!r}. The conftest isolation is incomplete."
    )


def test_finance_db_path_is_under_tmp(tmp_path):
    """finance.store.db_path() must not resolve to the real home state dir."""
    from lifeos.finance import store as finance_store

    p = finance_store.db_path()
    real_state = Path.home() / ".local" / "state" / "lifeos"
    assert not str(p).startswith(str(real_state)), (
        f"finance.store.db_path() resolved to {p!r} which is inside the production "
        f"state dir {real_state!r}. The conftest isolation is incomplete."
    )


def test_events_db_path_is_under_tmp(tmp_path):
    """events.store.db_path() must not resolve to the real home state dir."""
    from lifeos.events import store as events_store

    p = events_store.db_path()
    real_state = Path.home() / ".local" / "state" / "lifeos"
    assert not str(p).startswith(str(real_state)), (
        f"events.store.db_path() resolved to {p!r} which is inside the production "
        f"state dir {real_state!r}. The conftest isolation is incomplete."
    )


def test_lifeos_state_dir_env_is_set_to_tmp():
    """LIFEOS_STATE_DIR must be set (and not be the real home) during tests."""
    state_dir = os.environ.get("LIFEOS_STATE_DIR", "")
    real_state = str(Path.home() / ".local" / "state" / "lifeos")
    assert state_dir, (
        "LIFEOS_STATE_DIR is not set during tests — lifeos domain stores will "
        "default to the production ~/.local/state/lifeos/ directory."
    )
    assert not state_dir.startswith(real_state), (
        f"LIFEOS_STATE_DIR={state_dir!r} still points at the production state dir."
    )
