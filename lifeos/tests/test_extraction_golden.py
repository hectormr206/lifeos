"""Golden regression harness for extraction reliability — L4 layer.

CONTRACT / POLICY
-----------------
Every newly reported real-world extraction miss MUST get a golden case added
here BEFORE its fix is merged. This harness is the regression net that locks
in the deterministic overrides introduced in SLICE 2 (L2).

The cases here are partitioned into two tiers:

  Tier A — deterministic parsers called directly (no nano, no dashboard).
    These verify the core arithmetic / regex results in isolation.
    Characteristics: fast, fully deterministic, do not require the axi package.

  Tier B — dashboard gate behaviour.
    These verify that the GATE in dashboard._try_nano_extract fires (or
    intentionally does NOT fire) for edge-case utterances. They use the
    existing _SLEEP_FROM_TO_RE / _SLEEP_DE_X_A_Y_RE directly — no
    live dashboard call is required for gate-shape assertions.

HOW TO ADD A NEW CASE
---------------------
1. Find the relevant GOLDEN_* list below that matches the domain/parser.
2. Append a tuple: (input_text, expected_value_or_assertion_hint).
   For parametrized tiers the tuple shape is documented above each list.
3. That's it. The @pytest.mark.parametrize decorator picks it up automatically.

Never weaken an existing assertion to make a failing case pass — that would
hide a regression. Instead, investigate and fix the underlying parser.
"""
from __future__ import annotations

import pytest
from datetime import datetime
from zoneinfo import ZoneInfo

_TZ = ZoneInfo("America/Mexico_City")


# ---------------------------------------------------------------------------
# Tier A — deterministic parser cases
# ---------------------------------------------------------------------------

# Shape: (input_text, expected_minutes)
GOLDEN_DURATION = [
    # ── cases that WOULD HAVE CAUGHT the sleep-hour bug (wrong duration):
    # "media hora" — simplest exercise duration phrase
    ("hice media hora de ejercicio", 30),
    # word-number "una hora y cuarto" — compound hour + fraction
    ("una hora y cuarto de carrera", 75),
    # bare fractional "hora y media"
    ("hora y media de yoga", 90),
    # digit hours only
    ("corrí 2 horas", 120),
    # digit minutes
    ("caminé 45 minutos", 45),
    # "una hora" alone
    ("una hora en el gym", 60),
    # "una hora y media" (explicit una)
    ("hice una hora y media de natación", 90),
]


@pytest.mark.parametrize("text,expected_minutes", GOLDEN_DURATION)
def test_golden_duration(text: str, expected_minutes: int) -> None:
    """_parse_duration_es must return the exact expected minute count."""
    from lifeos.health.ingestion import _parse_duration_es

    result = _parse_duration_es(text)
    assert result == expected_minutes, (
        f"_parse_duration_es({text!r}) returned {result!r}, expected {expected_minutes}"
    )


# ---------------------------------------------------------------------------
# Tier A — sleep: digit-form explicit wake time
# ---------------------------------------------------------------------------

# Shape: (input_text, expected_hours_float)
GOLDEN_SLEEP_DETERMINISTIC = [
    # KEY REGRESSION CASE: digit-form 11:50 pm → 5:50 am → exactly 6.0 h
    # This WOULD HAVE CAUGHT the original sleep bug (nano returned wrong value;
    # the deterministic gate must fire and compute 6.0 from the timestamps).
    ("Me dormí a las 11:50 pm y me desperté hoy a las 5:50 am", 6.0),
    # Word-form: 11 pm → 7 am → 8.0 h
    # This WOULD HAVE CAUGHT the word-form gate bug (gate was digit-only
    # so word hours were passed to nano, which returned garbage).
    ("me dormí a las once de la noche y desperté a las siete", 8.0),
    # "dormí de X a Y" form (uses _SLEEP_DE_X_A_Y_RE)
    ("dormí de las 11 pm a las 6 am", 7.0),
    # Word-form via _SLEEP_DE_X_A_Y_RE
    ("dormí de las once de la noche a las seis de la mañana", 7.0),
]


