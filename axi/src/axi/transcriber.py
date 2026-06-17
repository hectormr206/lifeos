"""Voice-daemon transcription via the shared `axi-whisper` server.

Previously this loaded its own `WhisperModel` (~1.6 GB VRAM + ~600 MB
CUDA context per process) — duplicated with `axi.translate`. Now both
consumers share a single instance via Unix socket, freeing VRAM for
`llama-server` and the translator's Piper/Opus.

Decoder behaviour is preserved verbatim from the prior in-process loader:
language is config-driven ('language' key; defaults to 'es'), no VAD (recorder bounds at toggle time),
beam_size 5, high `no_speech_threshold` and low `compression_ratio_threshold`
to suppress hallucinations, no carry-over of previous text.
"""
from __future__ import annotations

import logging

import numpy as np

from axi.whisper_client import (
    TranscriptionResult,
    WhisperServiceError,
    transcribe as _whisper_transcribe,
)

log = logging.getLogger("axi.transcriber")

DEFAULT_MODEL_NAME = "large-v3-turbo"
# Back-compat alias — some callers import MODEL_NAME directly.
MODEL_NAME = DEFAULT_MODEL_NAME

DEFAULT_INITIAL_PROMPT = (
    "Transcripción en español de dictado técnico y conversación natural. "
    "El asistente se llama Axi (se escribe con X, no con S; pronunciación 'a-csi'). "
    "Cuando Héctor le habla, suele empezar con 'Axi, ...'. "
    "Incluye términos en inglés como Python, daemon, terminal, clipboard, "
    "Whisper, GPU, systemd, KDE, PipeWire, Piper, Kokoro, XTTS, prompt, "
    "código, framework, PR, branch, commit, debug, log, repo, endpoint, Axi."
)

INITIAL_PROMPT_EN = (
    "English transcription of technical dictation and natural conversation. "
    "The assistant is called Axi — spelled with an X (not 'Axe', not 'Aksi', not 'Axis'). "
    "The user often starts with 'Axi, ...'. "
    "Includes technical English vocabulary: Python, daemon, terminal, clipboard, "
    "Whisper, GPU, systemd, KDE, PipeWire, Piper, prompt, framework, PR, branch, "
    "commit, debug, log, repo, endpoint, llama, LifeOS, Axi."
)

DEFAULT_BEAM_SIZE = 5


class Transcriber:
    """Thin facade over the shared whisper server preserving the legacy
    API used elsewhere in axi-voice (constructor + .transcribe() method).
    No GPU resources are acquired locally — only a socket is opened per
    call."""

    def __init__(
        self,
        model_name: str | None = None,
        initial_prompt: str | None = None,
    ) -> None:
        from axi.config import get  # noqa: PLC0415 — lazy import
        if model_name is None:
            model_name = str(get("whisper_model_name", DEFAULT_MODEL_NAME))

        # Derive STT language from the user's configured language setting.
        # 'en' (or 'en-*') → pin Whisper to English; everything else → Spanish.
        # This replaces the hardcoded "es" that was previously in transcribe().
        _lang_cfg = str(get("language", "es-MX"))
        _lang_family = _lang_cfg.split("-")[0].lower()
        self.stt_language: str = "en" if _lang_family == "en" else "es"

        if initial_prompt is None:
            # Use the EN or ES initial prompt based on language unless the user
            # has overridden whisper_initial_prompt directly in config.
            _cfg_prompt = get("whisper_initial_prompt", None)
            if _cfg_prompt is not None:
                initial_prompt = str(_cfg_prompt)
            elif self.stt_language == "en":
                initial_prompt = INITIAL_PROMPT_EN
            else:
                initial_prompt = DEFAULT_INITIAL_PROMPT

        self.model_name = model_name
        self.initial_prompt = initial_prompt
        self.beam_size = int(get("whisper_beam_size", DEFAULT_BEAM_SIZE))

    def transcribe(self, audio: np.ndarray) -> tuple[str, str, float]:
        try:
            r: TranscriptionResult = _whisper_transcribe(
                audio,
                language=self.stt_language,  # set in __init__ from config; was hardcoded "es"
                beam_size=self.beam_size,
                initial_prompt=self.initial_prompt,
                condition_on_previous_text=False,
                no_speech_threshold=0.8,
                compression_ratio_threshold=1.8,
                vad_filter=False,
            )
        except WhisperServiceError as e:
            log.warning("whisper service unavailable: %s", e)
            return "", "", 0.0
        return r.text, r.language, r.language_probability
