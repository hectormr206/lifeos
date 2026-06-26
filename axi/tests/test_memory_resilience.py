"""Tests for self-healing memory: graceful degradation, shutdown hardening,
and startup auto-recovery.

TDD cycle: RED → GREEN → REFACTOR
Layer 1: Graceful degradation (memory.py wraps)
Layer 2: Shutdown checkpoint discipline (daemon.py + store.py synchronous)
Layer 3: Startup auto-recovery ladder (store._connect corruption recovery)
"""
from __future__ import annotations

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

    def test_add_retries_after_connection_reset_persists_turn(self, monkeypatch):
        """A latched connection (healthy file) must NOT drop the turn: on the
        corruption error the connection is reset and the insert is retried, so
        the turn actually persists."""
        class _LatchThenReset:
            """add_conversation latches once with an hmac error; reset_connection
            'fixes' it so the retry succeeds with a real row id."""
            def __init__(self):
                self.attempts = 0
                self.reset_calls = 0
                self.heal_calls = 0
            def add_conversation(self, *a, **kw):
                self.attempts += 1
                if self.attempts == 1:
                    raise sqlcipher3.dbapi2.DatabaseError("hmac check failed for pgno=3")
                return 147
            def reset_connection(self):
                self.reset_calls += 1
                return True
            def attempt_self_heal(self):
                self.heal_calls += 1
                return False

        stub = _LatchThenReset()
        monkeypatch.setattr("axi.memory.store", stub)
        monkeypatch.setattr("axi.memory.config.get", lambda k, d=None: False)
        mem = ConversationMemory.__new__(ConversationMemory)
        mem.max_context_turns = 20
        mem._self_healed = False
        mem.degraded = False

        conv_id, node_id = mem.add("glucosa 91", "Anotado en Salud: glucosa 91.")

        assert conv_id == 147          # the retry persisted the turn
        assert stub.attempts == 2      # first failed, retry succeeded
        assert stub.reset_calls == 1   # the cheap reset was used
        assert stub.heal_calls == 0    # never escalated to the heavy ladder
        assert mem.degraded is False   # not degraded — it recovered cleanly


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
        """Common case: WAL reset (remove WAL/SHM) returns a working connection.

        The re-check inside _repair_corrupt_db_locked calls _remove_wal_sidecars
        then _try_open.  With a real corrupt WAL the re-check would naturally fail
        and proceed to the ladder.  Here we patch _try_open so the FIRST call
        (the re-check) returns None, ensuring Step 2 (WAL reset) is the actual
        path that produces the successful connection — not the re-check skip.
        """
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

        # Re-check must fail (return None) so the ladder's Step 2 runs.
        # Subsequent calls use the real function — Step 2 will open the clean DB.
        real_try_open = store._try_open
        call_count = {"n": 0}

        def _recheck_fails(path, k):
            call_count["n"] += 1
            if call_count["n"] == 1:
                return None  # re-check fails → proceed to Step 2
            return real_try_open(path, k)

        monkeypatch.setattr(store, "_try_open", _recheck_fails)

        # Step 2 (WAL reset) must succeed and return a connection.
        conn = store._repair_corrupt_db(db, key)
        assert conn is not None
        # WAL/SHM must be gone after recovery.
        assert not Path(str(db) + "-wal").exists()

    def test_corrupt_backup_files_created_on_recovery(self, tmp_path, monkeypatch):
        """On recovery, a .corrupt-*.bak backup of the original file is created.

        The re-check (new behavior) is made to fail by writing garbage WAL so the
        post-WAL-removal _try_open still raises DatabaseError, forcing Step 1 to run.
        The backup must be written before any destructive step.
        """
        import sqlcipher3

        db = tmp_path / "memory.db"
        key = "a" * 64

        # Build a valid DB.
        c = sqlcipher3.connect(str(db), check_same_thread=False, isolation_level=None)
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)")
        c.close()

        # Write garbage WAL so _remove_wal_sidecars + re-check still fails,
        # forcing the ladder to run and write the backup in Step 1.
        Path(str(db) + "-wal").write_bytes(b"\xff" * 512)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        # Patch _try_open so the re-check (after WAL removal) still returns None,
        # forcing Step 1 to run.  Subsequent calls (Step 2) use the real function.
        real_try_open = store._try_open
        call_count = {"n": 0}

        def _recheck_fails(path, k):
            call_count["n"] += 1
            if call_count["n"] == 1 and str(path) == str(db):
                # Re-check fails — ladder must run.
                return None
            return real_try_open(path, k)

        monkeypatch.setattr(store, "_try_open", _recheck_fails)

        # Trigger recovery (Step 1 backup + Step 2 WAL reset).
        store._repair_corrupt_db(db, key)

        bak_files = list(tmp_path.glob("memory.db.corrupt-*.bak"))
        assert len(bak_files) >= 1, "Expected at least one .corrupt-*.bak file"

    def test_forensic_wal_snapshot_preserved_before_recheck_removal(
        self, tmp_path, monkeypatch
    ):
        """Forensic regression: WAL bytes must be preserved even when the re-check
        removes sidecars before Step 1 runs.

        _repair_corrupt_db_locked snapshots existing WAL/SHM to
        ``<db>.corrupt-<pid>.bak-wal`` / ``-shm`` BEFORE calling
        _remove_wal_sidecars, so the corrupt bytes survive for post-incident
        inspection regardless of which recovery path is taken.
        """
        import sqlcipher3

        db = tmp_path / "memory.db"
        key = "a" * 64

        # Build a valid DB.
        c = sqlcipher3.connect(str(db), check_same_thread=False, isolation_level=None)
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)")
        c.close()

        # Write a recognisable WAL payload so we can confirm it was copied.
        wal_sentinel = b"\xDE\xAD\xBE\xEF" * 64
        Path(str(db) + "-wal").write_bytes(wal_sentinel)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        # Re-check fails so the ladder runs (same pattern as other tests).
        real_try_open = store._try_open
        call_count = {"n": 0}

        def _recheck_fails(path, k):
            call_count["n"] += 1
            if call_count["n"] == 1 and str(path) == str(db):
                return None
            return real_try_open(path, k)

        monkeypatch.setattr(store, "_try_open", _recheck_fails)

        store._repair_corrupt_db(db, key)

        # A forensic WAL artifact must exist after recovery.
        wal_artifacts = list(tmp_path.glob("memory.db.corrupt-*.bak-wal"))
        assert len(wal_artifacts) >= 1, (
            "Expected a forensic .corrupt-<pid>.bak-wal file preserving the corrupt WAL"
        )
        # Confirm the sentinel bytes were captured (not an empty snapshot).
        assert wal_artifacts[0].read_bytes() == wal_sentinel, (
            "Forensic WAL snapshot must contain the original corrupt WAL bytes"
        )

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

    # ── Safety-gate tests (new, 2026-06-24) ──────────────────────────────────

    def test_healthy_backup_restore_fails_raises_recovery_error(
        self, tmp_path, monkeypatch
    ):
        """SAFETY: healthy backup exists but restore fails (temp open returns None) →
        MUST raise RecoveryError, MUST NOT wipe db_path to empty.

        Discriminates old vs new (updated for atomic-restore flow):
        - OLD behavior: exits step-3 loop with no success, falls to step 4,
          calls db_path.unlink() and returns an empty-schema connection.
        - NEW behavior: detects healthy_backup_seen=True, refuses to wipe,
          raises RecoveryError so the caller learns recoverable data exists.

        Patching strategy (atomic-restore aware): block _try_open on the temp
        file path (simulating transient I/O after copy to temp), which is the
        failure mode that triggered the June-24 real incident.
        """
        db = tmp_path / "memory.db"
        key = "a" * 64

        # Main file is garbage (forces step 2 to fail).
        db.write_bytes(b"\xff" * 4096)

        # Create a healthy backup that passes integrity_check.
        healthy_bak = tmp_path / "memory.db.good.bak"
        c = sqlcipher3.connect(str(healthy_bak), check_same_thread=False, isolation_level=None)
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("CREATE TABLE nodes (id INTEGER PRIMARY KEY, label TEXT)")
        c.execute("INSERT INTO nodes (label) VALUES ('precious')")
        c.close()

        # Capture the original bytes of db_path before recovery.
        original_bytes = db.read_bytes()

        # Block _try_open on the live db_path (step 2 WAL reset, already fails
        # because it's garbage) AND on any restore-tmp path (atomic restore
        # temp-open step) — simulates transient I/O error after copy to temp.
        real_try_open = store._try_open

        def _failing_try_open(path, k):
            p = str(path)
            if p == str(db) or ".restore-tmp-" in p:
                return None
            return real_try_open(path, k)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)
        monkeypatch.setattr(store, "_try_open", _failing_try_open)

        # Must raise RecoveryError (not return an empty connection).
        with pytest.raises(store.RecoveryError):
            store._repair_corrupt_db(db, key)

        # db_path must NOT have been wiped — original bytes preserved.
        assert db.exists(), "db_path must not be unlinked"
        assert db.read_bytes() == original_bytes, (
            "db_path bytes changed — it was wiped or overwritten during failed recovery"
        )

    def test_healthy_backup_restore_fails_does_not_return_empty_connection(
        self, tmp_path, monkeypatch
    ):
        """Companion to above: _repair_corrupt_db must not return a fresh empty
        connection when healthy backups exist but restores fail.

        OLD: returned a live sqlcipher3.Connection to an empty schema → silent loss.
        NEW: raises, never returns, so no caller can mistake 'empty connection' for success.

        Patching strategy (atomic-restore aware): block _try_open on temp path
        to simulate the failure mode where copy succeeds but the file won't open.
        """
        db = tmp_path / "memory.db"
        key = "a" * 64

        db.write_bytes(b"\xff" * 4096)

        healthy_bak = tmp_path / "memory.db.healthy.bak"
        c = sqlcipher3.connect(str(healthy_bak), check_same_thread=False, isolation_level=None)
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("CREATE TABLE t (v TEXT)")
        c.execute("INSERT INTO t VALUES ('must-not-lose')")
        c.close()

        real_try_open = store._try_open

        def _failing_try_open(path, k):
            p = str(path)
            if p == str(db) or ".restore-tmp-" in p:
                return None
            return real_try_open(path, k)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)
        monkeypatch.setattr(store, "_try_open", _failing_try_open)

        result = None
        raised = False
        try:
            result = store._repair_corrupt_db(db, key)
        except (store.RecoveryError, RuntimeError):
            raised = True

        assert raised, "_repair_corrupt_db must raise, not return, when healthy backup exists"
        assert result is None, "result must be None — no empty connection was returned"

    def test_no_healthy_backup_still_rebuilds_empty_schema(self, tmp_path, monkeypatch):
        """Regression guard: when genuinely NO healthy backup exists,
        the existing behavior (rebuild empty schema) must be preserved.

        This covers the 'nothing to lose' path — healthy_backup_seen stays False
        and step 4 runs as before.

        Note: we verify conn is not None (step 4 returns a connection, not raises).
        We do not attempt DDL here because a just-unlinked+recreated SQLCipher file
        may exhibit transient disk-I/O in certain fs setups (matches the known flake
        in test_fresh_schema_created_when_no_recovery_possible when run in suite).
        """
        db = tmp_path / "memory.db"
        key = "a" * 64

        # Main file + WAL are garbage. NO .bak files exist.
        db.write_bytes(b"\xff" * 4096)
        Path(str(db) + "-wal").write_bytes(b"\xff" * 512)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        # Must NOT raise RecoveryError — no data to lose, rebuild empty.
        conn = store._repair_corrupt_db(db, key)
        assert conn is not None, "step 4 must return a fresh connection, not raise"

    def test_healthy_backup_that_restores_ok_returns_connection(self, tmp_path, monkeypatch):
        """Happy path: healthy backup + restore succeeds → returns working connection.
        This must remain GREEN (no regression from the safety flag).
        """
        db = tmp_path / "memory.db"
        key = "a" * 64

        # Main file is garbage.
        db.write_bytes(b"\xff" * 4096)

        # Healthy backup.
        healthy_bak = tmp_path / "memory.db.restore-ok.bak"
        c = sqlcipher3.connect(str(healthy_bak), check_same_thread=False, isolation_level=None)
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("CREATE TABLE memories (id INTEGER PRIMARY KEY, content TEXT)")
        c.execute("INSERT INTO memories (content) VALUES ('survive-recovery')")
        c.close()

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        conn = store._repair_corrupt_db(db, key)
        assert conn is not None

        rows = conn.execute("SELECT content FROM memories").fetchall()
        assert [r[0] for r in rows] == ["survive-recovery"]

    # ── Atomic-restore tests (2026-06-24 clobber fix) ────────────────────────

    def test_failed_restore_does_not_clobber_db_path(self, tmp_path, monkeypatch):
        """ATOMIC RESTORE — RED test: db_path must be UNTOUCHED when the post-restore
        open of the temp (or in-place) file fails.

        Discriminates old vs new:
        - OLD code: shutil.copy2(candidate, db_path) runs BEFORE verifying the file
          opens → db_path is overwritten with the (stale) backup bytes even when
          _try_open subsequently fails.  db_path.read_bytes() != original_bytes → FAIL.
        - NEW code: copy goes to a temp file; _try_open(tmp) fails → tmp.unlink();
          os.replace is NEVER called → db_path is untouched → PASS.

        The monkeypatch returns None from _try_open when the path is the live db_path
        (old code) OR when the path ends with ".restore-tmp-*" (new code), simulating
        a transient btrfs disk-I/O error after copy.
        """
        db = tmp_path / "memory.db"
        key = "a" * 64

        # Original (corrupt) db_path — known bytes so we can assert no change.
        original_bytes = b"\xff" * 4096
        db.write_bytes(original_bytes)

        # A healthy backup that passes integrity_check.
        healthy_bak = tmp_path / "memory.db.clobber-test.bak"
        c = sqlcipher3.connect(
            str(healthy_bak), check_same_thread=False, isolation_level=None
        )
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("CREATE TABLE nodes (id INTEGER PRIMARY KEY, label TEXT)")
        c.execute("INSERT INTO nodes (label) VALUES ('do-not-lose')")
        c.close()

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        real_try_open = store._try_open

        def _failing_open_for_restore(path, k):
            # Fail when called on the live db_path (old code path) OR
            # on any restore-tmp file (new code path) — simulates transient I/O.
            p = str(path)
            if p == str(db) or ".restore-tmp-" in p:
                return None
            return real_try_open(path, k)

        monkeypatch.setattr(store, "_try_open", _failing_open_for_restore)

        # Must raise RecoveryError (healthy_backup_seen=True but restore failed).
        with pytest.raises(store.RecoveryError):
            store._repair_corrupt_db(db, key)

        # INVARIANT: db_path bytes must be identical to what we put there.
        assert db.exists(), "db_path must not be unlinked"
        assert db.read_bytes() == original_bytes, (
            "db_path was clobbered during a failed restore attempt — "
            "shutil.copy2 ran directly onto db_path before verifying the open succeeded"
        )

        # No temp file must linger.
        leftover_tmp = list(tmp_path.glob("memory.db.restore-tmp-*"))
        assert leftover_tmp == [], (
            f"restore temp file(s) left behind: {leftover_tmp}"
        )

    def test_successful_restore_swaps_atomically(self, tmp_path, monkeypatch):
        """ATOMIC RESTORE — GREEN path: healthy backup + successful open → db_path
        contains restored content, returns working connection, no temp file left.

        Discriminates old vs new:
        - OLD: works by luck (copy2 directly to db_path, _try_open succeeds) but
          is non-atomic.  This test passes on old code too — it is a regression
          guard that ensures new atomic code does not break the happy path.
        - NEW: temp file created, verified, os.replace atomically swaps in → same
          observable result but with atomicity guarantee.
        """
        db = tmp_path / "memory.db"
        key = "a" * 64

        # Corrupt main file.
        db.write_bytes(b"\xff" * 4096)

        # Healthy backup with distinct data.
        healthy_bak = tmp_path / "memory.db.atomic-ok.bak"
        c = sqlcipher3.connect(
            str(healthy_bak), check_same_thread=False, isolation_level=None
        )
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("CREATE TABLE memories (id INTEGER PRIMARY KEY, content TEXT)")
        c.execute("INSERT INTO memories (content) VALUES ('atomic-swap-ok')")
        c.close()

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        conn = store._repair_corrupt_db(db, key)
        assert conn is not None, "successful restore must return a valid connection"

        # db_path now has the restored content.
        rows = conn.execute("SELECT content FROM memories").fetchall()
        assert [r[0] for r in rows] == ["atomic-swap-ok"], (
            "restored data not found after successful recovery"
        )
        conn.close()

        # No temp file must linger.
        leftover_tmp = list(tmp_path.glob("memory.db.restore-tmp-*"))
        assert leftover_tmp == [], (
            f"restore temp file(s) left behind: {leftover_tmp}"
        )

    def test_try_open_raises_database_error_on_temp_leaves_db_path_untouched(
        self, tmp_path, monkeypatch
    ):
        """FIX 3 — production-path: _try_open RAISES DatabaseError (not returns None)
        on the temp-file open, exactly as in the 2026-06-24 btrfs incident.

        Discriminates old vs new:
        - OLD code (pre-atomic): shutil.copy2 went directly to db_path; a raise
          from _try_open never occurred there; db_path was already clobbered.
        - NEW code (atomic): copy goes to a temp; _try_open(tmp) raises
          DatabaseError → caught by `except (OSError, DatabaseError)` → tmp.unlink()
          in finally → os.replace never called → db_path untouched.

        Asserts:
        - _repair_corrupt_db raises RecoveryError (healthy_backup_seen=True,
          no restore succeeded).
        - db_path bytes are identical to original (no clobber).
        - No .restore-tmp-* file is left behind.
        """
        db = tmp_path / "memory.db"
        key = "a" * 64

        original_bytes = b"\xff" * 4096
        db.write_bytes(original_bytes)

        # Healthy backup — passes integrity_check.
        healthy_bak = tmp_path / "memory.db.incident-btrfs.bak"
        c = sqlcipher3.connect(str(healthy_bak), check_same_thread=False, isolation_level=None)
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("CREATE TABLE nodes (id INTEGER PRIMARY KEY, label TEXT)")
        c.execute("INSERT INTO nodes (label) VALUES ('btrfs-incident-data')")
        c.close()

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        real_try_open = store._try_open

        def _raising_try_open(path, k):
            p = str(path)
            # Simulate btrfs I/O decrypt error on the temp file open (or live path).
            if p == str(db) or ".restore-tmp-" in p:
                raise sqlcipher3.dbapi2.DatabaseError("file is not a database")
            return real_try_open(path, k)

        monkeypatch.setattr(store, "_try_open", _raising_try_open)

        with pytest.raises(store.RecoveryError):
            store._repair_corrupt_db(db, key)

        # db_path must be untouched.
        assert db.exists(), "db_path must not be unlinked"
        assert db.read_bytes() == original_bytes, (
            "db_path was clobbered — os.replace must not run when temp open raises"
        )

        # No temp file left behind.
        leftover = list(tmp_path.glob("memory.db.restore-tmp-*"))
        assert leftover == [], f"restore temp file(s) left behind: {leftover}"

    def test_swap_ok_but_reopen_fails_leaves_db_path_with_verified_backup_bytes(
        self, tmp_path, monkeypatch
    ):
        """FIX 4 — swap-ok-but-reopen-fails corner: after os.replace, db_path holds
        verified-good backup bytes even though the subsequent _try_open(db_path) fails.

        Discriminates the invariant:
        - _try_open(tmp) (pre-replace) SUCCEEDS → tmp is verified good.
        - os.replace(tmp, db_path) runs → db_path now contains backup bytes.
        - _try_open(db_path) (post-replace) returns None or raises → loop continues.
        - After all candidates exhausted, RecoveryError is raised.
        - db_path holds the verified backup bytes, NOT the original corrupt bytes.

        This documents and locks the intended behavior: a swap that occurred but
        whose post-replace reopen failed leaves db_path strictly better than before
        (verified backup vs corrupt original).
        """
        db = tmp_path / "memory.db"
        key = "a" * 64

        corrupt_bytes = b"\xff" * 4096
        db.write_bytes(corrupt_bytes)

        # Healthy backup with distinct content.
        healthy_bak = tmp_path / "memory.db.swap-reopen.bak"
        c = sqlcipher3.connect(str(healthy_bak), check_same_thread=False, isolation_level=None)
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("CREATE TABLE t (v TEXT)")
        c.execute("INSERT INTO t VALUES ('swap-corner-case')")
        c.close()

        # Capture backup bytes so we can assert db_path ends up holding them.
        backup_bytes = Path(str(healthy_bak)).read_bytes()

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        real_try_open = store._try_open
        calls: list[str] = []

        def _selective_try_open(path, k):
            p = str(path)
            calls.append(p)
            # Temp open (pre-replace) succeeds — backup is verified good.
            if ".restore-tmp-" in p:
                return real_try_open(path, k)
            # Live db_path open (step 2 WAL reset AND post-replace) returns None
            # — simulates a transient lock or delayed fsync after swap.
            if p == str(db):
                return None
            return real_try_open(path, k)

        monkeypatch.setattr(store, "_try_open", _selective_try_open)

        with pytest.raises(store.RecoveryError):
            store._repair_corrupt_db(db, key)

        # db_path must now hold the verified backup bytes, not the original corrupt bytes.
        assert db.exists(), "db_path must exist after swap"
        assert db.read_bytes() != corrupt_bytes, (
            "db_path still holds corrupt bytes — os.replace did not run"
        )
        assert db.read_bytes() == backup_bytes, (
            "db_path does not hold the verified backup bytes after swap-ok-reopen-fail"
        )

        # No temp file must linger.
        leftover = list(tmp_path.glob("memory.db.restore-tmp-*"))
        assert leftover == [], f"restore temp file(s) left behind: {leftover}"

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


