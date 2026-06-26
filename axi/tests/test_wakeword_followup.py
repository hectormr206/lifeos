"""Tests for Feature C — follow-up conversation window in WakeWordListener.

Validates the followup_active_fn injection in both WakeWordListener and
OWWWakeWordListener._process_segment / _process_command_segment paths.

No real audio hardware required: FakeStreamingCapture from test_wakeword.py
is replicated inline for isolation, and transcribe_fn is always mocked.
"""
from __future__ import annotations

import numpy as np
import pytest

from axi.wakeword import WakeWordListener, OWWWakeWordListener


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_audio() -> np.ndarray:
    """Return a 16000-sample silence segment (1 s at 16 kHz)."""
    return np.zeros(16000, dtype=np.float32)


def _build_ww_listener(
    transcribe_fn,
    on_wake_fn,
    *,
    followup_active_fn=None,
) -> WakeWordListener:
    """Build a WakeWordListener with a no-op stream factory (no hardware)."""

    def _fake_stream_factory(callback, **kwargs):
        class _FakeStream:
            def start(self):
                pass

            def stop(self):
                pass

            def close(self):
                pass

        return _FakeStream()

    return WakeWordListener(
        transcribe_fn=transcribe_fn,
        on_wake=on_wake_fn,
        stream_factory=_fake_stream_factory,
        vad_aggressiveness=1,
        silence_duration_s=0.1,
        followup_active_fn=followup_active_fn,
    )


def _build_oww_listener(
    transcribe_fn,
    on_wake_fn,
    *,
    followup_active_fn=None,
) -> OWWWakeWordListener:
    """Build an OWWWakeWordListener with injected predict_fn (no ONNX)."""

    def _fake_stream_factory(callback, **kwargs):
        class _FakeStream:
            def start(self):
                pass

            def stop(self):
                pass

            def close(self):
                pass

        return _FakeStream()

    def _always_below_threshold(_chunk):
        # Never fire acoustic wake — tests control this via _process_command_segment.
        return {"test_model": 0.0}

    return OWWWakeWordListener(
        transcribe_fn=transcribe_fn,
        on_wake=on_wake_fn,
        stream_factory=_fake_stream_factory,
        oww_predict_fn=_always_below_threshold,
        oww_threshold=0.5,
        followup_active_fn=followup_active_fn,
    )


# ---------------------------------------------------------------------------
# WakeWordListener._process_segment — follow-up window tests
# ---------------------------------------------------------------------------


class TestWakeWordListenerFollowup:
    """Tests for WakeWordListener._process_segment follow-up window behaviour."""

    def test_followup_active_fires_on_wake(self):
        """When followup_active_fn returns True, a non-wake transcript calls on_wake."""
        called: list[str] = []

        def fake_transcribe(audio):
            return "hay alguna poción cerca", "es", 0.9

        def fake_on_wake(command: str):
            called.append(command)

        listener = _build_ww_listener(
            transcribe_fn=fake_transcribe,
            on_wake_fn=fake_on_wake,
            followup_active_fn=lambda: True,
        )

        # Call _process_segment directly — no hardware needed.
        listener._process_segment(_make_audio())

        assert len(called) == 1, "on_wake should have been called once"
        assert called[0] == "hay alguna poción cerca"

    def test_followup_inactive_does_not_fire_on_wake(self):
        """When followup_active_fn returns False, a non-wake transcript is ignored."""
        called: list[str] = []

        def fake_transcribe(audio):
            return "hay alguna poción cerca", "es", 0.9

        def fake_on_wake(command: str):
            called.append(command)

        listener = _build_ww_listener(
            transcribe_fn=fake_transcribe,
            on_wake_fn=fake_on_wake,
            followup_active_fn=lambda: False,
        )

        listener._process_segment(_make_audio())

        assert len(called) == 0, "on_wake must NOT fire when follow-up window is closed"

    def test_followup_active_but_empty_text_does_not_fire(self):
        """Empty transcript does not trigger on_wake even when the window is open."""
        called: list[str] = []

        def fake_transcribe(audio):
            # Empty after strip — should not route.
            return "   ", "es", 0.5

        def fake_on_wake(command: str):
            called.append(command)

        listener = _build_ww_listener(
            transcribe_fn=fake_transcribe,
            on_wake_fn=fake_on_wake,
            followup_active_fn=lambda: True,
        )

        listener._process_segment(_make_audio())

        assert len(called) == 0, "Empty transcript must not call on_wake"

    def test_followup_active_but_very_short_text_does_not_fire(self):
        """Text with <= 2 characters is treated as noise — on_wake not called."""
        called: list[str] = []

        def fake_transcribe(audio):
            return "ok", "es", 0.5  # 2 chars — below the > 2 guard

        def fake_on_wake(command: str):
            called.append(command)

        listener = _build_ww_listener(
            transcribe_fn=fake_transcribe,
            on_wake_fn=fake_on_wake,
            followup_active_fn=lambda: True,
        )

        listener._process_segment(_make_audio())

        assert len(called) == 0, "Very short text must not call on_wake"

    def test_followup_none_preserves_original_behaviour(self):
        """When followup_active_fn is None, non-wake transcripts are silently dropped."""
        called: list[str] = []

        def fake_transcribe(audio):
            return "hay alguna poción cerca", "es", 0.9

        def fake_on_wake(command: str):
            called.append(command)

        listener = _build_ww_listener(
            transcribe_fn=fake_transcribe,
            on_wake_fn=fake_on_wake,
            followup_active_fn=None,
        )

        listener._process_segment(_make_audio())

        assert len(called) == 0, "followup_active_fn=None must preserve original behaviour"

    def test_followup_active_with_actual_wake_word_still_works(self):
        """A real wake word transcript fires on_wake normally (wake path unaffected)."""
        called: list[str] = []

        def fake_transcribe(audio):
            return "axi, qué veo en pantalla", "es", 0.95

        def fake_on_wake(command: str):
            called.append(command)

        listener = _build_ww_listener(
            transcribe_fn=fake_transcribe,
            on_wake_fn=fake_on_wake,
            followup_active_fn=lambda: False,  # window closed — but wake word present
        )

        listener._process_segment(_make_audio())

        assert len(called) == 1, "Wake word must always fire on_wake regardless of follow-up"
        assert "qué veo" in called[0]