@pytest.mark.parametrize("text,expected_hours", GOLDEN_SLEEP_DETERMINISTIC)
def test_golden_sleep_deterministic(text: str, expected_hours: float) -> None:
    """_try_natural_sleep must return the expected sleep hours deterministically.

    These cases are the ones that WOULD HAVE exposed the original sleep bug
    and the word-form gate omission. They exercise the deterministic parser
    directly — no nano, no wall time dependence.
    """
    from lifeos.health.ingestion import _try_natural_sleep

    # Pass a fixed 'now' so any wall-time fallback is also deterministic
    fixed_now = datetime(2026, 6, 19, 6, 0, tzinfo=_TZ)
    result = _try_natural_sleep(text, now=fixed_now)
    assert result is not None, (
        f"_try_natural_sleep({text!r}) returned None — expected {expected_hours}h"
    )
    actual = result.data["value"]
    assert abs(actual - expected_hours) < 0.1, (
        f"_try_natural_sleep({text!r}) → {actual}h, expected {expected_hours}h"
    )


# ---------------------------------------------------------------------------
# Tier A — sleep footgun case
# ---------------------------------------------------------------------------

def test_golden_sleep_footgun_no_explicit_wake() -> None:
    """'me dormí a las 11 pm y acabo de despertar' must NOT produce a fixed value.

    FOOTGUN: _SLEEP_FROM_TO_RE matches this utterance but end_h is None.
    The parser falls back to wall time. The dashboard gate MUST NOT fire for
    this case (ADR-4), ensuring the unreliable wall-time result is not stored
    as a deterministic override.

    This test asserts the GATE CONTRACT, not a fixed sleep value:
    - The regex matches (onset verb present).
    - end_h is absent (no explicit wake time stated).
    - The gate in dashboard.py skips the deterministic path for this input.
    """
    from lifeos.health.ingestion import _SLEEP_FROM_TO_RE

    utterance = "me dormí a las 11 pm y acabo de despertar"

    m = _SLEEP_FROM_TO_RE.search(utterance)
    assert m is not None, (
        "Regression: _SLEEP_FROM_TO_RE no longer matches the footgun utterance"
    )
    # The critical contract: end_h MUST be None so the gate correctly skips
    assert m.group("end_h") is None, (
        "FOOTGUN BROKEN: end_h is unexpectedly non-None — the gate will fire "
        "and store a wall-time-dependent sleep duration as if it were reliable. "
        f"Got end_h={m.group('end_h')!r}"
    )


# ---------------------------------------------------------------------------
# Tier A — blood pressure
# ---------------------------------------------------------------------------

# Shape: (input_text, systolic, diastolic, pulse)
GOLDEN_BP = [
    # Real-world format "sys, dia, pulse pulsos" — no keyword prefix
    ("114, 83, 55 pulsos", 114, 83, 55),
    # Keyword prefix with slash separator
    ("presión 120/80 pulso 72", 120, 80, 72),
    # Keyword prefix with space separator
    ("presión arterial 118 76", 118, 76, None),
]


@pytest.mark.parametrize("text,systolic,diastolic,pulse", GOLDEN_BP)
def test_golden_blood_pressure(
    text: str, systolic: int, diastolic: int, pulse: int | None
) -> None:
    """parse_health must extract BP fields correctly for known real-world inputs."""
    from lifeos.health.ingestion import parse_health

    result = parse_health(text)
    assert result is not None, f"parse_health({text!r}) returned None"
    data = result.data
    assert data.get("type") == "blood_pressure", (
        f"Expected type='blood_pressure' but got {data.get('type')!r}"
    )
    assert data["systolic"] == systolic, (
        f"systolic: expected {systolic}, got {data['systolic']}"
    )
    assert data["diastolic"] == diastolic, (
        f"diastolic: expected {diastolic}, got {data['diastolic']}"
    )
    if pulse is not None:
        assert data.get("pulse_bpm") == pulse, (
            f"pulse_bpm: expected {pulse}, got {data.get('pulse_bpm')}"
        )


# ---------------------------------------------------------------------------
# Tier A — finance amount validation
# ---------------------------------------------------------------------------

