//! Multilingual Translation Engine (Fase X)
//!
//! Provides offline-first translation with multiple backends:
//! 1. Argos Translate (Python CLI, fully offline)
//! 2. LLM Router (local or cloud via llm_router)

use log::{debug, info, warn};
use serde::{Deserialize, Serialize};
use tokio::process::Command;

use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest, TaskComplexity};

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

/// Configuration for the translation engine.
pub struct TranslationEngine {}

/// A request to translate text.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranslationRequest {
    /// The text to translate.
    pub text: String,
    /// Source language ISO 639-1 code. `None` means auto-detect.
    pub source_lang: Option<String>,
    /// Target language ISO 639-1 code (e.g. "es", "en", "fr").
    pub target_lang: String,
}

/// The result of a translation operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranslationResult {
    pub original: String,
    pub translated: String,
    /// Detected or provided source language code.
    pub source_lang: String,
    pub target_lang: String,
    /// Which backend produced the translation: "argos", "llm-router".
    pub method: String,
}

// ---------------------------------------------------------------------------
// Language detection
// ---------------------------------------------------------------------------

/// Detect the language of the given text.
///
/// Uses a simple heuristic first (Spanish markers, common English words),
/// and falls back to the LLM router when the heuristic is inconclusive.
pub async fn detect_language(text: &str, router: Option<&LlmRouter>) -> Result<String, String> {
    // --- Heuristic pass ---
    if let Some(lang) = heuristic_detect(text) {
        debug!("translation: heuristic detected language '{lang}'");
        return Ok(lang);
    }

    // --- LLM fallback ---
    if let Some(router) = router {
        let prompt = format!(
            "What language is the following text written in? \
             Return ONLY the ISO 639-1 two-letter code (e.g. en, es, fr, de, pt). \
             Text: {text}"
        );
        let req = RouterRequest {
            messages: vec![ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(prompt),
            }],
            complexity: Some(TaskComplexity::Simple),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(4),
        };
        match router.chat(&req).await {
            Ok(resp) => {
                let code = resp.text.trim().to_lowercase();
                if code.len() == 2 && code.chars().all(|c| c.is_ascii_lowercase()) {
                    return Ok(code);
                }
                warn!("translation: LLM returned non-ISO code '{code}', defaulting to 'en'");
                return Ok("en".into());
            }
            Err(e) => {
                warn!("translation: LLM detect_language failed: {e}");
            }
        }
    }

    Err("Could not detect language: heuristic inconclusive and no LLM available".into())
}

/// Simple heuristic language detection.
fn heuristic_detect(text: &str) -> Option<String> {
    let lower = text.to_lowercase();

    // Spanish markers
    let spanish_markers = ['¿', 'ñ'];
    let spanish_accents = ['á', 'é', 'í', 'ó', 'ú'];
    let has_spanish_marker = spanish_markers.iter().any(|&c| lower.contains(c));
    let accent_count: usize = spanish_accents
        .iter()
        .map(|&c| lower.matches(c).count())
        .sum();
    if has_spanish_marker || accent_count >= 2 {
        return Some("es".into());
    }

    // Common English words (high-frequency function words)
    let english_words = [
        "the ", " is ", " are ", " have ", " has ", " was ", " were ",
    ];
    let english_hits: usize = english_words.iter().filter(|&&w| lower.contains(w)).count();
    if english_hits >= 2 {
        return Some("en".into());
    }

    // French markers
    let french_markers = ['ç', 'œ', 'ë', 'ï', 'ù', 'û', 'ê', 'î', 'ô', 'â'];
    let french_hits: usize = french_markers
        .iter()
        .filter(|&&c| lower.contains(c))
        .count();
    if french_hits >= 2 {
        return Some("fr".into());
    }

    // German markers
    let german_markers = ['ä', 'ö', 'ü', 'ß'];
    let german_hits: usize = german_markers
        .iter()
        .filter(|&&c| lower.contains(c))
        .count();
    if german_hits >= 2 {
        return Some("de".into());
    }

    // Portuguese markers
    let portuguese_markers = ['ã', 'õ', 'ç'];
    let portuguese_hits: usize = portuguese_markers
        .iter()
        .filter(|&&c| lower.contains(c))
        .count();
    if portuguese_hits >= 2 {
        return Some("pt".into());
    }

    None
}

// ---------------------------------------------------------------------------
// Translation
// ---------------------------------------------------------------------------

