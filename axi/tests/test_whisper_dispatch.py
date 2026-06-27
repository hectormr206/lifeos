"""PR2 dispatch tests: _dispatch_transcription routing + pipeline construction.

Phase 2.1 — RED tests for:
  2.1.1  audio.size < threshold  → model.transcribe called, pipeline NOT used
  2.1.2  audio.size >= threshold → pipeline.transcribe called with correct kwargs
  2.1.3  audio.size == threshold (exactly) → batched path (inclusive boundary)
  2.1.4  both paths return identical (segments, info) shape
  2.1.5  LONG_AUDIO_SAMPLES constant == 16000 * 120

Phase 2.2 — RED test for:
  2.2.1  pipeline is constructed via BatchedInferencePipeline (import smoke)

All tests inject fake model + fake pipeline objects — NEVER instantiate WhisperModel.
"""
from __future__ import annotations

import numpy as np
import pytest


# ─────────────────────────────────────────────────────────────────────────────
# Fake objects — replace GPU model and pipeline completely
# ─────────────────────────────────────────────────────────────────────────────

class _FakeSegment:
    """Minimal Segment stand-in with the fields _handle uses."""

    def __init__(self, text: str, end: float = 1.0):
        self.text = text
        self.end = end


class _FakeInfo:
    """Minimal TranscriptionInfo stand-in."""

    def __init__(self, language: str = "es", language_probability: float = 0.99,
                 duration: float = 5.0):
        self.language = language
        self.language_probability = language_probability
        self.duration = duration


class _RecordingModel:
    """Fake WhisperModel that records every call to .transcribe."""

    def __init__(self, segments=None, info=None):
        self._segments = segments or [_FakeSegment("hello")]
        self._info = info or _FakeInfo()
        self.calls: list[dict] = []

    def transcribe(self, audio, **kwargs):
        self.calls.append({"audio_size": audio.size, **kwargs})
        return iter(self._segments), self._info


class _RecordingPipeline:
    """Fake BatchedInferencePipeline that records every call to .transcribe."""

    def __init__(self, segments=None, info=None):
        self._segments = segments or [_FakeSegment("hello batched")]
        self._info = info or _FakeInfo()
        self.calls: list[dict] = []

    def transcribe(self, audio, **kwargs):
        self.calls.append({"audio_size": audio.size, **kwargs})
        return iter(self._segments), self._info


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def _short_audio():
    """Audio strictly below the 2-minute threshold (1 second)."""
    from axi.whisper_server import LONG_AUDIO_SAMPLES
    return np.zeros(LONG_AUDIO_SAMPLES - 1, dtype=np.float32)


def _long_audio():
    """Audio strictly above the threshold (2 min + 1 sample)."""
    from axi.whisper_server import LONG_AUDIO_SAMPLES
    return np.zeros(LONG_AUDIO_SAMPLES + 1, dtype=np.float32)


def _threshold_audio():
    """Audio exactly at threshold — must take batched path (inclusive)."""
    from axi.whisper_server import LONG_AUDIO_SAMPLES
    return np.zeros(LONG_AUDIO_SAMPLES, dtype=np.float32)


# ─────────────────────────────────────────────────────────────────────────────
# Phase 2.1.5 — LONG_AUDIO_SAMPLES constant
# ─────────────────────────────────────────────────────────────────────────────

def test_long_audio_samples_constant():
    """LONG_AUDIO_SAMPLES must equal 16000 * 120 (2 minutes at 16kHz).

    Phase 2.1.5 — RED. Must FAIL before constant is added.
    """
    from axi import whisper_server
    assert hasattr(whisper_server, "LONG_AUDIO_SAMPLES"), \
        "LONG_AUDIO_SAMPLES constant not found in whisper_server"
    assert whisper_server.LONG_AUDIO_SAMPLES == 16000 * 120, \
        f"expected {16000 * 120}, got {whisper_server.LONG_AUDIO_SAMPLES}"


# ─────────────────────────────────────────────────────────────────────────────
# Phase 2.1.1 — short audio → model.transcribe called, pipeline NOT used
# ─────────────────────────────────────────────────────────────────────────────

