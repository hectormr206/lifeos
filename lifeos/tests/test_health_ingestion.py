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


# ── New failing patterns from real chat history (2026-06-06) ─────────────────
# "122/81 53 pulsos" — slash BP, then a plain space before the pulse number
# (no comma between diastolic and pulse value).

def test_bp_slash_space_pulsos() -> None:
    """'122/81 53 pulsos' — N/N <space> N pulsos (no comma before pulse)."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("122/81 53 pulsos")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 122
    assert h.data["diastolic"] == 81
    assert h.data["pulse_bpm"] == 53


def test_bp_slash_space_pulsos_rejects_implausible() -> None:
    """Plain-space variant still applies the physiological plausibility gate."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("30/20 200 pulsos")  # all out of range
    assert h is None or h.data.get("type") != "blood_pressure"


# "113, 82 y 55 de pulso." — "N de pulso/pulsos/pulsaciones" shape.

def test_bp_de_pulso_y_shape() -> None:
    """'113, 82 y 55 de pulso.' — sys, dia, then pulse with 'de pulso' suffix."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("113, 82 y 55 de pulso.")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 113
    assert h.data["diastolic"] == 82
    assert h.data["pulse_bpm"] == 55


def test_bp_de_pulsos_plural() -> None:
    """'120, 80 y 60 de pulsos.' — plural form 'de pulsos'."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("120, 80 y 60 de pulsos.")
    assert h is not None
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 120
    assert h.data["diastolic"] == 80
    assert h.data["pulse_bpm"] == 60


def test_bp_de_pulsaciones() -> None:
    """'120, 80 y 60 de pulsaciones.' — 'de pulsaciones' variant."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("120, 80 y 60 de pulsaciones.")
    assert h is not None
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 120
    assert h.data["diastolic"] == 80
    assert h.data["pulse_bpm"] == 60


def test_three_bare_numbers_no_keyword_rejected() -> None:
    """Three bare numbers with NO pulse keyword must NOT parse (too ambiguous)."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("113, 82, 55")
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


# ── Task 1: extended sleep natural-language coverage ───────────────────────


def test_sleep_hours_y_media_half_hour() -> None:
    """'dormí 6 horas y media' must parse as 6.5, not 6.0."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("anoche dormí 6 horas y media")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 6.5


def test_sleep_onset_me_dormi_wake_acabo_de_despertar() -> None:
    """'Me dormí a las 11 pm y acabo de despertar' — wake = now.
    Freeze at UTC 15:00 = 09:00 CDMX (UTC-6), so 23:00→09:00 = 10h.
    """
    from freezegun import freeze_time
    from lifeos.health.ingestion import parse_health
    with freeze_time("2026-06-07 15:00:00"):  # 15:00 UTC = 09:00 CDMX
        h = parse_health("Me dormí a las 11 pm y acabo de despertar")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "sleep_hours"
    # 23:00 → 09:00 CDMX = 10h
    assert h.data["value"] == 10.0


def test_sleep_onset_lowercase_no_accent_wake_now() -> None:
    """'me dormí a las 11 y acabo de despertar' (no pm, bare hour).
    Freeze at UTC 13:00 = 07:00 CDMX, so 23:00→07:00 = 8h.
    """
    from freezegun import freeze_time
    from lifeos.health.ingestion import parse_health
    with freeze_time("2026-06-07 13:00:00"):  # 13:00 UTC = 07:00 CDMX
        h = parse_health("me dormí a las 11 y acabo de despertar")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    # 23:00 → 07:00 CDMX = 8h
    assert h.data["value"] == 8.0


def test_sleep_onset_me_dormi_levantarme() -> None:
    """'Me dormí a las 11 pm y acabo de levantarme' — 'levantarme' as wake.
    Freeze at UTC 13:30 = 07:30 CDMX, so 23:00→07:30 = 8.5h.
    """
    from freezegun import freeze_time
    from lifeos.health.ingestion import parse_health
    with freeze_time("2026-06-07 13:30:00"):  # 13:30 UTC = 07:30 CDMX
        h = parse_health("Me dormí a las 11 pm y acabo de levantarme")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 8.5


def test_sleep_me_acosté_wake_me_levanté() -> None:
    """'me acosté a las 11 y me levanté a las 7'."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("me acosté a las 11 y me levanté a las 7")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 8.0


