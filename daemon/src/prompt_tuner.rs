//! Prompt Tuner — Axi analyzes task failure patterns and suggests improvements.
//!
//! When a task type fails repeatedly, the tuner examines the failure history
//! and proposes modifications to the system prompt or role prompts to
//! improve future success rates.

use anyhow::Result;
use log::info;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::fs;

const FAILURE_LOG: &str = "prompt-failures.json";
const PROMPT_OVERRIDES: &str = "prompt-overrides.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FailureEntry {
    pub objective: String,
    pub role: String,
    pub error: String,
    pub timestamp: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FailureLog {
    pub entries: Vec<FailureEntry>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PromptOverrides {
    /// Additional instructions appended to role prompts, keyed by role name.
    pub role_addons: std::collections::HashMap<String, String>,
}

pub struct PromptTuner {
    data_dir: PathBuf,
    failures: FailureLog,
    overrides: PromptOverrides,
}

impl PromptTuner {
    pub async fn load(data_dir: &std::path::Path) -> Self {
        let failures = if let Ok(c) = fs::read_to_string(data_dir.join(FAILURE_LOG)).await {
            serde_json::from_str(&c).unwrap_or_default()
        } else {
            FailureLog::default()
        };

        let overrides = if let Ok(c) = fs::read_to_string(data_dir.join(PROMPT_OVERRIDES)).await {
            serde_json::from_str(&c).unwrap_or_default()
        } else {
            PromptOverrides::default()
        };

        Self {
            data_dir: data_dir.to_path_buf(),
            failures,
            overrides,
        }
    }

    /// Record a task failure for pattern analysis.
    pub async fn record_failure(&mut self, objective: &str, role: &str, error: &str) -> Result<()> {
        self.failures.entries.push(FailureEntry {
            objective: objective.to_string(),
            role: role.to_string(),
            error: error.to_string(),
            timestamp: chrono::Utc::now().to_rfc3339(),
        });

        // Keep only last 100 failures
        if self.failures.entries.len() > 100 {
            self.failures.entries = self
                .failures
                .entries
                .split_off(self.failures.entries.len() - 100);
        }

        let json = serde_json::to_string_pretty(&self.failures)?;
        fs::write(self.data_dir.join(FAILURE_LOG), json).await?;
        Ok(())
    }

    /// Analyze failure patterns and generate prompt improvement suggestions.
    pub fn analyze_failures(&self) -> Vec<PromptSuggestion> {
        let mut suggestions = Vec::new();

        // Count failures per role
        let mut role_failures: std::collections::HashMap<String, Vec<&FailureEntry>> =
            std::collections::HashMap::new();
        for entry in &self.failures.entries {
            role_failures
                .entry(entry.role.clone())
                .or_default()
                .push(entry);
        }

        for (role, failures) in &role_failures {
            if failures.len() < 3 {
                continue; // Not enough data
            }

            // Find common error patterns
            let mut error_keywords: std::collections::HashMap<String, u32> =
                std::collections::HashMap::new();
            for f in failures {
                for word in f.error.split_whitespace() {
                    let w = word.to_lowercase();
                    if w.len() > 4 {
                        *error_keywords.entry(w).or_insert(0) += 1;
                    }
                }
            }

            // Find keywords that appear in >50% of failures for this role
            let threshold = (failures.len() as f64 * 0.5) as u32;
            let common: Vec<&String> = error_keywords
                .iter()
                .filter(|(_, count)| **count >= threshold.max(2))
                .map(|(word, _)| word)
                .collect();

            if !common.is_empty() {
                suggestions.push(PromptSuggestion {
                    role: role.clone(),
                    failure_count: failures.len(),
                    common_errors: common.iter().map(|s| s.to_string()).collect(),
                    suggestion: format!(
                        "Role '{}' has {} failures with common patterns: {}. Consider adding explicit instructions to handle these cases.",
                        role,
                        failures.len(),
                        common.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", ")
                    ),
                });
            }
        }

        suggestions
    }

    /// Get prompt addon for a role (if any override exists).
    pub fn get_role_addon(&self, role: &str) -> Option<&str> {
        self.overrides.role_addons.get(role).map(|s| s.as_str())
    }

    /// Set a prompt addon for a role.
    pub async fn set_role_addon(&mut self, role: &str, addon: &str) -> Result<()> {
        self.overrides
            .role_addons
            .insert(role.to_string(), addon.to_string());
        let json = serde_json::to_string_pretty(&self.overrides)?;
        fs::write(self.data_dir.join(PROMPT_OVERRIDES), json).await?;
        info!(
            "[prompt_tuner] Updated addon for role '{}': {}",
            role,
            &addon[..addon.len().min(80)]
        );
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PromptSuggestion {
    pub role: String,
    pub failure_count: usize,
    pub common_errors: Vec<String>,
    pub suggestion: String,
}
