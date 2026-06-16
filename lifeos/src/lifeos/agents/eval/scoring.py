"""Pure scoring utilities for the nano-agent domain-classification eval harness.

All functions in this module are PURE — no I/O, no network, no side-effects
beyond reading a file in ``load_golden_set`` / ``load_extraction_golden_set``.
They accept predictions from any system (nano extractor, regex baseline,
brain), so A/B comparisons are trivial.

Null domains are modelled as the string "null" internally so they participate
in per-class metrics like any other label. Callers and data files use Python
``None`` / JSON ``null``; the conversion happens at load/score boundaries.

Pipeline layers
---------------
The golden set annotates each case with a ``layer`` field that reflects which
production layer is responsible for handling the input:

``nano``
    The nano extractor is called and its prediction matters.  This is the
    primary layer and the one used for the *nano-eligible accuracy* metric.

``regex``
    The regex-based finance parser matches the text BEFORE the nano is ever
    called.  The nano's output is irrelevant for these cases in production.

``guard``
    A dashboard guard short-circuits before (or immediately after) the nano
    runs, so the nano's prediction has no effect.  Examples:
    - Text shorter than 12 chars → nano is never called.
    - Spirituality result with no title/kind on text < 20 chars → discarded.

Public API — domain classification:
    GoldenCase                       — dataclass for one labeled eval example
    DomainScore                      — dataclass holding all scoring outputs
    load_golden_set(path)            — read a .jsonl file into list[GoldenCase]
    score_domain(preds, golds)       -> DomainScore
    score_by_layer(preds, golds)     -> dict[str, DomainScore]
    format_report(score)             -> str
    format_segmented_report(scores, golds) -> str

Public API — extraction quality:
    ExtractionCase                   — dataclass for one extraction eval example
    ExtractionScore                  — dataclass holding all extraction scoring outputs
    load_extraction_golden_set(path) — read a .jsonl file into list[ExtractionCase]
    score_extraction(preds, cases)   -> ExtractionScore
    format_extraction_report(score)  -> str
"""

from __future__ import annotations

import json
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Union

# The sentinel string used internally for the None / "no-action" class.
_NULL_LABEL = "null"


@dataclass
class GoldenCase:
    """One labeled example in the golden evaluation set.

    Attributes:
        text: The input text to be classified.
        expected_domain: One of the valid LifeOS domains
            (``finance``, ``relationships``, ``exercise``, ``learning``,
            ``health``, ``events``, ``spirituality``) or ``None`` meaning
            no extraction should occur.
        note: Optional free-text annotation (e.g. "trap case — too short").
        layer: Which production pipeline layer handles this input.
            - ``"nano"``  — nano extractor is called and its output matters
              (default; backward-compatible with golden sets lacking the field).
            - ``"regex"`` — regex finance parser fires before nano; nano output
              is irrelevant in production for these cases.
            - ``"guard"`` — a dashboard guard short-circuits before the nano
              result reaches storage (too-short inputs, spirituality noise).
    """

    text: str
    expected_domain: str | None
    note: str = ""
    layer: str = "nano"


@dataclass
class DomainScore:
    """Scoring results for a single eval run.

    Attributes:
        accuracy: Fraction of predictions that exactly matched gold.
        total: Total number of cases evaluated.
        per_class: ``{label: {"precision": float, "recall": float, "f1": float}}``.
            The ``null`` class (no-extraction) is included when present.
        confusion: ``{(gold_label, pred_label): count}`` for all
            misclassified pairs. Correct predictions are NOT stored here.
    """

    accuracy: float
    total: int
    per_class: dict[str, dict[str, float]] = field(default_factory=dict)
    confusion: dict[tuple[str, str], int] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# I/O
# ---------------------------------------------------------------------------


