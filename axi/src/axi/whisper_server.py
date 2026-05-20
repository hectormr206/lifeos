"""Shared Whisper RPC server.

Loads `faster-whisper` ONCE on GPU and exposes it over a Unix socket so
`axi-voice` (Spanish dictation, sporadic) and `axi-translate` (English
transcription, 1-2 Hz while running) both reuse the same model. This
saves a full ~1.6 GB VRAM copy of the model and a ~600 MB CUDA context
that we used to pay twice.

Protocol — one request per connection, length-prefixed binary:

  Request:
    uint32 BE  params_json_len
    bytes      params_json (UTF-8)          — kwargs forwarded to
                                              `WhisperModel.transcribe`
                                              plus optional `sr` (sample
                                              rate, default 16000).
    uint32 BE  audio_byte_len
    bytes      audio                         — mono PCM float32 LE.

  Response:
    uint32 BE  response_json_len
    bytes      response_json (UTF-8)         — either
                                                {"text": "...", "language": "es",
                                                 "language_probability": 0.97}
                                              or
                                                {"error": "..."}.

A single `threading.Lock` serialises calls into `model.transcribe`
because faster-whisper's CTranslate2 backend is not safe for concurrent
calls on the same Translator instance. In practice translate's 1-2 Hz
cadence and voice's user-triggered toggle rarely collide, and when they
do the wait is one transcribe cycle (~150-300 ms).
"""
from __future__ import annotations

# CUDA preload MUST happen before faster_whisper / ctranslate2 import. Same
# pattern as the existing transcriber.py.
from axi import _cuda_preload  # noqa: F401

import json
import logging
import os
import signal
import socket
import struct
import sys
import threading
import time
from pathlib import Path

import numpy as np
from faster_whisper import WhisperModel

log = logging.getLogger("axi.whisper_server")

DEFAULT_MODEL = "large-v3-turbo"
DEFAULT_DEVICE = "cuda"
DEFAULT_COMPUTE = "float16"

# /run/user/$UID/axi/whisper.sock — same dir convention as axi voice.sock.
RUNTIME_DIR = Path(
    os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
) / "axi"
SOCKET_PATH = RUNTIME_DIR / "whisper.sock"


def _read_exact(conn: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("client closed mid-message")
        buf.extend(chunk)
    return bytes(buf)


def _send_response(conn: socket.socket, obj: dict) -> None:
    payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    conn.sendall(struct.pack("!I", len(payload)) + payload)


def _handle(conn: socket.socket, model: WhisperModel, lock: threading.Lock) -> None:
    try:
        (params_len,) = struct.unpack("!I", _read_exact(conn, 4))
        if params_len > 64 * 1024:
            raise ValueError(f"params too large: {params_len}")
        params = json.loads(_read_exact(conn, params_len).decode("utf-8"))
        (audio_len,) = struct.unpack("!I", _read_exact(conn, 4))
        # Cap at ~120 s of fp32 16 kHz mono = 7.5 MB — generous for a 6-8 s
        # window plus headroom.
        if audio_len > 16 * 1024 * 1024:
            raise ValueError(f"audio too large: {audio_len}")
        audio_bytes = _read_exact(conn, audio_len)
        audio = np.frombuffer(audio_bytes, dtype=np.float32)
        if audio.size == 0:
            _send_response(conn, {"text": "", "language": "", "language_probability": 0.0})
            return

        # `sr` is informational only (faster-whisper expects 16 kHz). We pop
        # it before forwarding kwargs to .transcribe().
        params.pop("sr", None)
        t0 = time.monotonic()
        with lock:
            segments, info = model.transcribe(audio, **params)
            text = " ".join(s.text.strip() for s in segments).strip()
        dt_ms = (time.monotonic() - t0) * 1000.0
        log.debug(
            "transcribed %.2fs audio in %.0fms (lang=%s, %d chars)",
            audio.size / 16000.0, dt_ms, info.language, len(text),
        )
        _send_response(conn, {
            "text": text,
            "language": info.language,
            "language_probability": float(info.language_probability),
        })
    except Exception as e:  # noqa: BLE001 — protocol boundary, surface every error
        log.warning("request failed: %s", e)
        try:
            _send_response(conn, {"error": f"{type(e).__name__}: {e}"})
        except OSError:
            pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

    model_name = os.environ.get("AXI_WHISPER_MODEL", DEFAULT_MODEL)
    device = os.environ.get("AXI_WHISPER_DEVICE", DEFAULT_DEVICE)
    compute = os.environ.get(
        "AXI_WHISPER_COMPUTE_TYPE",
        "int8" if device == "cpu" else DEFAULT_COMPUTE,
    )
    log.info("loading Whisper (%s, %s, %s)…", model_name, device, compute)
    model = WhisperModel(model_name, device=device, compute_type=compute)
    # Warm with a 1 s silent buffer so the first real request is fast.
    list(model.transcribe(np.zeros(16000, dtype=np.float32), language="en", beam_size=1)[0])
    log.info("Whisper warmed")

    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    try:
        SOCKET_PATH.unlink()
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(str(SOCKET_PATH))
    server.listen(16)
    os.chmod(SOCKET_PATH, 0o600)
    log.info("listening on %s", SOCKET_PATH)

    lock = threading.Lock()
    stop = threading.Event()

    def _shutdown(*_):
        log.info("SIGTERM — shutting down")
        stop.set()
        try:
            server.close()
        except OSError:
            pass

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    while not stop.is_set():
        try:
            conn, _addr = server.accept()
        except OSError:
            break
        threading.Thread(
            target=_handle,
            args=(conn, model, lock),
            daemon=True,
        ).start()

    try:
        SOCKET_PATH.unlink()
    except FileNotFoundError:
        pass
    log.info("bye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
