"""Tests for /api/snapshot graceful degradation when memory.db is unavailable.

The endpoint must NEVER return HTTP 500 due to DB failures. Instead it must:
- Return HTTP 200 with all non-DB fields intact
- Return safe defaults for memory fields (counts=0, lists=[])
- Set memory.degraded=True when any DB read failed

RED criteria: `_fact_count` and `_recent_facts` currently call `store._connect()`
without a guard, so RecoveryError/DatabaseError propagates → 500.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

import sqlcipher3.dbapi2 as _sc3_dbapi


# ──────────────────────────────────────────────────────────────────
# Helpers / fixtures
# ──────────────────────────────────────────────────────────────────

def _minimal_monkeypatches(monkeypatch, dashboard):
    """Patch everything that touches external state so snapshot is stable."""
    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda *_a, **_k: "idle")
    monkeypatch.setattr(dashboard, "_llama_alive", lambda: False)
    monkeypatch.setattr(dashboard, "_service_state", lambda *_a, **_k: "active")
    monkeypatch.setattr(dashboard, "_vram_snapshot", lambda: {
        "name": "test", "used_mb": 0, "total_mb": 0, "util_pct": 0,
    })
    monkeypatch.setattr(dashboard, "_ram_snapshot", lambda: {
        "used": 0, "total": 1, "pct": 0.0,
    })
    monkeypatch.setattr(dashboard, "_cpu_pct", lambda: 0.0)


# ──────────────────────────────────────────────────────────────────
# Task 1 — /api/snapshot returns 200 even when DB raises RecoveryError
# ──────────────────────────────────────────────────────────────────

class TestSnapshotDegradeOnRecoveryError:
    """The endpoint must not propagate RecoveryError as an HTTP 500."""

    @pytest.fixture
    def client_db_recovery_error(self, monkeypatch):
        from axi import dashboard, store

        _minimal_monkeypatches(monkeypatch, dashboard)

        def _raise_recovery(*_a, **_k):
            raise store.RecoveryError("memory.db temporarily unreadable")

        # Patch store._connect so every DB-touching call explodes.
        monkeypatch.setattr(store, "_connect", _raise_recovery)
        # _safe_conversation_count calls store.conversation_count, not _connect directly.
        monkeypatch.setattr(store, "conversation_count", _raise_recovery)
        monkeypatch.setattr(store, "recent_conversations", _raise_recovery)

        return TestClient(dashboard.app)

    def test_snapshot_returns_200_on_recovery_error(self, client_db_recovery_error):
        """HTTP 200 — not 500 — when DB raises RecoveryError."""
        r = client_db_recovery_error.get("/api/snapshot")
        assert r.status_code == 200, f"Expected 200, got {r.status_code}: {r.text}"

    def test_snapshot_non_db_fields_present_on_recovery_error(self, client_db_recovery_error):
        """services, vram, ram are unaffected by the DB failure."""
        data = client_db_recovery_error.get("/api/snapshot").json()
        assert "services" in data
        assert "vram" in data
        assert "ram" in data
        assert "state" in data

    def test_snapshot_memory_degraded_true_on_recovery_error(self, client_db_recovery_error):
        """memory.degraded must be True when the DB raised."""
        data = client_db_recovery_error.get("/api/snapshot").json()
        memory = data.get("memory", {})
        assert memory.get("degraded") is True

    def test_snapshot_memory_safe_defaults_on_recovery_error(self, client_db_recovery_error):
        """conversation_turns and facts_count default to 0 on DB failure."""
        data = client_db_recovery_error.get("/api/snapshot").json()
        memory = data.get("memory", {})
        assert memory.get("conversation_turns") == 0
        assert memory.get("facts_count") == 0

    def test_snapshot_recent_lists_empty_on_recovery_error(self, client_db_recovery_error):
        """recent_conversations and recent_facts default to [] on DB failure."""
        data = client_db_recovery_error.get("/api/snapshot").json()
        assert data.get("recent_conversations") == []
        assert data.get("recent_facts") == []


# ──────────────────────────────────────────────────────────────────
# Task 2 — /api/snapshot returns 200 when DB raises DatabaseError
# ──────────────────────────────────────────────────────────────────

class TestSnapshotDegradeOnDatabaseError:
    """The endpoint must not propagate DatabaseError as an HTTP 500."""

    @pytest.fixture
    def client_db_database_error(self, monkeypatch):
        from axi import dashboard, store

        _minimal_monkeypatches(monkeypatch, dashboard)

        def _raise_db_error(*_a, **_k):
            raise _sc3_dbapi.DatabaseError("disk I/O error")

        monkeypatch.setattr(store, "_connect", _raise_db_error)
        monkeypatch.setattr(store, "conversation_count", _raise_db_error)
        monkeypatch.setattr(store, "recent_conversations", _raise_db_error)

        return TestClient(dashboard.app)

    def test_snapshot_returns_200_on_database_error(self, client_db_database_error):
        """HTTP 200 — not 500 — when DB raises DatabaseError."""
        r = client_db_database_error.get("/api/snapshot")
        assert r.status_code == 200, f"Expected 200, got {r.status_code}: {r.text}"

    def test_snapshot_memory_degraded_true_on_database_error(self, client_db_database_error):
        """memory.degraded must be True when DatabaseError was caught."""
        data = client_db_database_error.get("/api/snapshot").json()
        memory = data.get("memory", {})
        assert memory.get("degraded") is True


# ──────────────────────────────────────────────────────────────────
# Task 3 — Unit tests for individual helpers
# ──────────────────────────────────────────────────────────────────

class TestHelpersSafeDefaults:
    """_recent_facts() → [] on DB failure. (Fact-count degradation is covered at
    the snapshot level — see TestSnapshotDegradeOn* — since the inline count in
    _memory_snapshot replaced the old _fact_count helper.)"""

    def test_recent_facts_returns_empty_list_on_recovery_error(self, monkeypatch):
        """_recent_facts must return [] instead of propagating RecoveryError."""
        from axi import dashboard, store

        def _raise(): raise store.RecoveryError("db gone")
        monkeypatch.setattr(store, "_connect", _raise)
        result = dashboard._recent_facts(10)
        assert result == []

    def test_recent_facts_returns_empty_list_on_database_error(self, monkeypatch):
        """_recent_facts must return [] instead of propagating DatabaseError."""
        from axi import dashboard, store

        def _raise(): raise _sc3_dbapi.DatabaseError("disk I/O error")
        monkeypatch.setattr(store, "_connect", _raise)
        result = dashboard._recent_facts(10)
        assert result == []


# ──────────────────────────────────────────────────────────────────
# Task 4 — Happy path: DB works → real counts, degraded absent/False
# ──────────────────────────────────────────────────────────────────

class TestSnapshotHappyPath:
    """When the DB works, snapshot returns real data and memory.degraded is absent or False."""

    @pytest.fixture
    def client_db_ok(self, monkeypatch):
        from axi import dashboard, store

        _minimal_monkeypatches(monkeypatch, dashboard)

        # Stub _memory_snapshot to return known healthy values.
        monkeypatch.setattr(dashboard, "_memory_snapshot", lambda: {
            "conversation_turns": 7,
            "facts_count": 42,
        })
        monkeypatch.setattr(dashboard, "_recent_conversations", lambda n=10: [
            {"id": 1, "ts": 0, "ts_human": "now", "user": "hi", "axi": "hello", "has_screenshot": False}
        ])
        monkeypatch.setattr(dashboard, "_recent_facts", lambda n=30: [
            {"id": 1, "label": "test fact", "domain": "health", "category": None,
             "created_ts": 0, "created_human": "now", "created_tz": "UTC"}
        ])

        return TestClient(dashboard.app)

    def test_snapshot_happy_path_has_real_counts(self, client_db_ok):
        """Real counts flow through when DB is healthy."""
        data = client_db_ok.get("/api/snapshot").json()
        memory = data.get("memory", {})
        assert memory.get("facts_count") == 42
        assert memory.get("conversation_turns") == 7

    def test_snapshot_happy_path_degraded_is_false_or_absent(self, client_db_ok):
        """memory.degraded must be False or absent when DB is healthy."""
        data = client_db_ok.get("/api/snapshot").json()
        memory = data.get("memory", {})
        # Degraded flag should be absent or explicitly False.
        assert not memory.get("degraded", False)

    def test_snapshot_happy_path_recent_lists_populated(self, client_db_ok):
        """recent_conversations and recent_facts are populated when DB works."""
        data = client_db_ok.get("/api/snapshot").json()
        assert len(data.get("recent_conversations", [])) == 1
        assert len(data.get("recent_facts", [])) == 1
