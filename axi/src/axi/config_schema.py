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
    ConfigField(
        "reminder_voice_enabled", "boolean", True,
        "If true, transcribed speech is checked for reminder intent before the "
        "intent classifier and dictation path. Set to false to disable voice "
        "reminder creation (e.g. if the parser causes false positives).",
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
    ConfigField(
        "diarize_version", "string", "auto",
        "Diarizer elegido: 'auto' (intenta pyannote, cae a Resemblyzer), "
        "'v2' (fuerza pyannote, log si falla), 'v0' (fuerza Resemblyzer).",
        choices=("auto", "v2", "v0"),
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
    # ─────── chat ───────
    ConfigField(
        "chat_enabled", "boolean", True,
        "If false, the in-dashboard text chat endpoints return 503 (P-chat kill switch).",
    ),
    ConfigField(
        "chat_tts_enabled", "boolean", True,
        "If false, the chat 'speak' toggle is ignored — voice output never plays even "
        "when the request asks for it (P-chat-multimodal kill switch).",
    ),
    # ─────── nano-agents endpoint ───────
    ConfigField(
        "nano_endpoint", "string", "http://127.0.0.1:8090",
        "URL del nano llama-server (extractor de entidades, puerto 8090).",
    ),
    # ─────── dashboard bind ───────
    ConfigField(
        "dashboard_host", "string", "127.0.0.1",
        "IP en la que escucha el dashboard. 127.0.0.1 = solo local. "
        "0.0.0.0 = todas las interfaces (necesario para acceder desde la VPN). "
        "Reinicio del dashboard requerido.",
    ),
    ConfigField(
        "dashboard_port", "integer", 8081,
        "Puerto del dashboard. Reinicio del dashboard requerido.",
        minimum=1024, maximum=65535,
    ),
    # ─────── Axi autonomous agent (proactive thought) ───────
    ConfigField(
        "autonomous_enabled", "boolean", False,
        "Master toggle for Axi's autonomous proactive thought: a reflection tick "
        "that perceives presence (webcam) + activity (screen), decides when to "
        "surface the one thing that most deserves your attention, and sends at "
        "most one proactive notification per day. Read-only, opt-in. Live (no restart).",
    ),
    # ─────── lifeos posture (P6.2) ───────
    ConfigField(
        "posture_enabled", "boolean", False,
        "Master toggle for camera-based posture scans (opt-in).",
    ),
    ConfigField(
        "posture_cadence_minutes", "integer", 25,
        "Minutes between scheduled posture scans.",
        minimum=5, maximum=240,
    ),
    ConfigField(
        "posture_start_hour", "integer", 9,
        "Earliest hour of the day (local) for posture scans.",
        minimum=0, maximum=23,
    ),
    ConfigField(
        "posture_end_hour", "integer", 18,
        "Latest hour of the day (local) for posture scans.",
        minimum=1, maximum=24,
    ),
    ConfigField(
        "posture_weekdays_only", "boolean", True,
        "If true, posture scans only run Monday-Friday.",
    ),
    ConfigField(
        "posture_cooldown_minutes", "integer", 30,
        "Minimum minutes between consecutive nudges so the user isn't spammed.",
        minimum=1, maximum=600,
    ),
    ConfigField(
        "posture_confidence_threshold", "number", 0.6,
        "Minimum LLM confidence to fire a nudge.",
        minimum=0.0, maximum=1.0,
    ),
    # ─────── gaming co-pilot (Slice 1) ───────
    ConfigField(
        "game_copilot_enabled", "boolean", True,
        "When game-mode is active, inject a game-aware system prompt and brevity "
        "cap (max_tokens=256) into the voice ask flow. Set to false to disable the "
        "gaming co-pilot and keep the standard assistant prompt in game-mode.",
    ),
    # ─────── gaming co-pilot web-search (Slice 2) ───────
    ConfigField(
        "copilot_web_search_enabled", "boolean", True,
        "When game-mode is active and the question matches a search-intent pattern, "
        "run the deterministic web-search pipeline (entity extraction → SearXNG → "
        "synthesis) instead of the vision-only path. Requires web_research to be "
        "configured (searxng_url reachable). Set to false to keep the vision-only "
        "game co-pilot path without web search.",
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
