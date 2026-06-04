"""Tests for at-rest encryption of the Axi memory store and the one-time
plaintext -> SQLCipher migration.

These drive T1 (encrypted assistant memory). They are written RED-first:
the migration module and the key helpers do not exist yet.
"""
from __future__ import annotations

import sqlite3

import pytest

from axi import store


def _make_plain_db(path, *, nodes=(), conversations=()):
    """Create a plain (unencrypted) SQLite DB with the real Axi schema and
    optional sample rows, using sqlite3 directly (bypassing the encrypted
    connect path). Returns nothing; the file is left closed on disk."""
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), isolation_level=None)
    conn.executescript(store._SCHEMA)
    conn.execute("INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', '1')")
    now = 1_700_000_000.0
    for kind, label in nodes:
        cur = conn.execute(
            "INSERT INTO nodes(kind, label, data, domain, created_at, updated_at, created_tz) "
            "VALUES (?,?,?,?,?,?,?)",
            (kind, label, "{}", "setup", now, now, "UTC"),
        )
        # Mirror text into FTS the same way store.add_node does.
        conn.execute(
            "INSERT INTO nodes_fts(rowid, label, data_text) VALUES (?, ?, ?)",
            (cur.lastrowid, label, ""),
        )
    for i, (user_text, axi_text) in enumerate(conversations):
        conn.execute(
            "INSERT INTO conversations(ts, user_text, axi_text, session_id, has_screenshot) "
            "VALUES (?, ?, ?, NULL, 0)",
            (now + i, user_text, axi_text),
        )
    # Flush WAL into the main file so the migration sees committed data.
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()


def _opens_as_plain_sqlite(path) -> bool:
    """True if the file can be read as an unencrypted SQLite DB."""
    try:
        conn = sqlite3.connect(str(path))
        conn.execute("SELECT count(*) FROM nodes").fetchone()
        conn.close()
        return True
    except sqlite3.DatabaseError:
        return False


# ───────────────────────────── key handling ─────────────────────────────

def test_load_key_generates_and_persists(tmp_path, monkeypatch):
    store.close()
    state = tmp_path / "fresh"  # autouse fixture seeds a key in tmp_path root
    monkeypatch.setattr(store, "STATE_DIR", state)
    monkeypatch.setattr(store, "DB_PATH", state / "memory.db")
    kp = store.key_path()
    assert not kp.exists()
    key1 = store.load_key()
    assert kp.exists()
    assert len(key1) == 64  # 32 bytes, hex-encoded
    # Stable across calls.
    assert store.load_key() == key1


def test_key_file_is_owner_only(tmp_path, monkeypatch):
    store.close()
    state = tmp_path / "fresh"
    monkeypatch.setattr(store, "STATE_DIR", state)
    monkeypatch.setattr(store, "DB_PATH", state / "memory.db")
    store.load_key()
    mode = store.key_path().stat().st_mode & 0o777
    assert mode == 0o600


# ─────────────────────── encryption on disk ───────────────────────

def test_fresh_db_is_encrypted_on_disk(tmp_path, monkeypatch):
    store.close()
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    monkeypatch.setattr(store, "DB_PATH", tmp_path / "memory.db")
    monkeypatch.setattr(store, "_conn", None)
    store.init_db()
    store.add_node("fact", "secret note", domain="setup")
    store.close()
    # The raw file must NOT be readable as plain SQLite.
    assert store.DB_PATH.exists()
    assert not _opens_as_plain_sqlite(store.DB_PATH)


# ──────────────────────────── migration ────────────────────────────

def test_migrate_plaintext_preserves_data(tmp_path, monkeypatch):
    from axi import db_migrate

    store.close()
    db = tmp_path / "memory.db"
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    monkeypatch.setattr(store, "DB_PATH", db)
    monkeypatch.setattr(store, "_conn", None)
    _make_plain_db(
        db,
        nodes=[("fact", "Héctor usa CachyOS")],
        conversations=[("hola", "qué tal"), ("hora?", "07:30")],
    )
    assert _opens_as_plain_sqlite(db)  # precondition

    result = db_migrate.migrate_to_encrypted()
    assert result["status"] == "migrated"

    # File is now encrypted.
    assert not _opens_as_plain_sqlite(db)
    # A timestamped backup of the plaintext DB exists.
    backups = list(tmp_path.glob("memory.db.pre-encrypt.*.bak"))
    assert len(backups) == 1
    assert _opens_as_plain_sqlite(backups[0])

    # Data is intact through the normal (encrypted) store API.
    store._conn = None
    assert store.conversation_count() == 2
    rows = store.recent_conversations(limit=10)
    assert [r["user_text"] for r in rows] == ["hola", "hora?"]


def test_migrate_preserves_fts_search(tmp_path, monkeypatch):
    from axi import db_migrate

    store.close()
    db = tmp_path / "memory.db"
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    monkeypatch.setattr(store, "DB_PATH", db)
    monkeypatch.setattr(store, "_conn", None)
    _make_plain_db(db, nodes=[("fact", "Axi corre en CachyOS")])

    db_migrate.migrate_to_encrypted()

    store._conn = None
    hits = store.search_nodes_fts("Axi")
    assert len(hits) == 1
    assert "Axi" in hits[0]["label"]


def test_migrate_is_idempotent_on_encrypted_db(tmp_path, monkeypatch):
    from axi import db_migrate

    store.close()
    db = tmp_path / "memory.db"
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    monkeypatch.setattr(store, "DB_PATH", db)
    monkeypatch.setattr(store, "_conn", None)
    store.init_db()  # creates an encrypted DB
    store.close()

    result = db_migrate.migrate_to_encrypted()
    assert result["status"] == "already_encrypted"


def test_migrate_noop_when_db_absent(tmp_path, monkeypatch):
    from axi import db_migrate

    store.close()
    db = tmp_path / "memory.db"
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    monkeypatch.setattr(store, "DB_PATH", db)
    monkeypatch.setattr(store, "_conn", None)
    assert not db.exists()

    result = db_migrate.migrate_to_encrypted()
    assert result["status"] in ("already_encrypted", "no_db")
    assert not db.exists()


def test_migrate_dry_run_does_not_swap(tmp_path, monkeypatch):
    from axi import db_migrate

    store.close()
    db = tmp_path / "memory.db"
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    monkeypatch.setattr(store, "DB_PATH", db)
    monkeypatch.setattr(store, "_conn", None)
    _make_plain_db(db, nodes=[("fact", "still plain")])

    result = db_migrate.migrate_to_encrypted(dry_run=True)
    assert result["status"] in ("migrated", "dry_run")
    # Original stays plaintext, no stray temp file.
    assert _opens_as_plain_sqlite(db)
    assert not (tmp_path / "memory.db.encrypted").exists()


# ─────────────────── transparent auto-migration on connect ───────────────────

def test_connect_auto_migrates_plaintext(tmp_path, monkeypatch):
    """A pre-existing plaintext DB is migrated transparently on first use."""
    store.close()
    db = tmp_path / "memory.db"
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    monkeypatch.setattr(store, "DB_PATH", db)
    monkeypatch.setattr(store, "_conn", None)
    _make_plain_db(db, conversations=[("antes", "de cifrar")])

    # First normal API call should just work and see the old data...
    assert store.conversation_count() == 1
    # ...and the file on disk is now encrypted.
    store.close()
    assert not _opens_as_plain_sqlite(db)
