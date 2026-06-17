"""Tests for the gaming co-pilot prompt/brevity selection logic (Slice 1).

TDD RED → GREEN cycle:
- Unit-test the _select_ask_params() seam in isolation.
- Mock the lock-file state so tests never touch the real filesystem.
- Verify game-mode active → game-aware system prompt + max_tokens cap.
- Verify game-mode inactive → normal SYSTEM_PROMPT, unchanged max_tokens.
- Verify game_copilot_enabled=False disables the co-pilot path even in game-mode.
- Verify the heartbeat.game_mode_active() predicate reads the correct lock path.
"""
from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest

# ---------------------------------------------------------------------------
# Imports under test (will fail until implementation exists — RED phase)
# ---------------------------------------------------------------------------
from axi.daemon import _select_ask_params
from axi.brain import SYSTEM_PROMPT


# ---------------------------------------------------------------------------
# _select_ask_params — pure prompt/brevity selection helper
# ---------------------------------------------------------------------------

class TestSelectAskParams:
    """Unit tests for _select_ask_params(game_active, copilot_enabled)."""

    def test_game_inactive_returns_default_system_prompt(self):
        """When game-mode is off, the normal SYSTEM_PROMPT is returned unchanged."""
        system, max_tokens = _select_ask_params(game_active=False, copilot_enabled=True)
        assert system == SYSTEM_PROMPT

    def test_game_inactive_returns_default_max_tokens(self):
        """When game-mode is off, max_tokens uses the standard 2048 default."""
        system, max_tokens = _select_ask_params(game_active=False, copilot_enabled=True)
        assert max_tokens == 2048

    def test_game_active_returns_game_aware_system_prompt(self):
        """When game-mode is on and co-pilot is enabled, a game-aware prompt is returned."""
        system, max_tokens = _select_ask_params(game_active=True, copilot_enabled=True)
        assert system != SYSTEM_PROMPT
        # The game prompt must contain meaningful game-copilot content
        assert len(system) > 20

    def test_game_active_returns_brevity_cap(self):
        """When game-mode is on and co-pilot is enabled, max_tokens is capped at 256."""
        system, max_tokens = _select_ask_params(game_active=True, copilot_enabled=True)
        assert max_tokens == 256

    def test_game_active_but_copilot_disabled_returns_default_prompt(self):
        """When co-pilot is disabled via config, game-mode does NOT change the prompt."""
        system, max_tokens = _select_ask_params(game_active=True, copilot_enabled=False)
        assert system == SYSTEM_PROMPT

    def test_game_active_but_copilot_disabled_returns_default_max_tokens(self):
        """When co-pilot is disabled via config, max_tokens stays at default."""
        system, max_tokens = _select_ask_params(game_active=True, copilot_enabled=False)
        assert max_tokens == 2048

    def test_return_type_is_tuple_str_int(self):
        """Return value must always be (str, int)."""
        for game_active in (True, False):
            for copilot_enabled in (True, False):
                result = _select_ask_params(game_active=game_active, copilot_enabled=copilot_enabled)
                assert isinstance(result, tuple) and len(result) == 2
                assert isinstance(result[0], str)
                assert isinstance(result[1], int)


# ---------------------------------------------------------------------------
# game_mode_active() predicate — verifies the correct lock file is used
# ---------------------------------------------------------------------------

class TestGameModeActive:
    """Unit tests for heartbeat.game_mode_active() predicate."""

    def test_returns_false_when_lock_absent(self, tmp_path):
        """game_mode_active() returns False when the lock file does not exist."""
        from axi import heartbeat
        with patch.object(heartbeat, "_game_lock_path", return_value=tmp_path / "game-mode.lock"):
            assert heartbeat.game_mode_active() is False

    def test_returns_true_when_lock_exists(self, tmp_path):
        """game_mode_active() returns True when the lock file exists."""
        from axi import heartbeat
        lock = tmp_path / "game-mode.lock"
        lock.write_text("relocate")
        with patch.object(heartbeat, "_game_lock_path", return_value=lock):
            assert heartbeat.game_mode_active() is True


# ---------------------------------------------------------------------------
# Integration: daemon._stop_and_ask() selects game-aware params when game-mode
# is active and game_copilot_enabled=True.
# ---------------------------------------------------------------------------