def test_dispatch_short_uses_model():
    """Short audio (< threshold) must call model.transcribe, never pipeline.transcribe.

    Phase 2.1.1 — RED. Must FAIL before _dispatch_transcription exists.
    """
    from axi.whisper_server import _dispatch_transcription

    model = _RecordingModel()
    pipeline = _RecordingPipeline()
    audio = _short_audio()
    params = {"language": "es", "beam_size": 5, "vad_filter": False}

    _dispatch_transcription(audio, params, model=model, pipeline=pipeline)

    assert len(model.calls) == 1, "model.transcribe must be called exactly once"
    assert len(pipeline.calls) == 0, "pipeline.transcribe must NOT be called for short audio"
    # legacy params forwarded unchanged
    assert model.calls[0]["beam_size"] == 5
    assert model.calls[0]["vad_filter"] is False


# ─────────────────────────────────────────────────────────────────────────────
# Phase 2.1.2 — long audio → pipeline.transcribe called with correct kwargs
# ─────────────────────────────────────────────────────────────────────────────

def test_dispatch_long_uses_pipeline():
    """Long audio (>= threshold) must call pipeline.transcribe with batched kwargs.

    Phase 2.1.2 — RED. Must FAIL before _dispatch_transcription exists.
    """
    from axi.whisper_server import _dispatch_transcription, LONG_AUDIO_BATCH_SIZE

    model = _RecordingModel()
    pipeline = _RecordingPipeline()
    audio = _long_audio()
    params = {"language": "es", "beam_size": 5, "vad_filter": False}

    _dispatch_transcription(audio, params, model=model, pipeline=pipeline)

    assert len(pipeline.calls) == 1, "pipeline.transcribe must be called exactly once"
    assert len(model.calls) == 0, "model.transcribe must NOT be called for long audio"

    call = pipeline.calls[0]
    assert call["vad_filter"] is True, "vad_filter must be True for batched path"
    assert call["beam_size"] == 3, "beam_size must be 3 for batched path"
    assert call["batch_size"] == LONG_AUDIO_BATCH_SIZE, "batch_size must match LONG_AUDIO_BATCH_SIZE"
    assert call["condition_on_previous_text"] is True, \
        "condition_on_previous_text must be True for batched path"


# ─────────────────────────────────────────────────────────────────────────────
# Phase 2.1.3 — exactly at threshold → batched path (inclusive boundary)
# ─────────────────────────────────────────────────────────────────────────────

def test_dispatch_at_threshold_uses_pipeline():
    """Audio of length exactly LONG_AUDIO_SAMPLES must use the batched path.

    Boundary is INCLUSIVE: audio.size >= threshold → batched.

    Phase 2.1.3 — RED. Must FAIL before _dispatch_transcription exists.
    """
    from axi.whisper_server import _dispatch_transcription

    model = _RecordingModel()
    pipeline = _RecordingPipeline()
    audio = _threshold_audio()
    params = {"language": "es"}

    _dispatch_transcription(audio, params, model=model, pipeline=pipeline)

    assert len(pipeline.calls) == 1, \
        "audio exactly at threshold must take batched path (inclusive)"
    assert len(model.calls) == 0


def test_dispatch_long_respects_vad_flag():
    """The long (batched) path passes vad_filter=vad. Default True; vad=False is
    the no-VAD retry the server uses to recover when VAD strips a whole
    dictation (faster_whisper VAD can remove 100% of quiet/fast speech)."""
    from axi.whisper_server import _dispatch_transcription

    audio = _long_audio()

    p_on = _RecordingPipeline()
    _dispatch_transcription(audio, {"language": "es"}, model=_RecordingModel(), pipeline=p_on)
    assert p_on.calls[0]["vad_filter"] is True  # default keeps VAD (meetings)

    p_off = _RecordingPipeline()
    _dispatch_transcription(audio, {"language": "es"}, model=_RecordingModel(), pipeline=p_off, vad=False)
    assert p_off.calls[0]["vad_filter"] is False  # fallback disables VAD


# ─────────────────────────────────────────────────────────────────────────────
# Phase 2.1.4 — both paths return identical (segments, info) shape
# ─────────────────────────────────────────────────────────────────────────────

