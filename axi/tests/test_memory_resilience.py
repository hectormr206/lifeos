"""Tests for self-healing memory: graceful degradation, shutdown hardening,
and startup auto-recovery.

TDD cycle: RED → GREEN → REFACTOR
Layer 1: Graceful degradation (memory.py wraps)
Layer 2: Shutdown checkpoint discipline (daemon.py + store.py synchronous)
Layer 3: Startup auto-recovery ladder (store._connect corruption recovery)
"""
from __future__ import annotations

import shutil
from pathlib import Path
from unittest.mock import MagicMock, patch, call

import pytest
import sqlcipher3

from axi import store
from axi.memory import ConversationMemory


# ─────────────────────────── helpers ────────────────────────────────────────


class _RaisingStore:
    """Stub that mimics the store module but every call raises DatabaseError."""

    def __init__(self, exc: Exception | None = None):
        self._exc = exc or sqlcipher3.dbapi2.DatabaseError("database disk image is malformed")

    def init_db(self):
        raise self._exc

    def recent_conversations(self, *a, **kw):
        raise self._exc

    def add_node(self, *a, **kw):
        raise self._exc

    def add_conversation(self, *a, **kw):
        raise self._exc

    def conversation_count(self, *a, **kw):
        raise self._exc

    def search_nodes_fts(self, *a, **kw):
        raise self._exc

    def clear_conversations(self, *a, **kw):
        raise self._exc

    # _tx context manager — raises on __enter__
    def _tx(self):
        raise self._exc


# ──────────────────────────────────────────────────────────────────────────────
# LAYER 1 — Graceful Degradation
# ──────────────────────────────────────────────────────────────────────────────


class TestMemoryGracefulDegradation:
    """memory.py methods must return safe defaults, never propagate DatabaseError."""

    def test_messages_returns_empty_list_when_store_raises(self, monkeypatch):
        """messages() must return [] when store.recent_conversations raises."""
        monkeypatch.setattr("axi.memory.store", _RaisingStore())
        # init_db raises — ConversationMemory must still construct
        mem = ConversationMemory.__new__(ConversationMemory)
        mem.max_context_turns = 20
        # Now test messages()
        result = mem.messages()
        assert result == []

    def test_add_returns_safe_default_when_store_raises(self, monkeypatch):
        """add() must not raise when the underlying store fails."""
        monkeypatch.setattr("axi.memory.store", _RaisingStore())
        mem = ConversationMemory.__new__(ConversationMemory)
        mem.max_context_turns = 20
        # Must not raise; return value is (0, 0) or similar safe sentinel
        result = mem.add("hola", "respuesta")
        assert isinstance(result, tuple)
        assert len(result) == 2

    def test_turn_count_returns_zero_when_store_raises(self, monkeypatch):
        """turn_count() must return 0 when store.conversation_count raises."""
        monkeypatch.setattr("axi.memory.store", _RaisingStore())
        mem = ConversationMemory.__new__(ConversationMemory)
        mem.max_context_turns = 20
        assert mem.turn_count() == 0

    def test_init_succeeds_even_if_init_db_raises(self, monkeypatch):
        """ConversationMemory.__init__ must not propagate DatabaseError."""
        monkeypatch.setattr("axi.memory.store", _RaisingStore())
        # This must NOT raise
        mem = ConversationMemory()
        assert mem is not None

    def test_degraded_flag_set_when_init_db_fails(self, monkeypatch):
        """ConversationMemory must expose a degraded flag when the DB failed to init."""
        monkeypatch.setattr("axi.memory.store", _RaisingStore())
        mem = ConversationMemory()
        assert mem.degraded is True

    def test_not_degraded_when_store_is_healthy(self):
        """Normal operation: degraded flag must be False."""
        mem = ConversationMemory()
        assert mem.degraded is False

    def test_messages_logs_warning_on_database_error(self, monkeypatch, caplog):
        """messages() must log a WARNING (not ERROR/CRITICAL) when degraded."""
        import logging
        monkeypatch.setattr("axi.memory.store", _RaisingStore())
        mem = ConversationMemory.__new__(ConversationMemory)
        mem.max_context_turns = 20
        with caplog.at_level(logging.WARNING, logger="axi.memory"):
            mem.messages()
        assert any("memory degraded" in r.message for r in caplog.records)

    def test_add_logs_warning_on_database_error(self, monkeypatch, caplog):
        """add() must log a WARNING when the store raises."""
        import logging
        monkeypatch.setattr("axi.memory.store", _RaisingStore())
        mem = ConversationMemory.__new__(ConversationMemory)
        mem.max_context_turns = 20
        with caplog.at_level(logging.WARNING, logger="axi.memory"):
            mem.add("x", "y")
        assert any("memory degraded" in r.message for r in caplog.records)

    def test_turn_count_logs_warning_on_database_error(self, monkeypatch, caplog):
        """turn_count() must log a WARNING when the store raises."""
        import logging
        monkeypatch.setattr("axi.memory.store", _RaisingStore())
        mem = ConversationMemory.__new__(ConversationMemory)
        mem.max_context_turns = 20
        with caplog.at_level(logging.WARNING, logger="axi.memory"):
            mem.turn_count()
        assert any("memory degraded" in r.message for r in caplog.records)

    def test_messages_raises_nothing_on_generic_exception(self, monkeypatch):
        """messages() must catch ANY exception, not only DatabaseError."""
        class _AnyError(_RaisingStore):
            def __init__(self):
                super().__init__(RuntimeError("unexpected internal error"))
        monkeypatch.setattr("axi.memory.store", _AnyError())
        mem = ConversationMemory.__new__(ConversationMemory)
        mem.max_context_turns = 20
        assert mem.messages() == []


