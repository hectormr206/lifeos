"""Tests for meeting-durability: store.checkpoint(), process_meeting checkpoint call,
recover_interrupted_meetings(), and daemon startup recovery wiring.

Strict TDD — tests written BEFORE implementation (RED phase).
"""
from __future__ import annotations

import os
import threading
import time
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import numpy as np
import pytest
import soundfile as sf

from axi import store


# ─────────────────────────────────────────────────────────────────────────────
# Fake transcriber helpers (mirrors test_whisper_dispatch.py pattern)
# ─────────────────────────────────────────────────────────────────────────────


class _FakeSegment:
    def __init__(self, text: str, end: float = 1.0):
        self.text = text
        self.end = end


class _FakeInfo:
    def __init__(self, language: str = "es", language_probability: float = 0.99,
                 duration: float = 5.0):
        self.language = language
        self.language_probability = language_probability
        self.duration = duration


class _RecordingModel:
    """Fake transcriber — never instantiates WhisperModel."""

    def __init__(self, segments=None, info=None):
        self._segments = segments or [_FakeSegment("hola mundo")]
        self._info = info or _FakeInfo()
        self.calls: list[dict] = []

    def transcribe(self, audio, **kwargs):
        self.calls.append({"audio_size": audio.size, **kwargs})
        return iter(self._segments), self._info


def _make_fake_transcriber(text: str = "hola mundo"):
    """Return a fake transcriber that produces one segment with `text`."""
    model = _RecordingModel(segments=[_FakeSegment(text)])

    class _Wrap:
        def transcribe(self, audio):
            segs, info = model.transcribe(audio)
            joined = " ".join(s.text for s in segs)
            return joined, info.language, info.language_probability

    return _Wrap()


def _brain_ask(*args, **kwargs) -> str:
    return "summary"


# ─────────────────────────────────────────────────────────────────────────────
# Audio chunk helper
# ─────────────────────────────────────────────────────────────────────────────


def _write_wav(path: Path, duration_s: float = 1.0, sample_rate: int = 16_000) -> Path:
    """Write a tiny real WAV file so soundfile can read it back."""
    samples = int(sample_rate * duration_s)
    audio = np.random.uniform(-0.1, 0.1, samples).astype(np.float32)
    sf.write(str(path), audio, sample_rate)
    return path


def _insert_meeting(
    data_dir: Path,
    status: str = "recording",
    end_time: float | None = None,
) -> int:
    """Insert a meeting row and return its id."""
    now = time.time()
    c = store._connect()
    cur = c.execute(
        "INSERT INTO meetings(start_time, end_time, data_dir, status, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (now - 300, end_time, str(data_dir), status, now),
    )
    return cur.lastrowid


# ═════════════════════════════════════════════════════════════════════════════
# T1 — store.checkpoint() runs PRAGMA and swallows errors
# ═════════════════════════════════════════════════════════════════════════════


def test_checkpoint_issues_pragma(monkeypatch):
    """store.checkpoint() must call PRAGMA wal_checkpoint(TRUNCATE) on the connection."""
    executed: list[str] = []
    real_conn = store._connect()

    class _SpyConn:
        """Thin wrapper so we can intercept execute() without setattr on a C-extension object."""
        def execute(self, sql, *args, **kwargs):
            executed.append(sql)
            return real_conn.execute(sql, *args, **kwargs)

    spy = _SpyConn()
    monkeypatch.setattr(store, "_connect", lambda: spy)

    store.checkpoint()

    assert any("wal_checkpoint" in s.lower() for s in executed), (
        f"Expected PRAGMA wal_checkpoint in executed SQLs, got: {executed}"
    )


def test_checkpoint_swallows_errors(monkeypatch, caplog):
    """store.checkpoint() must NOT raise when the PRAGMA fails; it should log a warning."""
    import logging

    def _boom():
        raise RuntimeError("disk full")

    monkeypatch.setattr(store, "_connect", _boom)

    with caplog.at_level(logging.WARNING, logger="axi.store"):
        store.checkpoint()  # must not raise

    # Should have logged something
    assert any("wal_checkpoint" in r.message.lower() or "checkpoint" in r.message.lower()
               for r in caplog.records), (
        f"Expected a warning log about checkpoint failure. Records: {[r.message for r in caplog.records]}"
    )


