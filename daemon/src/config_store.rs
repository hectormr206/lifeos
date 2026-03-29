//! Config Store — versioned configuration with checkpoint/rollback.
//!
//! Instead of a full git repo, uses numbered checkpoint directories:
//! /var/lib/lifeos/config-checkpoints/
//!   checkpoint-001/    <- oldest
//!   checkpoint-002/
//!   checkpoint-003/    <- current known-good
//!   working/           <- live config (what daemon reads)
//!
//! Before any self-modification: checkpoint() copies working/ to a new checkpoint.
//! After modification: validate(). If invalid: rollback() restores from last checkpoint.
//! After 10min stable: tag as known-good.

use anyhow::{Context, Result};
use chrono::Utc;
use log::{info, warn};
use std::path::{Path, PathBuf};

const MAX_CHECKPOINTS: usize = 20;
const KNOWN_GOOD_MARKER: &str = ".known-good";

pub struct ConfigStore {
    base_dir: PathBuf,    // /var/lib/lifeos/config-checkpoints/
    working_dir: PathBuf, // /var/lib/lifeos/config-checkpoints/working/
}

impl ConfigStore {
    pub fn new(data_dir: &Path) -> Self {
        let base_dir = data_dir.join("config-checkpoints");
        let working_dir = base_dir.join("working");
        Self {
            base_dir,
            working_dir,
        }
    }

    /// Initialize the store. Creates directories if needed.
    pub async fn init(&self) -> Result<()> {
        tokio::fs::create_dir_all(&self.working_dir)
            .await
            .context("creating working dir")?;
        tokio::fs::create_dir_all(&self.base_dir)
            .await
            .context("creating base dir")?;
        Ok(())
    }

    /// Return the path to the working config directory.
    pub fn working_dir(&self) -> &Path {
        &self.working_dir
    }

    /// Create a checkpoint of the current working config.
    /// Returns the checkpoint number.
    pub async fn checkpoint(&self, message: &str) -> Result<u32> {
        let num = self.next_checkpoint_number().await;
        let checkpoint_dir = self.base_dir.join(format!("checkpoint-{:04}", num));

        // Copy working/ to checkpoint-NNNN/
        copy_dir_recursive(&self.working_dir, &checkpoint_dir)
            .await
            .context("copying working dir to checkpoint")?;

        // Write metadata
        let meta = format!("{}\n{}\n", Utc::now().to_rfc3339(), message);
        tokio::fs::write(checkpoint_dir.join(".metadata"), meta)
            .await
            .context("writing checkpoint metadata")?;

        // Prune old checkpoints
        self.prune_old_checkpoints().await;

        info!("[config_store] Checkpoint {} created: {}", num, message);
        Ok(num)
    }

    /// Rollback working config to the last checkpoint.
    pub async fn rollback(&self) -> Result<()> {
        let latest = self.latest_checkpoint().await;
        if let Some(checkpoint_dir) = latest {
            // Clear working/
            let _ = tokio::fs::remove_dir_all(&self.working_dir).await;
            // Copy checkpoint to working/
            copy_dir_recursive(&checkpoint_dir, &self.working_dir)
                .await
                .context("restoring from checkpoint")?;
            info!("[config_store] Rolled back to {:?}", checkpoint_dir);
            Ok(())
        } else {
            anyhow::bail!("No checkpoints available for rollback")
        }
    }

    /// Rollback to the last known-good checkpoint.
    pub async fn rollback_to_last_good(&self) -> Result<()> {
        let mut entries = self.list_checkpoints().await;
        entries.reverse(); // Most recent first

        for entry in entries {
            if entry.join(KNOWN_GOOD_MARKER).exists() {
                let _ = tokio::fs::remove_dir_all(&self.working_dir).await;
                copy_dir_recursive(&entry, &self.working_dir)
                    .await
                    .context("restoring from known-good checkpoint")?;
                info!("[config_store] Rolled back to known-good: {:?}", entry);
                return Ok(());
            }
        }
        anyhow::bail!("No known-good checkpoint found")
    }

    /// Tag the current state as known-good.
    pub async fn tag_known_good(&self) -> Result<()> {
        if let Some(latest) = self.latest_checkpoint().await {
            tokio::fs::write(latest.join(KNOWN_GOOD_MARKER), "")
                .await
                .context("writing known-good marker")?;
            info!("[config_store] Tagged latest checkpoint as known-good");
        }
        Ok(())
    }

    /// Restore factory defaults (last resort).
    pub async fn restore_factory_defaults(&self) -> Result<()> {
        let factory_config = include_str!("../defaults/config.toml");
        let _ = tokio::fs::remove_dir_all(&self.working_dir).await;
        tokio::fs::create_dir_all(&self.working_dir)
            .await
            .context("creating working dir for factory reset")?;
        tokio::fs::write(self.working_dir.join("config.toml"), factory_config)
            .await
            .context("writing factory config")?;
        warn!("[config_store] FACTORY DEFAULTS RESTORED — all customizations lost");
        Ok(())
    }

    /// List all checkpoint numbers and their metadata (for API/dashboard).
    pub async fn list_checkpoint_info(&self) -> Vec<CheckpointInfo> {
        let mut result = Vec::new();
        for path in self.list_checkpoints().await {
            let name = path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string();
            let known_good = path.join(KNOWN_GOOD_MARKER).exists();
            let message = if let Ok(meta) = tokio::fs::read_to_string(path.join(".metadata")).await
            {
                meta.lines().nth(1).unwrap_or("").to_string()
            } else {
                String::new()
            };
            let timestamp =
                if let Ok(meta) = tokio::fs::read_to_string(path.join(".metadata")).await {
                    meta.lines().next().unwrap_or("").to_string()
                } else {
                    String::new()
                };
            result.push(CheckpointInfo {
                name,
                timestamp,
                message,
                known_good,
            });
        }
        result
    }