def load_golden_set(path: Union[str, Path]) -> list[GoldenCase]:
    """Read a ``.jsonl`` file and return a list of :class:`GoldenCase`.

    Each non-blank, non-comment line must be a valid JSON object with at least:
      - ``text``: str
      - ``expected_domain``: str | null

    Optional fields:
      - ``note``:  str  (defaults to ``""``)
      - ``layer``: str  (defaults to ``"nano"`` — backward-compatible with sets
                   that predate the layer segmentation feature)

    Lines that start with ``//`` or ``#`` (after optional whitespace) are
    treated as comments and skipped, so you can annotate the golden-set file.
    Blank / whitespace-only lines are also skipped.

    Raises:
        ValueError: When a non-comment, non-blank line contains invalid JSON,
            citing the 1-based line number.
    """
    cases: list[GoldenCase] = []
    for lineno, raw in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), start=1):
        stripped = raw.strip()
        if not stripped:
            continue
        if stripped.startswith("//") or stripped.startswith("#"):
            continue
        try:
            obj = json.loads(stripped)
        except json.JSONDecodeError as exc:
            raise ValueError(
                f"line {lineno}: invalid JSON in golden-set file {path!r}: {exc}"
            ) from exc
        cases.append(
            GoldenCase(
                text=obj["text"],
                expected_domain=obj.get("expected_domain"),  # None when JSON null
                note=obj.get("note", ""),
                layer=obj.get("layer", "nano"),  # "nano" default — backward compat
            )
        )
    return cases


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------


def _to_label(domain: str | None) -> str:
    """Normalise a domain value to an internal label string.

    ``None`` and the string ``"null"`` both map to ``_NULL_LABEL``."""
    if domain is None or domain == _NULL_LABEL:
        return _NULL_LABEL
    return domain


def score_domain(
    predictions: list[str | None],
    golds: list[GoldenCase],
) -> DomainScore:
    """Compute per-class precision/recall/F1, overall accuracy, and a
    confusion mapping.

    Both ``predictions`` and ``golds`` must be aligned (same length, same
    order). ``None`` predictions/gold-labels are internally mapped to
    ``"null"`` so they participate in all per-class metrics.

    The implementation is system-agnostic: pass predictions from the nano
    extractor, a regex baseline, or the brain — the math is identical.

    Args:
        predictions: Predicted domain strings (or ``None``) for each case.
        golds: Labeled golden cases. Must have the same length as
            ``predictions``.

    Returns:
        A :class:`DomainScore` with ``accuracy``, ``total``,
        ``per_class`` metrics, and a ``confusion`` mapping.

    Raises:
        ValueError: When ``len(predictions) != len(golds)``.
    """
    if len(predictions) != len(golds):
        raise ValueError(
            f"predictions length ({len(predictions)}) != golds length ({len(golds)})"
        )

    total = len(golds)
    correct = 0

    # Counters per label
    tp: dict[str, int] = defaultdict(int)
    fp: dict[str, int] = defaultdict(int)
    fn: dict[str, int] = defaultdict(int)
    confusion: dict[tuple[str, str], int] = defaultdict(int)

    # Collect all label classes that appear in gold OR predictions
    all_labels: set[str] = set()

    for pred_raw, gc in zip(predictions, golds):
        pred = _to_label(pred_raw)
        gold = _to_label(gc.expected_domain)
        all_labels.add(pred)
        all_labels.add(gold)

        if pred == gold:
            correct += 1
            tp[gold] += 1
        else:
            fp[pred] += 1
            fn[gold] += 1
            confusion[(gold, pred)] += 1

    accuracy = correct / total if total > 0 else 0.0

    per_class: dict[str, dict[str, float]] = {}
    for label in sorted(all_labels):
        tp_val = tp[label]
        fp_val = fp[label]
        fn_val = fn[label]

        precision = tp_val / (tp_val + fp_val) if (tp_val + fp_val) > 0 else 0.0
        recall = tp_val / (tp_val + fn_val) if (tp_val + fn_val) > 0 else 0.0
        f1 = (
            2 * precision * recall / (precision + recall)
            if (precision + recall) > 0
            else 0.0
        )
        per_class[label] = {"precision": precision, "recall": recall, "f1": f1}

    return DomainScore(
        accuracy=accuracy,
        total=total,
        per_class=per_class,
        confusion=dict(confusion),
    )


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


