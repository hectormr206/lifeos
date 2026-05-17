"""Tunable parameter schema for llama-server model entries.

Declares the *universe* of user-tweakable knobs. The catalog entry stays
the source of truth for the byte-identical baseline (`entry.extra_args`).
Overrides stored in `model_overrides.json` mutate that baseline at
activation time via `merge_extra_args` — when there are no overrides for
a model, the baseline is written through unchanged.

Design notes:
- `ctx` and `ngl` live at the top of `active_model.json` (not inside
  `extra_args`) so we model them as schema rows whose `extra_args_pattern`
  is None — they round-trip through dedicated fields.
- Boolean flags (e.g. `--cpu-moe`, `--mlock`) are represented by a single
  CLI token with no value: pattern = "--cpu-moe", emitted when True,
  omitted when False.
- Value flags use a `{value}` placeholder: pattern = "--temp {value}",
  emitted as ["--temp", "<value>"].
- `flash_attention` uses pattern "-fa on" / omitted-when-False; this
  matches the existing baseline (the legacy `-fa on` token is dropped if
  the user disables flash attention).

Adding a new tunable:
1. Append a `ParamSpec` below.
2. If the catalog has entries that should default it differently, add the
   override in their `ModelEntry.param_defaults` map (catalog file).
3. Confirm `merge_extra_args` round-trips it (test).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class ParamSpec:
    key: str
    label: str
    kind: str  # "float" | "int" | "bool" | "enum"
    default: Any
    min: float | int | None = None
    max: float | int | None = None
    step: float | int | None = None
    choices: tuple[str, ...] | None = None
    description: str = ""
    group: str = "Sampling"
    requires_features: tuple[str, ...] = ()
    requires_family: tuple[str, ...] = ()
    # CLI rendering. None means "not rendered into extra_args" (top-level
    # fields like ctx/ngl). A string with "{value}" becomes a two-token
    # flag. A string without "{value}" is emitted as a single token when
    # the value is truthy (bool flags like "--cpu-moe").
    extra_args_pattern: str | None = None
    # All possible CLI tokens this param can claim when merging. Used to
    # strip stale flags from the baseline. For a value-flag, this is the
    # flag itself (e.g. "--temp"); for a bool flag, it's the literal token
    # (e.g. "--cpu-moe"). For "-fa on" multi-token specials, list every
    # token that may appear at the flag position.
    cli_flags: tuple[str, ...] = ()


# Curated tunables — 16 knobs grouped for the editor UI.
SCHEMA: tuple[ParamSpec, ...] = (
    # ── Context & Memory ───────────────────────────────────────────────
    ParamSpec(
        key="ctx", label="Contexto (tokens)", kind="int",
        default=32768, min=1024, max=262144, step=1024,
        description="Tamaño del context window (-c).",
        group="Context & Memory",
        extra_args_pattern=None,  # written to active_model.json["ctx"]
    ),
    ParamSpec(
        key="ngl", label="GPU layers (-ngl)", kind="int",
        default=999, min=0, max=999, step=1,
        description="Capas a offloadear a GPU. 999 = todo lo que entre.",
        group="Context & Memory",
        extra_args_pattern=None,  # written to active_model.json["ngl"]
    ),
    ParamSpec(
        key="mlock", label="--mlock", kind="bool",
        default=False,
        description="Fuerza el modelo en RAM (no swap).",
        group="Context & Memory",
        extra_args_pattern="--mlock", cli_flags=("--mlock",),
    ),
    # ── Sampling ────────────────────────────────────────────────────────
    ParamSpec(
        key="temperature", label="Temperature (--temp)", kind="float",
        default=0.7, min=0.0, max=2.0, step=0.05,
        description="Sampling temperature.",
        group="Sampling",
        extra_args_pattern="--temp {value}", cli_flags=("--temp",),
    ),
    ParamSpec(
        key="top_p", label="Top-p (--top-p)", kind="float",
        default=0.95, min=0.0, max=1.0, step=0.01,
        description="Núcleo top-p sampling.",
        group="Sampling",
        extra_args_pattern="--top-p {value}", cli_flags=("--top-p",),
    ),
    ParamSpec(
        key="top_k", label="Top-k (--top-k)", kind="int",
        default=40, min=0, max=200, step=1,
        description="Top-k sampling.",
        group="Sampling",
        extra_args_pattern="--top-k {value}", cli_flags=("--top-k",),
    ),
    ParamSpec(
        key="min_p", label="Min-p (--min-p)", kind="float",
        default=0.0, min=0.0, max=0.5, step=0.01,
        description="Min-p sampling threshold.",
        group="Sampling",
        extra_args_pattern="--min-p {value}", cli_flags=("--min-p",),
    ),
    ParamSpec(
        key="repeat_penalty", label="Repeat penalty", kind="float",
        default=1.0, min=1.0, max=1.5, step=0.01,
        description="Penalización de repetición.",
        group="Sampling",
        extra_args_pattern="--repeat-penalty {value}",
        cli_flags=("--repeat-penalty",),
    ),
    # ── Threading ───────────────────────────────────────────────────────
    ParamSpec(
        key="threads", label="Threads (-t)", kind="int",
        default=8, min=1, max=32, step=1,
        description="Threads de generación.",
        group="Threading",
        extra_args_pattern="-t {value}", cli_flags=("-t",),
    ),
    ParamSpec(
        key="threads_batch", label="Batch threads (-tb)", kind="int",
        default=8, min=1, max=32, step=1,
        description="Threads de batch.",
        group="Threading",
        extra_args_pattern="-tb {value}", cli_flags=("-tb",),
    ),
    # ── Cache ───────────────────────────────────────────────────────────
    ParamSpec(
        key="flash_attention", label="Flash attention (-fa on)", kind="bool",
        default=True,
        description="Habilita flash attention en GPU.",
        group="Cache",
        # Multi-token special: emitted as "-fa on" when True, stripped when
        # False. cli_flags lists every token that may appear at the flag
        # position so merge_extra_args can find and remove it.
        extra_args_pattern="-fa on", cli_flags=("-fa",),
    ),
    ParamSpec(
        key="cache_type_k", label="Cache type K", kind="enum",
        default="q8_0", choices=("f16", "q8_0", "q4_0"),
        description="Quantización del K cache.",
        group="Cache",
        extra_args_pattern="--cache-type-k {value}",
        cli_flags=("--cache-type-k",),
    ),
    ParamSpec(
        key="cache_type_v", label="Cache type V", kind="enum",
        default="q8_0", choices=("f16", "q8_0", "q4_0"),
        description="Quantización del V cache.",
        group="Cache",
        extra_args_pattern="--cache-type-v {value}",
        cli_flags=("--cache-type-v",),
    ),
    # ── MoE ─────────────────────────────────────────────────────────────
    ParamSpec(
        key="cpu_moe", label="--cpu-moe", kind="bool",
        default=False,
        description="Offload de expertos MoE a CPU. Solo MoE.",
        group="MoE",
        # Only applicable on MoE families. We don't have a feature tag
        # for "moe" so the API decides applicability by inspecting the
        # entry's `params` string ("A3B", "A4B"). See _applicable_for.
        extra_args_pattern="--cpu-moe", cli_flags=("--cpu-moe",),
    ),
    # ── Reasoning ───────────────────────────────────────────────────────
    ParamSpec(
        key="reasoning_format", label="--reasoning-format", kind="enum",
        default="auto", choices=("none", "auto"),
        description="Modo de reasoning (para modelos hybrid-thinking).",
        group="Reasoning",
        extra_args_pattern="--reasoning-format {value}",
        cli_flags=("--reasoning-format",),
    ),
    # ── Multimodal ──────────────────────────────────────────────────────
    ParamSpec(
        key="image_min_tokens", label="--image-min-tokens", kind="int",
        default=1024, min=256, max=2048, step=64,
        description="Tokens mínimos por imagen (vision).",
        group="Multimodal",
        requires_features=("vision",),
        extra_args_pattern="--image-min-tokens {value}",
        cli_flags=("--image-min-tokens",),
    ),
)


def by_key(key: str) -> ParamSpec | None:
    for spec in SCHEMA:
        if spec.key == key:
            return spec
    return None


def validate_value(spec: ParamSpec, value: Any) -> Any:
    """Coerce + validate a raw value against the spec. Raises ValueError."""
    if spec.kind == "bool":
        if isinstance(value, bool):
            return value
        if isinstance(value, (int, float)):
            return bool(value)
        if isinstance(value, str):
            low = value.strip().lower()
            if low in {"true", "1", "yes", "on"}:
                return True
            if low in {"false", "0", "no", "off"}:
                return False
        raise ValueError(f"{spec.key}: expected boolean, got {value!r}")
    if spec.kind == "int":
        try:
            iv = int(value)
        except (TypeError, ValueError):
            raise ValueError(f"{spec.key}: expected int, got {value!r}")
        if spec.min is not None and iv < spec.min:
            raise ValueError(f"{spec.key}: {iv} < min {spec.min}")
        if spec.max is not None and iv > spec.max:
            raise ValueError(f"{spec.key}: {iv} > max {spec.max}")
        return iv
    if spec.kind == "float":
        try:
            fv = float(value)
        except (TypeError, ValueError):
            raise ValueError(f"{spec.key}: expected float, got {value!r}")
        if spec.min is not None and fv < spec.min:
            raise ValueError(f"{spec.key}: {fv} < min {spec.min}")
        if spec.max is not None and fv > spec.max:
            raise ValueError(f"{spec.key}: {fv} > max {spec.max}")
        return fv
    if spec.kind == "enum":
        sv = str(value)
        if spec.choices and sv not in spec.choices:
            raise ValueError(
                f"{spec.key}: {sv!r} not in choices {spec.choices}"
            )
        return sv
    raise ValueError(f"{spec.key}: unknown kind {spec.kind!r}")


def is_applicable(spec: ParamSpec, entry) -> bool:
    """True if this knob should be exposed for the given catalog entry.

    Rules:
    - requires_features: ALL listed features must be present on entry.
    - requires_family: entry.family must be in the list (if set).
    - cpu_moe special: only show on MoE entries (params contains "A").
    """
    if spec.requires_features:
        feats = set(entry.features)
        if not set(spec.requires_features).issubset(feats):
            return False
    if spec.requires_family and entry.family not in spec.requires_family:
        return False
    if spec.key == "cpu_moe":
        # Heuristic: MoE entries have params like "35B-A3B" / "26B-A4B".
        # Dense entries have "9B", "4B", "E4B", etc — no "-A".
        if "-A" not in entry.params:
            return False
    return True


__all__ = [
    "ParamSpec",
    "SCHEMA",
    "by_key",
    "validate_value",
    "is_applicable",
]
