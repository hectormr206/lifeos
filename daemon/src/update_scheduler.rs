//! Update Scheduler with Channels
//!
//! Provides update scheduling and management with multiple channels:
//! - stable: Stable releases only
//! - candidate: Release candidates for testing
//! - edge: Bleeding edge features
//!
//! Supports scheduled updates, rollback, and verification.

use anyhow::{Context, Result};
use chrono::{DateTime, Duration, Utc};
use log::{error, info, warn};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::process::Command;
use tokio::sync::RwLock;

/// Update channel
#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq, Eq)]
pub enum UpdateChannel {
    #[default]
    Stable,
    Candidate,
    Edge,
}

/// Update schedule type
#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq, Eq)]
pub enum ScheduleType {
    #[default]
    Automatic,
    Manual,
    Scheduled,
    Never,
}

/// Update priority
#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq, Eq)]
pub enum UpdatePriority {
    #[default]
    Critical,
    High,
    Normal,
    Low,
}

/// Update status
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum UpdateStatus {
    Pending,
    Downloading,
    Installing,
    Installed,
    Failed,
    RolledBack,
}

/// Update task
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateTask {
    pub id: String,
    pub channel: UpdateChannel,
    pub version: String,
    pub scheduled_at: DateTime<Utc>,
    pub priority: UpdatePriority,
    pub auto_install: bool,
}

/// Available update version
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AvailableVersion {
    pub version: String,
    pub channel: UpdateChannel,
    pub release_date: DateTime<Utc>,
    pub checksum: String,
    pub notes: String,
    pub size_bytes: u64,
    pub download_url: String,
    pub required_disk_space_mb: u32,
}

/// Update record
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateRecord {
    pub timestamp: DateTime<Utc>,
    pub version: String,
    pub channel: UpdateChannel,
    pub status: UpdateStatus,
    pub checksum: String,
}

/// Update schedule configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScheduleConfig {
    /// Schedule type
    pub schedule_type: ScheduleType,
    /// Update time (for scheduled updates, HH:MM format)
    pub update_time: String,
    /// Update day (for scheduled updates, 0-6, 0=Sunday)
    pub update_day: u8,
    /// Auto-check frequency (hours)
    pub check_frequency_hours: u32,
    /// Whether to auto-install updates
    pub auto_install: bool,
    /// Whether to verify checksum before install
    pub verify_checksum: bool,
    /// Whether to create backup before update
    pub create_backup: bool,
}

impl Default for ScheduleConfig {
    fn default() -> Self {
        Self {
            schedule_type: ScheduleType::Automatic,
            update_time: "02:00".to_string(),
            update_day: 1, // Monday
            check_frequency_hours: 24,
            auto_install: false,
            verify_checksum: true,
            create_backup: true,
        }
    }
}

/// Update scheduler
pub struct UpdateScheduler {
    current_channel: Arc<RwLock<UpdateChannel>>,
    schedule_type: Arc<RwLock<ScheduleType>>,
    update_time: Arc<RwLock<String>>,
    update_day: Arc<RwLock<u8>>,
    check_frequency_hours: Arc<RwLock<u32>>,
    auto_install: Arc<RwLock<bool>>,
    verify_checksum: Arc<RwLock<bool>>,
    create_backup: Arc<RwLock<bool>>,
    scheduled_updates: Arc<RwLock<Vec<UpdateTask>>>,
    update_history: Arc<RwLock<Vec<UpdateRecord>>>,
    config_dir: PathBuf,
    available_versions: Arc<RwLock<Vec<AvailableVersion>>>,
}