def format_report(score: DomainScore) -> str:
    """Render a human-readable text table of a :class:`DomainScore`.

    The report includes:
    - Overall accuracy and case count.
    - Per-class precision, recall, and F1 in a fixed-width table.
    - A confusion matrix section listing only misclassified pairs.

    Args:
        score: The scoring result from :func:`score_domain`.

    Returns:
        A multi-line string suitable for printing to a terminal.
    """
    lines: list[str] = []

    # Header
    lines.append("=" * 62)
    lines.append("  Domain Classification Eval Report")
    lines.append("=" * 62)
    lines.append(
        f"  Accuracy : {score.accuracy:.1%}  ({round(score.accuracy * score.total)}/{score.total} correct)"
    )
    lines.append("")

    # Per-class table
    header = f"  {'Class':<16} {'Precision':>10} {'Recall':>8} {'F1':>8}"
    lines.append(header)
    lines.append("  " + "-" * 46)
    for label, metrics in sorted(score.per_class.items()):
        lines.append(
            f"  {label:<16} {metrics['precision']:>10.3f} {metrics['recall']:>8.3f} {metrics['f1']:>8.3f}"
        )

    # Confusion section (only errors)
    if score.confusion:
        lines.append("")
        lines.append("  Misclassifications (gold → predicted):")
        for (gold, pred), count in sorted(
            score.confusion.items(), key=lambda kv: -kv[1]
        ):
            lines.append(f"    {gold:<16} → {pred:<16}  ×{count}")

    lines.append("=" * 62)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Segmented scoring
# ---------------------------------------------------------------------------


def score_by_layer(
    predictions: list[str | None],
    golds: list[GoldenCase],
) -> dict[str, DomainScore]:
    """Score predictions grouped by the ``layer`` field of each golden case.

    Calls :func:`score_domain` independently on each layer subset and also on
    the full set.  The result is a mapping from layer name to
    :class:`DomainScore`.  The key ``"overall"`` always contains the aggregate
    over all cases regardless of layer.

    Recognised layer values in the golden set are ``"nano"``, ``"regex"``, and
    ``"guard"``, but any string value is accepted — unknown layers are grouped
    under their own key.

    Args:
        predictions: Predicted domain strings (or ``None``) for each case.
            Must be the same length and order as ``golds``.
        golds: Labeled golden cases with ``layer`` annotations.

    Returns:
        A dict mapping each observed layer name (plus ``"overall"``) to a
        :class:`DomainScore` computed over that subset.

    Raises:
        ValueError: When ``len(predictions) != len(golds)``.
    """
    if len(predictions) != len(golds):
        raise ValueError(
            f"predictions length ({len(predictions)}) != golds length ({len(golds)})"
        )

    # Group indices by layer
    layer_indices: dict[str, list[int]] = defaultdict(list)
    for idx, gc in enumerate(golds):
        layer_indices[gc.layer].append(idx)

    result: dict[str, DomainScore] = {}

    # Overall score across every case
    result["overall"] = score_domain(predictions, golds)

    # Per-layer scores
    for layer, indices in sorted(layer_indices.items()):
        layer_preds = [predictions[i] for i in indices]
        layer_golds = [golds[i] for i in indices]
        result[layer] = score_domain(layer_preds, layer_golds)

    return result


