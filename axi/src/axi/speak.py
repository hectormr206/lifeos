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
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

log = logging.getLogger("axi.speak")

PIPER_BIN = "piper-tts"
# Legacy module-level constant kept for back-compat with any code that imports it
# directly. The canonical selector is now _piper_model_path().
PIPER_MODEL = Path.home() / "LifeOS/models/piper-voices/es_MX-claude/es_MX-claude-high.onnx"

_PIPER_VOICES: dict[str, Path] = {
    "es": Path.home() / "LifeOS/models/piper-voices/es_MX-claude/es_MX-claude-high.onnx",
    "en": Path.home() / "LifeOS/models/piper-voices/en_US-lessac/en_US-lessac-medium.onnx",
}


def _piper_model_path(lang: str | None = None) -> Path:
    """Return the Piper voice model path for the given language tag.

    'en' (or 'en-*') -> en_US-lessac-medium
    'es', 'es-MX', None, or anything else -> es_MX-claude-high (default)

    When the resolved voice file does not exist, logs a warning and falls
    back to the Spanish voice so a missing EN download does not hard-crash.
    """
    family = (lang or "es").split("-")[0].lower()
    path = _PIPER_VOICES.get(family, _PIPER_VOICES["es"])
    if not path.exists() and family != "es":
        log.warning(
            "Piper voice for lang='%s' not found at %s — falling back to Spanish voice. "
            "Run axi/scripts/axi-install-en-voice to install it.",
            lang, path,
        )
        path = _PIPER_VOICES["es"]
    return path


# Silence prefix to wake the audio sink before speech starts. Bluetooth codecs
# (FreeClip etc.) take ~1-1.5 s to spin up after idle, but laptop speakers via
# the PipeWire alsa sink also clip the first ~600 ms when the sink was suspended.
# 2.5 s is generous but inaudible to the user and protects every sink type
# we have tested.
WAKE_SILENCE_S = 2.5


# ── Markdown → speech sanitizer ──────────────────────────────────────────────
# The brain formats answers in Markdown (e.g. **bold**, `code`, # headings).
# Piper reads those symbols literally ("**" -> "asterisco asterisco"), so every
# string heading into TTS must be stripped of Markdown first. This is TTS-only:
# the on-screen / stored text keeps its original formatting.
_MD_FENCE_RE = re.compile(r"```[^\n]*\n?")          # ``` fenced code delimiters
_MD_LINK_RE = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")  # [text](url) / ![alt](url) -> text
_MD_HEAD_RE = re.compile(r"(?m)^\s{0,3}#{1,6}\s*")    # # / ## headings
_MD_BULLET_RE = re.compile(r"(?m)^\s*[-*+]\s+")        # -, *, + bullets
_MD_EMPH_RE = re.compile(r"\*\*\*|\*\*|\*|___|__|_|~~|`")  # emphasis / inline-code markers
_MULTISPACE_RE = re.compile(r"[ \t]{2,}")


def _clean_for_tts(text: str) -> str:
    """Strip Markdown so the TTS engine does not read symbols aloud.

    Removes code fences, emphasis markers (**, *, _, ~~, `), heading hashes and
    bullet markers, and unwraps links to their visible text. Leaves the words
    intact. Returns the cleaned, whitespace-collapsed string.
    """
    if not text:
        return text
    t = _MD_FENCE_RE.sub("", text)
    t = _MD_LINK_RE.sub(r"\1", t)
    t = _MD_HEAD_RE.sub("", t)
    t = _MD_BULLET_RE.sub("", t)
    t = _MD_EMPH_RE.sub("", t)
    t = _MULTISPACE_RE.sub(" ", t)
    t = re.sub(r"\n{3,}", "\n\n", t)
    return t.strip()


def _piper_synthesize(text: str, out_wav: Path) -> bool:
    from axi import config as _cfg  # noqa: PLC0415 — lazy to avoid import cycle
    # Strip Markdown so Piper never voices symbols like "**" or "`".
    text = _clean_for_tts(text)
    _lang = str(_cfg.get("language", "es-MX"))
    model = _piper_model_path(_lang)
    if not shutil.which(PIPER_BIN):
        log.warning("%s not in PATH", PIPER_BIN)
        return False
    if not model.exists():
        log.warning("Piper model not found at %s", model)
        return False
    try:
        proc = subprocess.run(
            [PIPER_BIN, "--model", str(model), "--output_file", str(out_wav)],
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


_ACK_CUE_PATH = Path(tempfile.gettempdir()) / "axi-ack-cue.wav"


def _ensure_ack_cue() -> Path | None:
    """Generate (once, cached) a short two-tone 'Axi heard you' chime."""
    try:
        if _ACK_CUE_PATH.exists() and _ACK_CUE_PATH.stat().st_size > 0:
            return _ACK_CUE_PATH
        sr = 22050

        def _tone(freq: float, dur: float) -> np.ndarray:
            t = np.linspace(0, dur, int(sr * dur), endpoint=False)
            # quick attack + decay envelope so it doesn't click
            env = np.clip(np.minimum(t / 0.008, (dur - t) / 0.03), 0.0, 1.0)
            return (0.22 * env * np.sin(2 * np.pi * freq * t)).astype(np.float32)

        sig = np.concatenate([_tone(880.0, 0.07), _tone(1320.0, 0.10)])
        sf.write(str(_ACK_CUE_PATH), sig, sr)
        return _ACK_CUE_PATH
    except Exception as e:  # noqa: BLE001
        log.warning("ack cue generation failed: %s", e)
        return None


def play_ack_cue() -> None:
    """Play the short 'I heard you' chime. Non-blocking, best-effort.

    Gives the user immediate audible confirmation that the wake word was caught,
    so they don't repeat "Axi" while the (laggy) transcription path runs.
    """
    p = _ensure_ack_cue()
    if p is None:
        return
    try:
        subprocess.Popen(
            ["paplay", str(p)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (FileNotFoundError, OSError) as e:
        log.warning("ack cue playback failed: %s", e)


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


def synthesize_wav_bytes(text: str, with_silence_prefix: bool = False) -> bytes | None:
    """Synthesize `text` to WAV bytes WITHOUT playing them locally. Used by
    the dashboard chat to return audio that the browser plays — works on
    laptop AND remote (Android via VPN). Returns None on failure.

    The wake-silence prefix is OFF by default here because remote browsers
    don't need it (no BT sink wake-up); local playback (which still uses
    the legacy `speak()` path) keeps it.
    """
    if not text.strip():
        return None
    tmp = Path(tempfile.gettempdir())
    raw = tmp / f"axi-synth-{os.getpid()}.wav"
    try:
        if not _piper_synthesize(text, raw):
            return None
        if with_silence_prefix:
            padded = tmp / f"axi-synth-{os.getpid()}-padded.wav"
            _prepend_silence(raw, padded, WAKE_SILENCE_S)
            data = padded.read_bytes()
            try: padded.unlink()
            except OSError: pass
        else:
            data = raw.read_bytes()
        return data
    finally:
        try: raw.unlink()
        except OSError: pass


import os  # noqa: E402 — used in synthesize_wav_bytes


if __name__ == "__main__":
    import sys
    msg = " ".join(sys.argv[1:]) or "Hola Héctor, esta es una prueba con Piper."
    print("hablando…")
    print("OK" if speak(msg) else "ERROR")