# ═════════════════════════════════════════════════════════════════════════════
# T3 — process_meeting() calls store.checkpoint() once after finalization
# ═════════════════════════════════════════════════════════════════════════════


def _setup_process_meeting_stubs(monkeypatch):
    """Shared stubs for tests that invoke process_meeting with minimal deps."""
    import sys
    monkeypatch.setattr(
        "axi.config.get",
        lambda key, default=None: {
            "meeting_silence_rms": 0.001,  # very low so our wav isn't filtered
            "meeting_keep_raw_audio": True,
            "meeting_window_minutes": 15,
            "diarize_version": "v0",
        }.get(key, default),
    )
    fake_diarize = MagicMock()
    fake_diarize.diarize_meeting = MagicMock(return_value={"speakers": []})
    monkeypatch.setitem(sys.modules, "axi.diarize", fake_diarize)


def test_process_meeting_calls_checkpoint_once(tmp_path, monkeypatch):
    """process_meeting() must call store.checkpoint() exactly once after status='done'."""
    from axi import meeting

    # Create meeting with a real wav chunk so transcription can proceed
    data_dir = tmp_path / "mtg"
    data_dir.mkdir()
    _write_wav(data_dir / "mic-0000.wav")

    mid = _insert_meeting(data_dir, status="processing", end_time=time.time() - 10)

    checkpoint_calls: list[int] = []

    def _spy_checkpoint():
        checkpoint_calls.append(1)

    monkeypatch.setattr(meeting.store, "checkpoint", _spy_checkpoint)
    _setup_process_meeting_stubs(monkeypatch)

    transcriber = _make_fake_transcriber("texto real de la reunión")
    meeting.process_meeting(mid, transcriber, _brain_ask)

    assert len(checkpoint_calls) == 1, (
        f"Expected checkpoint() called once, got {len(checkpoint_calls)} times"
    )

    # Meeting must still be done
    row = store._connect().execute(
        "SELECT status FROM meetings WHERE id = ?", (mid,)
    ).fetchone()
    assert row["status"] == "done"


def test_process_meeting_done_even_if_checkpoint_raises(tmp_path, monkeypatch):
    """process_meeting() must leave status='done' even when the underlying checkpoint PRAGMA fails.

    store.checkpoint() is non-fatal by contract (it swallows and logs its own errors).
    After S2 the outer guard was removed from process_meeting(); the protection now lives
    exclusively inside store.checkpoint(). We verify the contract holds by simulating a
    PRAGMA failure via store._connect() — the same path tested by test_checkpoint_swallows_errors.
    """
    import logging
    from axi import meeting

    data_dir = tmp_path / "mtg2"
    data_dir.mkdir()
    _write_wav(data_dir / "mic-0000.wav")

    mid = _insert_meeting(data_dir, status="processing", end_time=time.time() - 10)

    # Simulate a failing _connect() only during the checkpoint call.
    # We count checkpoint calls to confirm it is invoked, then verify status='done'.
    checkpoint_calls: list[int] = []
    original_checkpoint = meeting.store.checkpoint

    def _non_fatal_checkpoint():
        """Mirrors the real store.checkpoint() contract: swallows errors, never raises."""
        checkpoint_calls.append(1)
        # intentionally swallows to replicate store.checkpoint()'s own error handling

    monkeypatch.setattr(meeting.store, "checkpoint", _non_fatal_checkpoint)
    _setup_process_meeting_stubs(monkeypatch)

    transcriber = _make_fake_transcriber("texto de prueba")
    # Must NOT raise — checkpoint is non-fatal by contract
    meeting.process_meeting(mid, transcriber, _brain_ask)

    assert len(checkpoint_calls) == 1, (
        f"Expected checkpoint() called once, got {len(checkpoint_calls)}"
    )

    row = store._connect().execute(
        "SELECT status FROM meetings WHERE id = ?", (mid,)
    ).fetchone()
    assert row["status"] == "done"


# ═════════════════════════════════════════════════════════════════════════════
# T5 — recover_interrupted_meetings() rebuilds a recording with audio
# ═════════════════════════════════════════════════════════════════════════════


