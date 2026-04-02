//! Storage Housekeeping — enforce file limits and cleanup stale data.
//!
//! Runs every 6 hours as a background task. Ensures no directory accumulates
//! more than MAX_FILES files, and purges old data from SQLite databases.
//!
//! Philosophy: raw files (screenshots, recordings, game frames) are ephemeral.
//! Anything worth keeping should be in MemoryPlane (encrypted, searchable).
//! The raw files exist only for immediate processing, then get cleaned up.

use anyhow::Result;
use log::{info, warn};
use std::path::Path;
use tokio::fs;

/// Maximum files per directory. Files beyond this limit are deleted (oldest first).
const MAX_FILES_PER_DIR: usize = 120;

/// Maximum age for completed/failed tasks in task_queue (days).
const TASK_QUEUE_RETENTION_DAYS: u64 = 30;

/// Maximum age for reliability records (days).
const RELIABILITY_RETENTION_DAYS: u64 = 90;

/// Maximum age for meeting recordings (days).
const MEETING_RETENTION_DAYS: u64 = 30;

/// Maximum age for telemetry events (days). Used by telemetry.rs purge_old_events().
const _TELEMETRY_RETENTION_DAYS: u64 = 30;

/// Maximum age for ephemeral captures (camera, audio, tts) in days.
/// These are processed immediately; raw files only needed short-term.
const EPHEMERAL_RETENTION_DAYS: u64 = 7;

/// Maximum age for session transcript files on disk (days).
const SESSION_RETENTION_DAYS: u64 = 30;

/// Directories to enforce the file count limit on (relative to data_dir).
/// All directories here get capped at MAX_FILES_PER_DIR (oldest removed first).
const MANAGED_DIRS: &[&str] = &[
    "meetings",
    "browser_screenshots",
    "game_frames",
    "screenshots",
    "game-sessions",
    "camera",
    "audio",
    "tts",
];

/// Run all storage housekeeping tasks.
pub async fn run_housekeeping(data_dir: &Path) -> HousekeepingReport {
    let mut report = HousekeepingReport::default();

    // 1. Enforce file limits on all managed directories
    for dir_name in MANAGED_DIRS {
        let dir = data_dir.join(dir_name);
        if dir.exists() {
            match cleanup_dir_by_count(&dir, MAX_FILES_PER_DIR).await {
                Ok(removed) => {
                    if removed > 0 {
                        info!(
                            "[housekeeping] {}: removed {} files (limit {})",
                            dir_name, removed, MAX_FILES_PER_DIR
                        );
                    }
                    report.files_removed += removed;
                }
                Err(e) => warn!("[housekeeping] {}: cleanup error: {}", dir_name, e),
            }
        }
    }

    // 2. Purge old completed/failed tasks from task_queue.db
    let task_db = data_dir.join("task_queue.db");
    if task_db.exists() {
        match purge_old_tasks(&task_db, TASK_QUEUE_RETENTION_DAYS).await {
            Ok(purged) => {
                if purged > 0 {
                    info!("[housekeeping] task_queue: purged {} old entries", purged);
                }
                report.db_rows_purged += purged;
            }
            Err(e) => warn!("[housekeeping] task_queue purge error: {}", e),
        }
    }

    // 3. Purge old reliability records
    let reliability_db = data_dir.join("reliability.db");
    if reliability_db.exists() {
        match purge_old_reliability(&reliability_db, RELIABILITY_RETENTION_DAYS).await {
            Ok(purged) => {
                if purged > 0 {
                    info!("[housekeeping] reliability: purged {} old entries", purged);
                }
                report.db_rows_purged += purged;
            }
            Err(e) => warn!("[housekeeping] reliability purge error: {}", e),
        }
    }

    // 4. Purge old meeting files by age
    let meetings_dir = data_dir.join("meetings");
    if meetings_dir.exists() {
        match cleanup_dir_by_age(&meetings_dir, MEETING_RETENTION_DAYS).await {
            Ok(removed) => {
                if removed > 0 {
                    info!("[housekeeping] meetings: removed {} old files", removed);
                }
                report.files_removed += removed;
            }
            Err(e) => warn!("[housekeeping] meetings age cleanup error: {}", e),
        }
    }

    // 5. Purge ephemeral captures by age (camera, audio, tts — 7 days)
    for dir_name in ["camera", "audio", "tts"] {
        let dir = data_dir.join(dir_name);
        if dir.exists() {
            match cleanup_dir_by_age(&dir, EPHEMERAL_RETENTION_DAYS).await {
                Ok(removed) => {
                    if removed > 0 {
                        info!(
                            "[housekeeping] {}: removed {} files older than {} days",
                            dir_name, removed, EPHEMERAL_RETENTION_DAYS
                        );
                    }
                    report.files_removed += removed;
                }
                Err(e) => warn!("[housekeeping] {} age cleanup error: {}", dir_name, e),
            }
        }
    }

    // 6. Purge old session transcript directories by age
    let sessions_dir = data_dir.join("sessions");
    if sessions_dir.exists() {
        match cleanup_session_dirs(&sessions_dir, SESSION_RETENTION_DAYS).await {
            Ok(removed) => {
                if removed > 0 {
                    info!(
                        "[housekeeping] sessions: removed {} old session dirs",
                        removed
                    );
                }
                report.files_removed += removed;
            }
            Err(e) => warn!("[housekeeping] sessions cleanup error: {}", e),
        }
    }

    info!(
        "[housekeeping] complete: {} files removed, {} db rows purged",
        report.files_removed, report.db_rows_purged
    );

    report
}

