"""Tests for SQLCipher self-healing recovery and healthy-backup rotation.

Covers:
  - Malformed-during-operation triggers attempt_self_heal()
  - Failed self-heal degrades the ConversationMemory instance
  - do_healthy_backup() rotation keeps at most 3 backup slots
  - _repair_corrupt_db_locked prefers healthy-N.bak over other candidates
"""
from __future__ import annotations

import shutil
from pathlib import Path
from unittest.mock import MagicMock

import pytest
import sqlcipher3

from axi import store
from axi.memory import ConversationMemory


# ─────────────────────────── helpers ─────────────────────────────────────────


def _make_encrypted_db(path: Path, key: str, *, table: str = "t", rows=()) -> None:
    """Create a minimal valid SQLCipher DB at *path* with *key*."""
    c = sqlcipher3.connect(str(path), isolation_level=None)
    c.execute(f"PRAGMA key = \"x'{key}'\"")
    c.execute(f"CREATE TABLE IF NOT EXISTS {table} (v TEXT)")
    for v in rows:
        c.execute(f"INSERT INTO {table} VALUES (?)", (v,))
    c.close()


# ─────────────────── Task B: self-heal triggered on malformed error ───────────


class TestMalformedDuringOperationTriggersRecovery:
    """When messages() catches a corruption error, attempt_self_heal is called."""

    def test_malformed_during_operation_triggers_recovery(self, monkeypatch):
        """When a cheap reset can't fix it, messages() escalates to
        attempt_self_heal() and, on success, RETRIES so the read completes."""
        heal_calls: list[bool] = []

        def _fake_heal():
            heal_calls.append(True)
            return True  # recovery succeeded

        # Reset rung can't fix it → escalate to the heavy ladder.
        monkeypatch.setattr(store, "reset_connection", lambda: False)
        monkeypatch.setattr(store, "attempt_self_heal", _fake_heal)

        # Throw on the first read; after self-heal the retry succeeds.
        calls = {"n": 0}
        def _recent(*a, **kw):
            calls["n"] += 1
            if calls["n"] == 1:
                raise sqlcipher3.dbapi2.OperationalError("database disk image is malformed")
            return []
        monkeypatch.setattr(store, "recent_conversations", _recent)

        mem = ConversationMemory.__new__(ConversationMemory)
        mem.max_context_turns = 20
        mem._self_healed = False
        mem.degraded = False

        result = mem.messages()

        assert result == [], "messages() must return [] after recovery"
        assert len(heal_calls) == 1, "attempt_self_heal must be called exactly once"
        assert calls["n"] == 2, "the read must be retried after self-heal"
        assert mem.degraded is False, (
            "degraded must NOT be set when self-heal + retry succeed"
        )

    def test_malformed_recovery_degrades_on_second_failure(self, monkeypatch):
        """When both the reset and self-heal fail, the store ends up degraded."""
        heal_calls: list[bool] = []

        def _failing_heal():
            heal_calls.append(True)
            return False  # recovery failed

        monkeypatch.setattr(store, "reset_connection", lambda: False)
        monkeypatch.setattr(store, "attempt_self_heal", _failing_heal)
        monkeypatch.setattr(
            store,
            "recent_conversations",
            lambda *a, **kw: (_ for _ in ()).throw(
                sqlcipher3.dbapi2.OperationalError("database disk image is malformed")
            ),
        )

        mem = ConversationMemory.__new__(ConversationMemory)
        mem.max_context_turns = 20
        mem._self_healed = False
        mem.degraded = False

        mem.messages()

        assert len(heal_calls) == 1, "attempt_self_heal called exactly once (no loop)"
        assert mem.degraded is True, "degraded must be True when self-heal fails"

    def test_no_infinite_loop_second_call_skips_heal(self, monkeypatch):
        """Second messages() call after a failed heal must NOT retry self-heal."""
        heal_calls: list[bool] = []

        def _failing_heal():
            heal_calls.append(True)
            return False

        monkeypatch.setattr(store, "attempt_self_heal", _failing_heal)
        monkeypatch.setattr(
            store,
            "recent_conversations",
            lambda *a, **kw: (_ for _ in ()).throw(
                sqlcipher3.dbapi2.OperationalError("database disk image is malformed")
            ),
        )

        mem = ConversationMemory.__new__(ConversationMemory)
        mem.max_context_turns = 20
        mem._self_healed = False
        mem.degraded = False

        mem.messages()  # first call: heals (fails), sets _self_healed
        mem.messages()  # second call: must NOT call attempt_self_heal again

        assert len(heal_calls) == 1, (
            "attempt_self_heal must be called at most once per ConversationMemory instance"
        )


# ─────────────── Task C: healthy backup rotation ─────────────────────────────


