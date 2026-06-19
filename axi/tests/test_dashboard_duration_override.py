"""Tests for deterministic duration_minutes override in dashboard._try_nano_extract
(task 2.2).

Verifies:
- When _parse_duration_es returns non-None, it OVERRIDES the nano's duration_minutes.
- When _parse_duration_es returns None, the nano's duration_minutes is kept.
"""
from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest


def _nano_result(**kwargs):
    """Return a SimpleNamespace mimicking the nano ExtractedEntry shape."""
    defaults = dict(
        domain=None,
        kind=None,
        title="test entry",
        confidence=0.9,
        people=[],
        dates_text=None,
        items=None,
        amount=None,
        merchant=None,
        currency="MXN",
        duration_minutes=None,
        systolic=None,
        diastolic=None,
        pulse_bpm=None,
        sleep_hours=None,
        weight_kg=None,
        glucose_mg_dl=None,
    )
    defaults.update(kwargs)
    return SimpleNamespace(**defaults)


class TestDurationDeterministicOverride:
    """The deterministic duration parser must override the nano's value."""

    def test_deterministic_overrides_nano_duration(self, monkeypatch):
        """When _parse_duration_es returns 30, nano's 60 must be overridden."""
        from axi import dashboard

        utterance = "hice media hora de ejercicio"
        # Nano says 60 minutes (wrong), deterministic says 30.
        nano_result = _nano_result(
            domain="exercise",
            kind="other",
            title="ejercicio",
            duration_minutes=60,  # nano is wrong
        )
        created_session = SimpleNamespace(id="sess-det-1")
        create_spy = MagicMock(return_value=created_session)
        monkeypatch.setattr("lifeos.exercise.sessions.create", create_spy)

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance,
                location_tag=None,
                original_text=utterance,
            )

        assert result is not None, "Expected result dict, got None"
        assert result["domain"] == "exercise"
        # The create call must have received the deterministic value (30), not nano's 60
        create_spy.assert_called_once()
        _, call_kwargs = create_spy.call_args
        assert call_kwargs["duration_minutes"] == 30, (
            f"Expected 30 (deterministic) but got {call_kwargs['duration_minutes']}"
        )

    def test_nano_duration_kept_when_deterministic_returns_none(self, monkeypatch):
        """When _parse_duration_es returns None, the nano's duration_minutes is kept."""
        from axi import dashboard

        utterance = "fui al gimnasio"  # no duration phrase → _parse_duration_es → None
        nano_result = _nano_result(
            domain="exercise",
            kind="other",
            title="ejercicio",
            duration_minutes=45,  # nano provided this
        )
        created_session = SimpleNamespace(id="sess-det-2")
        create_spy = MagicMock(return_value=created_session)
        monkeypatch.setattr("lifeos.exercise.sessions.create", create_spy)

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance,
                location_tag=None,
                original_text=utterance,
            )

        assert result is not None, "Expected result dict, got None"
        create_spy.assert_called_once()
        _, call_kwargs = create_spy.call_args
        assert call_kwargs["duration_minutes"] == 45, (
            f"Expected 45 (nano fallback) but got {call_kwargs['duration_minutes']}"
        )

    def test_una_hora_y_cuarto_overrides_nano(self, monkeypatch):
        """'una hora y cuarto' → 75 overrides nano's wrong value."""
        from axi import dashboard

        utterance = "entrené una hora y cuarto"
        nano_result = _nano_result(
            domain="exercise",
            kind="run",
            title="entreno",
            duration_minutes=100,  # nano is wrong
        )
        created_session = SimpleNamespace(id="sess-det-3")
        create_spy = MagicMock(return_value=created_session)
        monkeypatch.setattr("lifeos.exercise.sessions.create", create_spy)

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance,
                location_tag=None,
                original_text=utterance,
            )

        assert result is not None
        _, call_kwargs = create_spy.call_args
        assert call_kwargs["duration_minutes"] == 75