class TestDaemonStopAndAskGameMode:
    """Integration tests that drive the daemon's ask flow in game-mode.

    Uses the existing fake seam (FakeRecorder / FakeTranscriber / FakeBrainAsk)
    so no real hardware, Whisper, or brain HTTP call is made.
    """

    def _build_daemon(self, brain_ask_fn):
        """Construct a Daemon with minimal fakes."""
        import numpy as np
        from axi.daemon import Daemon
        from axi.memory import ConversationMemory
        from axi.recorder import SAMPLE_RATE

        # Inline fakes (mirrors conftest pattern from test_daemon.py)
        class _FakeRecorder:
            active_source = "fake"
            is_recording = False

            def start(self):
                self.is_recording = True
                return self.active_source

            def stop(self):
                self.is_recording = False
                t = np.arange(SAMPLE_RATE, dtype=np.float32) / SAMPLE_RATE
                return (0.05 * np.sin(2 * np.pi * 220.0 * t)).astype(np.float32)

        class _FakeTranscriber:
            def transcribe(self, audio):
                return "qué ves en pantalla?", "es", 0.95

        return Daemon(
            recorder=_FakeRecorder(),
            transcriber=_FakeTranscriber(),
            memory=ConversationMemory(),
            brain_ask=brain_ask_fn,
            vision_capture=lambda: "fake-screenshot-b64",
            eyes_capture=lambda: ("fake-webcam-b64", "ok"),
            meeting_factory=lambda **kw: None,
        )

    def test_game_mode_on_passes_game_prompt_to_brain(self, monkeypatch):
        """When game-mode is active and copilot enabled, brain.ask receives the game prompt."""
        from axi import daemon as d
        from axi import extractor as e
        from axi.brain import SYSTEM_PROMPT

        # Silence side effects
        monkeypatch.setattr(d, "notify", lambda *a, **kw: None)
        monkeypatch.setattr(d, "save_last", lambda *a, **kw: "/tmp/x")
        monkeypatch.setattr(d, "save_last_answer", lambda *a, **kw: None)
        monkeypatch.setattr(d, "to_clipboard", lambda *a, **kw: "ok")
        monkeypatch.setattr(d, "speak_text", lambda *a, **kw: None)
        monkeypatch.setattr(e, "extract_and_store", lambda *a, **kw: 0)

        captured: list[dict] = []

        def fake_ask(prompt, *, system=SYSTEM_PROMPT, max_tokens=2048,
                     image_b64=None, history=None, **kwargs):
            captured.append({"system": system, "max_tokens": max_tokens})
            return "respuesta de co-piloto"

        daemon = self._build_daemon(fake_ask)

        # Activate game-mode: patch the predicate in the daemon module
        monkeypatch.setattr(d, "_game_mode_active", lambda: True)
        # Ensure co-pilot is enabled in config
        monkeypatch.setattr(d.config, "get", lambda key, default=None: (
            True if key == "game_copilot_enabled" else default
        ))

        daemon._start_ask()
        daemon._stop_and_ask()

        assert captured, "brain.ask was never called"
        call = captured[0]
        assert call["system"] != SYSTEM_PROMPT, "Expected game-aware prompt but got default"
        assert call["max_tokens"] == 256, f"Expected max_tokens=256 but got {call['max_tokens']}"

    def test_game_mode_off_keeps_default_prompt(self, monkeypatch):
        """When game-mode is inactive, brain.ask receives the standard SYSTEM_PROMPT."""
        from axi import daemon as d
        from axi import extractor as e
        from axi.brain import SYSTEM_PROMPT

        monkeypatch.setattr(d, "notify", lambda *a, **kw: None)
        monkeypatch.setattr(d, "save_last", lambda *a, **kw: "/tmp/x")
        monkeypatch.setattr(d, "save_last_answer", lambda *a, **kw: None)
        monkeypatch.setattr(d, "to_clipboard", lambda *a, **kw: "ok")
        monkeypatch.setattr(d, "speak_text", lambda *a, **kw: None)
        monkeypatch.setattr(e, "extract_and_store", lambda *a, **kw: 0)

        captured: list[dict] = []

        def fake_ask(prompt, *, system=SYSTEM_PROMPT, max_tokens=2048,
                     image_b64=None, history=None, **kwargs):
            captured.append({"system": system, "max_tokens": max_tokens})
            return "respuesta normal"

        daemon = self._build_daemon(fake_ask)

        monkeypatch.setattr(d, "_game_mode_active", lambda: False)
        monkeypatch.setattr(d.config, "get", lambda key, default=None: (
            True if key == "game_copilot_enabled" else default
        ))

        daemon._start_ask()
        daemon._stop_and_ask()

        assert captured, "brain.ask was never called"
        call = captured[0]
        # System may have facts appended but must START with SYSTEM_PROMPT
        assert call["system"].startswith(SYSTEM_PROMPT), (
            "Expected system to start with default SYSTEM_PROMPT when game-mode is off"
        )
        assert call["max_tokens"] == 2048, f"Expected default max_tokens=2048, got {call['max_tokens']}"
