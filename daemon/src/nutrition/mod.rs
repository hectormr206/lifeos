//! Nutrition extraction pipeline (BI.3 — photo/voice → nutrition_log).
//!
//! This module turns raw user signals (a food photo from a capture, or
//! a voice transcript describing what was eaten) into structured
//! `NutritionEntry` records and persists them in the existing
//! `nutrition_log` table via `MemoryPlaneManager::log_nutrition_meal`.
//!
//! Design principles:
//!
//! * **Local-first.** The extractor calls the in-house `AiManager`
//!   wrapper around `llama-server` (vision-capable Qwen 4B by default).
//!   No external API is contacted unless the user opted into a remote
//!   provider through the standard router; this module never sends raw
//!   images or transcripts off-device on its own.
//! * **Strict schema.** LLM output is parsed into a strict JSON shape;
//!   anything that fails validation (empty name, non-positive qty,
//!   nonsensical kcal) is rejected before it touches storage.
//! * **No new gates.** This module only EXPOSES extraction + persistence
//!   helpers. Trigger surfaces (axi tool, HTTP endpoint, or the optional
//!   sensory-pipeline auto path) live in their own files and reuse the
//!   gates already enforced there (autoexec, audio_enabled, kill switch,
//!   bootstrap-token middleware).

pub mod extractor;

pub use extractor::{
    detect_food_intent, extract_from_image, extract_from_voice_transcript, persist_extraction,
    NutritionExtraction,
};
