"""Tests for lifeos.text.normalize.normalize_numbers_es.

Positive cases: word numbers should be converted to digits.
Negative/ambiguity cases: articles/pronouns must pass through unchanged.
Quote protection: numbers inside quoted titles must NOT be converted.
"""

from __future__ import annotations

import pytest


# ─── Cardinals: basic words ────────────────────────────────────────────────

def test_cardinal_simple_units() -> None:
    from lifeos.text.normalize import normalize_numbers_es
    assert normalize_numbers_es("dos") == "2"
    assert normalize_numbers_es("tres") == "3"
    assert normalize_numbers_es("diez") == "10"
    assert normalize_numbers_es("once") == "11"
    assert normalize_numbers_es("veinte") == "20"


def test_cardinal_tens_with_y() -> None:
    from lifeos.text.normalize import normalize_numbers_es
    assert normalize_numbers_es("cuarenta y cinco") == "45"
    assert normalize_numbers_es("cincuenta y seis") == "56"
    assert normalize_numbers_es("treinta y dos") == "32"
    assert normalize_numbers_es("noventa y nueve") == "99"


def test_cardinal_hundreds() -> None:
    from lifeos.text.normalize import normalize_numbers_es
    assert normalize_numbers_es("ciento veintidós") == "122"
    assert normalize_numbers_es("ciento veintidos") == "122"
    assert normalize_numbers_es("doscientos") == "200"
    assert normalize_numbers_es("trescientos cincuenta") == "350"


def test_cardinal_thousands() -> None:
    from lifeos.text.normalize import normalize_numbers_es
    assert normalize_numbers_es("mil") == "1000"
    assert normalize_numbers_es("dos mil") == "2000"
    assert normalize_numbers_es("mil quinientos") == "1500"
    assert normalize_numbers_es("dos mil trescientos") == "2300"


# ─── Time normalization ────────────────────────────────────────────────────

def test_time_word_hour_word_minutes_after_alas() -> None:
    """'a las nueve cuarenta y cinco' → 'a las 9:45'"""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("a las nueve cuarenta y cinco")
    assert result == "a las 9:45"


def test_time_word_hour_word_minutes_seis_cincuenta_y_seis() -> None:
    """'seis cincuenta y seis' in time context → '6:56'"""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("me desperté a las seis cincuenta y seis")
    assert "6:56" in result


def test_time_digit_hour_word_minutes() -> None:
    """'9 cuarenta y cinco' → '9:45' in time context"""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("me dormí a las 9 cuarenta y cinco")
    assert "9:45" in result


def test_time_digit_hour_word_minutes_standalone() -> None:
    """Without time context, digit + word-minutes must NOT convert.
    'habitacion 9 treinta' must stay unchanged.
    """
    from lifeos.text.normalize import normalize_numbers_es
    # No time context → should not fire digit-hour+word-minutes substitution
    result = normalize_numbers_es("habitacion 9 treinta")
    assert "9:30" not in result  # must not be mangled


def test_time_y_media_not_mangled() -> None:
    """'8 y media' must pass through — downstream regex handles it."""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("Me dormí a las 10 y me desperté a las 8 y media")
    assert "8 y media" in result


def test_time_word_hour_simple() -> None:
    """'nueve' after 'a las' → '9'"""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("a las nueve de la noche")
    assert "9" in result


# ─── Health empirical cases (the 5 from the spec) ─────────────────────────

def test_health_case1_sleep_digit_hour_word_minutes() -> None:
    """Case 1: 'Me dormí a las 9 cuarenta y cinco y me desperté a las seis cincuenta y seis'
    → digits for both start and end so parse_health gets '9:45' and '6:56'."""
    from lifeos.text.normalize import normalize_numbers_es
    text = "Me dormí a las 9 cuarenta y cinco y me desperté a las seis cincuenta y seis"
    result = normalize_numbers_es(text)
    assert "9:45" in result
    assert "6:56" in result


def test_health_case2_bp_word_numbers() -> None:
    """Case 2: 'presión ciento veintidós ochenta y uno, cincuenta y tres pulsos'
    → 'presión 122 81, 53 pulsos' (so the BP parsers can match)."""
    from lifeos.text.normalize import normalize_numbers_es
    text = "presión ciento veintidós ochenta y uno, cincuenta y tres pulsos"
    result = normalize_numbers_es(text)
    assert "122" in result
    assert "81" in result
    assert "53" in result


def test_health_case3_bp_no_keyword() -> None:
    """Case 3: 'ciento veintidós ochenta y uno y cincuenta y tres de pulso'"""
    from lifeos.text.normalize import normalize_numbers_es
    text = "ciento veintidós ochenta y uno y cincuenta y tres de pulso"
    result = normalize_numbers_es(text)
    assert "122" in result
    assert "81" in result
    assert "53" in result


def test_health_case4_weight_word() -> None:
    """Case 4: 'pesé sesenta y cuatro kilos' → '... 64 kilos'"""
    from lifeos.text.normalize import normalize_numbers_es
    text = "pesé sesenta y cuatro kilos"
    result = normalize_numbers_es(text)
    assert "64" in result


def test_health_case5_glucose_word() -> None:
    """Case 5: 'glucosa en noventa y cinco' → '... 95'"""
    from lifeos.text.normalize import normalize_numbers_es
    text = "glucosa en noventa y cinco"
    result = normalize_numbers_es(text)
    assert "95" in result