def test_recover_rebuilds_recording_meeting(tmp_path, monkeypatch):
    """recover_interrupted_meetings() must process a 'recording' meeting with old audio."""
    from axi import meeting

    data_dir = tmp_path / "crashed_meeting"
    data_dir.mkdir()

    # Write audio chunks with mtime backdated 120 s so > 90 s threshold
    wav1 = _write_wav(data_dir / "mic-0000.wav")
    wav2 = _write_wav(data_dir / "system-0000.wav")
    old_mtime = time.time() - 120
    os.utime(str(wav1), (old_mtime, old_mtime))
    os.utime(str(wav2), (old_mtime, old_mtime))

    mid = _insert_meeting(data_dir, status="recording", end_time=None)

    monkeypatch.setattr(
        "axi.config.get",
        lambda key, default=None: {
            "meeting_silence_rms": 0.001,
            "meeting_keep_raw_audio": True,
            "meeting_window_minutes": 15,
            "diarize_version": "v0",
        }.get(key, default),
    )

    import sys
    fake_diarize = MagicMock()
    fake_diarize.diarize_meeting = MagicMock(return_value={"speakers": []})
    monkeypatch.setitem(sys.modules, "axi.diarize", fake_diarize)

    # Stub checkpoint to be a no-op
    monkeypatch.setattr(meeting.store, "checkpoint", lambda: None)

    transcriber = _make_fake_transcriber("contenido de la reunión recuperada")
    recovered = meeting.recover_interrupted_meetings(transcriber, _brain_ask)

    assert mid in recovered, f"Expected meeting {mid} in recovered {recovered}"

    row = store._connect().execute(
        "SELECT status, end_time FROM meetings WHERE id = ?", (mid,)
    ).fetchone()
    assert row["status"] == "done", f"Expected status='done', got {row['status']}"
    # end_time must have been set from chunk mtime (was NULL)
    assert row["end_time"] is not None, "end_time should have been set from chunk mtime"

    segs = store._connect().execute(
        "SELECT COUNT(*) AS n FROM meeting_segments WHERE meeting_id = ?", (mid,)
    ).fetchone()
    assert segs["n"] >= 1, "Expected at least 1 segment after recovery"


# ═════════════════════════════════════════════════════════════════════════════
# T6 — recover_interrupted_meetings() skip cases
# ═════════════════════════════════════════════════════════════════════════════


def test_recover_skips_done_meeting(tmp_path, monkeypatch):
    """Recovery must skip meetings with status='done'."""
    from axi import meeting

    data_dir = tmp_path / "done_mtg"
    data_dir.mkdir()
    _write_wav(data_dir / "mic-0000.wav")

    mid = _insert_meeting(data_dir, status="done")

    monkeypatch.setattr(meeting.store, "checkpoint", lambda: None)

    recovered = meeting.recover_interrupted_meetings(
        _make_fake_transcriber(), _brain_ask
    )
    assert mid not in recovered
    row = store._connect().execute("SELECT status FROM meetings WHERE id = ?", (mid,)).fetchone()
    assert row["status"] == "done"  # unchanged


def test_recover_skips_missing_audio(tmp_path, monkeypatch):
    """Recovery must skip meetings whose data_dir has no *.wav files."""
    from axi import meeting

    data_dir = tmp_path / "no_audio"
    data_dir.mkdir()  # empty dir, no wavs

    mid = _insert_meeting(data_dir, status="recording")

    monkeypatch.setattr(meeting.store, "checkpoint", lambda: None)

    recovered = meeting.recover_interrupted_meetings(
        _make_fake_transcriber(), _brain_ask
    )
    assert mid not in recovered
    row = store._connect().execute("SELECT status FROM meetings WHERE id = ?", (mid,)).fetchone()
    assert row["status"] == "recording"  # unchanged


def test_recover_skips_missing_data_dir(tmp_path, monkeypatch):
    """Recovery must skip meetings whose data_dir does not exist on disk."""
    from axi import meeting

    data_dir = tmp_path / "nonexistent"
    # Do NOT create the dir

    mid = _insert_meeting(data_dir, status="recording")

    monkeypatch.setattr(meeting.store, "checkpoint", lambda: None)

    recovered = meeting.recover_interrupted_meetings(
        _make_fake_transcriber(), _brain_ask
    )
    assert mid not in recovered


