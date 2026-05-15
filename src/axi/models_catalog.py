"""Curated catalog of llama-server-compatible models for Axi.

Every entry must fit on a 12 GB RTX 5070 Ti — either fully on GPU, or as a
MoE with `--cpu-moe` offload (the current 35B-A3B pattern). Entries are
GGUF-only; mmproj companions are listed alongside the main weights when the
model supports vision.

The catalog is intentionally short and human-maintained. Each entry has been
verified against the upstream HuggingFace repo via
`huggingface_hub.list_repo_files` at authoring time; if you add a new entry,
do the same verification and update the docstring.
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


# Standard llama-server tuning shared by GPU-resident models on the 13900HX +
# RTX 5070 Ti hardware. Kept as a constant so individual entries are short.
_GPU_DEFAULT_ARGS: tuple[str, ...] = (
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


CATALOG: tuple[ModelEntry, ...] = (
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
    ),
    ModelEntry(
        id="qwen25-vl-7b",
        name="Qwen2.5-VL 7B (vision)",
        family="Qwen",
        params="7B",
        features=("vision", "tools"),
        description=(
            "Compact vision-language model. Q4_K_M quant fits fully on GPU "
            "with ~5–6 GB VRAM. Good for chat + screen-understanding when "
            "the 35B is overkill."
        ),
        files=(
            ModelFile(
                repo_id="unsloth/Qwen2.5-VL-7B-Instruct-GGUF",
                filename="Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf",
                kind="gguf",
            ),
            ModelFile(
                repo_id="unsloth/Qwen2.5-VL-7B-Instruct-GGUF",
                filename="mmproj-BF16.gguf",
                kind="mmproj",
            ),
        ),
        ctx=16384,
        ngl=999,
        extra_args=_GPU_DEFAULT_ARGS + ("-a", "Qwen2.5-VL-7B"),
        vram_estimate_gb=6.0,
    ),
    ModelEntry(
        id="qwen3-8b",
        name="Qwen3 8B (text)",
        family="Qwen",
        params="8B",
        features=("tools",),
        description=(
            "Text-only Qwen3 8B with strong tool-use. Q4_K_M ~5 GB VRAM, "
            "full-GPU. No vision."
        ),
        files=(
            ModelFile(
                repo_id="unsloth/Qwen3-8B-GGUF",
                filename="Qwen3-8B-Q4_K_M.gguf",
                kind="gguf",
            ),
        ),
        ctx=32768,
        ngl=999,
        extra_args=_GPU_DEFAULT_ARGS + ("-a", "Qwen3-8B"),
        vram_estimate_gb=5.5,
    ),
    ModelEntry(
        id="qwen3-4b",
        name="Qwen3 4B (text)",
        family="Qwen",
        params="4B",
        features=("tools",),
        description=(
            "Lightest text-only Qwen3. Q5_K_M ~3 GB VRAM, plenty of headroom "
            "for Whisper + translate alongside."
        ),
        files=(
            ModelFile(
                repo_id="unsloth/Qwen3-4B-GGUF",
                filename="Qwen3-4B-Q5_K_M.gguf",
                kind="gguf",
            ),
        ),
        ctx=32768,
        ngl=999,
        extra_args=_GPU_DEFAULT_ARGS + ("-a", "Qwen3-4B"),
        vram_estimate_gb=3.5,
    ),
    ModelEntry(
        id="gemma3-4b-it",
        name="Gemma3 4B IT (vision)",
        family="Gemma",
        params="4B",
        features=("vision", "tools"),
        description=(
            "Gemma3 4B Instruct with vision (mmproj). Q4_K_M ~3–4 GB VRAM. "
            "Different prompt style than Qwen — useful as an A/B."
        ),
        files=(
            ModelFile(
                repo_id="unsloth/gemma-3-4b-it-GGUF",
                filename="gemma-3-4b-it-Q4_K_M.gguf",
                kind="gguf",
            ),
            ModelFile(
                repo_id="unsloth/gemma-3-4b-it-GGUF",
                filename="mmproj-BF16.gguf",
                kind="mmproj",
            ),
        ),
        ctx=16384,
        ngl=999,
        extra_args=_GPU_DEFAULT_ARGS + ("-a", "gemma-3-4b-it"),
        vram_estimate_gb=4.0,
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
