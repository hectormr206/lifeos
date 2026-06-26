"""Tests for Feature A & C config schema additions.

Verifies that the three new wakeword-related config keys are correctly
defined in the schema with the right types and defaults.
"""
from __future__ import annotations

import pytest

from axi.config_schema import defaults, load_validated, field_names, ConfigError


class TestWakewordAlwaysOn:
    """Tests for the wakeword_always_on config key."""

    def test_default_is_true(self):
        d = defaults()
        assert "wakeword_always_on" in d
        assert d["wakeword_always_on"] is True

    def test_field_exists_in_schema(self):
        assert "wakeword_always_on" in set(field_names())

    def test_accepts_false(self):
        out = load_validated({"wakeword_always_on": False})
        assert out["wakeword_always_on"] is False

    def test_accepts_true(self):
        out = load_validated({"wakeword_always_on": True})
        assert out["wakeword_always_on"] is True

    def test_rejects_non_bool(self):
        with pytest.raises(ConfigError):
            load_validated({"wakeword_always_on": 1})

    def test_rejects_string(self):
        with pytest.raises(ConfigError):
            load_validated({"wakeword_always_on": "yes"})


class TestWakewordFollowupEnabled:
    """Tests for the wakeword_followup_enabled config key."""

    def test_default_is_true(self):
        d = defaults()
        assert "wakeword_followup_enabled" in d
        assert d["wakeword_followup_enabled"] is True

    def test_field_exists_in_schema(self):
        assert "wakeword_followup_enabled" in set(field_names())

    def test_accepts_false(self):
        out = load_validated({"wakeword_followup_enabled": False})
        assert out["wakeword_followup_enabled"] is False

    def test_rejects_non_bool(self):
        with pytest.raises(ConfigError):
            load_validated({"wakeword_followup_enabled": 0})


class TestWakewordFollowupSeconds:
    """Tests for the wakeword_followup_seconds config key."""

    def test_default_is_7_seconds(self):
        d = defaults()
        assert "wakeword_followup_seconds" in d
        assert d["wakeword_followup_seconds"] == pytest.approx(7.0)

    def test_field_exists_in_schema(self):
        assert "wakeword_followup_seconds" in set(field_names())

    def test_accepts_float(self):
        out = load_validated({"wakeword_followup_seconds": 10.0})
        assert out["wakeword_followup_seconds"] == pytest.approx(10.0)

    def test_accepts_minimum_boundary(self):
        out = load_validated({"wakeword_followup_seconds": 1.0})
        assert out["wakeword_followup_seconds"] == pytest.approx(1.0)

    def test_rejects_below_minimum(self):
        with pytest.raises(ConfigError):
            load_validated({"wakeword_followup_seconds": 0.5})

    def test_rejects_above_maximum(self):
        with pytest.raises(ConfigError):
            load_validated({"wakeword_followup_seconds": 61.0})

    def test_accepts_integer_coerced_as_number(self):
        # The field type is "number" which accepts both int and float.
        out = load_validated({"wakeword_followup_seconds": 5})
        assert out["wakeword_followup_seconds"] == pytest.approx(5.0)

    def test_rejects_string(self):
        with pytest.raises(ConfigError):
            load_validated({"wakeword_followup_seconds": "7"})


class TestDefaultsRoundTrip:
    """Validate that new defaults pass their own validation (regression guard)."""

    def test_all_new_keys_round_trip(self):
        d = defaults()
        out = load_validated(d)
        assert out["wakeword_always_on"] == d["wakeword_always_on"]
        assert out["wakeword_followup_enabled"] == d["wakeword_followup_enabled"]
        assert out["wakeword_followup_seconds"] == pytest.approx(d["wakeword_followup_seconds"])
