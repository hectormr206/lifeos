"""Hardware-aware automatic model selection for a fresh LifeOS install.

Goal: a fresh install should end up with the BEST brain model for the user's
machine, pre-tuned, with ZERO manual decisions. We detect VRAM (NVIDIA) and
system RAM, map the machine to a hardware tier, and return a recommended
catalog model id plus tuned llama-server params (context window, GPU offload,
KV-cache dtype, MoE offload) that fit the budget AND run well.

This module is PURE and DETERMINISTIC for selection: `select_model(profile)`
takes a `HardwareProfile` and returns `(model_id, params)`. Detection is the
only impure part and is isolated behind small, monkeypatchable helpers
(`_query_nvidia_vram_mib`, `_query_system_ram_kib`) so tests can inject any
machine shape. Detection is strictly READ-ONLY (parses `nvidia-smi
--query-gpu` and `/proc/meminfo`); it never loads a model or runs a GPU
workload.

Scope: the BIG brain model only. The CPU/RAM nano-agents are out of scope and
untouched.

Empirical anchor vs. derived numbers
-------------------------------------
VRAM tiers for 4 GB, 8 GB, and 12 GB are EMPIRICALLY PROVEN from the
2026-06-09/10 bench run on a 12 GB RTX 5070 Ti:

  qwen36-35b-a3b @ ngl=999, --cpu-moe:  27.4 tok/s, 5028 MiB peak VRAM
  qwen36-35b-a3b @ ngl=20, --cpu-moe:   15.6 tok/s, 3546 MiB peak VRAM
  gemma4-e2b-it @ ngl=999:             193   tok/s, 3342 MiB peak VRAM

CPU/RAM tiers use measured idle RSS as the weight footprint anchor:
  qwen36-35b-a3b CPU RSS: ~23073 MB (measured)
  gemma4-e2b-it  CPU RSS:  ~4631 MB (measured)

Cut from catalog (2026-06-10):
  gemma4-e4b-it: dominated by gemma4-e2b-it (e2b quality 0.698>0.665, faster,
    smaller) — no tier where e4b is strictly better.
  gemma4-26b-a4b-it: measured CPU RSS = 18.5 GB (gguf 16 GB). With
    reserve=max(25%×tier,3GB) it fails 22 GB (18.5+5.5=24>22) and
    24 GB (18.5+6=24.5>24). Its only safe niche (~26–31 GB) is bordered by
    the 35B at 32 GB — owns no common tier.

Reserve rule for CPU/RAM tiers:
  reserve = max(25% of tier_RAM, 3 GB)
  Tier qualifies when: weights_RSS + KV(ctx) + reserve <= tier_RAM

MoE entries (e.g. qwen36-35b-a3b) use ``--cpu-moe``: the experts live in CPU
RAM and only attention + KV + the active expert sit on the GPU, so the GPU
footprint is ~5 GB regardless of the 35B total. On a pure-CPU machine the
same MoE runs with ``ngl=0`` (everything in RAM); it needs enough system RAM
to hold the full weight RSS.

Tune the table, not the code.
"""
from __future__ import annotations

import logging
import shutil
import subprocess
from dataclasses import dataclass, field

log = logging.getLogger("axi.hardware")


# ────────────────────────── data shapes ──────────────────────────


@dataclass(frozen=True)
class HardwareProfile:
    """Read-only snapshot of the machine relevant to brain-model selection."""

    has_nvidia: bool
    gpu_name: str
    vram_gb: float
    ram_gb: float
    compute_kind: str  # "cuda" | "cpu"


