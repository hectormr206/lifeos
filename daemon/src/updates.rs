//! Update checking module
//! Handles checking for and staging system updates

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Command;

#[cfg(test)]
mod updates_tests;

/// Update check result
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateResult {
    pub available: bool,
    pub current_version: String,
    pub new_version: String,
    pub changelog: Option<String>,
    pub size_mb: Option<u64>,
}

/// Update checker
#[derive(Debug)]
pub struct UpdateChecker {
    current_image: Option<String>,
    tuf_metadata_dir: PathBuf,
    tuf_state_path: PathBuf,
    require_tuf: bool,
}

impl UpdateChecker {
    pub fn new() -> Self {
        let tuf_metadata_dir = std::env::var("LIFEOS_TUF_METADATA_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("/etc/lifeos/tuf"));
        let tuf_state_path = std::env::var("LIFEOS_TUF_STATE_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("/var/lib/lifeos/tuf-state.json"));
        let require_tuf_default = crate::tuf::metadata_exists(&tuf_metadata_dir);
        let require_tuf = parse_env_bool("LIFEOS_TUF_REQUIRED", require_tuf_default);

        Self {
            current_image: None,
            tuf_metadata_dir,
            tuf_state_path,
            require_tuf,
        }
    }

    /// Check for available updates
    pub async fn check_for_updates(&mut self) -> anyhow::Result<UpdateResult> {
        self.enforce_tuf_policy()?;

        // Get current bootc status to determine current image
        let output = Command::new("bootc").args(["status", "--json"]).output()?;

        if !output.status.success() {
            anyhow::bail!("Failed to get bootc status");
        }

        let json: serde_json::Value = serde_json::from_slice(&output.stdout)?;

        // Extract current image
        let current_image = json
            .get("status")
            .and_then(|s| s.get("booted"))
            .and_then(|b| b.get("image"))
            .and_then(|i| i.get("image"))
            .and_then(|i| i.as_str())
            .map(|s| s.to_string());

        self.current_image = current_image.clone();

        let current_version = json
            .get("status")
            .and_then(|s| s.get("booted"))
            .and_then(|b| b.get("version"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| "unknown".to_string());

        // Check for updates with bootc upgrade --check
        let check_output = Command::new("bootc")
            .args(["upgrade", "--check"])
            .output()?;

        let output_str = String::from_utf8_lossy(&check_output.stdout);
        let stderr_str = String::from_utf8_lossy(&check_output.stderr);

        // Parse output to determine if update is available
        let available = check_output.status.success()
            && (output_str.contains("Update available") || stderr_str.contains("Update available"));

        if available {
            // Parse new version from output
            let new_version = parse_version_from_output(&output_str)
                .or_else(|| parse_version_from_output(&stderr_str))
                .unwrap_or_else(|| "newer".to_string());

            Ok(UpdateResult {
                available: true,
                current_version: current_version.clone(),
                new_version,
                changelog: None, // Could fetch from OCI annotations
                size_mb: None,   // Could calculate from layers
            })
        } else {
            Ok(UpdateResult {
                available: false,
                current_version: current_version.clone(),
                new_version: current_version,
                changelog: None,
                size_mb: None,
            })
        }
    }

    /// Stage an update (download but don't apply yet)
    pub async fn stage_update(&self) -> anyhow::Result<()> {
        self.enforce_tuf_policy()?;

        let output = Command::new("bootc").arg("upgrade").output()?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("Failed to stage update: {}", stderr);
        }

        Ok(())
    }

    /// Apply staged update (reboot required)
    pub async fn apply_update(&self) -> anyhow::Result<()> {
        self.enforce_tuf_policy()?;

        let output = Command::new("bootc")
            .args(["upgrade", "--apply"])
            .output()?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("Failed to apply update: {}", stderr);
        }

        Ok(())
    }

    /// Get update history
    pub async fn get_update_history(&self) -> anyhow::Result<Vec<UpdateHistoryEntry>> {
        // This would typically read from a log file or database
        // For now, return empty
        Ok(Vec::new())
    }

    fn enforce_tuf_policy(&self) -> anyhow::Result<()> {
        let result =
            crate::tuf::validate_tuf_metadata(&self.tuf_metadata_dir, &self.tuf_state_path);

        match result {
            Ok(versions) => {
                log::info!(
                    "TUF metadata validated (root={}, timestamp={}, snapshot={}, targets={})",
                    versions.root,
                    versions.timestamp,
                    versions.snapshot,
                    versions.targets
                );
                Ok(())
            }
            Err(err) if !self.require_tuf => {
                log::warn!(
                    "TUF metadata validation failed but enforcement is disabled: {}",
                    err
                );
                Ok(())
            }
            Err(err) => Err(err),
        }
    }
}

impl Default for UpdateChecker {
    fn default() -> Self {
        Self::new()
    }
}

/// Update history entry
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateHistoryEntry {
    pub timestamp: chrono::DateTime<chrono::Local>,
    pub from_version: String,
    pub to_version: String,
    pub status: UpdateStatus,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub enum UpdateStatus {
    Success,
    Failed,
    RolledBack,
}

fn parse_version_from_output(output: &str) -> Option<String> {
    // Look for version patterns in output
    for line in output.lines() {
        if line.contains("version") {
            // Extract version number
            let parts: Vec<&str> = line.split_whitespace().collect();
            for (i, part) in parts.iter().enumerate() {
                if *part == "version" && i + 1 < parts.len() {
                    return Some(parts[i + 1].to_string());
                }
            }
        }
    }
    None
}

fn parse_env_bool(name: &str, default: bool) -> bool {
    match std::env::var(name) {
        Ok(v) => matches!(v.to_lowercase().as_str(), "1" | "true" | "yes" | "on"),
        Err(_) => default,
    }
}
