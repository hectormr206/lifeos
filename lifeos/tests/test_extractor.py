"""Tests for lifeos.agents.extractor — retry-on-transient-failure behavior.

The extractor is the nano fallback in the regex → nano → brain ingestion
cascade. A nano *timeout* is a transient infra failure (CPU contention,
long input), NOT a "no domain here" decision. Treating the two identically
silently drops user data: on timeout extract() returned None, the caller
fell through to the brain, and the brain does not persist. These tests pin
the fix — retry on transport failure with a larger budget, but never waste
a retry on a clean "no domain" answer.
"""
from __future__ import annotations

import pytest

from lifeos.agents import extractor, runtime


def _ok(content: str) -> runtime.NanoResult:
    return runtime.NanoResult(ok=True, content=content, latency_ms=120)


def _timeout() -> runtime.NanoResult:
    return runtime.NanoResult(ok=False, content="", latency_ms=5000,
                              error="timed out")


_VALID_JSON = '{"domain": "health", "title": "presión 120/80", "kind": "vital"}'


class _Recorder:
    """Stand-in for runtime.call_nano that plays a scripted sequence of
    results and records the timeout_s used on each call."""

    def __init__(self, results):
        self._results = list(results)
        self.timeouts: list[float] = []
        self.calls = 0

    def __call__(self, *, system, user, temperature, max_tokens, timeout_s):
        self.timeouts.append(timeout_s)
        self.calls += 1
        # Repeat the last scripted result if we run past the script.
        idx = min(self.calls - 1, len(self._results) - 1)
        return self._results[idx]


def test_retries_nano_on_timeout_then_succeeds(monkeypatch):
    rec = _Recorder([_timeout(), _ok(_VALID_JSON)])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract("me tomé la presión, 120/80")

    assert result is not None
    assert result.domain == "health"
    assert rec.calls == 2  # timed out once, retried once, succeeded


def test_returns_none_after_retries_exhausted(monkeypatch):
    rec = _Recorder([_timeout()])  # always times out
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract("me tomé la presión, 120/80")

    assert result is None
    assert rec.calls == 2  # 1 initial attempt + 1 retry, then give up


def test_no_retry_on_clean_no_domain(monkeypatch):
    # ok=True with domain=null is a legitimate "nothing to extract" — the
    # caller should fall to the brain immediately, NOT burn a 15s retry.
    rec = _Recorder([_ok('{"domain": null}')])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract("hola, qué tal")

    assert result is None
    assert rec.calls == 1  # no retry on a clean answer


def test_retry_uses_larger_timeout_budget(monkeypatch):
    rec = _Recorder([_timeout(), _ok(_VALID_JSON)])
    monkeypatch.setattr(runtime, "call_nano", rec)

    extractor.extract("me tomé la presión, 120/80", timeout_s=5.0,
                      retry_timeout_s=15.0)

    assert rec.timeouts[0] == 5.0    # first attempt: fast budget
    assert rec.timeouts[1] == 15.0   # retry: generous budget


def test_no_retry_when_retries_zero(monkeypatch):
    rec = _Recorder([_timeout()])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract("me tomé la presión, 120/80", retries=0)

    assert result is None
    assert rec.calls == 1  # retries=0 disables the retry entirely


# ── Layer 3 — structured vitals fields in ExtractionResult ───────────────────
# These tests verify that the extractor correctly parses and surfaces the new
# systolic / diastolic / pulse_bpm fields from JSON returned by the nano model.
# The HTTP call is stubbed via monkeypatch — no real server required.

_BP_VITAL_JSON = (
    '{"domain":"health","amount":null,"currency":null,"merchant":null,'
    '"people":[],"dates_text":[],"duration_minutes":null,"items":[],'
    '"title":"presión 122/81, pulso 53","kind":"vital",'
    '"systolic":122,"diastolic":81,"pulse_bpm":53}'
)

_BP_NO_PULSE_JSON = (
    '{"domain":"health","amount":null,"currency":null,"merchant":null,'
    '"people":[],"dates_text":[],"duration_minutes":null,"items":[],'
    '"title":"presión 120/80","kind":"vital",'
    '"systolic":120,"diastolic":80,"pulse_bpm":null}'
)

_SYMPTOM_JSON = (
    '{"domain":"health","amount":null,"currency":null,"merchant":null,'
    '"people":[],"dates_text":[],"duration_minutes":null,"items":[],'
    '"title":"dolor de cabeza","kind":"symptom",'
    '"systolic":null,"diastolic":null,"pulse_bpm":null}'
)


def test_extraction_result_carries_vitals_fields(monkeypatch):
    """When nano returns systolic/diastolic/pulse_bpm, ExtractionResult exposes them."""
    rec = _Recorder([_ok(_BP_VITAL_JSON)])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract("122/81 53 pulsos")

    assert result is not None
    assert result.domain == "health"
    assert result.systolic == 122
    assert result.diastolic == 81
    assert result.pulse_bpm == 53


