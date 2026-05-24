"""Live eval script for the nano entity-extractor domain classifier.

Loads the golden set, calls ``extractor.extract()`` for each case, then
scores and prints a report. This is NOT a pytest module — the leading
underscore keeps it out of pytest collection.

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
    format_report,
    load_golden_set,
    score_domain,
)
from lifeos.agents import extractor

_GOLDEN_SET_PATH = Path(__file__).parent / "golden_sets" / "domain_classification.jsonl"


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
    failures = 0

    for i, case in enumerate(cases, start=1):
        pred = _predict(case)
        predictions.append(pred)
        status = "✓" if pred == case.expected_domain else "✗"
        note_str = f"  [{case.note}]" if case.note else ""
        print(
            f"  [{i:02d}] {status}  gold={case.expected_domain!r:<16}"
            f"  pred={pred!r:<16}  text={case.text[:50]!r}{note_str}"
        )
        if pred != case.expected_domain:
            failures += 1

    print()
    score = score_domain(predictions, cases)
    print(format_report(score))

    # Exit code: 0 if accuracy >= 0.7 (a reasonable bar for v1), else 1.
    threshold = 0.70
    if score.accuracy < threshold:
        print(
            f"\n[WARN] Accuracy {score.accuracy:.1%} is below threshold {threshold:.0%}.",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