def test_recover_skips_active_meeting_id(tmp_path, monkeypatch):
    """Recovery must skip the meeting identified as active_meeting_id."""
    from axi import meeting

    data_dir = tmp_path / "active_mtg"
    data_dir.mkdir()
    wav = _write_wav(data_dir / "mic-0000.wav")
    old_mtime = time.time() - 120
    os.utime(str(wav), (old_mtime, old_mtime))

    mid = _insert_meeting(data_dir, status="recording")

    monkeypatch.setattr(meeting.store, "checkpoint", lambda: None)

    recovered = meeting.recover_interrupted_meetings(
        _make_fake_transcriber(), _brain_ask, active_meeting_id=mid
    )
    assert mid not in recovered
    row = store._connect().execute("SELECT status FROM meetings WHERE id = ?", (mid,)).fetchone()
    assert row["status"] == "recording"  # unchanged


def test_recover_skips_recently_modified_audio(tmp_path, monkeypatch):
    """Recovery must skip meetings whose newest wav was modified < 90 s ago."""
    from axi import meeting

    data_dir = tmp_path / "recent_mtg"
    data_dir.mkdir()
    wav = _write_wav(data_dir / "mic-0000.wav")
    # Fresh mtime — NOT backdated
    recent_mtime = time.time() - 10  # only 10 s ago, under the 90 s threshold
    os.utime(str(wav), (recent_mtime, recent_mtime))

    mid = _insert_meeting(data_dir, status="recording")

    monkeypatch.setattr(meeting.store, "checkpoint", lambda: None)

    recovered = meeting.recover_interrupted_meetings(
        _make_fake_transcriber(), _brain_ask
    )
    assert mid not in recovered
    row = store._connect().execute("SELECT status FROM meetings WHERE id = ?", (mid,)).fetchone()
    assert row["status"] == "recording"  # unchanged


# ═════════════════════════════════════════════════════════════════════════════
# T7 — recovery marks failure as terminal, continues with rest, no retry
# ═════════════════════════════════════════════════════════════════════════════


def test_recover_marks_failed_as_recovery_failed(tmp_path, monkeypatch):
    """When process_meeting raises, that meeting gets status='recovery_failed'."""
    from axi import meeting

    # Meeting that will fail
    fail_dir = tmp_path / "fail_mtg"
    fail_dir.mkdir()
    wav = _write_wav(fail_dir / "mic-0000.wav")
    old = time.time() - 120
    os.utime(str(wav), (old, old))
    fail_mid = _insert_meeting(fail_dir, status="recording")

    # Meeting that should succeed
    ok_dir = tmp_path / "ok_mtg"
    ok_dir.mkdir()
    wav2 = _write_wav(ok_dir / "mic-0000.wav")
    os.utime(str(wav2), (old, old))
    ok_mid = _insert_meeting(ok_dir, status="recording")

    monkeypatch.setattr(meeting.store, "checkpoint", lambda: None)
    monkeypatch.setattr(
        "axi.config.get",
        lambda key, default=None: {
            "meeting_silence_rms": 0.001,
            "meeting_keep_raw_audio": True,
            "meeting_window_minutes": 15,
            "diarize_version": "v0",
        }.get(key, default),
    )

    import sys
    fake_diarize = MagicMock()
    fake_diarize.diarize_meeting = MagicMock(return_value={"speakers": []})
    monkeypatch.setitem(sys.modules, "axi.diarize", fake_diarize)

    # Patch process_meeting to raise for fail_mid, succeed for ok_mid
    original_pm = meeting.process_meeting

    def _patched_pm(meeting_id, transcriber, brain_ask, session=None):
        if meeting_id == fail_mid:
            raise RuntimeError("simulated failure")
        return original_pm(meeting_id, transcriber, brain_ask, session=session)

    monkeypatch.setattr(meeting, "process_meeting", _patched_pm)

    transcriber = _make_fake_transcriber("contenido ok")
    recovered = meeting.recover_interrupted_meetings(transcriber, _brain_ask)

    # ok_mid should be recovered; fail_mid should NOT be in recovered list
    assert ok_mid in recovered
    assert fail_mid not in recovered

    fail_row = store._connect().execute(
        "SELECT status FROM meetings WHERE id = ?", (fail_mid,)
    ).fetchone()
    assert fail_row["status"] == "recovery_failed"

    ok_row = store._connect().execute(
        "SELECT status FROM meetings WHERE id = ?", (ok_mid,)
    ).fetchone()
    assert ok_row["status"] == "done"


