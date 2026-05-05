#!/usr/bin/env python3
"""Extract speaker embedding from a WAV file using WeSpeaker ONNX model.

Usage: lifeos-speaker-embedding.py <wav_path> [--model <onnx_path>]

Outputs a JSON array of 256 floats (the speaker embedding vector) to stdout.
Designed to be called from lifeosd as a subprocess for speaker identification.

Requirements: onnxruntime, numpy (both installed in the image).
"""

import sys
import json
import struct
import math
import os

MODEL_PATH = os.environ.get(
    "LIFEOS_WESPEAKER_MODEL",
    "/usr/share/lifeos/models/wespeaker/voxceleb_resnet34_LM.onnx",
)

SAMPLE_RATE = 16000
FRAME_LENGTH_MS = 25
FRAME_SHIFT_MS = 10
NUM_MEL_BINS = 80
N_FFT = 512  # For 16kHz with 25ms frames


def read_wav_pcm16(path):
    """Read a 16-bit PCM WAV file and return float samples normalized to [-1, 1]."""
    with open(path, "rb") as f:
        header = f.read(44)
        if len(header) < 44 or header[:4] != b"RIFF":
            raise ValueError("Not a valid WAV file")
        data = f.read()

    samples = struct.unpack(f"<{len(data)//2}h", data)
    return [s / 32768.0 for s in samples]


def mel_filterbank(n_fft, n_mels, sr):
    """Create a mel filterbank matrix (n_mels x (n_fft//2 + 1))."""
    def hz_to_mel(hz):
        return 2595.0 * math.log10(1.0 + hz / 700.0)

    def mel_to_hz(mel):
        return 700.0 * (10.0 ** (mel / 2595.0) - 1.0)

    fmax = sr / 2.0
    mel_min = hz_to_mel(0)
    mel_max = hz_to_mel(fmax)
    mel_points = [mel_min + i * (mel_max - mel_min) / (n_mels + 1) for i in range(n_mels + 2)]
    hz_points = [mel_to_hz(m) for m in mel_points]
    bin_points = [int((n_fft + 1) * h / sr) for h in hz_points]

    filters = []
    for i in range(n_mels):
        row = [0.0] * (n_fft // 2 + 1)
        for j in range(bin_points[i], bin_points[i + 1]):
            if j < len(row):
                row[j] = (j - bin_points[i]) / max(bin_points[i + 1] - bin_points[i], 1)
        for j in range(bin_points[i + 1], bin_points[i + 2]):
            if j < len(row):
                row[j] = (bin_points[i + 2] - j) / max(bin_points[i + 2] - bin_points[i + 1], 1)
        filters.append(row)
    return filters


def compute_fbank(samples, sr=SAMPLE_RATE, n_mels=NUM_MEL_BINS, n_fft=N_FFT):
    """Compute log mel filterbank features from audio samples."""
    import numpy as np

    frame_len = int(sr * FRAME_LENGTH_MS / 1000)
    frame_shift = int(sr * FRAME_SHIFT_MS / 1000)

    # Pre-emphasis
    emphasized = [samples[0]] + [samples[i] - 0.97 * samples[i - 1] for i in range(1, len(samples))]
    signal = np.array(emphasized, dtype=np.float32)

    # Framing
    num_frames = max(1, 1 + (len(signal) - frame_len) // frame_shift)
    frames = np.zeros((num_frames, frame_len), dtype=np.float32)
    for i in range(num_frames):
        start = i * frame_shift
        end = min(start + frame_len, len(signal))
        frames[i, :end - start] = signal[start:end]

    # Hamming window
    window = np.hamming(frame_len).astype(np.float32)
    frames *= window

    # FFT
    fft_out = np.fft.rfft(frames, n=n_fft)
    power_spectrum = np.abs(fft_out) ** 2 / n_fft

    # Mel filterbank
    fb = np.array(mel_filterbank(n_fft, n_mels, sr), dtype=np.float32)
    mel_energy = np.dot(power_spectrum, fb.T)
    mel_energy = np.maximum(mel_energy, 1e-10)
    log_mel = np.log(mel_energy)

    # CMVN (cepstral mean and variance normalization)
    log_mel = (log_mel - log_mel.mean(axis=0)) / (log_mel.std(axis=0) + 1e-10)

    return log_mel


def extract_embedding(wav_path, model_path=MODEL_PATH):
    """Extract speaker embedding using WeSpeaker ONNX model."""
    import numpy as np
    import onnxruntime as ort

    if not os.path.exists(model_path):
        print(f"Error: model not found at {model_path}", file=sys.stderr)
        sys.exit(1)

    samples = read_wav_pcm16(wav_path)
    if len(samples) < SAMPLE_RATE:  # Less than 1 second
        # Pad with zeros
        samples = samples + [0.0] * (SAMPLE_RATE - len(samples))

    fbank = compute_fbank(samples)

    # Model expects: [batch, frames, mel_bins]
    input_data = np.expand_dims(fbank, axis=0).astype(np.float32)

    session = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    outputs = session.run(None, {input_name: input_data})

    embedding = outputs[0].flatten().tolist()

    # L2 normalize
    norm = math.sqrt(sum(x * x for x in embedding))
    if norm > 1e-8:
        embedding = [x / norm for x in embedding]

    return embedding


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Extract speaker embedding from WAV")
    parser.add_argument("wav_path", help="Path to 16kHz mono WAV file")
    parser.add_argument("--model", default=MODEL_PATH, help="Path to ONNX model")
    args = parser.parse_args()

    if not os.path.exists(args.wav_path):
        print(f"Error: file not found: {args.wav_path}", file=sys.stderr)
        sys.exit(1)

    embedding = extract_embedding(args.wav_path, args.model)
    json.dump(embedding, sys.stdout)
    print()  # newline


if __name__ == "__main__":
    main()