def test_sleep_dormi_de_x_a_y() -> None:
    """'dormí de 11 a 7' — de X a Y pattern."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("dormí de 11 a 7")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 8.0


def test_sleep_me_fui_a_dormir_desperte() -> None:
    """'me fui a dormir a las 11 y desperté a las 7'."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("me fui a dormir a las 11 y desperté a las 7")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 8.0


def test_sleep_plausibility_gate_too_long() -> None:
    """Duration > 16h must be rejected (implausible).
    'dormí de las 10 de la noche a las 3 de la mañana' = only 5h — this tests
    plausibility passes for normal duration.
    For > 16h: 'me acosté a la 1 de la tarde y me levanté a las 6 am' = 17h.
    """
    from lifeos.health.ingestion import parse_health
    # 13:00 → 06:00 next day = 17h — should fail the 0.5-16h gate
    h = parse_health("me acosté a la 1 de la tarde y me levanté a las 6 de la mañana")
    # Either None or not a vital sleep_hours
    assert h is None or h.data.get("type") != "sleep_hours"


# ── Issue 1: UTC hour used for sleep wake-time ───────────────────────────────


def test_sleep_wake_now_uses_local_time_not_utc() -> None:
    """When now= is a UTC-aware datetime, _try_natural_sleep must convert to
    Mexico_City before extracting hour/minute for the wake time.

    14:30 UTC == 08:30 CDMX (UTC-6 in winter).
    Slept at 11 pm → 23:00. Woke at 08:30 CDMX → delta = 9.5h.
    """
    from datetime import datetime
    from zoneinfo import ZoneInfo

    from lifeos.health.ingestion import parse_health

    now_utc = datetime(2026, 1, 1, 14, 30, tzinfo=ZoneInfo("UTC"))
    h = parse_health(
        "me dormí a las 11 y acabo de despertar",
        now=now_utc,
    )
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "sleep_hours"
    assert h.data["end_hour_24"] == 8
    assert h.data["end_minute"] == 30
    assert abs(h.data["value"] - 9.5) < 0.1


# ── Issue 2: "12 de la mañana" → noon not midnight ───────────────────────────


def test_sleep_twelve_manana_is_noon_from_to() -> None:
    """'dormí de 2 a 12 de la mañana' — 12 mañana must be noon (12:00), not 0."""
    from lifeos.health.ingestion import parse_health

    h = parse_health("dormí de 2 de la mañana a 12 de la mañana")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["end_hour_24"] == 12  # noon, NOT midnight (0)


def test_sleep_twelve_manana_is_noon_from_to_pattern() -> None:
    """'dormí de las 2 a las 12 de la mañana' via _SLEEP_FROM_TO_RE path."""
    from lifeos.health.ingestion import parse_health

    h = parse_health("me dormí a las 2 de la mañana y me levanté a las 12 de la mañana")
    assert h is not None
    assert h.data["end_hour_24"] == 12  # noon, NOT 0


# ── Issue 3: hours 4/5/6 "de la noche" must be PM ────────────────────────────


def test_sleep_six_noche_is_18() -> None:
    """'me dormí a las 6 de la noche' — 6 PM = 18:00, not 6 AM.
    Wake at 2 de la madrugada (2:00) = 8h sleep from 18:00.
    """
    from lifeos.health.ingestion import parse_health

    h = parse_health("me dormí a las 6 de la noche y me levanté a las 2 de la madrugada")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["start_hour_24"] == 18  # was returning 6 (bug)
    assert h.data["value"] == 8.0


def test_sleep_four_noche_is_16() -> None:
    """'dormí de 4 de la noche a 12 de la noche' — 4 PM = 16:00, midnight = 0."""
    from lifeos.health.ingestion import parse_health

    h = parse_health("dormí de 4 de la noche a 12 de la noche")
    assert h is not None
    assert h.data["start_hour_24"] == 16
    assert h.data["end_hour_24"] == 0  # midnight
    assert h.data["value"] == 8.0


def test_sleep_three_noche_stays_am() -> None:
    """Hours <= 3 with 'de la noche' are kept as AM (madrugada convention)."""
    from lifeos.health.ingestion import parse_health

    # 3 de la noche = 3:00 AM (03:00), 7 de la mañana wake = 7h sleep
    h = parse_health("me dormí a las 3 de la noche y me levanté a las 7")
    assert h is not None
    assert h.data["start_hour_24"] == 3  # madrugada-style AM


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


