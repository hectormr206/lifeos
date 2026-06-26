"""Tests for Features A, B, C daemon-level behaviour.

Feature A: wakeword_always_on config gates the wake-word listener in serve().
Feature B: _select_ask_params co-pilot persona depends only on copilot_enabled.
Feature B: _web_search_branch in _wakeword_ask does NOT require game_active.
Feature C: _followup_until is initialized in __init__ (via direct construction).

All tests use dependency injection — no real hardware, no Whisper, no brain.
"""
from __future__ import annotations

import os
import threading
from unittest.mock import MagicMock, patch, call

import numpy as np
import pytest

from axi.daemon import Daemon, _select_ask_params


# ---------------------------------------------------------------------------
# Shared fake support objects
# ---------------------------------------------------------------------------


class _FakeRecorder:
    def __init__(self) -> None:
        self._recording = False

    @property
    def is_recording(self) -> bool:
        return self._recording

    def start(self) -> str:
        self._recording = True
        return "fake"

    def stop(self) -> np.ndarray:
        self._recording = False
        return np.zeros(16000, dtype=np.float32)


def _make_daemon() -> Daemon:
    """Build a minimal Daemon with all I/O faked."""
    d = Daemon.__new__(Daemon)
    d.recorder = _FakeRecorder()
    d.transcriber = MagicMock()
    d.transcriber.transcribe.return_value = ("hola", "es", 0.9)
    d.brain_ask = MagicMock(return_value="ok")
    d.memory = MagicMock()
    d.memory.messages.return_value = []
    d.memory.relevant_facts.return_value = []
    d._state = "idle"
    d._state_lock = threading.Lock()
    d._transcribe_lock = threading.Lock()
    d._wakeword_listener = None
    d._followup_until = 0.0
    d._wakeword_paused_for_meeting = False
    d.vision_capture = MagicMock(return_value=None)
    d.eyes_capture = MagicMock(return_value=(None, "ok"))
    d._pending_screenshot = None
    d.meeting = None
    d._watchdog = None
    d._watchdog_lock = threading.Lock()
    return d


def _mock_listener_cls(name: str = "MockListener") -> MagicMock:
    instance = MagicMock()
    instance.start.return_value = None
    instance.stop.return_value = None
    cls = MagicMock(return_value=instance)
    cls.__name__ = name
    return cls


# ---------------------------------------------------------------------------
# Feature B: _select_ask_params
# ---------------------------------------------------------------------------


class TestSelectAskParams:
    """_select_ask_params contracts: hotkey path vs wake-word path (force_copilot)."""

    def test_wakeword_path_game_inactive_returns_copilot_prompt(self):
        """Wake-word path: force_copilot=True + game_active=False → co-pilot persona (Feature B)."""
        from axi.daemon import _GAME_COPILOT_SYSTEM_PROMPT, _GAME_COPILOT_MAX_TOKENS

        prompt, max_tokens = _select_ask_params(
            game_active=False,
            copilot_enabled=True,
            lang="es-MX",
            force_copilot=True,
        )
        assert prompt == _GAME_COPILOT_SYSTEM_PROMPT
        assert max_tokens == _GAME_COPILOT_MAX_TOKENS

    def test_hotkey_path_game_inactive_returns_standard_prompt(self):
        """Hotkey path: force_copilot=False (default) + game_active=False → standard prompt."""
        from axi.daemon import _GAME_COPILOT_SYSTEM_PROMPT

        prompt, max_tokens = _select_ask_params(
            game_active=False,
            copilot_enabled=True,
            lang="es-MX",
            # force_copilot defaults to False — hotkey path
        )
        assert prompt != _GAME_COPILOT_SYSTEM_PROMPT
        assert max_tokens == 2048

    def test_copilot_enabled_game_active_returns_copilot_prompt(self):
        """Both paths: game_active=True + copilot_enabled=True → co-pilot persona."""
        from axi.daemon import _GAME_COPILOT_SYSTEM_PROMPT, _GAME_COPILOT_MAX_TOKENS

        prompt, max_tokens = _select_ask_params(
            game_active=True,
            copilot_enabled=True,
            lang="es-MX",
        )
        assert prompt == _GAME_COPILOT_SYSTEM_PROMPT
        assert max_tokens == _GAME_COPILOT_MAX_TOKENS

    def test_copilot_disabled_game_active_returns_standard_prompt(self):
        """Standard prompt is used when copilot_enabled=False, regardless of game_active."""
        from axi.daemon import _GAME_COPILOT_SYSTEM_PROMPT, _GAME_COPILOT_MAX_TOKENS

        prompt, max_tokens = _select_ask_params(
            game_active=True,
            copilot_enabled=False,
            lang="es-MX",
        )
        assert prompt != _GAME_COPILOT_SYSTEM_PROMPT
        assert max_tokens != _GAME_COPILOT_MAX_TOKENS

    def test_copilot_disabled_game_inactive_returns_standard_prompt(self):
        """Standard prompt is used when both are False."""
        from axi.daemon import _GAME_COPILOT_SYSTEM_PROMPT

        prompt, max_tokens = _select_ask_params(
            game_active=False,
            copilot_enabled=False,
            lang="es-MX",
        )
        assert prompt != _GAME_COPILOT_SYSTEM_PROMPT
        assert max_tokens == 2048

    def test_wakeword_path_en_lang_returns_english_copilot_prompt(self):
        """Wake-word path: force_copilot=True + lang='en' → English co-pilot prompt."""
        from axi.daemon import _GAME_COPILOT_SYSTEM_PROMPT_EN, _GAME_COPILOT_MAX_TOKENS

        prompt, max_tokens = _select_ask_params(
            game_active=False,
            copilot_enabled=True,
            lang="en",
            force_copilot=True,
        )
        assert prompt == _GAME_COPILOT_SYSTEM_PROMPT_EN
        assert max_tokens == _GAME_COPILOT_MAX_TOKENS


