#!/usr/bin/env python3
"""LifeOS AI reviewer gate.

Generates an auditable JSON report and fails on high-severity findings.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass, asdict
from typing import List


ROOT = pathlib.Path(__file__).resolve().parents[1]
REPORT_DIR = ROOT / "artifacts"
REPORT_PATH = REPORT_DIR / "ai-review-report.json"

SOURCE_PREFIXES = ("cli/src/", "daemon/src/", "scripts/", ".github/workflows/", "contracts/")
PLACEHOLDER_PATTERN = re.compile(r"\b(TODO|TBD)\b|<\.\.\.>")
SOURCE_EXTENSIONS = {".rs", ".sh", ".yml", ".yaml", ".toml", ".json"}


@dataclass
class Finding:
    rule_id: str
    severity: str
    file: str
    line: int
    message: str


def run(cmd: List[str]) -> str:
    output = subprocess.check_output(cmd, cwd=ROOT)
    return output.decode("utf-8", errors="replace")


def discover_base_sha() -> str:
    base_ref = os.getenv("GITHUB_BASE_REF", "").strip()
    if base_ref:
        subprocess.run(
            ["git", "fetch", "origin", base_ref, "--depth=1"],
            cwd=ROOT,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return run(["git", "merge-base", f"origin/{base_ref}", "HEAD"]).strip()

    # Fallback for local runs / push events
    try:
        return run(["git", "rev-parse", "HEAD~1"]).strip()
    except subprocess.CalledProcessError:
        return run(["git", "rev-parse", "HEAD"]).strip()


def changed_files(base_sha: str) -> List[str]:
    diff = run(["git", "diff", "--name-only", base_sha, "HEAD"]).splitlines()
    return [f.strip() for f in diff if f.strip()]


def should_scan_file(path: str) -> bool:
    if not path.startswith(SOURCE_PREFIXES):
        return False
    ext = pathlib.Path(path).suffix.lower()
    return ext in SOURCE_EXTENSIONS


def check_placeholders(files: List[str]) -> List[Finding]:
    findings: List[Finding] = []
    for rel in files:
        if not should_scan_file(rel):
            continue
        abs_path = ROOT / rel
        if not abs_path.exists() or abs_path.is_dir():
            continue

        try:
            lines = abs_path.read_text(encoding="utf-8", errors="ignore").splitlines()
        except OSError:
            continue
        for idx, line in enumerate(lines, start=1):
            if PLACEHOLDER_PATTERN.search(line):
                findings.append(
                    Finding(
                        rule_id="no_placeholders",
                        severity="high",
                        file=rel,
                        line=idx,
                        message="Placeholder marker detected (TODO/TBD/<...>).",
                    )
                )
    return findings


def check_tests_for_source_changes(files: List[str]) -> List[Finding]:
    touched_source = [
        f
        for f in files
        if (f.startswith("cli/src/") or f.startswith("daemon/src/")) and f.endswith(".rs")
    ]
    if not touched_source:
        return []

    touched_tests = any(
        (
            f.endswith("_tests.rs")
            or "tests/" in f
            or f.endswith("/main_tests.rs")
            or f.startswith("tests/")
        )
        for f in files
    )
    if touched_tests:
        return []

    return [
        Finding(
            rule_id="tests_required_for_source_change",
            severity="high",
            file=touched_source[0],
            line=1,
            message="Rust source changed without touching tests in the same change set.",
        )
    ]


def main() -> int:
    base_sha = discover_base_sha()
    files = changed_files(base_sha)
    findings: List[Finding] = []
    findings.extend(check_placeholders(files))
    findings.extend(check_tests_for_source_changes(files))

    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "timestamp_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "base_sha": base_sha,
        "head_sha": run(["git", "rev-parse", "HEAD"]).strip(),
        "changed_files_count": len(files),
        "changed_files": files,
        "rules": [
            {
                "id": "no_placeholders",
                "description": "Reject TODO/TBD/<...> placeholders in source and CI files.",
            },
            {
                "id": "tests_required_for_source_change",
                "description": "Require test file changes when Rust source changes.",
            },
        ],
        "findings_count": len(findings),
        "findings": [asdict(f) for f in findings],
        "status": "failed" if findings else "passed",
    }
    REPORT_PATH.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    print(f"AI review report written to {REPORT_PATH}")
    if findings:
        print("AI reviewer found blocking findings:")
        for finding in findings:
            print(
                f"- [{finding.severity}] {finding.rule_id} "
                f"{finding.file}:{finding.line} {finding.message}"
            )
        return 1

    print("AI reviewer gate passed with no blocking findings.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
