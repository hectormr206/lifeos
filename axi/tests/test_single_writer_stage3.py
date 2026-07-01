"""Single-writer Stage 3: tripwire, last route, daemon owner wiring.

Covers the three Stage-3 additions:

  - the observability tripwire at the top of ``store._tx()`` (throttled, no-op
    when routing is off or this process is the owner);
  - ``diarize.rename_speaker`` — the last dashboard-called writer — routing
    end-to-end through a running WriteServer;
  - the daemon owner flag: ``enable_write_owner()`` makes ``is_owner()`` True.

No models, no live servers. Mirrors test_write_router.py style. The autouse
``fresh_db`` fixture points the store at a per-test temp DB and runs init_db.
"""
from __future__ import annotations

import time

import pytest

from axi import diarize, store, write_router


# ─────────────────────────── tripwire ────────────────────────────────────────


@pytest.fixture
def _reset_tripwire():
    """Clear the module-level throttle set so each test starts fresh."""
    store._TRIPWIRE_SEEN.clear()
    yield
    store._TRIPWIRE_SEEN.clear()


@pytest.fixture
def _emits(monkeypatch):
    """Collect every recovery event emitted by the tripwire."""
    collected: list[tuple[str, str, dict]] = []

    def _capture(level, message, data=None):
        collected.append((level, message, data or {}))

    monkeypatch.setattr(store, "_emit_recovery_event", _capture)
    return collected


def _direct_tx_write() -> None:
    """A direct memory.db write via the _tx primitive (an unrouted path)."""
    with store._tx() as c:
        c.execute(
            "INSERT INTO meta(key, value) VALUES('tripwire_probe', 'x') "
            "ON CONFLICT(key) DO UPDATE SET value = value"
        )


class TestTripwire:
    def test_logs_and_emits_once_when_on_and_not_owner(
        self, monkeypatch, caplog, _reset_tripwire, _emits
    ):
        """single_writer ON + not owner: a direct _tx write logs a WARNING and
        emits a recovery event, and repeating the SAME call site is throttled to
        exactly one log/emit per process run."""
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        monkeypatch.setattr(write_router, "is_owner", lambda: False)

        with caplog.at_level("WARNING", logger="axi.store"):
            # Same source line both iterations → one call-site signature.
            for _ in range(2):
                _direct_tx_write()

        assert len(_emits) == 1, "throttle must emit exactly once per call site"
        level, message, data = _emits[0]
        assert level == "warning"
        assert "DIRECT memory.db write from non-owner" in message
        assert "call_site" in data and data["call_site"]
        warnings = [r for r in caplog.records if "DIRECT memory.db write" in r.message]
        assert len(warnings) == 1

    def test_no_tripwire_when_disabled(
        self, monkeypatch, _reset_tripwire, _emits
    ):
        """single_writer OFF: the tripwire is a no-op (common case)."""
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: False)
        monkeypatch.setattr(write_router, "is_owner", lambda: False)
        _direct_tx_write()
        assert _emits == []

    def test_no_tripwire_when_owner(
        self, monkeypatch, _reset_tripwire, _emits
    ):
        """is_owner True (the sole writer): its own direct writes are expected."""
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        monkeypatch.setattr(write_router, "is_owner", lambda: True)
        _direct_tx_write()
        assert _emits == []

    def test_write_still_proceeds(self, monkeypatch, _reset_tripwire, _emits):
        """The tripwire is observability only — the write must still land."""
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        monkeypatch.setattr(write_router, "is_owner", lambda: False)
        _direct_tx_write()
        row = store._connect().execute(
            "SELECT value FROM meta WHERE key = 'tripwire_probe'"
        ).fetchone()
        assert row is not None and row["value"] == "x"


# ─────────────────────────── rename_speaker routing ──────────────────────────


@pytest.fixture
def write_server(tmp_path, monkeypatch):
    """A running WriteServer bound to an isolated socket under tmp_path."""
    sock_path = tmp_path / "write.sock"
    monkeypatch.setattr(write_router, "WRITE_SOCK_PATH", sock_path)
    server = write_router.WriteServer(path=sock_path)
    server.start()
    try:
        yield server
    finally:
        server.stop()


class TestRenameSpeakerRouting:
    def test_rename_speaker_forwarded_end_to_end(self, write_server, monkeypatch):
        """single_writer ON + not owner: diarize.rename_speaker forwards to the
        server, which runs the REAL function against the temp DB as the owner,
        and the rename lands in the speakers table."""
        now = time.time()
        c = store._connect()
        c.execute(
            "INSERT INTO speakers(name, created_at, updated_at) VALUES('Persona 1', ?, ?)",
            (now, now),
        )
        c.commit()
        sid = c.execute(
            "SELECT id FROM speakers WHERE name = 'Persona 1'"
        ).fetchone()["id"]

        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        assert write_router.is_owner() is False  # client thread is not the owner

        updated = diarize.rename_speaker(sid, "Sergio")
        assert isinstance(updated, int)

        row = store._connect().execute(
            "SELECT name FROM speakers WHERE id = ?", (sid,)
        ).fetchone()
        assert row["name"] == "Sergio"

    def test_rename_speaker_relabels_segments(self, write_server, monkeypatch):
        """The forwarded rename also rewrites cached speaker_label on segments
        across meetings (verified end-to-end through the server)."""
        now = time.time()
        c = store._connect()
        c.execute(
            "INSERT INTO speakers(name, created_at, updated_at) VALUES('Persona 2', ?, ?)",
            (now, now),
        )
        c.execute(
            "INSERT INTO meetings(title, start_time, status, data_dir, created_at) "
            "VALUES('m', ?, 'done', '/tmp/m', ?)",
            (now, now),
        )
        c.commit()
        sid = c.execute("SELECT id FROM speakers WHERE name = 'Persona 2'").fetchone()["id"]
        mid = c.execute("SELECT id FROM meetings LIMIT 1").fetchone()["id"]
        c.execute(
            "INSERT INTO meeting_speakers(meeting_id, cluster_id, speaker_id, created_at) "
            "VALUES(?, 0, ?, ?)",
            (mid, sid, now),
        )
        c.execute(
            "INSERT INTO meeting_segments(meeting_id, channel, chunk_path, start_ms, "
            "end_ms, text, speaker_label, created_at) "
            "VALUES(?, 'system', 'a.wav', 0, 100, 'hi', 'Persona 2', ?)",
            (mid, now),
        )
        c.commit()

        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        updated = diarize.rename_speaker(sid, "Sully")
        assert updated == 1

        seg = store._connect().execute(
            "SELECT speaker_label FROM meeting_segments WHERE meeting_id = ?", (mid,)
        ).fetchone()
        assert seg["speaker_label"] == "Sully"

    def test_handler_registered(self):
        """The Stage-3 op is wired in the dispatch table."""
        assert "diarize.rename_speaker" in write_router.OP_HANDLERS


# ─────────────────────────── daemon owner wiring ─────────────────────────────


class TestOwnerWiring:
    def test_enable_write_owner_makes_is_owner_true(self, monkeypatch):
        """The daemon's startup call makes this process the sole writer."""
        monkeypatch.setattr(write_router, "_WRITE_OWNER", False)
        assert write_router.is_owner() is False
        write_router.enable_write_owner()
        assert write_router.is_owner() is True
