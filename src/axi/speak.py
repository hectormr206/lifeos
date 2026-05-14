"""Axi voice output via Piper TTS (es_MX-claude).

Decision history: XTTS-v2 with voice cloning was the ideal in quality
(Hector's own Mexican voice, recorded with HyperX SoloCast) but takes
60+ s on CPU for a 4-sentence response — unusable for interactive use.
Until the VRAM-routing puzzle (Qwen + Whisper + TTS in 12 GB) is solved,
we use Piper as the production engine: ~30x realtime on CPU, sub-second
latency, native Mexican Spanish — at the cost of a slightly robotic timbre.

The model and reference WAV from XTTS-v2 stay installed for the future swap.
A 1.5 s silence prefix is prepended to every clip to mask the Bluetooth
codec wake-up delay (FreeClip earbuds clip the first ~1 s otherwise).
"""
from __future__ import annotations

import logging
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

log = logging.getLogger("axi.speak")

PIPER_BIN = "piper-tts"
PIPER_MODEL = Path.home() / "LifeOS/models/piper-voices/es_MX-claude/es_MX-claude-high.onnx"
# Silence prefix to wake the audio sink before speech starts. Bluetooth codecs
# (FreeClip etc.) take ~1-1.5 s to spin up after idle, but laptop speakers via
# the PipeWire alsa sink also clip the first ~600 ms when the sink was suspended.
# 2.5 s is generous but inaudible to the user and protects every sink type
# we have tested.
WAKE_SILENCE_S = 2.5


def _piper_synthesize(text: str, out_wav: Path) -> bool:
    if not shutil.which(PIPER_BIN):
        log.warning("%s not in PATH", PIPER_BIN)
        return False
    if not PIPER_MODEL.exists():
        log.warning("Piper model not found at %s", PIPER_MODEL)
        return False
    try:
        proc = subprocess.run(
            [PIPER_BIN, "--model", str(PIPER_MODEL), "--output_file", str(out_wav)],
            input=text.encode("utf-8"),
            check=False,
            timeout=60,
            capture_output=True,
        )
        if proc.returncode != 0:
            log.warning("piper rc=%d stderr=%s", proc.returncode, proc.stderr.decode(errors="replace")[:200])
            return False
        return out_wav.exists() and out_wav.stat().st_size > 0
    except (subprocess.TimeoutExpired, OSError) as e:
        log.warning("piper failed: %s", e)
        return False


def _prepend_silence(in_path: Path, out_path: Path, seconds: float) -> Path:
    data, sr = sf.read(str(in_path))
    silence = np.zeros(int(sr * seconds), dtype=data.dtype)
    sf.write(str(out_path), np.concatenate([silence, data]), sr)
    return out_path


def speak(text: str) -> bool:
    """Synthesize and play. Blocking — call from a thread to keep the daemon
    responsive while the BT/laptop speaker streams the audio."""
    if not text.strip():
        return False
    tmp = Path(tempfile.gettempdir())
    raw = tmp / "axi-speak.wav"
    padded = tmp / "axi-speak-padded.wav"
    if not _piper_synthesize(text, raw):
        return False
    _prepend_silence(raw, padded, WAKE_SILENCE_S)
    try:
        subprocess.run(["paplay", str(padded)], check=False, timeout=120)
        return True
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        log.warning("paplay failed: %s", e)
        return False


if __name__ == "__main__":
    import sys
    msg = " ".join(sys.argv[1:]) or "Hola Héctor, esta es una prueba con Piper."
    print("hablando…")
    print("OK" if speak(msg) else "ERROR")