# Shape: (raw_text_hint, nano_amount, expected_result)
# expected_result is None for implausible amounts, the float itself for valid ones.
GOLDEN_AMOUNT = [
    # Plausible finance amounts must pass through unchanged
    ("gasté 350 en la tienda", 350.0, 350.0),
    ("pagué 1800 de renta", 1800.0, 1800.0),
    ("compré algo por 0.99", 0.99, 0.99),
    # Implausible amounts must be rejected (return None)
    # Negative
    ("weird input", -5.0, None),
    # Zero
    ("weird input", 0.0, None),
    # Astronomically large (>= 1e9)
    ("weird input", 2_000_000_000.0, None),
    # None passthrough
    ("no amount here", None, None),
]


@pytest.mark.parametrize("raw_text,nano_amount,expected", GOLDEN_AMOUNT)
def test_golden_amount_validation(
    raw_text: str, nano_amount: float | None, expected: float | None
) -> None:
    """_validate_amount must accept plausible amounts and reject implausible ones."""
    from lifeos.health.ingestion import _validate_amount

    result = _validate_amount(raw_text, nano_amount)
    assert result == expected, (
        f"_validate_amount({raw_text!r}, {nano_amount!r}) → {result!r}, expected {expected!r}"
    )


# ---------------------------------------------------------------------------
# Tier B — dashboard gate shape assertions (no live nano call)
# ---------------------------------------------------------------------------

def test_golden_gate_word_form_fires_with_explicit_wake() -> None:
    """Word-form sleep WITH explicit end time: gate fires (_word_form=True).

    Regression for the fix introduced in task 2.8: before the fix, the gate
    condition only checked _CLOCK_TIME_RE digit matches and missed word-form
    inputs like this one.
    """
    from lifeos.health.ingestion import _SLEEP_FROM_TO_RE
    from axi.dashboard import _CLOCK_TIME_RE

    utterance = "me dormí a las once de la noche y desperté a las siete"

    # Digit gate should NOT fire (no digit clock times)
    assert len(_CLOCK_TIME_RE.findall(utterance)) < 2, (
        "Digit-clock gate should NOT fire for pure word-form input"
    )
    # Word-form gate MUST fire
    m = _SLEEP_FROM_TO_RE.search(utterance)
    assert m is not None, "_SLEEP_FROM_TO_RE did not match word-form utterance"
    assert m.group("end_h") is not None, (
        "end_h should be non-None when explicit wake time is stated "
        "(seven = siete is the explicit end)"
    )


def test_golden_gate_de_x_a_y_fires() -> None:
    """'dormí de X a Y' gate always fires via _SLEEP_DE_X_A_Y_RE."""
    from lifeos.health.ingestion import _SLEEP_DE_X_A_Y_RE

    utterance = "dormí de las 11 pm a las 6 am"
    assert _SLEEP_DE_X_A_Y_RE.search(utterance) is not None, (
        "_SLEEP_DE_X_A_Y_RE did not match 'dormí de X a Y' utterance"
    )


def test_golden_gate_footgun_does_not_fire() -> None:
    """Footgun: word-form WITHOUT explicit end time → gate must NOT fire.

    Before ADR-4 fix the gate condition didn't inspect end_h at all, so this
    would have fired and stored a wall-time-dependent sleep duration as if it
    were a reliable deterministic override.
    """
    from lifeos.health.ingestion import _SLEEP_FROM_TO_RE
    from axi.dashboard import _CLOCK_TIME_RE

    utterance = "me dormí a las 11 pm y acabo de despertar"

    # Digit gate does not fire
    assert len(_CLOCK_TIME_RE.findall(utterance)) < 2

    # Word-form matches, BUT end_h is absent → gate must NOT count this
    m = _SLEEP_FROM_TO_RE.search(utterance)
    assert m is not None, "_SLEEP_FROM_TO_RE must still match for the onset verb"
    end_h = m.group("end_h")
    # Simulate the gate condition as implemented in dashboard.py
    _word_form_gate_fires = end_h is not None
    assert not _word_form_gate_fires, (
        "The gate would have fired for the footgun case — "
        "this means the ADR-4 end_h guard is missing or broken"
    )
