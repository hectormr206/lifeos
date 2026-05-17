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

DEFAULT_BEAM_SIZE = 5


class Transcriber:
    def __init__(
        self,
        model_name: str | None = None,
        initial_prompt: str | None = None,
    ) -> None:
        # Resolve config-overridable values at construction time. Whisper
        # is loaded once at daemon startup; changes take effect on restart
        # (the dashboard surfaces a "Reinicio pendiente" affordance).
        from axi.config import get  # noqa: PLC0415 — lazy import
        if model_name is None:
            model_name = str(get("whisper_model_name", DEFAULT_MODEL_NAME))
        if initial_prompt is None:
            initial_prompt = str(get("whisper_initial_prompt", DEFAULT_INITIAL_PROMPT))
        self.beam_size = int(get("whisper_beam_size", DEFAULT_BEAM_SIZE))
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
            beam_size=self.beam_size,
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
