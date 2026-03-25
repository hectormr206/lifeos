//! Exec Approval Whitelist — Persistent list of pre-approved commands.
//!
//! When the supervisor encounters a medium-risk command for the first time,
//! it asks for approval. If approved, the command pattern is saved to the
//! whitelist so it auto-approves next time.

use anyhow::Result;
use log::info;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
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
    path: PathBuf,
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

        Self { path, whitelist }
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

    /// Add a command pattern to the approved list.
    pub async fn approve(&mut self, pattern: &str) -> Result<()> {
        if !self
            .whitelist
            .approved_patterns
            .contains(&pattern.to_string())
        {
            self.whitelist.approved_patterns.push(pattern.to_string());
            info!("[whitelist] Approved pattern: {}", pattern);
            self.save().await?;
        }
        Ok(())
    }

    /// Add a command pattern to the denied list.
    pub async fn deny(&mut self, pattern: &str) -> Result<()> {
        if !self
            .whitelist
            .denied_patterns
            .contains(&pattern.to_string())
        {
            self.whitelist.denied_patterns.push(pattern.to_string());
            info!("[whitelist] Denied pattern: {}", pattern);
            self.save().await?;
        }
        Ok(())
    }

    /// List all approved patterns.
    pub fn list_approved(&self) -> &[String] {
        &self.whitelist.approved_patterns
    }

    async fn save(&self) -> Result<()> {
        let json = serde_json::to_string_pretty(&self.whitelist)?;
        fs::write(&self.path, json).await?;
        Ok(())
    }
}