def test_dispatch_result_shape_identical():
    """Both dispatch paths must return (segments_iterable, info) with identical shape.

    Callers must not branch on which path was taken. Simulate the eager-join
    pattern used in _handle to verify both paths produce the same text output.

    Phase 2.1.4 — RED. Must FAIL before _dispatch_transcription exists.
    """
    from axi.whisper_server import _dispatch_transcription

    seg_text = "uniform output"
    segs = [_FakeSegment(seg_text)]
    info = _FakeInfo(language="es", language_probability=0.95)

    # Short path
    model = _RecordingModel(segments=segs, info=info)
    pipeline = _RecordingPipeline(segments=segs, info=info)
    audio_short = _short_audio()
    segs_out_short, info_out_short = _dispatch_transcription(
        audio_short, {}, model=model, pipeline=pipeline
    )
    text_short = " ".join(s.text.strip() for s in segs_out_short).strip()

    # Long path
    model2 = _RecordingModel(segments=segs, info=info)
    pipeline2 = _RecordingPipeline(segments=segs, info=info)
    audio_long = _long_audio()
    segs_out_long, info_out_long = _dispatch_transcription(
        audio_long, {}, model=model2, pipeline=pipeline2
    )
    text_long = " ".join(s.text.strip() for s in segs_out_long).strip()

    # Both paths produce same text and info fields
    assert text_short == text_long == seg_text
    assert info_out_short.language == info_out_long.language == "es"
    assert info_out_short.language_probability == info_out_long.language_probability


# ─────────────────────────────────────────────────────────────────────────────
# Phase 2.2.1 — BatchedInferencePipeline import smoke
# ─────────────────────────────────────────────────────────────────────────────

def test_pipeline_constructed_once_in_main():
    """BatchedInferencePipeline must be importable from faster_whisper.

    This confirms the import path used in main() works without a real GPU.

    Phase 2.2.1 — RED structural test (import-only, no GPU).
    Triangulation skipped: single assertion, import is binary pass/fail.
    """
    # If this import fails the package is missing or the API changed.
    from faster_whisper import BatchedInferencePipeline  # noqa: F401
    assert BatchedInferencePipeline is not None


# ─────────────────────────────────────────────────────────────────────────────
# Long-audio OOM fallback (_long_transcribe)
# ─────────────────────────────────────────────────────────────────────────────

class _OOMPipeline:
    """Batched pipeline that fails with a CUDA out-of-memory error."""
    def transcribe(self, audio, **kwargs):
        raise RuntimeError("CUDA failed with error out of memory")


class _BoomPipeline:
    """Batched pipeline that fails with a non-OOM error."""
    def transcribe(self, audio, **kwargs):
        raise ValueError("some other failure")


@pytest.fixture
def _no_progress(monkeypatch):
    # _long_transcribe writes a progress file; stub it so tests touch no disk.
    monkeypatch.setattr("axi.whisper_server._write_progress", lambda *a, **k: None)
    monkeypatch.setattr("axi.whisper_server._clear_progress", lambda *a, **k: None)


def test_long_transcribe_oom_falls_back_to_sequential(_no_progress):
    """On a CUDA OOM in the batched path, _long_transcribe retries on the
    sequential model.transcribe path and returns its text."""
    from axi.whisper_server import _long_transcribe
    audio = np.zeros(16000 * 121, dtype=np.float32)  # > 2 min → long path
    model = _RecordingModel(segments=[_FakeSegment("texto secuencial")])
    text, _info = _long_transcribe(audio, {"language": "es"}, model=model, pipeline=_OOMPipeline())
    assert text == "texto secuencial"
    assert len(model.calls) == 1  # sequential fallback was used


def test_long_transcribe_uses_pipeline_when_ok(_no_progress):
    """With no OOM, _long_transcribe uses the batched pipeline and never touches
    the sequential model path."""
    from axi.whisper_server import _long_transcribe
    audio = np.zeros(16000 * 121, dtype=np.float32)
    model = _RecordingModel(segments=[_FakeSegment("NO deberia usarse")])
    pipeline = _RecordingPipeline(segments=[_FakeSegment("texto batched")])
    text, _info = _long_transcribe(audio, {"language": "es"}, model=model, pipeline=pipeline)
    assert text == "texto batched"
    assert model.calls == []          # sequential path NOT used
    assert len(pipeline.calls) == 1


def test_long_transcribe_reraises_non_oom(_no_progress):
    """A non-OOM error is not swallowed by the fallback — it propagates."""
    from axi.whisper_server import _long_transcribe
    audio = np.zeros(16000 * 121, dtype=np.float32)
    with pytest.raises(ValueError):
        _long_transcribe(audio, {"language": "es"}, model=_RecordingModel(), pipeline=_BoomPipeline())
