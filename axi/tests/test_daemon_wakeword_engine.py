"""TDD tests for daemon.start_wakeword_listener engine selection.

Tests that:
1. wakeword_engine="openwakeword" → OWWWakeWordListener is instantiated.
2. wakeword_engine="vad_whisper"  → WakeWordListener (legacy) is instantiated.
3. OWW load failure (ImportError or model error) → falls back to WakeWordListener
   with a WARNING log.
"""
from __future__ import annotations

import logging
import threading
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

from axi.daemon import Daemon
from axi.recorder import SAMPLE_RATE


# ──────────────────────────────────────────────────────────────────────────────
# Minimal fake support objects
# ──────────────────────────────────────────────────────────────────────────────

class _FakeRecorder:
    def __init__(self) -> None:
        self._recording = False
        self.active_source = "fake"

    @property
    def is_recording(self) -> bool:
        return self._recording

    def start(self) -> str:
        self._recording = True
        return self.active_source

    def stop(self) -> np.ndarray:
        self._recording = False
        t = np.arange(SAMPLE_RATE, dtype=np.float32) / SAMPLE_RATE
        return (0.05 * np.sin(2 * np.pi * 220.0 * t)).astype(np.float32)


def _make_daemon() -> Daemon:
    """Build a Daemon instance with all I/O faked — no hardware, no Whisper, no brain."""
    d = Daemon.__new__(Daemon)
    d.recorder = _FakeRecorder()
    d.transcriber = MagicMock()
    d.transcriber.transcribe.return_value = ("hola", "es", 0.9)
    d.brain_ask = MagicMock(return_value="ok")
    d.memory = MagicMock()
    d.memory.messages.return_value = []
    d.memory.relevant_facts.return_value = []
    # state is a property backed by _state + _state_lock
    d._state = "idle"
    d._state_lock = threading.Lock()
    d._transcribe_lock = threading.Lock()
    d._wakeword_listener = None
    d.vision_capture = MagicMock(return_value=None)
    d._pending_screenshot = None
    d.meeting = None
    return d


def _mock_listener_cls(name: str = "MockListener") -> MagicMock:
    """Return a mock class whose instances have .start() and .stop()."""
    instance = MagicMock()
    instance.start.return_value = None
    instance.stop.return_value = None
    cls = MagicMock(return_value=instance)
    cls.__name__ = name
    return cls


# ──────────────────────────────────────────────────────────────────────────────
# TEST 1: wakeword_engine="openwakeword" → OWWWakeWordListener is used
# ──────────────────────────────────────────────────────────────────────────────

def test_oww_engine_selects_oww_listener():
    """When config has wakeword_engine=openwakeword, OWWWakeWordListener is used."""
    daemon = _make_daemon()

    oww_cls = _mock_listener_cls("OWWWakeWordListener")
    legacy_cls = _mock_listener_cls("WakeWordListener")

    config_values = {
        "wakeword_engine": "openwakeword",
        "wakeword_model_path": "/some/axi.onnx",
        "wakeword_threshold": 0.5,
        "language": "es-MX",
    }

    with patch("axi.daemon.config") as mock_config, \
         patch("axi.wakeword.OWWWakeWordListener", oww_cls), \
         patch("axi.wakeword.WakeWordListener", legacy_cls), \
         patch("axi.daemon._transcribe_wakeword", return_value=("", "es", 0.0)), \
         patch("axi.daemon.notify", return_value=None):
        mock_config.get = lambda key, default=None: config_values.get(key, default)
        daemon.start_wakeword_listener()

    assert oww_cls.called, "OWWWakeWordListener was NOT instantiated for engine=openwakeword"
    assert not legacy_cls.called, "WakeWordListener (legacy) was instantiated unexpectedly"
    oww_cls.return_value.start.assert_called_once()


# ──────────────────────────────────────────────────────────────────────────────
# TEST 2: wakeword_engine="vad_whisper" → WakeWordListener (legacy) is used
# ──────────────────────────────────────────────────────────────────────────────

