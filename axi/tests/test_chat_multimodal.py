"""Tests for the multimodal extensions of P-chat (images + audio).

Covers:
- POST /api/chat/capture-screen + /api/chat/capture-camera (mocked sources).
- POST /api/chat/ask with `image_b64` forwarding to brain.ask.
- POST /api/chat/ask with `speak: true` firing axi.speak.speak in background,
  honoring the `chat_tts_enabled` kill switch.
- POST /api/chat/transcribe round-trip through a mocked daemon socket.
- Daemon `transcribe_path:<path>` command transcribing a tiny fixture WAV.

We never touch the real microphone, the real webcam, the real screen, the
real llama-server, or the real Whisper model — everything is mocked or
injected via the daemon's DI seam.
"""
from __future__ import annotations

import base64
import struct
import threading
import time
import wave
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    return TestClient(dashboard.app)


# ───────────────────────── capture endpoints ─────────────────────────

def test_capture_screen_ok(client, monkeypatch):
    from axi import vision
    monkeypatch.setattr(vision, "capture_active_window_b64", lambda: "AAAA")
    r = client.post("/api/chat/capture-screen")
    assert r.status_code == 200
    body = r.json()
    assert body["image_b64"] == "AAAA"
    assert body["status"] == "ok"


def test_capture_screen_failure_returns_503(client, monkeypatch):
    from axi import vision
    monkeypatch.setattr(vision, "capture_active_window_b64", lambda: None)
    r = client.post("/api/chat/capture-screen")
    assert r.status_code == 503


def test_capture_camera_ok(client, monkeypatch):
    from axi import eyes
    monkeypatch.setattr(eyes, "capture_b64", lambda: ("BBBB", "ok"))
    r = client.post("/api/chat/capture-camera")
    assert r.status_code == 200
    body = r.json()
    assert body["image_b64"] == "BBBB"
    assert body["status"] == "ok"


def test_capture_camera_busy_returns_503(client, monkeypatch):
    from axi import eyes
    monkeypatch.setattr(eyes, "capture_b64", lambda: (None, "busy:zoom"))
    r = client.post("/api/chat/capture-camera")
    assert r.status_code == 503
    assert "busy" in r.json()["detail"]


# ───────────────────────── /api/chat/ask multimodal ─────────────────────────

def test_chat_ask_with_image_forwards_to_brain(client, monkeypatch):
    """An `image_b64` payload should hit brain.ask with image_b64= set."""
    from axi import brain
    captured: dict = {}

    def fake_ask(prompt, **kw):
        captured["prompt"] = prompt
        captured["image_b64"] = kw.get("image_b64")
        return "veo una taza"

    monkeypatch.setattr(brain, "ask", fake_ask)

    r = client.post("/api/chat/ask", json={"text": "qué ves", "image_b64": "XYZ"})
    assert r.status_code == 200
    assert r.json()["answer"] == "veo una taza"
    assert captured["image_b64"] == "XYZ"
    assert captured["prompt"] == "qué ves"


def test_chat_ask_image_only_uses_default_prompt(client, monkeypatch):
    """Empty text + image → fallback prompt ('Describe lo que ves…')."""
    from axi import brain
    captured: dict = {}

    def fake_ask(prompt, **kw):
        captured["prompt"] = prompt
        captured["image_b64"] = kw.get("image_b64")
        return "ok"

    monkeypatch.setattr(brain, "ask", fake_ask)

    r = client.post("/api/chat/ask", json={"text": "", "image_b64": "ZZZ"})
    assert r.status_code == 200
    assert captured["image_b64"] == "ZZZ"
    assert "Describe" in captured["prompt"]


def test_chat_ask_persists_image_marker(client, monkeypatch):
    """When an image is attached, the persisted user turn should be tagged
    with the '[imagen adjunta]' prefix so history rendering can flag it."""
    from axi import brain
    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: "ok")
    r = client.post("/api/chat/ask", json={"text": "mirá", "image_b64": "QQ"})
    assert r.status_code == 200
    rows = client.get("/api/chat/history?limit=10").json()
    assert rows
    assert rows[-1]["user_text"].startswith("[imagen adjunta]")
    assert "mirá" in rows[-1]["user_text"]


