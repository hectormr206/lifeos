"""PR1 transport tests: OSError wrapping, cap constant, timeout constant.

Phase 1.3 — RED tests for:
  1.3.1  BrokenPipeError from sendall → WhisperServiceError
  1.3.2  OSError from recv → WhisperServiceError
  1.3.3  MAX_AUDIO_BYTES constant == 400 MB
  1.3.4  DEFAULT_REQUEST_TIMEOUT_S == 600.0
"""
from __future__ import annotations

import socket
import struct
import unittest.mock as mock

import numpy as np
import pytest


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def _make_audio() -> np.ndarray:
    """1-second 16kHz float32 mono waveform."""
    return np.zeros(16000, dtype=np.float32)


class _FakeSocket:
    """Minimal socket stand-in; sendall and recv are overrideable."""

    def __init__(self, *, sendall_exc=None, recv_exc=None, recv_data=None):
        self._sendall_exc = sendall_exc
        self._recv_exc = recv_exc
        self._recv_data = recv_data or b""
        self._closed = False
        self._timeout = None

    def settimeout(self, t):
        self._timeout = t

    def sendall(self, data):
        if self._sendall_exc is not None:
            raise self._sendall_exc

    def recv(self, n):
        if self._recv_exc is not None:
            raise self._recv_exc
        return self._recv_data[:n]

    def close(self):
        self._closed = True


# ─────────────────────────────────────────────────────────────────────────────
# Phase 1.3.1 — BrokenPipeError from sendall → WhisperServiceError
# ─────────────────────────────────────────────────────────────────────────────

def test_oserror_wrapped_as_whisper_service_error_sendall(monkeypatch):
    """BrokenPipeError from sendall must be re-raised as WhisperServiceError.

    Phase 1.3.1 — RED. Must FAIL before OSError catch is added.
    """
    from axi import whisper_client
    from axi.whisper_client import WhisperServiceError

    fake_sock = _FakeSocket(sendall_exc=BrokenPipeError("pipe broken"))
    monkeypatch.setattr(whisper_client, "_connect", lambda *a, **kw: fake_sock)

    with pytest.raises(WhisperServiceError, match="transport failed"):
        whisper_client.transcribe(_make_audio())


# ─────────────────────────────────────────────────────────────────────────────
# Phase 1.3.2 — OSError from recv → WhisperServiceError
# ─────────────────────────────────────────────────────────────────────────────

def test_oserror_on_recv_wrapped(monkeypatch):
    """OSError during response recv must be re-raised as WhisperServiceError.

    Phase 1.3.2 — RED. Must FAIL before OSError catch is added.
    """
    from axi import whisper_client
    from axi.whisper_client import WhisperServiceError

    # sendall succeeds, but recv raises OSError.
    fake_sock = _FakeSocket(recv_exc=OSError("connection reset"))
    monkeypatch.setattr(whisper_client, "_connect", lambda *a, **kw: fake_sock)

    with pytest.raises(WhisperServiceError, match="transport failed"):
        whisper_client.transcribe(_make_audio())


# ─────────────────────────────────────────────────────────────────────────────
# Phase 1.3.3 — MAX_AUDIO_BYTES constant == 400 MB
# ─────────────────────────────────────────────────────────────────────────────

def test_cap_constant_is_400mb():
    """MAX_AUDIO_BYTES on whisper_server must equal 400 * 1024 * 1024.

    Phase 1.3.3 — RED. Must FAIL while cap is still 16 MB.
    """
    from axi import whisper_server
    assert hasattr(whisper_server, "MAX_AUDIO_BYTES"), \
        "MAX_AUDIO_BYTES constant not found in whisper_server"
    assert whisper_server.MAX_AUDIO_BYTES == 400 * 1024 * 1024, \
        f"expected 400MB, got {whisper_server.MAX_AUDIO_BYTES / (1024**2):.0f}MB"


# ─────────────────────────────────────────────────────────────────────────────
# Phase 1.3.4 — DEFAULT_REQUEST_TIMEOUT_S == 600.0
# ─────────────────────────────────────────────────────────────────────────────

def test_default_request_timeout_is_600s():
    """DEFAULT_REQUEST_TIMEOUT_S on whisper_client must equal 600.0.

    Phase 1.3.4 — RED. Must FAIL while timeout is still 60.0.
    """
    from axi import whisper_client
    assert whisper_client.DEFAULT_REQUEST_TIMEOUT_S == 600.0, \
        f"expected 600.0, got {whisper_client.DEFAULT_REQUEST_TIMEOUT_S}"
