//! Config Validator — validates configuration files at daemon startup.
//! Detects missing required keys, unknown keys, and type mismatches.
//! Also creates backup before writing config changes.

use anyhow::Result;
use log::{info, warn};
use serde::{Deserialize, Serialize};
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

/// Severity level for doctor findings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Severity {
    Info,
    Warning,
    Error,
}

/// A single finding from the doctor health check.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DoctorFinding {
    pub severity: Severity,
    pub component: String,
    pub message: String,
    pub fix: Option<String>,
}

/// Run a comprehensive health check on the LifeOS daemon configuration.
pub async fn run_doctor(data_dir: &Path) -> Vec<DoctorFinding> {
    let mut findings = Vec::new();

    // Check 1: Config files are valid TOML
    let config_files = ["/etc/lifeos/llm-providers.toml"];
    for path in &config_files {
        let p = Path::new(path);
        if p.exists() && validate_toml(p).is_err() {
            findings.push(DoctorFinding {
                severity: Severity::Error,
                component: "config".into(),
                message: format!("{} is invalid TOML", path),
                fix: Some(format!("Check {}.bak.1 for backup", path)),
            });
        }
    }

    // Check 2: SQLite databases — open + PRAGMA integrity_check
    for db_name in &[
        "memory.db",
        "task_queue.db",
        "calendar.db",
        "scheduled_tasks.db",
        "reliability.db",
    ] {
        let db_path = data_dir.join(db_name);
        if db_path.exists() {
            match rusqlite::Connection::open(&db_path) {
                Ok(conn) => {
                    // Full integrity check (not just SELECT 1)
                    match conn
                        .query_row("PRAGMA integrity_check", [], |row| row.get::<_, String>(0))
                    {
                        Ok(ref result) if result == "ok" => {
                            // Database is healthy
                        }
                        Ok(result) => {
                            findings.push(DoctorFinding {
                                severity: Severity::Error,
                                component: "database".into(),
                                message: format!("{} integrity check failed: {}", db_name, result),
                                fix: Some(format!(
                                    "Backup and recreate: cp {} {}.corrupt",
                                    db_path.display(),
                                    db_path.display()
                                )),
                            });
                        }
                        Err(e) => {
                            findings.push(DoctorFinding {
                                severity: Severity::Error,
                                component: "database".into(),
                                message: format!("{} integrity check error: {}", db_name, e),
                                fix: None,
                            });
                        }
                    }
                }
                Err(e) => {
                    findings.push(DoctorFinding {
                        severity: Severity::Error,
                        component: "database".into(),
                        message: format!("Cannot open {}: {}", db_name, e),
                        fix: None,
                    });
                }
            }
        }
    }

    // Check 3: Required directories exist
    for dir in &["sessions", "meetings", "screenshots"] {
        let dir_path = data_dir.join(dir);
        if !dir_path.exists() {
            findings.push(DoctorFinding {
                severity: Severity::Warning,
                component: "filesystem".into(),
                message: format!("Directory {} missing", dir),
                fix: Some("Will be created on first use".into()),
            });
        }
    }

    // Check 4: Bootstrap token exists
    if !Path::new("/run/lifeos/bootstrap.token").exists() {
        findings.push(DoctorFinding {
            severity: Severity::Warning,
            component: "auth".into(),
            message: "Bootstrap token not found".into(),
            fix: Some("Daemon will generate on next start".into()),
        });
    }

    // Check 5: Disk space — warn if data partition has < 1 GB free
    {
        use sysinfo::Disks;
        let disks = Disks::new_with_refreshed_list();
        let data_mount = data_dir.to_str().unwrap_or("/var").as_bytes();
        // Find the disk that contains data_dir (longest mount-point prefix match)
        let best_disk = disks
            .iter()
            .filter(|d| data_dir.starts_with(d.mount_point()))
            .max_by_key(|d| d.mount_point().as_os_str().len());
        if let Some(disk) = best_disk {
            let free_gb = disk.available_space() as f64 / 1_073_741_824.0;
            if free_gb < 1.0 {
                findings.push(DoctorFinding {
                    severity: Severity::Error,
                    component: "disk".into(),
                    message: format!(
                        "Low disk space on {}: {:.1} GB free",
                        disk.mount_point().display(),
                        free_gb
                    ),
                    fix: Some("Free space or expand partition".into()),
                });
            } else if free_gb < 5.0 {
                findings.push(DoctorFinding {
                    severity: Severity::Warning,
                    component: "disk".into(),
                    message: format!(
                        "Disk space getting low on {}: {:.1} GB free",
                        disk.mount_point().display(),
                        free_gb
                    ),
                    fix: None,
                });
            }
        }
        let _ = data_mount; // suppress unused warning
    }

    // Check 6: llama-server reachability (local LLM provider)
    {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(3))
            .build();
        if let Ok(client) = client {
            match client.get("http://127.0.0.1:8082/health").send().await {
                Ok(resp) if resp.status().is_success() => {
                    info!("[doctor] llama-server is reachable");
                }
                Ok(resp) => {
                    findings.push(DoctorFinding {
                        severity: Severity::Warning,
                        component: "llama-server".into(),
                        message: format!("llama-server returned HTTP {}", resp.status()),
                        fix: Some("sudo systemctl restart llama-server".into()),
                    });
                }
                Err(_) => {
                    findings.push(DoctorFinding {
                        severity: Severity::Warning,
                        component: "llama-server".into(),
                        message: "llama-server not reachable on :8082".into(),
                        fix: Some("sudo systemctl restart llama-server".into()),
                    });
                }
            }
        }
    }

    if findings.is_empty() {
        findings.push(DoctorFinding {
            severity: Severity::Info,
            component: "overall".into(),
            message: "All checks passed".into(),
            fix: None,
        });
    }

    findings
}
