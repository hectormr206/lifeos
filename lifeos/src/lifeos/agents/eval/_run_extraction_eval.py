"""Live eval script for the nano entity-extractor extraction-quality eval.

Loads the extraction golden set, calls ``extractor.extract()`` for each case,
then scores and prints a per-field report.  This is NOT a pytest module — the
leading underscore keeps it out of pytest collection.

Requirements:
    The nano llama-server must be running on port 8090.

Run:
    cd ~/LifeOS/lifeos/lifeos && .venv/bin/python -m lifeos.agents.eval._run_extraction_eval

Optional env vars (read by lifeos.agents.runtime):
    LIFEOS_NANO_ENDPOINT — override server URL (default http://127.0.0.1:8090)
"""

from __future__ import annotations

import dataclasses
import sys
import time
from pathlib import Path

from lifeos.agents.eval.scoring import (
    ExtractionCase,
    format_extraction_report,
    load_extraction_golden_set,
    score_extraction,
)
from lifeos.agents import extractor

_GOLDEN_SET_PATH = (
    Path(__file__).parent / "golden_sets" / "extraction_quality.jsonl"
)


def _extract_as_dict(text: str) -> dict:
    """Call extractor.extract() and return the result as a plain dict.

    Uses temperature=0.0 and seed=0 for deterministic, reproducible eval runs.
    timeout_s=30 and retry_timeout_s=60 give the CPU nano server enough
    headroom for the full 12K-char system prompt.
    Production default is now temperature=0.0, seed=0 (matches eval — ADR-1).

    Returns a dict with all ExtractionResult fields; domain=None when the
    extractor returns None (no extraction).
    """
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


def main() -> None:
    print(f"Loading extraction golden set from: {_GOLDEN_SET_PATH}")
    cases: list[ExtractionCase] = load_extraction_golden_set(_GOLDEN_SET_PATH)
    print(f"  {len(cases)} cases loaded.\n")

    predictions: list[dict] = []
    t_start = time.perf_counter()

    for i, case in enumerate(cases, start=1):
        pred = _extract_as_dict(case.text)
        predictions.append(pred)

        # Per-case pass/fail preview (domain field only — quick sanity check)
        gold_domain = case.expected.get("domain")
        pred_domain = pred.get("domain")
        domain_ok = "✓" if pred_domain == gold_domain else "✗"
        note_str = f"  [{case.note[:60]}]" if case.note else ""
        print(
            f"  [{i:02d}] {domain_ok} "
            f"gold_domain={gold_domain!r:<16} "
            f"pred_domain={pred_domain!r:<16} "
            f"text={case.text[:45]!r}"
            f"{note_str}"
        )

    elapsed = time.perf_counter() - t_start
    print(f"\n  Total extraction time: {elapsed:.2f}s  "
          f"({elapsed / len(cases) * 1000:.0f}ms/case)\n")

    # Score
    score = score_extraction(predictions, cases)

    # Full report
    print(format_extraction_report(score))

    # Per-case failures (non-fuzzy only)
    failed_cases = [pc for pc in score.per_case if not pc["passed"]]
    if failed_cases:
        print("\n  Failed cases (non-fuzzy field mismatches):")
        for i, pc in enumerate(failed_cases, start=1):
            print(f"    [{i:02d}] {pc['text'][:60]!r}")
            print(f"          mismatches: {pc['mismatches']}")
    else:
        print("  All cases passed (non-fuzzy fields).")

    # Weakest fields diagnosis
    if score.field_accuracy:
        print("\n  Weakest extraction fields (non-fuzzy, accuracy < 70%):")
        weak = {f: a for f, a in score.field_accuracy.items() if a < 0.70}
        if weak:
            for fname, acc in sorted(weak.items(), key=lambda kv: kv[1]):
                print(f"    {fname:<22}  {acc:.1%}")
        else:
            print("    (none below 70%)")

    print(f"\n  Runtime: {elapsed:.2f}s")


if __name__ == "__main__":
    main()