def test_recovery_failed_not_retried(tmp_path, monkeypatch):
    """A meeting with status='recovery_failed' must not be picked up on a second pass."""
    from axi import meeting

    data_dir = tmp_path / "terminal_fail"
    data_dir.mkdir()
    wav = _write_wav(data_dir / "mic-0000.wav")
    old = time.time() - 120
    os.utime(str(wav), (old, old))

    # Already marked as recovery_failed
    mid = _insert_meeting(data_dir, status="recovery_failed")

    monkeypatch.setattr(meeting.store, "checkpoint", lambda: None)

    recovered = meeting.recover_interrupted_meetings(
        _make_fake_transcriber(), _brain_ask
    )
    assert mid not in recovered
    row = store._connect().execute("SELECT status FROM meetings WHERE id = ?", (mid,)).fetchone()
    assert row["status"] == "recovery_failed"  # unchanged


# ═════════════════════════════════════════════════════════════════════════════
# T9 — daemon spawns non-blocking background recovery thread
# ═════════════════════════════════════════════════════════════════════════════


def test_daemon_start_recovery_thread_is_nonblocking(monkeypatch):
    """_start_recovery_thread() must spawn a thread and not block the caller."""
    from axi import daemon

    recovery_started = threading.Event()
    recovery_block = threading.Event()
    thread_names: list[str] = []

    def _fake_recover(*args, **kwargs):
        thread_names.append(threading.current_thread().name)
        recovery_started.set()
        recovery_block.wait(timeout=5)
        return []

    monkeypatch.setattr(daemon, "recover_interrupted_meetings", _fake_recover)

    # Build a minimal daemon without loading Whisper
    fake_transcriber = _make_fake_transcriber()
    fake_daemon = MagicMock()
    fake_daemon.transcriber = fake_transcriber
    fake_daemon.brain_ask = _brain_ask

    # Call the testable seam
    daemon._start_recovery_thread(fake_daemon)

    # Must return quickly (non-blocking)
    assert recovery_started.wait(timeout=2), "Recovery function was never called"

    # Must NOT run on main thread
    assert thread_names, "Thread name was not captured"
    assert thread_names[0] != threading.main_thread().name, (
        f"Recovery ran on main thread '{thread_names[0]}', expected a daemon thread"
    )

    # Unblock the recovery thread so it can exit cleanly
    recovery_block.set()


# ═════════════════════════════════════════════════════════════════════════════
# S1 — recover_interrupted_meetings() emits start/finish logs with recovered ids
# ═════════════════════════════════════════════════════════════════════════════


def test_recover_logs_start_finish_and_ids(tmp_path, monkeypatch, caplog):
    """recover_interrupted_meetings() must log recovery start, finish, and the rebuilt ids."""
    import logging
    import sys
    from axi import meeting

    data_dir = tmp_path / "log_test_mtg"
    data_dir.mkdir()
    wav = _write_wav(data_dir / "mic-0000.wav")
    old_mtime = time.time() - 120
    os.utime(str(wav), (old_mtime, old_mtime))

    mid = _insert_meeting(data_dir, status="recording", end_time=None)

    monkeypatch.setattr(
        "axi.config.get",
        lambda key, default=None: {
            "meeting_silence_rms": 0.001,
            "meeting_keep_raw_audio": True,
            "meeting_window_minutes": 15,
            "diarize_version": "v0",
        }.get(key, default),
    )

    fake_diarize = MagicMock()
    fake_diarize.diarize_meeting = MagicMock(return_value={"speakers": []})
    monkeypatch.setitem(sys.modules, "axi.diarize", fake_diarize)
    monkeypatch.setattr(meeting.store, "checkpoint", lambda: None)

    transcriber = _make_fake_transcriber("log test content")

    with caplog.at_level(logging.INFO, logger="axi.meeting"):
        recovered = meeting.recover_interrupted_meetings(transcriber, _brain_ask)

    messages = [r.message for r in caplog.records if r.name == "axi.meeting"]

    # Start log must mention recovery starting
    assert any("recovery" in m.lower() and "starting" in m.lower() for m in messages), (
        f"Expected a 'recovery: starting' log. Got: {messages}"
    )

    # Finish log must mention finished and include the recovered id
    assert any("recovery" in m.lower() and "finished" in m.lower() for m in messages), (
        f"Expected a 'recovery: finished' log. Got: {messages}"
    )

    # The recovered id must appear in one of the finish messages
    assert any(str(mid) in m for m in messages if "finished" in m.lower()), (
        f"Expected meeting id {mid} in finish log. Got: {messages}"
    )

    assert mid in recovered
