"""Bake-off comparison runner: BASELINE vs any candidate extraction run.

This is NOT a pytest module (leading underscore keeps it out of collection).
It scores a candidate run against the 69-case golden ruler at temperature=0.0,
seed=0 and prints a per-field delta table + PASS/FAIL verdict using the
machine-checkable win protocol.

BAKE-OFF RESULT (WU-6 — 2026-06-17): Approach B (pre-router)
-------------------------------------------------------------
  Baseline dates_text  : 73.5% (36/49)
  Approach B (router)  : 67.3% dates_text — FAIL

  Per-field deltas (B vs baseline):
    dates_text  : -6.1%  (36/49 → ~33/49)  [REGRESSED — hard fail on gate 1]
    domain      : -4.4%  (66/69 → 63/69)   [REGRESSED — also fails gate 2]
    merchant    : +20.0% (improvement)
    people      : +5.1%  (improvement)
    currency    : +6.2%  (improvement)
    All other fields: unchanged

  VERDICT: Approach B (pre-router) FAILS the win bar.
  - dates_text 67.3% < 73.5% threshold (must be strictly greater).
  - domain accuracy dropped from 95.6% to 91.2% (4.4% = ~3 cases > noise band).

  ROOT CAUSE: The "general" variant (used for relationships/exercise/events/
  spirituality/learning) lacks the domain-specific few-shots that the monolith
  has for those domains. Cases like "ok ya entendí todo" (null) route to
  general → spirituality misclassification. Also "el próximo viernes me toca
  revisión con la dermatóloga" routes to health (revisión keyword triggers
  health pattern) instead of events.

BAKE-OFF RESULT (WU-7 — 2026-06-17): Approach A (two-stage classify→extract)
------------------------------------------------------------------------------
  Baseline dates_text  : 73.5% (36/49)
  Approach A (twostage): 63.3% dates_text — FAIL

  Per-field deltas (A vs baseline):
    dates_text  : -10.2%  (36/49 → ~31/49)  [REGRESSED — hard fail on gate 1]
    domain      :  -3.0%  (66/69 → 64/69)   [REGRESSED — also fails gate 2]
    merchant    :  -20.0% (regression)
    All other fields: unchanged or improved

  Latency: 249s for 69 cases = ~3,612ms/case (~14-18s stage-2 per case, stage-1 fast)

  VERDICT: Approach A (two-stage) FAILS the win bar.
  - dates_text 63.3% < 73.5% threshold (must be strictly greater, need > 73.5%).
  - domain accuracy dropped from 95.6% to 92.6% (3.0% = ~2 cases, fails gate 2).

  ROOT CAUSE: Stage-1 nano classifier misclassifies edge/null cases:
    - Case 25: "caminata familiar" → events (should be exercise)
    - Case 37: "hace mucho calor" → health (should be null)
    - Case 38: "el sol sale por el este" → events (should be null)
    - Case 61: "le mandé mensaje a Carlos Fuentes" → events (should be relationships)
    - Case 66: "me registré a un curso de Python en línea" → finance (should be learning)
    - Case 69: "nada, estuve descansando" → health (should be null)
  When stage-1 misclassifies, stage-2 runs the wrong domain prompt which then
  introduces phantom dates or produces incorrect fields. The 0.8B model at max_tokens=8
  is not reliable enough as a gate classifier on ambiguous Spanish inputs.

  FINAL OUTCOME: NEITHER Approach A nor Approach B ships.
  Real wins kept: temp=0 alignment (WU-2) and bake-off harness (WU-5).
  Prod default: monolith prompt (original baseline). No regression in prod.

  WIN BAR: dates_text strictly > 73.5% AND no other field drops > 1 case

Usage:
    # Score the current baseline (monolith) against the golden set:
    cd ~/LifeOS/lifeos/lifeos
    .venv/bin/python -m lifeos.agents.eval._run_bakeoff

    # To wire a future candidate: import _run_candidate and pass a different
    # label and mode override, then call _print_delta_table + decide_winner
    # with the baseline and candidate field_accuracy dicts.

Design refs: design §4.1-4.5; spec Requirement — Bake-off Measurement and Win Protocol.
Win bar ref: engram obs #496 — noise-band bar, not strict-zero Pareto.

Requirements:
    The nano llama-server must be running on port 8090.

Run:
    cd ~/LifeOS/lifeos/lifeos
    .venv/bin/python -m lifeos.agents.eval._run_bakeoff
"""
from __future__ import annotations

import dataclasses
import time
from pathlib import Path

_GOLDEN_SET_PATH = (
    Path(__file__).parent / "golden_sets" / "extraction_quality.jsonl"
)

# The noise-band win bar: dates_text must strictly exceed this threshold.
_DATES_BASELINE_THRESHOLD = 0.735

# Noise-band tolerance: how much any non-dates field can drop before it counts
# as a regression. 1 case on the ~49-case dates denominator ≈ 0.02 fractional
# drop. We use 1/49 ≈ 0.0205 as the tolerance bound.
_REGRESSION_NOISE_BAND = 1 / 49  # ~0.0204


# ---------------------------------------------------------------------------
# Pure functions (testable without nano server or golden set)
# ---------------------------------------------------------------------------

def compute_field_deltas(
    baseline: dict[str, float],
    candidate: dict[str, float],
) -> dict[str, float]:
    """Compute per-field accuracy deltas: candidate - baseline.

    Fields absent in candidate are treated as 0.0 (worst case).
    Only fields present in baseline are returned (baseline is the reference).

    Args:
        baseline: Per-field accuracy dict from the baseline run.
        candidate: Per-field accuracy dict from the candidate run.

    Returns:
        Dict mapping each field in baseline to (candidate_acc - baseline_acc).
        Positive = improvement; negative = regression.
    """
    return {
        field: candidate.get(field, 0.0) - acc
        for field, acc in baseline.items()
    }