impl TranslationEngine {
    /// Create a new `TranslationEngine`.
    pub fn new(_model_path: Option<std::path::PathBuf>) -> Self {
        Self {}
    }

    /// Translate text using the best available backend.
    ///
    /// Backends are tried in priority order:
    /// 1. **Argos Translate** — fully offline Python CLI
    /// 2. **LLM Router** — local llama-server or cloud provider
    ///
    /// Returns an error only if every backend fails.
    pub async fn translate(
        &self,
        req: &TranslationRequest,
        router: Option<&LlmRouter>,
    ) -> Result<TranslationResult, String> {
        // Resolve source language
        let source_lang = match &req.source_lang {
            Some(lang) => lang.clone(),
            None => detect_language(&req.text, router)
                .await
                .unwrap_or_else(|_| "auto".into()),
        };

        // 1. Try Argos Translate
        match self
            .try_argos(&req.text, &source_lang, &req.target_lang)
            .await
        {
            Ok(translated) => {
                info!(
                    "translation: argos {} -> {} ({} chars)",
                    source_lang,
                    req.target_lang,
                    req.text.len()
                );
                return Ok(TranslationResult {
                    original: req.text.clone(),
                    translated,
                    source_lang,
                    target_lang: req.target_lang.clone(),
                    method: "argos".into(),
                });
            }
            Err(e) => {
                debug!("translation: argos unavailable: {e}");
            }
        }

        // 2. Try LLM Router
        if let Some(router) = router {
            match self
                .try_llm_router(router, &req.text, &source_lang, &req.target_lang)
                .await
            {
                Ok(translated) => {
                    info!(
                        "translation: llm-router {} -> {} ({} chars)",
                        source_lang,
                        req.target_lang,
                        req.text.len()
                    );
                    return Ok(TranslationResult {
                        original: req.text.clone(),
                        translated,
                        source_lang,
                        target_lang: req.target_lang.clone(),
                        method: "llm-router".into(),
                    });
                }
                Err(e) => {
                    debug!("translation: llm-router failed: {e}");
                }
            }
        }

        Err(format!(
            "All translation backends failed for {} -> {}",
            source_lang, req.target_lang
        ))
    }

    // --- Backend: Argos Translate ---

    async fn try_argos(&self, text: &str, source: &str, target: &str) -> Result<String, String> {
        let output = Command::new("argos-translate")
            .arg("--from")
            .arg(source)
            .arg("--to")
            .arg(target)
            .arg(text)
            .output()
            .await
            .map_err(|e| format!("Failed to spawn argos-translate: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("argos-translate exited with error: {stderr}"));
        }

        let translated = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if translated.is_empty() {
            return Err("argos-translate returned empty output".into());
        }
        Ok(translated)
    }

    // --- Backend: LLM Router ---

    async fn try_llm_router(
        &self,
        router: &LlmRouter,
        text: &str,
        source: &str,
        target: &str,
    ) -> Result<String, String> {
        let prompt = format!(
            "Translate the following text from {source} to {target}. \
             Return ONLY the translation, nothing else:\n{text}"
        );
        let req = RouterRequest {
            messages: vec![ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(prompt),
            }],
            complexity: Some(TaskComplexity::Medium),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(2048),
        };
        let resp = router
            .chat(&req)
            .await
            .map_err(|e| format!("LLM router error: {e}"))?;
        let translated = resp.text.trim().to_string();
        if translated.is_empty() {
            return Err("LLM router returned empty translation".into());
        }
        Ok(translated)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_heuristic_detect_spanish() {
        assert_eq!(heuristic_detect("¿Cómo estás hoy?"), Some("es".into()));
        assert_eq!(heuristic_detect("El niño corrió rápido"), Some("es".into()));
    }

    #[test]
    fn test_heuristic_detect_english() {
        assert_eq!(
            heuristic_detect("the cat is on the table and they have food"),
            Some("en".into())
        );
    }

    #[test]
    fn test_heuristic_detect_french() {
        assert_eq!(
            heuristic_detect("le garçon mange des crêpes"),
            Some("fr".into())
        );
    }

    #[test]
    fn test_heuristic_detect_german() {
        assert_eq!(
            heuristic_detect("der Bär isst Würstchen mit Käse"),
            Some("de".into())
        );
    }

    #[test]
    fn test_heuristic_detect_unknown() {
        assert_eq!(heuristic_detect("xyz 123"), None);
    }
}