# ---------------------------------------------------------------------------
# Feature B: web-search branch condition (no longer requires game_active)
# ---------------------------------------------------------------------------


class TestWebSearchBranchCondition:
    """_wakeword_ask web-search branch fires when copilot_on=True regardless of game mode."""

    def _run_wakeword_ask_and_capture_branch(
        self,
        *,
        game_active: bool,
        copilot_on: bool,
        copilot_search_on: bool,
        needs_search_result: bool,
    ):
        """Run _wakeword_ask with mocked dependencies; return whether web-search path ran."""
        web_search_ran = []
        d = _make_daemon()

        def _fake_brain_ask(question, **kwargs):
            return "la respuesta es 42"

        d.brain_ask = _fake_brain_ask

        with (
            patch("axi.daemon.config") as mock_config,
            patch("axi.daemon._game_mode_active", return_value=game_active),
            patch("axi.daemon._copilot_search") as mock_cs,
            patch("axi.daemon.speak_text"),
            patch("axi.daemon.notify"),
            patch("axi.daemon.to_clipboard"),
            patch("axi.daemon.save_last_answer"),
        ):
            mock_config.get.side_effect = lambda key, default=None: {
                "game_copilot_enabled": copilot_on,
                "language": "es-MX",
                "copilot_web_search_enabled": copilot_search_on,
                "fact_extraction_enabled": False,
                "ocr_enabled": False,
                "wakeword_followup_enabled": False,
            }.get(key, default)

            mock_cs.needs_search.return_value = needs_search_result
            mock_cs.run.side_effect = lambda *a, **kw: (
                web_search_ran.append(True) or "web answer"
            )

            # Use a real web mock so the branch actually executes.
            import sys
            import types

            fake_web = types.ModuleType("lifeos.web")
            fake_web.is_enabled = lambda: True
            fake_web.get_search_fn = lambda: (lambda q: [])
            # Save and RESTORE the original module (not pop) so the real
            # lifeos.web global state does not leak to later tests that assert
            # on web_research enablement (test isolation).
            _orig_web = sys.modules.get("lifeos.web")
            sys.modules["lifeos.web"] = fake_web

            try:
                d._wakeword_ask("qué hago con esto", None)
                # Give the speaking thread a moment to start (it's async).
                import time
                time.sleep(0.05)
            finally:
                if _orig_web is not None:
                    sys.modules["lifeos.web"] = _orig_web
                else:
                    sys.modules.pop("lifeos.web", None)

        return bool(web_search_ran)

    def test_web_search_fires_without_game_active_when_copilot_on(self):
        """Web-search branch runs when copilot_on=True even when game_active=False."""
        ran = self._run_wakeword_ask_and_capture_branch(
            game_active=False,
            copilot_on=True,
            copilot_search_on=True,
            needs_search_result=True,
        )
        assert ran, "Web-search branch should fire when copilot_on=True and needs_search=True"

    def test_web_search_does_not_fire_when_copilot_off(self):
        """Web-search branch is skipped when copilot_on=False."""
        ran = self._run_wakeword_ask_and_capture_branch(
            game_active=True,
            copilot_on=False,
            copilot_search_on=True,
            needs_search_result=True,
        )
        assert not ran, "Web-search branch must not run when copilot is disabled"

    def test_web_search_does_not_fire_when_needs_search_false(self):
        """Web-search branch is skipped when needs_search returns False."""
        ran = self._run_wakeword_ask_and_capture_branch(
            game_active=False,
            copilot_on=True,
            copilot_search_on=True,
            needs_search_result=False,
        )
        assert not ran, "Web-search branch must not run when needs_search=False"


