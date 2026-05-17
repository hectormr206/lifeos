"""End-to-end smoke test: record N seconds, transcribe, print.

Run:
    cd ~/LifeOS/lifeos/axi && .venv/bin/python -m axi.test_capture [seconds]
"""
from __future__ import annotations

import sys
import time

from axi import _cuda_preload  # noqa: F401  — must precede faster_whisper

import numpy as np
import sounddevice as sd
from faster_whisper import WhisperModel

SAMPLE_RATE = 16_000
CHANNELS = 1
MODEL_NAME = "large-v3-turbo"


def record(seconds: float) -> np.ndarray:
    print(f"[axi] grabando {seconds:.1f}s desde el mic default…", flush=True)
    audio = sd.rec(
        int(seconds * SAMPLE_RATE),
        samplerate=SAMPLE_RATE,
        channels=CHANNELS,
        dtype="float32",
    )
    sd.wait()
    print("[axi] grabación lista", flush=True)
    return audio.flatten()


def transcribe(audio: np.ndarray) -> str:
    print(f"[axi] cargando modelo {MODEL_NAME} (primera vez descarga ~1.5GB)…", flush=True)
    t0 = time.time()
    model = WhisperModel(MODEL_NAME, device="cuda", compute_type="float16")
    print(f"[axi] modelo listo en {time.time() - t0:.1f}s", flush=True)

    t0 = time.time()
    segments, info = model.transcribe(
        audio,
        beam_size=5,
        vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 300},
    )
    text = " ".join(seg.text.strip() for seg in segments).strip()
    elapsed = time.time() - t0
    print(
        f"[axi] transcrito en {elapsed:.2f}s | idioma detectado: {info.language} "
        f"(p={info.language_probability:.2f})",
        flush=True,
    )
    return text


def main() -> int:
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 5.0
    audio = record(seconds)
    text = transcribe(audio)
    print("\n--- TRANSCRIPCIÓN ---")
    print(text or "(vacío)")
    print("---------------------")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