# ─── Ambiguity guard (MUST NOT convert) ───────────────────────────────────

def test_no_convert_una_reunion() -> None:
    """'una reunión con Diego' — 'una' is article, must NOT become '1'."""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("una reunión con Diego")
    assert result == "una reunión con Diego"


def test_no_convert_hable_con_una_amiga() -> None:
    """'hablé con una amiga' — 'una' is article."""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("hablé con una amiga")
    assert result == "hablé con una amiga"


def test_no_convert_es_uno_de_mis_favoritos() -> None:
    """'es uno de mis favoritos' — 'uno' is pronoun."""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("es uno de mis favoritos")
    assert result == "es uno de mis favoritos"


def test_no_convert_uno_alone_ambiguous() -> None:
    """Standalone 'uno' without numeric context passes through."""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("eso es uno")
    # Should not become "eso es 1" — ambiguous pronoun context
    assert "uno" in result


# ─── Quote protection ──────────────────────────────────────────────────────

def test_quote_protection_single_quotes() -> None:
    """Numbers inside single-quoted titles must NOT be converted."""
    from lifeos.text.normalize import normalize_numbers_es
    text = "empecé el libro 'Cien años de soledad'"
    result = normalize_numbers_es(text)
    assert "'Cien años de soledad'" in result


def test_quote_protection_double_quotes() -> None:
    """Numbers inside double-quoted titles must NOT be converted."""
    from lifeos.text.normalize import normalize_numbers_es
    text = 'vi la película "Dos mil años"'
    result = normalize_numbers_es(text)
    assert '"Dos mil años"' in result


# ─── Measurement unit context: uno/una conversion ─────────────────────────

def test_una_before_hora() -> None:
    """'dormí una hora' — 'una' before unit → should convert."""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("dormí una hora")
    assert "1" in result


def test_uno_before_kilo() -> None:
    """'pesé uno kilos' (unusual but should convert near unit)."""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("pesé uno kilos")
    assert "1" in result


# ─── Finance domain ────────────────────────────────────────────────────────

def test_finance_word_amount() -> None:
    """'gasté mil quinientos en el súper' → '... 1500 ...'"""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("gasté mil quinientos en el súper")
    assert "1500" in result


# ─── Exercise domain ──────────────────────────────────────────────────────

def test_exercise_word_minutes() -> None:
    """'caminé cuarenta y cinco minutos' → '... 45 ...'"""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("caminé cuarenta y cinco minutos")
    assert "45" in result


# ─── Idempotency: pure digits pass through unchanged ──────────────────────

def test_digits_pass_through() -> None:
    from lifeos.text.normalize import normalize_numbers_es
    assert normalize_numbers_es("dormí 6 horas") == "dormí 6 horas"
    assert normalize_numbers_es("presión 120/80 pulso 72") == "presión 120/80 pulso 72"


def test_empty_and_none_safe() -> None:
    from lifeos.text.normalize import normalize_numbers_es
    assert normalize_numbers_es("") == ""


# ─── Issue 4: digit+word-minutes only in time context ──────────────────────

def test_digit_word_minutes_no_context_habitacion() -> None:
    """'habitacion 9 treinta' must NOT become 'habitacion 9:30'.
    'treinta' may still be converted to '30' by the general number pass,
    but the digit+word-minutes clock format must NOT fire here.
    """
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("habitacion 9 treinta")
    assert "9:30" not in result  # must not produce a clock time


def test_digit_word_minutes_no_context_anio() -> None:
    """'año 9 cuarenta y cinco' must NOT become 'año 9:45'."""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("año 9 cuarenta y cinco")
    assert "9:45" not in result


def test_digit_word_minutes_with_alas_context() -> None:
    """'a las 9 cuarenta y cinco' → 'a las 9:45'."""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("a las 9 cuarenta y cinco")
    assert "9:45" in result


def test_digit_word_minutes_full_sleep_phrase() -> None:
    """End-to-end: 'Me dormí a las 9 cuarenta y cinco y me desperté a las seis cincuenta y seis'
    must normalize via normalize_numbers_es first, then parse correctly via parse_health."""
    from lifeos.health.ingestion import parse_health
    from lifeos.text.normalize import normalize_numbers_es

    raw = "Me dormí a las 9 cuarenta y cinco y me desperté a las seis cincuenta y seis"
    normalized = normalize_numbers_es(raw)
    # Normalized form should contain the colon-time representations
    assert "9:45" in normalized
    assert "6:56" in normalized
    h = parse_health(normalized)
    assert h is not None
    assert h.data["type"] == "sleep_hours"
    assert h.data["start_hour_24"] == 21  # 9 PM (evening heuristic, no explicit period)
    assert h.data["start_minute"] == 45
    assert h.data["end_hour_24"] == 6
    assert h.data["end_minute"] == 56


# ─── Issue 5: "un" converted to "1" in all contexts ───────────────────────

def test_no_convert_un_medicamento() -> None:
    """'tomé un medicamento' — 'un' is article, must NOT become '1 medicamento'."""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("tomé un medicamento")
    assert "un medicamento" in result
    assert "1 medicamento" not in result


def test_no_convert_con_un_amigo() -> None:
    """'con un amigo' — 'un' is article."""
    from lifeos.text.normalize import normalize_numbers_es
    result = normalize_numbers_es("con un amigo")
    assert "un amigo" in result
    assert "1 amigo" not in result
