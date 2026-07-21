#!/usr/bin/env python3
"""gen_reaudit_plan.py — FAST re-score plan generator for the tuned roster.

The recurring case this solves: "we changed/added a benchmark task → update
just those role scores for EVERY already-tuned model", without re-tuning.

It reads the single-source-of-truth roster (roster.json) and emits a plan in
the exact shape audit_batches.py consumes ({"notes", "jobs": [...]}). Each job
re-audits one model on the requested roles at its SAVED recipe
(``use_recipe=True`` → Stages A/B/B2 skipped in model_audit.py, straight to the
quality/role eval at the stored peak). The rare full tune-to-peak case is
``--tune`` (use_recipe=False).

Vision is auto-dropped for models with no mmproj; a model left with zero roles
is skipped. moe/server_bin/extra_flags/mmproj are carried through verbatim.
Jobs are ordered fastest-first with qwen36-27b always last.

Usage
-----
  gen_reaudit_plan.py --roles codereview,codegen,vision,routing
  gen_reaudit_plan.py --roles longsum --tune          # full re-tune
  gen_reaudit_plan.py --roles vision --out results/vision_plan.json

Then launch (NOT run here — the printed systemd-run command does it):
  systemd-run --user --unit=axi-reaudit --collect \\
    --property=WorkingDirectory=$HOME/LifeOS/lifeos/axi \\
    $HOME/LifeOS/lifeos/lifeos/.venv/bin/python \\
    $HOME/LifeOS/lifeos/axi/scripts/bench/audit_batches.py run --plan <out>
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import model_audit as ma  # VALID_ROLES — single source of role names

RESULTS_DIR = SCRIPT_DIR / "results"
RECIPES_PATH = RESULTS_DIR / "model_recipes.json"
DEFAULT_ROSTER_PATH = SCRIPT_DIR / "roster.json"
REPO_ROOT = SCRIPT_DIR.parents[2]                    # …/LifeOS/lifeos
LIFEOS_PYTHON = REPO_ROOT / "lifeos" / ".venv" / "bin" / "python"
AUDIT_BATCHES = SCRIPT_DIR / "audit_batches.py"

# Fastest-first ordering (measured/expected decode tok/s), qwen36-27b LAST.
# Labels not listed sort AFTER the known ones but BEFORE qwen36-27b.
_ORDER = (
    "gemma4-e2b", "qwen35-0_8b", "qwen35-2b", "qwen35-4b", "gemma4-e4b",
    "vibethinker-3b", "qwen25-coder-3b", "laguna-xs-2.1",
    "bonsai-1bit", "bonsai-ternary", "gemma4-26b", "qwen3-omni-30b",
    "nemotron-cascade2-30b", "north-mini-code", "qwen36-35b",
)
_ORDER_INDEX = {label: i for i, label in enumerate(_ORDER)}
_LAST = len(_ORDER) + 1          # unknown labels
_ALWAYS_LAST = len(_ORDER) + 2   # qwen36-27b


def _order_key(label: str) -> int:
    if label == "qwen36-27b":
        return _ALWAYS_LAST
    return _ORDER_INDEX.get(label, _LAST)


# ── the pure, testable core ──────────────────────────────────────────────────

def filter_roster(roster, only=None, exclude=None) -> list[dict]:
    """Return the roster entries kept by ``--only`` / ``--exclude`` labels.

    ``only`` (when given) keeps just those labels; ``exclude`` drops labels.
    ``only`` is applied before ``exclude``. Order is preserved. Default (both
    ``None``) returns the roster unchanged. Raises ValueError for any label in
    ``only`` that is absent from the roster (a typo would otherwise silently
    score nothing).
    """
    kept = list(roster)
    if only:
        only = list(only)
        known = {e["label"] for e in kept}
        missing = [lbl for lbl in only if lbl not in known]
        if missing:
            raise ValueError(f"--only label(s) not in roster: {missing} — "
                             f"known: {sorted(known)}")
        keep = set(only)
        kept = [e for e in kept if e["label"] in keep]
    if exclude:
        drop = set(exclude)
        kept = [e for e in kept if e["label"] not in drop]
    return kept


def build_reaudit_plan(roster, roles, *, use_recipe=True,
                       tiers=("vram12",), thinking_modes=("none",),
                       recipes=None) -> dict:
    """Roster + requested roles → an audit_batches.py plan dict.

    - one job per roster model on ``roles`` (fastest-first, qwen36-27b last);
    - ``vision`` is dropped for models with no ``mmproj`` (mmproj omitted too);
      a model left with zero roles is skipped;
    - ``moe``/``server_bin``/``extra_flags``/``mmproj`` carried through when set;
    - ``use_recipe=True`` (default) = FAST re-score at the saved recipe;
      ``False`` = full tune-to-peak.
    - ``recipes`` (a ``{label: {tier: recipe}}`` dict, e.g. from
      ``model_audit.load_recipes``): only consulted on the FAST path
      (``use_recipe=True``). Any targeted model missing a saved recipe for a
      requested tier is OMITTED from the plan and a WARNING is printed to
      stderr — so the fast run never errors at bench time on an un-onboarded
      model. ``None`` (default) skips the pre-check entirely; a ``--tune`` plan
      (``use_recipe=False``) also skips it since tuning creates the recipe.

    Raises ValueError on an empty role list or any unknown role.
    """
    roles = list(roles)
    if not roles:
        raise ValueError("roles must be a non-empty list")
    bad = [r for r in roles if r not in ma.VALID_ROLES]
    if bad:
        raise ValueError(f"unknown role(s): {bad} — "
                         f"valid: {list(ma.VALID_ROLES)}")

    tiers = list(tiers)
    thinking_modes = list(thinking_modes)
    check_recipes = bool(use_recipe) and recipes is not None
    jobs: list[dict] = []
    for entry in sorted(roster, key=lambda e: _order_key(e["label"])):
        if check_recipes:
            missing_tiers = [t for t in tiers
                             if ma.get_recipe(recipes, entry["label"], t) is None]
            if missing_tiers:
                print(f"WARNING: {entry['label']}/{','.join(missing_tiers)} "
                      f"has no saved recipe — onboard it first with "
                      f"onboard_model.py (omitted from this fast plan).",
                      file=sys.stderr)
                continue
        has_mmproj = bool(entry.get("mmproj"))
        job_roles = [r for r in roles if not (r == "vision" and not has_mmproj)]
        if not job_roles:
            continue  # nothing left to score for this model
        job: dict = {
            "label": entry["label"],
            "gguf": entry["gguf"],
            "tiers": list(tiers),
            "thinking_modes": list(thinking_modes),
            "roles": job_roles,
            "use_recipe": bool(use_recipe),
        }
        if has_mmproj:
            job["mmproj"] = entry["mmproj"]
        for key in ("moe", "server_bin", "extra_flags"):
            if entry.get(key):
                job[key] = entry[key]
        jobs.append(job)

    mode = "FAST re-score at saved recipe (use_recipe)" if use_recipe \
        else "FULL tune-to-peak (use_recipe off)"
    notes = (f"Re-audit plan generated {datetime.now():%Y-%m-%d %H:%M} — "
             f"{mode}. Roles: {', '.join(roles)}. "
             f"vision auto-dropped for no-mmproj models. "
             f"Order: fastest-first, qwen36-27b last.")
    return {"notes": notes, "jobs": jobs}


# ── disk validation (impure — CLI only) ──────────────────────────────────────

def load_roster(path: Path) -> list[dict]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, list) or not data:
        raise ValueError(f"roster must be a non-empty JSON list: {path}")
    return data


def warn_missing_paths(roster) -> None:
    """Warn (stderr) for any gguf/mmproj/server_bin that isn't on disk."""
    for entry in roster:
        for key in ("gguf", "mmproj", "server_bin"):
            p = entry.get(key)
            if p and not Path(p).exists():
                print(f"WARNING: {entry.get('label', '?')}: {key} not found "
                      f"on disk: {p}", file=sys.stderr)


