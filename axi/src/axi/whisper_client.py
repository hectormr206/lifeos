"""Thin Unix-socket client for `axi-whisper.service`.

Both `axi-voice` and `axi-translate` use this instead of importing
faster-whisper directly, so the model is loaded once on GPU by the shared
server. See `whisper_server.py` for the protocol.
"""
from __future__ import annotations

import json
import logging
import os
import socket
import struct
import time
from pathlib import Path
from typing import Any

import numpy as np

log = logging.getLogger("axi.whisper_client")

SOCKET_PATH = Path(
    os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
) / "axi" / "whisper.sock"

DEFAULT_CONNECT_TIMEOUT_S = 30.0  # tolerant for server cold start
DEFAULT_REQUEST_TIMEOUT_S = 60.0


class WhisperServiceError(RuntimeError):
    """Raised when the shared whisper service returns an error or is
    unreachable. Callers can decide to retry, fall back, or surface."""


class TranscriptionResult:
    __slots__ = ("text", "language", "language_probability")

    def __init__(self, text: str, language: str, language_probability: float):
        self.text = text
        self.language = language
        self.language_probability = language_probability

    def __repr__(self) -> str:
        return (
            f"TranscriptionResult(text={self.text!r}, "
            f"language={self.language!r}, prob={self.language_probability:.2f})"
        )


def _read_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise WhisperServiceError("server closed connection mid-response")
        buf.extend(chunk)
    return bytes(buf)


def _connect(timeout_s: float) -> socket.socket:
    """Connect to the server, retrying with backoff up to `timeout_s`.
    Tolerates server cold-start (~3-5 s to load the model)."""
    deadline = time.monotonic() + timeout_s
    delay = 0.1
    last_err: BaseException | None = None
    while time.monotonic() < deadline:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(str(SOCKET_PATH))
            return sock
        except (FileNotFoundError, ConnectionRefusedError, OSError) as e:
            last_err = e
            try:
                sock.close()
            except OSError:
                pass
            time.sleep(delay)
            delay = min(delay * 1.6, 1.0)
    raise WhisperServiceError(
        f"could not connect to {SOCKET_PATH} after {timeout_s:.0f}s: {last_err}"
    )


def transcribe(
    audio: np.ndarray,
    *,
    language: str | None = None,
    beam_size: int = 1,
    initial_prompt: str | None = None,
    vad_filter: bool = False,
    vad_parameters: dict | None = None,
    no_speech_threshold: float | None = None,
    compression_ratio_threshold: float | None = None,
    condition_on_previous_text: bool = False,
    extra_kwargs: dict[str, Any] | None = None,
    connect_timeout_s: float = DEFAULT_CONNECT_TIMEOUT_S,
    request_timeout_s: float = DEFAULT_REQUEST_TIMEOUT_S,
) -> TranscriptionResult:
    """Transcribe a mono float32 audio array via the shared service.

    Audio is normalised to float32 if a non-float dtype arrives (int16 is
    auto-scaled by 32768 — matches the PyAudio paInt16 capture path used
    by axi-translate). All keyword args are forwarded to the underlying
    `WhisperModel.transcribe` call so behaviour matches a direct call.
    """
    if audio.dtype != np.float32:
        if audio.dtype == np.int16:
            audio = audio.astype(np.float32) / 32768.0
        else:
            audio = audio.astype(np.float32)
    if not audio.flags["C_CONTIGUOUS"]:
        audio = np.ascontiguousarray(audio)

    params: dict[str, Any] = {
        "beam_size": int(beam_size),
        "condition_on_previous_text": bool(condition_on_previous_text),
        "vad_filter": bool(vad_filter),
    }
    if language is not None:
        params["language"] = language
    if initial_prompt is not None:
        params["initial_prompt"] = initial_prompt
    if vad_parameters is not None:
        params["vad_parameters"] = vad_parameters
    if no_speech_threshold is not None:
        params["no_speech_threshold"] = float(no_speech_threshold)
    if compression_ratio_threshold is not None:
        params["compression_ratio_threshold"] = float(compression_ratio_threshold)
    if extra_kwargs:
        params.update(extra_kwargs)

    payload = json.dumps(params, ensure_ascii=False).encode("utf-8")
    audio_bytes = audio.tobytes()

    sock = _connect(connect_timeout_s)
    try:
        sock.settimeout(request_timeout_s)
        sock.sendall(struct.pack("!I", len(payload)) + payload)
        sock.sendall(struct.pack("!I", len(audio_bytes)) + audio_bytes)
        (resp_len,) = struct.unpack("!I", _read_exact(sock, 4))
        resp = json.loads(_read_exact(sock, resp_len).decode("utf-8"))
    finally:
        try:
            sock.close()
        except OSError:
            pass

    if "error" in resp:
        raise WhisperServiceError(resp["error"])
    return TranscriptionResult(
        text=resp.get("text", ""),
        language=resp.get("language", ""),
        language_probability=float(resp.get("language_probability", 0.0)),
    )


def ping(timeout_s: float = 2.0) -> bool:
    """Check if the server is reachable. Used by doctor / preflight."""
    try:
        sock = _connect(timeout_s)
        sock.close()
        return True
    except WhisperServiceError:
        return False
