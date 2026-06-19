"""Tests for widened sleep gate in dashboard._try_nano_extract (task 2.3).

Verifies:
- Word-form: "me dormí a las once de la noche y desperté a las siete" fires the
  gate via _SLEEP_FROM_TO_RE and computes sleep deterministically (~8h).
- Digit-form regression: "a las 11 pm ... a las 5 am" still computes correctly
  via the existing _CLOCK_TIME_RE path (gate still fires for two digit clocks).
"""
from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import MagicMock, patch
from datetime import datetime, timezone

import pytest


def _nano_result(**kwargs):
    defaults = dict(
        domain=None, kind=None, title="test entry", confidence=0.9,
        people=[], dates_text=None, items=None, amount=None,
        merchant=None, currency="MXN", duration_minutes=None,
        systolic=None, diastolic=None, pulse_bpm=None,
        sleep_hours=None, weight_kg=None, glucose_mg_dl=None,
    )
    defaults.update(kwargs)
    return SimpleNamespace(**defaults)


class TestSleepGateWordForm:
    """Word-form sleep text must fire the deterministic gate."""

    def test_word_form_sleep_fires_gate_and_computes_deterministically(self, monkeypatch):
        """'me dormí a las once de la noche y desperté a las siete' → ~8h, entry kind=vital."""
        from axi import dashboard

        utterance = "me dormí a las once de la noche y desperté a las siete"
        # Nano gives a wrong sleep value — we expect the deterministic parser to override.
        nano_result = _nano_result(domain="health", kind="vital", sleep_hours=6.0)

        created_entry = SimpleNamespace(id="sleep-word-1", kind="vital")
        create_spy = MagicMock(return_value=created_entry)
        monkeypatch.setattr("lifeos.health.entries.create", create_spy)

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance,
                location_tag=None,
                original_text=utterance,
            )

        assert result is not None, "Expected a result dict, got None"
        assert result["domain"] == "health"

        create_spy.assert_called_once()
        _, call_kwargs = create_spy.call_args
        # Kind must be vital (not note) — gate fired and deterministic path ran
        assert call_kwargs["kind"] == "vital", (
            f"Expected kind=vital but got {call_kwargs['kind']}"
        )
        # The deterministic value for 11pm→7am is 8h
        data = call_kwargs.get("data") or {}
        assert data.get("type") == "sleep_hours", f"Expected sleep_hours data, got {data}"
        sleep_val = data.get("value")
        assert sleep_val is not None, "data.value is None — gate did not fire"
        assert abs(sleep_val - 8.0) < 0.1, f"Expected ~8h but got {sleep_val}"

    def test_word_form_gate_fires_via_sleep_from_to_re(self):
        """Direct check: _SLEEP_FROM_TO_RE matches the word-form utterance."""
        from axi.dashboard import _CLOCK_TIME_RE
        from lifeos.health.ingestion import _SLEEP_FROM_TO_RE

        utterance = "me dormí a las once de la noche y desperté a las siete"
        # Digit gate should NOT fire (no digit clocks)
        assert len(_CLOCK_TIME_RE.findall(utterance)) < 2, (
            "Digit-clock gate should not fire for word-form input"
        )
        # Word-form gate MUST fire
        assert _SLEEP_FROM_TO_RE.search(utterance) is not None, (
            "_SLEEP_FROM_TO_RE should match the word-form sleep utterance"
        )


class TestSleepGateDigitRegression:
    """Digit-form sleep still works through the existing _CLOCK_TIME_RE path."""

    def test_digit_form_sleep_still_computes_correctly(self, monkeypatch):
        """'a las 11 pm ... a las 5 am' → 6h (digit gate path, regression check)."""
        from axi import dashboard

        utterance = "me dormí a las 11 pm y me desperté a las 5 am"
        nano_result = _nano_result(domain="health", kind="vital", sleep_hours=10.0)

        created_entry = SimpleNamespace(id="sleep-digit-1", kind="vital")
        create_spy = MagicMock(return_value=created_entry)
        monkeypatch.setattr("lifeos.health.entries.create", create_spy)

        with patch("lifeos.agents.extractor.extract", return_value=nano_result):
            result = dashboard._try_nano_extract(
                text=utterance,
                location_tag=None,
                original_text=utterance,
            )

        assert result is not None
        assert result["domain"] == "health"
        create_spy.assert_called_once()
        _, call_kwargs = create_spy.call_args
        assert call_kwargs["kind"] == "vital"
        data = call_kwargs.get("data") or {}
        assert data.get("type") == "sleep_hours"
        sleep_val = data.get("value")
        assert sleep_val is not None
        # 11pm → 5am = 6h
        assert abs(sleep_val - 6.0) < 0.1, f"Expected ~6h but got {sleep_val}"

    def test_digit_clock_re_fires_for_digit_form(self):
        """Direct check: _CLOCK_TIME_RE fires >= 2 for digit-form sleep text."""
        from axi.dashboard import _CLOCK_TIME_RE

        utterance = "me dormí a las 11 pm y me desperté a las 5 am"
        assert len(_CLOCK_TIME_RE.findall(utterance)) >= 2