def launch_command(out_path: Path, unit: str = "axi-reaudit") -> str:
    """The exact systemd-run command that runs the generated plan."""
    return (
        f"systemd-run --user --unit={unit} --collect \\\n"
        f"  --property=WorkingDirectory={REPO_ROOT / 'axi'} \\\n"
        f"  {LIFEOS_PYTHON} \\\n"
        f"  {AUDIT_BATCHES} run \\\n"
        f"  --plan {out_path}"
    )


# ── CLI ──────────────────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="gen_reaudit_plan.py",
        description="Generate a FAST re-score plan (reuse each model's saved "
                    "recipe) for the roster on a chosen set of roles.")
    p.add_argument("--roles", required=True,
                   help="comma list of roles to re-score, e.g. "
                        "codereview,codegen,vision")
    p.add_argument("--roster", default=str(DEFAULT_ROSTER_PATH),
                   help=f"roster JSON (default: {DEFAULT_ROSTER_PATH})")
    p.add_argument("--only", default=None,
                   help="comma list of roster labels to include (default: all)")
    p.add_argument("--exclude", default=None,
                   help="comma list of roster labels to drop (default: none)")
    p.add_argument("--recipes", default=str(RECIPES_PATH),
                   help=f"recipe registry JSON for the FAST-path pre-check "
                        f"(default: {RECIPES_PATH})")
    p.add_argument("--out", default=None,
                   help="output plan path (default: "
                        "results/reaudit_<YYYYMMDD-HHMM>.json)")
    p.add_argument("--stamp", default=None,
                   help="fixed timestamp for the default --out name "
                        "(deterministic); ignored when --out is given")
    p.add_argument("--tune", action="store_true",
                   help="full tune-to-peak (use_recipe off) — the rare case")
    p.add_argument("--tiers", default="vram12",
                   help="comma list of VRAM tiers (default: vram12)")
    p.add_argument("--thinking-modes", default="none",
                   help="comma list of thinking modes (default: none)")
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    roles = [r.strip() for r in args.roles.split(",") if r.strip()]
    tiers = tuple(t.strip() for t in args.tiers.split(",") if t.strip())
    thinking = tuple(t.strip() for t in args.thinking_modes.split(",")
                     if t.strip())

    roster = load_roster(Path(args.roster))
    only = [s.strip() for s in args.only.split(",") if s.strip()] \
        if args.only else None
    exclude = [s.strip() for s in args.exclude.split(",") if s.strip()] \
        if args.exclude else None
    roster = filter_roster(roster, only=only, exclude=exclude)
    warn_missing_paths(roster)

    use_recipe = not args.tune
    # FAST path: pre-check saved recipes so the bench never errors on an
    # un-onboarded model. --tune skips it (tuning creates the recipe).
    recipes = ma.load_recipes(Path(args.recipes)) if use_recipe else None
    plan = build_reaudit_plan(roster, roles, use_recipe=use_recipe,
                              tiers=tiers, thinking_modes=thinking,
                              recipes=recipes)

    if args.out:
        out_path = Path(args.out)
    else:
        stamp = args.stamp or f"{datetime.now():%Y%m%d-%H%M}"
        out_path = RESULTS_DIR / f"reaudit_{stamp}.json"
    if not out_path.is_absolute():
        out_path = (Path.cwd() / out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8")

    print(f"wrote {len(plan['jobs'])} jobs → {out_path}")
    vision_models = [j["label"] for j in plan["jobs"] if "vision" in j["roles"]]
    print(f"vision on {len(vision_models)} models: {', '.join(vision_models)}"
          if vision_models else "vision: not in requested roles")
    print("\nLaunch it with (NOT run here):\n")
    print(launch_command(out_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