def format_segmented_report(
    scores: dict[str, DomainScore],
    golds: list[GoldenCase],
) -> str:
    """Render a multi-section text report from the output of :func:`score_by_layer`.

    The report includes:

    1. **Raw accuracy** over all cases (same as :func:`format_report` on
       ``scores["overall"]``).
    2. **Layer breakdown** — case counts per layer (nano / regex / guard).
    3. **Nano-eligible accuracy** — the real decision metric, prominently
       labelled.  Includes the per-class table for the nano subset.

    Args:
        scores: Mapping from layer name to :class:`DomainScore`, as returned
            by :func:`score_by_layer`.  Must contain the ``"overall"`` key.
        golds: The original golden cases (used for layer case counts).

    Returns:
        A multi-line string suitable for printing to a terminal.
    """
    lines: list[str] = []

    # ── Section 1: Raw accuracy ──────────────────────────────────────────────
    overall = scores["overall"]
    correct_overall = round(overall.accuracy * overall.total)
    lines.append("=" * 62)
    lines.append("  Domain Classification Eval — Segmented Report")
    lines.append("=" * 62)
    lines.append(
        f"  Raw accuracy (all {overall.total} cases) : "
        f"{overall.accuracy:.1%}  ({correct_overall}/{overall.total})"
    )
    lines.append("")

    # ── Section 2: Layer breakdown ───────────────────────────────────────────
    layer_counts = Counter(gc.layer for gc in golds)
    lines.append("  Layer breakdown:")
    for layer in ("nano", "regex", "guard"):
        count = layer_counts.get(layer, 0)
        score = scores.get(layer)
        if score is not None:
            correct = round(score.accuracy * score.total)
            lines.append(
                f"    {layer:<8}  {count:>3} cases  "
                f"accuracy {score.accuracy:.1%}  ({correct}/{score.total})"
            )
        else:
            lines.append(f"    {layer:<8}  {count:>3} cases  (no predictions)")
    # Any unexpected layers
    for layer, count in sorted(layer_counts.items()):
        if layer not in ("nano", "regex", "guard"):
            score = scores.get(layer)
            if score is not None:
                correct = round(score.accuracy * score.total)
                lines.append(
                    f"    {layer:<8}  {count:>3} cases  "
                    f"accuracy {score.accuracy:.1%}  ({correct}/{score.total})"
                )
    lines.append("")

    # ── Section 3: Nano-eligible accuracy (decision metric) ─────────────────
    nano_score = scores.get("nano")
    lines.append("─" * 62)
    if nano_score is not None:
        correct_nano = round(nano_score.accuracy * nano_score.total)
        lines.append("  ★ NANO-ELIGIBLE ACCURACY  ←  decision metric")
        lines.append(
            f"  Accuracy : {nano_score.accuracy:.1%}  "
            f"({correct_nano}/{nano_score.total} correct)"
        )
        lines.append("")
        # Per-class table for nano subset
        header = f"  {'Class':<16} {'Precision':>10} {'Recall':>8} {'F1':>8}"
        lines.append(header)
        lines.append("  " + "-" * 46)
        for label, metrics in sorted(nano_score.per_class.items()):
            lines.append(
                f"  {label:<16} {metrics['precision']:>10.3f}"
                f" {metrics['recall']:>8.3f} {metrics['f1']:>8.3f}"
            )
        if nano_score.confusion:
            lines.append("")
            lines.append("  Nano misclassifications (gold → predicted):")
            for (gold, pred), count in sorted(
                nano_score.confusion.items(), key=lambda kv: -kv[1]
            ):
                lines.append(f"    {gold:<16} → {pred:<16}  ×{count}")
    else:
        lines.append("  No nano-layer cases found in golden set.")
    lines.append("=" * 62)

    return "\n".join(lines)


# ===========================================================================
# Extraction-quality scoring
# ===========================================================================
#
# Rules per field type (implemented in _score_field):
#
#   Numeric int  (systolic, diastolic, pulse_bpm):
#       exact == after int coercion.
#
#   Numeric float (amount, duration_minutes, sleep_hours, weight_kg,
#                  glucose_mg_dl):
#       abs(a - b) <= max(0.01, 0.01 * abs(gold))   — 1 % or 0.01 floor.
#
#   Lists, set-equality, case-insensitive (people):
#       {p.lower() for p in pred} == {g.lower() for g in gold}
#
#   items: order-insensitive; match by name (lowercased) — set equality.
#       amount agreement reported as sub-metric.
#       category agreement reported separately as sub_metric
#       "items_category_agreement"; does NOT affect the headline metric.
#
#   Enum exact, case-insensitive (domain, currency):
#       (pred or "").lower() == (gold or "").lower()
#
#   kind: case-insensitive + ALIAS MAP.  Unknown kinds fall back to
#       case-insensitive comparison.
#
#   dates_text: set-equality, EXACT strings (no normalization).
#
#   title: EXCLUDED from scoring entirely.
#
# Absent-field rule:
#   If a field is absent from the ``expected`` dict, it is NOT scored.
#   An explicit null in ``expected`` IS scored — pred must also be null.
#
# Fuzzy-field rule:
#   Fields listed in ``fuzzy_fields`` are scored separately and do NOT
#   contribute to the headline ``field_accuracy`` or ``case_pass_rate``.
#   They appear only in ``fuzzy_field_accuracy``.
#
# ===========================================================================

