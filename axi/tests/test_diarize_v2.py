"""Tests for diarization V2 (PRD P2.1).

Goals:
- Verify the meeting code path picks V0 vs V2 based on `diarization_v2_enabled`.
- Verify V2 falls back to V0 silently when pyannote import / pipeline fails.
- Verify the segment-label mapping math is correct without ever loading the
  real pyannote model (kept under 1 s).

We never import pyannote in tests — we monkeypatch the module table so the
test suite stays light and offline.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path
from unittest.mock import MagicMock

import numpy as np
import pytest
import soundfile as sf

from axi import diarize_v2, store


def _resemblyzer_torch_ok() -> tuple[bool, str]:
    """Diarize V2's preprocess_wav goes through resemblyzer → torch → NCCL.
    Even with pyannote and Resemblyzer's centroid step mocked, the test
    still indirectly imports torch via the diarize module chain. If torch
    can't load its CUDA companion libs (e.g. libnccl.so.2 absent), the
    happy-path test asserts on empty cluster results. Probe the import
    here so we skip cleanly instead of failing on a hard-to-read assert.
    """
    try:
        import torch  # noqa: F401
    except Exception as e:  # noqa: BLE001
        return False, f"torch import failed: {e}"
    return True, ""


_torch_ok, _torch_reason = _resemblyzer_torch_ok()


# ─────────────────────── helpers ─────────────────────────────────────────

def _make_meeting_with_chunks(tmp_path: Path, n_chunks: int = 2) -> int:
    """Create a meeting + N system chunks (1 s of low-amplitude noise each).

    We don't care about acoustic content — the pipeline is mocked. We just
    need real WAV files on disk so soundfile can read them.
    """
    data_dir = tmp_path / "meet1"
    data_dir.mkdir(parents=True, exist_ok=True)
    sr = 16_000
    now = time.time()
    with store._tx() as c:  # noqa: SLF001
        cur = c.execute(
            "INSERT INTO meetings(start_time, data_dir, status, created_at) "
            "VALUES (?, ?, 'done', ?)",
            (now, str(data_dir), now),
        )
        meeting_id = cur.lastrowid
        for i in range(n_chunks):
            rel = f"system-{i:04d}.wav"
            audio = (np.random.default_rng(i).standard_normal(sr) * 0.01).astype(np.float32)
            sf.write(str(data_dir / rel), audio, sr)
            c.execute(
                "INSERT INTO meeting_segments(meeting_id, channel, chunk_path, "
                "start_ms, end_ms, text, created_at) "
                "VALUES (?, 'system', ?, ?, ?, ?, ?)",
                (meeting_id, rel, i * 1000, (i + 1) * 1000, "hola mundo", now),
            )
    return meeting_id


# ─────────────────────── routing through config flag ─────────────────────

def test_meeting_uses_v0_when_flag_disabled(monkeypatch):
    """With `diarization_v2_enabled=False`, meeting.py imports V0 — V2 must
    never be touched on the hot path."""
    from axi import config
    monkeypatch.setattr(config, "get", lambda key, default=None:
                        False if key == "diarization_v2_enabled" else default)

    called = {"v0": False, "v2": False}
    from axi import diarize as v0_module
    monkeypatch.setattr(v0_module, "diarize_meeting",
                        lambda mid: called.__setitem__("v0", True) or
                        {"clusters": 0, "segments_updated": 0, "new_speakers": 0})
    monkeypatch.setattr(diarize_v2, "diarize_meeting",
                        lambda mid: called.__setitem__("v2", True) or
                        {"clusters": 0, "segments_updated": 0, "new_speakers": 0})

    # Direct simulation of the meeting.py dispatch — we test the conditional
    # itself, not the surrounding orchestration which has heavy deps.
    flag = config.get("diarization_v2_enabled", False)
    if flag:
        from axi.diarize_v2 import diarize_meeting
    else:
        from axi.diarize import diarize_meeting
    diarize_meeting(1)

    assert called["v0"] is True
    assert called["v2"] is False


# ─────────────────────── pyannote import failure ─────────────────────────

def test_v2_falls_back_when_pyannote_import_fails(tmp_path, monkeypatch):
    """If `import pyannote.audio` raises, we MUST fall back to V0 silently
    and the event log records the error."""
    meeting_id = _make_meeting_with_chunks(tmp_path)

    # Pretend HF_TOKEN is set so _load_hf_token doesn't short-circuit before
    # the import attempt — we want to test the import-failure path specifically.
    monkeypatch.setenv("HF_TOKEN", "fake-token-for-test")

    # Make `import pyannote.audio` blow up by installing a broken stub.
    class _Broken:
        def __getattr__(self, name):
            raise ImportError("simulated pyannote breakage")

    monkeypatch.setitem(sys.modules, "pyannote", _Broken())
    monkeypatch.setitem(sys.modules, "pyannote.audio", _Broken())

    fallback_calls = []
    from axi import diarize as v0_module
    monkeypatch.setattr(
        v0_module, "diarize_meeting",
        lambda mid: fallback_calls.append(mid) or
        {"clusters": 0, "segments_updated": 0, "new_speakers": 0},
    )

    result = diarize_v2.diarize_meeting(meeting_id)
    assert fallback_calls == [meeting_id]
    assert result == {"clusters": 0, "segments_updated": 0, "new_speakers": 0}


def test_v2_falls_back_when_token_missing(tmp_path, monkeypatch):
    """No HF_TOKEN and no .env entry → fall back to V0 without touching
    pyannote (we never want to attempt a download with no credentials)."""
    meeting_id = _make_meeting_with_chunks(tmp_path)

    monkeypatch.delenv("HF_TOKEN", raising=False)
    # Point _ENV_PATH to a nonexistent file so _load_hf_token returns None.
    monkeypatch.setattr(diarize_v2, "_ENV_PATH", tmp_path / "nope.env")

    fallback_calls = []
    from axi import diarize as v0_module
    monkeypatch.setattr(
        v0_module, "diarize_meeting",
        lambda mid: fallback_calls.append(mid) or
        {"clusters": 1, "segments_updated": 2, "new_speakers": 1},
    )

    result = diarize_v2.diarize_meeting(meeting_id)
    assert fallback_calls == [meeting_id]
    assert result["clusters"] == 1


# ─────────────────────── happy-path with mocked pipeline ─────────────────

def test_assign_segment_labels_picks_dominant_overlap():
    """Unit test of the mapping math — segments win the label of the turn
    that covers most of their span."""
    turns = [
        {"start": 0.0, "end": 1.2, "label": "SPEAKER_00"},
        {"start": 1.2, "end": 2.0, "label": "SPEAKER_01"},
    ]
    index = [
        {"segment_id": 100, "offset_s": 0.0, "duration_s": 1.0, "start_ms_db": 0},
        {"segment_id": 101, "offset_s": 1.0, "duration_s": 1.0, "start_ms_db": 1000},
    ]
    out = diarize_v2._assign_segment_labels(turns, index)
    # Segment 100: 0..1 → entirely under SPEAKER_00.
    assert out[100] == "SPEAKER_00"
    # Segment 101: 1..2 → 0.2 s SPEAKER_00, 0.8 s SPEAKER_01 → SPEAKER_01.
    assert out[101] == "SPEAKER_01"


@pytest.mark.skipif(
    not _torch_ok,
    reason=f"happy path needs torch loadable end-to-end ({_torch_reason})",
)
def test_v2_happy_path_with_mocked_pipeline(tmp_path, monkeypatch):
    """End-to-end V2: mock the pyannote Pipeline to return a known
    diarization, verify the DB ends up with the right speaker labels.

    The real model is never touched. Stays under 1 s.
    """
    meeting_id = _make_meeting_with_chunks(tmp_path, n_chunks=2)
    monkeypatch.setenv("HF_TOKEN", "fake-token")

    # Build a fake diarization object that mimics pyannote's API: an
    # itertracks(yield_label=True) iterator over (Turn, track, label).
    class _Turn:
        def __init__(self, start, end):
            self.start = start
            self.end = end

    fake_diarization = MagicMock()
    fake_diarization.itertracks.return_value = iter([
        (_Turn(0.0, 1.0), "_", "SPEAKER_00"),
        (_Turn(1.0, 2.0), "_", "SPEAKER_01"),
    ])

    fake_pipeline = MagicMock()
    fake_pipeline.return_value = fake_diarization

    fake_pyannote_audio = MagicMock()
    fake_pyannote_audio.Pipeline.from_pretrained.return_value = fake_pipeline

    monkeypatch.setitem(sys.modules, "pyannote", MagicMock())
    monkeypatch.setitem(sys.modules, "pyannote.audio", fake_pyannote_audio)

    # Stub centroid computation — we don't want Resemblyzer in tests.
    monkeypatch.setattr(diarize_v2, "_centroids_per_cluster",
                        lambda mid, idx, turns: {})

    result = diarize_v2.diarize_meeting(meeting_id)

    assert result["clusters"] == 2
    assert result["segments_updated"] == 2
    assert result["new_speakers"] == 2

    # The two segments should have distinct (Persona N) labels.
    c = store._connect()  # noqa: SLF001
    rows = c.execute(
        "SELECT speaker_label FROM meeting_segments "
        "WHERE meeting_id = ? ORDER BY start_ms",
        (meeting_id,),
    ).fetchall()
    labels = [r["speaker_label"] for r in rows]
    assert all(lbl and lbl.startswith("Persona ") for lbl in labels)
    assert labels[0] != labels[1]


def test_v2_handles_empty_meeting(tmp_path, monkeypatch):
    """A meeting with no system segments returns zeros — never crashes."""
    now = time.time()
    with store._tx() as c:  # noqa: SLF001
        cur = c.execute(
            "INSERT INTO meetings(start_time, data_dir, status, created_at) "
            "VALUES (?, ?, 'done', ?)",
            (now, str(tmp_path / "empty"), now),
        )
        meeting_id = cur.lastrowid

    monkeypatch.setenv("HF_TOKEN", "fake-token")
    result = diarize_v2.diarize_meeting(meeting_id)
    assert result == {"clusters": 0, "segments_updated": 0, "new_speakers": 0}


# ─────────────────────── env / device resolution ─────────────────────────

def test_resolve_device_default_is_cpu(monkeypatch):
    monkeypatch.delenv("AXI_DIARIZE_DEVICE", raising=False)
    assert diarize_v2._resolve_device() == "cpu"


def test_resolve_device_honours_env_for_cuda(monkeypatch):
    monkeypatch.setenv("AXI_DIARIZE_DEVICE", "cuda")
    assert diarize_v2._resolve_device() == "cuda"


def test_load_hf_token_reads_env_file(tmp_path, monkeypatch):
    monkeypatch.delenv("HF_TOKEN", raising=False)
    env = tmp_path / ".env"
    env.write_text("# comment\nHF_TOKEN=hf_test_secret_value\nOTHER=foo\n")
    monkeypatch.setattr(diarize_v2, "_ENV_PATH", env)
    assert diarize_v2._load_hf_token() == "hf_test_secret_value"
    # Idempotent — second call returns the same without re-reading.
    monkeypatch.setattr(diarize_v2, "_ENV_PATH", tmp_path / "doesnotexist")
    assert diarize_v2._load_hf_token() == "hf_test_secret_value"


def test_load_hf_token_missing_returns_none(tmp_path, monkeypatch):
    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.setattr(diarize_v2, "_ENV_PATH", tmp_path / "nope.env")
    assert diarize_v2._load_hf_token() is None