    async fn next_checkpoint_number(&self) -> u32 {
        let checkpoints = self.list_checkpoints().await;
        checkpoints.len() as u32 + 1
    }

    async fn latest_checkpoint(&self) -> Option<PathBuf> {
        let mut checkpoints = self.list_checkpoints().await;
        checkpoints.pop()
    }

    async fn list_checkpoints(&self) -> Vec<PathBuf> {
        let mut entries = Vec::new();
        if let Ok(mut dir) = tokio::fs::read_dir(&self.base_dir).await {
            while let Ok(Some(entry)) = dir.next_entry().await {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.starts_with("checkpoint-") {
                    entries.push(entry.path());
                }
            }
        }
        entries.sort();
        entries
    }

    async fn prune_old_checkpoints(&self) {
        let mut checkpoints = self.list_checkpoints().await;
        while checkpoints.len() > MAX_CHECKPOINTS {
            if let Some(oldest) = checkpoints.first() {
                // Don't prune known-good checkpoints
                if !oldest.join(KNOWN_GOOD_MARKER).exists() {
                    let _ = tokio::fs::remove_dir_all(oldest).await;
                    checkpoints.remove(0);
                } else {
                    break;
                }
            }
        }
    }
}

/// Metadata about a checkpoint (for API responses).
#[derive(Debug, Clone, serde::Serialize)]
pub struct CheckpointInfo {
    pub name: String,
    pub timestamp: String,
    pub message: String,
    pub known_good: bool,
}

/// Recursively copy a directory.
async fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<()> {
    tokio::fs::create_dir_all(dst)
        .await
        .with_context(|| format!("creating {:?}", dst))?;
    let mut dir = tokio::fs::read_dir(src)
        .await
        .with_context(|| format!("reading {:?}", src))?;
    while let Some(entry) = dir.next_entry().await? {
        let src_path = entry.path();
        let dst_path = dst.join(entry.file_name());
        if src_path.is_dir() {
            Box::pin(copy_dir_recursive(&src_path, &dst_path)).await?;
        } else {
            tokio::fs::copy(&src_path, &dst_path)
                .await
                .with_context(|| format!("copying {:?} -> {:?}", src_path, dst_path))?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_checkpoint_and_rollback() {
        let tmp = std::env::temp_dir().join(format!("lifeos-config-test-{}", std::process::id()));
        let store = ConfigStore::new(&tmp);
        store.init().await.unwrap();

        // Write a file to working/
        tokio::fs::write(store.working_dir().join("test.toml"), "version = 1")
            .await
            .unwrap();

        // Checkpoint
        let num = store.checkpoint("initial").await.unwrap();
        assert_eq!(num, 1);

        // Modify working
        tokio::fs::write(store.working_dir().join("test.toml"), "version = 2")
            .await
            .unwrap();

        // Rollback
        store.rollback().await.unwrap();
        let content = tokio::fs::read_to_string(store.working_dir().join("test.toml"))
            .await
            .unwrap();
        assert_eq!(content, "version = 1");

        // Cleanup
        let _ = tokio::fs::remove_dir_all(&tmp).await;
    }

    #[tokio::test]
    async fn test_known_good_rollback() {
        let tmp = std::env::temp_dir().join(format!(
            "lifeos-config-known-good-test-{}",
            std::process::id()
        ));
        let store = ConfigStore::new(&tmp);
        store.init().await.unwrap();

        // Write v1, checkpoint, tag as known-good
        tokio::fs::write(store.working_dir().join("test.toml"), "version = 1")
            .await
            .unwrap();
        store.checkpoint("v1 known-good").await.unwrap();
        store.tag_known_good().await.unwrap();

        // Write v2, checkpoint (not known-good)
        tokio::fs::write(store.working_dir().join("test.toml"), "version = 2")
            .await
            .unwrap();
        store.checkpoint("v2 experimental").await.unwrap();

        // Write v3 (broken)
        tokio::fs::write(store.working_dir().join("test.toml"), "BROKEN")
            .await
            .unwrap();

        // Rollback to known-good should get v1
        store.rollback_to_last_good().await.unwrap();
        let content = tokio::fs::read_to_string(store.working_dir().join("test.toml"))
            .await
            .unwrap();
        assert_eq!(content, "version = 1");

        // Cleanup
        let _ = tokio::fs::remove_dir_all(&tmp).await;
    }

    #[tokio::test]
    async fn test_factory_defaults() {
        let tmp =
            std::env::temp_dir().join(format!("lifeos-config-factory-test-{}", std::process::id()));
        let store = ConfigStore::new(&tmp);
        store.init().await.unwrap();

        // Write custom config
        tokio::fs::write(store.working_dir().join("config.toml"), "custom = true")
            .await
            .unwrap();

        // Restore factory defaults
        store.restore_factory_defaults().await.unwrap();

        let content = tokio::fs::read_to_string(store.working_dir().join("config.toml"))
            .await
            .unwrap();
        assert!(content.contains("[ai]"));
        assert!(content.contains("Qwen3.5-4B"));

        // Cleanup
        let _ = tokio::fs::remove_dir_all(&tmp).await;
    }
}
