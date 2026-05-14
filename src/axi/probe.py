"""Diagnostic probe: compares sd.rec() vs sd.InputStream(callback=).

Both record 3 seconds from the default input device and report peak/rms +
device info. Helps isolate whether the InputStream path differs from rec().

Run while speaking continuously:
    .venv/bin/python -m axi.probe
"""
from __future__ import annotations

import time

import numpy as np
import sounddevice as sd
import soundfile as sf

SR = 16_000


def info() -> None:
    print("=== devices ===")
    print(f"sd.default.device = {sd.default.device}")
    print(f"default input    = {sd.query_devices(kind='input')['name']}")
    print(f"default output   = {sd.query_devices(kind='output')['name']}")
    print()


def test_rec() -> None:
    print("=== sd.rec() (3s) — speak now ===")
    audio = sd.rec(int(3 * SR), samplerate=SR, channels=1, dtype="float32")
    sd.wait()
    audio = audio.flatten()
    peak, rms = float(np.abs(audio).max()), float(np.sqrt(np.mean(audio**2)))
    print(f"samples={audio.size} peak={peak:.4f} rms={rms:.4f}")
    sf.write("/tmp/axi-probe-rec.wav", audio, SR, subtype="FLOAT")
    print("saved /tmp/axi-probe-rec.wav\n")


def test_stream() -> None:
    print("=== sd.InputStream(callback=) (3s) — speak now ===")
    chunks: list[np.ndarray] = []

    def cb(indata, _frames, _t, status):
        if status:
            print(f"  status: {status}")
        chunks.append(indata.copy())

    stream = sd.InputStream(samplerate=SR, channels=1, dtype="float32", callback=cb)
    with stream:
        time.sleep(3.0)
    audio = np.concatenate(chunks).flatten() if chunks else np.zeros(0, dtype=np.float32)
    peak = float(np.abs(audio).max()) if audio.size else 0.0
    rms = float(np.sqrt(np.mean(audio**2))) if audio.size else 0.0
    print(f"samples={audio.size} peak={peak:.4f} rms={rms:.4f}")
    sf.write("/tmp/axi-probe-stream.wav", audio, SR, subtype="FLOAT")
    print("saved /tmp/axi-probe-stream.wav\n")


def main() -> int:
    info()
    test_rec()
    print("--- pausa de 1s ---\n")
    time.sleep(1.0)
    test_stream()
    print("=== verdict ===")
    print("Si rec tiene peak>0 y stream peak=0 → bug del InputStream path.")
    print("Si los dos peak=0 → mic default está mudo o suspendido.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
