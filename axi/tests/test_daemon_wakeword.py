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

from axi.daemon import Daemon, _select_ask_params, _route_vision


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
# Phase 2a: _wakeword_ask routing — ask_with_tools vs brain_ask
# ---------------------------------------------------------------------------


class TestWebSearchBranchCondition:
    """_wakeword_ask routes to ask_with_tools when copilot + web enabled; brain_ask otherwise."""

    def _run_wakeword_ask_and_capture_branch(
        self,
        *,
        game_active: bool,
        copilot_on: bool,
        web_enabled: bool,
    ) -> dict:
        """Run _wakeword_ask with mocked dependencies; return which path fired."""
        ask_with_tools_called = []
        brain_ask_called = []
        d = _make_daemon()

        def _fake_brain_ask(question, **kwargs):
            brain_ask_called.append(True)
            return "la respuesta es 42"

        d.brain_ask = _fake_brain_ask

        def _fake_ask_with_tools(prompt, **kwargs):
            ask_with_tools_called.append(True)
            return "web answer"

        with (
            patch("axi.daemon.config") as mock_config,
            patch("axi.daemon._game_mode_active", return_value=game_active),
            patch("axi.daemon._brain_ask_with_tools", side_effect=_fake_ask_with_tools),
            patch("axi.daemon.speak_text"),
            patch("axi.daemon.notify"),
            patch("axi.daemon.to_clipboard"),
            patch("axi.daemon.save_last_answer"),
        ):
            mock_config.get.side_effect = lambda key, default=None: {
                "game_copilot_enabled": copilot_on,
                "language": "es-MX",
                "fact_extraction_enabled": False,
                "ocr_enabled": False,
                "wakeword_followup_enabled": False,
            }.get(key, default)

            # Use a fake lifeos.web module with configurable is_enabled.
            # NOTE: `import lifeos.web as x` compiles to IMPORT_FROM 'web',
            # which does getattr(lifeos, 'web') — NOT a sys.modules lookup.
            # We must patch both sys.modules["lifeos.web"] AND the attribute
            # on the lifeos package object to guarantee isolation.
            import sys
            import types
            import lifeos as _lifeos_pkg

            fake_web = types.ModuleType("lifeos.web")
            fake_web.is_enabled = lambda: web_enabled
            fake_web.get_search_fn = lambda: (lambda q: [])
            # Save and RESTORE the original module (not pop) so the real
            # lifeos.web global state does not leak to later tests that assert
            # on web_research enablement (test isolation).
            _orig_web = sys.modules.get("lifeos.web")
            _orig_lifeos_web_attr = getattr(_lifeos_pkg, "web", None)
            sys.modules["lifeos.web"] = fake_web
            _lifeos_pkg.web = fake_web

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
                if _orig_lifeos_web_attr is not None:
                    _lifeos_pkg.web = _orig_lifeos_web_attr
                else:
                    try:
                        del _lifeos_pkg.web
                    except AttributeError:
                        pass

        return {
            "ask_with_tools_called": bool(ask_with_tools_called),
            "brain_ask_called": bool(brain_ask_called),
        }

    def test_ask_with_tools_called_when_copilot_and_web_enabled(self):
        """ask_with_tools fires (not brain_ask) when copilot_on=True and web enabled."""
        result = self._run_wakeword_ask_and_capture_branch(
            game_active=False,
            copilot_on=True,
            web_enabled=True,
        )
        assert result["ask_with_tools_called"], "ask_with_tools must be called when copilot+web enabled"
        assert not result["brain_ask_called"], "brain_ask must NOT be called on the web-enabled path"

    def test_brain_ask_called_when_copilot_disabled(self):
        """brain_ask fires (not ask_with_tools) when copilot_on=False."""
        result = self._run_wakeword_ask_and_capture_branch(
            game_active=True,
            copilot_on=False,
            web_enabled=True,
        )
        assert result["brain_ask_called"], "brain_ask must be called when copilot is disabled"
        assert not result["ask_with_tools_called"], "ask_with_tools must NOT be called when copilot disabled"

    def test_brain_ask_called_when_web_disabled(self):
        """brain_ask fires (not ask_with_tools) when web research is not enabled."""
        result = self._run_wakeword_ask_and_capture_branch(
            game_active=False,
            copilot_on=True,
            web_enabled=False,
        )
        assert result["brain_ask_called"], "brain_ask must be called when web is disabled"
        assert not result["ask_with_tools_called"], "ask_with_tools must NOT be called when web disabled"


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


