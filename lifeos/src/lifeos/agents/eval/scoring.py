"""Pure scoring utilities for the nano-agent domain-classification eval harness.

All functions in this module are PURE — no I/O, no network, no side-effects
beyond reading a file in `load_golden_set`. They accept predictions from any
system (nano extractor, regex baseline, brain), so A/B comparisons are trivial.

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

Public API:
    GoldenCase                       — dataclass for one labeled eval example
    DomainScore                      — dataclass holding all scoring outputs
    load_golden_set(path)            — read a .jsonl file into list[GoldenCase]
    score_domain(preds, golds)       -> DomainScore
    score_by_layer(preds, golds)     -> dict[str, DomainScore]
    format_report(score)             -> str
    format_segmented_report(scores, golds) -> str
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
