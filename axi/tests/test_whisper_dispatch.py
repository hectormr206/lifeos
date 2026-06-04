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
    from axi.whisper_server import _dispatch_transcription

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
    assert call["batch_size"] == 8, "batch_size must be 8 for batched path"
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
