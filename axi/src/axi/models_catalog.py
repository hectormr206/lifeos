"""Curated catalog of llama-server-compatible models for Axi.

Every entry must fit on a 12 GB RTX 5070 Ti — either fully on GPU, or as a
MoE with `--cpu-moe` offload (the current 35B-A3B pattern). Entries are
GGUF-only; mmproj companions are listed alongside the main weights when the
model supports vision.

Refreshed 2026-05-15: Qwen3-VL family rejected in favor of Qwen3.5 dense
multimodal (hybrid-thinking, 256K context, 201 languages). Catalog now
combines:
- Qwen3.6 35B-A3B MoE (current default, local)
- Qwen3.5 dense multimodal at 0.8B / 2B / 4B / 9B (Apr 2026)
- NVIDIA Nemotron-3 Nano Omni (late 2025+)
- Gemma 4 family (April 2026)

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


# Shared MoE tuning (CPU experts + GPU attention via --cpu-moe). Mirrors
# the qwen3.6 production layout for the smaller A3B / A4B MoE entries that
# don't need the ultra-aggressive batching of qwen3.6.
_MOE_DEFAULT_ARGS: tuple[str, ...] = (
    "--cpu-moe",
    "--jinja",
    "--reasoning-format", "auto",
    "--cache-type-k", "q8_0",
    "--cache-type-v", "q8_0",
    "-fa", "on",
    "-b", "4096",
    "-ub", "2048",
    "-t", "8",
    "-tb", "16",
    "--temp", "0.7",
    "--top-p", "0.95",
    "--top-k", "20",
    "-np", "1",
    "--no-mmap",
    "--mlock",
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
    # MoE multimodal entries (--cpu-moe, ~7–8 GB VRAM).                  #
    # ------------------------------------------------------------------ #
    ModelEntry(
        id="nemotron3-nano-omni-30b-a3b",
        name="Nemotron-3 Nano Omni 30B-A3B (omni)",
        family="Nemotron",
        params="30B-A3B",
        features=("vision", "tools"),
        description=(
            "NVIDIA Nemotron-3 Nano Omni Reasoning, MoE 30B/3B active. "
            "Omnimodal (visión + audio + texto) con razonamiento; corre "
            "vía --cpu-moe en 12 GB. El soporte de audio en llama.cpp "
            "todavía está madurando — la entrada queda como vision+tools "
            "hasta que upstream estabilice."
        ),
        files=(
            ModelFile(
                repo_id="lmstudio-community/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-GGUF",
                filename="Nemotron-3-Nano-Omni-30B-A3B-Reasoning-Q4_K_M.gguf",
                kind="gguf",
            ),
            ModelFile(
                repo_id="lmstudio-community/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-GGUF",
                filename="mmproj-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-BF16.gguf",
                kind="mmproj",
            ),
        ),
        ctx=32768,
        ngl=999,
        extra_args=_MOE_DEFAULT_ARGS + ("-a", "Nemotron-3-Nano-Omni-30B-A3B"),
        vram_estimate_gb=8.0,
        notes=(
            "Reasoning mode — usa --reasoning-format auto. Algunos quants "
            "tienen issues con llama.cpp recientes; verificar la build "
            "antes de activarlo en prod."
        ),
    ),
    ModelEntry(
        id="gemma4-26b-a4b-it",
        name="Gemma 4 26B-A4B IT (vision)",
        family="Gemma",
        params="26B-A4B",
        features=("vision", "tools"),
        description=(
            "Google Gemma 4 Instruct MoE (April 2026). 26B total / 4B "
            "active, corre vía --cpu-moe. Vision con mmproj BF16 (los "
            "quants del mmproj tienen un bug conocido — usar SIEMPRE BF16)."
        ),
        files=(
            ModelFile(
                repo_id="unsloth/gemma-4-26B-A4B-it-GGUF",
                filename="gemma-4-26B-A4B-it-UD-Q4_K_M.gguf",
                kind="gguf",
            ),
            ModelFile(
                repo_id="unsloth/gemma-4-26B-A4B-it-GGUF",
                filename="mmproj-BF16.gguf",
                kind="mmproj",
            ),
        ),
        ctx=32768,
        ngl=999,
        extra_args=_MOE_DEFAULT_ARGS + ("-a", "gemma-4-26B-A4B-it"),
        vram_estimate_gb=8.5,
        notes="mmproj DEBE ser BF16 — los quants del projector están rotos en upstream.",
    ),

    # ------------------------------------------------------------------ #
    # Dense multimodal entries (full GPU residency).                     #
    # ------------------------------------------------------------------ #
    ModelEntry(
        id="qwen35-0_8b",
        name="Qwen3.5 0.8B (vision)",
        family="Qwen",
        params="0.8B",
        features=("vision", "tools"),
        description=(
            "Qwen3.5 0.8B denso multimodal (abril 2026). El más chico de "
            "la familia Qwen3.5: hybrid-thinking, contexto 256K, soporte "
            "para 201 idiomas, visión via mmproj-F16. Q4_K_M ~1 GB VRAM "
            "— ideal para correr junto a otros servicios en background."
        ),
        files=(
            ModelFile(
                repo_id="unsloth/Qwen3.5-0.8B-GGUF",
                filename="Qwen3.5-0.8B-Q4_K_M.gguf",
                kind="gguf",
            ),
            ModelFile(
                repo_id="unsloth/Qwen3.5-0.8B-GGUF",
                filename="mmproj-F16.gguf",
                kind="mmproj",
            ),
        ),
        ctx=32768,
        ngl=999,
        extra_args=_GPU_DEFAULT_ARGS + ("-a", "Qwen3.5-0.8B"),
        vram_estimate_gb=1.0,
    ),
    ModelEntry(
        id="qwen35-2b",
        name="Qwen3.5 2B (vision)",
        family="Qwen",
        params="2B",
        features=("vision", "tools"),
        description=(
            "Qwen3.5 2B denso multimodal (abril 2026). Hybrid-thinking, "
            "contexto 256K, 201 idiomas, visión via mmproj-F16. Q4_K_M "
            "~1.8 GB VRAM — pareja chica con buena calidad/latencia."
        ),
        files=(
            ModelFile(
                repo_id="unsloth/Qwen3.5-2B-GGUF",
                filename="Qwen3.5-2B-Q4_K_M.gguf",
                kind="gguf",
            ),
            ModelFile(
                repo_id="unsloth/Qwen3.5-2B-GGUF",
                filename="mmproj-F16.gguf",
                kind="mmproj",
            ),
        ),
        ctx=32768,
        ngl=999,
        extra_args=_GPU_DEFAULT_ARGS + ("-a", "Qwen3.5-2B"),
        vram_estimate_gb=1.8,
    ),
    ModelEntry(
        id="qwen35-4b",
        name="Qwen3.5 4B (vision)",
        family="Qwen",
        params="4B",
        features=("vision", "tools"),
        description=(
            "Qwen3.5 4B denso multimodal (abril 2026). Hybrid-thinking, "
            "contexto 256K, 201 idiomas, visión via mmproj-F16. Q4_K_M "
            "~3 GB VRAM — deja headroom para Whisper + translate en paralelo."
        ),
        files=(
            ModelFile(
                repo_id="unsloth/Qwen3.5-4B-GGUF",
                filename="Qwen3.5-4B-Q4_K_M.gguf",
                kind="gguf",
            ),
            ModelFile(
                repo_id="unsloth/Qwen3.5-4B-GGUF",
                filename="mmproj-F16.gguf",
                kind="mmproj",
            ),
        ),
        ctx=32768,
        ngl=999,
        extra_args=_GPU_DEFAULT_ARGS + ("-a", "Qwen3.5-4B"),
        vram_estimate_gb=3.0,
    ),
    ModelEntry(
        id="qwen35-9b",
        name="Qwen3.5 9B (vision)",
        family="Qwen",
        params="9B",
        features=("vision", "tools"),
        description=(
            "Qwen3.5 9B denso multimodal (abril 2026). El más grande de "
            "la familia densa: hybrid-thinking, contexto 256K, 201 "
            "idiomas, visión via mmproj-F16. Q4_K_M ~6 GB VRAM — la mejor "
            "calidad denso/GPU del catálogo cuando no querés MoE. "
            "Confirmado funcionando en GGUF."
        ),
        files=(
            ModelFile(
                repo_id="unsloth/Qwen3.5-9B-GGUF",
                filename="Qwen3.5-9B-Q4_K_M.gguf",
                kind="gguf",
            ),
            ModelFile(
                repo_id="unsloth/Qwen3.5-9B-GGUF",
                filename="mmproj-F16.gguf",
                kind="mmproj",
            ),
        ),
        ctx=32768,
        ngl=999,
        extra_args=_GPU_DEFAULT_ARGS + ("-a", "Qwen3.5-9B"),
        vram_estimate_gb=6.0,
    ),
    ModelEntry(
        id="gemma4-e4b-it",
        name="Gemma 4 E4B IT (vision)",
        family="Gemma",
        params="E4B",
        features=("vision", "tools"),
        description=(
            "Google Gemma 4 E4B Instruct (April 2026). Denso ~4 GB VRAM "
            "en Q4_K_M, multimodal (visión hoy, audio cuando llama.cpp "
            "lo soporte). Prompt style Gemma — buena pareja para A/B "
            "frente a Qwen3.5."
        ),
        files=(
            ModelFile(
                repo_id="unsloth/gemma-4-E4B-it-GGUF",
                filename="gemma-4-E4B-it-Q4_K_M.gguf",
                kind="gguf",
            ),
            ModelFile(
                repo_id="unsloth/gemma-4-E4B-it-GGUF",
                filename="mmproj-BF16.gguf",
                kind="mmproj",
            ),
        ),
        ctx=32768,
        ngl=999,
        extra_args=_GPU_DEFAULT_ARGS + ("-a", "gemma-4-E4B-it"),
        vram_estimate_gb=4.5,
        notes="mmproj DEBE ser BF16 — los quants del projector están rotos en upstream.",
    ),
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
        extra_args=_GPU_DEFAULT_ARGS + ("-a", "gemma-4-E2B-it"),
        vram_estimate_gb=2.8,
        notes="mmproj DEBE ser BF16 — los quants del projector están rotos en upstream.",
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
