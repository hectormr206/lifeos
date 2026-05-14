"""Shared test fixtures.

Every test gets a fresh temp SQLite DB so the production lifeos.db is
never touched. Done by monkeypatching `axi.store.DB_PATH` and resetting
the cached connection.
"""
from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def fresh_db(tmp_path, monkeypatch):
    """Point the store at a per-test temp DB and reset its global state."""
    from axi import store
    monkeypatch.setattr(store, "DB_PATH", tmp_path / "test.db")
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    # Force a new connection bound to the temp DB.
    monkeypatch.setattr(store, "_conn", None)
    store.init_db()
    yield
    store.close()
