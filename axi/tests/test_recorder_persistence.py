"""PR3 recording persistence tests.

Phase 3.4 — RED tests for:
  3.4.1  Two saves → two distinct filenames (monkeypatched datetime + uuid)
  3.4.2  >10 recordings exist → retention prunes oldest, keeps exactly 10
  3.4.3  Cleanup tolerates OSError on individual file deletion (no crash)

The Recorder.save_recording method must:
  - Write to ~/.local/state/axi/recordings/{iso}_{uuid8}.wav  (mkdir -p, atomic)
  - After saving, prune to keep only the last `retention` files (default 10)
  - Treat OSError in cleanup as non-fatal

All tests use tmp_path — no real ~/.local/state/axi touched.
"""
from __future__ import annotations

import threading
import time
from pathlib import Path
from unittest.mock import patch

import numpy as np
import pytest
import soundfile as sf

from axi.recorder import Recorder, SAMPLE_RATE


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def _make_recorder(recordings_dir: Path, dump_debug: bool = False) -> Recorder:
    """Build a Recorder with its recordings dir redirected to tmp_path."""
    r = Recorder(dump_debug_wav=dump_debug)
    r._recordings_dir = recordings_dir  # inject tmp dir
    return r


def _short_audio() -> np.ndarray:
    """1-second audio (below long-audio threshold for retention tests)."""
    t = np.arange(SAMPLE_RATE, dtype=np.float32) / SAMPLE_RATE
    return (0.05 * np.sin(2 * np.pi * 440.0 * t)).astype(np.float32)


def _long_audio() -> np.ndarray:
    """3-minute audio (above the 2-min long-audio threshold)."""
    return np.zeros(16000 * 181, dtype=np.float32) + 0.01  # 3 min 1 s


# ─────────────────────────────────────────────────────────────────────────────
# Phase 3.4.1 — two saves → two distinct filenames
# ─────────────────────────────────────────────────────────────────────────────

def test_recording_unique_filename(tmp_path):
    """Two consecutive saves produce two distinct WAV filenames.

    Phase 3.4.1 — RED.
    """
    recordings_dir = tmp_path / "recordings"
    r = _make_recorder(recordings_dir)

    audio = _long_audio()

    import uuid as _uuid
    import datetime as _dt

    calls = []

    class _FakeDatetime:
        @staticmethod
        def now():
            calls.append("now")
            return _dt.datetime(2026, 6, 4, 9, 11, len(calls))

        def strftime(self, fmt):  # noqa: ARG002
            return "2026-06-04T09-11-0" + str(len(calls))

    _counter = [0]

    def _fake_uuid4():
        _counter[0] += 1
        return _uuid.UUID(f"00000000-0000-0000-0000-{_counter[0]:012d}")

    with patch("axi.recorder.datetime") as mock_dt, \
         patch("axi.recorder.uuid4", side_effect=_fake_uuid4):
        mock_dt.now.side_effect = lambda: _dt.datetime(2026, 6, 4, 9, 11, _counter[0] * 3)

        path1 = r.save_recording(audio)
        path2 = r.save_recording(audio)

    assert path1 is not None, "save_recording must return a path"
    assert path2 is not None, "save_recording must return a path"
    assert path1 != path2, "two saves must produce distinct filenames"
    assert path1.exists(), f"saved file must exist: {path1}"
    assert path2.exists(), f"saved file must exist: {path2}"


# ─────────────────────────────────────────────────────────────────────────────
# Phase 3.4.2 — >10 recordings → prune oldest, keep exactly 10
# ─────────────────────────────────────────────────────────────────────────────

def test_recording_retention_keeps_10(tmp_path):
    """After 13 total saves, retention must keep exactly 10 (oldest 3 pruned).

    Phase 3.4.2 — RED.
    """
    recordings_dir = tmp_path / "recordings"
    recordings_dir.mkdir(parents=True, exist_ok=True)

    # Pre-create 12 "old" wav stubs with ascending names (chronological sort safe)
    for i in range(12):
        name = f"2026-06-01T00-00-{i:02d}_aabbccdd.wav"
        stub = recordings_dir / name
        # Write a minimal valid WAV so soundfile doesn't complain
        sf.write(str(stub), np.zeros(100, dtype=np.float32), SAMPLE_RATE, subtype="FLOAT")

    r = _make_recorder(recordings_dir)
    audio = _long_audio()

    # Save one more → total 13 → prune to 10
    r.save_recording(audio)

    remaining = sorted(recordings_dir.glob("*.wav"))
    assert len(remaining) == 10, \
        f"expected 10 recordings after retention, got {len(remaining)}: {[p.name for p in remaining]}"

    # The oldest (lowest-sorted names) must be gone
    oldest_names = [f"2026-06-01T00-00-{i:02d}_aabbccdd.wav" for i in range(3)]
    for name in oldest_names:
        assert not (recordings_dir / name).exists(), \
            f"oldest recording must have been pruned: {name}"


# ─────────────────────────────────────────────────────────────────────────────
# Phase 3.4.3 — cleanup tolerates OSError
# ─────────────────────────────────────────────────────────────────────────────

def test_recording_retention_oserror_tolerated(tmp_path):
    """OSError during retention cleanup must not propagate.

    Phase 3.4.3 — RED.
    """
    recordings_dir = tmp_path / "recordings"
    recordings_dir.mkdir(parents=True, exist_ok=True)

    # Create 11 stubs so a prune is triggered
    for i in range(11):
        name = f"2026-06-01T00-00-{i:02d}_aabbccdd.wav"
        sf.write(str(recordings_dir / name), np.zeros(100, dtype=np.float32), SAMPLE_RATE, subtype="FLOAT")

    r = _make_recorder(recordings_dir)
    audio = _long_audio()

    # Patch Path.unlink to always raise OSError
    original_unlink = Path.unlink

    def _bad_unlink(self, missing_ok=False):
        raise OSError("simulated delete failure")

    with patch.object(Path, "unlink", _bad_unlink):
        # Must NOT raise
        try:
            r.save_recording(audio)
        except OSError as exc:
            pytest.fail(f"save_recording raised OSError during cleanup: {exc}")