# ──────────────────────────────────────────────────────────────────────────────
# LAYER 2 — Shutdown Checkpoint Discipline
# ──────────────────────────────────────────────────────────────────────────────


class TestShutdownCheckpoint:
    """daemon.serve() finally block must call store.checkpoint() and store.close()."""

    def test_serve_calls_checkpoint_on_clean_shutdown(self, tmp_path, monkeypatch):
        """serve() must call store.checkpoint() in its finally block."""
        import socket as _socket
        import signal
        from axi import daemon as _daemon

        checkpoint_calls = []
        close_calls = []

        monkeypatch.setattr(_daemon.store, "checkpoint", lambda: checkpoint_calls.append(1))
        monkeypatch.setattr(_daemon.store, "close", lambda: close_calls.append(1))

        sock_path = tmp_path / "test.sock"
        monkeypatch.setattr(_daemon, "SOCK_PATH", sock_path)

        # Patch Daemon to raise immediately so serve() exits fast
        monkeypatch.setattr(_daemon, "Daemon", lambda: (_ for _ in ()).throw(SystemExit(0)))

        try:
            _daemon.serve()
        except SystemExit:
            pass

        assert len(checkpoint_calls) >= 1, "store.checkpoint() must be called on shutdown"

    def test_serve_calls_store_close_on_clean_shutdown(self, tmp_path, monkeypatch):
        """serve() must call store.close() in its finally block."""
        from axi import daemon as _daemon

        close_calls = []
        monkeypatch.setattr(_daemon.store, "checkpoint", lambda: None)
        monkeypatch.setattr(_daemon.store, "close", lambda: close_calls.append(1))

        sock_path = tmp_path / "test.sock"
        monkeypatch.setattr(_daemon, "SOCK_PATH", sock_path)

        monkeypatch.setattr(_daemon, "Daemon", lambda: (_ for _ in ()).throw(SystemExit(0)))

        try:
            _daemon.serve()
        except SystemExit:
            pass

        assert len(close_calls) >= 1, "store.close() must be called on shutdown"


class TestSynchronousFull:
    """store._connect() must set PRAGMA synchronous=FULL on the conversation DB."""

    def test_synchronous_pragma_is_full(self, tmp_path, monkeypatch):
        """After _connect(), the connection must report synchronous=2 (FULL)."""
        monkeypatch.setattr(store, "DB_PATH", tmp_path / "test_sync.db")
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)
        store.close()  # clear thread-local so _connect() re-opens against new DB_PATH

        conn = store._connect()
        row = conn.execute("PRAGMA synchronous").fetchone()
        # SQLite PRAGMA synchronous: 0=OFF, 1=NORMAL, 2=FULL, 3=EXTRA
        assert row[0] == 2, f"Expected synchronous=FULL (2), got {row[0]}"


