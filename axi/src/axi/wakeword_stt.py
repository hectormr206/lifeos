"""Lightweight CPU Whisper for the always-listening wake-gate.

The wake-word listener transcribes EVERY voiced segment to check for "Axi".
Routing that to the shared GPU whisper server (large-v3-turbo) keeps the GPU
awake around the clock — a real, constant power/battery drain even when plugged
in. This module runs a SMALL model (base/tiny, int8) IN-PROCESS on the CPU for
the wake-gate only, so the GPU stays asleep until an actual command needs the
high-quality server.

The model is lazy-loaded on first use. If faster-whisper is unavailable or the
model fails to load/transcribe, every entry point returns ``None`` so the caller
falls back to the shared GPU server — the wake-gate never breaks.
"""
from __future__ import annotations

import logging
import threading

import numpy as np

log = logging.getLogger("axi.wakeword_stt")

_model = None
_model_lock = threading.Lock()
_load_failed = False
_loaded_name: str | None = None


def _get_model(model_name: str):
    """Lazy-load (once) a CPU faster-whisper model. None on any failure."""
    global _model, _load_failed, _loaded_name
    if _model is not None and _loaded_name == model_name:
        return _model
    if _load_failed:
        return None
    with _model_lock:
        if _model is not None and _loaded_name == model_name:
            return _model
        if _load_failed:
            return None
        try:
            from faster_whisper import WhisperModel  # noqa: PLC0415
            _model = WhisperModel(model_name, device="cpu", compute_type="int8")
            _loaded_name = model_name
            log.info("wake-gate CPU whisper loaded: %s (cpu/int8)", model_name)
        except Exception as e:  # noqa: BLE001
            log.warning(
                "wake-gate CPU whisper unavailable (%s); falling back to GPU server", e
            )
            _load_failed = True
            return None
    return _model


def warm_up(model_name: str = "base") -> bool:
    """Pre-load the CPU model so the first real wake doesn't pay the load cost.

    Safe to call from a background thread at listener startup. Returns True if
    the model is loaded, False if it is unavailable (caller need not react —
    transcribe() falls back to the GPU server either way).
    """
    return _get_model(model_name) is not None


def transcribe(
    audio: np.ndarray,
    *,
    language: str | None = "es",
    model_name: str = "base",
    initial_prompt: str = "",
) -> tuple[str, str, float] | None:
    """Transcribe a short wake-gate segment on the CPU.

    Returns ``(text, language, language_probability)``, or ``None`` if the CPU
    model is unavailable (the caller must then fall back to the GPU server).
    Mirrors the anti-hallucination params of ``transcriber.transcribe_wakeword``.
    """
    model = _get_model(model_name)
    if model is None:
        return None
    if audio.dtype != np.float32:
        audio = (
            audio.astype(np.float32) / 32768.0
            if audio.dtype == np.int16
            else audio.astype(np.float32)
        )
    if not audio.flags["C_CONTIGUOUS"]:
        audio = np.ascontiguousarray(audio)
    try:
        segments, info = model.transcribe(
            audio,
            language=language,
            beam_size=1,                       # greedy, no sampling
            initial_prompt=(initial_prompt or None),
            condition_on_previous_text=False,  # kill repetition loops
            no_speech_threshold=0.6,
            compression_ratio_threshold=1.35,
            temperature=0,
            vad_filter=False,
        )
        text = "".join(seg.text for seg in segments)
        return text, info.language, float(info.language_probability)
    except Exception as e:  # noqa: BLE001
        log.warning("wake-gate CPU transcribe failed (%s); falling back", e)
        return None
