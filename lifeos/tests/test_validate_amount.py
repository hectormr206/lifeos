"""Tests for _validate_amount in lifeos.health.ingestion (task 2.4).

Actually lives in health/ingestion.py for now per the design (single module for
L2 deterministic helpers). The function validates a raw_text + nano_amount pair:
- A plausible amount passes through (returns that amount).
- An implausible/garbled amount is not silently trusted (returns None).
"""
from __future__ import annotations

import pytest


class TestValidateAmount:
    """Conservative validate-and-skip guard for finance amounts."""

    def test_plausible_small_amount_passes(self):
        from lifeos.health.ingestion import _validate_amount
        # $150 pesos — totally plausible
        result = _validate_amount("gasté 150 pesos en el super", 150.0)
        assert result == 150.0

    def test_plausible_large_amount_passes(self):
        from lifeos.health.ingestion import _validate_amount
        # $8500 — plausible (rent, electronics, etc.)
        result = _validate_amount("pagué 8500 pesos de renta", 8500.0)
        assert result == 8500.0

    def test_zero_amount_is_implausible(self):
        from lifeos.health.ingestion import _validate_amount
        result = _validate_amount("gasté algo", 0.0)
        assert result is None

    def test_negative_amount_is_implausible(self):
        from lifeos.health.ingestion import _validate_amount
        result = _validate_amount("gasté algo", -50.0)
        assert result is None

    def test_absurdly_large_amount_is_implausible(self):
        from lifeos.health.ingestion import _validate_amount
        # > 1e9 — almost certainly a parse error
        result = _validate_amount("gasté algo", 2_000_000_000.0)
        assert result is None

    def test_none_amount_returns_none(self):
        from lifeos.health.ingestion import _validate_amount
        result = _validate_amount("gasté algo", None)
        assert result is None

    def test_boundary_just_above_zero(self):
        from lifeos.health.ingestion import _validate_amount
        # 0.01 — centavo, plausible for a transaction
        result = _validate_amount("gasté 0.01", 0.01)
        assert result == pytest.approx(0.01)

    def test_boundary_at_upper_limit(self):
        from lifeos.health.ingestion import _validate_amount
        # 999_999_999 — just under the billion cutoff, still plausible
        result = _validate_amount("gasté un chingo", 999_999_999.0)
        assert result == pytest.approx(999_999_999.0)