# ──────────────────────────────────────────────────────────────────────────────
# LAYER 3 — Startup Auto-Recovery
# ──────────────────────────────────────────────────────────────────────────────


class TestStartupRecovery:
    """store._repair_corrupt_db() self-heals corrupt DB files."""

    def test_wal_sidecar_removal_recovers_after_corruption(self, tmp_path, monkeypatch):
        """Common case: WAL reset (remove WAL/SHM) returns a working connection."""
        import sqlcipher3

        db = tmp_path / "test_recover.db"
        key = "a" * 64

        # Build a valid encrypted DB at a known path.
        c = sqlcipher3.connect(str(db), check_same_thread=False, isolation_level=None)
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)")
        c.close()

        # Write garbage WAL/SHM that look corrupt.
        Path(str(db) + "-wal").write_bytes(b"\xff" * 512)
        Path(str(db) + "-shm").write_bytes(b"\x00" * 32768)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        # _repair_corrupt_db calls step 2 (WAL reset) — must succeed.
        conn = store._repair_corrupt_db(db, key)
        assert conn is not None
        # WAL/SHM must be gone after recovery.
        assert not Path(str(db) + "-wal").exists()

    def test_corrupt_backup_files_created_on_recovery(self, tmp_path, monkeypatch):
        """On recovery, a .corrupt-*.bak backup of the original file is created."""
        import sqlcipher3

        db = tmp_path / "memory.db"
        key = "a" * 64

        # Build a valid DB.
        c = sqlcipher3.connect(str(db), check_same_thread=False, isolation_level=None)
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)")
        c.close()

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        # Trigger recovery (WAL reset path is sufficient to test backup creation).
        store._repair_corrupt_db(db, key)

        bak_files = list(tmp_path.glob("memory.db.corrupt-*.bak"))
        assert len(bak_files) >= 1, "Expected at least one .corrupt-*.bak file"

    def test_fresh_schema_created_when_no_recovery_possible(self, tmp_path, monkeypatch):
        """Last resort: if main file and WAL are both unrecoverable, fresh schema is built."""
        db = tmp_path / "memory.db"
        key = "a" * 64

        # Completely corrupt main DB file (not a valid SQLCipher file at all).
        db.write_bytes(b"\xff" * 4096)
        Path(str(db) + "-wal").write_bytes(b"\xff" * 512)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        # Should NOT raise — must fall back to empty schema.
        conn = store._repair_corrupt_db(db, key)
        assert conn is not None

        # The resulting connection must be writable (fresh schema can be created).
        conn.execute(f"PRAGMA key = \"x'{key}'\"")  # key already applied but idempotent
        conn.execute("CREATE TABLE IF NOT EXISTS sentinel (id INTEGER PRIMARY KEY)")
        conn.execute("INSERT INTO sentinel VALUES (1)")

    def test_recovery_restores_data_from_healthy_corrupt_named_backup(
        self, tmp_path, monkeypatch
    ):
        """Regression (2026-06-20 data-loss incident): recovery MUST restore a
        healthy backup even when it is named ``.corrupt-<pid>.bak``.

        Corruption is most often WAL-only or cross-process, so the snapshot the
        recovery ladder takes in step 1 (named ``memory.db.corrupt-<pid>.bak``)
        is frequently a perfectly healthy copy of the main file. The old code
        skipped every ``.corrupt-*`` candidate by filename and fell through to
        the empty-schema rebuild — destroying all memory that was never actually
        lost. The fix validates each candidate with a real integrity check and
        restores the newest healthy one regardless of its name.
        """
        db = tmp_path / "memory.db"
        key = "a" * 64

        # A healthy backup of the data, carrying the very name the old code skipped.
        healthy_bak = tmp_path / "memory.db.corrupt-99999.bak"
        c = sqlcipher3.connect(str(healthy_bak), check_same_thread=False, isolation_level=None)
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("CREATE TABLE nodes (id INTEGER PRIMARY KEY, label TEXT)")
        c.execute("INSERT INTO nodes (label) VALUES ('keep-me-1'), ('keep-me-2')")
        c.close()

        # Main file + WAL are unrecoverable garbage so steps 2 cannot reopen them.
        db.write_bytes(b"\xff" * 4096)
        Path(str(db) + "-wal").write_bytes(b"\xff" * 512)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        conn = store._repair_corrupt_db(db, key)
        assert conn is not None
        # The data MUST survive — recovery restored the healthy named-corrupt backup
        # instead of rebuilding an empty schema.
        rows = conn.execute("SELECT label FROM nodes ORDER BY id").fetchall()
        assert [r[0] for r in rows] == ["keep-me-1", "keep-me-2"], (
            "recovery destroyed recoverable data instead of restoring the "
            "healthy .corrupt-*.bak snapshot"
        )

    def test_events_persist_to_separate_db_not_memory_db(self):
        """Events (telemetry) must live in their own events.db, never in memory.db.

        Three processes (daemon, dashboard, heartbeat) all open memory.db; the
        observability work made heartbeat a high-frequency events writer. Mixing
        disposable telemetry writes from 3 processes into the same SQLCipher file
        that holds irreplaceable user memory is what drove the cross-process WAL
        contention behind the 2026-06-20 corruption. Events get their own DB so
        only the daemon ever writes memory.db.
        """
        key = store.load_key()
        store.init_db()
        store.insert_event(123.0, "sep.test", "info", "hello-events-db", None)

        # Queryable through the normal API.
        evs = store.query_events(source="sep.test")
        assert any(e["message"] == "hello-events-db" for e in evs)

        # The row lives in events.db ...
        ec = sqlcipher3.connect(str(store._events_db_path()), isolation_level=None)
        ec.execute(f"PRAGMA key = \"x'{key}'\"")
        in_events = ec.execute(
            "SELECT count(*) FROM events WHERE source='sep.test'"
        ).fetchone()[0]
        ec.close()
        assert in_events == 1, "event did not land in events.db"

        # ... and NOT in memory.db.
        mc = sqlcipher3.connect(str(store.DB_PATH), isolation_level=None)
        mc.execute(f"PRAGMA key = \"x'{key}'\"")
        has_tbl = mc.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='events'"
        ).fetchone()
        leaked = (
            mc.execute("SELECT count(*) FROM events WHERE source='sep.test'").fetchone()[0]
            if has_tbl else 0
        )
        mc.close()
        assert leaked == 0, "event leaked into memory.db — telemetry must not touch user memory"

    def test_recovery_logged_on_corrupt_file(self, tmp_path, monkeypatch, caplog):
        """Recovery steps must produce WARNING log records."""
        import logging
        import sqlcipher3

        db = tmp_path / "memory.db"
        key = "a" * 64

        c = sqlcipher3.connect(str(db), check_same_thread=False, isolation_level=None)
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)")
        c.close()

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        with caplog.at_level(logging.WARNING, logger="axi.store"):
            store._repair_corrupt_db(db, key)

        recovery_msgs = [
            r for r in caplog.records
            if "recover" in r.message.lower() or "corrupt" in r.message.lower()
        ]
        assert len(recovery_msgs) >= 1, "No recovery log message found"

    def test_connect_triggers_repair_when_open_raises(self, tmp_path, monkeypatch):
        """_connect() must call _repair_corrupt_db when _try_open raises DatabaseError."""
        import sqlcipher3

        db = tmp_path / "memory.db"
        key = "a" * 64

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)
        store.close()  # clear thread-local so _connect() re-opens against new DB_PATH
        monkeypatch.setattr(store, "load_key", lambda: key)

        repair_calls = []
        real_repair = store._repair_corrupt_db

        def _mock_repair(db_path, k):
            repair_calls.append(1)
            return real_repair(db_path, k)

        # Simulate _try_open raising DatabaseError to trigger repair path.
        call_count = {"n": 0}
        real_try_open = store._try_open

        def _failing_try_open(db_path, k):
            call_count["n"] += 1
            if call_count["n"] == 1:
                raise sqlcipher3.dbapi2.DatabaseError("database disk image is malformed")
            return real_try_open(db_path, k)

        monkeypatch.setattr(store, "_try_open", _failing_try_open)
        monkeypatch.setattr(store, "_repair_corrupt_db", _mock_repair)
        monkeypatch.setattr("axi.db_migrate.migrate_to_encrypted", lambda **kw: {"status": "no_db"})

        conn = store._connect()
        assert conn is not None
        assert len(repair_calls) == 1, "_repair_corrupt_db must be called when _try_open raises"