def decide_winner(
    baseline: dict[str, float],
    candidate: dict[str, float],
    dates_field: str = "dates_text",
    baseline_dates: float = _DATES_BASELINE_THRESHOLD,
    noise_band: float = _REGRESSION_NOISE_BAND,
) -> bool:
    """Apply the noise-band win protocol to determine if the candidate wins.

    A candidate WINS if and only if ALL of the following hold:
    1. candidate[dates_field] strictly > baseline_dates (e.g. > 0.735).
    2. No non-dates field regresses by more than noise_band beyond its baseline
       (noise_band ≈ 1/49 ≈ 0.02 — one case on small-N denominator).

    Fields absent in candidate are treated as 0.0 (pessimistic assumption).

    Args:
        baseline: Per-field accuracy dict from the baseline run.
        candidate: Per-field accuracy dict from the candidate run.
        dates_field: The field name for dates accuracy (default 'dates_text').
        baseline_dates: The threshold that dates_field must strictly exceed.
        noise_band: Maximum allowed fractional drop for non-dates fields.

    Returns:
        True when the candidate passes the win protocol; False otherwise.
    """
    # Gate 1: dates_text must strictly exceed the baseline threshold.
    cand_dates = candidate.get(dates_field, 0.0)
    if cand_dates <= baseline_dates:
        return False

    # Gate 2: no non-dates field may regress by more than noise_band.
    for field, base_acc in baseline.items():
        if field == dates_field:
            continue
        cand_acc = candidate.get(field, 0.0)
        drop = base_acc - cand_acc
        if drop > noise_band:
            return False

    return True


# ---------------------------------------------------------------------------
# Runner helpers
# ---------------------------------------------------------------------------

def _extract_as_dict(text: str) -> dict:
    """Call extractor.extract() and return as plain dict."""
    from lifeos.agents import extractor

    result = extractor.extract(
        text,
        temperature=0.0,
        seed=0,
        timeout_s=30.0,
        retry_timeout_s=60.0,
    )
    if result is None:
        return {
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
            "title": None,
        }
    return dataclasses.asdict(result)


def _run_candidate(
    cases: list,
    label: str,
) -> tuple[list[dict], float]:
    """Run all cases through extract(). Returns (predictions, elapsed_s)."""
    from lifeos.agents.eval.scoring import score_extraction

    print(f"\n{'='*66}")
    print(f"  Running: {label}")
    print(f"{'='*66}")

    predictions = []
    t0 = time.perf_counter()
    for i, case in enumerate(cases, start=1):
        pred = _extract_as_dict(case.text)
        predictions.append(pred)
        gold_domain = case.expected.get("domain")
        pred_domain = pred.get("domain")
        tick = "✓" if pred_domain == gold_domain else "✗"
        print(
            f"  [{i:02d}] {tick} "
            f"gold={gold_domain!r:<16} "
            f"pred={pred_domain!r:<16} "
            f"text={case.text[:40]!r}"
        )
    elapsed = time.perf_counter() - t0
    print(f"\n  Time: {elapsed:.2f}s  ({elapsed / len(cases) * 1000:.0f}ms/case)")
    return predictions, elapsed


def _print_delta_table(
    baseline_score: dict[str, float],
    candidates: list[tuple[str, dict[str, float]]],
) -> None:
    """Print a per-field delta table comparing baseline to each candidate."""
    all_fields = sorted(set(baseline_score.keys()))
    print(f"\n{'='*80}")
    print("  Per-field delta table (candidate - baseline)")
    print(f"{'='*80}")
    header = f"  {'Field':<22} {'Baseline':>10}"
    for label, _ in candidates:
        header += f"  {label[:12]:>12}  {'Δ':>8}"
    print(header)
    print("  " + "-" * (60 + 22 * len(candidates)))

    for field in all_fields:
        base_acc = baseline_score.get(field, 0.0)
        row = f"  {field:<22} {base_acc:>10.1%}"
        for label, cand_score in candidates:
            cand_acc = cand_score.get(field, 0.0)
            delta = cand_acc - base_acc
            sign = "+" if delta >= 0 else ""
            row += f"  {cand_acc:>12.1%}  {sign}{delta:>+7.1%}"
        print(row)


def main() -> None:
    from lifeos.agents.eval.scoring import (
        ExtractionCase,
        format_extraction_report,
        load_extraction_golden_set,
        score_extraction,
    )

    print(f"Loading golden set: {_GOLDEN_SET_PATH}")
    cases: list[ExtractionCase] = load_extraction_golden_set(_GOLDEN_SET_PATH)
    print(f"  {len(cases)} cases loaded.")

    # Score the baseline (monolith) against the golden set.
    preds, elapsed = _run_candidate(cases, "BASELINE (monolith prompt)")
    score = score_extraction(preds, cases)
    baseline_score = score.field_accuracy
    print(format_extraction_report(score))

    print(f"\n{'='*66}")
    print("  WIN BAR")
    print(f"  Bar: dates_text strictly > {_DATES_BASELINE_THRESHOLD:.1%} "
          f"AND no other field drops > {_REGRESSION_NOISE_BAND:.3f} (~1/49 case)")
    print(f"  To wire a future candidate: import _run_candidate, run it with a")
    print(f"  custom label, then call decide_winner(baseline_score, candidate_score).")
    print(f"{'='*66}")


if __name__ == "__main__":
    main()
