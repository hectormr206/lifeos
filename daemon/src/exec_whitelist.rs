//! Exec Approval Whitelist — Persistent list of pre-approved commands.
//!
//! When the supervisor encounters a medium-risk command for the first time,
//! it asks for approval. If approved, the command pattern is saved to the
//! whitelist so it auto-approves next time.

use serde::{Deserialize, Serialize};
use tokio::fs;

const WHITELIST_FILE: &str = "exec-whitelist.json";

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ExecWhitelist {
    /// Command patterns that are pre-approved (substring match).
    pub approved_patterns: Vec<String>,
    /// Commands that were explicitly denied.
    pub denied_patterns: Vec<String>,
}

pub struct ExecWhitelistManager {
    whitelist: ExecWhitelist,
}

impl ExecWhitelistManager {
    pub async fn load(data_dir: &std::path::Path) -> Self {
        let path = data_dir.join(WHITELIST_FILE);
        let whitelist = if let Ok(content) = fs::read_to_string(&path).await {
            serde_json::from_str(&content).unwrap_or_default()
        } else {
            ExecWhitelist::default()
        };

        Self { whitelist }
    }

    /// Check if a command is pre-approved.
    pub fn is_approved(&self, command: &str) -> bool {
        let lower = command.to_lowercase();
        self.whitelist
            .approved_patterns
            .iter()
            .any(|p| lower.contains(&p.to_lowercase()))
    }

    /// Check if a command is explicitly denied.
    pub fn is_denied(&self, command: &str) -> bool {
        let lower = command.to_lowercase();
        self.whitelist
            .denied_patterns
            .iter()
            .any(|p| lower.contains(&p.to_lowercase()))
    }
}
