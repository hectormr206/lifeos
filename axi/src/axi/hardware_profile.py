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
The 12 GB VRAM tier is the EMPIRICALLY PROVEN config: it mirrors what runs
today on a 12 GB RTX 5070 Ti (`qwen36-35b-a3b` MoE with `--cpu-moe`, 32k ctx,
q8_0 KV cache). It is marked ``empirical=True`` below.

Every other tier is DERIVED (``empirical=False``) from each catalog model's
VRAM estimate plus llama.cpp budget math:

    GPU budget ≈ weights(Q4_K_M ≈ params_B * 0.55 GB) + KV-cache(ctx) + ~1 GB
                 CUDA/runtime overhead.

MoE entries (e.g. qwen36-35b-a3b) use ``--cpu-moe``: the experts live in CPU
RAM and only attention + KV + the active expert sit on the GPU, so the GPU
footprint is ~7–8 GB regardless of the 35B total — which is why the MoE brain
still fits at 8 GB. On a pure-CPU machine the same MoE runs with ``ngl=0``
(everything in RAM); it needs enough system RAM to hold the weights.

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
            "At 65536 ctx, q8_0 KV ≈ 2.0 GB; +attention/active ≈ 6 GB; +1 GB "
            "overhead ≈ 9 GB << 24 GB. Doubled ctx is the only headroom gain — "
            "more VRAM does not help an MoE whose experts are on CPU. DERIVED."
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
            "Same MoE/--cpu-moe pattern as 12 GB. ~8 GB base + larger KV for "
            "49152 ctx (q8_0 ≈ 1.5 GB) ≈ 10 GB < 16 GB. Bump ctx vs 12 GB. "
            "DERIVED."
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
        # PROVEN: exactly Hector's running config. ngl=999/ctx=32768/cpu-moe
        # match the catalog baseline (_QWEN36_ARGS) so this is byte-identical
        # to what runs today; we still write them explicitly for clarity.
        params={"ngl": 999, "ctx": 32768, "cpu_moe": True,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=True,
        budget_math=(
            "EMPIRICAL: the config running today on a 12 GB RTX 5070 Ti. MoE "
            "35B-A3B with --cpu-moe, 32768 ctx, q8_0 KV — fits in ~8 GB with "
            "headroom for Whisper/translate. Ground truth, not derived."
        ),
    ),
    HardwareTier(
        compute_kind="cuda",
        min_budget_gb=8.0,
        label="8 GB VRAM",
        model_id=_MOE_BRAIN,
        # Tighter KV (q4_0) to keep the MoE attention+KV comfortably under 8 GB.
        params={"ngl": 999, "ctx": 16384, "cpu_moe": True,
                "cache_type_k": "q4_0", "cache_type_v": "q4_0"},
        empirical=False,
        budget_math=(
            "Best brain still reachable: MoE via --cpu-moe. Shrink ctx to "
            "16384 and KV to q4_0 (≈ 0.4 GB) so GPU footprint ≈ 6.5–7 GB < 8 "
            "GB even alongside other services. Keeps the 35B brain on an 8 GB "
            "card. DERIVED."
        ),
    ),
    HardwareTier(
        compute_kind="cuda",
        min_budget_gb=6.0,
        label="6 GB VRAM",
        model_id="gemma4-e4b-it",
        params={"ngl": 999, "ctx": 16384, "cpu_moe": False,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "Gemma 4 E4B Q4_K_M ≈ 4.5 GB weights + q8_0 KV at 16384 ctx "
            "(≈ 0.5 GB) + ~0.5 GB CUDA overhead ≈ 5.5 GB < 6 GB. Better "
            "quality + native multimodal vision vs the previous qwen35-9b "
            "(≈ 6.6 GB, text-only at this budget). DERIVED."
        ),
    ),
    HardwareTier(
        compute_kind="cuda",
        min_budget_gb=4.0,
        label="4 GB VRAM",
        model_id="gemma4-e2b-it",
        params={"ngl": 999, "ctx": 16384, "cpu_moe": False,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "Gemma 4 E2B Q4_K_M ≈ 2.8 GB weights + q8_0 KV at 16384 ctx "
            "(≈ 0.4 GB) + ~0.5 GB overhead ≈ 3.7 GB < 4 GB. Multimodal "
            "vision included; beats qwen35-4b (text-only, similar VRAM). "
            "DERIVED."
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
            "Floor tier so we never recommend a model that won't fit. "
            "Gemma 4 E2B Q4_K_M ≈ 2.8 GB + tiny KV at 8192 ctx fits any "
            "GPU that reports usable VRAM; delivers vision where qwen35-0_8b "
            "was text-only. DERIVED."
        ),
    ),
    # ── CPU / RAM tiers (high → low) ────────────────────────────────
    HardwareTier(
        compute_kind="cpu",
        min_budget_gb=24.0,
        label="CPU, 24 GB+ RAM",
        model_id=_MOE_BRAIN,
        # Pure CPU: ngl=0, experts already on CPU via --cpu-moe. Needs RAM to
        # hold the ~22 GB MoE weights + KV.
        params={"ngl": 0, "ctx": 16384, "cpu_moe": True,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "No usable GPU but enough RAM for the full MoE brain on CPU. "
            "ngl=0; --cpu-moe is already the layout. ~22 GB weights + KV needs "
            ">= 24 GB RAM headroom. Slower than GPU but best quality on CPU. "
            "DERIVED."
        ),
    ),
    HardwareTier(
        compute_kind="cpu",
        min_budget_gb=12.0,
        label="CPU, 12 GB+ RAM",
        model_id="gemma4-e4b-it",
        params={"ngl": 0, "ctx": 8192, "cpu_moe": False,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "Not enough RAM for the 22 GB MoE. Gemma 4 E4B Q4_K_M ≈ 4.5 GB "
            "weights comfortably fits in 12–16 GB RAM; native multimodal vision "
            "on CPU beats text-only qwen35-4b at the same footprint. DERIVED."
        ),
    ),
    HardwareTier(
        compute_kind="cpu",
        min_budget_gb=0.0,  # floor
        label="CPU, <12 GB RAM (smallest)",
        model_id="gemma4-e2b-it",
        params={"ngl": 0, "ctx": 8192, "cpu_moe": False,
                "cache_type_k": "q8_0", "cache_type_v": "q8_0"},
        empirical=False,
        budget_math=(
            "Constrained CPU floor: Gemma 4 E2B Q4_K_M ≈ 2.8 GB fits in a few "
            "GB of RAM and delivers vision where qwen35-0_8b was text-only. "
            "Never returns nothing. DERIVED."
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
