"""Tests for the nano-agent eval scoring layer (lifeos.agents.eval.scoring).

All tests are PURE — no live extractor, no network, no filesystem side-effects
beyond tmp_path. This module must remain importable even when the nano
llama-server is offline.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from lifeos.agents.eval.scoring import (
    DomainScore,
    GoldenCase,
    format_report,
    format_segmented_report,
    load_golden_set,
    score_by_layer,
    score_domain,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def simple_golden_set() -> list[GoldenCase]:
    return [
        GoldenCase(text="Gasté 500 en el super", expected_domain="finance"),
        GoldenCase(text="Corrí 5km en el parque", expected_domain="exercise"),
        GoldenCase(text="Hablé con Diego sobre el trabajo", expected_domain="relationships"),
        GoldenCase(text="ok", expected_domain=None, note="very short — trap case"),
    ]


# ---------------------------------------------------------------------------
# GoldenCase dataclass
# ---------------------------------------------------------------------------


class TestGoldenCase:
    def test_basic_fields(self) -> None:
        gc = GoldenCase(text="hello", expected_domain="finance")
        assert gc.text == "hello"
        assert gc.expected_domain == "finance"
        assert gc.note == ""

    def test_note_optional(self) -> None:
        gc = GoldenCase(text="x", expected_domain=None, note="trap")
        assert gc.note == "trap"

    def test_expected_domain_none_allowed(self) -> None:
        gc = GoldenCase(text="...", expected_domain=None)
        assert gc.expected_domain is None


# ---------------------------------------------------------------------------
# load_golden_set
# ---------------------------------------------------------------------------


class TestLoadGoldenSet:
    def test_loads_valid_jsonl(self, tmp_path: Path) -> None:
        lines = [
            json.dumps({"text": "Gasté 200 pesos", "expected_domain": "finance"}),
            json.dumps({"text": "Corrí 10km", "expected_domain": "exercise"}),
        ]
        f = tmp_path / "set.jsonl"
        f.write_text("\n".join(lines))
        result = load_golden_set(f)
        assert len(result) == 2
        assert result[0].text == "Gasté 200 pesos"
        assert result[0].expected_domain == "finance"
        assert result[1].expected_domain == "exercise"

    def test_skips_blank_lines(self, tmp_path: Path) -> None:
        content = (
            json.dumps({"text": "A", "expected_domain": "health"}) + "\n"
            "\n"
            "   \n"
            + json.dumps({"text": "B", "expected_domain": "learning"}) + "\n"
        )
        f = tmp_path / "set.jsonl"
        f.write_text(content)
        result = load_golden_set(f)
        assert len(result) == 2

    def test_skips_comment_lines_slash(self, tmp_path: Path) -> None:
        content = (
            "// This is a comment\n"
            + json.dumps({"text": "A", "expected_domain": "health"}) + "\n"
            "// another comment\n"
            + json.dumps({"text": "B", "expected_domain": None}) + "\n"
        )
        f = tmp_path / "set.jsonl"
        f.write_text(content)
        result = load_golden_set(f)
        assert len(result) == 2

    def test_skips_comment_lines_hash(self, tmp_path: Path) -> None:
        content = (
            "# header comment\n"
            + json.dumps({"text": "A", "expected_domain": "events"}) + "\n"
        )
        f = tmp_path / "set.jsonl"
        f.write_text(content)
        result = load_golden_set(f)
        assert len(result) == 1

    def test_malformed_line_raises_value_error(self, tmp_path: Path) -> None:
        content = (
            json.dumps({"text": "A", "expected_domain": "health"}) + "\n"
            "this is not json\n"
        )
        f = tmp_path / "set.jsonl"
        f.write_text(content)
        with pytest.raises(ValueError, match="line 2"):
            load_golden_set(f)

    def test_optional_note_field(self, tmp_path: Path) -> None:
        content = json.dumps(
            {"text": "A", "expected_domain": "finance", "note": "trap case"}
        )
        f = tmp_path / "set.jsonl"
        f.write_text(content)
        result = load_golden_set(f)
        assert result[0].note == "trap case"

    def test_missing_note_defaults_empty_string(self, tmp_path: Path) -> None:
        content = json.dumps({"text": "A", "expected_domain": "exercise"})
        f = tmp_path / "set.jsonl"
        f.write_text(content)
        result = load_golden_set(f)
        assert result[0].note == ""

    def test_null_expected_domain_loaded_as_none(self, tmp_path: Path) -> None:
        content = json.dumps({"text": "X", "expected_domain": None})
        f = tmp_path / "set.jsonl"
        f.write_text(content)
        result = load_golden_set(f)
        assert result[0].expected_domain is None

    def test_accepts_path_and_str(self, tmp_path: Path) -> None:
        content = json.dumps({"text": "Y", "expected_domain": "health"})
        f = tmp_path / "set.jsonl"
        f.write_text(content)
        # both Path and str should work
        r1 = load_golden_set(f)
        r2 = load_golden_set(str(f))
        assert len(r1) == len(r2) == 1


# ---------------------------------------------------------------------------
# score_domain — perfect score
# ---------------------------------------------------------------------------


class TestScoreDomainPerfect:
    def test_perfect_predictions_accuracy_one(
        self, simple_golden_set: list[GoldenCase]
    ) -> None:
        preds = ["finance", "exercise", "relationships", None]
        score = score_domain(preds, simple_golden_set)
        assert score.accuracy == pytest.approx(1.0)

    def test_perfect_per_class_f1(
        self, simple_golden_set: list[GoldenCase]
    ) -> None:
        preds = ["finance", "exercise", "relationships", None]
        score = score_domain(preds, simple_golden_set)
        for cls, metrics in score.per_class.items():
            assert metrics["f1"] == pytest.approx(1.0), f"class {cls} f1 should be 1.0"


# ---------------------------------------------------------------------------
# score_domain — all wrong
# ---------------------------------------------------------------------------


class TestScoreDomainAllWrong:
    def test_all_wrong_accuracy_zero(
        self, simple_golden_set: list[GoldenCase]
    ) -> None:
        # all wrong — pick wrong classes for each
        preds = ["exercise", "finance", "finance", "finance"]
        score = score_domain(preds, simple_golden_set)
        assert score.accuracy == pytest.approx(0.0)


# ---------------------------------------------------------------------------
# score_domain — partial
# ---------------------------------------------------------------------------


class TestScoreDomainPartial:
    def test_half_correct(self, simple_golden_set: list[GoldenCase]) -> None:
        # first 2 correct, last 2 wrong
        preds = ["finance", "exercise", "finance", "finance"]
        score = score_domain(preds, simple_golden_set)
        assert score.accuracy == pytest.approx(0.5)

    def test_total_cases_matches_input(
        self, simple_golden_set: list[GoldenCase]
    ) -> None:
        preds = ["finance", "exercise", "finance", "finance"]
        score = score_domain(preds, simple_golden_set)
        assert score.total == 4


# ---------------------------------------------------------------------------
# score_domain — null class
# ---------------------------------------------------------------------------


class TestScoreDomainNullClass:
    def test_null_class_treated_as_real_label(self) -> None:
        golds = [
            GoldenCase(text="ok", expected_domain=None),
            GoldenCase(text="hmm", expected_domain=None),
            GoldenCase(text="Corrí", expected_domain="exercise"),
        ]
        preds = [None, None, "exercise"]
        score = score_domain(preds, golds)
        assert score.accuracy == pytest.approx(1.0)
        assert "null" in score.per_class

    def test_null_predicted_but_gold_not_null(self) -> None:
        golds = [GoldenCase(text="Corrí 5km", expected_domain="exercise")]
        preds = [None]
        score = score_domain(preds, golds)
        assert score.accuracy == pytest.approx(0.0)


# ---------------------------------------------------------------------------
# score_domain — zero gold instances (no division by zero)
# ---------------------------------------------------------------------------


class TestScoreDomainNoGoldInstances:
    def test_class_with_zero_golds_no_crash(self) -> None:
        """A class that appears in predictions but has zero gold instances
        must not raise ZeroDivisionError."""
        golds = [GoldenCase(text="Gasté 100", expected_domain="finance")]
        preds = ["exercise"]  # predicted exercise, gold is finance → exercise has 0 golds
        score = score_domain(preds, golds)
        assert "exercise" in score.per_class
        # recall should be 0 or NaN-safe value (0 by convention)
        assert score.per_class["exercise"]["recall"] == pytest.approx(0.0)

    def test_class_with_zero_predictions_no_crash(self) -> None:
        """A class that has gold instances but is never predicted."""
        golds = [
            GoldenCase(text="Corrí", expected_domain="exercise"),
            GoldenCase(text="Gasté", expected_domain="finance"),
        ]
        preds = ["finance", "finance"]
        score = score_domain(preds, golds)
        assert score.per_class["exercise"]["precision"] == pytest.approx(0.0)
        assert score.per_class["exercise"]["f1"] == pytest.approx(0.0)


# ---------------------------------------------------------------------------
# Precision / recall / F1 math on a known matrix
# ---------------------------------------------------------------------------


class TestPrecisionRecallF1Math:
    """Manual ground truth:
      gold:  finance, finance, exercise, exercise, finance
      pred:  finance, exercise, exercise, finance,  finance

      finance:  TP=2, FP=1(pred finance for exercise), FN=1(pred exercise for finance)
        precision = 2/3, recall = 2/3, f1 = 2/3
      exercise: TP=1, FP=1(pred exercise for finance), FN=1(pred finance for exercise)
        precision = 1/2, recall = 1/2, f1 = 1/2
      accuracy = 3/5 = 0.6
    """

    @pytest.fixture()
    def known_score(self) -> DomainScore:
        golds = [
            GoldenCase(text="a", expected_domain="finance"),
            GoldenCase(text="b", expected_domain="finance"),
            GoldenCase(text="c", expected_domain="exercise"),
            GoldenCase(text="d", expected_domain="exercise"),
            GoldenCase(text="e", expected_domain="finance"),
        ]
        preds = ["finance", "exercise", "exercise", "finance", "finance"]
        return score_domain(preds, golds)

    def test_accuracy(self, known_score: DomainScore) -> None:
        assert known_score.accuracy == pytest.approx(3 / 5)

    def test_finance_precision(self, known_score: DomainScore) -> None:
        assert known_score.per_class["finance"]["precision"] == pytest.approx(2 / 3)

    def test_finance_recall(self, known_score: DomainScore) -> None:
        assert known_score.per_class["finance"]["recall"] == pytest.approx(2 / 3)

    def test_finance_f1(self, known_score: DomainScore) -> None:
        assert known_score.per_class["finance"]["f1"] == pytest.approx(2 / 3)

    def test_exercise_precision(self, known_score: DomainScore) -> None:
        assert known_score.per_class["exercise"]["precision"] == pytest.approx(1 / 2)

    def test_exercise_recall(self, known_score: DomainScore) -> None:
        assert known_score.per_class["exercise"]["recall"] == pytest.approx(1 / 2)

    def test_exercise_f1(self, known_score: DomainScore) -> None:
        assert known_score.per_class["exercise"]["f1"] == pytest.approx(1 / 2)

    def test_confusion_matrix_entries(self, known_score: DomainScore) -> None:
        # finance predicted as exercise: 1 case (text b)
        assert known_score.confusion[("finance", "exercise")] == 1
        # exercise predicted as finance: 1 case (text d)
        assert known_score.confusion[("exercise", "finance")] == 1


# ---------------------------------------------------------------------------
# format_report
# ---------------------------------------------------------------------------


class TestFormatReport:
    def test_returns_non_empty_string(
        self, simple_golden_set: list[GoldenCase]
    ) -> None:
        preds = ["finance", "exercise", "relationships", None]
        score = score_domain(preds, simple_golden_set)
        report = format_report(score)
        assert isinstance(report, str)
        assert len(report) > 0

    def test_report_contains_accuracy(
        self, simple_golden_set: list[GoldenCase]
    ) -> None:
        preds = ["finance", "exercise", "relationships", None]
        score = score_domain(preds, simple_golden_set)
        report = format_report(score)
        assert "accuracy" in report.lower() or "Accuracy" in report

    def test_report_contains_class_names(
        self, simple_golden_set: list[GoldenCase]
    ) -> None:
        preds = ["finance", "exercise", "relationships", None]
        score = score_domain(preds, simple_golden_set)
        report = format_report(score)
        assert "finance" in report
        assert "exercise" in report


# ---------------------------------------------------------------------------
# GoldenCase — layer field
# ---------------------------------------------------------------------------


class TestGoldenCaseLayerField:
    def test_default_layer_is_nano(self) -> None:
        gc = GoldenCase(text="Corrí 5km", expected_domain="exercise")
        assert gc.layer == "nano"

    def test_layer_can_be_set_to_guard(self) -> None:
        gc = GoldenCase(text="ok", expected_domain=None, layer="guard")
        assert gc.layer == "guard"

    def test_layer_can_be_set_to_regex(self) -> None:
        gc = GoldenCase(text="Gasté 500", expected_domain="finance", layer="regex")
        assert gc.layer == "regex"

    def test_layer_can_be_set_to_nano(self) -> None:
        gc = GoldenCase(text="Me cobraron 230", expected_domain="finance", layer="nano")
        assert gc.layer == "nano"


# ---------------------------------------------------------------------------
# load_golden_set — layer field
# ---------------------------------------------------------------------------


class TestLoadGoldenSetLayerField:
    def test_loads_layer_field(self, tmp_path: Path) -> None:
        content = json.dumps(
            {"text": "Gasté 500", "expected_domain": "finance", "layer": "regex"}
        )
        f = tmp_path / "set.jsonl"
        f.write_text(content)
        result = load_golden_set(f)
        assert result[0].layer == "regex"

    def test_missing_layer_defaults_to_nano(self, tmp_path: Path) -> None:
        content = json.dumps({"text": "Corrí 5km", "expected_domain": "exercise"})
        f = tmp_path / "set.jsonl"
        f.write_text(content)
        result = load_golden_set(f)
        assert result[0].layer == "nano"

    def test_layer_guard_loaded(self, tmp_path: Path) -> None:
        content = json.dumps(
            {"text": "ok", "expected_domain": None, "layer": "guard"}
        )
        f = tmp_path / "set.jsonl"
        f.write_text(content)
        result = load_golden_set(f)
        assert result[0].layer == "guard"

    def test_mixed_layers_loaded_correctly(self, tmp_path: Path) -> None:
        lines = [
            json.dumps({"text": "A", "expected_domain": "finance", "layer": "regex"}),
            json.dumps({"text": "B", "expected_domain": None, "layer": "guard"}),
            json.dumps({"text": "C", "expected_domain": "exercise"}),
        ]
        f = tmp_path / "set.jsonl"
        f.write_text("\n".join(lines))
        result = load_golden_set(f)
        assert result[0].layer == "regex"
        assert result[1].layer == "guard"
        assert result[2].layer == "nano"  # default


# ---------------------------------------------------------------------------
# score_by_layer
# ---------------------------------------------------------------------------


@pytest.fixture()
def layered_golden_set() -> list[GoldenCase]:
    return [
        GoldenCase(text="Gasté 500", expected_domain="finance", layer="regex"),
        GoldenCase(text="Pagué 1000", expected_domain="finance", layer="regex"),
        GoldenCase(text="ok", expected_domain=None, layer="guard"),
        GoldenCase(text="si", expected_domain=None, layer="guard"),
        GoldenCase(text="Corrí 5km", expected_domain="exercise", layer="nano"),
        GoldenCase(text="Hablé con Diego", expected_domain="relationships", layer="nano"),
        GoldenCase(text="Me cobraron 230", expected_domain="finance", layer="nano"),
    ]


class TestScoreByLayer:
    def test_returns_dict_with_overall_key(
        self, layered_golden_set: list[GoldenCase]
    ) -> None:
        preds = ["finance", "finance", None, None, "exercise", "relationships", "finance"]
        result = score_by_layer(preds, layered_golden_set)
        assert "overall" in result

    def test_returns_per_layer_keys(
        self, layered_golden_set: list[GoldenCase]
    ) -> None:
        preds = ["finance", "finance", None, None, "exercise", "relationships", "finance"]
        result = score_by_layer(preds, layered_golden_set)
        assert "regex" in result
        assert "guard" in result
        assert "nano" in result

    def test_overall_score_matches_score_domain(
        self, layered_golden_set: list[GoldenCase]
    ) -> None:
        preds = ["finance", "finance", None, None, "exercise", "relationships", "finance"]
        result = score_by_layer(preds, layered_golden_set)
        expected = score_domain(preds, layered_golden_set)
        assert result["overall"].accuracy == pytest.approx(expected.accuracy)
        assert result["overall"].total == expected.total

    def test_regex_layer_accuracy(
        self, layered_golden_set: list[GoldenCase]
    ) -> None:
        # All regex cases correct
        preds = ["finance", "finance", None, None, "exercise", "relationships", "finance"]
        result = score_by_layer(preds, layered_golden_set)
        assert result["regex"].accuracy == pytest.approx(1.0)
        assert result["regex"].total == 2

    def test_guard_layer_accuracy(
        self, layered_golden_set: list[GoldenCase]
    ) -> None:
        preds = ["finance", "finance", None, None, "exercise", "relationships", "finance"]
        result = score_by_layer(preds, layered_golden_set)
        assert result["guard"].accuracy == pytest.approx(1.0)
        assert result["guard"].total == 2

    def test_nano_layer_accuracy(
        self, layered_golden_set: list[GoldenCase]
    ) -> None:
        preds = ["finance", "finance", None, None, "exercise", "relationships", "finance"]
        result = score_by_layer(preds, layered_golden_set)
        assert result["nano"].accuracy == pytest.approx(1.0)
        assert result["nano"].total == 3

    def test_nano_layer_partial_accuracy(
        self, layered_golden_set: list[GoldenCase]
    ) -> None:
        # nano case "Corrí 5km" predicted wrong
        preds = ["finance", "finance", None, None, "finance", "relationships", "finance"]
        result = score_by_layer(preds, layered_golden_set)
        assert result["nano"].accuracy == pytest.approx(2 / 3)

    def test_missing_layer_in_set_still_grouped(self, tmp_path: Path) -> None:
        """score_by_layer works even when some cases have layer='nano' by default."""
        golds = [
            GoldenCase(text="A", expected_domain="exercise"),  # default nano
            GoldenCase(text="B", expected_domain="exercise"),  # default nano
        ]
        preds = ["exercise", "finance"]
        result = score_by_layer(preds, golds)
        assert result["nano"].total == 2
        assert result["nano"].accuracy == pytest.approx(0.5)

    def test_length_mismatch_raises(
        self, layered_golden_set: list[GoldenCase]
    ) -> None:
        with pytest.raises(ValueError, match="length"):
            score_by_layer(["finance"], layered_golden_set)


# ---------------------------------------------------------------------------
# format_segmented_report
# ---------------------------------------------------------------------------


class TestFormatSegmentedReport:
    def test_returns_string(self, layered_golden_set: list[GoldenCase]) -> None:
        preds = ["finance", "finance", None, None, "exercise", "relationships", "finance"]
        scores = score_by_layer(preds, layered_golden_set)
        report = format_segmented_report(scores, layered_golden_set)
        assert isinstance(report, str)
        assert len(report) > 0

    def test_contains_raw_accuracy(self, layered_golden_set: list[GoldenCase]) -> None:
        preds = ["finance", "finance", None, None, "exercise", "relationships", "finance"]
        scores = score_by_layer(preds, layered_golden_set)
        report = format_segmented_report(scores, layered_golden_set)
        assert "overall" in report.lower() or "raw" in report.lower() or "Accuracy" in report

    def test_contains_nano_eligible_section(
        self, layered_golden_set: list[GoldenCase]
    ) -> None:
        preds = ["finance", "finance", None, None, "exercise", "relationships", "finance"]
        scores = score_by_layer(preds, layered_golden_set)
        report = format_segmented_report(scores, layered_golden_set)
        assert "nano" in report.lower()
        assert "eligible" in report.lower() or "nano" in report.lower()

    def test_contains_per_layer_counts(
        self, layered_golden_set: list[GoldenCase]
    ) -> None:
        preds = ["finance", "finance", None, None, "exercise", "relationships", "finance"]
        scores = score_by_layer(preds, layered_golden_set)
        report = format_segmented_report(scores, layered_golden_set)
        # Should mention each layer
        assert "regex" in report.lower()
        assert "guard" in report.lower()

    def test_nano_accuracy_prominently_labeled(
        self, layered_golden_set: list[GoldenCase]
    ) -> None:
        preds = ["finance", "finance", None, None, "exercise", "relationships", "finance"]
        scores = score_by_layer(preds, layered_golden_set)
        report = format_segmented_report(scores, layered_golden_set)
        # Nano-eligible accuracy must appear with a metric value
        assert "100.0%" in report or "100%" in report  # all nano correct in fixture
