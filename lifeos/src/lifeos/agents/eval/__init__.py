"""Nano-agent evaluation harness.

Provides a golden-set loader, a pure domain-accuracy scorer, and a
hand-run script for live model evaluation.

Public re-exports:
    GoldenCase, DomainScore, load_golden_set, score_domain, format_report,
    score_by_layer, format_segmented_report
"""

from __future__ import annotations

from lifeos.agents.eval.scoring import (
    DomainScore,
    GoldenCase,
    format_report,
    format_segmented_report,
    load_golden_set,
    score_by_layer,
    score_domain,
)

__all__ = [
    "DomainScore",
    "GoldenCase",
    "format_report",
    "format_segmented_report",
    "load_golden_set",
    "score_by_layer",
    "score_domain",
]