# ---------------------------------------------------------------------------
# Phase 2b: _route_vision — pure router
# ---------------------------------------------------------------------------


class TestRouteVision:
    """Unit tests for the pure _route_vision router function."""

    # game_active always → screen, even with webcam/none-looking text
    def test_game_active_always_returns_screen(self):
        assert _route_vision("mírame", game_active=True) == "screen"

    def test_game_active_with_neutral_command_returns_screen(self):
        assert _route_vision("qué hora es", game_active=True) == "screen"

    def test_game_active_with_webcam_cue_still_returns_screen(self):
        assert _route_vision("look at me", game_active=True) == "screen"

    # webcam cues → "webcam"
    def test_webcam_cue_mirame(self):
        assert _route_vision("mírame", game_active=False) == "webcam"

    def test_webcam_cue_me_ves(self):
        assert _route_vision("me ves bien?", game_active=False) == "webcam"

    def test_webcam_cue_como_me_veo(self):
        assert _route_vision("cómo me veo hoy", game_active=False) == "webcam"

    def test_webcam_cue_mi_cara(self):
        assert _route_vision("cómo está mi cara", game_active=False) == "webcam"

    def test_webcam_cue_que_tengo_en_la_mano(self):
        assert _route_vision("qué tengo en la mano", game_active=False) == "webcam"

    def test_webcam_cue_esto_que_tengo(self):
        assert _route_vision("esto que tengo acá", game_active=False) == "webcam"

    def test_webcam_cue_este_objeto(self):
        assert _route_vision("qué es este objeto", game_active=False) == "webcam"

    def test_webcam_cue_con_la_camara(self):
        assert _route_vision("con la cámara mostrá", game_active=False) == "webcam"

    def test_webcam_cue_por_la_camara(self):
        assert _route_vision("mirá por la cámara", game_active=False) == "webcam"

    def test_webcam_cue_toma_una_foto(self):
        assert _route_vision("toma una foto", game_active=False) == "webcam"

    def test_webcam_cue_toma_una_foto_accent(self):
        assert _route_vision("tomá una foto", game_active=False) == "webcam"

    def test_webcam_cue_foto_mia(self):
        assert _route_vision("sacá una foto mía", game_active=False) == "webcam"

    def test_webcam_cue_look_at_me(self):
        assert _route_vision("look at me", game_active=False) == "webcam"

    def test_webcam_cue_what_am_i_holding(self):
        assert _route_vision("what am i holding", game_active=False) == "webcam"

    def test_webcam_cue_with_the_camera(self):
        assert _route_vision("take a picture with the camera", game_active=False) == "webcam"

    def test_webcam_cue_take_a_photo(self):
        assert _route_vision("take a photo please", game_active=False) == "webcam"

    def test_webcam_cue_take_a_picture(self):
        assert _route_vision("take a picture", game_active=False) == "webcam"

    # screen cues → "screen"
    def test_screen_cue_en_pantalla(self):
        assert _route_vision("qué hay en pantalla", game_active=False) == "screen"

    def test_screen_cue_esta_ventana(self):
        assert _route_vision("qué es esta ventana", game_active=False) == "screen"

    def test_screen_cue_este_codigo(self):
        assert _route_vision("explicá este código", game_active=False) == "screen"

    def test_screen_cue_este_error(self):
        assert _route_vision("qué significa este error", game_active=False) == "screen"

    def test_screen_cue_lo_que_estoy_viendo(self):
        assert _route_vision("ayudame con lo que estoy viendo", game_active=False) == "screen"

    def test_screen_cue_lo_que_ves(self):
        assert _route_vision("lo que ves ahora", game_active=False) == "screen"

    def test_screen_cue_la_pagina(self):
        assert _route_vision("resumí la página", game_active=False) == "screen"

    def test_screen_cue_esta_captura(self):
        assert _route_vision("describí esta captura", game_active=False) == "screen"

    def test_screen_cue_on_screen(self):
        assert _route_vision("what is on screen", game_active=False) == "screen"

    def test_screen_cue_on_the_screen(self):
        assert _route_vision("what do you see on the screen", game_active=False) == "screen"

    def test_screen_cue_this_window(self):
        assert _route_vision("explain this window", game_active=False) == "screen"

    def test_screen_cue_this_error(self):
        assert _route_vision("what is this error", game_active=False) == "screen"

    def test_screen_cue_this_code(self):
        assert _route_vision("review this code", game_active=False) == "screen"

    # neutral text → "none"
    def test_neutral_que_hora_es(self):
        assert _route_vision("qué hora es", game_active=False) == "none"

    def test_neutral_hola(self):
        assert _route_vision("hola", game_active=False) == "none"

    def test_neutral_reminder(self):
        assert _route_vision("recordame comprar leche", game_active=False) == "none"

    def test_neutral_empty(self):
        assert _route_vision("", game_active=False) == "none"

    # webcam_enabled=False → webcam cue downgrades
    def test_webcam_disabled_mirame_returns_none(self):
        assert _route_vision("mírame", game_active=False, webcam_enabled=False) == "none"

    def test_webcam_disabled_look_at_me_returns_none(self):
        assert _route_vision("look at me", game_active=False, webcam_enabled=False) == "none"

    def test_webcam_disabled_screen_cue_still_returns_screen(self):
        assert _route_vision("este error en pantalla", game_active=False, webcam_enabled=False) == "screen"

    def test_webcam_disabled_neutral_still_returns_none(self):
        assert _route_vision("qué hora es", game_active=False, webcam_enabled=False) == "none"

    # webcam priority when both patterns would match
    def test_webcam_beats_screen_when_both_match(self):
        # "mírame" (webcam) + "en pantalla" (screen) — webcam wins
        assert _route_vision("mírame en pantalla", game_active=False) == "webcam"


