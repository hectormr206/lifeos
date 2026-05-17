"""Push-to-talk style recorder. Toggle start/stop, returns float32 mono @ 16kHz.

PortAudio under PulseAudio only exposes "default" — we cannot pass a specific
device index. To control which mic Axi uses, we call `pactl set-default-source`
on each recording start. This survives the session and protects against the
classic "paired BT mic stole my default" failure mode.
"""
from __future__ import annotations

import os
import subprocess
import threading
import time
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf

from axi.mic import pick_best

SAMPLE_RATE = 16_000
CHANNELS = 1
DEBUG_DUMP = Path("/tmp/axi-last-recording.wav")
# Keep recording briefly after the stop toggle. Users tap the hotkey *during*
# the final stressed syllable (Spanish "aquí", "café", "acabó"), so the literal
# end of the word arrives after their finger does. 400ms covers human latency
# without making the daemon feel sluggish.
TAIL_BUFFER_S = 0.8


class Recorder:
    def __init__(self, dump_debug_wav: bool = True) -> None:
        self._stream: sd.InputStream | None = None
        self._chunks: list[np.ndarray] = []
        self._lock = threading.Lock()
        self.active_source: str | None = None
        self.dump_debug_wav = dump_debug_wav

    @property
    def is_recording(self) -> bool:
        return self._stream is not None

    def _callback(self, indata, _frames, _time_info, status) -> None:
        if status:
            print(f"[recorder] PortAudio status: {status}", flush=True)
        with self._lock:
            self._chunks.append(indata.copy())

    def start(self) -> str | None:
        if self._stream is not None:
            return self.active_source
        picked = pick_best()
        if picked is not None:
            try:
                subprocess.run(
                    ["pactl", "set-default-source", picked.name],
                    check=True,
                    timeout=2,
                    capture_output=True,
                )
            except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as e:
                print(f"[recorder] could not set default source: {e}", flush=True)
            self.active_source = picked.description or picked.name
        else:
            self.active_source = "default"
        with self._lock:
            self._chunks = []
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="float32",
            callback=self._callback,
        )
        self._stream.start()
        return self.active_source

    def stop(self) -> np.ndarray | None:
        if self._stream is None:
            return None
        # Capture human-latency tail so stressed final syllables are not clipped.
        time.sleep(TAIL_BUFFER_S)
        self._stream.stop()
        self._stream.close()
        self._stream = None
        with self._lock:
            if not self._chunks:
                return None
            audio = np.concatenate(self._chunks).flatten()

        if self.dump_debug_wav:
            try:
                sf.write(str(DEBUG_DUMP), audio, SAMPLE_RATE, subtype="FLOAT")
            except OSError:
                pass

        peak = float(np.abs(audio).max()) if audio.size else 0.0
        rms = float(np.sqrt(np.mean(audio**2))) if audio.size else 0.0
        print(f"[recorder] dump={DEBUG_DUMP} samples={audio.size} peak={peak:.4f} rms={rms:.4f}", flush=True)

        return audio
