#!/usr/bin/env python3
"""One-shot retro-annotation: stamp the CURRENT machine's hardware fingerprint
onto model_audit.jsonl rows that predate the "hardware" field.

Every row written before the fingerprint feature was measured on THIS laptop,
so annotating them with the current machine's fingerprint is correct — with
one exception: rows produced by a fork llama-server binary (e.g. bonsai-1bit /
bonsai-ternary ran on the PrismML fork) must carry that binary's build string,
not /usr/bin/llama-server's. Use --fork-labels/--fork-build for those.

Usage:
  # Dry run (report what would change, write nothing):
  .venv/bin/python scripts/bench/annotate_hardware.py --dry-run

  # Annotate for real, stamping bonsai fork rows with the fork's build:
  .venv/bin/python scripts/bench/annotate_hardware.py \
      --fork-labels bonsai-1bit,bonsai-ternary \
      --fork-build /path/to/prismml/llama-server

Safety: a timestamped backup copy (model_audit.jsonl.bak-<ts>) is written
first, then the rewrite is atomic (tmp + os.replace). Rows that already have
"hardware" and unparsable lines are preserved byte-for-byte.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import model_audit as ma  # noqa: E402 — fingerprint collector lives there

DEFAULT_SERVER_BIN = "/usr/bin/llama-server"


def annotate_lines(lines: list[str], base_hw: dict,
                   fork_hw: Optional[dict],
                   fork_labels: set[str]) -> tuple[list[str], int, int]:
    """Pure core: return (new_lines, annotated_count, skipped_count).

    A line is annotated only when it parses to a dict WITHOUT "hardware".
    Everything else (already-annotated rows, malformed lines) passes through
    verbatim. fork_labels rows get fork_hw; everyone else gets base_hw.
    """
    out: list[str] = []
    annotated = skipped = 0
    for line in lines:
        stripped = line.strip()
        if stripped:
            try:
                row = json.loads(stripped)
            except json.JSONDecodeError:
                row = None
            if isinstance(row, dict) and "hardware" not in row:
                hw = fork_hw if (fork_hw is not None
                                 and row.get("label") in fork_labels) else base_hw
                row["hardware"] = hw
                out.append(json.dumps(row, ensure_ascii=False))
                annotated += 1
                continue
        skipped += 1
        out.append(line.rstrip("\n"))
    return out, annotated, skipped


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(
        description="Retro-annotate model_audit.jsonl rows with the current "
                    "machine's hardware fingerprint.")
    p.add_argument("--registry", default=str(ma.AUDIT_REGISTRY_PATH),
                   help=f"Audit registry JSONL (default: {ma.AUDIT_REGISTRY_PATH})")
    p.add_argument("--server-bin", default=DEFAULT_SERVER_BIN,
                   help="llama-server binary whose --version stamps normal "
                        f"rows (default: {DEFAULT_SERVER_BIN})")
    p.add_argument("--fork-labels", default="",
                   help="Comma-separated row labels that ran on a FORK binary "
                        "(e.g. bonsai-1bit,bonsai-ternary)")
    p.add_argument("--fork-build", default=None,
                   help="Path to the fork llama-server; its --version stamps "
                        "the --fork-labels rows instead")
    p.add_argument("--dry-run", action="store_true",
                   help="Report what would change; write nothing")
    args = p.parse_args(argv)

    fork_labels = {s.strip() for s in args.fork_labels.split(",") if s.strip()}
    if bool(fork_labels) != bool(args.fork_build):
        print("ERROR: --fork-labels and --fork-build must be used together.",
              file=sys.stderr)
        return 2

    registry = Path(args.registry)
    if not registry.exists():
        print(f"ERROR: registry not found: {registry}", file=sys.stderr)
        return 2

    base_hw = ma.collect_hardware_fingerprint(server_bin=args.server_bin)
    fork_hw = None
    if fork_labels:
        fork_hw = dict(base_hw)
        fork_hw["llama_build"] = ma.probe_llama_build(args.fork_build)

    lines = registry.read_text(encoding="utf-8").splitlines()
    new_lines, annotated, skipped = annotate_lines(
        lines, base_hw, fork_hw, fork_labels)

    print(f"registry   : {registry}")
    print(f"fingerprint: {base_hw['fingerprint_id']} "
          f"({base_hw.get('cpu_model')} / {base_hw.get('gpu_name')})")
    print(f"llama_build: {base_hw.get('llama_build')}"
          + (f" | fork rows ({', '.join(sorted(fork_labels))}): "
             f"{fork_hw.get('llama_build')}" if fork_hw else ""))
    print(f"rows to annotate: {annotated} | untouched: {skipped}")

    if args.dry_run:
        print("[dry-run] no files written.")
        return 0
    if annotated == 0:
        print("nothing to do — no rows lack \"hardware\".")
        return 0

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = registry.with_name(f"{registry.name}.bak-{ts}")
    shutil.copy2(registry, backup)
    print(f"backup     : {backup}")

    fd, tmp_name = tempfile.mkstemp(dir=str(registry.parent),
                                    prefix=registry.name, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(new_lines) + "\n")
        os.replace(tmp_name, registry)
    except BaseException:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)
        raise
    print(f"annotated {annotated} rows in place (atomic rewrite).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
