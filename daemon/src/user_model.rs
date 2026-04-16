//! User Model — dynamic profile built from user interactions.
//!
//! Stores: communication preferences, schedule patterns, active projects,
//! preferred response format, and current context. Auto-updated every 30min.

use anyhow::Result;
use chrono::{DateTime, Datelike, Utc};
use log::info;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UserModel {
    pub communication: CommunicationProfile,
    pub schedule_patterns: Vec<SchedulePattern>,
    pub active_projects: Vec<String>,
    pub declared_goals: Vec<String>,
    /// Current context: "work", "personal", "rest", "gaming"
    pub current_context: String,
    /// Language: "es", "en"
    pub language: String,
    pub updated_at: Option<DateTime<Utc>>,
    /// When the user first started using LifeOS (set on first boot)
    pub first_seen: Option<DateTime<Utc>>,
    /// Preferred TTS voice for Kokoro (e.g. "if_sara", "af_heart"). None = use server default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tts_voice: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommunicationProfile {
    /// 1-5 (1=muy informal, 5=muy formal)
    pub formality_level: u8,
    /// "brief", "normal", "detailed"
    pub verbosity: String,
    /// "bullets", "paragraphs", "tables", "mixed"
    pub preferred_format: String,
    /// "none", "light", "heavy"
    pub emoji_usage: String,
    /// "simple", "technical", "expert"
    pub vocabulary_level: String,
}