def test_vad_whisper_engine_selects_legacy_listener():
    """When config has wakeword_engine=vad_whisper, WakeWordListener is used."""
    daemon = _make_daemon()

    oww_cls = _mock_listener_cls("OWWWakeWordListener")
    legacy_cls = _mock_listener_cls("WakeWordListener")

    config_values = {
        "wakeword_engine": "vad_whisper",
        "wakeword_model_path": "alexa",
        "wakeword_threshold": 0.5,
        "language": "es-MX",
    }

    with patch("axi.daemon.config") as mock_config, \
         patch("axi.wakeword.OWWWakeWordListener", oww_cls), \
         patch("axi.wakeword.WakeWordListener", legacy_cls), \
         patch("axi.daemon._transcribe_wakeword", return_value=("", "es", 0.0)), \
         patch("axi.daemon.notify", return_value=None):
        mock_config.get = lambda key, default=None: config_values.get(key, default)
        daemon.start_wakeword_listener()

    assert legacy_cls.called, "WakeWordListener was NOT instantiated for engine=vad_whisper"
    assert not oww_cls.called, "OWWWakeWordListener was instantiated unexpectedly"
    legacy_cls.return_value.start.assert_called_once()


# ──────────────────────────────────────────────────────────────────────────────
# TEST 3: OWW instantiation raises ImportError → falls back to legacy + WARN
# ──────────────────────────────────────────────────────────────────────────────

def test_oww_engine_falls_back_to_legacy_on_import_error(caplog):
    """When OWWWakeWordListener raises ImportError, legacy WakeWordListener is used + WARN."""
    daemon = _make_daemon()

    legacy_cls = _mock_listener_cls("WakeWordListener")
    oww_cls = MagicMock(side_effect=ImportError("openwakeword not installed"))
    oww_cls.__name__ = "OWWWakeWordListener"

    config_values = {
        "wakeword_engine": "openwakeword",
        "wakeword_model_path": "/missing/axi.onnx",
        "wakeword_threshold": 0.5,
        "language": "es-MX",
    }

    with patch("axi.daemon.config") as mock_config, \
         patch("axi.wakeword.OWWWakeWordListener", oww_cls), \
         patch("axi.wakeword.WakeWordListener", legacy_cls), \
         patch("axi.daemon._transcribe_wakeword", return_value=("", "es", 0.0)), \
         patch("axi.daemon.notify", return_value=None), \
         caplog.at_level(logging.WARNING, logger="axi.daemon"):
        mock_config.get = lambda key, default=None: config_values.get(key, default)
        daemon.start_wakeword_listener()

    assert legacy_cls.called, "Legacy WakeWordListener was NOT used as fallback"
    legacy_cls.return_value.start.assert_called_once()

    warning_texts = " ".join(r.message for r in caplog.records if r.levelno >= logging.WARNING)
    assert any(
        kw in warning_texts.lower()
        for kw in ("falling back", "vad_whisper", "fallback", "failed")
    ), f"Expected fallback warning. Got: {warning_texts!r}"


# ──────────────────────────────────────────────────────────────────────────────
# TEST 3b: OWW raises RuntimeError (bad model path) → same fallback
# ──────────────────────────────────────────────────────────────────────────────