# Fields excluded from extraction scoring entirely.
_EXCLUDED_FIELDS: frozenset[str] = frozenset({"title"})

# Numeric-int fields — exact match after int coercion.
_NUMERIC_INT_FIELDS: frozenset[str] = frozenset({"systolic", "diastolic", "pulse_bpm"})

# Numeric-float fields — 1% tolerance.
_NUMERIC_FLOAT_FIELDS: frozenset[str] = frozenset(
    {"amount", "duration_minutes", "sleep_hours", "weight_kg", "glucose_mg_dl"}
)

# List fields with set-equality (case-insensitive elements).
_LIST_SET_CI_FIELDS: frozenset[str] = frozenset({"people"})

# Enum fields — case-insensitive exact match.
_ENUM_FIELDS: frozenset[str] = frozenset({"domain", "currency"})

# dates_text — set equality, exact strings.
_DATES_TEXT_FIELDS: frozenset[str] = frozenset({"dates_text"})

# kind field — case-insensitive + alias map.
_KIND_ALIASES: dict[str, str] = {
    # Spanish → English canonical
    "caminata": "walk",
    "correr": "run",
    "estudio": "study",
    "cumpleaños": "birthday",
    "cita": "appointment",
    # reverse (English → English; harmless identity entries omitted)
}


def _normalise_kind(k: str | None) -> str | None:
    """Normalise a kind value through the alias map then lowercase."""
    if k is None:
        return None
    lower = k.lower()
    return _KIND_ALIASES.get(lower, lower)


def _float_match(pred_val: object, gold_val: float) -> bool:
    """Return True when pred_val is within 1% (floor 0.01) of gold_val."""
    try:
        pf = float(pred_val)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return False
    tolerance = max(0.01, 0.01 * abs(gold_val))
    return abs(pf - gold_val) <= tolerance