class TestHealthyBackupRotation:
    """do_healthy_backup() must rotate slots and keep at most 3 files."""

    def test_creates_slot1_on_first_call(self, tmp_path, monkeypatch):
        """First call: memory.db.healthy-1.bak must be created."""
        db = tmp_path / "memory.db"
        key = "a" * 64
        _make_encrypted_db(db, key)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "load_key", lambda: key)

        store.do_healthy_backup(db)

        slot1 = tmp_path / "memory.db.healthy-1.bak"
        assert slot1.exists(), "healthy-1.bak must exist after first backup"

    def test_rotates_on_second_call(self, tmp_path, monkeypatch):
        """Second call: healthy-1.bak → healthy-2.bak, new healthy-1.bak created."""
        db = tmp_path / "memory.db"
        key = "a" * 64
        _make_encrypted_db(db, key)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "load_key", lambda: key)

        store.do_healthy_backup(db)
        slot1_mtime_after_first = (tmp_path / "memory.db.healthy-1.bak").stat().st_mtime

        store.do_healthy_backup(db)

        slot1 = tmp_path / "memory.db.healthy-1.bak"
        slot2 = tmp_path / "memory.db.healthy-2.bak"
        assert slot1.exists(), "healthy-1.bak must exist after second backup"
        assert slot2.exists(), "healthy-2.bak must exist after second backup (rotated)"

    def test_at_most_three_slots_after_four_calls(self, tmp_path, monkeypatch):
        """After 4 calls, at most 3 .healthy-N.bak files must exist."""
        db = tmp_path / "memory.db"
        key = "a" * 64
        _make_encrypted_db(db, key)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "load_key", lambda: key)

        for _ in range(4):
            store.do_healthy_backup(db)

        bak_files = list(tmp_path.glob("memory.db.healthy-*.bak"))
        assert len(bak_files) <= 3, (
            f"Expected at most 3 healthy backup slots, found {len(bak_files)}: {bak_files}"
        )

    def test_skips_when_integrity_check_fails(self, tmp_path, monkeypatch):
        """do_healthy_backup must NOT create a backup when the DB is corrupt."""
        db = tmp_path / "memory.db"
        key = "a" * 64
        # Write garbage — integrity_check will fail
        db.write_bytes(b"\xff" * 4096)

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "load_key", lambda: key)

        store.do_healthy_backup(db)  # must not raise

        bak_files = list(tmp_path.glob("memory.db.healthy-*.bak"))
        assert bak_files == [], "No backup must be written when integrity_check fails"

    def test_is_nonfatal_on_any_error(self, tmp_path, monkeypatch):
        """do_healthy_backup must swallow all errors and never raise."""
        db = tmp_path / "memory.db"
        # DB does not exist; function must silently return
        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "load_key", lambda: "a" * 64)

        # Must not raise
        store.do_healthy_backup(db)


# ─────────────── Task C: repair prefers healthy backups ──────────────────────


class TestRepairPrefersHealthyBackup:
    """_repair_corrupt_db_locked must try healthy-N.bak before other .bak files."""

    def test_repair_prefers_healthy_slot_over_corrupt_named_backup(
        self, tmp_path, monkeypatch
    ):
        """Recovery must restore from healthy-1.bak when it exists and passes."""
        db = tmp_path / "memory.db"
        key = "a" * 64

        # Main DB is corrupt garbage
        db.write_bytes(b"\xff" * 4096)

        # healthy-1.bak has the data we want
        slot1 = tmp_path / "memory.db.healthy-1.bak"
        _make_encrypted_db(slot1, key, rows=["from-healthy-1"])

        # An older .corrupt-*.bak that also passes — should NOT be preferred
        old_bak = tmp_path / "memory.db.corrupt-99999.bak"
        _make_encrypted_db(old_bak, key, rows=["from-corrupt-bak"])
        # Make old_bak appear newer by mtime so we can confirm healthy-1 still wins
        import os, time as _time
        os.utime(str(old_bak), (_time.time() + 60, _time.time() + 60))

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        conn = store._repair_corrupt_db(db, key)
        assert conn is not None

        rows = conn.execute("SELECT v FROM t").fetchall()
        values = [r[0] for r in rows]
        assert values == ["from-healthy-1"], (
            f"Recovery must prefer healthy-1.bak; got: {values}"
        )
        conn.close()

    def test_repair_falls_back_to_slot2_when_slot1_missing(
        self, tmp_path, monkeypatch
    ):
        """When healthy-1.bak does not exist, healthy-2.bak must be used."""
        db = tmp_path / "memory.db"
        key = "a" * 64

        db.write_bytes(b"\xff" * 4096)

        # Only slot2 exists
        slot2 = tmp_path / "memory.db.healthy-2.bak"
        _make_encrypted_db(slot2, key, rows=["from-healthy-2"])

        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)

        conn = store._repair_corrupt_db(db, key)
        assert conn is not None

        rows = conn.execute("SELECT v FROM t").fetchall()
        values = [r[0] for r in rows]
        assert values == ["from-healthy-2"], (
            f"Recovery must fall back to healthy-2.bak; got: {values}"
        )
        conn.close()


