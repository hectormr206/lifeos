//! Update checking module
//! Handles checking for and staging system updates

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// Path of the cached update state written by the system-level
/// `lifeos-update-check.service` (runs as root via systemd timer).
/// The unprivileged user daemon reads this file instead of shelling out to
/// `bootc status`, which requires root.
pub const UPDATE_STATE_CACHE_PATH: &str = "/var/lib/lifeos/update-state.json";

/// Maximum age of the cached update state before it is considered stale. Past
/// this threshold the cache is ignored (treated as missing) so we do not keep
/// reporting "update available" indefinitely when the system timer is broken.
const CACHE_STALE_AFTER: Duration = Duration::from_secs(48 * 3600);

/// Tracks whether we have already logged a warning about a stale cache in this
/// process, so a tight polling loop does not spam the journal.
static STALE_CACHE_WARNED: AtomicBool = AtomicBool::new(false);
/// Same idea for unreadable / unparseable cache files.
static CACHE_READ_ERROR_WARNED: AtomicBool = AtomicBool::new(false);

/// Cached update state as written by `lifeos-update-check.sh`.
#[derive(Debug, Clone, Deserialize)]
struct CachedUpdateState {
    available: bool,
    #[serde(default)]
    current_version: Option<String>,
    #[serde(default)]
    new_version: Option<String>,
    #[serde(default)]
    checked_at: Option<String>,
}

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

    /// Read update availability from the cached state file written by the
    /// system-level `lifeos-update-check.service`. This avoids calling `bootc`
    /// directly, which requires root privileges.
    ///
    /// Returns `Ok(None)` if the cache file does not yet exist (the system
    /// timer may not have fired since boot). Returns `Err` if the file exists
    /// but cannot be parsed.
    pub fn check_from_cached_state(&mut self) -> anyhow::Result<Option<UpdateResult>> {
        self.check_from_cached_state_at(Path::new(UPDATE_STATE_CACHE_PATH))
    }

    /// Like `check_from_cached_state`, but reads from an explicit path.
    /// Separated for unit testing.
    pub fn check_from_cached_state_at(
        &mut self,
        path: &Path,
    ) -> anyhow::Result<Option<UpdateResult>> {
        if !path.exists() {
            return Ok(None);
        }
        let raw = std::fs::read_to_string(path)
            .map_err(|e| anyhow::anyhow!("Failed to read {}: {}", path.display(), e))?;
        let cached: CachedUpdateState = serde_json::from_str(&raw)
            .map_err(|e| anyhow::anyhow!("Failed to parse {}: {}", path.display(), e))?;

        let current_version = cached
            .current_version
            .clone()
            .unwrap_or_else(|| "unknown".to_string());
        let new_version = cached
            .new_version
            .clone()
            .unwrap_or_else(|| current_version.clone());

        // Reject stale caches: if the system timer has not refreshed the file
        // within `CACHE_STALE_AFTER`, treat it as missing. This prevents a
        // broken timer from pinning a false "update available" indefinitely.
        if let Some(ts) = cached.checked_at.as_deref() {
            if let Ok(checked_at) = chrono::DateTime::parse_from_rfc3339(ts) {
                let age = chrono::Utc::now()
                    .signed_duration_since(checked_at.with_timezone(&chrono::Utc));
                if let Ok(age) = age.to_std() {
                    if age > CACHE_STALE_AFTER && !STALE_CACHE_WARNED.swap(true, Ordering::Relaxed)
                    {
                        log::warn!(
                            "Update state cache at {} is stale (checked_at={}, age={}s); \
                             lifeos-update-check.service may be failing. Ignoring cache.",
                            path.display(),
                            ts,
                            age.as_secs()
                        );
                        return Ok(None);
                    }
                    if age > CACHE_STALE_AFTER {
                        return Ok(None);
                    }
                }
            }
        }

        Ok(Some(UpdateResult {
            available: cached.available,
            current_version,
            new_version,
            changelog: None,
            size_mb: None,
        }))
    }

    /// Best-effort update check that reads the cached state file written by
    /// the privileged system timer. When the cache is missing, stale, or
    /// unreadable, returns a conservative "unknown / unavailable" result
    /// instead of shelling out to `bootc`, which would require privileges the
    /// unprivileged user daemon does not have.
    pub async fn check_for_updates_cached_first(&mut self) -> anyhow::Result<UpdateResult> {
        match self.check_from_cached_state() {
            Ok(Some(result)) => Ok(result),
            Ok(None) => Ok(unknown_update_result()),
            Err(e) => {
                if !CACHE_READ_ERROR_WARNED.swap(true, Ordering::Relaxed) {
                    log::warn!("Failed to read cached update state: {e}");
                }
                Ok(unknown_update_result())
            }
        }
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

fn unknown_update_result() -> UpdateResult {
    UpdateResult {
        available: false,
        current_version: "unknown".to_string(),
        new_version: "unknown".to_string(),
        changelog: None,
        size_mb: None,
    }
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