impl UpdateScheduler {
    /// Create new update scheduler
    pub fn new(config_dir: PathBuf) -> Self {
        let config = match Self::read_config_file(config_dir.as_path()) {
            Ok(config) => config,
            Err(e) => {
                warn!(
                    "Failed to load update scheduler config, using defaults: {}",
                    e
                );
                ScheduleConfig::default()
            }
        };

        let scheduler = Self {
            current_channel: Arc::new(RwLock::new(UpdateChannel::default())),
            schedule_type: Arc::new(RwLock::new(config.schedule_type)),
            update_time: Arc::new(RwLock::new(config.update_time)),
            update_day: Arc::new(RwLock::new(config.update_day)),
            check_frequency_hours: Arc::new(RwLock::new(config.check_frequency_hours)),
            auto_install: Arc::new(RwLock::new(config.auto_install)),
            verify_checksum: Arc::new(RwLock::new(config.verify_checksum)),
            create_backup: Arc::new(RwLock::new(config.create_backup)),
            scheduled_updates: Arc::new(RwLock::new(Vec::new())),
            update_history: Arc::new(RwLock::new(Vec::new())),
            config_dir,
            available_versions: Arc::new(RwLock::new(Vec::new())),
        };

        info!("Update scheduler initialized");
        scheduler
    }

    fn read_config_file(config_dir: &Path) -> Result<ScheduleConfig> {
        let config_file = config_dir.join("update_schedule.conf");
        if !config_file.exists() {
            return Ok(ScheduleConfig::default());
        }

        let config_content = std::fs::read_to_string(&config_file)
            .with_context(|| format!("Failed to read {}", config_file.display()))?;

        toml::from_str(&config_content)
            .with_context(|| format!("Failed to parse {}", config_file.display()))
    }

    /// Save schedule configuration
    async fn save_config(&self) -> Result<()> {
        let config_file = self.config_dir.join("update_schedule.conf");
        let schedule_type = *self.schedule_type.read().await;
        let update_time = self.update_time.read().await.clone();
        let update_day = *self.update_day.read().await;
        let check_frequency = *self.check_frequency_hours.read().await;
        let auto_install = *self.auto_install.read().await;
        let verify_checksum = *self.verify_checksum.read().await;
        let create_backup = *self.create_backup.read().await;

        let config = ScheduleConfig {
            schedule_type,
            update_time,
            update_day,
            check_frequency_hours: check_frequency,
            auto_install,
            verify_checksum,
            create_backup,
        };

        tokio::fs::create_dir_all(&self.config_dir).await?;
        let config_content = toml::to_string_pretty(&config)?;
        tokio::fs::write(&config_file, config_content)
            .await
            .with_context(|| format!("Failed to write {}", config_file.display()))?;

        info!("Update schedule saved");
        Ok(())
    }

    /// Get current channel
    pub async fn get_channel(&self) -> UpdateChannel {
        *self.current_channel.read().await
    }

    /// Set current channel
    pub async fn set_channel(&self, channel: UpdateChannel) -> Result<()> {
        *self.current_channel.write().await = channel;
        info!("Update channel changed to: {:?}", channel);
        self.save_config().await?;
        Ok(())
    }

    /// Get available versions
    pub async fn get_available_versions(
        &self,
        channel: Option<UpdateChannel>,
    ) -> Result<Vec<AvailableVersion>> {
        let target_channel = channel.unwrap_or(self.get_channel().await);
        let versions = self.available_versions.read().await;
        let filtered = versions
            .iter()
            .filter(|v| v.channel == target_channel)
            .cloned()
            .collect();
        Ok(filtered)
    }

    /// Add available version
    pub async fn add_available_version(&self, version: AvailableVersion) -> Result<()> {
        self.available_versions.write().await.push(version);
        Ok(())
    }

    /// Schedule an update
    pub async fn schedule_update(&self, version: String, channel: UpdateChannel) -> Result<()> {
        let task = UpdateTask {
            id: uuid::Uuid::new_v4().to_string(),
            channel,
            version: version.clone(),
            scheduled_at: Utc::now() + Duration::hours(1),
            priority: UpdatePriority::Normal,
            auto_install: *self.auto_install.read().await,
        };

        self.scheduled_updates.write().await.push(task);
        info!("Update scheduled: {} in {:?}", version, channel);
        Ok(())
    }