@dataclass(frozen=True)
class HardwareTier:
    """One declarative (compute_kind, budget) -> model + tuned params row.

    `min_budget_gb` is the lower bound of the tier: a machine qualifies for
    this tier when its budget (VRAM for cuda, RAM for cpu) is >= min_budget_gb.
    Tiers are scanned high→low, so the first match is the best fit.

    `params` are llama-server overrides keyed by `model_params_schema` keys
    (plus ctx/ngl). They are written verbatim into the per-model overrides the
    launcher reads, on top of the catalog baseline.

    `empirical` marks the one PROVEN row (12 GB). `budget_math` documents how a
    DERIVED row's numbers were obtained.
    """

    compute_kind: str
    min_budget_gb: float
    label: str
    model_id: str
    params: dict = field(default_factory=dict)
    empirical: bool = False
    budget_math: str = ""


@dataclass(frozen=True)
class Recommendation:
    """Result of detect + select, for the installer UX."""

    profile: HardwareProfile
    tier: HardwareTier
    model_id: str
    params: dict


# ────────────────────────── the tier table ────────────────────────
#
# PROVEN q8_0 KV cache + cpu-moe baseline mirrors _QWEN36_ARGS / axi-llama-
# launch defaults. Only the knobs that differ per tier are listed; the rest of
# the byte-identical baseline comes from the catalog entry.

# qwen36-35b-a3b weights are MXFP4 MoE on disk (~22 GB); with --cpu-moe the GPU
# only carries attention + KV + active expert (~7–8 GB at 32k ctx, q8_0 KV).
_MOE_BRAIN = "qwen36-35b-a3b"

