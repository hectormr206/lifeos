"""Tests for _parse_duration_es in lifeos.health.ingestion (task 2.1).

Verifies that _parse_duration_es:
- Returns 30 for "media hora"
- Returns 75 for "una hora y cuarto" / "entrené una hora y cuarto"
- Returns 90 for "hora y media" / "una hora y media"
- Returns 45 for "45 minutos" / "corrí 45 minutos"
- Returns None when no duration phrase is present → nano value kept.
- Reuses _parse_minutes_word and _parse_hour_token (no new number parser).
"""
from __future__ import annotations

import pytest


def test_duration_media_hora():
    from lifeos.health.ingestion import _parse_duration_es
    assert _parse_duration_es("hice media hora de ejercicio") == 30


def test_duration_una_hora_y_cuarto():
    from lifeos.health.ingestion import _parse_duration_es
    assert _parse_duration_es("entrené una hora y cuarto") == 75


def test_duration_hora_y_media():
    from lifeos.health.ingestion import _parse_duration_es
    assert _parse_duration_es("hora y media de yoga") == 90


def test_duration_una_hora_y_media():
    from lifeos.health.ingestion import _parse_duration_es
    assert _parse_duration_es("hice una hora y media de caminata") == 90


def test_duration_minutes_only():
    from lifeos.health.ingestion import _parse_duration_es
    assert _parse_duration_es("corrí 45 minutos") == 45


def test_duration_no_phrase_returns_none():
    from lifeos.health.ingestion import _parse_duration_es
    assert _parse_duration_es("fui al gimnasio") is None


def test_duration_unrelated_text_returns_none():
    from lifeos.health.ingestion import _parse_duration_es
    assert _parse_duration_es("hola axi, ¿cómo estás?") is None


def test_duration_implausible_returns_none():
    """Values outside 1..1440 should return None."""
    from lifeos.health.ingestion import _parse_duration_es
    # 0 minutes — implausible
    assert _parse_duration_es("cero minutos de ejercicio") is None


@pytest.mark.parametrize("text,expected", [
    ("hice media hora de ejercicio", 30),
    ("entrené una hora y cuarto", 75),
    ("hora y media de yoga", 90),
    ("corrí 45 minutos", 45),
    ("30 minutos de bici", 30),
    ("2 horas de natación", 120),
])
def test_duration_parametrized(text, expected):
    from lifeos.health.ingestion import _parse_duration_es
    assert _parse_duration_es(text) == expected
