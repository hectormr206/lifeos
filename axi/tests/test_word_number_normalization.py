"""End-to-end tests for the word-number normalization pre-pass.

These tests verify that the normalize_numbers_es → parse_* pipeline works
correctly end-to-end at the parser level (not HTTP POST level, which would
require a running DB and brain). They confirm that voice-dictated Spanish
number words reach the correct domain parsers and produce the right structured
data.

Tests are grouped by domain:
  - Health (the 5 empirical spec cases)
  - Finance (word amounts)
  - Exercise (word minutes)
"""

from __future__ import annotations


# ─── Helper: normalize_then_parse ─────────────────────────────────────────


def _norm(text: str) -> str:
    from lifeos.text.normalize import normalize_numbers_es
    return normalize_numbers_es(text)


# ─── Health: empirical spec cases ─────────────────────────────────────────


def test_health_case1_sleep_word_minutes_start_and_end() -> None:
    """Case 1 (MOST DANGEROUS — silent-wrong-data):
    'Me dormí a las 9 cuarenta y cinco y me desperté a las seis cincuenta y seis'
    Old behavior: start=21:00, end=6:00 (silently drops word minutes).
    Expected:     start=21:45, end=6:56, value≈9.18h (rounds to 9.2).
    """
    from lifeos.health.ingestion import parse_health
    text = "Me dormí a las 9 cuarenta y cinco y me desperté a las seis cincuenta y seis"
    h = parse_health(_norm(text))
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "sleep_hours"
    assert h.data["start_hour_24"] == 21
    assert h.data["start_minute"] == 45, (
        f"Expected start_minute=45, got {h.data['start_minute']} — "
        "silent-wrong-data bug: word minutes must not be silently dropped"
    )
    assert h.data["end_hour_24"] == 6
    assert h.data["end_minute"] == 56, (
        f"Expected end_minute=56, got {h.data['end_minute']}"
    )
    # Duration: 21:45→06:56 = 9h11m ≈ 9.2h (rounded to 1 decimal)
    assert abs(h.data["value"] - 9.2) < 0.15, (
        f"Expected ≈9.2h, got {h.data['value']}"
    )


def test_health_case2_bp_word_numbers_with_keyword() -> None:
    """Case 2: 'presión ciento veintidós ochenta y uno, cincuenta y tres pulsos'
    → BP vital 122/81 pulse 53.
    """
    from lifeos.health.ingestion import parse_health
    text = "presión ciento veintidós ochenta y uno, cincuenta y tres pulsos"
    h = parse_health(_norm(text))
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 122
    assert h.data["diastolic"] == 81
    assert h.data["pulse_bpm"] == 53


def test_health_case3_bp_word_numbers_no_keyword() -> None:
    """Case 3: 'ciento veintidós ochenta y uno y cincuenta y tres de pulso'
    → BP vital 122/81 pulse 53 (no 'presión' keyword, bare numbers).
    """
    from lifeos.health.ingestion import parse_health
    text = "ciento veintidós ochenta y uno y cincuenta y tres de pulso"
    h = parse_health(_norm(text))
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 122
    assert h.data["diastolic"] == 81
    assert h.data["pulse_bpm"] == 53


def test_health_case4_weight_word() -> None:
    """Case 4: 'pesé sesenta y cuatro kilos' → weight vital 64 kg."""
    from lifeos.health.ingestion import parse_health
    text = "pesé sesenta y cuatro kilos"
    h = parse_health(_norm(text))
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "weight"
    assert h.data["value"] == 64.0


def test_health_case5_glucose_word() -> None:
    """Case 5: 'glucosa en noventa y cinco' → glucose vital 95."""
    from lifeos.health.ingestion import parse_health
    text = "glucosa en noventa y cinco"
    h = parse_health(_norm(text))
    assert h is not None
    assert h.kind == "vital"
    assert h.data["type"] == "glucose"
    assert h.data["value"] == 95


# ─── Health: regression — digit forms must not regress ────────────────────


def test_health_digit_sleep_regression() -> None:
    """'Me dormí a las 10 y me desperté a las 8 y media' still works."""
    from lifeos.health.ingestion import parse_health
    h = parse_health(_norm("Me dormí a las 10 y me desperté a las 8 y media"))
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["start_hour_24"] == 22
    assert h.data["end_minute"] == 30


def test_health_digit_sleep_range_regression() -> None:
    """'dormí de 11 a 7' still works."""
    from lifeos.health.ingestion import parse_health
    h = parse_health(_norm("dormí de 11 a 7"))
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 8.0


def test_health_digit_sleep_hours_regression() -> None:
    """'anoche dormí 6 horas y media' still produces 6.5h."""
    from lifeos.health.ingestion import parse_health
    h = parse_health(_norm("anoche dormí 6 horas y media"))
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["value"] == 6.5


def test_health_digit_bp_regression() -> None:
    """'presión 120/80 pulso 72' still works."""
    from lifeos.health.ingestion import parse_health
    h = parse_health(_norm("presión 120/80 pulso 72"))
    assert h is not None
    assert h.data["type"] == "blood_pressure"
    assert h.data["systolic"] == 120
    assert h.data["diastolic"] == 80


# ─── Finance: word amounts ─────────────────────────────────────────────────


def test_finance_word_amount_mil_quinientos() -> None:
    """'gasté mil quinientos en el súper' → expense 1500 MXN."""
    from lifeos.finance.ingestion import parse_finance
    fi = parse_finance(_norm("gasté mil quinientos en el súper"))
    assert fi is not None
    assert fi.kind == "expense"
    assert fi.amount == 1500
    assert fi.currency == "MXN"


# ─── Exercise: word minutes ────────────────────────────────────────────────


def test_exercise_word_minutes_caminar() -> None:
    """'caminé cuarenta y cinco minutos' → walk 45 min."""
    from lifeos.exercise.ingestion import parse_exercise
    ei = parse_exercise(_norm("caminé cuarenta y cinco minutos"))
    assert ei is not None
    assert ei.kind == "walk"
    assert ei.duration_minutes == 45
