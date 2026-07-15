"""Curated catalog of llama-server-compatible models for the nano agent.

The nano agent runs on CPU only (CUDA_VISIBLE_DEVICES="" in its systemd
unit) and is used exclusively for entity extraction and structured JSON
tasks by `lifeos.agents.runtime`. Models here must:

  - Run acceptably on CPU (no GPU required)
  - Support GGUF format
  - Be small enough to fit within the 2 GB MemoryMax cap of llama-nano.service

The `port` field on each entry is always 8090 — the nano service is
single-port. It is stored here so the launcher script never has to
hardcode the number independently.

Default entry: qwen35-0_8b (the historical model, must stay first).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable


@dataclass(frozen=True)
class NanoModelFile:
    """Single file inside a nano model bundle."""

    repo_id: str
    filename: str
    kind: str  # "gguf" | "mmproj" | "misc"
    dest_relname: str = ""  # local filename; defaults to `filename`

    @property
    def local_name(self) -> str:
        return self.dest_relname or self.filename


@dataclass(frozen=True)
class NanoModelEntry:
    """A selectable nano model.

    `port` is always 8090; stored here so callers never hardcode it.
    `ngl` is always 0 for nano (CPU-only); stored explicitly so the
    launcher can read it from the config without special-casing.
    """

    id: str
    name: str
    family: str
    params: str
    features: tuple[str, ...]
    description: str
    files: tuple[NanoModelFile, ...]
    ctx: int
    ngl: int = 0  # CPU-only — always 0 for nano agent
    port: int = 8090
    extra_args: tuple[str, ...] = field(default_factory=tuple)
    notes: str = ""

    @property
    def gguf_file(self) -> NanoModelFile:
        for f in self.files:
            if f.kind == "gguf":
                return f
        raise ValueError(f"nano entry {self.id} has no gguf file")

    @property
    def mmproj_file(self) -> NanoModelFile | None:
        for f in self.files:
            if f.kind == "mmproj":
                return f
        return None


# Args shared by all CPU-only nano entries.
# Note: --jinja, -c <ctx>, and -ngl <ngl> are injected by the launcher
# (axi-nano-launch) from the config dict, so they are NOT repeated here.
_CPU_ARGS: tuple[str, ...] = (
    "-t", "4",
    "--no-mmap",
    "-np", "1",
)

# ------------------------------------------------------------------ #
# Catalog — default entry MUST be first.                             #
# ------------------------------------------------------------------ #
NANO_CATALOG: tuple[NanoModelEntry, ...] = (
    # ------------------------------------------------------------------ #
    # Default — Qwen3.5-0.8B (historical, must stay first + identical).   #
    # ------------------------------------------------------------------ #
    NanoModelEntry(
        id="qwen35-0_8b",
        name="Qwen3.5 0.8B (nano-agent)",
        family="Qwen",
        params="0.8B",
        features=("tools", "vision"),
        description=(
            "Default nano-agent model. Qwen3.5 0.8B multimodal Q4_K_M ~740 MB. "
            "CPU-only (CUDA_VISIBLE_DEVICES='' in the service unit). Supports "
            "thinking mode — disable_thinking=True is passed by the runtime. "
            "Files live at ~/LifeOS/models/qwen35-0_8b/ (historical path)."
        ),
        files=(
            NanoModelFile(
                repo_id="unsloth/Qwen3.5-0.8B-GGUF",
                filename="Qwen3.5-0.8B-Q4_K_M.gguf",
                kind="gguf",
            ),
            NanoModelFile(
                repo_id="unsloth/Qwen3.5-0.8B-GGUF",
                filename="mmproj-F16.gguf",
                kind="mmproj",
            ),
        ),
        ctx=8192,
        ngl=0,
        port=8090,
        extra_args=_CPU_ARGS + ("-a", "Qwen3.5-0.8B-nano"),
        notes="Historical default. mmproj included for vision parity.",
    ),

    # ------------------------------------------------------------------ #
    # Recommended extractor — Qwen3.5-2B (text-only).                     #
    # Won the 2026-07-14 Spanish extraction bake-off vs 0.8B: 73.9% case  #
    # pass rate (51/69) vs 60.9% (42/69), no fields below 70% accuracy.   #
    # ~2x slower on CPU (~6.5s vs ~3.1s/case) but the nano extractor runs #
    # in the background, so quality wins. Bundled text-only (no mmproj):  #
    # it was benchmarked text-only and mmproj would inflate RSS toward    #
    # the service MemoryMax.                                              #
    # ------------------------------------------------------------------ #
    NanoModelEntry(
        id="qwen35-2b",
        name="Qwen3.5 2B (nano-agent, recommended)",
        family="Qwen",
        params="2B",
        features=("tools",),
        description=(
            "Recommended nano-agent extractor. Qwen3.5 2B Q4_K_M ~1.3 GB. "
            "CPU-only. Text-only (no mmproj) — benchmarked and run purely for "
            "structured extraction. Won the 2026-07-14 Spanish extraction "
            "bake-off vs 0.8B (+13pp case pass rate, no weak fields). "
            "Files live at ~/LifeOS/models/qwen35-2b/."
        ),
        files=(
            NanoModelFile(
                repo_id="unsloth/Qwen3.5-2B-GGUF",
                filename="Qwen3.5-2B-Q4_K_M.gguf",
                kind="gguf",
            ),
        ),
        ctx=8192,
        ngl=0,
        port=8090,
        extra_args=_CPU_ARGS + ("-a", "Qwen3.5-2B-nano"),
        notes=(
            "Recommended default extractor as of 2026-07-14. ~1.3 GB gguf; "
            "needs MemoryMax >= 3G on llama-nano.service to avoid OOM under "
            "the KV cache. Text-only by design (extraction workload)."
        ),
    ),

    # ------------------------------------------------------------------ #
    # Nano-agent / extraction tier — Liquid AI LFM2 1.2B.                #
    # ------------------------------------------------------------------ #
    NanoModelEntry(
        id="lfm2-1.2b-extract",
        name="LFM2 1.2B Extract (extraction/RAG)",
        family="LFM",
        params="1.2B",
        features=("tools",),
        description=(
            "Liquid AI LFM2 1.2B Extract (CC-BY-4.0). State-space hybrid "
            "specialized for extraction/RAG/agents. Q4_K_M ~731 MB. 2x faster "
            "decode/prefill vs Qwen3 same size on CPU. Native function calling "
            "(OpenAI tool spec). Dedicated extraction checkpoint. Text-only: "
            "no mmproj."
        ),
        files=(
            NanoModelFile(
                repo_id="LiquidAI/LFM2-1.2B-Extract-GGUF",
                filename="LFM2-1.2B-Extract-Q4_K_M.gguf",
                kind="gguf",
            ),
        ),
        ctx=8192,
        ngl=0,
        port=8090,
        extra_args=_CPU_ARGS + ("-a", "LFM2-1.2B-Extract"),
        notes=(
            "No mmproj — text-only extraction model. CC-BY-4.0. "
            "Ruled out by 2026-06-07 benchmark: 28% field accuracy and "
            "KV-slot contamination on this extraction workload. "
            "Kept in catalog for reference only."
        ),
    ),
)


def catalog() -> tuple[NanoModelEntry, ...]:
    """Return the full nano catalog (immutable)."""
    return NANO_CATALOG


def by_id(model_id: str) -> NanoModelEntry | None:
    """Look up a nano entry by id; returns None if unknown."""
    for entry in NANO_CATALOG:
        if entry.id == model_id:
            return entry
    return None


def iter_files(entry: NanoModelEntry) -> Iterable[NanoModelFile]:
    """Iterate every file in the nano bundle (download targets)."""
    yield from entry.files


__all__ = [
    "NANO_CATALOG",
    "NanoModelEntry",
    "NanoModelFile",
    "by_id",
    "catalog",
    "iter_files",
]