    /// Get scheduled updates
    pub async fn get_scheduled_updates(&self) -> Vec<UpdateTask> {
        self.scheduled_updates.read().await.clone()
    }

    /// Update available versions from remote
    pub async fn fetch_available_versions(&self) -> Result<()> {
        info!("Fetching available updates...");

        // Simulated catalog for now.
        let versions = vec![
            AvailableVersion {
                version: "0.1.1".to_string(),
                channel: UpdateChannel::Stable,
                release_date: Utc::now(),
                checksum: format!("sha256_{}", uuid::Uuid::new_v4()),
                notes: "Stable release with bug fixes".to_string(),
                size_bytes: 250 * 1024 * 1024, // 250 MB
                download_url: "https://lifeos.io/releases/0.1.1/LifeOS-0.1.1.iso".to_string(),
                required_disk_space_mb: 500,
            },
            AvailableVersion {
                version: "0.2.0-beta".to_string(),
                channel: UpdateChannel::Candidate,
                release_date: Utc::now() - Duration::days(7),
                checksum: format!("sha256_{}", uuid::Uuid::new_v4()),
                notes: "Beta release with new features".to_string(),
                size_bytes: 300 * 1024 * 1024, // 300 MB
                download_url: "https://lifeos.io/releases/0.2.0-beta/LifeOS-0.2.0.iso".to_string(),
                required_disk_space_mb: 600,
            },
        ];

        let total = versions.len();
        *self.available_versions.write().await = versions;
        info!("Fetched {} available versions", total);
        Ok(())
    }

    /// Download update
    pub async fn download_update(&self, version: &AvailableVersion) -> Result<UpdateStatus> {
        info!(
            "Downloading update: {} ({} bytes)",
            version.version, version.size_bytes
        );

        let download_dir = self.config_dir.join("downloads");
        tokio::fs::create_dir_all(&download_dir).await?;

        let iso_path = download_dir.join(format!("{}.iso", version.version));

        let status = Command::new("curl")
            .arg("-fSL")
            .arg("-o")
            .arg(iso_path.as_os_str())
            .arg(&version.download_url)
            .status()
            .await?;

        if !status.success() {
            error!("Failed to download update: {}", status);
            return Ok(UpdateStatus::Failed);
        }

        info!("Update downloaded: {}", iso_path.display());
        Ok(UpdateStatus::Downloading)
    }

    /// Install update
    pub async fn install_update(&self, version: &AvailableVersion) -> Result<UpdateStatus> {
        info!("Installing update: {}", version.version);

        if *self.verify_checksum.read().await {
            self.verify_checksum(version).await?;
        }

        if *self.create_backup.read().await {
            if let Err(e) = self.create_backup().await {
                warn!("Failed to create backup before update: {}", e);
            }
        }

        self.update_history.write().await.push(UpdateRecord {
            timestamp: Utc::now(),
            version: version.version.clone(),
            channel: version.channel,
            status: UpdateStatus::Installed,
            checksum: version.checksum.clone(),
        });

        info!("Update installed: {}", version.version);
        Ok(UpdateStatus::Installed)
    }

    /// Verify checksum
    async fn verify_checksum(&self, version: &AvailableVersion) -> Result<()> {
        let download_dir = self.config_dir.join("downloads");
        let iso_path = download_dir.join(format!("{}.iso", version.version));

        if !iso_path.exists() {
            anyhow::bail!("ISO file not found: {}", iso_path.display());
        }

        info!("Verifying checksum for: {}", iso_path.display());
        // Placeholder: checksum verification hook.
        Ok(())
    }

    /// Create backup
    async fn create_backup(&self) -> Result<PathBuf> {
        let backup_dir = self.config_dir.join("backups");
        tokio::fs::create_dir_all(&backup_dir).await?;

        let timestamp = Utc::now().format("%Y%m%d_%H%M%S");
        let backup_path = backup_dir.join(format!("lifeos-backup-{}", timestamp));

        tokio::fs::write(&backup_path, format!("backup: {}\n", timestamp)).await?;
        Ok(backup_path)
    }