def test_extraction_result_vitals_nullable(monkeypatch):
    """When pulse_bpm is null in JSON, ExtractionResult.pulse_bpm is None."""
    rec = _Recorder([_ok(_BP_NO_PULSE_JSON)])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract("presión 120/80")

    assert result is not None
    assert result.systolic == 120
    assert result.diastolic == 80
    assert result.pulse_bpm is None


def test_extraction_result_vitals_absent_for_non_vital(monkeypatch):
    """Non-BP health entries have systolic/diastolic/pulse_bpm = None."""
    rec = _Recorder([_ok(_SYMPTOM_JSON)])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract("tengo dolor de cabeza")

    assert result is not None
    assert result.domain == "health"
    assert result.systolic is None
    assert result.diastolic is None
    assert result.pulse_bpm is None


# ── Task 2: new structured vitals fields (sleep, weight, glucose) ─────────────

_SLEEP_VITAL_JSON = (
    '{"domain":"health","amount":null,"currency":null,"merchant":null,'
    '"people":[],"dates_text":[],"duration_minutes":null,"items":[],'
    '"title":"sueño 8h","kind":"vital",'
    '"systolic":null,"diastolic":null,"pulse_bpm":null,'
    '"sleep_hours":8.0,"weight_kg":null,"glucose_mg_dl":null}'
)

_WEIGHT_VITAL_JSON = (
    '{"domain":"health","amount":null,"currency":null,"merchant":null,'
    '"people":[],"dates_text":[],"duration_minutes":null,"items":[],'
    '"title":"peso 64.5 kg","kind":"vital",'
    '"systolic":null,"diastolic":null,"pulse_bpm":null,'
    '"sleep_hours":null,"weight_kg":64.5,"glucose_mg_dl":null}'
)

_GLUCOSE_VITAL_JSON = (
    '{"domain":"health","amount":null,"currency":null,"merchant":null,'
    '"people":[],"dates_text":[],"duration_minutes":null,"items":[],'
    '"title":"glucosa 95 mg/dL","kind":"vital",'
    '"systolic":null,"diastolic":null,"pulse_bpm":null,'
    '"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":95.0}'
)


def test_extraction_result_carries_sleep_hours(monkeypatch):
    """ExtractionResult exposes sleep_hours when nano returns it."""
    rec = _Recorder([_ok(_SLEEP_VITAL_JSON)])
    monkeypatch.setattr(runtime, "call_nano", rec)
    result = extractor.extract("dormí 8 horas")
    assert result is not None
    assert result.domain == "health"
    assert result.sleep_hours == 8.0


def test_extraction_result_carries_weight_kg(monkeypatch):
    """ExtractionResult exposes weight_kg when nano returns it."""
    rec = _Recorder([_ok(_WEIGHT_VITAL_JSON)])
    monkeypatch.setattr(runtime, "call_nano", rec)
    result = extractor.extract("pesé 64.5 kg hoy en ayunas")
    assert result is not None
    assert result.weight_kg == 64.5


def test_extraction_result_carries_glucose(monkeypatch):
    """ExtractionResult exposes glucose_mg_dl when nano returns it."""
    rec = _Recorder([_ok(_GLUCOSE_VITAL_JSON)])
    monkeypatch.setattr(runtime, "call_nano", rec)
    result = extractor.extract("glucosa en 95 esta mañana")
    assert result is not None
    assert result.glucose_mg_dl == 95.0


def test_extraction_result_new_fields_nullable(monkeypatch):
    """When sleep/weight/glucose are absent (BP-only entry), they are None."""
    rec = _Recorder([_ok(_BP_VITAL_JSON)])
    monkeypatch.setattr(runtime, "call_nano", rec)
    result = extractor.extract("122/81 53 pulsos")
    assert result is not None
    assert result.sleep_hours is None
    assert result.weight_kg is None
    assert result.glucose_mg_dl is None


# ── Prompt-gap fixes (2026-06-07 benchmark) ──────────────────────────────────
# These tests verify the three prompt gaps found in the 30-case Spanish
# benchmark: (1) garbage inputs, (2) spirituality vs health boundary,
# (3) utility bill categorization.
#
# The nano endpoint is mocked — tests pin the *extractor parser behaviour*
# given the corrected model output, AND verify that null/none responses take
# the cheap "no domain" path rather than burning a retry.


# ── Gap 1: garbage / meaningless inputs must map to null ─────────────────────

@pytest.mark.parametrize("garbage_text", [
    "jajaja sí claro",       # laughter filler (14 chars, passes 12-char guard)
    "jeje que raro",          # filler with no life-domain content (13 chars)
    "sí claro que sí",        # agreement filler (15 chars)
    "ok ya entendí todo",     # conversational ack (18 chars)
])
def test_garbage_input_returns_null_domain(monkeypatch, garbage_text):
    """Garbage/filler inputs should produce null from the model.
    The extractor must return None (no retry — it's a clean null, not a transport failure)."""
    rec = _Recorder([_ok('{"domain": null}')])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract(garbage_text)

    assert result is None
    assert rec.calls == 1, "null domain must NOT trigger a retry — cheap path only"


