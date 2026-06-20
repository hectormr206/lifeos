"""Slice 3 TDD tests — DB corruption events + FastAPI global 500 handler.

Coverage:
- 3.1  store._repair_corrupt_db emits events.log_critical on detection
- 3.2  recovery step: backup made → emits event
- 3.3  recovery step: WAL reset succeeded → emits event
- 3.4  recovery step: WAL reset failed → emits event
- 3.5  recovery step: restore from backup → emits event
- 3.6  recovery step: fresh-schema fallback → emits event
- 3.7  if events.log_* itself raises, recovery still completes (no propagation)
- 3.8  store.checkpoint failure emits events.log_warning
- 3.9  dashboard global 500 handler: unhandled Exception → api.500 event + re-raise (TestClient gets 500)
- 3.10 dashboard global 500 handler: HTTPException is NOT caught as api.500
- 3.11 dashboard 500 handler: even when events.log_error itself raises, re-raise still happens
"""
from __future__ import annotations

import importlib
import os
import subprocess
import sys
import threading
from pathlib import Path
from unittest.mock import MagicMock, call, patch

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_db_path(tmp_path: Path) -> Path:
    """Return a path to a (non-existent) DB in tmp_path."""
    return tmp_path / "memory.db"


# ---------------------------------------------------------------------------
# 3.1 RED — _repair_corrupt_db emits log_critical on detection
# ---------------------------------------------------------------------------


def test_repair_corrupt_db_emits_log_critical_on_detection(tmp_path, monkeypatch):
    """When _repair_corrupt_db is called the first event emitted is a
    log_critical with source='store.corruption' and a message describing the
    corrupt DB path.
    """
    from axi import events, store

    db_path = _make_db_path(tmp_path)
    key = "deadbeef" * 8  # 64 hex chars

    emitted = []
    monkeypatch.setattr(events, "log_critical", lambda source, msg, data=None: emitted.append(("critical", source, msg, data)))
    # Also stub the rest of events so they don't fail
    monkeypatch.setattr(events, "log_warning", lambda *a, **kw: None)
    monkeypatch.setattr(events, "log_error", lambda *a, **kw: None)
    monkeypatch.setattr(events, "log_info", lambda *a, **kw: None)

    # Stub _try_open to simulate that WAL reset succeeds (so recovery finishes fast)
    conn_stub = MagicMock()
    conn_stub.execute.return_value = MagicMock()
    conn_stub.execute.return_value.fetchone.return_value = (1,)
    monkeypatch.setattr(store, "_try_open", lambda *a, **kw: conn_stub)

    store._repair_corrupt_db(db_path, key)

    # The FIRST event must be log_critical about the detection
    assert len(emitted) >= 1
    first = emitted[0]
    assert first[0] == "critical"
    assert first[1] == "store.corruption"
    # message should mention the db path or 'corrupt'
    assert "corrupt" in first[2].lower() or str(db_path.name) in first[2]


# ---------------------------------------------------------------------------
# 3.2 RED — backup-made step emits an event
# ---------------------------------------------------------------------------


def test_repair_corrupt_db_emits_event_after_backup(tmp_path, monkeypatch):
    """After writing the corrupt-backup, an event is emitted confirming the
    backup was created (or that it failed to be created).
    """
    from axi import events, store

    db_path = _make_db_path(tmp_path)
    # Create a real DB file so the backup copy succeeds
    db_path.write_bytes(b"not a real db")
    key = "deadbeef" * 8

    emitted = []
    monkeypatch.setattr(events, "log_critical", lambda *a, **kw: emitted.append(("critical",) + a))
    monkeypatch.setattr(events, "log_warning", lambda *a, **kw: emitted.append(("warning",) + a))
    monkeypatch.setattr(events, "log_error", lambda *a, **kw: emitted.append(("error",) + a))
    monkeypatch.setattr(events, "log_info", lambda *a, **kw: emitted.append(("info",) + a))

    conn_stub = MagicMock()
    conn_stub.execute.return_value = MagicMock()
    conn_stub.execute.return_value.fetchone.return_value = (1,)
    monkeypatch.setattr(store, "_try_open", lambda *a, **kw: conn_stub)

    store._repair_corrupt_db(db_path, key)

    sources = [e[2] for e in emitted if len(e) > 2]
    # Some event should reference backup / corruption
    backup_events = [e for e in emitted if "backup" in str(e).lower() or "corrupt" in str(e).lower()]
    assert len(backup_events) >= 1