# ── Golden tests: sleep-duration miscalculation bug (obs #575, 2026-06-18) ───
# Original bug: "Me dormí a las 11:50 pm y me desperté hoy a las 5:50 am"
# → Axi logged "dormí 8.0h". Correct is 6.0h (23:50→05:50 with midnight wrap).
# Root cause: nano disobeyed its null rule and computed wrong math; the
# deterministic regex now matches all these shapes and computes in Python.


def test_sleep_original_bug_11_50pm_to_5_50am() -> None:
    """THE original bug: 23:50→05:50 with midnight wrap = 6.0h, not 8.0h."""
    from lifeos.health.ingestion import parse_health

    h = parse_health("Me dormí a las 11:50 pm y me desperté hoy a las 5:50 am")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 6.0
    assert h.data["start_hour_24"] == 23
    assert h.data["start_minute"] == 50
    assert h.data["end_hour_24"] == 5
    assert h.data["end_minute"] == 50


def test_sleep_23_to_7_midnight_wrap() -> None:
    """'me dormí a las 23 y desperté a las 7' — 24h notation, 8.0h."""
    from lifeos.health.ingestion import parse_health

    h = parse_health("me dormí a las 23 y desperté a las 7")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 8.0
    assert h.data["start_hour_24"] == 23
    assert h.data["end_hour_24"] == 7


def test_sleep_22_30_to_6_15_with_minutes() -> None:
    """'me acosté a las 22:30 y me levanté a las 6:15' = 7h45m = 7.75h."""
    from lifeos.health.ingestion import parse_health

    h = parse_health("me acosté a las 22:30 y me levanté a las 6:15")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 7.75
    assert h.data["start_hour_24"] == 22
    assert h.data["start_minute"] == 30
    assert h.data["end_hour_24"] == 6
    assert h.data["end_minute"] == 15


def test_sleep_1am_to_9am_inline_ampm() -> None:
    """'dormí de 1am a 9am' — inline am/pm (no space), 8.0h."""
    from lifeos.health.ingestion import parse_health

    h = parse_health("dormí de 1am a 9am")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 8.0


def test_sleep_explicit_hours_8_unchanged() -> None:
    """'dormí 8 horas' → 8.0h — explicit hours path must be unaffected."""
    from lifeos.health.ingestion import parse_health

    h = parse_health("dormí 8 horas")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 8.0


def test_sleep_explicit_hours_plausibility_rejects_too_short() -> None:
    """'dormí 0.2 horas' — below 0.5h plausibility floor, must return None."""
    from lifeos.health.ingestion import parse_health

    h = parse_health("dormí 0.2 horas")
    assert h is None or h.data.get("type") != "sleep_hours"


def test_sleep_same_day_no_wrap() -> None:
    """'dormí de las 8 a las 10' — same morning, no midnight wrap, 2.0h."""
    from lifeos.health.ingestion import parse_health

    h = parse_health("dormí de las 8 de la mañana a las 10 de la mañana")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 2.0


# ── English support (Wave 2) ─────────────────────────────────────────────────
# Inline EN alternations in the existing regexes; digits only for EN v1
# (the ES word→digit normalizer stays ES-only). Same plausibility gates as ES.


# Glucose

def test_glucose_en_bare() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("glucose 110")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "glucose"
    assert h.data["value"] == 110


def test_glucose_en_blood_sugar() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("blood sugar 95 this morning")
    assert h is not None
    assert h.data["type"] == "glucose"
    assert h.data["value"] == 95


def test_glucose_en_negative_no_number() -> None:
    from lifeos.health.ingestion import parse_health
    assert parse_health("my glucose meter is broken") is None


def test_glucose_en_negative_plain_sugar() -> None:
    """Bare 'sugar' (without 'blood') is NOT a glucose keyword."""
    from lifeos.health.ingestion import parse_health
    assert parse_health("sugar is bad for you, avoid 100 grams") is None


# Blood pressure

def test_bp_en_over_with_pulse() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("blood pressure 120 over 80, pulse 72")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 120
    assert h.data["diastolic"] == 80
    assert h.data["pulse_bpm"] == 72


def test_bp_en_bp_keyword_slash() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("bp 118/76")
    assert h is not None
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 118
    assert h.data["diastolic"] == 76


