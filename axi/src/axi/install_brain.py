"""Installer-facing glue: turn a hardware recommendation into a download plan,
a human report, and the on-disk config the launcher reads.

This is the bridge between `hardware_profile.recommend()` (what model fits this
machine) and `models_manager` (download + activate + per-model overrides). The
installer (`install.sh`) shells out to this module so the bash side stays thin
and all the real logic is unit-tested Python.

Responsibilities
----------------
- `format_report(rec)`     → human-readable "detected X → chose Y" text.
- `download_plan(rec)`      → which catalog files to fetch (repo_id/filename),
                              consumed by install.sh's `hf_get`.
- `write_recommended_config(rec)` → persist the tuned params as per-model
                              overrides AND write active_model.json so
                              axi-llama-launch / models_manager pick them up.
- `main(argv)`              → CLI: `--report` (human), `--json` (machine),
                              `--write-config` (activate without download).

The BIG brain model only. Nano-agents are untouched.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

from axi import hardware_profile as hp
from axi import models_manager
from axi.models_catalog import by_id


# ────────────────────────── recommendation resolution ────────────


def resolve_recommendation() -> hp.Recommendation:
    """Detect hardware and recommend a model, honoring the AXI_BRAIN_MODEL
    override.

    Default behavior is fully automatic (hardware → tier → model). If
    AXI_BRAIN_MODEL names a known catalog model, that model is pinned instead;
    we still attach tuned params from the best-matching tier for the detected
    compute kind (or fall back to the detected tier's params). An unknown
    override id is ignored, so a typo never breaks the install.
    """
    rec = hp.recommend()
    override = os.environ.get("AXI_BRAIN_MODEL", "").strip()
    if not override or by_id(override) is None:
        return rec
    # Reuse a tier's tuned params if one targets this model on the same compute
    # kind; otherwise keep the auto-detected tier's params as a sane default.
    params = rec.params
    tier = rec.tier
    for t in hp.HARDWARE_TIERS:
        if t.model_id == override and t.compute_kind == rec.profile.compute_kind:
            params = dict(t.params)
            tier = t
            break
    return hp.Recommendation(
        profile=rec.profile, tier=tier, model_id=override, params=params,
    )


# ────────────────────────── report ───────────────────────────────


def format_report(rec: hp.Recommendation) -> str:
    """Human-readable detection + choice summary for the installer."""
    p = rec.profile
    entry = by_id(rec.model_id)
    name = entry.name if entry else rec.model_id
    lines: list[str] = []
    if p.compute_kind == "cuda":
        lines.append(
            f"Detected: NVIDIA GPU '{p.gpu_name}' with {p.vram_gb:.1f} GB VRAM "
            f"({p.ram_gb:.0f} GB system RAM)."
        )
    else:
        gpu = f" (GPU '{p.gpu_name}' present but no usable VRAM)" if p.gpu_name else ""
        lines.append(
            f"Detected: no usable GPU VRAM{gpu}; falling back to CPU with "
            f"{p.ram_gb:.0f} GB system RAM."
        )
    lines.append(f"Tier:     {rec.tier.label}")
    lines.append(f"Chosen:   {name} [{rec.model_id}]")
    ctx = rec.params.get("ctx")
    ngl = rec.params.get("ngl")
    moe = rec.params.get("cpu_moe", False)
    knobs = f"ctx={ctx}, ngl={ngl}" + (", --cpu-moe" if moe else "")
    lines.append(f"Tuned:    {knobs}")
    if rec.tier.empirical:
        lines.append("          (empirically validated config)")
    return "\n".join(lines)


# ────────────────────────── download plan ────────────────────────


def download_plan(rec: hp.Recommendation) -> dict:
    """Files the installer must fetch for the recommended model.

    Returns a dict suitable for JSON: the catalog entry id, its target
    directory name, and a list of {repo_id, filename, kind}. Files whose
    repo_id is 'local' (the legacy Qwen bundle) are flagged so the installer
    can fall back to its historical download path.
    """
    entry = by_id(rec.model_id)
    if entry is None:
        return {"model_id": rec.model_id, "dir": rec.model_id, "files": [], "local": True}
    files = [
        {"repo_id": f.repo_id, "filename": f.filename, "kind": f.kind,
         "local_name": f.local_name}
        for f in entry.files
    ]
    return {
        "model_id": entry.id,
        "dir": models_manager.model_dir(entry).name,
        "files": files,
        "local": any(f.repo_id == "local" for f in entry.files),
    }


# ────────────────────────── write config ─────────────────────────


def write_recommended_config(rec: hp.Recommendation, *, restart: bool = True) -> None:
    """Persist the tuned params as per-model overrides and activate the model.

    Steps:
      1. Merge the tier's tuned params into model_overrides.json under the
         recommended model id (preserving any pre-existing overrides for other
         models).
      2. Write active_model.json for the model WITH those overrides applied, so
         axi-llama-launch reads the tuned ctx/ngl/extra_args.
      3. Optionally restart llama-server (skipped in tests / when files are not
         yet present).

    This wires the recommendation end-to-end into the launcher's config — the
    same files models_manager and the dashboard model selector already use, so
    the manual override path keeps working.
    """
    entry = by_id(rec.model_id)
    if entry is None:
        raise ValueError(f"recommended model {rec.model_id!r} not in catalog")

    overrides = models_manager.load_overrides()
    overrides[rec.model_id] = {**overrides.get(rec.model_id, {}), **rec.params}
    models_manager.save_overrides(overrides)

    # write_active(overrides=None) re-loads the on-disk overrides we just saved.
    models_manager.write_active(entry, overrides=None)

    if restart:
        try:
            models_manager._systemctl_restart_llama()
        except Exception:  # noqa: BLE001 — installer should not abort on this
            pass


# ────────────────────────── CLI ──────────────────────────────────


def _json_payload(rec: hp.Recommendation) -> dict:
    plan = download_plan(rec)
    return {
        "compute_kind": rec.profile.compute_kind,
        "gpu_name": rec.profile.gpu_name,
        "vram_gb": rec.profile.vram_gb,
        "ram_gb": rec.profile.ram_gb,
        "tier": rec.tier.label,
        "empirical": rec.tier.empirical,
        "model_id": rec.model_id,
        "params": rec.params,
        "dir": plan["dir"],
        "files": plan["files"],
        "local": plan["local"],
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="axi-install-brain",
        description="Hardware-aware brain-model recommendation for install.",
    )
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--report", action="store_true",
                   help="print a human-readable detection + choice summary")
    g.add_argument("--json", action="store_true",
                   help="print a machine-readable recommendation (for install.sh)")
    g.add_argument("--write-config", action="store_true",
                   help="activate the recommended model + tuned params "
                        "(no download, no restart unless --restart)")
    ap.add_argument("--restart", action="store_true",
                    help="with --write-config, also restart llama-server")
    args = ap.parse_args(argv)

    rec = resolve_recommendation()

    if args.json:
        print(json.dumps(_json_payload(rec)))
        return 0
    if args.write_config:
        write_recommended_config(rec, restart=args.restart)
        print(format_report(rec))
        return 0
    # Default + --report.
    print(format_report(rec))
    return 0


__all__ = [
    "resolve_recommendation",
    "format_report",
    "download_plan",
    "write_recommended_config",
    "main",
]


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