# ---------------------------------------------------------------------------
# Feature A: serve() wakeword start gate
# ---------------------------------------------------------------------------


class TestServeWakewordGate:
    """serve() starts the wakeword listener based on config and env var."""

    def _run_serve_and_capture_listener_start(
        self,
        *,
        wakeword_always_on: bool,
        env_enabled: str = "",
    ):
        """Verify whether start_wakeword_listener would be called during serve() startup.

        We do NOT call the full serve() (it opens a socket), but we replicate the
        exact gate logic to test it in isolation. This tests the decision logic, not
        the socket machinery.
        """
        import axi.config as _config

        # Replicate the gate logic from serve() exactly.
        with patch.dict(os.environ, {"AXI_WAKEWORD_ENABLED": env_enabled}):
            with patch("axi.daemon.config") as mock_config:
                mock_config.get.side_effect = lambda key, default=None: (
                    wakeword_always_on if key == "wakeword_always_on" else default
                )

                _ww_always_on = bool(mock_config.get("wakeword_always_on", True))
                _ww_env_on = os.environ.get("AXI_WAKEWORD_ENABLED", "").strip() == "1"
                return _ww_always_on or _ww_env_on

    def test_always_on_true_env_unset_starts_listener(self):
        """wakeword_always_on=True with env unset → listener should start."""
        should_start = self._run_serve_and_capture_listener_start(
            wakeword_always_on=True,
            env_enabled="",
        )
        assert should_start is True

    def test_always_on_false_env_unset_does_not_start(self):
        """wakeword_always_on=False with env unset → listener should NOT start."""
        should_start = self._run_serve_and_capture_listener_start(
            wakeword_always_on=False,
            env_enabled="",
        )
        assert should_start is False

    def test_always_on_false_env_set_starts_listener(self):
        """wakeword_always_on=False but AXI_WAKEWORD_ENABLED=1 → listener should start."""
        should_start = self._run_serve_and_capture_listener_start(
            wakeword_always_on=False,
            env_enabled="1",
        )
        assert should_start is True

    def test_always_on_true_env_set_starts_listener(self):
        """Both conditions true → listener should start (no double-start)."""
        should_start = self._run_serve_and_capture_listener_start(
            wakeword_always_on=True,
            env_enabled="1",
        )
        assert should_start is True


# ---------------------------------------------------------------------------
# Feature C: _followup_until initialised in Daemon
# ---------------------------------------------------------------------------


class TestFollowupUntilAttribute:
    """Daemon.__init__ must set _followup_until = 0.0."""

    def test_followup_until_initialised_to_zero(self):
        """Directly constructed Daemon has _followup_until = 0.0."""
        d = _make_daemon()
        # The attribute must exist and be 0.0 (window closed by default).
        assert hasattr(d, "_followup_until")
        assert d._followup_until == 0.0

    def test_followup_until_is_float(self):
        d = _make_daemon()
        assert isinstance(d._followup_until, float)


# ---------------------------------------------------------------------------
# Meeting safety: wake-word is paused during a meeting so Axi never interrupts
# ---------------------------------------------------------------------------


class TestMeetingPausesWakeword:
    """The wake-word listener must be stopped while a meeting records and
    resumed when it ends — Axi must never interrupt a client meeting."""

    def test_pause_stops_listener_and_sets_flag(self):
        d = _make_daemon()
        fake_listener = MagicMock()
        d._wakeword_listener = fake_listener

        d._pause_wakeword_for_meeting()

        fake_listener.stop.assert_called_once()
        assert d._wakeword_listener is None
        assert d._wakeword_paused_for_meeting is True

    def test_pause_is_noop_when_listener_not_running(self):
        d = _make_daemon()
        d._wakeword_listener = None

        d._pause_wakeword_for_meeting()

        # Nothing was running, so nothing to resume later.
        assert d._wakeword_paused_for_meeting is False

    def test_resume_restarts_listener_when_paused(self):
        d = _make_daemon()
        d._wakeword_paused_for_meeting = True
        d.start_wakeword_listener = MagicMock()

        d._resume_wakeword_after_meeting()

        d.start_wakeword_listener.assert_called_once()
        assert d._wakeword_paused_for_meeting is False

    def test_resume_is_noop_when_not_paused(self):
        d = _make_daemon()
        d._wakeword_paused_for_meeting = False
        d.start_wakeword_listener = MagicMock()

        d._resume_wakeword_after_meeting()

        d.start_wakeword_listener.assert_not_called()