def _score_field(
    field_name: str,
    pred_val: object,
    gold_val: object,
) -> tuple[bool, dict[str, float]]:
    """Score one field.  Returns (matched: bool, sub_metrics: dict).

    sub_metrics is non-empty only for the 'items' field, where it reports
    category and amount agreement separately.
    """
    sub_metrics: dict[str, float] = {}

    # --- Excluded -----------------------------------------------------------
    if field_name in _EXCLUDED_FIELDS:
        # Should never be called for excluded fields, but guard anyway.
        return True, sub_metrics

    # --- Numeric int --------------------------------------------------------
    if field_name in _NUMERIC_INT_FIELDS:
        if gold_val is None:
            return pred_val is None, sub_metrics
        if pred_val is None:
            return False, sub_metrics
        try:
            return int(pred_val) == int(gold_val), sub_metrics  # type: ignore[arg-type]
        except (TypeError, ValueError):
            return False, sub_metrics

    # --- Numeric float ------------------------------------------------------
    if field_name in _NUMERIC_FLOAT_FIELDS:
        if gold_val is None:
            return pred_val is None, sub_metrics
        if pred_val is None:
            return False, sub_metrics
        return _float_match(pred_val, float(gold_val)), sub_metrics  # type: ignore[arg-type]

    # --- List set-equality (people) ----------------------------------------
    if field_name in _LIST_SET_CI_FIELDS:
        gold_set = {g.lower() for g in (gold_val or [])}  # type: ignore[union-attr]
        pred_set = {p.lower() for p in (pred_val or [])}  # type: ignore[union-attr]
        return gold_set == pred_set, sub_metrics

    # --- items --------------------------------------------------------------
    if field_name == "items":
        gold_items: list[dict] = gold_val or []  # type: ignore[assignment]
        pred_items: list[dict] = pred_val or []  # type: ignore[assignment]
        gold_names = {(i.get("name") or "").lower() for i in gold_items}
        pred_names = {(i.get("name") or "").lower() for i in pred_items}
        name_match = gold_names == pred_names

        # Secondary: category agreement (fraction of gold items whose category
        # the prediction also got right — matched by name).
        if gold_items:
            pred_by_name = {
                (i.get("name") or "").lower(): i for i in pred_items
            }
            cat_correct = 0
            cat_total = 0
            for gi in gold_items:
                gname = (gi.get("name") or "").lower()
                gcategory = gi.get("category")
                if gcategory is not None:
                    cat_total += 1
                    pi = pred_by_name.get(gname, {})
                    if (pi.get("category") or "").lower() == (gcategory or "").lower():
                        cat_correct += 1
            if cat_total > 0:
                sub_metrics["items_category_agreement"] = cat_correct / cat_total
        else:
            # No gold items — nothing to compare for category
            if not pred_items:
                sub_metrics["items_category_agreement"] = 1.0

        return name_match, sub_metrics

    # --- Enum exact, case-insensitive (domain, currency) --------------------
    if field_name in _ENUM_FIELDS:
        g = (gold_val or "").lower() if gold_val is not None else None  # type: ignore[union-attr]
        p = (pred_val or "").lower() if pred_val is not None else None  # type: ignore[union-attr]
        return g == p, sub_metrics

    # --- kind ---------------------------------------------------------------
    if field_name == "kind":
        return _normalise_kind(gold_val) == _normalise_kind(pred_val), sub_metrics  # type: ignore[arg-type]

    # --- dates_text (set equality, exact strings) ---------------------------
    if field_name in _DATES_TEXT_FIELDS:
        gold_set2 = set(gold_val or [])  # type: ignore[arg-type]
        pred_set2 = set(pred_val or [])  # type: ignore[arg-type]
        return gold_set2 == pred_set2, sub_metrics

    # --- Fallback: equality ------------------------------------------------
    return gold_val == pred_val, sub_metrics


@dataclass
class ExtractionCase:
    """One labeled example for the extraction-quality eval.

    Attributes:
        text: The raw input text.
        expected: Dict of fields the gold asserts.  A field absent from this
            dict is NOT scored.  An explicit ``null`` value IS scored (pred
            must also be null).
        fuzzy_fields: Field names that are scored in a separate fuzzy bucket
            and do NOT affect the headline metric or ``case_pass_rate``.
        note: Optional free-text annotation.
        layer: Pipeline layer (default ``"nano"``).
    """

    text: str
    expected: dict
    fuzzy_fields: list[str] = field(default_factory=list)
    note: str = ""
    layer: str = "nano"


@dataclass
class ExtractionScore:
    """Scoring results for one extraction eval run.

    Attributes:
        field_accuracy: Per-field accuracy over non-fuzzy asserted fields.
            ``{field_name: fraction_correct}`` — averaged across all cases
            that assert that field.
        fuzzy_field_accuracy: Same but for fuzzy fields only.
        case_pass_rate: Fraction of cases where ALL non-fuzzy asserted fields
            matched.
        per_case: ``[{"text": str, "passed": bool, "mismatches": list[str]}]``
        sub_metrics: Secondary metrics that don't affect headline scores.
            Currently: ``"items_category_agreement"`` (float).
        total: Total number of cases evaluated.
    """

    field_accuracy: dict[str, float]
    fuzzy_field_accuracy: dict[str, float]
    case_pass_rate: float
    per_case: list[dict]
    sub_metrics: dict[str, float]
    total: int