def test_bp_en_bare_with_a_pulse_of() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("120/80 with a pulse of 65")
    assert h is not None
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 120
    assert h.data["diastolic"] == 80
    assert h.data["pulse_bpm"] == 65


def test_bp_en_bare_rejects_implausible() -> None:
    """Same physiological gates as ES on the bare EN forms."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("20 over 10 with a pulse of 300")
    assert h is None or h.data.get("type") != "blood_pressure"


def test_bp_en_negative_plain_sentence() -> None:
    """'over' between numbers without any BP/pulse keyword must not parse."""
    from lifeos.health.ingestion import parse_health
    assert parse_health("I read 120 pages over 80 minutes") is None


# Sleep hours (explicit)

def test_sleep_hours_en() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("slept 7 hours")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 7.0


def test_sleep_hours_en_and_a_half() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("slept 7 and a half hours")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 7.5


def test_sleep_hours_en_i_slept_decimal() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("I slept 6.5 hours, feeling tired")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 6.5


def test_sleep_en_negative_like_a_baby() -> None:
    from lifeos.health.ingestion import parse_health
    assert parse_health("slept like a baby") is None


def test_sleep_en_negative_slept_over() -> None:
    from lifeos.health.ingestion import parse_health
    assert parse_health("we slept over at a friend's place") is None


# Natural sleep clock

def test_natural_sleep_en_went_to_bed_woke_up() -> None:
    """'went to bed at 11 and woke up at 6' — onset heuristic 11 → 23h."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("went to bed at 11 and woke up at 6")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "sleep_hours"
    assert h.data["start_hour_24"] == 23
    assert h.data["end_hour_24"] == 6
    assert h.data["value"] == 7.0


def test_natural_sleep_en_fell_asleep_ampm_minutes() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("fell asleep at 11 pm and got up at 6:30 am")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 7.5
    assert h.data["end_minute"] == 30


def test_natural_sleep_en_periods_night_morning() -> None:
    """EN periods 'at night' / 'in the morning' map onto the ES period logic."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("went to bed at 11 at night and woke up at 7 in the morning")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["start_hour_24"] == 23
    assert h.data["end_hour_24"] == 7
    assert h.data["value"] == 8.0


def test_natural_sleep_en_slept_from_to() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("slept from 1am to 9am")
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 8.0


def test_natural_sleep_en_negative_no_hours() -> None:
    from lifeos.health.ingestion import parse_health
    assert parse_health("went to bed early and woke up tired") is None


def test_natural_sleep_en_negative_plain_chat() -> None:
    from lifeos.health.ingestion import parse_health
    assert parse_health("I need to go to bed earlier these days") is None


# Medication

def test_medication_en_ibuprofen() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("I took ibuprofen")
    assert h is not None
    assert h.kind == "medication"
    assert "ibuprofen" in h.data["name"].lower()


def test_medication_en_dose_mg() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("took 500mg of paracetamol")
    assert h is not None
    assert h.kind == "medication"
    assert "paracetamol" in h.data["name"].lower()


def test_medication_en_negative_shower() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("took a shower")
    assert h is None or h.kind != "medication"


def test_medication_en_negative_break() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("I took a break")
    assert h is None or h.kind != "medication"


def test_medication_en_negative_nap() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("took a nap this afternoon")
    assert h is None or h.kind != "medication"


def test_medication_en_negative_bus() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("took the bus to work")
    assert h is None or h.kind != "medication"


# Weight sentence forms

def test_weight_en_i_weigh() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("I weigh 64")
    assert h is not None
    assert h.data["type"] == "weight"
    assert h.data["value"] == 64.0


def test_weight_en_my_weight_is() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("my weight is 64.5")
    assert h is not None
    assert h.data["type"] == "weight"
    assert h.data["value"] == 64.5


def test_weight_en_negative_no_number() -> None:
    from lifeos.health.ingestion import parse_health
    assert parse_health("I weigh my options carefully") is None


def test_weight_en_negative_implausible() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("weight 500")
    assert h is None or h.data.get("type") != "weight"


def test_vital_weight_en_pounds() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("I weigh 150 pounds")
    assert h is not None
    assert h.data["type"] == "weight"
    assert h.data["unit"] == "kg"
    # 150 lb * 0.45359237 = 68.0388555 kg → stored kg-canonical.
    assert h.data["value"] == 68.0


def test_vital_weight_en_lbs() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("weight 150 lbs")
    assert h is not None
    assert h.data["type"] == "weight"
    assert h.data["unit"] == "kg"
    assert h.data["value"] == 68.0


def test_vital_weight_kg_unchanged() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("peso 70.5 kg")
    assert h is not None
    assert h.data["type"] == "weight"
    assert h.data["unit"] == "kg"
    assert h.data["value"] == 70.5


# Bare scale sequence

def test_bare_scale_full_six_number_reading() -> None:
    """Canonical scale dictation: weight fat visceral muscle bmr bmi."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("59.9 13.2 7 34.6 1326 23.4")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "body_composition"
    assert h.data["entry_mode"] == "bare_sequence"
    assert h.data["weight_kg"] == 59.9
    assert h.data["body_fat_pct"] == 13.2
    assert h.data["visceral_fat"] == 7
    assert h.data["muscle_pct"] == 34.6
    assert h.data["basal_metabolic_rate"] == 1326
    assert h.data["bmi"] == 23.4
    assert "báscula" in h.title