# ─────────────── Connection reset (latched "deferred error") ──────────────────


class TestIsCorruptionError:
    """store.is_corruption_error classifies SQLCipher latch/corruption errors."""

    def test_detects_known_corruption_strings(self):
        for msg in (
            "hmac check failed for pgno=3",
            "database disk image is malformed",
            "error decrypting page 3 data",
            "file is not a database",
            "deferred error condition",
        ):
            assert store.is_corruption_error(Exception(msg)), msg

    def test_ignores_unrelated_errors(self):
        assert not store.is_corruption_error(Exception("no such table: foo"))
        assert not store.is_corruption_error(ValueError("bad input"))


class TestResetConnection:
    """reset_connection drops the latched thread-local connection and reopens a
    fresh one against the healthy file."""

    def test_reset_returns_true_and_connection_works(self, tmp_path, monkeypatch):
        db = tmp_path / "memory.db"
        key = "a" * 64
        _make_encrypted_db(db, key)
        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "STATE_DIR", tmp_path)
        monkeypatch.setattr(store, "load_key", lambda: key)
        import axi.db_migrate as _dbm
        monkeypatch.setattr(_dbm, "migrate_to_encrypted", lambda *a, **k: None)

        store.close()
        try:
            store._connect()  # open against the isolated db
            assert store.reset_connection() is True
            # The fresh connection still decrypts and queries.
            assert store._connect().execute("SELECT 1").fetchone()[0] == 1
        finally:
            store.close()


# ─────────── Data-loss guard: refuse to snapshot a truncated DB ───────────

def _make_db_with_conversations(path: Path, key: str, n: int) -> None:
    """Encrypted DB with a `conversations` table holding *n* rows."""
    c = sqlcipher3.connect(str(path), isolation_level=None)
    c.execute(f"PRAGMA key = \"x'{key}'\"")
    c.execute("CREATE TABLE IF NOT EXISTS conversations (id INTEGER PRIMARY KEY, user_text TEXT)")
    for i in range(n):
        c.execute("INSERT INTO conversations(user_text) VALUES (?)", (f"turn {i}",))
    c.close()


def _conv_count(path: Path, key: str) -> int:
    c = sqlcipher3.connect(str(path), isolation_level=None)
    c.execute(f"PRAGMA key = \"x'{key}'\"")
    n = c.execute("SELECT COUNT(*) FROM conversations").fetchone()[0]
    c.close()
    return n


def _truncate(db: Path, key: str, keep_max_id: int) -> None:
    c = sqlcipher3.connect(str(db), isolation_level=None)
    c.execute(f"PRAGMA key = \"x'{key}'\"")
    c.execute("DELETE FROM conversations WHERE id > ?", (keep_max_id,))
    c.close()


class TestHealthyBackupDataLossGuard:
    """do_healthy_backup must NOT overwrite good slots when rows collapse
    (a truncation that integrity_check cannot detect — the real data-loss bug)."""

    def _wire(self, tmp_path, monkeypatch, n):
        db = tmp_path / "memory.db"
        key = "a" * 64
        _make_db_with_conversations(db, key, n)
        monkeypatch.setattr(store, "DB_PATH", db)
        monkeypatch.setattr(store, "load_key", lambda: key)
        return db, key

    def test_refuses_snapshot_on_sharp_row_drop(self, tmp_path, monkeypatch):
        db, key = self._wire(tmp_path, monkeypatch, 100)
        store.do_healthy_backup(db)
        slot1 = tmp_path / "memory.db.healthy-1.bak"
        assert _conv_count(slot1, key) == 100
        _truncate(db, key, keep_max_id=3)          # 100 → 3 (data loss)
        store.do_healthy_backup(db)
        assert _conv_count(slot1, key) == 100, (
            "guard must preserve the good backup after a >50% row collapse"
        )

    def test_allows_snapshot_on_growth(self, tmp_path, monkeypatch):
        db, key = self._wire(tmp_path, monkeypatch, 50)
        store.do_healthy_backup(db)
        c = sqlcipher3.connect(str(db), isolation_level=None)
        c.execute(f"PRAGMA key = \"x'{key}'\"")
        for _ in range(10):
            c.execute("INSERT INTO conversations(user_text) VALUES ('new')")
        c.close()
        store.do_healthy_backup(db)
        assert _conv_count(tmp_path / "memory.db.healthy-1.bak", key) == 60

    def test_small_deletion_still_snapshots(self, tmp_path, monkeypatch):
        db, key = self._wire(tmp_path, monkeypatch, 100)
        store.do_healthy_backup(db)
        _truncate(db, key, keep_max_id=90)         # 100 → 90 (within tolerance)
        store.do_healthy_backup(db)
        assert _conv_count(tmp_path / "memory.db.healthy-1.bak", key) == 90
