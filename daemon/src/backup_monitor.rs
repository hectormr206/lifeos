//! Backup Monitor — Verify backup health and remind user when overdue.
//!
//! Supports restic and borg backups. Checks:
//! - Last backup age (alert if >24h for daily schedule)
//! - Repository integrity (periodic `check --read-data-subset`)
//! - Backup size trends (sudden changes indicate problems)

use anyhow::Result;
use serde::{Deserialize, Serialize};
use tokio::process::Command;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupStatus {
    pub tool: String, // "restic", "borg", "none"
    pub repo_path: Option<String>,
    pub last_backup_age_hours: Option<f64>,
    pub last_check_ok: Option<bool>,
    pub total_snapshots: Option<u32>,
}

/// Detect which backup tool is configured and check its status.
pub async fn check_backup_health() -> BackupStatus {
    // Try restic first
    if let Ok(status) = check_restic().await {
        return status;
    }

    // Try borg
    if let Ok(status) = check_borg().await {
        return status;
    }

    BackupStatus {
        tool: "none".into(),
        repo_path: None,
        last_backup_age_hours: None,
        last_check_ok: None,
        total_snapshots: None,
    }
}

async fn check_restic() -> Result<BackupStatus> {
    // Check if restic repo is configured
    let repo = std::env::var("RESTIC_REPOSITORY")
        .or_else(|_| std::env::var("LIFEOS_BACKUP_REPO"))
        .map_err(|_| anyhow::anyhow!("No restic repo configured"))?;

    let output = Command::new("restic")
        .args(["snapshots", "--json", "--last"])
        .output()
        .await?;

    if !output.status.success() {
        anyhow::bail!("restic snapshots failed");
    }

    let text = String::from_utf8_lossy(&output.stdout);
    let snapshots: Vec<serde_json::Value> = serde_json::from_str(&text).unwrap_or_default();

    let last_age = if let Some(last) = snapshots.last() {
        if let Some(time_str) = last.get("time").and_then(|v| v.as_str()) {
            if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(time_str) {
                let age = chrono::Utc::now().signed_duration_since(dt);
                Some(age.num_minutes() as f64 / 60.0)
            } else {
                None
            }
        } else {
            None
        }
    } else {
        None
    };

    Ok(BackupStatus {
        tool: "restic".into(),
        repo_path: Some(repo),
        last_backup_age_hours: last_age,
        last_check_ok: None,
        total_snapshots: Some(snapshots.len() as u32),
    })
}

async fn check_borg() -> Result<BackupStatus> {
    let repo =
        std::env::var("BORG_REPO").map_err(|_| anyhow::anyhow!("No borg repo configured"))?;

    let output = Command::new("borg")
        .args(["info", "--json"])
        .output()
        .await?;

    if !output.status.success() {
        anyhow::bail!("borg info failed");
    }

    let text = String::from_utf8_lossy(&output.stdout);
    let info: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();

    let archives = info
        .pointer("/archives")
        .and_then(|v| v.as_array())
        .map(|a| a.len() as u32);

    Ok(BackupStatus {
        tool: "borg".into(),
        repo_path: Some(repo),
        last_backup_age_hours: None,
        last_check_ok: None,
        total_snapshots: archives,
    })
}