def test_bare_scale_rotated_start_at_visceral() -> None:
    """Dictation starting mid-cycle: visceral muscle bmr bmi (4 numbers)."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("7 34.6 1326 23.4")
    assert h is not None
    assert h.data["type"] == "body_composition"
    assert h.data["entry_mode"] == "bare_sequence"
    assert h.data["visceral_fat"] == 7
    assert h.data["muscle_pct"] == 34.6
    assert h.data["basal_metabolic_rate"] == 1326
    assert h.data["bmi"] == 23.4
    assert "weight_kg" not in h.data
    assert "body_fat_pct" not in h.data


def test_bare_scale_decimal_comma_and_units() -> None:
    """Decimal commas + sprinkled unit words parse like the plain form."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("59,9 kg 13,2 % 7 34,6 1326 kcal 23,4")
    assert h is not None
    assert h.data["type"] == "body_composition"
    assert h.data["weight_kg"] == 59.9
    assert h.data["body_fat_pct"] == 13.2
    assert h.data["visceral_fat"] == 7
    assert h.data["muscle_pct"] == 34.6
    assert h.data["basal_metabolic_rate"] == 1326
    assert h.data["bmi"] == 23.4


def test_bare_scale_ambiguous_rotations_rejected() -> None:
    """4 numbers fitting ≥2 rotations must return None (never guess).

    "45 50 20 25" fits offset 0 (weight 45, fat 50, visceral 20, muscle 25)
    AND offset 5 (bmi 45, weight 50, fat 20, visceral 25) — ambiguous."""
    from lifeos.health.ingestion import _try_bare_scale_sequence, parse_health
    assert _try_bare_scale_sequence("45 50 20 25") is None
    h = parse_health("45 50 20 25")
    assert h is None or h.data.get("type") != "body_composition"


def test_bare_scale_does_not_shadow_blood_pressure() -> None:
    """2-3 bare numbers stay owned by the BP path; this parser never fires."""
    from lifeos.health.ingestion import _try_bare_scale_sequence, parse_health
    assert _try_bare_scale_sequence("109 80 52") is None
    assert _try_bare_scale_sequence("120 80") is None
    # Whole-pipeline behavior for 2-3 bare numbers is unchanged: they are
    # never claimed as body composition (bare BP without a pulse keyword is
    # rejected as too ambiguous — see test_three_bare_numbers_no_keyword_rejected).
    for text in ("109 80 52", "120 80"):
        h = parse_health(text)
        assert h is None or h.data.get("type") == "blood_pressure"
    # A keyworded bare BP form still parses as blood pressure.
    h = parse_health("116/84 pulso 72")
    assert h is not None
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 116
    assert h.data["pulse_bpm"] == 72


def test_bare_scale_text_with_words_flows_to_labeled_path() -> None:
    """Letters in the message reject this parser; labeled path takes over."""
    from lifeos.health.ingestion import _try_bare_scale_sequence, parse_health
    text = "peso 59.9 fat 13.2"
    assert _try_bare_scale_sequence(text) is None
    h = parse_health(text)
    assert h is not None
    assert h.data["type"] == "body_composition"
    assert h.data.get("entry_mode") != "bare_sequence"
    assert h.data["weight_kg"] == 59.9
    assert h.data["body_fat_pct"] == 13.2