def test_garbage_null_domain_in_full_json(monkeypatch):
    """Null domain returned in full JSON envelope is still treated as 'no extract'."""
    full_null = (
        '{"domain":null,"amount":null,"currency":null,"merchant":null,'
        '"people":[],"dates_text":[],"duration_minutes":null,"items":[],'
        '"title":null,"kind":null,"systolic":null,"diastolic":null,'
        '"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}'
    )
    rec = _Recorder([_ok(full_null)])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract("jajaja sí claro")

    assert result is None
    assert rec.calls == 1


# ── Gap 2: spirituality vs health — gratitude must NOT route to health ────────

_SPIRITUALITY_JSON = (
    '{"domain":"spirituality","amount":null,"currency":null,"merchant":null,'
    '"people":[],"dates_text":[],"duration_minutes":null,"items":[],'
    '"title":"agradecimiento","kind":"gratitude","systolic":null,"diastolic":null,'
    '"pulse_bpm":null,"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}'
)


@pytest.mark.parametrize("spiritual_text", [
    "gracias a Dios por este día",
    "hoy me desperté agradecido por todo lo que tengo",
    "me siento en paz y agradecido con la vida",
])
def test_gratitude_routes_to_spirituality_not_health(monkeypatch, spiritual_text):
    """Gratitude / spiritual reflection must come back as spirituality, never health."""
    rec = _Recorder([_ok(_SPIRITUALITY_JSON)])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract(spiritual_text)

    assert result is not None
    assert result.domain == "spirituality", (
        f"Expected spirituality, got {result.domain!r} for {spiritual_text!r}"
    )
    assert result.systolic is None
    assert result.diastolic is None
    assert result.pulse_bpm is None


# ── Gap 3: utility bills — finance/bill with category=servicios ──────────────

_GAS_BILL_JSON = (
    '{"domain":"finance","amount":580,"currency":"MXN","merchant":"Gas","people":[],'
    '"dates_text":[],"duration_minutes":null,"items":[{"name":"gas","amount":580,'
    '"category":"servicios"}],"title":"pago de gas","kind":"bill",'
    '"systolic":null,"diastolic":null,"pulse_bpm":null,'
    '"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}'
)

_LUZ_BILL_JSON = (
    '{"domain":"finance","amount":340,"currency":"MXN","merchant":"CFE","people":[],'
    '"dates_text":[],"duration_minutes":null,"items":[{"name":"luz","amount":340,'
    '"category":"servicios"}],"title":"pago de luz","kind":"bill",'
    '"systolic":null,"diastolic":null,"pulse_bpm":null,'
    '"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}'
)


def test_utility_gas_bill_routes_to_finance_bill(monkeypatch):
    """'pagué el gas, 580 pesos' — gas is a utility bill in MX context.
    Expects domain=finance, kind=bill, items[0].category=servicios."""
    rec = _Recorder([_ok(_GAS_BILL_JSON)])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract("pagué el gas, 580 pesos")

    assert result is not None
    assert result.domain == "finance"
    assert result.kind == "bill"
    assert result.amount == 580.0
    # items should have servicios category (not hogar / electrónica / transporte)
    assert result.items, "expected at least one item"
    assert result.items[0]["category"] == "servicios"


def test_utility_luz_bill_routes_to_finance_bill(monkeypatch):
    """'pagué la luz, 340' — luz (CFE) is a utility bill in MX context."""
    rec = _Recorder([_ok(_LUZ_BILL_JSON)])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract("pagué la luz, 340")

    assert result is not None
    assert result.domain == "finance"
    assert result.kind == "bill"
    assert result.items
    assert result.items[0]["category"] == "servicios"


@pytest.mark.parametrize("utility_text,expected_kind", [
    ("pagué el internet, 450 pesos", "bill"),
    ("pagué el agua, 220 pesos", "bill"),
    ("pagué el gas natural, 580 pesos", "bill"),
])
def test_utility_bills_generic(monkeypatch, utility_text, expected_kind):
    """Common Mexican utility payments produce kind=bill, domain=finance."""
    bill_json = (
        '{"domain":"finance","amount":450,"currency":"MXN","merchant":"Servicio",'
        '"people":[],"dates_text":[],"duration_minutes":null,'
        '"items":[{"name":"servicio","amount":450,"category":"servicios"}],'
        '"title":"pago de servicio","kind":"bill",'
        '"systolic":null,"diastolic":null,"pulse_bpm":null,'
        '"sleep_hours":null,"weight_kg":null,"glucose_mg_dl":null}'
    )
    rec = _Recorder([_ok(bill_json)])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract(utility_text)

    assert result is not None
    assert result.domain == "finance"
    assert result.kind == expected_kind