def load_extraction_golden_set(path: Union[str, Path]) -> list[ExtractionCase]:
    """Read a ``.jsonl`` file and return a list of :class:`ExtractionCase`.

    Each non-blank, non-comment line must be a valid JSON object with at least:
      - ``text``: str
      - ``expected``: dict

    Optional fields:
      - ``fuzzy_fields``: list[str]  (defaults to ``[]``)
      - ``note``:         str  (defaults to ``""``)
      - ``layer``:        str  (defaults to ``"nano"``)
      - Any other key (e.g. ``origin``) is silently ignored.

    Lines starting with ``//`` or ``#`` (after optional whitespace) are
    treated as comments and skipped. Blank lines are also skipped.

    Raises:
        ValueError: When a non-comment, non-blank line contains invalid JSON,
            citing the 1-based line number.
    """
    cases: list[ExtractionCase] = []
    for lineno, raw in enumerate(
        Path(path).read_text(encoding="utf-8").splitlines(), start=1
    ):
        stripped = raw.strip()
        if not stripped:
            continue
        if stripped.startswith("//") or stripped.startswith("#"):
            continue
        try:
            obj = json.loads(stripped)
        except json.JSONDecodeError as exc:
            raise ValueError(
                f"line {lineno}: invalid JSON in extraction golden-set file "
                f"{path!r}: {exc}"
            ) from exc
        cases.append(
            ExtractionCase(
                text=obj["text"],
                expected=obj["expected"],
                fuzzy_fields=obj.get("fuzzy_fields", []),
                note=obj.get("note", ""),
                layer=obj.get("layer", "nano"),
            )
        )
    return cases


def score_extraction(
    predictions: list[dict],
    cases: list[ExtractionCase],
) -> ExtractionScore:
    """Score extraction predictions against labeled golden cases.

    Each element of ``predictions`` is a dict with the same keys as
    :class:`~lifeos.agents.extractor.ExtractionResult` (or a superset).
    Each element of ``cases`` is an :class:`ExtractionCase` whose
    ``expected`` dict declares exactly which fields to assert.

    Field-scoring rules:
    - Only fields present in ``expected`` are evaluated.  Absent fields are
      skipped (they are NOT penalised).
    - An explicit ``null`` in ``expected`` IS evaluated; pred must be null.
    - Fields in ``fuzzy_fields`` are scored only in a separate fuzzy bucket
      and do NOT affect ``field_accuracy`` or ``case_pass_rate``.
    - ``title`` is always excluded from scoring.

    Args:
        predictions: One dict per case (same order as ``cases``).
        cases: Labeled golden cases.

    Returns:
        An :class:`ExtractionScore` with aggregated and per-case results.

    Raises:
        ValueError: When ``len(predictions) != len(cases)``.
    """
    if len(predictions) != len(cases):
        raise ValueError(
            f"predictions length ({len(predictions)}) != cases length ({len(cases)})"
        )

    # Accumulators for non-fuzzy fields: {field: [correct, total]}
    field_hits: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    # Accumulators for fuzzy fields
    fuzzy_hits: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    # Sub-metrics accumulators: {metric: [sum, count]}
    sub_acc: dict[str, list[float]] = defaultdict(lambda: [0.0, 0])

    cases_passed = 0
    per_case: list[dict] = []

    for pred_dict, case in zip(predictions, cases):
        fuzzy_set = set(case.fuzzy_fields)
        case_mismatches: list[str] = []
        case_passed = True  # assume pass; flip on any non-fuzzy mismatch

        for field_name, gold_val in case.expected.items():
            # Excluded fields are never scored.
            if field_name in _EXCLUDED_FIELDS:
                continue

            pred_val = pred_dict.get(field_name)
            matched, sub = _score_field(field_name, pred_val, gold_val)

            # Accumulate sub-metrics (e.g. category agreement)
            for sm_key, sm_val in sub.items():
                sub_acc[sm_key][0] += sm_val
                sub_acc[sm_key][1] += 1

            is_fuzzy = field_name in fuzzy_set
            if is_fuzzy:
                fuzzy_hits[field_name][1] += 1
                if matched:
                    fuzzy_hits[field_name][0] += 1
            else:
                field_hits[field_name][1] += 1
                if matched:
                    field_hits[field_name][0] += 1
                else:
                    case_passed = False
                    case_mismatches.append(field_name)

        if case_passed:
            cases_passed += 1

        per_case.append({
            "text": case.text,
            "passed": case_passed,
            "mismatches": case_mismatches,
        })

    total = len(cases)

    # Aggregate field accuracy
    field_accuracy = {
        fname: (hits[0] / hits[1]) if hits[1] > 0 else 0.0
        for fname, hits in field_hits.items()
    }
    fuzzy_field_accuracy = {
        fname: (hits[0] / hits[1]) if hits[1] > 0 else 0.0
        for fname, hits in fuzzy_hits.items()
    }

    # Aggregate sub-metrics
    sub_metrics = {
        sm_key: (vals[0] / vals[1]) if vals[1] > 0 else 0.0
        for sm_key, vals in sub_acc.items()
    }

    return ExtractionScore(
        field_accuracy=field_accuracy,
        fuzzy_field_accuracy=fuzzy_field_accuracy,
        case_pass_rate=cases_passed / total if total > 0 else 0.0,
        per_case=per_case,
        sub_metrics=sub_metrics,
        total=total,
    )


