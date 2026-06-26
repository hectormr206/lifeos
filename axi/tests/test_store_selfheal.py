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
        """messages() must call attempt_self_heal() on a malformed-page error."""
        heal_calls: list[bool] = []

        def _fake_heal():
            heal_calls.append(True)
            return True  # recovery succeeded

        monkeypatch.setattr(store, "attempt_self_heal", _fake_heal)
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

        result = mem.messages()

        assert result == [], "messages() must return [] after corruption"
        assert len(heal_calls) == 1, "attempt_self_heal must be called exactly once"
        assert mem.degraded is False, (
            "degraded must NOT be set when self-heal succeeds"
        )

    def test_malformed_recovery_degrades_on_second_failure(self, monkeypatch):
        """When self-heal itself fails, the store must end up in degraded state."""
        heal_calls: list[bool] = []

        def _failing_heal():
            heal_calls.append(True)
            return False  # recovery failed

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
