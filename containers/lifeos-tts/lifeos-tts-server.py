#!/usr/bin/env python3
"""
lifeos-tts-server.py — LifeOS Kokoro TTS HTTP Server

Binds to 127.0.0.1:$LIFEOS_TTS_ENGINE_PORT (default 8084).

Routes:
    GET  /health  → {"status":"ok","model":"Kokoro-82M","voices_loaded":N}
                    Returns 503 until warm-up completes.
    GET  /voices  → JSON array of {name, language, language_code, gender, is_default}
    POST /tts     → JSON body {text, voice?, speed?, format?}
                    Returns audio/wav (default) or audio/ogg when format="ogg".

Environment:
    LIFEOS_TTS_DEFAULT_VOICE  Default voice name (default: if_sara)
    LIFEOS_TTS_ENGINE_PORT    Bind port (default: 8084)
    LIFEOS_TTS_DEVICE         Torch device (default: cpu)
    HF_HUB_OFFLINE            Set to 1 to prevent HuggingFace downloads (set by env file)
    TRANSFORMERS_OFFLINE      Set to 1 to prevent transformers hub access

Concurrency: asyncio.Semaphore(2) — max 2 simultaneous synthesis requests.
Memory watchdog: SIGTERM self if process RSS exceeds 1400 MB.
Graceful shutdown: drains in-flight requests on SIGTERM before exit.
OGG encoding: ffmpeg subprocess (primary path, always available in image).
              soundfile/libsndfile used as fast path if available.
"""

from __future__ import annotations

import asyncio
import io
import json
import logging
import os
import resource
import signal
import struct
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path
from typing import Any

# Force offline mode before any kokoro/torch imports
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("PYTORCH_DISABLE_HUGGINGFACE_HUB_TELEMETRY", "1")

from aiohttp import web

# ---------------------------------------------------------------------------
# Structured JSON logging
# ---------------------------------------------------------------------------

class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        if record.exc_info:
            log_entry["exc"] = self.formatException(record.exc_info)
        return json.dumps(log_entry, ensure_ascii=False)


def _setup_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(logging.INFO)


_LOG = logging.getLogger("lifeos.tts")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Phonemizer needs an explicit path to libespeak-ng on Fedora — it does not probe
# standard lib dirs. Without this, every voice sounds robotic because the pipeline
# silently falls back to grapheme-level tokens. Set before any `phonemizer` import.
os.environ.setdefault("PHONEMIZER_ESPEAK_LIBRARY", "/usr/lib64/libespeak-ng.so.1")

DEFAULT_VOICE: str = os.environ.get("LIFEOS_TTS_DEFAULT_VOICE", "ef_dora")
PORT: int = int(os.environ.get("LIFEOS_TTS_ENGINE_PORT", "8084"))
DEVICE: str = os.environ.get("LIFEOS_TTS_DEVICE", "cpu")
SAMPLE_RATE: int = 24000
MEMORY_LIMIT_BYTES: int = 1400 * 1024 * 1024  # 1400 MB RSS watchdog (Kokoro-82M baseline ~900MB + headroom for concurrent synthesis)
VENV_DIR: Path = Path("/opt/lifeos/kokoro-env")
MANIFEST_PATH: Path = VENV_DIR / "voices-manifest.json"

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------

_pipeline: Any = None          # KPipeline instance after warm-up
_voices: list[dict] = []       # Loaded from voices-manifest.json
_ready: bool = False            # True after warm-up completes
_synth_sem: asyncio.Semaphore = asyncio.Semaphore(2)
_shutdown_event: asyncio.Event = asyncio.Event()

# ---------------------------------------------------------------------------
# OGG encoding helpers
# ---------------------------------------------------------------------------