impl Default for CommunicationProfile {
    fn default() -> Self {
        Self {
            formality_level: 2,
            verbosity: "normal".into(),
            preferred_format: "mixed".into(),
            emoji_usage: "light".into(),
            vocabulary_level: "technical".into(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SchedulePattern {
    /// 0=Sun, 1=Mon, ..., 6=Sat
    pub day_of_week: u8,
    pub hour_range: (u8, u8),
    pub typical_activity: String,
    pub confidence: f32,
}

impl UserModel {
    /// Load from disk or create default.
    pub async fn load_from_dir(data_dir: &Path) -> Self {
        let path = data_dir.join("user_model.json");
        if let Ok(content) = tokio::fs::read_to_string(&path).await {
            serde_json::from_str(&content).unwrap_or_default()
        } else {
            Self::default()
        }
    }

    /// Save to disk.
    pub async fn save(&self, data_dir: &Path) -> Result<()> {
        tokio::fs::create_dir_all(data_dir).await?;
        let path = data_dir.join("user_model.json");
        let json = serde_json::to_string_pretty(self)?;
        tokio::fs::write(&path, json).await?;
        info!("[user_model] Saved to {}", path.display());
        Ok(())
    }

    /// Generate system prompt instructions based on the user model.
    pub fn prompt_instructions(&self) -> String {
        let mut instructions = String::new();

        let verbosity_hint = match self.communication.verbosity.as_str() {
            "brief" => "Responde de forma breve y concisa. Maximo 2-3 oraciones.",
            "detailed" => "Responde con detalle, explica el razonamiento.",
            _ => "Responde con un nivel de detalle normal.",
        };

        let format_hint = match self.communication.preferred_format.as_str() {
            "bullets" => "Usa listas con puntos cuando sea posible.",
            "tables" => "Usa tablas para comparaciones y datos estructurados.",
            "paragraphs" => "Usa parrafos fluidos.",
            _ => "",
        };

        let formality_hint = if self.communication.formality_level <= 2 {
            "Usa tono informal y cercano. Tutea al usuario."
        } else if self.communication.formality_level >= 4 {
            "Usa tono formal y profesional."
        } else {
            "Usa tono neutral y amigable."
        };

        instructions.push_str(&format!(
            "[Preferencias del usuario]\n{}\n{}\n{}\n",
            verbosity_hint, format_hint, formality_hint
        ));

        if !self.active_projects.is_empty() {
            instructions.push_str(&format!(
                "Proyectos activos del usuario: {}\n",
                self.active_projects.join(", ")
            ));
        }

        if !self.current_context.is_empty() {
            instructions.push_str(&format!("Contexto actual: {}\n", self.current_context));
        }

        if self.is_learning_mode() {
            instructions.push_str(
                "\n[Modo aprendizaje activo — primera semana]\n\
                 Observa mas, sugiere menos. Aprende las preferencias del usuario.\n\
                 No hagas sugerencias proactivas agresivas. Pregunta antes de asumir.\n",
            );
        }

        instructions
    }

    /// Returns `true` during the first 7 days after first_seen (learning mode).
    /// Axi observes more and suggests less during this period.
    pub fn is_learning_mode(&self) -> bool {
        self.first_seen
            .map(|fs| Utc::now().signed_duration_since(fs).num_days() < 7)
            .unwrap_or(true) // If no first_seen, assume learning mode
    }

    /// Number of days since the user first started using LifeOS.
    /// Used by prompt_instructions() and learning mode detection.
    #[allow(dead_code)]
    pub fn days_since_first_seen(&self) -> i64 {
        self.first_seen
            .map(|fs| Utc::now().signed_duration_since(fs).num_days())
            .unwrap_or(0)
    }

    /// Apply a preference change detected from implicit feedback.
    pub fn apply_preference(&mut self, key: &str, value: &str) {
        match key {
            "verbosity" => self.communication.verbosity = value.to_string(),
            "preferred_format" => self.communication.preferred_format = value.to_string(),
            "formality_level" => {
                if let Ok(v) = value.parse::<u8>() {
                    self.communication.formality_level = v.clamp(1, 5);
                }
            }
            "emoji_usage" => self.communication.emoji_usage = value.to_string(),
            "vocabulary_level" => self.communication.vocabulary_level = value.to_string(),
            "tts_voice" => {
                if value.trim().is_empty() {
                    self.tts_voice = None;
                } else {
                    self.tts_voice = Some(value.to_string());
                }
            }
            _ => {}
        }
        self.updated_at = Some(Utc::now());
    }
}

/// Detect implicit preference feedback from a user message.
/// Returns `Some((key, value))` if feedback is detected.
pub fn detect_preference_feedback(text: &str) -> Option<(String, String)> {
    let lower = text.to_lowercase();
    if lower.contains("breve") || lower.contains("resume") || lower.contains("corto") {
        return Some(("verbosity".into(), "brief".into()));
    }
    if lower.contains("detalle") || lower.contains("explica") || lower.contains("profundiz") {
        return Some(("verbosity".into(), "detailed".into()));
    }
    if lower.contains("bullet") || lower.contains("lista") || lower.contains("puntos") {
        return Some(("preferred_format".into(), "bullets".into()));
    }
    if lower.contains("tabla") || lower.contains("compara") {
        return Some(("preferred_format".into(), "tables".into()));
    }
    if lower.contains("formal") && !lower.contains("informal") {
        return Some(("formality_level".into(), "4".into()));
    }
    if lower.contains("informal") || lower.contains("casual") {
        return Some(("formality_level".into(), "2".into()));
    }
    None
}

// ---------------------------------------------------------------------------
// AQ.7 — Emotional Intelligence
// ---------------------------------------------------------------------------

/// Frustration level detected from recent user messages.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FrustrationLevel {
    None,
    Mild,
    Frustrated,
    VeryFrustrated,
}

/// Error-like keywords (Spanish + English) that signal frustration.
const FRUSTRATION_KEYWORDS: &[&str] = &[
    "no funciona",
    "error",
    "fallo",
    "again",
    "otra vez",
    "por que no",
];

/// Analyse a window of recent messages and return a frustration level.
pub fn detect_frustration(messages: &[&str]) -> FrustrationLevel {
    if messages.is_empty() {
        return FrustrationLevel::None;
    }

    let mut score: u32 = 0;

    // 1. Count error-like keywords across all messages.
    for msg in messages {
        let lower = msg.to_lowercase();
        for kw in FRUSTRATION_KEYWORDS {
            if lower.contains(kw) {
                score += 1;
            }
        }
    }

    // 2. Short angry messages (< 10 chars with "!" or "??" or ALL CAPS).
    for msg in messages {
        let trimmed = msg.trim();
        if trimmed.len() < 10 {
            if trimmed.contains('!') || trimmed.contains("??") {
                score += 1;
            }
            // All caps check (only for alphabetical content >= 2 chars).
            let alpha: String = trimmed.chars().filter(|c| c.is_alphabetic()).collect();
            if alpha.len() >= 2 && alpha == alpha.to_uppercase() {
                score += 1;
            }
        }
    }

    // 3. Retry patterns — same message sent 2+ times.
    let mut freq: HashMap<String, usize> = HashMap::new();
    for msg in messages {
        let key = msg.trim().to_lowercase();
        *freq.entry(key).or_insert(0) += 1;
    }
    for count in freq.values() {
        if *count >= 2 {
            score += (*count as u32) - 1;
        }
    }

    match score {
        0 => FrustrationLevel::None,
        1 => FrustrationLevel::Mild,
        2..=3 => FrustrationLevel::Frustrated,
        _ => FrustrationLevel::VeryFrustrated,
    }
}

/// Success-signal keywords (Spanish + English).
const ACHIEVEMENT_KEYWORDS: &[&str] = &[
    "funciono",
    "listo",
    "perfecto",
    "genial",
    "excelente",
    "ya quedo",
    "done",
    "works",
    "fixed",
];

/// Detect an achievement / success signal and return a celebration prompt hint.
pub fn detect_achievement(text: &str) -> Option<String> {
    let lower = text.to_lowercase();
    for kw in ACHIEVEMENT_KEYWORDS {
        if lower.contains(kw) {
            return Some(format!(
                "El usuario logro algo (\"{}\" detectado). Celebra brevemente y refuerza el logro.",
                kw
            ));
        }
    }
    None
}

/// Return a prompt hint appropriate for the given frustration level.
pub fn emotional_prompt_hint(frustration: &FrustrationLevel) -> &str {
    match frustration {
        FrustrationLevel::None => "",
        FrustrationLevel::Mild => {
            "El usuario puede estar un poco frustrado. Se paciente y ofrece alternativas."
        }
        FrustrationLevel::Frustrated => {
            "El usuario esta frustrado. Se empatico, ofrece ayuda directa, y evita explicaciones largas."
        }
        FrustrationLevel::VeryFrustrated => {
            "El usuario esta muy frustrado. Responde con calma, ofrece solucion inmediata, y pregunta si quiere que investigues."
        }
    }
}

// ---------------------------------------------------------------------------
// AQ.3 — Proactive Suggestions
// ---------------------------------------------------------------------------

/// Maximum suggestions that should be shown per hour (rate-limit constant).
pub const MAX_SUGGESTIONS_PER_HOUR: usize = 3;

/// Types of proactive suggestions the system can generate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SuggestionType {
    MorningBriefing,
    BreakReminder,
    TaskNudge,
    EndOfDaySummary,
}

/// A proactive suggestion generated from the user model + context.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProactiveSuggestion {
    pub suggestion_type: SuggestionType,
    pub message: String,
    pub priority: u8,
}

/// Generate proactive suggestions based on the user model, current hour, and
/// number of pending tasks. Results are capped at [`MAX_SUGGESTIONS_PER_HOUR`].
pub fn generate_suggestions(
    model: &UserModel,
    hour: u8,
    pending_tasks: usize,
) -> Vec<ProactiveSuggestion> {
    let mut suggestions: Vec<ProactiveSuggestion> = Vec::new();

    // Morning briefing (7-9 AM) — only if we have schedule patterns for today.
    if (7..=9).contains(&hour) {
        let today = chrono::Local::now().weekday().num_days_from_sunday() as u8;
        let has_schedule = model
            .schedule_patterns
            .iter()
            .any(|p| p.day_of_week == today);
        if has_schedule {
            suggestions.push(ProactiveSuggestion {
                suggestion_type: SuggestionType::MorningBriefing,
                message: "Buenos dias. Tienes actividades programadas hoy. Quieres un resumen?"
                    .into(),
                priority: 2,
            });
        }
    }

    // Break reminder — every 2 hours after 10 AM (10, 12, 14, 16, 18, 20).
    if hour > 10 && hour % 2 == 0 {
        suggestions.push(ProactiveSuggestion {
            suggestion_type: SuggestionType::BreakReminder,
            message: "Llevas un rato trabajando. Considera tomar un descanso de 5 minutos.".into(),
            priority: 1,
        });
    }

    // Task nudge when there are pending tasks.
    if pending_tasks > 0 {
        suggestions.push(ProactiveSuggestion {
            suggestion_type: SuggestionType::TaskNudge,
            message: format!(
                "Tienes {} tarea(s) pendiente(s). Quieres que te ayude con alguna?",
                pending_tasks
            ),
            priority: 3,
        });
    }

    // End of day summary (17-19 PM).
    if (17..=19).contains(&hour) {
        suggestions.push(ProactiveSuggestion {
            suggestion_type: SuggestionType::EndOfDaySummary,
            message: "Se acerca el final del dia. Quieres un resumen de lo que lograste hoy?"
                .into(),
            priority: 2,
        });
    }

    // Rate-limit to MAX_SUGGESTIONS_PER_HOUR, keeping highest priority first.
    suggestions.sort_by(|a, b| b.priority.cmp(&a.priority));
    suggestions.truncate(MAX_SUGGESTIONS_PER_HOUR);
    suggestions
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_model() {
        let model = UserModel::default();
        assert_eq!(model.communication.formality_level, 2);
        assert_eq!(model.communication.verbosity, "normal");
        assert_eq!(model.communication.preferred_format, "mixed");
    }

    #[test]
    fn test_prompt_instructions_default() {
        let model = UserModel::default();
        let prompt = model.prompt_instructions();
        assert!(prompt.contains("[Preferencias del usuario]"));
        assert!(prompt.contains("nivel de detalle normal"));
        assert!(prompt.contains("informal y cercano"));
    }

    #[test]
    fn test_prompt_instructions_with_projects() {
        let model = UserModel {
            active_projects: vec!["LifeOS".into(), "OpenClaw".into()],
            current_context: "work".into(),
            ..Default::default()
        };
        let prompt = model.prompt_instructions();
        assert!(prompt.contains("LifeOS"));
        assert!(prompt.contains("OpenClaw"));
        assert!(prompt.contains("Contexto actual: work"));
    }

    #[test]
    fn test_detect_feedback_brief() {
        assert_eq!(
            detect_preference_feedback("se mas breve"),
            Some(("verbosity".into(), "brief".into()))
        );
        assert_eq!(
            detect_preference_feedback("resume eso"),
            Some(("verbosity".into(), "brief".into()))
        );
    }

    #[test]
    fn test_detect_feedback_detailed() {
        assert_eq!(
            detect_preference_feedback("dame mas detalles"),
            Some(("verbosity".into(), "detailed".into()))
        );
        assert_eq!(
            detect_preference_feedback("explica mejor"),
            Some(("verbosity".into(), "detailed".into()))
        );
    }

    #[test]
    fn test_detect_feedback_format() {
        assert_eq!(
            detect_preference_feedback("ponlo en lista"),
            Some(("preferred_format".into(), "bullets".into()))
        );
        assert_eq!(
            detect_preference_feedback("usa una tabla"),
            Some(("preferred_format".into(), "tables".into()))
        );
    }

    #[test]
    fn test_detect_feedback_none() {
        assert_eq!(detect_preference_feedback("hola que tal"), None);
    }

    #[test]
    fn test_apply_preference() {
        let mut model = UserModel::default();
        model.apply_preference("verbosity", "brief");
        assert_eq!(model.communication.verbosity, "brief");
        model.apply_preference("formality_level", "5");
        assert_eq!(model.communication.formality_level, 5);
        // Clamp out of range
        model.apply_preference("formality_level", "10");
        assert_eq!(model.communication.formality_level, 5);
    }

    #[tokio::test]
    async fn test_save_and_load() {
        let dir = std::env::temp_dir().join("lifeos_test_user_model");
        let _ = tokio::fs::remove_dir_all(&dir).await;
        tokio::fs::create_dir_all(&dir).await.unwrap();

        let mut model = UserModel::default();
        model.communication.verbosity = "brief".into();
        model.active_projects = vec!["TestProject".into()];
        model.save(&dir).await.unwrap();

        let loaded = UserModel::load_from_dir(&dir).await;
        assert_eq!(loaded.communication.verbosity, "brief");
        assert_eq!(loaded.active_projects, vec!["TestProject".to_string()]);

        let _ = tokio::fs::remove_dir_all(&dir).await;
    }

    // -----------------------------------------------------------------------
    // AQ.7 — Emotional Intelligence tests
    // -----------------------------------------------------------------------

    #[test]
    fn test_frustration_none() {
        let msgs: Vec<&str> = vec!["hola", "como estas", "todo bien"];
        assert_eq!(detect_frustration(&msgs), FrustrationLevel::None);
        assert_eq!(detect_frustration(&[]), FrustrationLevel::None);
    }

    #[test]
    fn test_frustration_mild() {
        // Single error keyword → score 1 → Mild
        let msgs = vec!["no funciona el wifi"];
        assert_eq!(detect_frustration(&msgs), FrustrationLevel::Mild);
    }

    #[test]
    fn test_frustration_frustrated() {
        // Two keywords → score 2 → Frustrated
        let msgs = vec!["no funciona", "error de nuevo"];
        assert_eq!(detect_frustration(&msgs), FrustrationLevel::Frustrated);
    }

    #[test]
    fn test_frustration_very_frustrated() {
        // Many signals: keywords + retry + short angry
        let msgs = vec![
            "no funciona",
            "no funciona",
            "error",
            "POR QUE!",
            "otra vez",
        ];
        assert_eq!(detect_frustration(&msgs), FrustrationLevel::VeryFrustrated);
    }

    #[test]
    fn test_frustration_short_angry_message() {
        // Short message with "!" → score 1
        let msgs = vec!["NO!!"];
        assert_eq!(detect_frustration(&msgs), FrustrationLevel::Frustrated);
        // "NO!!" is < 10 chars, has "!", and is all caps → 2 points
    }

    #[test]
    fn test_frustration_retry_pattern() {
        // Same message 3 times → 2 extra points from retry
        let msgs = vec!["ayuda", "ayuda", "ayuda"];
        assert_eq!(detect_frustration(&msgs), FrustrationLevel::Frustrated);
    }

    #[test]
    fn test_detect_achievement_found() {
        assert!(detect_achievement("ya funciono!").is_some());
        assert!(detect_achievement("Listo, ya quedo").is_some());
        assert!(detect_achievement("it works now").is_some());
        assert!(detect_achievement("fixed the bug").is_some());
        assert!(detect_achievement("perfecto gracias").is_some());
    }

    #[test]
    fn test_detect_achievement_none() {
        assert!(detect_achievement("hola que tal").is_none());
        assert!(detect_achievement("necesito ayuda").is_none());
    }

    #[test]
    fn test_emotional_prompt_hint_all_levels() {
        assert_eq!(emotional_prompt_hint(&FrustrationLevel::None), "");
        assert!(emotional_prompt_hint(&FrustrationLevel::Mild).contains("paciente"));
        assert!(emotional_prompt_hint(&FrustrationLevel::Frustrated).contains("empatico"));
        assert!(emotional_prompt_hint(&FrustrationLevel::VeryFrustrated).contains("calma"));
    }

    // -----------------------------------------------------------------------
    // AQ.3 — Proactive Suggestions tests
    // -----------------------------------------------------------------------

    #[test]
    fn test_max_suggestions_constant() {
        assert_eq!(MAX_SUGGESTIONS_PER_HOUR, 3);
    }

    #[test]
    fn test_suggestions_task_nudge() {
        let model = UserModel::default();
        // At noon with 5 pending tasks → should include TaskNudge
        let suggestions = generate_suggestions(&model, 12, 5);
        assert!(suggestions
            .iter()
            .any(|s| s.suggestion_type == SuggestionType::TaskNudge));
    }

    #[test]
    fn test_suggestions_break_reminder() {
        let model = UserModel::default();
        // Hour 14 (even, > 10) with no tasks → should get BreakReminder
        let suggestions = generate_suggestions(&model, 14, 0);
        assert!(suggestions
            .iter()
            .any(|s| s.suggestion_type == SuggestionType::BreakReminder));
    }

    #[test]
    fn test_suggestions_end_of_day() {
        let model = UserModel::default();
        let suggestions = generate_suggestions(&model, 18, 0);
        assert!(suggestions
            .iter()
            .any(|s| s.suggestion_type == SuggestionType::EndOfDaySummary));
    }

    #[test]
    fn test_suggestions_morning_briefing_with_schedule() {
        let today = chrono::Local::now().weekday().num_days_from_sunday() as u8;
        let mut model = UserModel::default();
        model.schedule_patterns.push(SchedulePattern {
            day_of_week: today,
            hour_range: (9, 17),
            typical_activity: "work".into(),
            confidence: 0.9,
        });
        let suggestions = generate_suggestions(&model, 8, 0);
        assert!(suggestions
            .iter()
            .any(|s| s.suggestion_type == SuggestionType::MorningBriefing));
    }

    #[test]
    fn test_suggestions_morning_no_schedule() {
        let model = UserModel::default(); // no schedule_patterns
        let suggestions = generate_suggestions(&model, 8, 0);
        assert!(!suggestions
            .iter()
            .any(|s| s.suggestion_type == SuggestionType::MorningBriefing));
    }

    #[test]
    fn test_suggestions_capped_at_max() {
        let today = chrono::Local::now().weekday().num_days_from_sunday() as u8;
        let mut model = UserModel::default();
        model.schedule_patterns.push(SchedulePattern {
            day_of_week: today,
            hour_range: (9, 17),
            typical_activity: "work".into(),
            confidence: 0.9,
        });
        // hour=8 (morning briefing) + pending_tasks > 0 (task nudge)
        // Even if more were generated, never exceed MAX_SUGGESTIONS_PER_HOUR
        let suggestions = generate_suggestions(&model, 8, 10);
        assert!(suggestions.len() <= MAX_SUGGESTIONS_PER_HOUR);
    }

    #[test]
    fn test_suggestions_empty_at_odd_hour_no_tasks() {
        let model = UserModel::default();
        // Hour 3 AM, no tasks, no schedule → nothing
        let suggestions = generate_suggestions(&model, 3, 0);
        assert!(suggestions.is_empty());
    }

    // -----------------------------------------------------------------------
    // AQ.10 — Learning mode + first_seen tests
    // -----------------------------------------------------------------------

    #[test]
    fn test_learning_mode_no_first_seen() {
        let model = UserModel::default();
        // No first_seen → assume learning mode
        assert!(model.is_learning_mode());
    }

    #[test]
    fn test_learning_mode_recent_first_seen() {
        let model = UserModel {
            first_seen: Some(Utc::now() - chrono::Duration::days(2)),
            ..Default::default()
        };
        assert!(model.is_learning_mode());
    }

    #[test]
    fn test_learning_mode_expired() {
        let model = UserModel {
            first_seen: Some(Utc::now() - chrono::Duration::days(10)),
            ..Default::default()
        };
        assert!(!model.is_learning_mode());
    }

    #[test]
    fn test_learning_mode_boundary() {
        let model = UserModel {
            first_seen: Some(Utc::now() - chrono::Duration::days(7)),
            ..Default::default()
        };
        assert!(!model.is_learning_mode());
    }

    #[test]
    fn test_days_since_first_seen_no_first_seen() {
        let model = UserModel::default();
        assert_eq!(model.days_since_first_seen(), 0);
    }

    #[test]
    fn test_days_since_first_seen_some() {
        let model = UserModel {
            first_seen: Some(Utc::now() - chrono::Duration::days(5)),
            ..Default::default()
        };
        assert_eq!(model.days_since_first_seen(), 5);
    }

    #[test]
    fn test_prompt_instructions_learning_mode() {
        let model = UserModel::default(); // no first_seen → learning mode
        let prompt = model.prompt_instructions();
        assert!(prompt.contains("Modo aprendizaje activo"));
        assert!(prompt.contains("Observa mas, sugiere menos"));
    }

    #[test]
    fn test_prompt_instructions_no_learning_mode() {
        let model = UserModel {
            first_seen: Some(Utc::now() - chrono::Duration::days(30)),
            ..Default::default()
        };
        let prompt = model.prompt_instructions();
        assert!(!prompt.contains("Modo aprendizaje activo"));
    }

    // ── D3: tts_voice field tests ─────────────────────────────────────────────
    #[test]
    fn test_user_model_tts_voice_defaults_to_none() {
        let model = UserModel::default();
        assert_eq!(model.tts_voice, None);
    }

    #[test]
    fn test_user_model_tts_voice_deserialize_missing_key() {
        let json = r#"{"communication":{"formality_level":2,"verbosity":"normal","preferred_format":"mixed","emoji_usage":"light","vocabulary_level":"technical"},"schedule_patterns":[],"active_projects":[],"declared_goals":[],"current_context":"","language":"","updated_at":null,"first_seen":null}"#;
        let model: UserModel = serde_json::from_str(json).expect("deserialize without tts_voice");
        assert_eq!(model.tts_voice, None);
    }

    #[test]
    fn test_apply_preference_tts_voice_sets_value() {
        let mut model = UserModel::default();
        model.apply_preference("tts_voice", "af_heart");
        assert_eq!(model.tts_voice, Some("af_heart".to_string()));
    }

    #[test]
    fn test_apply_preference_tts_voice_empty_clears_value() {
        let mut model = UserModel {
            tts_voice: Some("if_sara".to_string()),
            ..Default::default()
        };
        model.apply_preference("tts_voice", "");
        assert_eq!(model.tts_voice, None);
    }
}