# ---------------------------------------------------------------------------
# OWWWakeWordListener._process_command_segment — follow-up window tests
# ---------------------------------------------------------------------------


class TestOWWListenerFollowup:
    """Tests for OWWWakeWordListener._process_command_segment follow-up window."""

    def test_followup_active_fires_on_wake(self):
        """When followup_active_fn returns True, a non-wake command calls on_wake."""
        called: list[str] = []

        def fake_transcribe(audio):
            return "sí, eso es lo que necesito", "es", 0.9

        def fake_on_wake(command: str):
            called.append(command)

        listener = _build_oww_listener(
            transcribe_fn=fake_transcribe,
            on_wake_fn=fake_on_wake,
            followup_active_fn=lambda: True,
        )

        listener._process_command_segment(_make_audio())

        assert len(called) == 1
        assert called[0] == "sí, eso es lo que necesito"

    def test_followup_inactive_does_not_fire(self):
        """When followup_active_fn returns False, non-wake command is dropped."""
        called: list[str] = []

        def fake_transcribe(audio):
            return "sí, eso es lo que necesito", "es", 0.9

        def fake_on_wake(command: str):
            called.append(command)

        listener = _build_oww_listener(
            transcribe_fn=fake_transcribe,
            on_wake_fn=fake_on_wake,
            followup_active_fn=lambda: False,
        )

        listener._process_command_segment(_make_audio())

        assert len(called) == 0

    def test_followup_none_preserves_original_behaviour(self):
        """followup_active_fn=None: non-wake command segment is silently dropped."""
        called: list[str] = []

        def fake_transcribe(audio):
            return "sí, eso es lo que necesito", "es", 0.9

        def fake_on_wake(command: str):
            called.append(command)

        listener = _build_oww_listener(
            transcribe_fn=fake_transcribe,
            on_wake_fn=fake_on_wake,
            followup_active_fn=None,
        )

        listener._process_command_segment(_make_audio())

        assert len(called) == 0

    def test_followup_active_empty_text_does_not_fire(self):
        """Empty transcript does not trigger on_wake in OWW follow-up path."""
        called: list[str] = []

        def fake_transcribe(audio):
            return "", "es", 0.0

        def fake_on_wake(command: str):
            called.append(command)

        listener = _build_oww_listener(
            transcribe_fn=fake_transcribe,
            on_wake_fn=fake_on_wake,
            followup_active_fn=lambda: True,
        )

        listener._process_command_segment(_make_audio())

        assert len(called) == 0


# ---------------------------------------------------------------------------
# Feature C — follow-up window OPENING gate (daemon-side regression guard)
# ---------------------------------------------------------------------------


class TestShouldOpenFollowup:
    """Daemon._should_open_followup opens the window ONLY when Axi's answer
    ends with a question. Regression guard for the runaway false-trigger bug
    where the window caught the user's phone-call speech and replied to it.
    """

    def test_plain_answer_does_not_open(self):
        from axi.daemon import Daemon
        assert Daemon._should_open_followup("Son las 3 en punto.") is False

    def test_question_opens(self):
        from axi.daemon import Daemon
        assert Daemon._should_open_followup("¿Querés que busque más detalles?") is True

    def test_question_with_trailing_whitespace_opens(self):
        from axi.daemon import Daemon
        assert Daemon._should_open_followup("¿Seguimos?  \n") is True

    def test_disabled_config_never_opens(self, monkeypatch):
        from axi import daemon as _d
        monkeypatch.setattr(
            _d.config,
            "get",
            lambda key, default=None: False if key == "wakeword_followup_enabled" else default,
        )
        assert _d.Daemon._should_open_followup("¿Querés más?") is False
