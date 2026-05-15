"""Validated configuration schema for Axi (PRD P0.4).

Defines the 22 known config keys with types, defaults, bounds, and choices.
Used by `axi.config` for loading/saving and by the dashboard for typed
form rendering.

We intentionally avoid pulling pydantic into the dep tree — this module
implements minimal validation on top of stdlib dataclasses. The constraints
we need (type checks, numeric bounds, string enums) are all expressible
without a heavy validation library.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger("axi.config_schema")


class ConfigError(ValueError):
    """Raised when a config value fails validation.

    Attributes:
        field: The config key whose value is invalid.
        value: The invalid value (as supplied).
        reason: Human-readable description of why it was rejected.
    """

    def __init__(self, field: str, value: Any, reason: str) -> None:
        super().__init__(f"{field}={value!r}: {reason}")
        self.field = field
        self.value = value
        self.reason = reason


# Allowed Python types for each field. We use the JSON-Schema-ish primitive
# names so `to_json_schema()` is a straight mapping.
_TYPE_MAP: dict[str, tuple[type, ...]] = {
    "string": (str,),
    "boolean": (bool,),
    "integer": (int,),
    "number": (int, float),
}


@dataclass(frozen=True)
class ConfigField:
    name: str
    type: str  # "string" | "boolean" | "integer" | "number"
    default: Any
    description: str = ""
    minimum: float | None = None
    maximum: float | None = None
    choices: tuple[str, ...] | None = None

    def validate(self, value: Any) -> Any:
        # `bool` is a subclass of `int` in Python; reject the cross-confusion
        # explicitly so a stray `True` doesn't sneak in as `1` for integer
        # fields and vice versa.
        allowed = _TYPE_MAP[self.type]
        if self.type in ("integer", "number"):
            if isinstance(value, bool):
                raise ConfigError(self.name, value, f"expected {self.type}, got bool")
        if self.type == "boolean":
            if not isinstance(value, bool):
                raise ConfigError(self.name, value, "expected boolean")
        else:
            if not isinstance(value, allowed):
                raise ConfigError(
                    self.name, value, f"expected {self.type}, got {type(value).__name__}"
                )
        if self.type == "integer":
            # `int(1.0)` would coerce silently — we want strict integers.
            if isinstance(value, float):
                raise ConfigError(self.name, value, "expected integer, got float")
        if self.minimum is not None and value < self.minimum:
            raise ConfigError(self.name, value, f"must be >= {self.minimum}")
        if self.maximum is not None and value > self.maximum:
            raise ConfigError(self.name, value, f"must be <= {self.maximum}")
        if self.choices is not None and value not in self.choices:
            raise ConfigError(
                self.name, value, f"must be one of {list(self.choices)}"
            )
        return value


# ─────────────────────────── schema definition ──────────────────────────

_DEFAULT_WHISPER_PROMPT = (
    "Transcripción en español de dictado técnico y conversación natural. "
    "Incluye términos en inglés como Python, daemon, terminal, clipboard, "
    "Whisper, GPU, systemd, KDE, PipeWire, Piper, Kokoro, XTTS, prompt, "
    "código, framework, PR, branch, commit, debug, log, repo, endpoint."
)


FIELDS: tuple[ConfigField, ...] = (
    # ─────── identity / locale ───────
    ConfigField(
        "timezone", "string", "America/Mexico_City",
        "IANA timezone name used for dashboard timestamps.",
    ),
    ConfigField(
        "language", "string", "es-MX",
        "Primary user language for prompts and TTS.",
        choices=("es-MX", "es", "en"),
    ),
    ConfigField(
        "user_name", "string", "Héctor",
        "Display name addressed by the assistant.",
    ),
    # ─────── feature kill switches ───────
    ConfigField(
        "tts_enabled", "boolean", True,
        "If false, Piper/Kokoro never speaks responses.",
    ),
    ConfigField(
        "vision_enabled", "boolean", True,
        "If false, screen captures are not attached to brain calls.",
    ),
    ConfigField(
        "ocr_enabled", "boolean", True,
        "If true, OCR text from screen captures is prepended to the prompt "
        "when tesseract + pytesseract are available (P1.5 kill switch).",
    ),
    ConfigField(
        "fact_extraction_enabled", "boolean", True,
        "If false, long-term memory extraction is skipped.",
    ),
    ConfigField(
        "events_enabled", "boolean", True,
        "If false, structured event logging is a no-op (P0.1 kill switch).",
    ),
    ConfigField(
        "brain_metrics_enabled", "boolean", True,
        "If false, brain call latency/cost metrics are not recorded (P0.2 kill switch).",
    ),
    ConfigField(
        "digest_brain_enabled", "boolean", False,
        "If true, daily digest endpoint generates a brain summary paragraph (P1.3).",
    ),
    ConfigField(
        "notify_send_enabled", "boolean", True,
        "If true, critical/error events fire libnotify desktop notifications (P2.5).",
    ),
    ConfigField(
        "intents_enabled", "boolean", True,
        "If true, dictated utterances starting with 'axi …' are matched against "
        "the voice command palette before being typed (P1.2 kill switch).",
    ),
    ConfigField(
        "intents_brain_fallback_enabled", "boolean", False,
        "If true, an utterance that passes the prefix+verb gates but matches no "
        "regex intent is sent to the brain (2 s timeout) for classification. "
        "Off by default to keep the dictation path zero-cost (P1.2).",
    ),
    # ─────── meeting mode tuning ───────
    ConfigField(
        "meeting_silence_rms", "number", 0.015,
        "RMS gate below which a meeting chunk is dropped as silence.",
        minimum=0.0001, maximum=0.5,
    ),
    ConfigField(
        "meeting_window_minutes", "integer", 15,
        "Hierarchical summary window size in minutes.",
        minimum=1, maximum=120,
    ),
    ConfigField(
        "meeting_keep_raw_audio", "boolean", True,
        "Keep raw .wav chunks after successful transcription.",
    ),
    ConfigField(
        "meeting_incremental_transcribe", "boolean", True,
        "Transcribe incrementally during the meeting (vs only at close).",
    ),
    ConfigField(
        "meeting_transcribe_poll_s", "integer", 30,
        "Background incremental transcribe thread interval (seconds).",
        minimum=5, maximum=600,
    ),
    ConfigField(
        "meeting_chunk_seconds", "integer", 60,
        "Audio segment length for meeting recording (seconds).",
        minimum=10, maximum=600,
    ),
    ConfigField(
        "meeting_screen_interval_s", "integer", 2,
        "Screenshot capture interval during meetings (seconds).",
        minimum=1, maximum=60,
    ),
    ConfigField(
        "meeting_screen_dedup_hamming", "integer", 5,
        "Hamming distance threshold to dedupe near-identical screenshots.",
        minimum=0, maximum=32,
    ),
    # ─────── diarization (P2.1) ───────
    ConfigField(
        "diarization_v2_enabled", "boolean", False,
        "If true, meeting diarization uses pyannote.audio 3.1 instead of the "
        "V0 Resemblyzer pipeline. Opt-in because pyannote pulls ~600 MB of "
        "deps and runs on CPU (Blackwell sm_120 has no torch kernels yet).",
    ),
    # ─────── disk guards (P2.3) ───────
    ConfigField(
        "disk_min_gb_free", "integer", 2,
        "Minimum free disk space (GB) required before starting a meeting "
        "and reported by axi-check.",
        minimum=1, maximum=100,
    ),
    # ─────── daemon voice gate ───────
    ConfigField(
        "silence_rms_threshold", "number", 0.002,
        "RMS gate for dictation/ask — below this Whisper is skipped.",
        minimum=0.0001, maximum=0.5,
    ),
    ConfigField(
        "min_record_samples_ms", "integer", 300,
        "Minimum recording length (ms); shorter buffers are ignored.",
        minimum=50, maximum=5000,
    ),
    # ─────── whisper ───────
    ConfigField(
        "whisper_model_name", "string", "large-v3-turbo",
        "faster-whisper model identifier.",
    ),
    ConfigField(
        "whisper_beam_size", "integer", 5,
        "Whisper decoder beam size.",
        minimum=1, maximum=10,
    ),
    ConfigField(
        "whisper_initial_prompt", "string", _DEFAULT_WHISPER_PROMPT,
        "Decoder bias prompt — keeps Whisper on Spanish + tech vocabulary.",
    ),
    # ─────── UI polling ───────
    ConfigField(
        "tray_poll_ms", "integer", 500,
        "System tray state-poll interval (ms).",
        minimum=100, maximum=5000,
    ),
    ConfigField(
        "dashboard_poll_ms", "integer", 1000,
        "Dashboard auto-refresh interval (ms).",
        minimum=200, maximum=10000,
    ),
)


_BY_NAME: dict[str, ConfigField] = {f.name: f for f in FIELDS}


# ─────────────────────────────── public API ─────────────────────────────

def defaults() -> dict[str, Any]:
    """Return a fresh copy of the default values for every schema field."""
    return {f.name: f.default for f in FIELDS}


def load_validated(raw: dict[str, Any]) -> dict[str, Any]:
    """Strict load: apply defaults for missing keys, validate every value.

    Unknown keys cause a ConfigError. Use `lenient_load` if you want to
    accept and warn instead.
    """
    if not isinstance(raw, dict):
        raise ConfigError("<root>", raw, "config must be a JSON object")
    out: dict[str, Any] = defaults()
    for key, value in raw.items():
        f = _BY_NAME.get(key)
        if f is None:
            raise ConfigError(key, value, "unknown config key")
        out[key] = f.validate(value)
    return out


def lenient_load(raw: dict[str, Any]) -> dict[str, Any]:
    """Lenient load: unknown keys logged + preserved, known keys validated.

    Validation errors on KNOWN keys are also tolerated — the default value
    is used instead and a warning event is emitted. This is what `axi.config`
    uses at startup so a single bad value never blocks the daemon.
    """
    out: dict[str, Any] = defaults()
    if not isinstance(raw, dict):
        _warn("config", "root not a dict — using defaults", {"got": type(raw).__name__})
        return out
    for key, value in raw.items():
        f = _BY_NAME.get(key)
        if f is None:
            _warn("config", "unknown key (kept as-is)", {"key": key})
            out[key] = value
            continue
        try:
            out[key] = f.validate(value)
        except ConfigError as e:
            _warn(
                "config",
                f"invalid value for {key} — using default",
                {"key": key, "value": repr(value), "reason": e.reason},
            )
    return out


def to_json_schema() -> dict[str, Any]:
    """JSON Schema (draft 2020-12) describing every known field."""
    props: dict[str, Any] = {}
    for f in FIELDS:
        prop: dict[str, Any] = {
            "type": f.type,
            "default": f.default,
        }
        if f.description:
            prop["description"] = f.description
        if f.minimum is not None:
            prop["minimum"] = f.minimum
        if f.maximum is not None:
            prop["maximum"] = f.maximum
        if f.choices is not None:
            prop["enum"] = list(f.choices)
        props[f.name] = prop
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "AxiConfig",
        "type": "object",
        "additionalProperties": True,  # lenient — unknown keys allowed
        "properties": props,
    }


def field_names() -> tuple[str, ...]:
    return tuple(f.name for f in FIELDS)


def _warn(source: str, message: str, data: dict[str, Any] | None = None) -> None:
    """Emit a warning to the event log if available; never raises."""
    try:
        from axi import events  # lazy — avoid import cycle at module load
        events.log_warning(source, message, data)
    except Exception:  # noqa: BLE001
        log.warning("%s: %s data=%s", source, message, data)