# ──────────────────────────────────────────────────────────────────────────────
# LAYER 4 — RecoveryError propagation (daemon loudness)
# ──────────────────────────────────────────────────────────────────────────────


class TestRecoveryErrorLoudness:
    """ConversationMemory must NOT swallow RecoveryError silently.

    When init_db raises RecoveryError it means recoverable data exists but
    restore failed — the daemon must fail loudly rather than run amnesiac.
    """

    def test_init_reraises_recovery_error_not_silent_degrade(self, monkeypatch):
        """__init__ must propagate RecoveryError, NOT return degraded=True.

        RED discriminator:
        - OLD: except Exception catches RecoveryError → sets degraded=True, returns object.
        - NEW: except RecoveryError clause re-raises → ConversationMemory() raises.
        """
        from axi.store import RecoveryError

        def _raise_recovery():
            raise RecoveryError("healthy backup exists but every restore failed")

        monkeypatch.setattr("axi.memory.store.init_db", _raise_recovery)

        with pytest.raises(RecoveryError):
            ConversationMemory()

    def test_init_fires_critical_log_on_recovery_error(self, monkeypatch, caplog):
        """__init__ must emit a CRITICAL log (not WARNING) when RecoveryError is raised.

        RED discriminator:
        - OLD: logs at WARNING level via the broad except Exception clause.
        - NEW: logs at CRITICAL level in the specific except RecoveryError clause
               before re-raising.
        """
        import logging
        from axi.store import RecoveryError

        def _raise_recovery():
            raise RecoveryError("healthy backup exists but every restore failed")

        monkeypatch.setattr("axi.memory.store.init_db", _raise_recovery)

        with caplog.at_level(logging.CRITICAL, logger="axi.memory"):
            with pytest.raises(RecoveryError):
                ConversationMemory()

        critical_records = [r for r in caplog.records if r.levelno == logging.CRITICAL]
        assert critical_records, "Expected at least one CRITICAL log record from axi.memory"

    def test_init_fires_notification_on_recovery_error(self, monkeypatch):
        """__init__ must call notify() (best-effort desktop alert) on RecoveryError.

        RED discriminator:
        - OLD: notify() is never called because the error is silently swallowed.
        - NEW: notify() is called in the except RecoveryError clause before re-raising.
        """
        from axi.store import RecoveryError

        notify_calls = []

        def _raise_recovery():
            raise RecoveryError("healthy backup exists but every restore failed")

        monkeypatch.setattr("axi.memory.store.init_db", _raise_recovery)
        monkeypatch.setattr("axi.memory.notify", lambda *a, **kw: notify_calls.append((a, kw)))

        with pytest.raises(RecoveryError):
            ConversationMemory()

        assert notify_calls, "notify() must be called when RecoveryError is raised in __init__"

    def test_generic_exception_still_degrades_gracefully(self, monkeypatch):
        """Non-RecoveryError exceptions must still set degraded=True without raising.

        Ensures the existing contract for transient/unknown DB errors is preserved.

        RED discriminator: this test must pass both before and after the fix —
        it guards against over-catching that breaks the graceful-degradation path.
        """
        import sqlcipher3

        def _raise_db_error():
            raise sqlcipher3.dbapi2.DatabaseError("database disk image is malformed")

        monkeypatch.setattr("axi.memory.store.init_db", _raise_db_error)

        mem = ConversationMemory()  # must NOT raise
        assert mem.degraded is True

    def test_add_logs_critical_and_notifies_on_recovery_error(self, monkeypatch, caplog):
        """add() must log CRITICAL + call notify() when store raises RecoveryError.

        Returns (0, 0) safe default — must NOT crash mid-conversation.

        RED discriminator:
        - OLD: except Exception logs WARNING only, no notification.
        - NEW: except RecoveryError logs CRITICAL + calls notify() before returning (0, 0).
        """
        import logging
        from axi.store import RecoveryError

        notify_calls = []

        raising_store = _RaisingStore(exc=RecoveryError("runtime recovery error"))
        monkeypatch.setattr("axi.memory.store", raising_store)
        monkeypatch.setattr("axi.memory.notify", lambda *a, **kw: notify_calls.append((a, kw)))

        mem = ConversationMemory.__new__(ConversationMemory)
        mem.max_context_turns = 20

        with caplog.at_level(logging.CRITICAL, logger="axi.memory"):
            result = mem.add("hola", "respuesta")

        assert result == (0, 0), "add() must return (0, 0) safe default"
        critical_records = [r for r in caplog.records if r.levelno == logging.CRITICAL]
        assert critical_records, "add() must emit CRITICAL log on RecoveryError"
        assert notify_calls, "add() must call notify() on RecoveryError"


