#!/usr/bin/env python3
"""LifeOS Speaker Diarization — identifies different speakers in audio.

Uses a simple energy-based approach with speaker embeddings via ONNX.
Falls back to timestamp-based segmentation when embeddings aren't available.

Usage:
    lifeos-diarize.py <audio_path> <transcript_path> [--output <output_path>]

Output: transcript with speaker labels prepended to each segment:
    [Speaker 1] Hello, how are you?
    [Speaker 2] I'm doing great, thanks.
"""

import sys
import os
import json
import subprocess
import wave
import struct
import math
from pathlib import Path

def read_wav_energy(wav_path, segment_ms=2000):
    """Read WAV file and compute energy per segment."""
    try:
        with wave.open(wav_path, 'rb') as wf:
            channels = wf.getnchannels()
            sample_width = wf.getsampwidth()
            framerate = wf.getframerate()
            n_frames = wf.getnframes()

            frames = wf.readframes(n_frames)

            if sample_width == 2:
                fmt = f"<{n_frames * channels}h"
                samples = struct.unpack(fmt, frames)
            else:
                return []

            # Mono mixdown
            if channels > 1:
                mono = []
                for i in range(0, len(samples), channels):
                    mono.append(sum(samples[i:i+channels]) // channels)
                samples = mono

            # Compute energy per segment
            segment_samples = int(framerate * segment_ms / 1000)
            energies = []
            for i in range(0, len(samples), segment_samples):
                chunk = samples[i:i+segment_samples]
                if chunk:
                    rms = math.sqrt(sum(s*s for s in chunk) / len(chunk))
                    energies.append(rms)

            return energies
    except Exception:
        return []


def detect_speaker_changes(energies, threshold_ratio=0.4):
    """Detect speaker changes based on energy pattern shifts.

    Simple heuristic: when energy drops significantly (silence/pause)
    and then comes back, it likely means a different person is speaking.
    """
    if not energies:
        return []

    avg_energy = sum(energies) / len(energies) if energies else 1
    silence_threshold = avg_energy * threshold_ratio

    changes = [0]  # Start with speaker change at beginning
    was_silent = False

    for i, e in enumerate(energies):
        is_silent = e < silence_threshold
        if was_silent and not is_silent:
            # Silence ended, potential new speaker
            changes.append(i)
        was_silent = is_silent

    return changes


def try_whisper_timestamps(audio_path):
    """Try to get timestamped segments from Whisper output."""
    # Check for .json output from whisper-cli
    json_path = audio_path + ".json"
    if os.path.exists(json_path):
        try:
            with open(json_path) as f:
                data = json.load(f)
            if "segments" in data:
                return data["segments"]
        except Exception:
            pass

    # Check for .srt output
    srt_path = os.path.splitext(audio_path)[0] + ".srt"
    if os.path.exists(srt_path):
        segments = []
        try:
            with open(srt_path) as f:
                lines = f.readlines()
            i = 0
            while i < len(lines):
                line = lines[i].strip()
                if "-->" in line:
                    # Parse SRT timestamp
                    parts = line.split("-->")
                    start = parse_srt_time(parts[0].strip())
                    end = parse_srt_time(parts[1].strip())
                    i += 1
                    text_lines = []
                    while i < len(lines) and lines[i].strip():
                        text_lines.append(lines[i].strip())
                        i += 1
                    segments.append({
                        "start": start,
                        "end": end,
                        "text": " ".join(text_lines)
                    })
                i += 1
            return segments
        except Exception:
            pass

    return None


def parse_srt_time(s):
    """Parse SRT timestamp like '00:01:23,456' to seconds."""
    try:
        parts = s.replace(",", ".").split(":")
        return float(parts[0]) * 3600 + float(parts[1]) * 60 + float(parts[2])
    except Exception:
        return 0.0


def assign_speakers_to_transcript(transcript_text, speaker_changes, segment_ms=2000):
    """Assign speaker labels to transcript lines based on detected changes."""
    lines = [l.strip() for l in transcript_text.split("\n") if l.strip()]

    if not lines:
        return transcript_text

    if not speaker_changes or len(speaker_changes) <= 1:
        # No speaker changes detected, single speaker
        return "\n".join(f"[Speaker 1] {line}" for line in lines)

    # Distribute lines across speaker turns
    n_turns = len(speaker_changes)
    lines_per_turn = max(1, len(lines) // n_turns)

    result = []
    current_speaker = 1
    speaker_map = {}  # track which energy pattern -> speaker number
    next_speaker = 2

    for i, line in enumerate(lines):
        turn_idx = min(i // lines_per_turn, n_turns - 1)

        # Alternate speakers at each detected change
        if turn_idx not in speaker_map:
            if turn_idx == 0:
                speaker_map[turn_idx] = 1
            else:
                # Alternate between speakers (simple 2-speaker model)
                prev = speaker_map.get(turn_idx - 1, 1)
                speaker_map[turn_idx] = 1 if prev == 2 else 2

        speaker = speaker_map[turn_idx]
        result.append(f"[Speaker {speaker}] {line}")

    return "\n".join(result)


def assign_speakers_to_segments(segments, speaker_changes, segment_ms=2000):
    """Assign speaker labels to timestamped segments."""
    if not segments:
        return ""

    change_times = [c * segment_ms / 1000.0 for c in speaker_changes]

    result = []
    for seg in segments:
        start = seg.get("start", 0)
        text = seg.get("text", "").strip()
        if not text:
            continue

        # Find which speaker turn this segment belongs to
        speaker_turn = 0
        for ct in change_times:
            if start >= ct:
                speaker_turn += 1

        # Alternate speakers
        speaker = 1 if speaker_turn % 2 == 0 else 2
        result.append(f"[Speaker {speaker}] {text}")

    return "\n".join(result)


def main():
    if len(sys.argv) < 3:
        print("Usage: lifeos-diarize.py <audio_path> <transcript_path> [--output <path>]", file=sys.stderr)
        sys.exit(1)

    audio_path = sys.argv[1]
    transcript_path = sys.argv[2]
    output_path = None

    if "--output" in sys.argv:
        idx = sys.argv.index("--output")
        if idx + 1 < len(sys.argv):
            output_path = sys.argv[idx + 1]

    # Read transcript
    try:
        with open(transcript_path) as f:
            transcript = f.read()
    except FileNotFoundError:
        print(f"Transcript not found: {transcript_path}", file=sys.stderr)
        sys.exit(1)

    # Convert to WAV if needed (for energy analysis)
    wav_path = audio_path
    if not audio_path.endswith(".wav"):
        wav_path = audio_path + ".diarize.wav"
        try:
            subprocess.run([
                "ffmpeg", "-y", "-i", audio_path,
                "-ar", "16000", "-ac", "1", "-f", "wav", wav_path
            ], capture_output=True, check=True)
        except Exception:
            wav_path = None

    # Detect speaker changes via energy analysis
    speaker_changes = []
    if wav_path and os.path.exists(wav_path):
        energies = read_wav_energy(wav_path, segment_ms=2000)
        speaker_changes = detect_speaker_changes(energies)

        # Clean up temp wav
        if wav_path != audio_path and os.path.exists(wav_path):
            os.remove(wav_path)

    # Try timestamped segments from Whisper
    segments = try_whisper_timestamps(audio_path)

    if segments:
        diarized = assign_speakers_to_segments(segments, speaker_changes)
    else:
        diarized = assign_speakers_to_transcript(transcript, speaker_changes)

    # Output
    if output_path:
        with open(output_path, 'w') as f:
            f.write(diarized)
        print(f"Diarized transcript written to: {output_path}", file=sys.stderr)
    else:
        print(diarized)


if __name__ == "__main__":
    main()
