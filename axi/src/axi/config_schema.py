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


def _detect_system_timezone() -> str:
    """Return the IANA timezone name for the current machine.

    Uses tzlocal.get_localzone_name() which reads /etc/localtime or the
    TZ environment variable.  Falls back to 'UTC' if tzlocal is missing,
    raises, or returns None.
    """
    try:
        import tzlocal
        name = tzlocal.get_localzone_name()
        if name:
            return str(name)
    except Exception:
        pass
    return "UTC"


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
        "timezone", "string", _detect_system_timezone(),
        "IANA timezone name used for dashboard timestamps.",
    ),
    ConfigField(
        "language", "string", "es-MX",
        "Primary user language for prompts and TTS.",
        choices=("es-MX", "es", "en"),
    ),
    ConfigField(
        "user_name", "string", "",
        "Display name the assistant addresses you by. Empty on a fresh install — "
        "set during onboarding when you first introduce yourself to Axi. Also the "
        "label of the user-hub node in the knowledge graph (per-install, not "
        "hardcoded).",
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
        "chat_autoroute_enabled", "boolean", True,
        "If true (default), the general chat auto-routes domain data (a measurement, "
        "a gasto, a question about your records) to the matching domain spec before "
        "falling back to the general brain. Set false to always use the general brain.",
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
    # ─────── embedding service endpoint ───────
    ConfigField(
        "embed_endpoint", "string", "http://127.0.0.1:8091",
        "URL of the llama-embed server (text embedding service, port 8091). "
        "Serves /v1/embeddings for semantic memory (Slice 1). "
        "Default model: Qwen3-Embedding-4B (configurable via active_embed_model.json).",
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
    # ─────── wake-word speech segmentation ───────
    ConfigField(
        "wakeword_silence_seconds", "number", 1.8,
        "Seconds of silence that mark the end of a spoken command to the wake-word "
        "listener. Raise it if Axi cuts you off when you pause to think mid-sentence; "
        "lower it for snappier turn-taking. Also the pause that must precede a wake — "
        "raise toward 2-3s for fewer false wakes during a conversation.",
        minimum=0.4,
        maximum=6.0,
    ),
    ConfigField(
        "wakeword_max_leading_chars", "integer", 14,
        "'Axi' must start within this many characters of the transcript to count as "
        "a wake — so it must LEAD the utterance (after a pause), not be embedded in a "
        "conversation. This stops false wakes when an Axi-like sound appears mid-talk. "
        "Raise to be more permissive; set -1 to match 'Axi' anywhere (old behavior).",
        minimum=-1,
        maximum=120,
    ),
    ConfigField(
        "wakeword_max_segment_seconds", "number", 25.0,
        "Hard cap (seconds) on a single spoken command before it is force-flushed "
        "to transcription, so a very long utterance still gets processed. Raised so "
        "a long sentence is not chopped at the cap before you finish.",
        minimum=4.0,
        maximum=60.0,
    ),
    ConfigField(
        "wakeword_min_rms", "number", 0.018,
        "Minimum RMS energy a captured segment must have to be transcribed for "
        "wake detection. Below this it is treated as ambient noise and dropped, so "
        "background noise is not voiced as a hallucinated 'Axi' false wake. Raise it "
        "if Axi self-activates; lower it if it misses your quiet 'Axi'. 0 disables.",
        minimum=0.0,
        maximum=0.2,
    ),
    ConfigField(
        "chat_min_rms", "number", 0.005,
        "Minimum RMS energy a chat voice message must have before it is sent to "
        "Whisper. Below this the audio is treated as silence and dropped (Whisper "
        "would otherwise hallucinate YouTube-style filler over a near-silent clip). "
        "Kept low so quiet speech still transcribes; raise it if silent clips still "
        "produce garbage, lower it if quiet messages are ignored. 0 disables.",
        minimum=0.0,
        maximum=0.2,
    ),
    ConfigField(
        "wakeword_initial_prompt", "string", "",
        "Whisper initial_prompt for wake-word transcription. Empty by default: a "
        "non-empty bias like 'Axi.' made Whisper transcribe breaths/noise AS 'Axi', "
        "causing false wakes. Leave empty unless you specifically want to bias "
        "transcription toward certain words.",
    ),
    ConfigField(
        "wakeword_vad_filter", "boolean", False,
        "Whether faster-whisper's internal Silero VAD pre-filters the wake-word "
        "audio before transcription. Default false: with it on, marginal/quiet "
        "speech was discarded and the wake word 'Axi' was silently dropped, forcing "
        "the user to repeat. is_hallucination + match_wake already guard false wakes.",
    ),
    ConfigField(
        "wakeword_vad_aggressiveness", "integer", 3,
        "WebRTC VAD aggressiveness (0–3) for the wake-word listener. Higher rejects "
        "background noise as non-speech more strongly, so it detects when you actually "
        "stop talking instead of treating ambient noise as continuous speech (which "
        "forced 15 s mid-sentence cuts). 3 = most aggressive.",
        minimum=0,
        maximum=3,
    ),
    # ─────── wake-word CPU transcription (keep the GPU asleep) ───────
    ConfigField(
        "wakeword_cpu_whisper_enabled", "boolean", True,
        "If true (default), the always-listening wake-gate transcribes voiced "
        "segments with a small CPU Whisper model instead of the shared GPU "
        "server, so the GPU stays asleep until a real command needs it. Falls "
        "back to the GPU server automatically if the CPU model is unavailable.",
    ),
    ConfigField(
        "wakeword_cpu_whisper_model", "string", "base",
        "faster-whisper model for the CPU wake-gate (tiny|base|small). 'base' "
        "balances 'Axi' detection accuracy and CPU cost; 'tiny' is cheapest, "
        "'small' is more accurate. Only the wake-gate uses this — actual "
        "commands still use the high-quality GPU server.",
    ),
    # ─────── wake-word always-on ───────
    ConfigField(
        "wakeword_always_on", "boolean", True,
        "If true (default), the wake-word listener starts automatically when the "
        "daemon starts, regardless of the AXI_WAKEWORD_ENABLED env var. Set to false "
        "to revert to env-var-only control (legacy game-mode-only behaviour).",
    ),
    # ─────── wake-word follow-up window ───────
    ConfigField(
        "wakeword_followup_enabled", "boolean", True,
        "If true (default), after Axi finishes speaking a response, a follow-up window "
        "opens during which the user can reply without repeating the wake word.",
    ),
    ConfigField(
        "wakeword_followup_seconds", "number", 12.0,
        "Base duration (seconds) of the follow-up window opened after Axi speaks. "
        "If the answer ends with a question ('?'), 3 extra seconds are added automatically. "
        "Only active when wakeword_followup_enabled is true.",
        minimum=1.0,
        maximum=60.0,
    ),
    # ─────── wake-word engine ───────
    ConfigField(
        "wakeword_engine", "string", "openwakeword",
        "Wake-word detection engine: 'openwakeword' (instant acoustic detection via "
        "openWakeWord ONNX model — default) or 'vad_whisper' (legacy fallback: "
        "VAD gating + Whisper transcription for every segment).",
        choices=("openwakeword", "vad_whisper"),
    ),
    ConfigField(
        "wakeword_model_path", "string", "alexa",
        "openWakeWord model to load. Accepts either a pretrained model name (e.g. "
        "'alexa', 'hey_jarvis') or an absolute path to a custom .onnx file (e.g. "
        "'/home/user/models/axi.onnx'). The loader handles both forms so the "
        "custom Axi model can be activated with no code change.",
    ),
    ConfigField(
        "wakeword_threshold", "number", 0.5,
        "Confidence score threshold [0.0–1.0] above which an openWakeWord prediction "
        "triggers wake detection. Higher values reduce false positives; lower values "
        "increase recall. Only used when wakeword_engine='openwakeword'.",
        minimum=0.0,
        maximum=1.0,
    ),
    ConfigField(
        "wakeword_webcam_enabled", "boolean", True,
        "If true (default), the wake-word vision router may route to the webcam "
        "when the user's command contains physical-world cues ('mírame', 'qué tengo "
        "en la mano', 'look at me', etc.). Set to false to disable webcam capture "
        "for wake-word turns — the router will fall through to screen or none. "
        "Privacy opt-out; no restart required.",
    ),
    # ─────── semantic graph bridging gates ───────
    ConfigField(
        "graph_bridge_conversations", "boolean", False,
        "If true, each chat turn is also added as a node in the semantic graph. "
        "Default off keeps the graph to structured life-facts only.",
    ),
    ConfigField(
        "graph_bridge_meetings", "boolean", False,
        "If true, meeting summaries are added as nodes in the semantic graph. "
        "Default off (meetings are noisy and pollute the life-facts graph).",
    ),
    ConfigField(
        "graph_bridge_chat_facts", "boolean", True,
        "If true (default), durable facts from free chat (identity, preferences, "
        "biographical, relationships) are extracted into the semantic graph so Axi "
        "builds long-term, relatable memory of who you are — not just structured "
        "life-domains. Structured domains (health/finance) are skipped here to avoid "
        "duplicating their own bridged nodes.",
    ),
    # ─────── chat archive (bound the log as it grows) ───────
    ConfigField(
        "chat_archive_enabled", "boolean", True,
        "If true (default), once the chat log grows past hot_turns+batch, the "
        "oldest batch of turns is summarized into a graph node and the raw turns "
        "are deleted — durable facts already live in the graph, so knowledge is "
        "kept while the log stays bounded.",
    ),
    ConfigField(
        "chat_archive_hot_turns", "integer", 400,
        "How many recent chat turns to always keep raw (the 'hot' window). Archiving "
        "only touches turns older than this.",
        minimum=50,
        maximum=10000,
    ),
    ConfigField(
        "chat_archive_batch", "integer", 200,
        "How many old turns to summarize+prune per archive pass.",
        minimum=20,
        maximum=2000,
    ),
    ConfigField(
        "entity_coref_llm", "boolean", True,
        "If true (default), medium-confidence entity coreference (a novel name "
        "variant or typo that fuzzy-matches an existing entity) is confirmed by a "
        "quick LLM check before merging, so 'Ana Garcia'/'Anita' resolve to the "
        "same node without falsely merging distinct people. Strong fuzzy matches "
        "merge without the LLM; set false to disable the LLM tiebreaker.",
    ),
    # ─────── graph recall (RAG) ───────
    ConfigField(
        "graph_recall", "boolean", True,
        "If true, semantically relevant graph memories are injected into the brain "
        "system prompt as a recall block. Default on; set false to disable.",
    ),
    ConfigField(
        "graph_recall_max_distance", "number", 0.78,
        "Cosine distance upper bound for graph recall. Nodes with distance above "
        "this threshold are excluded. 0 = identical, 1 = orthogonal. Lower values "
        "produce tighter relevance. Default 0.78 — empirically tuned against the "
        "Qwen3-Embedding-4B/512 model on real data: keyword and natural-language "
        "recall queries land at 0.56-0.74 while casual chat sits at 0.83+, so 0.78 "
        "separates them. Fully conversational compound questions embed at ~0.87 "
        "(indistinguishable from casual) and are handled by the big-brain recall tool.",
        minimum=0.0,
        maximum=1.0,
    ),
    ConfigField(
        "graph_recall_tool_max_distance", "number", 0.9,
        "Looser distance gate used when the big brain explicitly calls the "
        "recall_memory tool (vs the tighter passive-injection default 0.78). "
        "Tool-based recall is intentional — the model chose to search — so a "
        "wider net is appropriate.",
        minimum=0.0,
        maximum=1.0,
    ),
    ConfigField(
        "recall_escalation_enabled", "boolean", True,
        "If true, voice/plain-ask compound personal-data questions that miss the tight passive "
        "recall gate retry at the wider graph_recall_tool_max_distance gate, gated by a "
        "personal-data heuristic.",
    ),
    # ─────── dev agent ───────
    ConfigField(
        "dev_agent_max_budget_usd", "number", 0.50,
        "Hard cost cap (USD) for a single dev-agent coding run.",
        minimum=0.0,
        maximum=20.0,
    ),
    ConfigField(
        "dev_agent_max_turns", "integer", 8,
        "Maximum agentic turns for a single dev-agent coding run.",
        minimum=1,
        maximum=50,
    ),
    ConfigField(
        "dev_agent_model", "string", "",
        "Claude model override for the dev agent. Empty string uses the SDK default.",
    ),
    ConfigField(
        "dev_agent_sandbox", "boolean", True,
        "If true (default), the dev agent runs inside a rootless podman container: "
        "FS isolation (worktree-only mounts), env scrubbing (only ANTHROPIC_API_KEY "
        "forwarded), --userns=keep-id. Disable only for debugging — the agent REFUSES "
        "to run uncontained when false.",
    ),
    ConfigField(
        "dev_agent_image", "string", "localhost/axi-coder:latest",
        "Podman image used for the dev agent sandbox container. Must be available "
        "locally (podman pull or built from the axi Containerfile).",
    ),
    # ─────── dev-director loop ───────
    ConfigField(
        "dev_director_repo", "string", "~/LifeOS/lifeos",
        "Path to the git repo used as the dev-director workspace (the real LifeOS repo). "
        "Tilde is expanded at runtime. A worktree is created here; the main tree is never touched.",
    ),
    ConfigField(
        "dev_director_results_dir", "string", "~/LifeOS/dev-results",
        "Directory where dev-director saves .patch files. Created automatically if missing. "
        "Tilde is expanded at runtime.",
    ),
    ConfigField(
        "dev_director_max_rounds", "integer", 3,
        "Maximum director→coder→reviewer rounds per dev_develop task.",
        minimum=1,
        maximum=8,
    ),
    ConfigField(
        "dev_director_max_turns", "integer", 60,
        "Hard cap on Claude Code agent turns per round (--max-turns) — runaway guard.",
        minimum=1,
        maximum=1000,
    ),
    ConfigField(
        "dev_director_max_budget_usd", "number", 5.0,
        "Hard spend cap per Claude Code round in USD (--max-budget-usd).",
        minimum=0.1,
        maximum=1000.0,
    ),
    ConfigField(
        "dev_director_fallback_models", "string", "sonnet,haiku",
        "Comma-separated --fallback-model list for Claude Code when the primary "
        "model is overloaded. Empty disables the flag.",
    ),
    ConfigField(
        "dev_director_test_command", "string", "tests/test_dev_director.py -q",
        "Pytest arguments (after `-m pytest`) to run in the worktree after each Claude round. "
        "PYTHONPATH is set to <worktree>/axi/src so the worktree's code is tested, not the live install.",
    ),
    ConfigField(
        "dev_director_venv_python", "string", "~/LifeOS/lifeos/axi/.venv/bin/python",
        "Absolute path to the venv Python used to invoke pytest. Tilde is expanded at runtime.",
    ),
    ConfigField(
        "dev_director_branch_prefix", "string", "axi/self-build",
        "Git branch-name prefix for worktree branches created by the dev-director.",
    ),
    ConfigField(
        "dev_director_test_timeout", "integer", 300,
        "Seconds before the test subprocess is killed.",
        minimum=30,
        maximum=1800,
    ),
    # ─────── dev-run (detached state-tracked runs) ───────
    ConfigField(
        "dev_run_state_dir", "string", "~/LifeOS/dev-runs",
        "Directory where dev-run state.json files are stored. Each run gets a subdirectory. "
        "Tilde is expanded at runtime.",
    ),
    ConfigField(
        "dev_run_poll_interval_s", "integer", 300,
        "Seconds between daemon polls that check run health and resume waiting_quota runs.",
        minimum=30,
        maximum=3600,
    ),
    ConfigField(
        "dev_run_max_wall_clock_s", "integer", 21600,
        "Maximum total wall-clock seconds a run may live (across all resumes). "
        "Runs exceeding this are moved to needs_human.",
        minimum=600,
        maximum=86400,
    ),
    # ─────── battery mode (power-aware behavior on battery) ───────
    # Axi follows the external power-mode service's state file as the single
    # source of truth (axi.power). VT-3B and the brains stay resident on battery
    # by design (VT also serves reasoning chat) — the battery win is fewer
    # background wakeups + the CPU wake-gate, not model eviction.
    ConfigField(
        "battery_loop_slowdown_factor", "integer", 4,
        "On battery, background loop intervals (self-improve, dev-run poll, "
        "embed drain) are multiplied by this factor to wake the "
        "machine less often. 1 = no slowdown.",
        minimum=1,
        maximum=20,
    ),
    ConfigField(
        "dev_run_quota_wait_default_s", "integer", 3600,
        "Seconds to wait before retrying a run that hit a quota/usage limit.",
        minimum=60,
        maximum=86400,
    ),
    ConfigField(
        "dev_run_max_resumes", "integer", 5,
        "Maximum number of automatic resumes after unexpected unit death. "
        "Runs that exceed this are moved to needs_human.",
        minimum=0,
        maximum=20,
    ),
    ConfigField(
        "dev_run_round_timeout_s", "integer", 3600,
        "Seconds before a single claude invocation inside a dev-run is killed.",
        minimum=60,
        maximum=86400,
    ),
    # ─────── dev environments (persistent worktrees you test before deploy) ───────
    ConfigField(
        "dev_env_worktree_dir", "string", "~/LifeOS/dev-envs",
        "Durable directory where each environment's persistent git worktree lives "
        "(one subdirectory per environment). Unlike ephemeral dev-runs, these are "
        "NOT deleted — you test, iterate, and deploy them. Tilde expanded at runtime.",
    ),
    ConfigField(
        "dev_env_branch_prefix", "string", "axi/env",
        "Git branch-name prefix for persistent environment worktrees.",
    ),
    ConfigField(
        "dev_env_meta_timeout_s", "number", 8.0,
        "Seconds to wait for VT-3B to generate an environment's card title/description "
        "at creation. On timeout, a goal-derived fallback title is used instead.",
        minimum=1.0,
        maximum=60.0,
    ),
    ConfigField(
        "dev_env_instance_port_base", "integer", 8092,
        "First port tried when launching an environment's isolated test dashboard. "
        "Kept above the real dashboard (8081) and the model servers (8090/8091).",
        minimum=1024,
        maximum=65000,
    ),
    ConfigField(
        "dev_env_instance_port_count", "integer", 24,
        "How many consecutive ports (from the base) to probe for a free one when "
        "launching an isolated test instance.",
        minimum=1,
        maximum=200,
    ),
    ConfigField(
        "dev_env_instance_seed_from_real", "boolean", False,
        "If true, copy the real (encrypted) DBs + keys into the isolated test "
        "instance so you test against your actual data (still a throwaway copy — "
        "changes never reach the real DBs). Default false = fresh empty databases.",
    ),
    ConfigField(
        "dev_env_deploy_target_branch", "string", "main",
        "Branch a deployed environment lands on. The env's diff is applied onto "
        "origin/<branch> and pushed directly (no PR — the isolated-instance test "
        "is the review gate). This is your production branch.",
    ),
    ConfigField(
        "dev_env_deploy_auto_install", "boolean", True,
        "If true, Deploy ALSO brings the change to the local running app: it pulls "
        "the target branch and restarts the services (detached, so the dashboard "
        "can restart itself). Guarded — only a clean, fast-forwardable tree is "
        "touched. Set false to keep Deploy GitHub-only and install by hand.",
    ),
    ConfigField(
        "dev_env_deploy_restart_services", "string", "axi-dashboard axi-voice",
        "Space-separated systemd --user services restarted by Deploy's local "
        "install step so the new code is picked up.",
    ),
    ConfigField(
        "dev_self_improve_enabled", "boolean", False,
        "If true, Axi fires ONE self-improvement dev run per day (high-stakes, "
        "opt-in). The result lands in /dev awaiting your approval — never auto-applied.",
    ),
    ConfigField(
        "dev_self_improve_hour", "integer", 3,
        "Hour of day (0-23, user timezone) for the daily self-improvement run.",
        minimum=0,
        maximum=23,
    ),
    ConfigField(
        "dev_self_improve_goal", "string", "",
        "Override the daily self-improvement meta-goal. Empty = the built-in "
        "low-risk default (review recent work, implement one small improvement).",
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
