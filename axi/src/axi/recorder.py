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
from datetime import datetime
from pathlib import Path
from uuid import uuid4

import numpy as np
import sounddevice as sd
import soundfile as sf

from axi.mic import pick_best

SAMPLE_RATE = 16_000
CHANNELS = 1
DEBUG_DUMP = Path("/tmp/axi-last-recording.wav")

# Persistent recordings directory.
RECORDINGS_DIR = Path(
    os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
) / "axi" / "recordings"

# How many recordings to keep.  Oldest are pruned after each save.
RECORDING_RETENTION = 10

# Only save recordings that are at least this long (samples).  Short dictation
# clips (< 2 min) are not archived by default to avoid filling the disk.
# 16000 Hz × 120 s = 2 minutes (matches LONG_AUDIO_SAMPLES in whisper_server).
RECORDING_MIN_SAMPLES = 16000 * 120
# Keep recording briefly after the stop toggle. Users tap the hotkey *during*
# the final stressed syllable (Spanish "aquí", "café", "acabó"), so the literal
# end of the word arrives after their finger does. 400ms covers human latency
# without making the daemon feel sluggish.
TAIL_BUFFER_S = 0.8


class Recorder:
    def __init__(self, dump_debug_wav: bool = True, save_recordings: bool = True) -> None:
        self._stream: sd.InputStream | None = None
        self._chunks: list[np.ndarray] = []
        self._lock = threading.Lock()
        self.active_source: str | None = None
        self.dump_debug_wav = dump_debug_wav
        self.save_recordings = save_recordings
        # Overrideable in tests to redirect saves to a tmp directory.
        self._recordings_dir: Path = RECORDINGS_DIR

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

        # Persist long recordings to the recordings directory (if enabled).
        if self.save_recordings and audio.size >= RECORDING_MIN_SAMPLES:
            self.save_recording(audio)

        return audio

    def save_recording(self, audio: np.ndarray) -> Path | None:
        """Persist audio as a uniquely-named WAV file in the recordings directory.

        Filename: {iso8601}_{uuid4hex8}.wav  (e.g. 2026-06-04T09-11-03_a1b2c3d4.wav)
        Atomic: writes to .wav.tmp then renames to final path.
        Retention: keeps last RECORDING_RETENTION files; cleanup tolerates OSError.

        Returns the final Path on success, or None if the write failed.
        """
        try:
            recordings_dir = self._recordings_dir
            recordings_dir.mkdir(parents=True, exist_ok=True)

            ts = datetime.now().strftime("%Y-%m-%dT%H-%M-%S")
            uid = uuid4().hex[:8]
            filename = f"{ts}_{uid}.wav"
            final_path = recordings_dir / filename
            tmp_path = recordings_dir / f"{filename}.tmp"

            # Specify format explicitly so soundfile does not guess from the
            # .tmp extension (which would fail since it is not ".wav").
            sf.write(str(tmp_path), audio, SAMPLE_RATE, format="WAV", subtype="FLOAT")
            os.replace(tmp_path, final_path)

            self._apply_retention(recordings_dir)

            return final_path
        except OSError as e:
            print(f"[recorder] save_recording failed: {e}", flush=True)
            return None

    def _apply_retention(self, recordings_dir: Path) -> None:
        """Prune the recordings directory to keep at most RECORDING_RETENTION files.

        Only considers *.wav files (ignores *.tmp in case of a prior crash).
        Crash-safe: tolerates OSError on individual file deletions.
        """
        try:
            wavs = sorted(recordings_dir.glob("*.wav"))
            overage = len(wavs) - RECORDING_RETENTION
            if overage <= 0:
                return
            for old in wavs[:overage]:
                try:
                    old.unlink()
                except OSError:
                    pass
        except OSError:
            pass