# ---------------------------------------------------------------------------
# 3.3 RED — WAL reset success emits an event
# ---------------------------------------------------------------------------


def test_repair_corrupt_db_emits_event_on_wal_reset_success(tmp_path, monkeypatch):
    """When WAL reset (step 2) succeeds, an event is emitted confirming
    recovery via WAL reset.
    """
    import sqlcipher3
    from axi import events, store

    db_path = _make_db_path(tmp_path)
    key = "deadbeef" * 8

    emitted = []
    monkeypatch.setattr(events, "log_critical", lambda *a, **kw: emitted.append(("critical",) + a))
    monkeypatch.setattr(events, "log_warning", lambda *a, **kw: emitted.append(("warning",) + a))
    monkeypatch.setattr(events, "log_error", lambda *a, **kw: emitted.append(("error",) + a))
    monkeypatch.setattr(events, "log_info", lambda *a, **kw: emitted.append(("info",) + a))

    # _try_open succeeds on the WAL-reset attempt (step 2)
    conn_stub = MagicMock()
    conn_stub.execute.return_value = MagicMock()
    conn_stub.execute.return_value.fetchone.return_value = (1,)
    monkeypatch.setattr(store, "_try_open", lambda *a, **kw: conn_stub)

    store._repair_corrupt_db(db_path, key)

    # An event mentioning "WAL" and success should appear
    all_text = " ".join(str(e) for e in emitted).lower()
    assert "wal" in all_text


# ---------------------------------------------------------------------------
# 3.4 RED — WAL reset failure emits an event then continues
# ---------------------------------------------------------------------------


def test_repair_corrupt_db_emits_event_on_wal_reset_failure(tmp_path, monkeypatch):
    """When WAL reset fails (step 2 raises DatabaseError), an event is emitted
    about the failure and recovery continues to step 3.
    """
    import sqlcipher3
    from axi import events, store

    db_path = _make_db_path(tmp_path)
    key = "deadbeef" * 8

    emitted = []
    monkeypatch.setattr(events, "log_critical", lambda *a, **kw: emitted.append(("critical",) + a))
    monkeypatch.setattr(events, "log_warning", lambda *a, **kw: emitted.append(("warning",) + a))
    monkeypatch.setattr(events, "log_error", lambda *a, **kw: emitted.append(("error",) + a))
    monkeypatch.setattr(events, "log_info", lambda *a, **kw: emitted.append(("info",) + a))

    call_count = [0]

    def _try_open_fail_first(path, key_hex):
        call_count[0] += 1
        if call_count[0] == 1:
            raise sqlcipher3.dbapi2.DatabaseError("file is not a database")
        return None  # subsequent calls return None → skip backup candidates

    monkeypatch.setattr(store, "_try_open", _try_open_fail_first)

    # Step 4 needs sqlcipher3.connect to work — stub it
    fake_conn = MagicMock()
    fake_conn.execute.return_value = MagicMock()
    monkeypatch.setattr("sqlcipher3.connect", lambda *a, **kw: fake_conn)

    store._repair_corrupt_db(db_path, key)

    all_text = " ".join(str(e) for e in emitted).lower()
    # Must mention WAL failure and continue to fresh schema
    assert "wal" in all_text or "backup" in all_text


# ---------------------------------------------------------------------------
# 3.5 RED — restore from backup emits an event
# ---------------------------------------------------------------------------