def test_chat_ask_speak_synthesizes_wav_in_response(client, monkeypatch):
    """speak=True → synthesize_wav_bytes(answer) runs synchronously and the
    response carries audio_b64 + spoke=True.

    Was previously named *_fires_speak_in_background and patched
    speak_mod.speak — that legacy path was replaced by a synchronous
    synth+ship pipeline (dashboard.py:2624-2645) so the browser plays
    the audio over VPN/mobile, not the laptop speakers.
    """
    from axi import brain, speak as speak_mod
    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: "hola Héctor")
    monkeypatch.setattr(brain, "ask_with_tools", lambda prompt, **kw: "hola Héctor")
    synthesized: list[str] = []

    def fake_synth(text: str) -> bytes:
        synthesized.append(text)
        return b"RIFF\x00\x00\x00\x00WAVEfmt fake-pcm-bytes"

    monkeypatch.setattr(speak_mod, "synthesize_wav_bytes", fake_synth)

    r = client.post("/api/chat/ask", json={"text": "saludá", "speak": True})
    assert r.status_code == 200
    payload = r.json()
    assert payload["spoke"] is True
    assert payload["audio_b64"], "expected base64-encoded WAV in response"
    assert synthesized == ["hola Héctor"]


def test_chat_ask_speak_killswitch_blocks_tts(client, monkeypatch):
    """chat_tts_enabled=false → speak NOT called even if request asks for it."""
    from axi import brain, config, speak as speak_mod
    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: "no debería sonar")

    def fake_get(key, default=None):
        if key == "chat_tts_enabled":
            return False
        if key == "chat_enabled":
            return True
        return default

    monkeypatch.setattr(config, "get", fake_get)

    spoken: list[str] = []
    monkeypatch.setattr(speak_mod, "speak", lambda text: spoken.append(text) or True)

    r = client.post("/api/chat/ask", json={"text": "x", "speak": True})
    assert r.status_code == 200
    assert r.json()["spoke"] is False
    # Give any rogue thread a moment to misbehave.
    time.sleep(0.2)
    assert spoken == []


def test_chat_ask_speak_false_does_not_speak(client, monkeypatch):
    from axi import brain, speak as speak_mod
    monkeypatch.setattr(brain, "ask", lambda prompt, **kw: "silencio")
    # Conversation mode routes through ask_with_tools — mock it so no live model call.
    monkeypatch.setattr(brain, "ask_with_tools", lambda *a, **kw: "silencio")
    called: list[str] = []
    monkeypatch.setattr(speak_mod, "speak", lambda text: called.append(text) or True)
    r = client.post("/api/chat/ask", json={"text": "x"})
    assert r.status_code == 200
    assert r.json()["spoke"] is False
    time.sleep(0.1)
    assert called == []


# ───────────────────────── /api/chat/transcribe ─────────────────────────

def test_transcribe_round_trip_via_mocked_daemon(client, monkeypatch):
    """The dashboard endpoint should send `transcribe_path:<file>` to the
    daemon socket and return whatever text comes back."""
    from axi import dashboard

    sent: dict = {}

    def fake_cmd(cmd, timeout=2.0):
        sent["cmd"] = cmd
        sent["timeout"] = timeout
        return "text:hola mundo"

    monkeypatch.setattr(dashboard, "_daemon_cmd", fake_cmd)

    audio_b64 = base64.b64encode(b"fake-webm-bytes").decode("ascii")
    r = client.post("/api/chat/transcribe", json={"audio_b64": audio_b64})
    assert r.status_code == 200
    assert r.json()["text"] == "hola mundo"
    assert sent["cmd"].startswith("transcribe_path:")
    assert sent["timeout"] >= 5.0  # should not use the 2s default


def test_transcribe_daemon_error_returns_503(client, monkeypatch):
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_daemon_cmd", lambda cmd, timeout=2.0: "error:ffmpeg not installed")
    audio_b64 = base64.b64encode(b"x").decode("ascii")
    r = client.post("/api/chat/transcribe", json={"audio_b64": audio_b64})
    assert r.status_code == 503
    assert "ffmpeg" in r.json()["detail"]


def test_transcribe_rejects_empty(client):
    r = client.post("/api/chat/transcribe", json={"audio_b64": ""})
    assert r.status_code == 400


def test_transcribe_rejects_invalid_b64(client):
    r = client.post("/api/chat/transcribe", json={"audio_b64": "@@@not_base64@@@"})
    # Either malformed b64 (400) or decodes to empty bytes (400). Accept both.
    assert r.status_code in (400,)


# ───────────────────── daemon transcribe_path: handler ──────────────────────

