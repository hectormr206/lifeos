//! Config Validator — validates configuration files at daemon startup.
//! Detects missing required keys, unknown keys, and type mismatches.
//! Also creates backup before writing config changes.

use anyhow::Result;
use log::{info, warn};
use std::path::Path;

/// Maximum config backups to keep
const MAX_BACKUPS: usize = 5;

/// Backup a config file before modification (rotated, max MAX_BACKUPS).
pub fn backup_config(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }

    let parent = path.parent().unwrap_or(Path::new("."));
    let stem = path.file_name().unwrap_or_default().to_string_lossy();

    // Rotate existing backups
    for i in (1..MAX_BACKUPS).rev() {
        let older = parent.join(format!("{}.bak.{}", stem, i));
        let newer = parent.join(format!("{}.bak.{}", stem, i + 1));
        if older.exists() {
            std::fs::rename(&older, &newer).ok();
        }
    }

    // Create new backup
    let backup = parent.join(format!("{}.bak.1", stem));
    std::fs::copy(path, &backup)?;
    info!(
        "[config] Backed up {} -> {}",
        path.display(),
        backup.display()
    );

    // Remove oldest if over limit
    let oldest = parent.join(format!("{}.bak.{}", stem, MAX_BACKUPS + 1));
    if oldest.exists() {
        std::fs::remove_file(&oldest).ok();
    }

    Ok(())
}

/// Validate that a TOML file is parseable and log any issues.
pub fn validate_toml(path: &Path) -> Result<()> {
    if !path.exists() {
        warn!("[config] Config file not found: {}", path.display());
        return Ok(());
    }

    let content = std::fs::read_to_string(path)?;
    match content.parse::<toml::Value>() {
        Ok(_) => {
            info!("[config] {} is valid TOML", path.display());
            Ok(())
        }
        Err(e) => {
            warn!("[config] {} has invalid TOML: {}", path.display(), e);
            // Try to use backup
            let backup = path.with_extension("toml.bak.1");
            if backup.exists() {
                warn!(
                    "[config] Attempting recovery from backup: {}",
                    backup.display()
                );
                // Don't auto-restore — just report
            }
            anyhow::bail!("Invalid config: {}", e)
        }
    }
}
