"""Tests for lifeos.health.ingestion regex parsers."""

from __future__ import annotations

import pytest


def test_returns_none_for_unrelated_text() -> None:
    from lifeos.health.ingestion import parse_health
    assert parse_health("hola axi") is None
    assert parse_health("explícame qué es un MoE") is None
    assert parse_health("") is None
    assert parse_health(None) is None  # type: ignore[arg-type]


# Symptoms

def test_symptom_dolor_de_garganta() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("me duele la garganta")
    assert h is not None
    assert h.kind == "symptom"
    assert "garganta" in h.data["location"].lower()


def test_symptom_tengo_dolor_de() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("Tengo dolor de cabeza desde la mañana")
    assert h is not None
    assert h.kind == "symptom"
    assert "cabeza" in h.data["location"].lower()


# Vitals

def test_vital_glucose() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("glucosa de 92 mg/dL en ayunas")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "glucose"
    assert h.data["value"] == 92


def test_vital_blood_pressure() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("Presión arterial 118/76 esta mañana")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 118
    assert h.data["diastolic"] == 76


def test_vital_weight() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("me pesé 72.4 kg hoy")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "weight"
    assert h.data["value"] == 72.4


def test_vital_sleep_hours() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("dormí 6.5 horas, me siento cansado")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 6.5


# Medications

def test_medication_tome_pastilla() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("tomé amoxicilina hace una hora")
    assert h is not None
    assert h.kind == "medication"
    assert "amoxicilina" in h.data["name"].lower()


def test_medication_false_positive_water() -> None:
    """'tomé agua' should NOT register as a medication."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("tomé agua")
    assert h is None or h.kind != "medication"


def test_medication_false_positive_coffee() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("tomé café hace 10 minutos")
    assert h is None or h.kind != "medication"


def test_priority_vitals_over_other_intents() -> None:
    """When the same text could match both a vital and a symptom, vital wins
    (it's structurally less ambiguous)."""
    from lifeos.health.ingestion import parse_health
    # This text mentions glucose (vital) AND a symptom keyword
    h = parse_health("Tengo dolor de cabeza y la glucosa salió 95")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "glucose"
