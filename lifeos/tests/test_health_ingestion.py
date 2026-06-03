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


# ── Héctor's real morning formats (regressed to nano before; see
#    bugs/health-bp-regex-format-gaps). The pulse can be plural "pulsos"
#    and the pulse number can come BEFORE the word ("58 pulsos"). ────────


def test_bp_plural_pulsos_keyword_before_number_slash() -> None:
    """'132/83, pulsos 58' — slash BP + plural 'pulsos' before the number."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("132/83, pulsos 58")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 132
    assert h.data["diastolic"] == 83
    assert h.data["pulse_bpm"] == 58


def test_bp_three_bare_numbers_trailing_pulsos() -> None:
    """'132, 83, 58 pulsos' — sys, dia, pulse then the trailing word."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("132, 83, 58 pulsos")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 132
    assert h.data["diastolic"] == 83
    assert h.data["pulse_bpm"] == 58


def test_bp_three_bare_numbers_trailing_pulsos_slash() -> None:
    """'117/83/57 pulsos' and '118, 83, 52 pulsos.' variants seen in history."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("118, 83, 52 pulsos.")
    assert h is not None
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 118
    assert h.data["diastolic"] == 83
    assert h.data["pulse_bpm"] == 52


def test_bp_plural_pulsos_still_rejects_implausible() -> None:
    """The new plural/trailing forms keep the physiological sanity bounds."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("12, 14, 18 pulsos")  # all below range
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
    from freezegun import freeze_time
    from lifeos.health.ingestion import parse_health

    # The 'ahorita' branch resolves the wake time from datetime.now(). Without
    # pinning the clock the asserted duration drifts with wall-time and the
    # 16h sanity bound trips after ~17:00 CDMX, making the test flaky. Freeze
    # to 14:00 UTC = 08:00 CDMX so "slept at 1:00, awoke now" is a clean 7h.
    with freeze_time("2026-05-25 14:00:00"):
        h = parse_health(
            "Me dormí a la una de la madrugada y acabo de despertar ahorita."
        )
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "sleep_hours"
    assert h.data["start_hour_24"] == 1
    # Hours depend on the frozen "now" — 1:00 → 8:00 CDMX = 7.0h.
    assert h.data["value"] == 7.0


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


def test_natural_sleep_y_media() -> None:
    """'8 y media' = 8:30. Should compute 5.5h not 5.0h."""
    from lifeos.health.ingestion import parse_health
    h = parse_health(
        "Me dormí a las 3 de la mañana y desperté a las 8 y media de la mañana."
    )
    assert h is not None
    assert h.data["value"] == 5.5
    assert h.data["end_hour_24"] == 8
    assert h.data["end_minute"] == 30


def test_natural_sleep_y_cuarto() -> None:
    """'11 y cuarto' = 11:15."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("Me dormí a las 11 y cuarto de la noche y desperté a las 7")
    assert h is not None
    assert h.data["start_minute"] == 15


def test_body_composition_plausibility_rejects_extreme() -> None:
    """A field value outside physiological range is DROPPED (whole entry
    not rejected — other plausible fields are kept)."""
    from lifeos.health.ingestion import parse_health
    # weight 500 kg is implausible; muscle 30% is fine. The weight should
    # drop, muscle kept. Since it's now only 1 field, _try_body_composition
    # falls through and _try_vital's single-muscle parser catches it.
    h = parse_health("musculo 30%, weight 500")
    assert h is not None
    # Either it's a body_composition WITHOUT weight, or fell to single muscle.
    if h.data.get("type") == "body_composition":
        assert "weight_kg" not in h.data
    else:
        assert h.data.get("type") == "muscle_pct"