/// Report from a housekeeping run.
#[derive(Debug, Default)]
pub struct HousekeepingReport {
    pub files_removed: usize,
    pub db_rows_purged: usize,
}

// ─────────────────────────────────────────────────────────
// File cleanup
// ─────────────────────────────────────────────────────────

/// Keep only the newest `max_files` files in a directory. Remove older ones.
async fn cleanup_dir_by_count(dir: &Path, max_files: usize) -> Result<usize> {
    let mut entries = Vec::new();
    let mut read_dir = fs::read_dir(dir).await?;

    while let Some(entry) = read_dir.next_entry().await? {
        let path = entry.path();
        if path.is_file() {
            if let Ok(meta) = fs::metadata(&path).await {
                if let Ok(modified) = meta.modified() {
                    entries.push((path, modified));
                }
            }
        }
    }

    if entries.len() <= max_files {
        return Ok(0);
    }

    // Sort by modification time, newest last
    entries.sort_by_key(|(_, m)| *m);

    let to_remove = entries.len() - max_files;
    let mut removed = 0;

    for (path, _) in entries.iter().take(to_remove) {
        if fs::remove_file(path).await.is_ok() {
            removed += 1;
        }
    }

    Ok(removed)
}

/// Remove files older than `max_days` from a directory.
async fn cleanup_dir_by_age(dir: &Path, max_days: u64) -> Result<usize> {
    let cutoff = std::time::SystemTime::now() - std::time::Duration::from_secs(max_days * 86400);
    let mut removed = 0;
    let mut read_dir = fs::read_dir(dir).await?;

    while let Some(entry) = read_dir.next_entry().await? {
        let path = entry.path();
        if path.is_file() {
            if let Ok(meta) = fs::metadata(&path).await {
                if let Ok(modified) = meta.modified() {
                    if modified < cutoff && fs::remove_file(&path).await.is_ok() {
                        removed += 1;
                    }
                }
            }
        }
    }

    Ok(removed)
}

/// Remove session directories whose most recent file is older than `max_days`.
async fn cleanup_session_dirs(sessions_dir: &Path, max_days: u64) -> Result<usize> {
    let cutoff = std::time::SystemTime::now() - std::time::Duration::from_secs(max_days * 86400);
    let mut removed = 0;
    let mut read_dir = fs::read_dir(sessions_dir).await?;

    while let Some(entry) = read_dir.next_entry().await? {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        // Check the newest file in this session directory
        let mut newest = None;
        if let Ok(mut sub_dir) = fs::read_dir(&path).await {
            while let Some(sub_entry) = sub_dir.next_entry().await.ok().flatten() {
                if let Ok(meta) = fs::metadata(sub_entry.path()).await {
                    if let Ok(modified) = meta.modified() {
                        newest = Some(match newest {
                            Some(prev) if modified > prev => modified,
                            Some(prev) => prev,
                            None => modified,
                        });
                    }
                }
            }
        }
        // If all files are older than cutoff, remove the directory
        if let Some(newest_time) = newest {
            if newest_time < cutoff && fs::remove_dir_all(&path).await.is_ok() {
                removed += 1;
            }
        }
    }

    Ok(removed)
}

// ─────────────────────────────────────────────────────────
// Database cleanup
// ─────────────────────────────────────────────────────────

/// Purge completed/failed tasks older than `days` from task_queue.db.
async fn purge_old_tasks(db_path: &Path, days: u64) -> Result<usize> {
    let path = db_path.to_path_buf();
    tokio::task::spawn_blocking(move || purge_old_tasks_sync(&path, days))
        .await
        .map_err(|e| anyhow::anyhow!("task panicked: {}", e))?
}

fn purge_old_tasks_sync(db_path: &Path, days: u64) -> Result<usize> {
    let conn = rusqlite::Connection::open(db_path)?;
    let cutoff = chrono::Utc::now() - chrono::Duration::days(days as i64);
    let cutoff_str = cutoff.to_rfc3339();

    let count = conn.execute(
        "DELETE FROM tasks WHERE status IN ('completed', 'failed', 'cancelled') AND updated_at < ?1",
        rusqlite::params![cutoff_str],
    )?;

    if count > 0 {
        conn.execute_batch("VACUUM")?;
    }

    Ok(count)
}

/// Purge reliability records older than `days` from reliability.db.
async fn purge_old_reliability(db_path: &Path, days: u64) -> Result<usize> {
    let path = db_path.to_path_buf();
    tokio::task::spawn_blocking(move || purge_old_reliability_sync(&path, days))
        .await
        .map_err(|e| anyhow::anyhow!("task panicked: {}", e))?
}

fn purge_old_reliability_sync(db_path: &Path, days: u64) -> Result<usize> {
    let conn = rusqlite::Connection::open(db_path)?;
    let cutoff = chrono::Utc::now() - chrono::Duration::days(days as i64);
    let cutoff_str = cutoff.to_rfc3339();

    let count = conn.execute(
        "DELETE FROM task_outcomes WHERE completed_at < ?1",
        rusqlite::params![cutoff_str],
    )?;

    if count > 0 {
        conn.execute_batch("VACUUM")?;
    }

    Ok(count)
}
