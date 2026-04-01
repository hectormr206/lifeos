//! User Model — dynamic profile built from user interactions.
//!
//! Stores: communication preferences, schedule patterns, active projects,
//! preferred response format, and current context. Auto-updated every 30min.

use anyhow::Result;
use chrono::{DateTime, Utc};
use log::info;
use serde::{Deserialize, Serialize};
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

        instructions
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
        let mut model = UserModel::default();
        model.active_projects = vec!["LifeOS".into(), "OpenClaw".into()];
        model.current_context = "work".into();
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
}