# ──────────────────────────────────────────────────────────────────────────────
# LAYER 5 — Inter-process flock serialization (recovery-serialize-flock)
# ──────────────────────────────────────────────────────────────────────────────


class TestRecoveryFlockSerialization:
    """_repair_corrupt_db must serialize across processes via flock + re-check.

    Prevents a cascade where multiple processes each detect a transient disk I/O
    error and independently run their own destructive recovery — last-writer-wins
    os.replace, repeated RecoveryErrors → API 500s.

    Design:
    - _recovery_lock(db_path): context-manager that acquires LOCK_EX flock on
      Path(str(db_path) + ".recovery.lock"). Best-effort: never raises.
    - _repair_corrupt_db: wraps its body in `with _recovery_lock(db_path):`; after
      acquiring, immediately re-checks via _try_open. If the DB is already healthy
      (another process recovered it), returns the connection without running Step 1.
    """

    def test_recheck_skips_recovery_when_db_already_healthy(self, tmp_path, monkeypatch):
        """RED: if _try_open succeeds after the lock is acquired (another process
        already recovered), _repair_corrupt_db MUST return that connection and
        MUST NOT execute Step 1 (shutil.copy2 backup write).

        Discriminates old vs new:
        - OLD: no re-check → always runs Step 1 → shutil.copy2 is called.
        - NEW: re-check succeeds → returns early → shutil.copy2 never called.
        """
        import shutil as _shutil

        db = tmp_path / "memory.db"
        key = "a" * 64

        # Main file is garbage (so _open_new_connection would have raised).
        db.write_bytes(b"\xff" * 4096)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        # Build a healthy connection that the re-check will return.
        healthy_db = tmp_path / "healthy.db"
        c = sqlcipher3.connect(str(healthy_db), check_same_thread=False, isolation_level=None)
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        c.execute("CREATE TABLE t (v TEXT)")
        c.execute("INSERT INTO t VALUES ('already-recovered')")

        # Track shutil.copy2 calls so we can assert Step 1 was NOT reached.
        copy2_calls: list = []
        real_copy2 = _shutil.copy2

        def _tracking_copy2(src, dst, **kw):
            copy2_calls.append((src, dst))
            return real_copy2(src, dst, **kw)

        monkeypatch.setattr(_shutil, "copy2", _tracking_copy2)

        # After _recovery_lock is acquired, the re-check _try_open must succeed.
        # Simulate: the real _try_open returns None on db (it's garbage), but we
        # patch _try_open to return our healthy connection on the SECOND call
        # (the re-check inside the lock) so the re-check path is exercised.
        real_try_open = store._try_open
        call_count = {"n": 0}

        def _patched_try_open(path, k):
            call_count["n"] += 1
            # The re-check is the FIRST _try_open call inside _repair_corrupt_db_locked.
            # Return the healthy connection on any call on db_path to simulate
            # "another process already recovered while we waited for the lock."
            if str(path) == str(db):
                return c
            return real_try_open(path, k)

        monkeypatch.setattr(store, "_try_open", _patched_try_open)

        # _repair_corrupt_db is called directly (as _open_new_connection does).
        result = store._repair_corrupt_db(db, key)

        # Must return the healthy connection from the re-check.
        assert result is c, (
            "_repair_corrupt_db must return the re-check connection when DB is already healthy"
        )
        # Step 1 (backup via shutil.copy2) must NOT have run.
        assert copy2_calls == [], (
            f"shutil.copy2 was called {len(copy2_calls)} time(s) — "
            "Step 1 must be skipped when the re-check finds the DB already healthy"
        )

    def test_recovery_still_runs_when_recheck_fails(self, tmp_path, monkeypatch):
        """Re-check returns None → existing ladder (Step 1-4) still executes.
        Regression guard: the flock+re-check must not prevent real recovery.

        Setup: main file is healthy (WAL-only corruption) — Step 2 (WAL reset) recovers it.
        The re-check is patched to return None on the FIRST _try_open call on db
        (simulating the pre-lock check that triggered _repair_corrupt_db), so the
        ladder enters. Then the real _try_open is used for Step 2's WAL-reset check.
        """
        db = tmp_path / "memory.db"
        key = "a" * 64

        # Build a valid encrypted DB.
        c_good = sqlcipher3.connect(str(db), check_same_thread=False, isolation_level=None)
        c_good.execute(f"PRAGMA key = \"x'{key}'\"")
        c_good.execute("CREATE TABLE nodes (id INTEGER PRIMARY KEY, label TEXT)")
        c_good.execute("INSERT INTO nodes (label) VALUES ('flock-guard')")
        c_good.close()

        # Write garbage WAL so the step-2 WAL-reset is needed and succeeds.
        Path(str(db) + "-wal").write_bytes(b"\xff" * 512)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        # First _try_open call returns None → triggers _repair_corrupt_db.
        # Subsequent calls (inside the re-check and Step 2) use the real function.
        real_try_open = store._try_open
        call_count = {"n": 0}

        def _first_call_fails(path, k):
            call_count["n"] += 1
            if call_count["n"] == 1 and str(path) == str(db):
                # Re-check inside lock also returns None → ladder must run.
                return None
            return real_try_open(path, k)

        monkeypatch.setattr(store, "_try_open", _first_call_fails)

        conn = store._repair_corrupt_db(db, key)
        assert conn is not None, "recovery ladder must still succeed when re-check fails"
        rows = conn.execute("SELECT label FROM nodes ORDER BY id").fetchall()
        assert [r[0] for r in rows] == ["flock-guard"], (
            "recovery must restore data from healthy backup when re-check fails"
        )

    def test_lock_best_effort_does_not_deadlock_when_flock_fails(
        self, tmp_path, monkeypatch
    ):
        """If _recovery_lock cannot acquire the flock (e.g. fcntl unavailable,
        timeout, or OSError), _repair_corrupt_db must still proceed and recover.
        Never hangs or raises from the lock itself.

        Simulate by patching fcntl.flock to always raise OSError.
        """
        import fcntl as _fcntl

        db = tmp_path / "memory.db"
        key = "a" * 64

        # DB is healthy on disk (WAL-only corruption simulation: main file is good,
        # WAL is garbage). Step 2 (WAL reset) will succeed.
        c_healthy = sqlcipher3.connect(str(db), check_same_thread=False, isolation_level=None)
        c_healthy.execute(f"PRAGMA key = \"x'{key}'\"")
        c_healthy.execute("CREATE TABLE t (v TEXT)")
        c_healthy.close()

        # Write garbage WAL so recovery is actually triggered.
        Path(str(db) + "-wal").write_bytes(b"\xff" * 512)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        # Make flock always fail.
        def _failing_flock(fd, op):
            raise OSError("simulated flock failure")

        monkeypatch.setattr(_fcntl, "flock", _failing_flock)

        # Must NOT raise from the lock; must still recover.
        # With flock unavailable, _recovery_lock yields without a lock and
        # _repair_corrupt_db_locked runs normally.  The re-check removes the
        # garbage WAL and _try_open succeeds on the healthy main DB, so recovery
        # returns via the re-check skip path (not Step 2).
        conn = store._repair_corrupt_db(db, key)
        assert conn is not None, (
            "_repair_corrupt_db must succeed even when flock raises — lock is best-effort"
        )

    def test_recovery_lock_acquires_and_releases(self, tmp_path):
        """_recovery_lock context manager acquires LOCK_EX flock on enter and
        releases it on exit (lock file is visible during and released after).

        After the with-block exits, a non-blocking flock on the same file must
        succeed — proving the first lock was released.
        """
        import fcntl as _fcntl

        db = tmp_path / "memory.db"
        lock_path = Path(str(db) + ".recovery.lock")

        # Enter the context: lock must be held.
        with store._recovery_lock(db):
            # Lock file must exist while the context is active.
            assert lock_path.exists(), "lock file must be created by _recovery_lock"
            # Attempting a non-blocking exclusive lock from the SAME process on the
            # same fd would succeed (flock is per open-file-description, not per-fd),
            # so we verify the lock file exists and is non-empty path as a proxy.
            # (Testing that another process would block requires a subprocess.)

        # After exit, a fresh non-blocking LOCK_EX must succeed (lock was released).
        fd = lock_path.open("r")
        try:
            # LOCK_EX | LOCK_NB: if still locked this would raise BlockingIOError.
            _fcntl.flock(fd.fileno(), _fcntl.LOCK_EX | _fcntl.LOCK_NB)
            _fcntl.flock(fd.fileno(), _fcntl.LOCK_UN)
        finally:
            fd.close()