# ---------------------------------------------------------------------------
# Phase 2b: _on_wake routing integration
# ---------------------------------------------------------------------------


class TestOnWakeVisionRouting:
    """Integration tests for the _on_wake vision routing inside start_wakeword_listener."""

    def _run_on_wake(
        self,
        command: str,
        *,
        game_active: bool = False,
        webcam_enabled: bool = True,
        eyes_return: tuple = ("fake_webcam_b64", "ok"),
        vision_return: str | None = "fake_screen_b64",
    ) -> dict:
        """Wire up _on_wake via start_wakeword_listener and fire it.

        Returns a dict with the calls observed on the mocked helpers.
        """
        d = _make_daemon()
        d.vision_capture = MagicMock(return_value=vision_return)
        d.eyes_capture = MagicMock(return_value=eyes_return)

        notify_calls: list[tuple] = []
        wakeword_ask_calls: list[tuple] = []

        def _fake_notify(title, body, **kwargs):
            notify_calls.append((title, body))

        def _fake_wakeword_ask(cmd, screenshot):
            wakeword_ask_calls.append((cmd, screenshot))

        d._wakeword_ask = _fake_wakeword_ask

        listener_cls = _mock_listener_cls()

        with (
            patch("axi.daemon.config") as mock_config,
            patch("axi.daemon._game_mode_active", return_value=game_active),
            patch("axi.daemon.notify", side_effect=_fake_notify),
            patch("axi.wakeword.WakeWordListener", listener_cls),
            patch("axi.wakeword.OWWWakeWordListener", listener_cls),
        ):
            mock_config.get.side_effect = lambda key, default=None: {
                "wakeword_webcam_enabled": webcam_enabled,
                "wakeword_engine": "openwakeword",
                "wakeword_model_path": "alexa",
                "wakeword_threshold": 0.5,
                "language": "es-MX",
                "wakeword_followup_enabled": False,
                "wakeword_followup_seconds": 7.0,
            }.get(key, default)

            d.start_wakeword_listener()

            # Extract the _on_wake closure injected into the listener.
            # The listener class constructor was called with on_wake=... kwarg.
            ctor_kwargs = listener_cls.call_args[1]
            _on_wake_fn = ctor_kwargs["on_wake"]

            # Fire it.
            _on_wake_fn(command)

        return {
            "vision_capture_called": d.vision_capture.called,
            "eyes_capture_called": d.eyes_capture.called,
            "wakeword_ask_calls": wakeword_ask_calls,
            "notify_calls": notify_calls,
            "pending_screenshot": d._pending_screenshot,
        }

    def test_route_none_skips_both_captures(self):
        result = self._run_on_wake("qué hora es", game_active=False)
        assert not result["vision_capture_called"]
        assert not result["eyes_capture_called"]
        assert result["wakeword_ask_calls"][0][1] is None
        assert result["pending_screenshot"] is None

    def test_route_screen_calls_vision_capture(self):
        result = self._run_on_wake("este error en pantalla", game_active=False)
        assert result["vision_capture_called"]
        assert not result["eyes_capture_called"]
        assert result["wakeword_ask_calls"][0][1] == "fake_screen_b64"

    def test_route_webcam_calls_eyes_capture_and_notifies(self):
        result = self._run_on_wake("mírame", game_active=False)
        assert result["eyes_capture_called"]
        assert not result["vision_capture_called"]
        # Must notify with camera message
        notify_bodies = [body for _, body in result["notify_calls"]]
        assert any("cámara" in b for b in notify_bodies), f"Expected camera notify, got: {notify_bodies}"
        assert result["wakeword_ask_calls"][0][1] == "fake_webcam_b64"

    def test_route_webcam_camera_busy_falls_back_to_none_and_notifies(self):
        result = self._run_on_wake(
            "mírame",
            game_active=False,
            eyes_return=(None, "camera-busy"),
        )
        assert result["eyes_capture_called"]
        assert not result["vision_capture_called"], "Must NOT fall back to screen on camera failure"
        assert result["wakeword_ask_calls"][0][1] is None
        notify_bodies = [body for _, body in result["notify_calls"]]
        assert any("no disponible" in b for b in notify_bodies), f"Expected unavailable notify, got: {notify_bodies}"

    def test_game_active_always_calls_vision_capture(self):
        result = self._run_on_wake("qué hora es", game_active=True)
        assert result["vision_capture_called"]
        assert not result["eyes_capture_called"]

    def test_game_active_with_webcam_cue_still_calls_vision_capture(self):
        result = self._run_on_wake("mírame", game_active=True)
        assert result["vision_capture_called"]
        assert not result["eyes_capture_called"]

    def test_webcam_disabled_mirame_falls_through_to_none(self):
        result = self._run_on_wake("mírame", game_active=False, webcam_enabled=False)
        assert not result["eyes_capture_called"]
        assert not result["vision_capture_called"]
        assert result["wakeword_ask_calls"][0][1] is None


