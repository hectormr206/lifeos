"""Curated catalog of llama-server-compatible models for Axi.

Every entry must fit on a 12 GB RTX 5070 Ti — either fully on GPU, or as a
MoE with `--cpu-moe` offload (the current 35B-A3B pattern). Entries are
GGUF-only; mmproj companions are listed alongside the main weights when the
model supports vision.

Refreshed 2026-06-18 (rev 6): Added qwen35-4b + vibethinker-3b (TRIAD).
- qwen35-4b: primary triad brain (60K ctx, GPU, vision+tools, port 8080)
- vibethinker-3b: reasoning sibling (60K ctx, GPU, no tools/vision, port 8082)
Both measured at 8.68 GB together + Whisper ~2.3 GB = ~10.98 GB / 12 GB
(~1.25 GB headroom). Flags: -np 1 --cache-type-k q8_0 --cache-type-v q8_0 -fa on.

Refreshed 2026-06-17 (rev 5): Added qwen35-2b as game co-pilot brain.
- qwen36-35b-a3b: production default (quality, local)
- gemma4-e2b-it: universal small/fast/vision tier (kept on disk as fallback)
- qwen35-2b: game co-pilot brain (10 s/frame, ~2.2 GB RAM, CPU-only, vision)

Rev 4 notes (2026-06-10): Consolidated to 2 models. Cut:
- gemma4-e4b-it: strictly dominated by gemma4-e2b-it (e2b quality 0.698 > e4b
  0.665, faster, smaller). No tier where e4b is a better pick.
- gemma4-26b-a4b-it: measured CPU RSS = 18.5 GB (gguf 16 GB). With
  reserve = max(25%×tier, 3 GB) it fails both 22 GB (18.5+5.5=24>22) and
  24 GB (18.5+6=24.5>24). Its only safe niche (~26–31 GB RAM) is bordered by
  the 35B at 32 GB, so it owns no common tier.

Every entry below has been verified against the upstream HuggingFace repo
via `huggingface_hub.list_repo_files` at authoring time; if you add a new
entry, do the same verification and update the docstring.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class ModelFile:
    """Single file inside a model bundle (gguf weights, mmproj, or auxiliary)."""

    repo_id: str
    filename: str
    kind: str  # "gguf" | "mmproj" | "misc"
    dest_relname: str = ""  # local filename; defaults to `filename`

    @property
    def local_name(self) -> str:
        return self.dest_relname or self.filename


@dataclass(frozen=True)
class ModelEntry:
    """A selectable model. Combines bundle files with the llama-server args
    needed to run it on this hardware."""

    id: str
    name: str
    family: str
    params: str
    features: tuple[str, ...]
    description: str
    files: tuple[ModelFile, ...]
    ctx: int
    ngl: int
    extra_args: tuple[str, ...]
    vram_estimate_gb: float
    notes: str = ""
    # Per-model overrides of `model_params_schema.SCHEMA` defaults. Used
    # by the params editor (`/models` page) to seed the form. Catalog
    # entries do NOT have to set this — the schema default applies if
    # absent. Importantly, this field does NOT affect what
    # `set_active(entry)` writes when there are no on-disk overrides for
    # this entry — `entry.extra_args` is still the byte-identical source
    # of truth in that case.
    param_defaults: dict = field(default_factory=dict)

    @property
    def gguf_file(self) -> ModelFile:
        for f in self.files:
            if f.kind == "gguf":
                return f
        raise ValueError(f"entry {self.id} has no gguf file")

    @property
    def mmproj_file(self) -> ModelFile | None:
        for f in self.files:
            if f.kind == "mmproj":
                return f
        return None


# Standard llama-server tuning shared by GPU-resident (dense) models on the
# 13900HX + RTX 5070 Ti hardware. Kept as a constant so individual entries
# are short.
_GPU_DEFAULT_ARGS: tuple[str, ...] = (
    "--jinja",
    "--reasoning-format", "auto",
    "--cache-type-k", "q8_0",
    "--cache-type-v", "q8_0",
    "-fa", "on",
    "-b", "2048",
    "-ub", "512",
    "-t", "8",
    "-tb", "8",
    "--temp", "0.7",
    "--top-p", "0.95",
    "--top-k", "20",
    "-np", "1",
)


# The current production default. The args here mirror what is actually
# running today (see `axi-llama-launch` defaults) so activating this entry
# is byte-equivalent to a fresh wrapper run.
_QWEN36_ARGS: tuple[str, ...] = (
    "--cpu-moe",
    "--prio", "3",
    "--prio-batch", "3",
    "--poll", "100",
    "--poll-batch", "1",
    "-Cr", "0-15",
    "-Crb", "0-15",
    "--cpu-strict", "1",
    "--cpu-strict-batch", "1",
    "--reasoning-format", "auto",
    "--cache-type-k", "q8_0",
    "--cache-type-v", "q8_0",
    "-fa", "on",
    "-b", "8192",
    "-ub", "4096",
    "-t", "8",
    "-tb", "16",
    "--temp", "0.6",
    "--top-p", "0.95",
    "--top-k", "20",
    "--min-p", "0.0",
    "--presence-penalty", "0.0",
    "--repeat-penalty", "1.0",
    "-np", "1",
    "--no-mmap",
    "--mlock",
    "--image-min-tokens", "1024",
    "-a", "Qwen3.6-35B-A3B",
)


def _with_vt_sampling(args: tuple[str, ...]) -> tuple[str, ...]:
    """Replace --temp and --top-k in `args` with VibeThinker-3B production values.

    VibeThinker degrades at low temp (benchmark #559); its production sampling
    is temp=1.0, top_k=-1 (disabled). The shared _GPU_DEFAULT_ARGS uses 0.7/20
    (optimised for 4B), so VT's entry substitutes these two params in-place to
    keep all other flags (batch sizes, -np 1, KV compression, etc.) unchanged.
    SYNC NOTE: Must match axi-vt-launch DEFAULT dict and brain.py _base_payload.
    """
    result: list[str] = []
    i = 0
    while i < len(args):
        tok = args[i]
        if tok == "--temp" and i + 1 < len(args):
            result += ["--temp", "1.0"]
            i += 2
        elif tok == "--top-k" and i + 1 < len(args):
            result += ["--top-k", "-1"]
            i += 2
        else:
            result.append(tok)
            i += 1
    return tuple(result)


def _strip_reasoning_format(args: tuple[str, ...]) -> tuple[str, ...]:
    """Remove --reasoning-format <value> from args (used for Gemma entries that
    append --reasoning off, so only one reasoning flag is passed to llama-server)."""
    result: list[str] = []
    skip_next = False
    for tok in args:
        if skip_next:
            skip_next = False
            continue
        if tok == "--reasoning-format":
            skip_next = True
            continue
        result.append(tok)
    return tuple(result)


CATALOG: tuple[ModelEntry, ...] = (
    # ------------------------------------------------------------------ #
    # Production default — keep first.                                   #
    # ------------------------------------------------------------------ #
    ModelEntry(
        id="qwen36-35b-a3b",
        name="Qwen3.6 35B-A3B (vision)",
        family="Qwen",
        params="35B-A3B",
        features=("vision", "tools", "current"),
        description=(
            "Current default. MoE model with 35B total / 3B active params, "
            "runs hybrid CPU-experts + GPU-attention via --cpu-moe. Vision "
            "via mmproj-BF16. Files already on disk; activating this entry "
            "is the no-op baseline."
        ),
        files=(
            ModelFile(
                repo_id="local",  # already present; no download
                filename="Qwen3.6-35B-A3B-MXFP4_MOE.gguf",
                kind="gguf",
            ),
            ModelFile(
                repo_id="local",
                filename="mmproj-BF16.gguf",
                kind="mmproj",
            ),
        ),
        ctx=32768,
        ngl=999,
        extra_args=_QWEN36_ARGS,
        vram_estimate_gb=8.0,
        notes="Local files — preloaded; no HF download required.",
        param_defaults={
            "temperature": 0.6,
            "top_p": 0.95,
            "top_k": 20,
            "min_p": 0.0,
            "repeat_penalty": 1.0,
            "threads": 8,
            "threads_batch": 16,
            "flash_attention": True,
            "cpu_moe": True,
            "cache_type_k": "q8_0",
            "cache_type_v": "q8_0",
            "reasoning_format": "auto",
            "mlock": True,
            "image_min_tokens": 1024,
        },
    ),

    # ------------------------------------------------------------------ #
    # Small/fast/vision tier (full GPU residency).                       #
    # ------------------------------------------------------------------ #
    ModelEntry(
        id="gemma4-e2b-it",
        name="Gemma 4 E2B IT (vision)",
        family="Gemma",
        params="E2B",
        features=("vision", "tools"),
        description=(
            "Google Gemma 4 E2B Instruct, el más chico del catálogo. "
            "Q4_K_M ~2.5 GB VRAM — ideal cuando necesitás VLM corriendo "
            "junto a otros servicios o en sesiones largas."
        ),
        files=(
            ModelFile(
                repo_id="unsloth/gemma-4-E2B-it-GGUF",
                filename="gemma-4-E2B-it-Q4_K_M.gguf",
                kind="gguf",
            ),
            ModelFile(
                repo_id="unsloth/gemma-4-E2B-it-GGUF",
                filename="mmproj-BF16.gguf",
                kind="mmproj",
            ),
        ),
        ctx=32768,
        ngl=999,
        extra_args=_strip_reasoning_format(_GPU_DEFAULT_ARGS) + ("--reasoning", "off", "-a", "gemma-4-E2B-it"),
        vram_estimate_gb=2.8,
        notes="mmproj DEBE ser BF16 — los quants del projector están rotos en upstream.",
    ),

    # ------------------------------------------------------------------ #
    # Triad primary brain — GPU-resident, vision+tools, port 8080.       #
    # Measured VRAM: 5.37 GB alone @60K; 8.68 GB together with VT-3B.   #
    # ------------------------------------------------------------------ #
    ModelEntry(
        id="qwen35-4b",
        name="Qwen3.5 4B (triad primary)",
        family="Qwen",
        params="4B",
        features=("vision", "tools"),
        description=(
            "Primary triad brain. Qwen3.5-4B Q4_K_M + mmproj-F16 for vision. "
            "Resident on GPU (ngl=999) at port 8080, ctx=61440 (60K). "
            "Measured VRAM: 5.37 GB alone, 8.68 GB paired with VibeThinker-3B. "
            "Replaces qwen36-35b-a3b as the daily-driver brain. "
            "Files on disk at ~/LifeOS/models/qwen35-4b/."
        ),
        files=(
            ModelFile(
                repo_id="local",  # already on disk; no download required
                filename="Qwen3.5-4B-Q4_K_M.gguf",
                kind="gguf",
            ),
            ModelFile(
                repo_id="local",
                filename="mmproj-F16.gguf",
                kind="mmproj",
            ),
        ),
        # ctx=61440 per VRAM measurement #565 — both triad brains at 60K fit
        # in 12 GB with ~1.25 GB headroom. SYNC NOTE: this value is duplicated
        # in axi-vt-launch DEFAULT dict; keep them in sync.
        ctx=61440,
        ngl=999,
        extra_args=_GPU_DEFAULT_ARGS + ("-a", "Qwen3.5-4B"),
        vram_estimate_gb=5.4,  # measured: 5.37 GB @60K, q8_0 KV, -np 1
        notes=(
            "Local files at ~/LifeOS/models/qwen35-4b/ — no HF download required. "
            "Mandatory flags per VRAM measurement #565: -np 1 --cache-type-k q8_0 "
            "--cache-type-v q8_0 -fa on (already in _GPU_DEFAULT_ARGS). "
            "Uses --reasoning-format auto (Qwen puts reasoning in reasoning_content). "
            "NO --cpu-moe (dense model), NO --reasoning off (Gemma-specific)."
        ),
    ),

    # ------------------------------------------------------------------ #
    # Triad reasoning sibling — GPU-resident, NO tools, NO vision.       #
    # Runs on port 8082 via llama-vt.service / axi-vt-launch.            #
    # Measured VRAM: +3.31 GB when paired with 4B (total 8.68 GB).      #
    # ------------------------------------------------------------------ #
    ModelEntry(
        id="vibethinker-3b",
        name="VibeThinker 3B (reasoning sibling)",
        family="VibeThinker",
        params="3B",
        # Empty features tuple = machine-readable signal that this entry is
        # router-ineligible for tools/vision. _route() in brain.py enforces
        # the hard pre-check (tools or image_b64 -> 4B always).
        features=(),
        description=(
            "Reasoning/code sibling in the triad. VibeThinker-3B Q4_K_M. "
            "GPU-resident (ngl=999) at port 8082, ctx=61440 (60K). "
            "NO mmproj (no vision), NO tools support. "
            "Routes math/code/reasoning prompts from brain.py; think-tags "
            "stripped by brain.py before returning to caller. "
            "Files on disk at ~/LifeOS/models/vibethinker-3b/."
        ),
        files=(
            ModelFile(
                repo_id="local",  # already on disk; no download required
                filename="VibeThinker-3B-Q4_K_M.gguf",
                kind="gguf",
            ),
            # NO mmproj: VibeThinker-3B has no vision capability.
        ),
        # ctx=61440 per VRAM measurement #565. SYNC NOTE: this value is
        # duplicated in axi-vt-launch DEFAULT dict; keep them in sync.
        ctx=61440,
        ngl=999,
        extra_args=_with_vt_sampling(_GPU_DEFAULT_ARGS) + ("-a", "VibeThinker-3B"),
        vram_estimate_gb=3.3,  # measured: +3.31 GB when paired with 4B @60K
        notes=(
            "Local files at ~/LifeOS/models/vibethinker-3b/ — no HF download required. "
            "Mandatory flags per VRAM measurement #565: -np 1 --cache-type-k q8_0 "
            "--cache-type-v q8_0 -fa on (already in _GPU_DEFAULT_ARGS). "
            "VT leaks <think> into content — brain.py strips it. "
            "Managed by llama-vt.service / axi-vt-launch on port 8082."
        ),
    ),

    # ------------------------------------------------------------------ #
    # Game co-pilot brain — CPU-only, vision, fast latency.              #
    # ------------------------------------------------------------------ #
    ModelEntry(
        id="qwen35-2b",
        name="Qwen3.5 2B (game co-pilot)",
        family="Qwen",
        params="2B",
        features=("vision", "tools"),
        description=(
            "Qwen3.5-2B Q4_K_M with mmproj-F16 for vision. Bench: 10 s/frame "
            "on real game content (RE Requiem), ~2.2 GB RAM at ngl=0. "
            "Designated game co-pilot brain; replaces gemma4-e2b-it in game mode "
            "(3x faster, no --jinja quirks, no thinking-token budget drain). "
            "Files already on disk at ~/LifeOS/models/qwen35-2b/."
        ),
        files=(
            ModelFile(
                repo_id="local",  # already present; no download required
                filename="Qwen3.5-2B-Q4_K_M.gguf",
                kind="gguf",
            ),
            ModelFile(
                repo_id="local",
                filename="mmproj-F16.gguf",
                kind="mmproj",
            ),
        ),
        ctx=8192,
        ngl=0,  # CPU-only; game mode frees all VRAM for the game
        extra_args=(
            "-t", "8",
            "--temp", "0.7",
            "--top-p", "0.95",
            "--top-k", "20",
            "-np", "1",
            "-a", "Qwen3.5-2B",
        ),
        vram_estimate_gb=0.0,  # ngl=0 — no VRAM used
        notes=(
            "Local files at ~/LifeOS/models/qwen35-2b/ — no HF download required. "
            "Benchmark: 10 s on 1024x576 game frame (RE Requiem), equal grounding "
            "quality to gemma4-e2b-it which takes 17-35 s. No --jinja in extra_args "
            "(axi-llama-launch injects it globally; Qwen3.5 chat template loads fine "
            "without extra flags). No --reasoning off needed (not a Gemma model)."
        ),
    ),

)


def catalog() -> tuple[ModelEntry, ...]:
    """Return the full catalog (immutable)."""
    return CATALOG


def by_id(model_id: str) -> ModelEntry | None:
    """Look up an entry by id; returns None if unknown."""
    for entry in CATALOG:
        if entry.id == model_id:
            return entry
    return None


def iter_files(entry: ModelEntry) -> Iterable[ModelFile]:
    """Iterate every file in the bundle (download targets)."""
    yield from entry.files
