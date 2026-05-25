"""Live eval script for the nano entity-extractor domain classifier.

Loads the golden set, calls ``extractor.extract()`` for each case, then
scores and prints a segmented report.  This is NOT a pytest module — the
leading underscore keeps it out of pytest collection.

Requirements:
    The nano llama-server must be running on port 8090.

Run:
    cd ~/LifeOS/lifeos/lifeos && .venv/bin/python -m lifeos.agents.eval._run_eval

Optional env vars (read by lifeos.agents.runtime):
    LIFEOS_NANO_ENDPOINT — override server URL (default http://127.0.0.1:8090)
"""

from __future__ import annotations

import sys
from pathlib import Path

from lifeos.agents.eval.scoring import (
    GoldenCase,
    format_segmented_report,
    load_golden_set,
    score_by_layer,
)
from lifeos.agents import extractor

_GOLDEN_SET_PATH = Path(__file__).parent / "golden_sets" / "domain_classification.jsonl"

# Accuracy threshold applied to the NANO-ELIGIBLE layer (the real decision
# metric).  The nano scored ~96% on its actual niche; 0.85 is a sane floor.
_NANO_THRESHOLD = 0.85


def _predict(case: GoldenCase) -> str | None:
    """Run the nano extractor for one golden case.

    Returns the predicted domain string, or ``None`` when the extractor
    returns ``None`` (service unreachable, garbage output, or no-action).
    """
    result = extractor.extract(case.text)
    if result is None:
        return None
    return result.domain


def main() -> None:
    print(f"Loading golden set from: {_GOLDEN_SET_PATH}")
    cases = load_golden_set(_GOLDEN_SET_PATH)
    print(f"  {len(cases)} cases loaded.\n")

    predictions: list[str | None] = []

    for i, case in enumerate(cases, start=1):
        pred = _predict(case)
        predictions.append(pred)
        status = "✓" if pred == case.expected_domain else "✗"
        note_str = f"  [{case.note}]" if case.note else ""
        layer_tag = f"[{case.layer}]"
        print(
            f"  [{i:02d}] {status} {layer_tag:<7} gold={case.expected_domain!r:<16}"
            f"  pred={pred!r:<16}  text={case.text[:50]!r}{note_str}"
        )

    print()
    scores = score_by_layer(predictions, cases)
    print(format_segmented_report(scores, cases))

    # Exit code threshold: applies to NANO-ELIGIBLE accuracy (not raw).
    # Raw accuracy is printed for transparency but is not the decision signal.
    nano_score = scores.get("nano")
    if nano_score is None:
        print("\n[WARN] No nano-layer cases found; cannot evaluate threshold.", file=sys.stderr)
        sys.exit(1)

    if nano_score.accuracy < _NANO_THRESHOLD:
        print(
            f"\n[WARN] Nano-eligible accuracy {nano_score.accuracy:.1%} is below "
            f"threshold {_NANO_THRESHOLD:.0%}.",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
