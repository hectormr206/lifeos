"""faster-whisper wrapper. Loaded once at daemon startup, kept warm on GPU.

Decoder is tuned for Spanish-first dictation with English technical loans,
the way Hector talks. Five anti-hallucination knobs vs faster-whisper defaults:

1. `language="es"` — Whisper auto-detection is unreliable on short, noisy
   chunks (a 60s meeting fragment from a Bluetooth monitor sink). Without
   pinning the language the model occasionally decides the audio is
   Icelandic, Portuguese, or random — emitting things like
   `Ég sé. Ég sé. B nöss公d` in the meeting transcript. Pin Spanish.
2. `initial_prompt` — biases the decoder toward Spanish + tech vocabulary
   so the first silent moments don't trigger "Following the February release
   of the Queen 3.5 series" type warmup garbage.
3. `condition_on_previous_text=False` — prevents an early hallucination
   from poisoning every subsequent segment.
4. `no_speech_threshold=0.8` (up from 0.6) — more aggressive silence
   rejection at segment level.
5. `compression_ratio_threshold=1.8` (down from 2.4) — rejects segments
   whose text is highly compressible, a fingerprint of repetition
   hallucinations.
"""
from __future__ import annotations

from axi import _cuda_preload  # noqa: F401  — must precede faster_whisper

import numpy as np
from faster_whisper import WhisperModel

MODEL_NAME = "large-v3-turbo"

DEFAULT_INITIAL_PROMPT = (
    "Transcripción en español de dictado técnico y conversación natural. "
    "Incluye términos en inglés como Python, daemon, terminal, clipboard, "
    "Whisper, GPU, systemd, KDE, PipeWire, Piper, Kokoro, XTTS, prompt, "
    "código, framework, PR, branch, commit, debug, log, repo, endpoint."
)


class Transcriber:
    def __init__(
        self,
        model_name: str = MODEL_NAME,
        initial_prompt: str = DEFAULT_INITIAL_PROMPT,
    ) -> None:
        # Device + compute_type are env-configurable so Game Guard can swap
        # us to CPU (frees VRAM for games) without killing axi-voice. On
        # CPU, float16 isn't supported by ctranslate2 — use int8 instead.
        import os  # noqa: PLC0415
        device = os.environ.get("AXI_WHISPER_DEVICE", "cuda")
        compute = os.environ.get(
            "AXI_WHISPER_COMPUTE_TYPE",
            "int8" if device == "cpu" else "float16",
        )
        self.model = WhisperModel(model_name, device=device, compute_type=compute)
        self.initial_prompt = initial_prompt

    def transcribe(self, audio: np.ndarray) -> tuple[str, str, float]:
        segments, info = self.model.transcribe(
            audio,
            language="es",  # see module docstring — auto-detect fails on short noisy chunks
            beam_size=5,
            initial_prompt=self.initial_prompt,
            condition_on_previous_text=False,
            no_speech_threshold=0.8,
            compression_ratio_threshold=1.8,
            # vad_filter disabled: the recorder already bounds the audio at
            # human-toggle time, and internal VAD was trimming Spanish stressed
            # final vowels ("aquí" → "aqu") even with permissive thresholds.
            vad_filter=False,
        )
        text = " ".join(s.text.strip() for s in segments).strip()
        return text, info.language, float(info.language_probability)
