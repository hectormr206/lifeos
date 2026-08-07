"""Tests for nodes embedding migration — Slice 1, tasks 1.10 (RED) / 1.11 (GREEN).

migrate_nodes_embedding() must add:
  - embedding BLOB
  - embedding_model TEXT
  - embedding_dim INTEGER

to the nodes table in a backward-compatible way. Existing rows must have
all three columns as NULL after the migration.
"""
from __future__ import annotations

import time

import pytest
import uuid as _uuid


def _get_column_names(conn) -> set[str]:
    """Return the set of column names in the nodes table."""
    rows = conn.execute("PRAGMA table_info(nodes)").fetchall()
    return {r[1] for r in rows}


def test_migration_adds_embedding_columns(tmp_path, monkeypatch):
    """Task 1.10 RED: migration adds embedding, embedding_model, embedding_dim."""
    import axi.store as store

    monkeypatch.setattr(store, "DB_PATH", tmp_path / "test.db")
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    store.close()  # clear thread-local so _connect() re-opens against new DB_PATH
    store.init_db()

    from axi.store import migrate_nodes_embedding

    migrate_nodes_embedding()

    conn = store._connect()
    cols = _get_column_names(conn)
    assert "embedding" in cols
    assert "embedding_model" in cols
    assert "embedding_dim" in cols


def test_migration_existing_rows_have_null_embedding(tmp_path, monkeypatch):
    """Task 1.10 RED: existing rows have all 3 new columns as NULL after migration."""
    import axi.store as store

    monkeypatch.setattr(store, "DB_PATH", tmp_path / "test.db")
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    store.close()  # clear thread-local so _connect() re-opens against new DB_PATH
    store.init_db()

    # Insert a node BEFORE migration (simulates an existing DB).
    conn = store._connect()
    now = time.time()
    conn.execute(
        "INSERT INTO nodes(uuid, kind, label, data, domain, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (str(_uuid.uuid4()), "fact", "existing node", "{}", "test", now, now),
    )
    conn.commit()

    from axi.store import migrate_nodes_embedding

    migrate_nodes_embedding()

    row = conn.execute(
        "SELECT embedding, embedding_model, embedding_dim FROM nodes LIMIT 1"
    ).fetchone()
    assert row[0] is None  # embedding
    assert row[1] is None  # embedding_model
    assert row[2] is None  # embedding_dim


def test_migration_is_idempotent(tmp_path, monkeypatch):
    """Task 1.10 RED: calling migrate_nodes_embedding() twice is safe (no error)."""
    import axi.store as store

    monkeypatch.setattr(store, "DB_PATH", tmp_path / "test.db")
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    store.close()  # clear thread-local so _connect() re-opens against new DB_PATH
    store.init_db()

    from axi.store import migrate_nodes_embedding

    migrate_nodes_embedding()
    migrate_nodes_embedding()  # must not raise


def test_migration_called_by_init_db(tmp_path, monkeypatch):
    """Task 1.11 GREEN prerequisite: init_db() must call migration so columns exist."""
    import axi.store as store

    monkeypatch.setattr(store, "DB_PATH", tmp_path / "test.db")
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    store.close()  # clear thread-local so _connect() re-opens against new DB_PATH
    # init_db is called by the fresh_db fixture; call it explicitly here too.
    store.init_db()

    conn = store._connect()
    cols = _get_column_names(conn)
    # After init_db, the columns must exist (migration is wired in).
    assert "embedding" in cols
    assert "embedding_model" in cols
    assert "embedding_dim" in cols