def format_extraction_report(score: ExtractionScore) -> str:
    """Render a human-readable text report from an :class:`ExtractionScore`.

    The report includes:
    1. Overall case pass-rate.
    2. Per-field accuracy table (non-fuzzy only), sorted worst → best so the
       weakest fields appear first.
    3. Fuzzy-field accuracy table (when non-empty), clearly labelled to show
       it does NOT affect the headline numbers.
    4. Secondary sub-metrics (e.g. items_category_agreement).

    Args:
        score: Output from :func:`score_extraction`.

    Returns:
        A multi-line string suitable for printing to a terminal.
    """
    lines: list[str] = []
    sep = "=" * 66

    # ── Header ──────────────────────────────────────────────────────────────
    lines.append(sep)
    lines.append("  Extraction Quality Eval Report")
    lines.append(sep)
    correct_cases = round(score.case_pass_rate * score.total)
    lines.append(
        f"  Case pass rate : {score.case_pass_rate:.1%}"
        f"  ({correct_cases}/{score.total} cases all-fields-match)"
    )
    lines.append("")

    # ── Per-field accuracy (non-fuzzy) ──────────────────────────────────────
    if score.field_accuracy:
        lines.append("  Per-field accuracy (non-fuzzy, worst → best):")
        header = f"  {'Field':<22} {'Accuracy':>10}  {'(correct/total)':>16}"
        lines.append(header)
        lines.append("  " + "-" * 52)
        # Sort worst → best so the weakest fields appear at the top.
        sorted_fields = sorted(score.field_accuracy.items(), key=lambda kv: kv[1])
        for fname, acc in sorted_fields:
            # Recompute correct/total for display
            # (we don't store raw counts in ExtractionScore, so approximate)
            lines.append(f"  {fname:<22} {acc:>10.1%}")
    else:
        lines.append("  (No non-fuzzy fields scored.)")
    lines.append("")

    # ── Fuzzy-field accuracy ─────────────────────────────────────────────────
    if score.fuzzy_field_accuracy:
        lines.append("─" * 66)
        lines.append("  Fuzzy-field accuracy  (NOT included in headline numbers):")
        header2 = f"  {'Field':<22} {'Accuracy':>10}"
        lines.append(header2)
        lines.append("  " + "-" * 34)
        for fname, acc in sorted(score.fuzzy_field_accuracy.items(), key=lambda kv: kv[1]):
            lines.append(f"  {fname:<22} {acc:>10.1%}")
        lines.append("")

    # ── Sub-metrics ──────────────────────────────────────────────────────────
    if score.sub_metrics:
        lines.append("─" * 66)
        lines.append("  Secondary sub-metrics:")
        for sm_key, sm_val in sorted(score.sub_metrics.items()):
            lines.append(f"  {sm_key:<30} {sm_val:.1%}")
        lines.append("")

    lines.append(sep)
    return "\n".join(lines)