def test_repair_corrupt_db_emits_event_on_backup_restore(tmp_path, monkeypatch):
    """When a clean backup is successfully restored (step 3), an event is emitted
    confirming restoration from the specific backup file.
    """
    import sqlcipher3
    from axi import events, store

    # Create the "corrupt" DB file
    db_path = tmp_path / "memory.db"
    db_path.write_bytes(b"corrupt data")
    key = "deadbeef" * 8

    # Create a valid-looking backup file (not .corrupt-)
    bak = tmp_path / "memory.db.bak"
    bak.write_bytes(b"backup data")

    emitted = []
    monkeypatch.setattr(events, "log_critical", lambda *a, **kw: emitted.append(("critical",) + a))
    monkeypatch.setattr(events, "log_warning", lambda *a, **kw: emitted.append(("warning",) + a))
    monkeypatch.setattr(events, "log_error", lambda *a, **kw: emitted.append(("error",) + a))
    monkeypatch.setattr(events, "log_info", lambda *a, **kw: emitted.append(("info",) + a))

    conn_stub = MagicMock()
    conn_stub.execute.return_value = MagicMock()
    conn_stub.execute.return_value.fetchone.return_value = (1,)

    call_count = [0]

    def _try_open_step3(path, key_hex):
        call_count[0] += 1
        if call_count[0] == 1:
            # WAL reset fails
            raise sqlcipher3.dbapi2.DatabaseError("file is not a database")
        # Backup restore attempt succeeds
        return conn_stub

    monkeypatch.setattr(store, "_try_open", _try_open_step3)

    store._repair_corrupt_db(db_path, key)

    all_text = " ".join(str(e) for e in emitted).lower()
    # Should mention restore / backup
    assert "backup" in all_text or "restor" in all_text


# ---------------------------------------------------------------------------
# 3.6 RED — fresh-schema fallback emits an event
# ---------------------------------------------------------------------------


def test_repair_corrupt_db_emits_event_on_fresh_schema_fallback(tmp_path, monkeypatch):
    """When no clean backup is found (step 4), an event is emitted about
    building a fresh empty schema.
    """
    import sqlcipher3
    from axi import events, store

    db_path = _make_db_path(tmp_path)
    key = "deadbeef" * 8

    emitted = []
    monkeypatch.setattr(events, "log_critical", lambda *a, **kw: emitted.append(("critical",) + a))
    monkeypatch.setattr(events, "log_warning", lambda *a, **kw: emitted.append(("warning",) + a))
    monkeypatch.setattr(events, "log_error", lambda *a, **kw: emitted.append(("error",) + a))
    monkeypatch.setattr(events, "log_info", lambda *a, **kw: emitted.append(("info",) + a))

    def _try_open_always_fail(path, key_hex):
        raise sqlcipher3.dbapi2.DatabaseError("file is not a database")

    monkeypatch.setattr(store, "_try_open", _try_open_always_fail)

    fake_conn = MagicMock()
    fake_conn.execute.return_value = MagicMock()
    monkeypatch.setattr("sqlcipher3.connect", lambda *a, **kw: fake_conn)

    store._repair_corrupt_db(db_path, key)

    all_text = " ".join(str(e) for e in emitted).lower()
    assert "fresh" in all_text or "empty" in all_text or "schema" in all_text or "rebuild" in all_text


# ---------------------------------------------------------------------------
# 3.7 RED — if events.log_* raises, recovery still completes
# ---------------------------------------------------------------------------


def test_repair_corrupt_db_events_failure_does_not_abort_recovery(tmp_path, monkeypatch):
    """If events.log_critical/log_warning itself raises an exception, recovery
    must still complete normally (no exception propagates from _repair_corrupt_db).
    """
    from axi import events, store

    db_path = _make_db_path(tmp_path)
    key = "deadbeef" * 8

    def _exploding_log(*args, **kwargs):
        raise RuntimeError("events system is down")

    monkeypatch.setattr(events, "log_critical", _exploding_log)
    monkeypatch.setattr(events, "log_warning", _exploding_log)
    monkeypatch.setattr(events, "log_error", _exploding_log)
    monkeypatch.setattr(events, "log_info", _exploding_log)

    conn_stub = MagicMock()
    conn_stub.execute.return_value = MagicMock()
    conn_stub.execute.return_value.fetchone.return_value = (1,)
    monkeypatch.setattr(store, "_try_open", lambda *a, **kw: conn_stub)

    # Must NOT raise even though all event calls explode
    conn = store._repair_corrupt_db(db_path, key)
    assert conn is conn_stub


