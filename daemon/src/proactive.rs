//! Proactive notifications — Monitors system state and generates alerts.
//!
//! Checks disk space, memory pressure, long sessions, and system health,
//! then sends notifications via the supervisor notification channel.

// log used when integrated with supervisor
#[allow(unused_imports)]
use log::{info, warn};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProactiveAlert {
    pub category: AlertCategory,
    pub message: String,
    pub severity: AlertSeverity,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlertCategory {
    DiskSpace,
    MemoryPressure,
    LongSession,
    SystemHealth,
    SecurityUpdate,
    TaskStuck,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlertSeverity {
    Info,
    Warning,
    Critical,
}

/// Run all proactive checks and return any alerts.
pub async fn check_all() -> Vec<ProactiveAlert> {
    let mut alerts = Vec::new();

    // Disk space check
    if let Some(alert) = check_disk_space().await {
        alerts.push(alert);
    }

    // Memory pressure
    if let Some(alert) = check_memory().await {
        alerts.push(alert);
    }

    // Long session (uptime without break)
    if let Some(alert) = check_session_duration().await {
        alerts.push(alert);
    }

    // Stuck tasks
    if let Some(alert) = check_stuck_tasks().await {
        alerts.push(alert);
    }

    alerts
}

async fn check_disk_space() -> Option<ProactiveAlert> {
    let output = tokio::process::Command::new("df")
        .args(["--output=pcent", "/"])
        .output()
        .await
        .ok()?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let pct: u32 = stdout
        .lines()
        .nth(1)?
        .trim()
        .trim_end_matches('%')
        .parse()
        .ok()?;

    if pct >= 95 {
        Some(ProactiveAlert {
            category: AlertCategory::DiskSpace,
            message: format!(
                "Disco al {}%. Espacio critico. Libera espacio urgentemente.",
                pct
            ),
            severity: AlertSeverity::Critical,
        })
    } else if pct >= 85 {
        Some(ProactiveAlert {
            category: AlertCategory::DiskSpace,
            message: format!("Disco al {}%. Considera liberar espacio.", pct),
            severity: AlertSeverity::Warning,
        })
    } else {
        None
    }
}

async fn check_memory() -> Option<ProactiveAlert> {
    let output = tokio::process::Command::new("free")
        .args(["-m"])
        .output()
        .await
        .ok()?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mem_line = stdout.lines().nth(1)?;
    let parts: Vec<&str> = mem_line.split_whitespace().collect();
    let total: u64 = parts.get(1)?.parse().ok()?;
    let available: u64 = parts.get(6)?.parse().ok()?;

    if total == 0 {
        return None;
    }

    let used_pct = ((total - available) as f64 / total as f64 * 100.0) as u32;

    if used_pct >= 95 {
        Some(ProactiveAlert {
            category: AlertCategory::MemoryPressure,
            message: format!(
                "RAM al {}% ({} MB libres de {} MB). Cierra aplicaciones.",
                used_pct, available, total
            ),
            severity: AlertSeverity::Critical,
        })
    } else if used_pct >= 85 {
        Some(ProactiveAlert {
            category: AlertCategory::MemoryPressure,
            message: format!("RAM al {}% ({} MB libres).", used_pct, available),
            severity: AlertSeverity::Warning,
        })
    } else {
        None
    }
}

async fn check_session_duration() -> Option<ProactiveAlert> {
    // Check uptime to see if user has been active for too long
    let output = tokio::process::Command::new("uptime")
        .args(["-p"])
        .output()
        .await
        .ok()?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    // Simple heuristic: if uptime contains "hours" and the number is > 4
    if stdout.contains("hours") || stdout.contains("hour") {
        let hours: u32 = stdout
            .split_whitespace()
            .find_map(|w| w.parse().ok())
            .unwrap_or(0);

        if hours >= 6 {
            return Some(ProactiveAlert {
                category: AlertCategory::LongSession,
                message: format!(
                    "Llevas {} horas activo. Recuerda tomar un descanso, hidratarte y estirar.",
                    hours
                ),
                severity: AlertSeverity::Info,
            });
        }
    }
    None
}

async fn check_stuck_tasks() -> Option<ProactiveAlert> {
    // Check for tasks stuck in "running" for more than 30 minutes
    // This would need access to the task queue — for now, skip
    // (will be connected when integrated with supervisor)
    None
}