def _wav_bytes_to_ogg(wav_bytes: bytes) -> bytes:
    """Convert WAV bytes to OGG/Vorbis bytes using ffmpeg subprocess.

    ffmpeg is the primary path — reliably available in the LifeOS image.
    soundfile/libsndfile is used as a fast path if available, but
    python:3.12-slim's libsndfile may not be compiled with Vorbis support,
    so ffmpeg is the safe fallback.
    """
    # Fast path: try soundfile first (no subprocess overhead)
    try:
        import soundfile as sf
        import numpy as np
        with io.BytesIO(wav_bytes) as wav_buf:
            with wave.open(wav_buf) as wf:
                n_frames = wf.getnframes()
                n_channels = wf.getnchannels()
                sampwidth = wf.getsampwidth()
                framerate = wf.getframerate()
                raw = wf.readframes(n_frames)
        # Convert to float32 numpy array
        if sampwidth == 2:
            audio = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
        else:
            audio = np.frombuffer(raw, dtype=np.float32)
        if n_channels > 1:
            audio = audio.reshape(-1, n_channels)
        ogg_buf = io.BytesIO()
        sf.write(ogg_buf, audio, framerate, format="OGG", subtype="VORBIS")
        return ogg_buf.getvalue()
    except Exception:
        pass  # Fall through to ffmpeg

    # Primary path: ffmpeg subprocess
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as wav_tmp:
        wav_tmp.write(wav_bytes)
        wav_tmp_path = wav_tmp.name
    ogg_tmp_path = wav_tmp_path.replace(".wav", ".ogg")
    try:
        result = subprocess.run(
            [
                "ffmpeg", "-y",
                "-i", wav_tmp_path,
                "-c:a", "libvorbis",
                "-q:a", "4",
                ogg_tmp_path,
            ],
            capture_output=True,
            timeout=30,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"ffmpeg exited {result.returncode}: {result.stderr.decode()[:200]}"
            )
        return Path(ogg_tmp_path).read_bytes()
    finally:
        try:
            os.unlink(wav_tmp_path)
        except OSError:
            pass
        try:
            os.unlink(ogg_tmp_path)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Synthesis helpers
# ---------------------------------------------------------------------------

def _synth_to_wav(text: str, voice: str, speed: float = 1.0) -> bytes:
    """Synthesise text → WAV bytes using KPipeline (blocking, CPU)."""
    import numpy as np

    audio_chunks: list[Any] = []
    for _, _, audio in _pipeline(text, voice=voice, speed=speed):
        if audio is not None:
            audio_chunks.append(audio)

    if not audio_chunks:
        raise RuntimeError("KPipeline returned no audio chunks")

    audio_np = np.concatenate(audio_chunks, axis=0)
    # Normalise to int16
    audio_np = np.clip(audio_np, -1.0, 1.0)
    audio_int16 = (audio_np * 32767).astype(np.int16)

    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(audio_int16.tobytes())
    return buf.getvalue()


def _resolve_voice(requested: str | None) -> str | None:
    """Return the voice name to use, or None if the requested voice is unknown.

    Returns DEFAULT_VOICE if requested is None/empty.
    Returns None if a non-empty requested voice is not in the voices list.
    """
    known = {v["name"] for v in _voices}
    if not requested:
        return DEFAULT_VOICE
    if requested in known:
        return requested
    return None


# ---------------------------------------------------------------------------
# Memory watchdog
# ---------------------------------------------------------------------------

async def _memory_watchdog() -> None:
    """Periodically check RSS; SIGTERM self if over the configured limit."""
    while not _shutdown_event.is_set():
        try:
            rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024  # KB → bytes
            if rss > MEMORY_LIMIT_BYTES:
                _LOG.warning(
                    "Memory watchdog: RSS %d MB exceeds limit %d MB — sending SIGTERM",
                    rss // 1024 // 1024,
                    MEMORY_LIMIT_BYTES // 1024 // 1024,
                )
                os.kill(os.getpid(), signal.SIGTERM)
        except Exception as exc:
            _LOG.error("Memory watchdog error: %s", exc)
        await asyncio.sleep(30)


# ---------------------------------------------------------------------------
# HTTP route handlers
# ---------------------------------------------------------------------------

async def handle_health(request: web.Request) -> web.Response:
    if not _ready:
        return web.Response(
            status=503,
            content_type="application/json",
            text=json.dumps({"status": "warming_up", "model": "Kokoro-82M"}),
        )
    return web.Response(
        content_type="application/json",
        text=json.dumps({
            "status": "ok",
            "model": "Kokoro-82M",
            "voices_loaded": len(_voices),
        }),
    )


async def handle_voices(request: web.Request) -> web.Response:
    return web.Response(
        content_type="application/json",
        text=json.dumps(_voices, ensure_ascii=False),
    )


