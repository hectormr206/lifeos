"""Tests for the CPU wake-gate transcription (axi.wakeword_stt) and the
routing in transcriber.transcribe_wakeword (CPU first, GPU-server fallback)."""
from __future__ import annotations

import numpy as np
import pytest

from axi import transcriber, wakeword_stt
import axi.config as cfg
import axi.whisper_client as wc


# ── fakes ───────────────────────────────────────────────────────────────────

class _FakeInfo:
    def __init__(self, language, language_probability):
        self.language = language
        self.language_probability = language_probability


class _FakeSeg:
    def __init__(self, text):
        self.text = text


class _FakeModel:
    def __init__(self, segs, info):
        self._segs, self._info = segs, info
        self.audio = None
        self.kw = None

    def transcribe(self, audio, **kw):
        self.audio = audio
        self.kw = kw
        return iter(self._segs), self._info


def _cfg(overrides):
    def get(key, default=None):
        return overrides.get(key, default)
    return get


def _boom(*_a, **_k):
    raise AssertionError("should not be called")


# ── wakeword_stt unit ───────────────────────────────────────────────────────

def test_transcribe_none_when_model_unavailable(monkeypatch):
    monkeypatch.setattr(wakeword_stt, "_get_model", lambda name: None)
    assert wakeword_stt.transcribe(np.zeros(16000, dtype=np.float32)) is None


def test_transcribe_success_joins_segments_and_forwards_greedy(monkeypatch):
    fake = _FakeModel([_FakeSeg("Axi"), _FakeSeg(" prueba")], _FakeInfo("es", 0.92))
    monkeypatch.setattr(wakeword_stt, "_get_model", lambda name: fake)
    text, lang, prob = wakeword_stt.transcribe(
        np.zeros(16000, dtype=np.float32), language="es"
    )
    assert text == "Axi prueba"
    assert lang == "es"
    assert prob == pytest.approx(0.92)
    assert fake.kw["beam_size"] == 1
    assert fake.kw["temperature"] == 0
    assert fake.kw["condition_on_previous_text"] is False


def test_transcribe_returns_none_on_model_exception(monkeypatch):
    class _Boom:
        def transcribe(self, *a, **k):
            raise RuntimeError("boom")
    monkeypatch.setattr(wakeword_stt, "_get_model", lambda name: _Boom())
    assert wakeword_stt.transcribe(np.zeros(16000, dtype=np.float32)) is None


def test_int16_audio_is_scaled_to_float32(monkeypatch):
    fake = _FakeModel([_FakeSeg("x")], _FakeInfo("es", 0.5))
    monkeypatch.setattr(wakeword_stt, "_get_model", lambda name: fake)
    audio = np.full(10, 16384, dtype=np.int16)  # 16384/32768 == 0.5
    wakeword_stt.transcribe(audio)
    assert fake.audio.dtype == np.float32
    assert fake.audio.max() == pytest.approx(0.5)


# ── transcribe_wakeword routing ─────────────────────────────────────────────

def test_routing_uses_cpu_when_enabled(monkeypatch):
    monkeypatch.setattr(cfg, "get", _cfg({
        "wakeword_cpu_whisper_enabled": True,
        "wakeword_cpu_whisper_model": "base",
    }))
    seen = {}

    def fake_cpu(audio, *, language, model_name, initial_prompt):
        seen["model"] = model_name
        seen["lang"] = language
        return ("Axi", "es", 0.9)

    monkeypatch.setattr(wakeword_stt, "transcribe", fake_cpu)
    monkeypatch.setattr(wc, "transcribe", _boom)  # GPU server must NOT run

    out = transcriber.transcribe_wakeword(np.zeros(16000, dtype=np.float32), language="es")
    assert out == ("Axi", "es", 0.9)
    assert seen == {"model": "base", "lang": "es"}


def test_routing_falls_back_to_server_when_cpu_none(monkeypatch):
    monkeypatch.setattr(cfg, "get", _cfg({"wakeword_cpu_whisper_enabled": True}))
    monkeypatch.setattr(wakeword_stt, "transcribe", lambda *a, **k: None)
    monkeypatch.setattr(
        wc, "transcribe",
        lambda audio, **k: wc.TranscriptionResult("server", "es", 0.8),
    )
    out = transcriber.transcribe_wakeword(np.zeros(16000, dtype=np.float32))
    assert out == ("server", "es", 0.8)


def test_routing_disabled_uses_server(monkeypatch):
    monkeypatch.setattr(cfg, "get", _cfg({"wakeword_cpu_whisper_enabled": False}))
    monkeypatch.setattr(wakeword_stt, "transcribe", _boom)  # CPU must NOT run
    monkeypatch.setattr(
        wc, "transcribe",
        lambda audio, **k: wc.TranscriptionResult("server", "es", 0.7),
    )
    out = transcriber.transcribe_wakeword(np.zeros(16000, dtype=np.float32))
    assert out == ("server", "es", 0.7)
