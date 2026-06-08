"""Installer-facing glue for the nano agent model.

Mirrors the pattern of `install_brain.py` but for the nano llama-server
(port 8090, CPU-only). The installer (`install.sh`) shells out to this
module so the bash side stays thin and all real logic is unit-tested Python.

Responsibilities
----------------
- `resolve_nano_entry()`  → pick the nano catalog entry, honoring the
                            AXI_NANO_MODEL env-var override.
- `download_plan(entry)`   → which catalog files to fetch (repo_id/filename).
- `write_nano_config(entry)` → write active_nano_model.json so the launcher
                               reads the right model on next start.
- `main(argv)`             → CLI: --report / --json / --write-config.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

from axi import nano_manager
from axi.nano_catalog import NanoModelEntry, by_id, catalog


# ────────────────────────── recommendation ───────────────────────────


def resolve_nano_entry() -> NanoModelEntry:
    """Return the nano catalog entry to use, honoring AXI_NANO_MODEL.

    Default is always qwen35-0_8b. If AXI_NANO_MODEL names a valid catalog
    id, that entry is used instead. Unknown ids are silently ignored so a
    typo never breaks the install.
    """
    override = os.environ.get("AXI_NANO_MODEL", "").strip()
    if override:
        entry = by_id(override)
        if entry is not None:
            return entry
    return catalog()[0]  # default: qwen35-0_8b


# ────────────────────────── download plan ────────────────────────────


def download_plan(entry: NanoModelEntry) -> dict:
    """Files the installer must fetch for the given nano entry."""
    files = [
        {"repo_id": f.repo_id, "filename": f.filename, "kind": f.kind,
         "local_name": f.local_name}
        for f in entry.files
    ]
    return {
        "model_id": entry.id,
        "dir": nano_manager.nano_model_dir(entry).name,
        "files": files,
    }


# ────────────────────────── write config ─────────────────────────────


def write_nano_config(entry: NanoModelEntry, *, restart: bool = False) -> None:
    """Write active_nano_model.json for the given entry.

    Does NOT restart llama-nano.service by default (the installer controls
    that separately). Pass restart=True to trigger a restart after writing.
    """
    nano_manager.write_active_nano(entry)
    if restart:
        try:
            nano_manager._systemctl_restart_nano()
        except Exception:  # noqa: BLE001 — installer must not abort on this
            pass


# ────────────────────────── report ───────────────────────────────────


def format_report(entry: NanoModelEntry) -> str:
    override = os.environ.get("AXI_NANO_MODEL", "").strip()
    src = f"AXI_NANO_MODEL={override}" if override and by_id(override) else "default"
    lines = [
        f"Nano model: {entry.name} [{entry.id}]  ({src})",
        f"Port:       {entry.port}",
        f"Context:    {entry.ctx}",
        f"CPU-only:   yes (ngl={entry.ngl})",
        f"Files:      {', '.join(f.filename for f in entry.files)}",
    ]
    if entry.notes:
        lines.append(f"Notes:      {entry.notes}")
    return "\n".join(lines)


# ────────────────────────── CLI ──────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="axi-install-nano",
        description="Nano-model selection and config writer for install.",
    )
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--report", action="store_true",
                   help="print a human-readable nano model summary")
    g.add_argument("--json", action="store_true",
                   help="print machine-readable plan (for install.sh)")
    g.add_argument("--write-config", action="store_true",
                   help="write active_nano_model.json without downloading")
    ap.add_argument("--restart", action="store_true",
                    help="with --write-config, also restart llama-nano.service")
    args = ap.parse_args(argv)

    entry = resolve_nano_entry()

    if args.json:
        plan = download_plan(entry)
        print(json.dumps(plan))
        return 0
    if args.write_config:
        write_nano_config(entry, restart=args.restart)
        print(format_report(entry))
        return 0
    # Default + --report.
    print(format_report(entry))
    return 0


__all__ = [
    "resolve_nano_entry",
    "download_plan",
    "write_nano_config",
    "format_report",
    "main",
]


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