def test_oww_engine_falls_back_on_model_load_error(caplog):
    """When OWWWakeWordListener raises RuntimeError (bad model), legacy is used."""
    daemon = _make_daemon()

    legacy_cls = _mock_listener_cls("WakeWordListener")
    oww_cls = MagicMock(side_effect=RuntimeError("ONNX file not found"))
    oww_cls.__name__ = "OWWWakeWordListener"

    config_values = {
        "wakeword_engine": "openwakeword",
        "wakeword_model_path": "/nonexistent/axi.onnx",
        "wakeword_threshold": 0.5,
        "language": "es-MX",
    }

    with patch("axi.daemon.config") as mock_config, \
         patch("axi.wakeword.OWWWakeWordListener", oww_cls), \
         patch("axi.wakeword.WakeWordListener", legacy_cls), \
         patch("axi.daemon._transcribe_wakeword", return_value=("", "es", 0.0)), \
         patch("axi.daemon.notify", return_value=None), \
         caplog.at_level(logging.WARNING, logger="axi.daemon"):
        mock_config.get = lambda key, default=None: config_values.get(key, default)
        daemon.start_wakeword_listener()

    assert legacy_cls.called, "Legacy WakeWordListener was NOT used as fallback on model error"
    warning_texts = " ".join(r.message for r in caplog.records if r.levelno >= logging.WARNING)
    assert any(
        kw in warning_texts.lower()
        for kw in ("falling back", "vad_whisper", "fallback", "failed")
    ), f"Expected fallback warning. Got: {warning_texts!r}"


# ──────────────────────────────────────────────────────────────────────────────
# TRIANGULATE 4: idempotency — second call is a no-op (no second instantiation)
# ──────────────────────────────────────────────────────────────────────────────

def test_start_wakeword_listener_is_idempotent():
    """Calling start_wakeword_listener a second time when already running is a no-op."""
    daemon = _make_daemon()

    oww_cls = _mock_listener_cls("OWWWakeWordListener")
    legacy_cls = _mock_listener_cls("WakeWordListener")

    config_values = {
        "wakeword_engine": "openwakeword",
        "wakeword_model_path": "/some/axi.onnx",
        "wakeword_threshold": 0.7,
        "language": "es-MX",
    }

    with patch("axi.daemon.config") as mock_config, \
         patch("axi.wakeword.OWWWakeWordListener", oww_cls), \
         patch("axi.wakeword.WakeWordListener", legacy_cls), \
         patch("axi.daemon._transcribe_wakeword", return_value=("", "es", 0.0)), \
         patch("axi.daemon.notify", return_value=None):
        mock_config.get = lambda key, default=None: config_values.get(key, default)
        daemon.start_wakeword_listener()
        daemon.start_wakeword_listener()  # second call — must be a no-op

    # OWW class must have been instantiated exactly ONCE
    assert oww_cls.call_count == 1, (
        f"OWWWakeWordListener was instantiated {oww_cls.call_count} times; expected 1"
    )
    oww_cls.return_value.start.assert_called_once()


# ──────────────────────────────────────────────────────────────────────────────
# TRIANGULATE 5: OWW kwargs — model_path and threshold are forwarded correctly
# ──────────────────────────────────────────────────────────────────────────────

def test_oww_kwargs_forwarded_correctly():
    """OWWWakeWordListener is called with the model_path and threshold from config."""
    daemon = _make_daemon()

    oww_cls = _mock_listener_cls("OWWWakeWordListener")
    legacy_cls = _mock_listener_cls("WakeWordListener")

    config_values = {
        "wakeword_engine": "openwakeword",
        "wakeword_model_path": "/home/user/models/axi.onnx",
        "wakeword_threshold": 0.75,
        "language": "es-MX",
    }

    with patch("axi.daemon.config") as mock_config, \
         patch("axi.wakeword.OWWWakeWordListener", oww_cls), \
         patch("axi.wakeword.WakeWordListener", legacy_cls), \
         patch("axi.daemon._transcribe_wakeword", return_value=("", "es", 0.0)), \
         patch("axi.daemon.notify", return_value=None):
        mock_config.get = lambda key, default=None: config_values.get(key, default)
        daemon.start_wakeword_listener()

    _args, kwargs = oww_cls.call_args
    assert kwargs.get("oww_model_path") == "/home/user/models/axi.onnx", (
        f"oww_model_path not forwarded; got {kwargs}"
    )
    assert kwargs.get("oww_threshold") == 0.75, (
        f"oww_threshold not forwarded; got {kwargs}"
    )