HARDWARE_TIERS: tuple[HardwareTier, ...] = (
    # ── CUDA / VRAM tiers (high → low) ──────────────────────────────
    # All three tiers below (12, 8, 4 GB) are EMPIRICALLY anchored to the
    # 2026-06-09 bench run on the 12 GB RTX 5070 Ti. Higher tiers (16, 24 GB)
    # are derived by extending the same --cpu-moe layout.
    HardwareTier(
        compute_kind="cuda",
        min_budget_gb=24.0,
        label="24 GB+ VRAM",
        model_id=_MOE_BRAIN,
        params={"ngl": 999, "ctx": 65536, "cpu_moe": True,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "MoE brain via --cpu-moe: GPU carries attention+KV+active expert. "
            "Empirical 12 GB base = 5028 MiB peak. At 65536 ctx, q8_0 KV adds "
            "~2 GB extra; total ~9 GB << 24 GB. Doubled ctx vs 12 GB tier — "
            "more VRAM gives headroom for larger context, not a model upgrade. "
            "DERIVED from empirical 12 GB anchor."
        ),
    ),
    HardwareTier(
        compute_kind="cuda",
        min_budget_gb=16.0,
        label="16 GB VRAM",
        model_id=_MOE_BRAIN,
        params={"ngl": 999, "ctx": 49152, "cpu_moe": True,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "Same MoE/--cpu-moe pattern as 12 GB. Empirical 5028 MiB base at "
            "32k ctx; +49152 ctx q8_0 KV adds ~1.5 GB extra ≈ 7.5 GB < 16 GB. "
            "DERIVED from empirical 12 GB anchor."
        ),
    ),
    HardwareTier(
        compute_kind="cuda",
        # 11.5, not 12.0: a "12 GB" card reports ~11.9 GiB usable (e.g. the
        # reference RTX 5070 Ti = 12227 MiB ≈ 11.94 GiB). Floor below that so
        # real 12 GB hardware lands on the PROVEN config, not the 8 GB tier.
        min_budget_gb=11.5,
        label="12 GB VRAM (proven)",
        model_id=_MOE_BRAIN,
        # PROVEN: measured 5028 MiB peak, 27.4 tok/s on RTX 5070 Ti.
        params={"ngl": 999, "ctx": 32768, "cpu_moe": True,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=True,
        budget_math=(
            "EMPIRICAL (2026-06-09): measured 5028 MiB VRAM peak, 27.4 tok/s "
            "on 12 GB RTX 5070 Ti. qwen36-35b-a3b MXFP4 MoE with --cpu-moe, "
            "32768 ctx, q8_0 KV. Ground truth — this is prod today."
        ),
    ),
    HardwareTier(
        compute_kind="cuda",
        min_budget_gb=8.0,
        label="8 GB VRAM",
        model_id=_MOE_BRAIN,
        params={"ngl": 999, "ctx": 32768, "cpu_moe": True,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "DERIVED. 5028 MiB measured on 12 GB RTX 5070 Ti; fits 8 GB by inspection "
            "(~3 GB headroom), NOT tested on 8 GB hardware. "
            "qwen36-35b-a3b MXFP4 MoE, ngl=999, --cpu-moe, 32768 ctx, q8_0 KV. "
            "27.4 tok/s on 12 GB; 8 GB performance unverified."
        ),
    ),
    HardwareTier(
        compute_kind="cuda",
        min_budget_gb=4.0,
        label="4 GB VRAM",
        model_id="gemma4-e2b-it",
        params={"ngl": 999, "ctx": 16384, "cpu_moe": False,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=True,
        budget_math=(
            "EMPIRICAL (2026-06-09): gemma4-e2b-it measured 3342 MiB VRAM, "
            "193 tok/s (full GPU, ngl=999). Fits 4 GB with ~660 MiB headroom. "
            "Quality det=0.657, vision capable. "
            "Alt: 35B @ ngl=20 --cpu-moe = 3546 MiB, 15.6 tok/s, det=0.771 "
            "(max quality but ~16 tok/s — prefer for background/async use). "
            "Default pick: gemma4-e2b for interactive latency at this tier."
        ),
    ),
    HardwareTier(
        compute_kind="cuda",
        min_budget_gb=0.0,  # safety floor: any usable CUDA VRAM below 4 GB
        label="<4 GB VRAM (smallest)",
        model_id="gemma4-e2b-it",
        params={"ngl": 999, "ctx": 8192, "cpu_moe": False,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "Floor tier. gemma4-e2b-it measured 3342 MiB at 16k ctx; at 8k ctx "
            "slightly less — fits any GPU that reports usable VRAM. DERIVED from "
            "empirical 3342 MiB anchor."
        ),
    ),
    # ── CPU / RAM tiers (high → low) ────────────────────────────────
    # Reserve rule: reserve = max(25% of tier_RAM, 3 GB).
    # Tier qualifies when: weights_RSS + KV(ctx) + reserve <= tier_RAM.
    # Measured RSS: 35B=23073 MB, e2b=4631 MB.
    # gemma4-26b (18.5 GB RSS) and gemma4-e4b-it removed — see module docstring.
    HardwareTier(
        compute_kind="cpu",
        min_budget_gb=64.0,
        label="CPU, 64 GB RAM",
        model_id=_MOE_BRAIN,
        params={"ngl": 0, "ctx": 32768, "cpu_moe": True,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "DERIVED. Reserve = max(25% × 64, 3) = 16 GB. "
            "35B RSS 23073 MB + KV@32k ~1 GB + reserve 16 GB = ~40 GB < 64 GB. "
            "Ample headroom; run at full 32k ctx."
        ),
    ),
    HardwareTier(
        compute_kind="cpu",
        min_budget_gb=32.0,
        label="CPU, 32 GB RAM",
        model_id=_MOE_BRAIN,
        params={"ngl": 0, "ctx": 8192, "cpu_moe": True,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "DERIVED. Reserve = max(25% × 32, 3) = 8 GB. "
            "35B RSS 23073 MB + KV@8k ~750 MB + reserve 8192 MB ≈ 32 GB with small margin. "
            "ctx=16384 was unsafe: KV@16k ~1.5 GB (q8_0) pushes total to ~32.8 GB > 32 GB → OOM. "
            "Dropped to 8k ctx to keep KV ~0.75 GB and preserve ~1.5 GB real margin. "
            "Measured 35B CPU RSS = 23073 MB (empirical)."
        ),
    ),
    HardwareTier(
        compute_kind="cpu",
        min_budget_gb=24.0,
        label="CPU, 24 GB RAM",
        model_id="gemma4-e2b-it",
        params={"ngl": 0, "ctx": 8192, "cpu_moe": False,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "DERIVED. Reserve = max(25% × 24, 3) = 6 GB. "
            "35B RSS ~23073 MB + reserve 6 GB = ~29 GB > 24 GB → 35B does NOT fit. "
            "gemma4-26b (measured RSS ~18.5 GB) also fails: 18.5+6=24.5 GB > 24 GB. "
            "gemma4-e2b measured RSS 4631 MB + KV@8k ~0.3 GB + reserve 6 GB ≈ 10.9 GB < 24 GB. "
            "Fits with large headroom. 26b removed (18.5 GB RSS exceeds 22/24 GB tiers with reserve)."
        ),
    ),
    HardwareTier(
        compute_kind="cpu",
        min_budget_gb=16.0,
        label="CPU, 16 GB RAM",
        model_id="gemma4-e2b-it",
        params={"ngl": 0, "ctx": 8192, "cpu_moe": False,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "DERIVED. Reserve = max(25% × 16, 3) = 4 GB. "
            "gemma4-e2b measured RSS 4631 MB + KV@8k ~0.3 GB + reserve 4 GB ≈ 8.9 GB < 16 GB. "
            "e4b (cut) is dominated by e2b on quality and footprint — e2b is the strict improvement. "
            "Measured RSS = 4631 MB (empirical)."
        ),
    ),
    HardwareTier(
        compute_kind="cpu",
        min_budget_gb=12.0,
        label="CPU, 12 GB RAM",
        model_id="gemma4-e2b-it",
        params={"ngl": 0, "ctx": 8192, "cpu_moe": False,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "DERIVED. Reserve = max(25% × 12, 3) = 3 GB. "
            "gemma4-e4b RSS 6810 MB + reserve 3 GB = ~9.8 GB < 12 GB → e4b fits, "
            "but e2b dominates e4b on quality AND speed AND footprint in our bench data. "
            "gemma4-e2b measured RSS 4631 MB + KV@8k ~0.3 GB + reserve 3 GB ≈ 7.9 GB < 12 GB. "
            "Prefer e2b wherever both fit. Measured RSS = 4631 MB (empirical)."
        ),
    ),
    HardwareTier(
        compute_kind="cpu",
        min_budget_gb=8.0,
        label="CPU, 8 GB RAM",
        model_id="gemma4-e2b-it",
        params={"ngl": 0, "ctx": 8192, "cpu_moe": False,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "DERIVED. Reserve = max(25% × 8, 3) = 3 GB. "
            "gemma4-e2b measured RSS 4631 MB + KV@8k ~0.3 GB + reserve 3 GB ≈ 7.9 GB < 8 GB. "
            "Fits with ~100 MB margin — use 8k ctx to minimise KV pressure. "
            "Measured RSS = 4631 MB (empirical)."
        ),
    ),
    HardwareTier(
        compute_kind="cpu",
        min_budget_gb=0.0,  # floor
        label="CPU, <8 GB RAM (smallest)",
        model_id="gemma4-e2b-it",
        params={"ngl": 0, "ctx": 4096, "cpu_moe": False,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "Floor tier. gemma4-e2b RSS ~4.5 GB + tiny KV at 4k ctx — "
            "smallest catalog model; never returns nothing. DERIVED."
        ),
    ),
)


# ────────────────────────── detection (impure, read-only) ─────────


def _query_nvidia_vram_mib() -> tuple[int, str] | None:
    """Return (total_vram_mib, gpu_name) for the first NVIDIA GPU, or None.

    READ-ONLY: shells out to `nvidia-smi --query-gpu=memory.total,name`. Never
    loads a model. Returns None if nvidia-smi is missing or fails.
    """
    if shutil.which("nvidia-smi") is None:
        return None
    try:
        out = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=memory.total,name",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return None
    first = out.strip().splitlines()[0] if out.strip() else ""
    if not first:
        return None
    # Format: "12227, NVIDIA GeForce RTX 5070 Ti Laptop GPU"
    mib_str, _, name = first.partition(",")
    try:
        mib = int(float(mib_str.strip()))
    except ValueError:
        return None
    return mib, name.strip()


def _query_system_ram_kib() -> int:
    """Return MemTotal from /proc/meminfo in KiB, or 0 if unavailable.

    READ-ONLY.
    """
    try:
        with open("/proc/meminfo", "r", encoding="ascii") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    # "MemTotal:       98567848 kB"
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return 0


# A GPU reporting less than this many MiB of VRAM is treated as unusable and we
# fall back to CPU/RAM selection.
_MIN_USABLE_VRAM_MIB = 512


def detect_hardware() -> HardwareProfile:
    """Detect VRAM, GPU vendor, and system RAM. Pure of model loading; only
    reads nvidia-smi + /proc/meminfo."""
    ram_gb = round(_query_system_ram_kib() / (1024 * 1024), 2)
    nv = _query_nvidia_vram_mib()
    if nv is not None and nv[0] >= _MIN_USABLE_VRAM_MIB:
        mib, name = nv
        return HardwareProfile(
            has_nvidia=True,
            gpu_name=name,
            vram_gb=round(mib / 1024, 2),
            ram_gb=ram_gb,
            compute_kind="cuda",
        )
    return HardwareProfile(
        has_nvidia=False,
        gpu_name=nv[1] if nv else "",
        vram_gb=0.0,
        ram_gb=ram_gb,
        compute_kind="cpu",
    )


# ────────────────────────── selection (pure) ──────────────────────


def _tiers_for(compute_kind: str) -> list[HardwareTier]:
    """Tiers for a compute kind, high→low budget (already authored that way)."""
    return [t for t in HARDWARE_TIERS if t.compute_kind == compute_kind]


def pick_tier(profile: HardwareProfile) -> HardwareTier:
    """Map a profile to its best-fitting tier via a high→low budget scan.

    Fallback chain is implicit in the table ordering: the largest tier whose
    `min_budget_gb` the machine satisfies wins; if VRAM is below every CUDA
    tier floor we still hit the 0.0-floor CUDA tier (smallest GPU model); a CPU
    machine scans the CPU tiers down to the 0.0 floor. We therefore always
    return a tier — never None.
    """
    budget = profile.vram_gb if profile.compute_kind == "cuda" else profile.ram_gb
    for tier in _tiers_for(profile.compute_kind):
        if budget >= tier.min_budget_gb:
            return tier
    # Defensive: a 0.0-floor tier always exists per compute_kind, so this is
    # only reached if the table is misconfigured. Return the last (smallest).
    return _tiers_for(profile.compute_kind)[-1]


def select_model(profile: HardwareProfile) -> tuple[str, dict]:
    """Return (model_id, params) for the machine. Pure + deterministic.

    `params` is a copy of the tier's tuned overrides, safe for the caller to
    mutate (e.g. install writing them to the overrides file).
    """
    tier = pick_tier(profile)
    return tier.model_id, dict(tier.params)


def recommend() -> Recommendation:
    """Detect the machine and select the recommended model in one call.

    This is the installer entry point: detect → tier → model + tuned params.
    """
    profile = detect_hardware()
    tier = pick_tier(profile)
    return Recommendation(
        profile=profile,
        tier=tier,
        model_id=tier.model_id,
        params=dict(tier.params),
    )


__all__ = [
    "HardwareProfile",
    "HardwareTier",
    "Recommendation",
    "HARDWARE_TIERS",
    "detect_hardware",
    "pick_tier",
    "select_model",
    "recommend",
]
