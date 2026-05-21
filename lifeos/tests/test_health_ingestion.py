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


# ─── Extended patterns (from real-user feedback 2026-05-21) ──────────


def test_bp_with_pulse_explicit_keyword() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("presión 120/80 pulso 72")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["systolic"] == 120
    assert h.data["diastolic"] == 80


def test_bp_bare_numbers_with_pulse_comma() -> None:
    """User reports: '116, 84 y pulso 72' (no 'presión' keyword)."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("116, 84 y pulso 72.")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["systolic"] == 116
    assert h.data["diastolic"] == 84
    assert h.data["pulse_bpm"] == 72


def test_bp_bare_numbers_with_pulse_slash() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("116/84 pulso 72")
    assert h is not None
    assert h.data["pulse_bpm"] == 72


def test_bp_bare_rejects_implausible_values() -> None:
    """Sanity bounds — don't capture random comma-separated numbers."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("12, 14 y pulso 200")  # below physiological range
    # Either None or NOT blood_pressure.
    assert h is None or h.data.get("type") != "blood_pressure"


def test_body_composition_full_inbody_string() -> None:
    """Real user input from Inbody scale: 6 fields in one message."""
    from lifeos.health.ingestion import parse_health
    h = parse_health(
        "Musculo 34.5%, RM 1435, weight 64, FAC 18.7%, visceral FAC 8. BMI 25"
    )
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "body_composition"
    assert h.data["muscle_pct"] == 34.5
    assert h.data["basal_metabolic_rate"] == 1435.0
    assert h.data["weight_kg"] == 64.0
    assert h.data["body_fat_pct"] == 18.7
    assert h.data["visceral_fat"] == 8.0
    assert h.data["bmi"] == 25.0


def test_body_composition_fac_alias_for_fat() -> None:
    """User writes FAC instead of FAT — both should map to body_fat_pct."""
    from lifeos.health.ingestion import parse_health
    h_fac = parse_health("Es FAC 18.7.")
    h_fat = parse_health("Es FAT 18.7.")
    assert h_fac is not None and h_fac.data["type"] == "body_fat_pct"
    assert h_fat is not None and h_fat.data["type"] == "body_fat_pct"
    assert h_fac.data["value"] == h_fat.data["value"] == 18.7


def test_body_composition_two_fields_triggers_multi() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("grasa 19%, musculo 33")
    assert h is not None
    assert h.data["type"] == "body_composition"
    assert h.data["body_fat_pct"] == 19.0
    assert h.data["muscle_pct"] == 33.0


def test_body_composition_single_field_falls_through() -> None:
    """Single body-comp field → _try_vital single-field parsers, not multi."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("IMC 24")
    assert h is not None
    assert h.data["type"] == "bmi"


def test_natural_sleep_una_de_madrugada() -> None:
    """User reports: 'Me dormí a la una de la madrugada y acabo de despertar
    ahorita.' — Spanish hour word + 'ahorita' = now."""
    from lifeos.health.ingestion import parse_health
    h = parse_health(
        "Me dormí a la una de la madrugada y acabo de despertar ahorita."
    )
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "sleep_hours"
    assert h.data["start_hour_24"] == 1
    # Hours depend on "now" — should be positive and plausible (0.5..16)
    assert 0.5 <= h.data["value"] <= 16


def test_natural_sleep_explicit_end() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("Me dormí a las 11 de la noche y desperté a las 7 de la mañana.")
    assert h is not None
    assert h.data["value"] == 8.0
    assert h.data["start_hour_24"] == 23
    assert h.data["end_hour_24"] == 7


def test_weight_unaccented() -> None:
    """'me pese 70' (sin tilde) should also match — Héctor scribe así."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("me pese 70")
    assert h is not None
    assert h.data["type"] == "weight"
    assert h.data["value"] == 70.0


def test_single_rm_metabolic_rate() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("RM 1500")
    assert h is not None
    assert h.data["type"] == "basal_metabolic_rate"
    assert h.data["value"] == 1500
