//! SQLite Protection — WAL mode, integrity checks, hot backups and perms.
//!
//! Ensures all SQLite databases are crash-resilient, can be verified/restored,
//! and are never world-readable (0o600 on owner, including WAL/SHM sidecars).

use anyhow::{Context, Result};
use log::{info, warn};
use std::path::{Path, PathBuf};

/// Tighten filesystem permissions to 0o600 (owner read/write only).
///
/// Call this right after opening or creating any file that may contain
/// sensitive user data (SQLite DBs, agent state, tokens, etc.). It is
/// idempotent and also fixes up historical files created as 0o644.
/// Also walks the common SQLite sidecars (`-wal`, `-shm`, `.backup`) so
/// the whole on-disk footprint is 0o600.
///
/// Unix-only. On non-unix this is a no-op.
#[allow(clippy::needless_return)]
pub fn ensure_sensitive_perms(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let apply = |p: &Path| {
            if let Ok(md) = std::fs::metadata(p) {
                let mut perms = md.permissions();
                if perms.mode() & 0o777 != 0o600 {
                    perms.set_mode(0o600);
                    if let Err(e) = std::fs::set_permissions(p, perms) {
                        log::warn!("[sqlite] failed to chmod 0600 {}: {}", p.display(), e);
                    }
                }
            }
        };
        apply(path);
        // SQLite sidecars
        for suffix in ["-wal", "-shm", ".backup"] {
            let mut sidecar = path.as_os_str().to_os_string();
            sidecar.push(suffix);
            let sp = std::path::PathBuf::from(sidecar);
            if sp.exists() {
                apply(&sp);
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
}

/// Run integrity check on a SQLite database.
/// Returns Ok(true) if healthy, Ok(false) if corrupt.
pub fn check_integrity(db_path: &Path) -> Result<bool> {
    let conn = rusqlite::Connection::open(db_path)
        .with_context(|| format!("Cannot open {}", db_path.display()))?;

    let result: String = conn.query_row("PRAGMA quick_check", [], |row| row.get(0))?;

    if result == "ok" {
        Ok(true)
    } else {
        warn!(
            "[sqlite] Integrity check FAILED for {}: {}",
            db_path.display(),
            result
        );
        Ok(false)
    }
}

/// Create a hot backup of a SQLite database using the backup API.
/// The backup is created while the database is in use (no locking).
pub fn hot_backup(db_path: &Path) -> Result<PathBuf> {
    let backup_path = db_path.with_extension("db.backup");

    let src = rusqlite::Connection::open(db_path)?;
    let mut dst = rusqlite::Connection::open(&backup_path)?;

    let backup = rusqlite::backup::Backup::new(&src, &mut dst)?;
    backup.run_to_completion(100, std::time::Duration::from_millis(50), None)?;

    info!("[sqlite] Hot backup created: {}", backup_path.display());
    Ok(backup_path)
}

/// Restore a database from its backup file.
pub fn restore_from_backup(db_path: &Path) -> Result<()> {
    let backup_path = db_path.with_extension("db.backup");
    if !backup_path.exists() {
        anyhow::bail!("No backup found for {}", db_path.display());
    }

    std::fs::copy(&backup_path, db_path)?;
    info!("[sqlite] Restored {} from backup", db_path.display());
    Ok(())
}

/// Check all LifeOS databases and backup/restore as needed.
pub async fn check_all_databases(data_dir: &Path) -> Vec<(String, bool)> {
    let db_names = [
        "memory.db",
        "task_queue.db",
        "calendar.db",
        "scheduled_tasks.db",
        "reliability.db",
    ];
    let mut results = Vec::new();

    for name in &db_names {
        let path = data_dir.join(name);
        if !path.exists() {
            continue;
        }

        let p = path.clone();
        let healthy = tokio::task::spawn_blocking(move || check_integrity(&p).unwrap_or(false))
            .await
            .unwrap_or(false);

        if !healthy {
            warn!(
                "[sqlite] {} is corrupt — attempting restore from backup",
                name
            );
            let restore_path = path.clone();
            let _ = tokio::task::spawn_blocking(move || restore_from_backup(&restore_path)).await;
        }

        results.push((name.to_string(), healthy));
    }

    results
}

/// Create hot backups of all databases.
pub async fn backup_all_databases(data_dir: &Path) -> usize {
    let db_names = [
        "memory.db",
        "task_queue.db",
        "calendar.db",
        "scheduled_tasks.db",
        "reliability.db",
    ];
    let mut count = 0;

    for name in &db_names {
        let path = data_dir.join(name);
        if !path.exists() {
            continue;
        }

        let p = path.clone();
        if let Ok(Ok(_)) = tokio::task::spawn_blocking(move || hot_backup(&p)).await {
            count += 1;
        }
    }

    info!("[sqlite] Backed up {}/{} databases", count, db_names.len());
    count
}