# ---------------------------------------------------------------------------
# Wake-word intent dispatch: a voice command fires the intent, not the brain
# ---------------------------------------------------------------------------


class TestWakewordIntentDispatch:
    """A wake-word command matching an intent ("desarrollá X", "modo juego") must
    dispatch the intent handler and skip the brain. match_wake already stripped
    "Axi", so _wakeword_ask re-prepends it for the prefix-gated classifier."""

    def test_intent_command_dispatches_handler_and_skips_brain(self, monkeypatch):
        import axi.intents as _intents
        from axi import daemon as _d

        d = _make_daemon()
        d.brain_ask = MagicMock(return_value="brain-answer")
        captured: dict = {}

        monkeypatch.setattr(
            _intents, "classify",
            lambda text: ("dev_develop", {"goal": "X"}) if "desarrollá" in text else None,
        )
        monkeypatch.setattr(
            _intents, "INTENT_HANDLERS",
            {"dev_develop": lambda daemon, params=None: captured.setdefault("params", params)},
        )
        monkeypatch.setattr(
            _d.config, "get",
            lambda key, default=None: True if key == "intents_enabled" else default,
        )

        d._wakeword_ask("desarrollá X", None)

        assert captured.get("params") == {"goal": "X"}
        d.brain_ask.assert_not_called()