def test_bare_scale_more_than_seven_numbers_rejected() -> None:
    from lifeos.health.ingestion import _try_bare_scale_sequence
    assert _try_bare_scale_sequence("59.9 13.2 7 34.6 1326 23.4 60 14") is None


def test_bare_scale_config_reorder_honored(monkeypatch: pytest.MonkeyPatch) -> None:
    """A monkeypatched scale_sequence reorder drives slot assignment."""
    import axi.config as axi_config
    from lifeos.health.ingestion import parse_health
    monkeypatch.setattr(
        axi_config, "get",
        lambda key, default=None: (
            "bmi,bmr,muscle,visceral,fat,weight"
            if key == "scale_sequence" else default
        ),
    )
    h = parse_health("23.4 1326 34.6 7 13.2 59.9")
    assert h is not None
    assert h.data["entry_mode"] == "bare_sequence"
    assert h.data["bmi"] == 23.4
    assert h.data["basal_metabolic_rate"] == 1326
    assert h.data["muscle_pct"] == 34.6
    assert h.data["visceral_fat"] == 7
    assert h.data["body_fat_pct"] == 13.2
    assert h.data["weight_kg"] == 59.9


def test_bare_scale_invalid_config_falls_back_to_default(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Unknown field names in scale_sequence → canonical default order."""
    import axi.config as axi_config
    from lifeos.health.ingestion import parse_health
    monkeypatch.setattr(
        axi_config, "get",
        lambda key, default=None: (
            "weight,banana,bmi" if key == "scale_sequence" else default
        ),
    )
    h = parse_health("59.9 13.2 7 34.6 1326 23.4")
    assert h is not None
    assert h.data["entry_mode"] == "bare_sequence"
    assert h.data["weight_kg"] == 59.9
    assert h.data["basal_metabolic_rate"] == 1326


# Labeled visceral typo forms ("viseralfat 7" — missing c, glued to fat)

def test_visceral_typo_viseralfat_single_field() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("viseralfat 7")
    assert h is not None
    assert h.data["type"] == "visceral_fat"
    assert h.data["value"] == 7


def test_visceral_typo_glued_in_multi_field_message() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("peso 60, visceralfat 8")
    assert h is not None
    assert h.data["type"] == "body_composition"
    assert h.data["visceral_fat"] == 8
    assert h.data["weight_kg"] == 60


# ─── EN symptoms (English parity with the ES pain-location parser) ─────
# The ES side extracts only pain-location (data["location"], title
# "dolor de {location}"). The EN pain patterns mirror that exact shape; the
# named non-pain symptoms (fever, cough, ...) are an English-only extension
# using data["symptom"] since ES has no non-pain symptom category.

def test_symptom_en_headache() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("I have a headache")
    assert h is not None
    assert h.kind == "symptom"
    assert h.data["location"] == "head"
    assert h.title == "dolor de head"


def test_symptom_en_my_stomach_hurts() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("my stomach hurts")
    assert h is not None
    assert h.kind == "symptom"
    assert "stomach" in h.data["location"].lower()


def test_symptom_en_my_back_hurts() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("my lower back is hurting since this morning")
    assert h is not None
    assert h.kind == "symptom"
    assert "back" in h.data["location"].lower()


def test_symptom_en_pain_in_my() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("I have pain in my knee")
    assert h is not None
    assert h.kind == "symptom"
    assert "knee" in h.data["location"].lower()


def test_symptom_en_toothache() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("got a bad toothache")
    assert h is not None
    assert h.kind == "symptom"
    assert h.data["location"] == "tooth"


def test_symptom_en_named_dizzy() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("I feel dizzy")
    assert h is not None
    assert h.kind == "symptom"
    assert h.data["symptom"] == "dizziness"


def test_symptom_en_named_nauseous() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("I'm nauseous")
    assert h is not None
    assert h.data["symptom"] == "nausea"


def test_symptom_en_named_fever() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("I have a fever")
    assert h is not None
    assert h.data["symptom"] == "fever"


def test_symptom_en_named_sore_throat() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("I have a sore throat")
    assert h is not None
    assert h.data["symptom"] == "sore_throat"


def test_symptom_en_named_diarrhea() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("I have diarrhea")
    assert h is not None
    assert h.data["symptom"] == "diarrhea"


def test_symptom_en_named_cough() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("I have a cough")
    assert h is not None
    assert h.data["symptom"] == "cough"


def test_symptom_en_negative_tired_idiom() -> None:
    """'tired of' is an idiom, not fatigue — must not register a symptom."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("I'm tired of waiting")
    assert h is None or h.kind != "symptom"


# ─── ES named (non-pain) symptoms — mirror of the EN named category ────
# Bare "tengo fiebre" (no number) must register as a fever symptom with the
# SAME canonical data["symptom"] values as the EN side; only the title is
# Spanish-form.

def test_symptom_es_named_fever() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("tengo fiebre")
    assert h is not None
    assert h.kind == "symptom"
    assert h.data["symptom"] == "fever"
    assert h.title == "fiebre"


def test_symptom_es_named_fever_variants() -> None:
    from lifeos.health.ingestion import parse_health
    for text in ("tengo calentura", "ando con fiebre"):
        h = parse_health(text)
        assert h is not None, text
        assert h.data["symptom"] == "fever", text


def test_symptom_es_named_cough() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("tengo tos")
    assert h is not None
    assert h.kind == "symptom"
    assert h.data["symptom"] == "cough"


def test_symptom_es_named_dizziness() -> None:
    from lifeos.health.ingestion import parse_health
    for text in ("estoy mareado", "me siento mareada", "tengo mareo"):
        h = parse_health(text)
        assert h is not None, text
        assert h.data["symptom"] == "dizziness", text


def test_symptom_es_named_nausea() -> None:
    from lifeos.health.ingestion import parse_health
    for text in ("tengo náuseas", "siento náuseas", "tengo ganas de vomitar"):
        h = parse_health(text)
        assert h is not None, text
        assert h.data["symptom"] == "nausea", text


def test_symptom_es_named_diarrhea() -> None:
    from lifeos.health.ingestion import parse_health
    for text in ("tengo diarrea", "ando con diarrea"):
        h = parse_health(text)
        assert h is not None, text
        assert h.data["symptom"] == "diarrhea", text


def test_symptom_es_named_sore_throat() -> None:
    """'tengo dolor de garganta' is the sore-throat NAMED symptom (wins over
    location='garganta' because the ES-named branch runs first)."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("tengo dolor de garganta")
    assert h is not None
    assert h.kind == "symptom"
    assert h.data["symptom"] == "sore_throat"
    assert h.title == "dolor de garganta"


def test_symptom_es_named_sore_throat_irritada() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("tengo la garganta irritada")
    assert h is not None
    assert h.data["symptom"] == "sore_throat"


def test_symptom_es_me_duele_garganta_stays_location() -> None:
    """Overlap guard: 'me duele la garganta' has no having/feeling verb the
    ES-named regex accepts, so it still parses to pain-location (unchanged)."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("me duele la garganta")
    assert h is not None
    assert h.kind == "symptom"
    assert "garganta" in h.data["location"].lower()
    assert "symptom" not in h.data


def test_symptom_es_named_negative_cansado_idiom() -> None:
    """'estoy cansado de ...' / 'harto de ...' are idioms, not symptoms."""
    from lifeos.health.ingestion import parse_health
    assert parse_health("estoy cansado de esto") is None
    assert parse_health("estoy harto de esperar") is None


def test_symptom_es_fever_with_number_stays_temperature() -> None:
    """A number keeps it a TEMPERATURE vital (_try_vital runs before
    _try_symptom); only the bare form becomes the fever symptom."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("fiebre de 38.5")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "temperature"
    assert h.data["value"] == 38.5
    bare = parse_health("tengo fiebre")
    assert bare is not None
    assert bare.kind == "symptom"
    assert bare.data["symptom"] == "fever"


def test_symptom_en_vital_wins_over_symptom() -> None:
    """A vital in the same text still wins (parser priority unchanged)."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("I have a headache and my glucose is 95")
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "glucose"


# ─── Temperature (bilingual, keyword-anchored) ─────────────────────────

def test_vital_temperature_es_keyword_first() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("temperatura 37.5")
    assert h is not None
    assert h.kind == "vital"
    assert h.data == {"type": "temperature", "value": 37.5, "unit": "°C"}
    assert h.title == "temperatura 37.5°C"


def test_vital_temperature_es_number_first() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("tengo 38 de temperatura")
    assert h is not None
    assert h.data["type"] == "temperature"
    assert h.data["value"] == 38.0


def test_vital_temperature_es_fiebre_de() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("fiebre de 38.5")
    assert h is not None
    assert h.data["type"] == "temperature"
    assert h.data["value"] == 38.5


def test_vital_temperature_en() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("my temperature is 37.5")
    assert h is not None
    assert h.data["type"] == "temperature"
    assert h.data["value"] == 37.5
    h2 = parse_health("I have a fever of 38")
    assert h2 is not None
    assert h2.data["type"] == "temperature"
    assert h2.data["value"] == 38.0


def test_vital_temperature_out_of_range_rejected() -> None:
    from lifeos.health.ingestion import parse_health
    # 34.0-43.0 gate: "temperatura 500" must not log a vital.
    h = parse_health("temperatura 500")
    assert h is None or h.data.get("type") != "temperature"


def test_temperature_bare_fever_stays_symptom_es() -> None:
    """'tengo fiebre' (no number) must NOT become a temperature vital."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("tengo fiebre")
    assert h is None or h.data.get("type") != "temperature"


def test_temperature_bare_fever_stays_symptom_en() -> None:
    """'I have a fever' (no number) is a symptom, not a temperature vital."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("I have a fever")
    assert h is not None
    assert h.kind == "symptom"
    assert h.data.get("symptom") == "fever"


# ─── Blood oxygen / SpO2 (bilingual, keyword-anchored) ─────────────────

def test_vital_oxygen_es() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("oxígeno 98")
    assert h is not None
    assert h.kind == "vital"
    assert h.data == {"type": "oxygen", "value": 98, "unit": "%"}
    assert h.title == "oxígeno 98%"


def test_vital_oxygen_es_saturacion() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("saturación de oxígeno 96%")
    assert h is not None
    assert h.data["type"] == "oxygen"
    assert h.data["value"] == 96


def test_vital_oxygen_en_variants() -> None:
    from lifeos.health.ingestion import parse_health
    for text, val in [("SpO2 97", 97), ("blood oxygen 96", 96),
                      ("O2 sat 95", 95), ("oxygen saturation 98%", 98)]:
        h = parse_health(text)
        assert h is not None, text
        assert h.data["type"] == "oxygen"
        assert h.data["value"] == val


def test_vital_oxygen_out_of_range_rejected() -> None:
    from lifeos.health.ingestion import parse_health
    # 70-100 gate: "oxígeno 50" is implausible SpO2, must not log.
    h = parse_health("oxígeno 50")
    assert h is None or h.data.get("type") != "oxygen"


# ─── Standalone heart-rate / pulse (bilingual, keyword-anchored) ───────

def test_vital_heart_rate_es() -> None:
    from lifeos.health.ingestion import parse_health
    h = parse_health("pulso 55")
    assert h is not None
    assert h.kind == "vital"
    assert h.data == {"type": "heart_rate", "value": 55, "unit": "bpm"}
    assert h.title == "pulso 55 bpm"


def test_vital_heart_rate_es_variants() -> None:
    from lifeos.health.ingestion import parse_health
    for text, val in [("mi pulso es 60", 60), ("frecuencia cardiaca 58", 58),
                      ("ritmo cardiaco 62", 62)]:
        h = parse_health(text)
        assert h is not None, text
        assert h.data["type"] == "heart_rate"
        assert h.data["value"] == val


def test_vital_heart_rate_en_variants() -> None:
    from lifeos.health.ingestion import parse_health
    for text, val in [("heart rate 55", 55), ("my heart rate is 60", 60),
                      ("pulse 58", 58), ("HR 62", 62),
                      ("heart rate of 66 bpm", 66)]:
        h = parse_health(text)
        assert h is not None, text
        assert h.data["type"] == "heart_rate"
        assert h.data["value"] == val


def test_vital_heart_rate_out_of_range_rejected() -> None:
    from lifeos.health.ingestion import parse_health
    # 30-220 gate: "pulso 900" is implausible, must not log.
    h = parse_health("pulso 900")
    assert h is None or h.data.get("type") != "heart_rate"


def test_heart_rate_does_not_shadow_blood_pressure() -> None:
    """A sys/dia pair with trailing pulse stays blood_pressure, not heart_rate."""
    from lifeos.health.ingestion import parse_health
    h = parse_health("116 82 55 pulsos")
    assert h is not None
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 116
    assert h.data["diastolic"] == 82
    assert h.data["pulse_bpm"] == 55
