"""Pure scoring utilities for the nano-agent domain-classification eval harness.

All functions in this module are PURE — no I/O, no network, no side-effects
beyond reading a file in `load_golden_set`. They accept predictions from any
system (nano extractor, regex baseline, brain), so A/B comparisons are trivial.

Null domains are modelled as the string "null" internally so they participate
in per-class metrics like any other label. Callers and data files use Python
``None`` / JSON ``null``; the conversion happens at load/score boundaries.

Public API:
    GoldenCase            — dataclass for one labeled eval example
    DomainScore           — dataclass holding all scoring outputs
    load_golden_set(path) — read a .jsonl file into list[GoldenCase]
    score_domain(preds, golds) -> DomainScore
    format_report(score)  -> str
"""

from __future__ import annotations

import json
from collections import defaultdict
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
    """

    text: str
    expected_domain: str | None
    note: str = ""


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
      - ``note``: str  (defaults to ``""``)

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