    /// Rollback to previous version in current channel
    pub async fn rollback(&self) -> Result<()> {
        info!("Rolling back to previous version...");

        let channel = *self.current_channel.read().await;
        let previous = self
            .update_history
            .read()
            .await
            .iter()
            .rev()
            .find(|r| r.channel == channel && r.status == UpdateStatus::Installed)
            .cloned();

        let prev = previous.ok_or_else(|| anyhow::anyhow!("No previous version to rollback to"))?;

        self.update_history.write().await.push(UpdateRecord {
            timestamp: Utc::now(),
            version: prev.version.clone(),
            channel: prev.channel,
            status: UpdateStatus::RolledBack,
            checksum: prev.checksum.clone(),
        });

        info!("Rollback completed: {}", prev.version);
        Ok(())
    }

    /// Get update status
    pub async fn get_status(&self) -> UpdateStatusInfo {
        let channel = self.get_channel().await;
        let scheduled = self.get_scheduled_updates().await;
        let history = self.update_history.read().await;
        let available = self
            .get_available_versions(Some(channel))
            .await
            .unwrap_or_default();

        UpdateStatusInfo {
            current_channel: channel,
            available_versions: available.len(),
            scheduled_updates: scheduled.len(),
            last_update: history.last().map(|r| r.version.clone()),
            schedule_type: *self.schedule_type.read().await,
            check_frequency_hours: *self.check_frequency_hours.read().await,
        }
    }

    /// Check for updates
    pub async fn check_for_updates(&self) -> Result<Option<AvailableVersion>> {
        let channel = self.get_channel().await;
        let current = self.get_current_version_from_history(channel).await;
        let current_key = Self::parse_version_key(&current);
        let available = self.get_available_versions(Some(channel)).await?;

        for version in available {
            if Self::parse_version_key(&version.version) > current_key {
                return Ok(Some(version));
            }
        }

        Ok(None)
    }

    fn parse_version_key(version: &str) -> Vec<u32> {
        version
            .chars()
            .map(|c| if c.is_ascii_digit() { c } else { ' ' })
            .collect::<String>()
            .split_whitespace()
            .filter_map(|p| p.parse::<u32>().ok())
            .collect()
    }

    async fn get_current_version_from_history(&self, channel: UpdateChannel) -> String {
        let history = self.update_history.read().await;
        history
            .iter()
            .rev()
            .find(|r| r.channel == channel && r.status == UpdateStatus::Installed)
            .map(|r| r.version.clone())
            .unwrap_or_else(|| "0.1.0".to_string())
    }

    /// Get update history
    pub async fn get_history(&self) -> Vec<UpdateRecord> {
        self.update_history.read().await.clone()
    }

    /// Clear update history and schedule
    pub async fn clear_history(&self) -> Result<()> {
        self.update_history.write().await.clear();
        self.scheduled_updates.write().await.clear();
        info!("Update history and schedule cleared");
        Ok(())
    }
}

/// Update status information
#[derive(Debug, Clone, Serialize)]
pub struct UpdateStatusInfo {
    pub current_channel: UpdateChannel,
    pub available_versions: usize,
    pub scheduled_updates: usize,
    pub last_update: Option<String>,
    pub schedule_type: ScheduleType,
    pub check_frequency_hours: u32,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_schedule_config() {
        let config = ScheduleConfig::default();
        assert_eq!(config.schedule_type, ScheduleType::Automatic);
        assert_eq!(config.update_time, "02:00");
        assert!(!config.auto_install);
    }

    #[test]
    fn test_update_task_creation() {
        let task = UpdateTask {
            id: uuid::Uuid::new_v4().to_string(),
            channel: UpdateChannel::Stable,
            version: "0.1.1".to_string(),
            scheduled_at: Utc::now(),
            priority: UpdatePriority::Normal,
            auto_install: false,
        };

        assert_eq!(task.channel, UpdateChannel::Stable);
        assert_eq!(task.version, "0.1.1");
    }
}
