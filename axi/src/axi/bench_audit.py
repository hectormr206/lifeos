"""Pure, read-only helpers for the model-audit dashboard page.

This module aggregates ``scripts/bench/results/model_audit.jsonl`` and
``model_recipes.json`` for display in ``/models/audit``. Those files are
owned and appended-to by the bench harness (``scripts/bench/model_audit.py``)
— this module MUST NEVER write to them, only read.
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Role -> ordered candidate keys for its headline scalar metric. The first
# key present with a numeric value wins (e.g. brain prefers "final" but
# falls back to "det" when the LLM-judge subjective pass didn't run).
_ROLE_HEADLINE_KEYS: dict[str, tuple[str, ...]] = {
    "brain": ("final", "det"),
    "extraction": ("case_pass_rate",),
    "domain": ("overall_accuracy",),
    "toolcall": ("score",),
    "vision": ("pass_rate",),
    "codereview": ("score",),
    "codegen": ("pass_rate",),
    "conversation": ("judge_score",),
    "recordsqa": ("pass_rate",),
    "narration": ("numeric_fidelity_rate",),
    "longsum": ("pass_rate",),
    "parsejson": ("pass_rate",),
    "agentic": ("pass_rate",),
    "proactive": ("pass_rate",),
    "visionclass": ("pass_rate",),
    "devplan": ("pass_rate",),
    "toolstress": ("pass_rate",),
    "speed": ("decode_p50_toks_s",),
    "ctxprobe": ("ctx_max_current",),
}

# Roles counted toward the 0-1 "overall" quality average. Speed and ctxprobe
# are excluded: tok/s and max-context-tokens live on different scales
# entirely (capacity, not a 0-1 quality score).
_OVERALL_ROLES: tuple[str, ...] = tuple(
    role for role in _ROLE_HEADLINE_KEYS if role not in ("speed", "ctxprobe")
)


def results_dir() -> Path:
    """Resolve ``axi/scripts/bench/results`` relative to this package.

    Computed from ``__file__`` so it works in any checkout/worktree — never
    hardcode an absolute home path.
    """
    # __file__ = .../axi/src/axi/bench_audit.py
    # parents[0] = src/axi, parents[1] = src, parents[2] = axi (package root)
    return Path(__file__).resolve().parents[2] / "scripts" / "bench" / "results"


def _role_headline(role_value: Any, keys: tuple[str, ...]) -> float | None:
    """Extract one role's headline scalar, or None if skipped/missing."""
    if not isinstance(role_value, dict):
        return None
    if "skipped" in role_value:
        return None
    for key in keys:
        val = role_value.get(key)
        if isinstance(val, (int, float)) and not isinstance(val, bool):
            return float(val)
    return None


def summarize_roles(roles: dict[str, Any]) -> dict[str, float | None]:
    """Map every known role to its headline scalar (None if missing/skipped)."""
    return {
        role: _role_headline(roles.get(role), keys)
        for role, keys in _ROLE_HEADLINE_KEYS.items()
    }


def compute_overall(summary: dict[str, float | None]) -> tuple[float | None, int]:
    """Mean of the 0-1 quality role headline metrics (speed excluded).

    Missing/skipped roles are skipped rather than counted as 0 — a partial
    audit's overall only reflects roles that actually ran.

    Returns ``(overall, roles_counted)``; ``overall`` is None when no
    quality role has scored yet.
    """
    values = [
        summary[role] for role in _OVERALL_ROLES if summary.get(role) is not None
    ]
    if not values:
        return None, 0
    return sum(values) / len(values), len(values)


def load_audit_rows(jsonl_path: Path) -> list[dict[str, Any]]:
    """Read model_audit.jsonl and MERGE rows per (label, tier).

    Rows are merged in chronological order: top-level fields come from the
    newest row, but ``roles`` are overlaid PER ROLE (a newer row's roles
    update only the roles it actually ran). This matters for backfills — a
    targeted re-run like ``--use-recipe --roles visionclass`` appends a row
    containing only that role, and it must fill the gap in the model's card
    rather than clobber the full audit. Malformed lines are skipped.
    """
    if not jsonl_path.exists():
        return []

    grouped: dict[tuple[str, str], list[dict[str, Any]]] = {}
    with jsonl_path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(row, dict) or "label" not in row or "tier" not in row:
                continue
            grouped.setdefault((row["label"], row["tier"]), []).append(row)

    merged_rows: list[dict[str, Any]] = []
    for rows in grouped.values():
        rows.sort(key=lambda r: r.get("timestamp_utc") or "")
        merged = dict(rows[-1])  # newest row wins for top-level fields
        roles: dict[str, Any] = {}
        for row in rows:  # chronological — later rows overlay per role
            row_roles = row.get("roles")
            if isinstance(row_roles, dict):
                roles.update(row_roles)
        merged["roles"] = roles
        merged_rows.append(merged)
    return merged_rows


def load_recipes(recipes_path: Path) -> dict[str, Any]:
    """Read model_recipes.json; empty dict when missing or malformed."""
    if not recipes_path.exists():
        return {}
    try:
        data = json.loads(recipes_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def build_audit_payload(results_dir_path: Path) -> dict[str, Any]:
    """Build the full ``/api/bench/audit`` payload: ranked audits + recipes."""
    rows = load_audit_rows(results_dir_path / "model_audit.jsonl")
    recipes = load_recipes(results_dir_path / "model_recipes.json")

    augmented: list[dict[str, Any]] = []
    for row in rows:
        summary = summarize_roles(row.get("roles") or {})
        overall, roles_counted = compute_overall(summary)
        item = dict(row)
        item["role_summary"] = summary
        item["overall"] = overall
        item["roles_counted"] = roles_counted
        augmented.append(item)

    # Ranking order: overall DESC, missing-overall rows sort last.
    augmented.sort(key=lambda r: (r["overall"] is None, -(r["overall"] or 0.0)))

    return {
        "audits": augmented,
        "recipes": recipes,
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }
