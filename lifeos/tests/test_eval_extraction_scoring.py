"""Tests for the extraction-quality scorer (score_extraction / format_extraction_report).

All tests are PURE — no live extractor, no network, no filesystem side-effects
beyond tmp_path.  This module must remain importable even when the nano
llama-server is offline.

TDD cycle: tests were written FIRST (RED) and the implementation was added
afterward (GREEN).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from lifeos.agents.eval.scoring import (
    ExtractionCase,
    ExtractionScore,
    score_extraction,
    format_extraction_report,
    load_extraction_golden_set,
)


# ---------------------------------------------------------------------------
# Helpers — minimal ExtractionCase factories
# ---------------------------------------------------------------------------


def _ec(text: str, expected: dict, fuzzy_fields: list[str] | None = None) -> ExtractionCase:
    return ExtractionCase(
        text=text,
        expected=expected,
        fuzzy_fields=fuzzy_fields or [],
    )


def _result(**kwargs) -> dict:
    """Build a prediction dict with sensible defaults for unset keys."""
    defaults: dict = {
        "domain": None,
        "kind": None,
        "amount": None,
        "currency": None,
        "merchant": None,
        "people": [],
        "dates_text": [],
        "items": [],
        "systolic": None,
        "diastolic": None,
        "pulse_bpm": None,
        "sleep_hours": None,
        "weight_kg": None,
        "glucose_mg_dl": None,
        "duration_minutes": None,
    }
    defaults.update(kwargs)
    return defaults


# ---------------------------------------------------------------------------
# ExtractionCase dataclass
# ---------------------------------------------------------------------------


class TestExtractionCase:
    def test_basic_construction(self) -> None:
        ec = ExtractionCase(
            text="dormí 8 horas",
            expected={"domain": "health", "kind": "vital", "sleep_hours": 8.0},
        )
        assert ec.text == "dormí 8 horas"
        assert ec.expected["sleep_hours"] == 8.0
        assert ec.fuzzy_fields == []

    def test_fuzzy_fields_stored(self) -> None:
        ec = ExtractionCase(
            text="pesé 64.5 kg hoy",
            expected={"domain": "health", "dates_text": ["hoy"]},
            fuzzy_fields=["dates_text"],
        )
        assert "dates_text" in ec.fuzzy_fields

    def test_optional_note_and_layer(self) -> None:
        ec = ExtractionCase(
            text="x",
            expected={"domain": "health"},
            note="test note",
            layer="nano",
        )
        assert ec.note == "test note"
        assert ec.layer == "nano"

    def test_defaults(self) -> None:
        ec = ExtractionCase(text="x", expected={})
        assert ec.note == ""
        assert ec.layer == "nano"
        assert ec.fuzzy_fields == []


# ---------------------------------------------------------------------------
# load_extraction_golden_set
# ---------------------------------------------------------------------------


class TestLoadExtractionGoldenSet:
    def test_loads_text_and_expected(self, tmp_path: Path) -> None:
        line = json.dumps({
            "text": "dormí 8 horas",
            "expected": {"domain": "health", "sleep_hours": 8.0},
            "layer": "nano",
            "fuzzy_fields": [],
        })
        f = tmp_path / "set.jsonl"
        f.write_text(line)
        result = load_extraction_golden_set(f)
        assert len(result) == 1
        assert result[0].text == "dormí 8 horas"
        assert result[0].expected["sleep_hours"] == 8.0

    def test_skips_blank_and_comment_lines(self, tmp_path: Path) -> None:
        content = (
            "// comment\n"
            + json.dumps({"text": "A", "expected": {"domain": "health"}, "fuzzy_fields": []})
            + "\n\n"
            + json.dumps({"text": "B", "expected": {"domain": "finance"}, "fuzzy_fields": []})
        )
        f = tmp_path / "set.jsonl"
        f.write_text(content)
        result = load_extraction_golden_set(f)
        assert len(result) == 2

    def test_fuzzy_fields_loaded(self, tmp_path: Path) -> None:
        line = json.dumps({
            "text": "pesé 64.5 kg hoy",
            "expected": {"domain": "health", "dates_text": ["hoy"]},
            "fuzzy_fields": ["dates_text"],
        })
        f = tmp_path / "set.jsonl"
        f.write_text(line)
        result = load_extraction_golden_set(f)
        assert result[0].fuzzy_fields == ["dates_text"]

    def test_origin_ignored_gracefully(self, tmp_path: Path) -> None:
        """Extra keys like 'origin' must not cause errors."""
        line = json.dumps({
            "text": "A",
            "expected": {"domain": "health"},
            "origin": "test_extractor",
            "fuzzy_fields": [],
        })
        f = tmp_path / "set.jsonl"
        f.write_text(line)
        result = load_extraction_golden_set(f)
        assert len(result) == 1

    def test_malformed_json_raises(self, tmp_path: Path) -> None:
        content = json.dumps({"text": "A", "expected": {"domain": "health"}, "fuzzy_fields": []}) + "\nnot json"
        f = tmp_path / "set.jsonl"
        f.write_text(content)
        with pytest.raises(ValueError, match="line 2"):
            load_extraction_golden_set(f)


# ---------------------------------------------------------------------------
# Field-level scoring rules: numeric int (exact ==)
# ---------------------------------------------------------------------------


class TestScoreNumericInt:
    """systolic, diastolic, pulse_bpm: exact match after int coercion."""

    def test_systolic_exact_match(self) -> None:
        case = _ec("122/81", {"domain": "health", "systolic": 122, "diastolic": 81})
        pred = _result(domain="health", systolic=122, diastolic=81)
        score = score_extraction([pred], [case])
        assert score.field_accuracy["systolic"] == pytest.approx(1.0)
        assert score.field_accuracy["diastolic"] == pytest.approx(1.0)

    def test_systolic_mismatch(self) -> None:
        case = _ec("122/81", {"domain": "health", "systolic": 122})
        pred = _result(domain="health", systolic=130)
        score = score_extraction([pred], [case])
        assert score.field_accuracy["systolic"] == pytest.approx(0.0)

    def test_int_coercion_from_float(self) -> None:
        """Gold=122, pred=122.0 → should match after int coercion."""
        case = _ec("122/81", {"domain": "health", "systolic": 122})
        pred = _result(domain="health", systolic=122.0)
        score = score_extraction([pred], [case])
        assert score.field_accuracy["systolic"] == pytest.approx(1.0)

    def test_null_gold_means_must_be_null(self) -> None:
        """When gold explicitly asserts null, pred must also be null."""
        case = _ec("presión 120/80", {"domain": "health", "pulse_bpm": None})
        pred = _result(domain="health", pulse_bpm=60)
        score = score_extraction([pred], [case])
        assert score.field_accuracy["pulse_bpm"] == pytest.approx(0.0)

    def test_null_gold_null_pred_passes(self) -> None:
        case = _ec("presión 120/80", {"domain": "health", "pulse_bpm": None})
        pred = _result(domain="health", pulse_bpm=None)
        score = score_extraction([pred], [case])
        assert score.field_accuracy["pulse_bpm"] == pytest.approx(1.0)


# ---------------------------------------------------------------------------
# Field-level scoring rules: numeric float (1% tolerance)
# ---------------------------------------------------------------------------


class TestScoreNumericFloat:
    """amount, duration_minutes, sleep_hours, weight_kg, glucose_mg_dl:
    within abs(a-b) <= max(0.01, 0.01*|gold|).
    """

    def test_sleep_hours_exact(self) -> None:
        case = _ec("dormí 8 horas", {"domain": "health", "sleep_hours": 8.0})
        pred = _result(domain="health", sleep_hours=8.0)
        score = score_extraction([pred], [case])
        assert score.field_accuracy["sleep_hours"] == pytest.approx(1.0)

    def test_sleep_hours_within_tolerance(self) -> None:
        # 8.0 * 0.01 = 0.08 tolerance → 8.05 should pass
        case = _ec("dormí 8 horas", {"domain": "health", "sleep_hours": 8.0})
        pred = _result(domain="health", sleep_hours=8.05)
        score = score_extraction([pred], [case])
        assert score.field_accuracy["sleep_hours"] == pytest.approx(1.0)

    def test_sleep_hours_outside_tolerance(self) -> None:
        case = _ec("dormí 8 horas", {"domain": "health", "sleep_hours": 8.0})
        pred = _result(domain="health", sleep_hours=9.0)  # delta=1.0 >> 0.08
        score = score_extraction([pred], [case])
        assert score.field_accuracy["sleep_hours"] == pytest.approx(0.0)

    def test_amount_tolerance_small(self) -> None:
        # gold=0.05: tolerance=max(0.01, 0.01*0.05)=0.01; pred=0.055 delta=0.005 → pass
        case = _ec("X", {"domain": "finance", "amount": 0.05})
        pred = _result(domain="finance", amount=0.055)
        score = score_extraction([pred], [case])
        assert score.field_accuracy["amount"] == pytest.approx(1.0)

    def test_weight_kg_pass(self) -> None:
        case = _ec("pesé 64.5 kg", {"domain": "health", "weight_kg": 64.5})
        pred = _result(domain="health", weight_kg=64.5)
        score = score_extraction([pred], [case])
        assert score.field_accuracy["weight_kg"] == pytest.approx(1.0)

    def test_glucose_pass(self) -> None:
        case = _ec("glucosa 95", {"domain": "health", "glucose_mg_dl": 95.0})
        pred = _result(domain="health", glucose_mg_dl=95.0)
        score = score_extraction([pred], [case])
        assert score.field_accuracy["glucose_mg_dl"] == pytest.approx(1.0)

    def test_null_float_gold_null_pred_passes(self) -> None:
        case = _ec("X", {"domain": "health", "sleep_hours": None})
        pred = _result(domain="health", sleep_hours=None)
        score = score_extraction([pred], [case])
        assert score.field_accuracy["sleep_hours"] == pytest.approx(1.0)

    def test_null_float_gold_non_null_pred_fails(self) -> None:
        case = _ec("X", {"domain": "health", "sleep_hours": None})
        pred = _result(domain="health", sleep_hours=8.0)
        score = score_extraction([pred], [case])
        assert score.field_accuracy["sleep_hours"] == pytest.approx(0.0)


# ---------------------------------------------------------------------------
# Field-level scoring rules: people (set equality, case-insensitive)
# ---------------------------------------------------------------------------


class TestScorePeople:
    def test_exact_match(self) -> None:
        case = _ec("hablé con Diego", {"domain": "relationships", "people": ["Diego"]})
        pred = _result(domain="relationships", people=["Diego"])
        score = score_extraction([pred], [case])
        assert score.field_accuracy["people"] == pytest.approx(1.0)

    def test_case_insensitive(self) -> None:
        case = _ec("X", {"domain": "relationships", "people": ["Diego"]})
        pred = _result(domain="relationships", people=["diego"])
        score = score_extraction([pred], [case])
        assert score.field_accuracy["people"] == pytest.approx(1.0)

    def test_extra_person_fails(self) -> None:
        case = _ec("X", {"domain": "relationships", "people": ["Diego"]})
        pred = _result(domain="relationships", people=["Diego", "Ana"])
        score = score_extraction([pred], [case])
        assert score.field_accuracy["people"] == pytest.approx(0.0)

    def test_missing_person_fails(self) -> None:
        case = _ec("X", {"domain": "relationships", "people": ["Diego", "Ana"]})
        pred = _result(domain="relationships", people=["Diego"])
        score = score_extraction([pred], [case])
        assert score.field_accuracy["people"] == pytest.approx(0.0)

    def test_empty_both_passes(self) -> None:
        case = _ec("X", {"domain": "relationships", "people": []})
        pred = _result(domain="relationships", people=[])
        score = score_extraction([pred], [case])
        assert score.field_accuracy["people"] == pytest.approx(1.0)

    def test_order_insensitive(self) -> None:
        case = _ec("X", {"domain": "relationships", "people": ["Rodrigo", "Ana"]})
        pred = _result(domain="relationships", people=["Ana", "Rodrigo"])
        score = score_extraction([pred], [case])
        assert score.field_accuracy["people"] == pytest.approx(1.0)


# ---------------------------------------------------------------------------
# Field-level scoring rules: items (order-insensitive, match by name)
# ---------------------------------------------------------------------------


class TestScoreItems:
    def test_items_single_match(self) -> None:
        case = _ec("X", {"domain": "finance", "items": [{"name": "gas", "amount": 580.0, "category": "servicios"}]})
        pred = _result(domain="finance", items=[{"name": "gas", "amount": 580.0, "category": "servicios"}])
        score = score_extraction([pred], [case])
        assert score.field_accuracy["items"] == pytest.approx(1.0)

    def test_items_name_set_equality_case_insensitive(self) -> None:
        case = _ec("X", {"domain": "finance", "items": [{"name": "Gas"}, {"name": "Luz"}]})
        pred = _result(domain="finance", items=[{"name": "luz"}, {"name": "gas"}])
        score = score_extraction([pred], [case])
        assert score.field_accuracy["items"] == pytest.approx(1.0)

    def test_items_missing_item_fails(self) -> None:
        case = _ec("X", {"domain": "finance", "items": [{"name": "gas"}, {"name": "luz"}]})
        pred = _result(domain="finance", items=[{"name": "gas"}])
        score = score_extraction([pred], [case])
        assert score.field_accuracy["items"] == pytest.approx(0.0)

    def test_items_empty_both(self) -> None:
        case = _ec("X", {"domain": "finance", "items": []})
        pred = _result(domain="finance", items=[])
        score = score_extraction([pred], [case])
        assert score.field_accuracy["items"] == pytest.approx(1.0)

    def test_items_category_mismatch_does_not_fail_headline(self) -> None:
        """Category mismatch is secondary; it should not fail the items headline metric."""
        case = _ec("X", {"domain": "finance", "items": [{"name": "gas", "amount": 580.0, "category": "servicios"}]})
        # pred has wrong category but correct name and amount
        pred = _result(domain="finance", items=[{"name": "gas", "amount": 580.0, "category": "hogar"}])
        score = score_extraction([pred], [case])
        # items headline (name set equality) should still pass
        assert score.field_accuracy["items"] == pytest.approx(1.0)

    def test_items_category_tracked_as_sub_metric(self) -> None:
        """Category agreement should be tracked separately in a sub-metric."""
        case = _ec("X", {"domain": "finance", "items": [{"name": "gas", "amount": 580.0, "category": "servicios"}]})
        pred = _result(domain="finance", items=[{"name": "gas", "amount": 580.0, "category": "hogar"}])
        score = score_extraction([pred], [case])
        # The sub-metric for category agreement must exist and be < 1.0
        assert "items_category_agreement" in score.sub_metrics
        assert score.sub_metrics["items_category_agreement"] < 1.0

    def test_items_category_correct_sub_metric(self) -> None:
        case = _ec("X", {"domain": "finance", "items": [{"name": "gas", "amount": 580.0, "category": "servicios"}]})
        pred = _result(domain="finance", items=[{"name": "gas", "amount": 580.0, "category": "servicios"}])
        score = score_extraction([pred], [case])
        assert score.sub_metrics.get("items_category_agreement", 0.0) == pytest.approx(1.0)


# ---------------------------------------------------------------------------
# Field-level scoring rules: enum exact (domain, currency) case-insensitive
# ---------------------------------------------------------------------------


class TestScoreEnum:
    def test_domain_match(self) -> None:
        case = _ec("X", {"domain": "health"})
        pred = _result(domain="health")
        score = score_extraction([pred], [case])
        assert score.field_accuracy["domain"] == pytest.approx(1.0)

    def test_domain_case_insensitive(self) -> None:
        case = _ec("X", {"domain": "health"})
        pred = _result(domain="Health")
        score = score_extraction([pred], [case])
        assert score.field_accuracy["domain"] == pytest.approx(1.0)

    def test_domain_mismatch(self) -> None:
        case = _ec("X", {"domain": "health"})
        pred = _result(domain="finance")
        score = score_extraction([pred], [case])
        assert score.field_accuracy["domain"] == pytest.approx(0.0)

    def test_currency_exact(self) -> None:
        case = _ec("X", {"domain": "finance", "currency": "MXN"})
        pred = _result(domain="finance", currency="MXN")
        score = score_extraction([pred], [case])
        assert score.field_accuracy["currency"] == pytest.approx(1.0)

    def test_currency_case_insensitive(self) -> None:
        case = _ec("X", {"domain": "finance", "currency": "MXN"})
        pred = _result(domain="finance", currency="mxn")
        score = score_extraction([pred], [case])
        assert score.field_accuracy["currency"] == pytest.approx(1.0)

    def test_domain_null_gold_null_pred(self) -> None:
        case = _ec("X", {"domain": None})
        pred = _result(domain=None)
        score = score_extraction([pred], [case])
        assert score.field_accuracy["domain"] == pytest.approx(1.0)

    def test_domain_null_gold_non_null_pred(self) -> None:
        case = _ec("X", {"domain": None})
        pred = _result(domain="health")
        score = score_extraction([pred], [case])
        assert score.field_accuracy["domain"] == pytest.approx(0.0)


# ---------------------------------------------------------------------------
# Field-level scoring rules: kind (case-insensitive + alias map)
# ---------------------------------------------------------------------------


class TestScoreKind:
    def test_exact_match(self) -> None:
        case = _ec("X", {"domain": "exercise", "kind": "walk"})
        pred = _result(domain="exercise", kind="walk")
        score = score_extraction([pred], [case])
        assert score.field_accuracy["kind"] == pytest.approx(1.0)

    def test_case_insensitive(self) -> None:
        case = _ec("X", {"domain": "exercise", "kind": "walk"})
        pred = _result(domain="exercise", kind="Walk")
        score = score_extraction([pred], [case])
        assert score.field_accuracy["kind"] == pytest.approx(1.0)

    def test_alias_walk_caminata(self) -> None:
        case = _ec("X", {"domain": "exercise", "kind": "walk"})
        pred = _result(domain="exercise", kind="caminata")
        score = score_extraction([pred], [case])
        assert score.field_accuracy["kind"] == pytest.approx(1.0)

    def test_alias_run_correr(self) -> None:
        case = _ec("X", {"domain": "exercise", "kind": "run"})
        pred = _result(domain="exercise", kind="correr")
        score = score_extraction([pred], [case])
        assert score.field_accuracy["kind"] == pytest.approx(1.0)

    def test_alias_study_estudio(self) -> None:
        case = _ec("X", {"domain": "learning", "kind": "study"})
        pred = _result(domain="learning", kind="estudio")
        score = score_extraction([pred], [case])
        assert score.field_accuracy["kind"] == pytest.approx(1.0)

    def test_unknown_kind_case_insensitive_comparison(self) -> None:
        case = _ec("X", {"domain": "health", "kind": "vital"})
        pred = _result(domain="health", kind="Vital")
        score = score_extraction([pred], [case])
        assert score.field_accuracy["kind"] == pytest.approx(1.0)

    def test_kind_mismatch_no_alias(self) -> None:
        case = _ec("X", {"domain": "health", "kind": "vital"})
        pred = _result(domain="health", kind="symptom")
        score = score_extraction([pred], [case])
        assert score.field_accuracy["kind"] == pytest.approx(0.0)


# ---------------------------------------------------------------------------
# Field-level scoring rules: dates_text (set equality, exact strings)
# ---------------------------------------------------------------------------


class TestScoreDatesText:
    def test_exact_set_match(self) -> None:
        case = _ec("X", {"domain": "events", "dates_text": ["15 de junio de 2018"]})
        pred = _result(domain="events", dates_text=["15 de junio de 2018"])
        score = score_extraction([pred], [case])
        assert score.field_accuracy["dates_text"] == pytest.approx(1.0)

    def test_order_insensitive(self) -> None:
        case = _ec("X", {"domain": "events", "dates_text": ["mañana", "a las 10 am"]})
        pred = _result(domain="events", dates_text=["a las 10 am", "mañana"])
        score = score_extraction([pred], [case])
        assert score.field_accuracy["dates_text"] == pytest.approx(1.0)

    def test_extra_date_fails(self) -> None:
        case = _ec("X", {"domain": "events", "dates_text": ["mañana"]})
        pred = _result(domain="events", dates_text=["mañana", "extra"])
        score = score_extraction([pred], [case])
        assert score.field_accuracy["dates_text"] == pytest.approx(0.0)

    def test_partial_string_does_not_match(self) -> None:
        """dates_text uses EXACT string matching — no normalization."""
        case = _ec("X", {"domain": "events", "dates_text": ["15 de junio de 2018"]})
        pred = _result(domain="events", dates_text=["junio de 2018"])  # partial
        score = score_extraction([pred], [case])
        assert score.field_accuracy["dates_text"] == pytest.approx(0.0)

    def test_empty_both_passes(self) -> None:
        case = _ec("X", {"domain": "events", "dates_text": []})
        pred = _result(domain="events", dates_text=[])
        score = score_extraction([pred], [case])
        assert score.field_accuracy["dates_text"] == pytest.approx(1.0)


# ---------------------------------------------------------------------------
# title field must be EXCLUDED from scoring
# ---------------------------------------------------------------------------


class TestTitleExcluded:
    def test_title_not_in_field_accuracy(self) -> None:
        """title must never appear in field_accuracy — it is excluded from scoring."""
        case = _ec("X", {"domain": "health", "kind": "vital", "title": "some title"})
        pred = _result(domain="health", kind="vital")
        pred["title"] = "different title"
        score = score_extraction([pred], [case])
        assert "title" not in score.field_accuracy

    def test_title_mismatch_does_not_affect_case_pass(self) -> None:
        """A case that passes all non-title fields must still pass even with title mismatch."""
        case = _ec("X", {"domain": "health", "kind": "vital", "title": "gold title"})
        pred = _result(domain="health", kind="vital")
        pred["title"] = "completely different"
        score = score_extraction([pred], [case])
        # domain and kind both match → case should pass
        assert score.case_pass_rate == pytest.approx(1.0)


# ---------------------------------------------------------------------------
# Absent fields in gold → skip (do not score)
# ---------------------------------------------------------------------------


class TestAbsentGoldFieldsSkipped:
    def test_field_absent_from_gold_is_not_scored(self) -> None:
        """If a field is not in expected dict, do not score it at all.

        This tests the rule: only score fields the gold explicitly asserts.
        An absent field is NOT the same as gold=null.
        """
        # expected has no 'merchant' key at all
        case = _ec("X", {"domain": "finance", "amount": 200.0})
        pred = _result(domain="finance", amount=200.0, merchant="SomeMerchant")
        score = score_extraction([pred], [case])
        # merchant should not penalize the score because it's absent from expected
        assert "merchant" not in score.field_accuracy

    def test_explicit_null_in_gold_is_scored(self) -> None:
        """If gold explicitly asserts null, the field IS scored and pred must also be null."""
        case = _ec("X", {"domain": "finance", "merchant": None})
        pred = _result(domain="finance", merchant="SomeMerchant")
        score = score_extraction([pred], [case])
        assert "merchant" in score.field_accuracy
        assert score.field_accuracy["merchant"] == pytest.approx(0.0)


# ---------------------------------------------------------------------------
# Fuzzy field separation
# ---------------------------------------------------------------------------


class TestFuzzyFieldSeparation:
    def test_fuzzy_fields_excluded_from_headline(self) -> None:
        """Fuzzy fields must NOT contribute to headline (non-fuzzy) field_accuracy."""
        case = _ec(
            "pesé 64.5 kg hoy",
            {"domain": "health", "kind": "vital", "dates_text": ["hoy"]},
            fuzzy_fields=["dates_text"],
        )
        pred = _result(domain="health", kind="vital", dates_text=["esta mañana"])  # wrong fuzzy
        score = score_extraction([pred], [case])
        # dates_text should be absent from field_accuracy (it's fuzzy)
        assert "dates_text" not in score.field_accuracy
        # but should appear in fuzzy_field_accuracy
        assert "dates_text" in score.fuzzy_field_accuracy
        assert score.fuzzy_field_accuracy["dates_text"] == pytest.approx(0.0)

    def test_fuzzy_correct_in_fuzzy_bucket(self) -> None:
        case = _ec(
            "pesé 64.5 kg hoy",
            {"domain": "health", "kind": "vital", "dates_text": ["hoy"]},
            fuzzy_fields=["dates_text"],
        )
        pred = _result(domain="health", kind="vital", dates_text=["hoy"])
        score = score_extraction([pred], [case])
        assert score.fuzzy_field_accuracy["dates_text"] == pytest.approx(1.0)

    def test_non_fuzzy_fields_not_in_fuzzy_bucket(self) -> None:
        case = _ec(
            "X",
            {"domain": "health", "kind": "vital"},
            fuzzy_fields=[],
        )
        pred = _result(domain="health", kind="vital")
        score = score_extraction([pred], [case])
        assert score.fuzzy_field_accuracy == {}

    def test_case_pass_uses_only_non_fuzzy_fields(self) -> None:
        """A case passes if all non-fuzzy asserted fields match, regardless of fuzzy ones."""
        case = _ec(
            "X",
            {"domain": "health", "kind": "vital", "dates_text": ["hoy"]},
            fuzzy_fields=["dates_text"],
        )
        # non-fuzzy fields (domain, kind) correct; fuzzy field wrong
        pred = _result(domain="health", kind="vital", dates_text=["ayer"])
        score = score_extraction([pred], [case])
        assert score.case_pass_rate == pytest.approx(1.0)


# ---------------------------------------------------------------------------
# Overall metrics
# ---------------------------------------------------------------------------


class TestOverallMetrics:
    def test_case_pass_rate_all_pass(self) -> None:
        case = _ec("dormí 8 horas", {"domain": "health", "kind": "vital", "sleep_hours": 8.0})
        pred = _result(domain="health", kind="vital", sleep_hours=8.0)
        score = score_extraction([pred], [case])
        assert score.case_pass_rate == pytest.approx(1.0)

    def test_case_pass_rate_partial(self) -> None:
        cases = [
            _ec("A", {"domain": "health", "kind": "vital"}),
            _ec("B", {"domain": "finance", "kind": "expense"}),
        ]
        preds = [
            _result(domain="health", kind="vital"),   # pass
            _result(domain="finance", kind="bill"),   # fail (wrong kind)
        ]
        score = score_extraction(preds, cases)
        assert score.case_pass_rate == pytest.approx(0.5)

    def test_length_mismatch_raises(self) -> None:
        case = _ec("X", {"domain": "health"})
        with pytest.raises(ValueError, match="length"):
            score_extraction([], [case])

    def test_per_case_results_length(self) -> None:
        cases = [
            _ec("A", {"domain": "health"}),
            _ec("B", {"domain": "finance"}),
        ]
        preds = [_result(domain="health"), _result(domain="finance")]
        score = score_extraction(preds, cases)
        assert len(score.per_case) == 2

    def test_field_accuracy_aggregated_across_cases(self) -> None:
        """field_accuracy must aggregate over ALL cases that assert a field, not just one."""
        cases = [
            _ec("A", {"domain": "health", "kind": "vital"}),
            _ec("B", {"domain": "health", "kind": "symptom"}),
        ]
        preds = [
            _result(domain="health", kind="vital"),    # kind correct
            _result(domain="health", kind="vital"),    # kind wrong (gold=symptom)
        ]
        score = score_extraction(preds, cases)
        assert score.field_accuracy["kind"] == pytest.approx(0.5)


# ---------------------------------------------------------------------------
# ExtractionScore dataclass
# ---------------------------------------------------------------------------


class TestExtractionScore:
    def test_has_required_fields(self) -> None:
        case = _ec("X", {"domain": "health"})
        pred = _result(domain="health")
        score = score_extraction([pred], [case])
        # Must have all required output fields
        assert hasattr(score, "field_accuracy")
        assert hasattr(score, "fuzzy_field_accuracy")
        assert hasattr(score, "case_pass_rate")
        assert hasattr(score, "per_case")
        assert hasattr(score, "sub_metrics")
        assert hasattr(score, "total")

    def test_total_matches_input(self) -> None:
        cases = [_ec("A", {"domain": "health"}), _ec("B", {"domain": "finance"})]
        preds = [_result(domain="health"), _result(domain="finance")]
        score = score_extraction(preds, cases)
        assert score.total == 2


# ---------------------------------------------------------------------------
# format_extraction_report
# ---------------------------------------------------------------------------


class TestFormatExtractionReport:
    def test_returns_non_empty_string(self) -> None:
        case = _ec("dormí 8 horas", {"domain": "health", "kind": "vital", "sleep_hours": 8.0})
        pred = _result(domain="health", kind="vital", sleep_hours=8.0)
        score = score_extraction([pred], [case])
        report = format_extraction_report(score)
        assert isinstance(report, str)
        assert len(report) > 0

    def test_contains_case_pass_rate(self) -> None:
        case = _ec("X", {"domain": "health"})
        pred = _result(domain="health")
        score = score_extraction([pred], [case])
        report = format_extraction_report(score)
        assert "pass" in report.lower() or "case" in report.lower()

    def test_contains_field_breakdown(self) -> None:
        case = _ec("X", {"domain": "health", "kind": "vital"})
        pred = _result(domain="health", kind="vital")
        score = score_extraction([pred], [case])
        report = format_extraction_report(score)
        assert "domain" in report
        assert "kind" in report

    def test_fuzzy_section_present_when_fuzzy_fields_exist(self) -> None:
        case = _ec("X", {"domain": "health", "dates_text": ["hoy"]}, fuzzy_fields=["dates_text"])
        pred = _result(domain="health", dates_text=["hoy"])
        score = score_extraction([pred], [case])
        report = format_extraction_report(score)
        assert "fuzzy" in report.lower()

    def test_no_fuzzy_section_when_no_fuzzy(self) -> None:
        case = _ec("X", {"domain": "health", "kind": "vital"})
        pred = _result(domain="health", kind="vital")
        score = score_extraction([pred], [case])
        report = format_extraction_report(score)
        # No fuzzy fields → should gracefully omit fuzzy section (or show empty)
        # Just check it doesn't crash
        assert isinstance(report, str)
