#!/usr/bin/env python3
"""onboard_model.py — one-command onboarding for a NEW roster model.

Onboarding a new model means: score it on the FULL canonical audit role set at
*tune-to-peak* (use_recipe=False), which is what actually CREATES the model's
saved recipe in results/model_recipes.json. Once that run finishes, the model
has a recipe for its tier and automatically joins the FAST re-score circuit
(gen_reaudit_plan.py, whose recipe pre-check now sees it as "has recipe").

This tool does everything but launch the bench:
  a. validates the gguf (and mmproj, if given) exist on disk;
  b. upserts the model into roster.json (idempotent — append new, update in
     place, order preserved), so it becomes part of the single source of truth;
  c. generates a tune-to-peak plan for JUST this model (shared build_reaudit_plan
     with use_recipe=False; vision auto-dropped when there is no mmproj);
  d. PRINTS (does not run) the systemd-run command that launches the plan.

Usage
-----
  onboard_model.py --label mymodel --gguf /m/mymodel/Q4.gguf
  onboard_model.py --label myvlm --gguf ... --mmproj ... --moe on
  onboard_model.py --label big --gguf ... --server-bin /opt/fork/llama-server \\
      --extra-flags --reasoning off

Then launch what it prints (NOT run here):
  systemd-run --user --unit=axi-onboard-<label> --collect ... \\
    audit_batches.py run --plan results/onboard_<label>.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import model_audit as ma          # VALID_ROLES + argparse --roles default
import gen_reaudit_plan as gr      # shared build_reaudit_plan / launch_command

RESULTS_DIR = SCRIPT_DIR / "results"
DEFAULT_ROSTER_PATH = SCRIPT_DIR / "roster.json"

# Order roster fields are emitted in, matching roster.json's existing shape.
_ENTRY_KEY_ORDER = ("label", "gguf", "mmproj", "moe", "server_bin",
                    "extra_flags")


# ── canonical roles (single source of truth = model_audit's --roles default) ──

def canonical_audit_roles() -> list[str]:
    """The full canonical audit role set — model_audit.py's ``--roles`` default.

    Read straight off model_audit's argparse default (model_audit.py:3361-3365)
    so a newly onboarded model is scored on everything the standard audit does,
    with zero drift from the source of truth.
    """
    for action in ma.build_parser()._actions:
        if action.dest == "roles":
            return [r.strip() for r in str(action.default).split(",")
                    if r.strip()]
    raise RuntimeError("model_audit.build_parser() has no --roles argument")


# ── pure builders ─────────────────────────────────────────────────────────────

def build_entry(label, gguf, *, mmproj=None, moe=None, server_bin=None,
                extra_flags=None) -> dict:
    """A roster entry dict with only the keys that are set (matches roster.json).

    ``label``/``gguf`` are always present; optional fields are added only when
    truthy so the entry mirrors how roster.json omits absent keys.
    """
    entry: dict = {"label": label, "gguf": gguf}
    if mmproj:
        entry["mmproj"] = mmproj
    if moe:
        entry["moe"] = moe
    if server_bin:
        entry["server_bin"] = server_bin
    if extra_flags:
        entry["extra_flags"] = list(extra_flags)
    return entry


def upsert_roster(roster, entry) -> list[dict]:
    """Return a new roster list with ``entry`` upserted by label.

    Idempotent and non-destructive: a new label is appended at the end; an
    existing label is replaced in place (order preserved). The input list and
    its entries are never mutated.
    """
    out = [dict(e) for e in roster]
    for i, e in enumerate(out):
        if e.get("label") == entry["label"]:
            out[i] = dict(entry)
            return out
    out.append(dict(entry))
    return out


def build_onboard_plan(entry, roles) -> dict:
    """A tune-to-peak (use_recipe=False) plan for JUST this one model.

    Delegates to the shared gr.build_reaudit_plan so vision-drop / field
    carry-through / plan schema all stay identical to the re-score path.
    """
    return gr.build_reaudit_plan([entry], roles, use_recipe=False)


# ── disk validation (impure — CLI only) ──────────────────────────────────────

def validate_paths(gguf, mmproj=None) -> None:
    """Raise FileNotFoundError if the gguf (or given mmproj) is not on disk."""
    if not Path(gguf).exists():
        raise FileNotFoundError(f"--gguf not found on disk: {gguf}")
    if mmproj and not Path(mmproj).exists():
        raise FileNotFoundError(f"--mmproj not found on disk: {mmproj}")


def write_roster(path: Path, roster) -> None:
    """Write roster.json with the same formatting as the existing file."""
    Path(path).write_text(
        json.dumps(roster, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8")


# ── CLI ──────────────────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="onboard_model.py",
        description="Onboard a NEW model: upsert it into roster.json and "
                    "generate a tune-to-peak plan that creates its recipe.")
    p.add_argument("--label", required=True, help="roster label (unique id)")
    p.add_argument("--gguf", required=True, help="path to the model gguf")
    p.add_argument("--mmproj", default=None,
                   help="path to the vision mmproj (enables the vision role)")
    p.add_argument("--moe", choices=("on", "off"), default=None,
                   help="MoE offload mode")
    p.add_argument("--server-bin", default=None,
                   help="override llama-server binary (e.g. a fork)")
    p.add_argument("--extra-flags", nargs=argparse.REMAINDER, default=None,
                   help="extra llama-server flags; comma list or trailing "
                        "tokens, e.g. --extra-flags --reasoning off")
    p.add_argument("--roles", default=None,
                   help="comma list of roles (default: the FULL canonical "
                        "audit role set from model_audit.py)")
    p.add_argument("--tiers", default="vram12",
                   help="comma list of VRAM tiers (default: vram12)")
    p.add_argument("--roster", default=str(DEFAULT_ROSTER_PATH),
                   help=f"roster JSON (default: {DEFAULT_ROSTER_PATH})")
    p.add_argument("--out", default=None,
                   help="output plan path (default: results/onboard_<label>.json)")
    return p


def _parse_extra_flags(raw) -> list[str] | None:
    """Accept either REMAINDER tokens or a single comma list → flat list."""
    if not raw:
        return None
    if len(raw) == 1 and "," in raw[0]:
        return [s.strip() for s in raw[0].split(",") if s.strip()]
    return [s for s in raw if s]


def run(argv=None) -> int:
    args = build_parser().parse_args(argv)

    try:
        validate_paths(args.gguf, args.mmproj)
    except FileNotFoundError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    roles = ([r.strip() for r in args.roles.split(",") if r.strip()]
             if args.roles else canonical_audit_roles())
    tiers = tuple(t.strip() for t in args.tiers.split(",") if t.strip())

    entry = build_entry(args.label, args.gguf, mmproj=args.mmproj,
                        moe=args.moe, server_bin=args.server_bin,
                        extra_flags=_parse_extra_flags(args.extra_flags))

    # (b) upsert into roster.json — idempotent, non-destructive
    roster_path = Path(args.roster)
    roster = gr.load_roster(roster_path)
    roster = upsert_roster(roster, entry)
    write_roster(roster_path, roster)

    # (c) tune-to-peak plan for just this model
    plan = gr.build_reaudit_plan([entry], roles, use_recipe=False, tiers=tiers)
    out_path = Path(args.out) if args.out else \
        RESULTS_DIR / f"onboard_{args.label}.json"
    if not out_path.is_absolute():
        out_path = Path.cwd() / out_path
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8")

    # (d) print the launch command (do NOT run it)
    job_roles = plan["jobs"][0]["roles"] if plan["jobs"] else []
    print(f"roster: upserted '{args.label}' → {roster_path}")
    print(f"plan:   tune-to-peak on {len(job_roles)} roles → {out_path}")
    if args.mmproj is None:
        print("note:   no --mmproj → vision role dropped")
    print("\nLaunch it with (NOT run here):\n")
    print(gr.launch_command(out_path, unit=f"axi-onboard-{args.label}"))
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