async def handle_tts(request: web.Request) -> web.Response:
    if not _ready:
        return web.Response(
            status=503,
            content_type="application/json",
            text=json.dumps({"error": "not_ready", "detail": "Server warming up"}),
        )

    # Parse request body
    try:
        body = await request.json()
    except Exception:
        return web.Response(
            status=400,
            content_type="application/json",
            text=json.dumps({"error": "invalid_json", "detail": "Request body must be JSON"}),
        )

    text: str = body.get("text", "").strip()
    if not text:
        return web.Response(
            status=400,
            content_type="application/json",
            text=json.dumps({"error": "empty_text", "detail": "text field is required and must not be empty"}),
        )

    requested_voice: str | None = body.get("voice") or None
    speed: float = float(body.get("speed", 1.0))
    fmt: str = (body.get("format") or "wav").lower()

    # Validate format
    if fmt not in ("wav", "ogg"):
        return web.Response(
            status=400,
            content_type="application/json",
            text=json.dumps({"error": "invalid_format", "detail": f"format must be 'wav' or 'ogg', got '{fmt}'"}),
        )

    # Resolve voice
    voice = _resolve_voice(requested_voice)
    if voice is None:
        return web.Response(
            status=400,
            content_type="application/json",
            text=json.dumps({
                "error": "unknown_voice",
                "detail": f"{requested_voice} is not a valid Kokoro voice",
            }),
        )

    # Concurrency guard
    async with _synth_sem:
        try:
            loop = asyncio.get_event_loop()
            wav_bytes = await loop.run_in_executor(
                None, _synth_to_wav, text, voice, speed
            )
        except Exception as exc:
            _LOG.error("Synthesis failed: %s", exc, exc_info=True)
            return web.Response(
                status=500,
                content_type="application/json",
                text=json.dumps({
                    "error": "synthesis_failed",
                    "detail": str(exc),
                }),
            )

    if fmt == "ogg":
        try:
            loop = asyncio.get_event_loop()
            audio_bytes = await loop.run_in_executor(None, _wav_bytes_to_ogg, wav_bytes)
            content_type = "audio/ogg"
        except Exception as exc:
            _LOG.error("OGG encoding failed: %s", exc, exc_info=True)
            return web.Response(
                status=500,
                content_type="application/json",
                text=json.dumps({
                    "error": "ogg_encoding_failed",
                    "detail": str(exc),
                }),
            )
    else:
        audio_bytes = wav_bytes
        content_type = "audio/wav"

    return web.Response(
        status=200,
        content_type=content_type,
        body=audio_bytes,
    )


# ---------------------------------------------------------------------------
# Application startup
# ---------------------------------------------------------------------------

def _load_voices_manifest() -> list[dict]:
    """Load voices-manifest.json; return empty list if not found."""
    if not MANIFEST_PATH.exists():
        _LOG.warning("voices-manifest.json not found at %s", MANIFEST_PATH)
        return []
    try:
        data = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        if not isinstance(data, list):
            _LOG.error("voices-manifest.json is not a JSON array")
            return []
        return data
    except Exception as exc:
        _LOG.error("Failed to load voices-manifest.json: %s", exc)
        return []


async def _startup(app: web.Application) -> None:
    """Load Kokoro model, warm up, mark ready."""
    global _pipeline, _voices, _ready

    _LOG.info("Loading voices manifest from %s", MANIFEST_PATH)
    _voices = _load_voices_manifest()
    _LOG.info("Loaded %d voices from manifest", len(_voices))

    _LOG.info("Importing KPipeline (device=%s)", DEVICE)
    try:
        from kokoro import KPipeline
        _pipeline = KPipeline(lang_code="e", device=DEVICE)
    except Exception as exc:
        _LOG.error("Failed to load KPipeline: %s", exc, exc_info=True)
        raise

    _LOG.info("Warming up with default voice '%s'", DEFAULT_VOICE)
    try:
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(
            None, _synth_to_wav, "Hola, sistema listo.", DEFAULT_VOICE, 1.0
        )
        _LOG.info("Warm-up complete")
    except Exception as exc:
        _LOG.warning("Warm-up failed (non-fatal): %s", exc)

    _ready = True
    _LOG.info("Server ready on 127.0.0.1:%d", PORT)

    # Start background tasks
    app["_watchdog_task"] = asyncio.ensure_future(_memory_watchdog())


async def _shutdown(app: web.Application) -> None:
    """Drain in-flight requests, cancel background tasks."""
    _LOG.info("Shutting down — draining in-flight requests")
    _shutdown_event.set()
    watchdog = app.get("_watchdog_task")
    if watchdog:
        watchdog.cancel()
        try:
            await watchdog
        except asyncio.CancelledError:
            pass
    _LOG.info("Shutdown complete")


def _handle_sigterm(signum: int, frame: Any) -> None:
    _LOG.info("Received SIGTERM — initiating graceful shutdown")
    _shutdown_event.set()
    # aiohttp will handle the rest via on_shutdown


def _build_app() -> web.Application:
    app = web.Application()
    app.router.add_get("/health", handle_health)
    app.router.add_get("/voices", handle_voices)
    app.router.add_post("/tts", handle_tts)
    app.on_startup.append(_startup)
    app.on_shutdown.append(_shutdown)
    return app


def main() -> None:
    _setup_logging()
    signal.signal(signal.SIGTERM, _handle_sigterm)

    app = _build_app()
    _LOG.info("Starting LifeOS TTS server on 127.0.0.1:%d", PORT)
    web.run_app(
        app,
        host="127.0.0.1",
        port=PORT,
        access_log=None,  # We handle logging ourselves
        handle_signals=True,
    )


if __name__ == "__main__":
    main()