def _make_wav(path: Path, seconds: float = 0.4, sr: int = 16000) -> None:
    """Write a small, valid mono 16-bit WAV with a soft tone for fixture use.

    Uses a low-amplitude 440 Hz sine (not pure silence): the daemon's
    transcribe_path energy gate drops near-silent audio (RMS < 0.002) before it
    ever reaches Whisper, so a silent fixture would never exercise the
    transcriber. The tone's RMS (~0.04 normalized) clears that floor.
    """
    import math
    n = int(seconds * sr)
    amp = 2000  # int16; normalized RMS ≈ 2000/32768/√2 ≈ 0.043 > 0.002 floor
    samples = [int(amp * math.sin(2 * math.pi * 440 * i / sr)) for i in range(n)]
    data = struct.pack(f"<{n}h", *samples)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(data)


def test_daemon_transcribe_path_calls_transcriber(tmp_path, monkeypatch):
    """The daemon command should decode + hand the waveform to Whisper.

    We override the chat-audio root to tmp_path so the path-safety check
    passes, then verify the injected FakeTranscriber gets called and the
    returned text reaches us through the `text:` prefix.
    """
    from tests.test_daemon import (
        FakeRecorder, FakeTranscriber, FakeBrainAsk, FakeMeetingSession,
    )
    from axi.daemon import Daemon, _handle_cmd
    from axi.memory import ConversationMemory

    # The conftest autouse fixture stubs `shutil.which → None` on the module
    # singleton to block real notify-send calls. That collateral kills our
    # ffmpeg lookup too — restore a working resolver here so transcribe_path
    # can find /usr/bin/ffmpeg.
    import shutil as _real_shutil
    monkeypatch.setattr(
        _real_shutil, "which",
        lambda name: f"/usr/bin/{name}" if Path(f"/usr/bin/{name}").exists() else None,
    )

    # Route the daemon's "allowed dir" check at tmp_path/axi/chat-audio.
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    audio_dir = tmp_path / "axi" / "chat-audio"
    audio_dir.mkdir(parents=True)

    fixture = audio_dir / "clip.wav"
    _make_wav(fixture)

    tx = FakeTranscriber(text="hola axi")
    d = Daemon(
        recorder=FakeRecorder(),
        transcriber=tx,
        memory=ConversationMemory(),
        brain_ask=FakeBrainAsk(),
        vision_capture=lambda: None,
        eyes_capture=lambda: (None, "ok"),
        meeting_factory=lambda **kw: FakeMeetingSession(**kw),
    )

    resp, _ = _handle_cmd(d, f"transcribe_path:{fixture}")
    assert resp.startswith("text:"), f"unexpected response: {resp!r}"
    # FakeTranscriber returns the canned text verbatim. clean_text may strip
    # whitespace but the core phrase survives.
    assert "hola axi" in resp.lower()
    assert tx.calls == 1


def test_daemon_transcribe_path_rejects_outside_dir(tmp_path, monkeypatch):
    """A path outside the chat-audio dir must be refused, even if readable.
    This protects the daemon from being tricked into decoding arbitrary files."""
    from tests.test_daemon import (
        FakeRecorder, FakeTranscriber, FakeBrainAsk, FakeMeetingSession,
    )
    from axi.daemon import Daemon, _handle_cmd
    from axi.memory import ConversationMemory

    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    (tmp_path / "axi" / "chat-audio").mkdir(parents=True)

    # File OUTSIDE chat-audio:
    bad = tmp_path / "elsewhere.wav"
    _make_wav(bad)

    d = Daemon(
        recorder=FakeRecorder(),
        transcriber=FakeTranscriber(),
        memory=ConversationMemory(),
        brain_ask=FakeBrainAsk(),
        vision_capture=lambda: None,
        eyes_capture=lambda: (None, "ok"),
        meeting_factory=lambda **kw: FakeMeetingSession(**kw),
    )
    resp, _ = _handle_cmd(d, f"transcribe_path:{bad}")
    assert resp.startswith("error:")
    assert "outside" in resp


def test_daemon_transcribe_path_missing_file(tmp_path, monkeypatch):
    from tests.test_daemon import (
        FakeRecorder, FakeTranscriber, FakeBrainAsk, FakeMeetingSession,
    )
    from axi.daemon import Daemon, _handle_cmd
    from axi.memory import ConversationMemory

    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    (tmp_path / "axi" / "chat-audio").mkdir(parents=True)

    d = Daemon(
        recorder=FakeRecorder(),
        transcriber=FakeTranscriber(),
        memory=ConversationMemory(),
        brain_ask=FakeBrainAsk(),
        vision_capture=lambda: None,
        eyes_capture=lambda: (None, "ok"),
        meeting_factory=lambda **kw: FakeMeetingSession(**kw),
    )
    ghost = tmp_path / "axi" / "chat-audio" / "missing.wav"
    resp, _ = _handle_cmd(d, f"transcribe_path:{ghost}")
    assert resp.startswith("error:")
    assert "not found" in resp