# ---------------------------------------------------------------------------
# 3.8 RED — checkpoint failure emits events.log_warning
# ---------------------------------------------------------------------------


def test_checkpoint_failure_emits_log_warning(monkeypatch):
    """When store.checkpoint() catches an exception from wal_checkpoint,
    it calls events.log_warning with source='store.checkpoint'.
    """
    from axi import events, store

    emitted = []
    monkeypatch.setattr(events, "log_warning", lambda source, msg, data=None: emitted.append((source, msg, data)))

    def _bad_connect():
        conn = MagicMock()
        conn.execute.side_effect = Exception("disk I/O error")
        return conn

    monkeypatch.setattr(store, "_connect", _bad_connect)

    store.checkpoint()

    assert len(emitted) == 1
    assert emitted[0][0] == "store.checkpoint"
    assert "checkpoint" in emitted[0][1].lower() or "wal" in emitted[0][1].lower()


# ---------------------------------------------------------------------------
# 3.9 RED — global 500 handler records event AND re-raises (TestClient gets 500)
# ---------------------------------------------------------------------------


def test_dashboard_500_handler_emits_event_and_reraises(monkeypatch):
    """A route that raises an unhandled Exception must:
    1. emit events.log_error with source='api.500'
    2. re-raise so the TestClient still gets HTTP 500.
    """
    from axi import events
    import axi.dashboard as dashboard_mod

    emitted = []
    monkeypatch.setattr(events, "log_error", lambda source, msg, data=None: emitted.append((source, msg, data)))

    from fastapi.testclient import TestClient

    # Add a route that raises an unhandled exception
    @dashboard_mod.app.get("/_test_500_handler")
    async def _boom():
        raise RuntimeError("intentional test error")

    with TestClient(dashboard_mod.app, raise_server_exceptions=False) as client:
        r = client.get("/_test_500_handler")

    assert r.status_code == 500
    assert any(e[0] == "api.500" for e in emitted), f"Expected api.500 event; got {emitted}"


# ---------------------------------------------------------------------------
# 3.10 RED — HTTPException is NOT caught by the global 500 handler
# ---------------------------------------------------------------------------


def test_dashboard_500_handler_does_not_catch_http_exception(monkeypatch):
    """An HTTPException (e.g. 404) must NOT produce an api.500 event — it is
    handled normally by FastAPI's default HTTPException handler.
    """
    from axi import events
    import axi.dashboard as dashboard_mod
    from fastapi import HTTPException

    emitted = []
    monkeypatch.setattr(events, "log_error", lambda source, msg, data=None: emitted.append((source, msg, data)))

    @dashboard_mod.app.get("/_test_http_exception")
    async def _raise_http():
        raise HTTPException(status_code=404, detail="not found")

    from fastapi.testclient import TestClient
    with TestClient(dashboard_mod.app, raise_server_exceptions=False) as client:
        r = client.get("/_test_http_exception")

    assert r.status_code == 404
    api500_events = [e for e in emitted if e[0] == "api.500"]
    assert api500_events == [], f"HTTPException must not produce api.500 events; got {api500_events}"


# ---------------------------------------------------------------------------
# 3.11 RED — 500 handler re-raises even when events.log_error itself fails
# ---------------------------------------------------------------------------


def test_dashboard_500_handler_reraises_even_when_events_fail(monkeypatch):
    """Even if events.log_error raises internally, the exception handler
    must still re-raise the original exception (not swallow it silently,
    which would produce a 200 or an incorrect response).
    """
    from axi import events
    import axi.dashboard as dashboard_mod

    def _exploding_log_error(*a, **kw):
        raise RuntimeError("events system down")

    monkeypatch.setattr(events, "log_error", _exploding_log_error)

    @dashboard_mod.app.get("/_test_500_events_fail")
    async def _boom_events_fail():
        raise ValueError("original error")

    from fastapi.testclient import TestClient
    with TestClient(dashboard_mod.app, raise_server_exceptions=False) as client:
        r = client.get("/_test_500_events_fail")

    # The server must still return 500, not 200 or any other code
    assert r.status_code == 500
