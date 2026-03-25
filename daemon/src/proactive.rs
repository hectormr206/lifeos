//! Proactive notifications — Monitors system state and generates alerts.
//!
//! Checks disk space, memory pressure, long sessions, stuck tasks, and
//! system health, then sends notifications via the supervisor notification channel.

use log::info;
#[allow(unused_imports)]
use log::warn;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

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
    ThermalCpu,
    ThermalGpu,
    SsdHealth,
    BatteryHealth,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlertSeverity {
    Info,
    Warning,
    Critical,
}

/// Run all proactive checks and return any alerts.
pub async fn check_all(
    task_queue: Option<&Arc<crate::task_queue::TaskQueue>>,
) -> Vec<ProactiveAlert> {
    let mut alerts = Vec::new();

    if let Some(alert) = check_disk_space().await {
        alerts.push(alert);
    }

    if let Some(alert) = check_memory().await {
        alerts.push(alert);
    }

    if let Some(alert) = check_session_duration().await {
        alerts.push(alert);
    }

    if let Some(alert) = check_cpu_thermal().await {
        alerts.push(alert);
    }

    if let Some(alert) = check_gpu_thermal().await {
        alerts.push(alert);
    }

    if let Some(alert) = check_ssd_health().await {
        alerts.push(alert);
    }

    if let Some(alert) = check_battery_health().await {
        alerts.push(alert);
    }

    if let Some(tq) = task_queue {
        if let Some(alert) = check_stuck_tasks(tq).await {
            alerts.push(alert);
        }
    }

    if !alerts.is_empty() {
        info!("Proactive check found {} alert(s)", alerts.len());
    }

    alerts
}

async fn check_disk_space() -> Option<ProactiveAlert> {
    // Check /var (which holds /home on bootc) instead of / (composefs overlay, always 100%).
    // On immutable systems, / is a tiny composefs mount that is always full by design.
    let output = tokio::process::Command::new("df")
        .args(["--output=pcent", "/var"])
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

async fn check_stuck_tasks(
    task_queue: &Arc<crate::task_queue::TaskQueue>,
) -> Option<ProactiveAlert> {
    // Check for tasks stuck in "running" for more than 30 minutes
    let tasks = task_queue
        .list(Some(crate::task_queue::TaskStatus::Running), 100)
        .ok()?;
    let now = chrono::Utc::now();

    let mut stuck_count = 0u32;
    for task in &tasks {
        if let Some(ref started) = task.started_at {
            if let Ok(started_dt) = chrono::DateTime::parse_from_rfc3339(started) {
                let elapsed = now.signed_duration_since(started_dt);
                if elapsed.num_minutes() > 30 {
                    stuck_count += 1;
                }
            }
        }
    }

    if stuck_count > 0 {
        Some(ProactiveAlert {
            category: AlertCategory::TaskStuck,
            message: format!(
                "{} tarea(s) llevan mas de 30 minutos en estado 'running'. Posible bloqueo.",
                stuck_count
            ),
            severity: if stuck_count >= 3 {
                AlertSeverity::Critical
            } else {
                AlertSeverity::Warning
            },
        })
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Thermal monitoring (CPU)
// ---------------------------------------------------------------------------

async fn check_cpu_thermal() -> Option<ProactiveAlert> {
    // Read the highest CPU temperature from /sys/class/thermal/thermal_zone*/temp
    let mut max_temp_mc: i64 = 0;
    let mut found = false;

    let mut entries = tokio::fs::read_dir("/sys/class/thermal").await.ok()?;
    while let Ok(Some(entry)) = entries.next_entry().await {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if !name_str.starts_with("thermal_zone") {
            continue;
        }
        let type_path = entry.path().join("type");
        let temp_path = entry.path().join("temp");
        // Only read CPU-related zones (x86_pkg_temp, coretemp, k10temp, acpitz)
        if let Ok(zone_type) = tokio::fs::read_to_string(&type_path).await {
            let zt = zone_type.trim();
            if zt.contains("x86_pkg")
                || zt.contains("coretemp")
                || zt.contains("k10temp")
                || zt == "acpitz"
            {
                if let Ok(temp_str) = tokio::fs::read_to_string(&temp_path).await {
                    if let Ok(temp) = temp_str.trim().parse::<i64>() {
                        found = true;
                        if temp > max_temp_mc {
                            max_temp_mc = temp;
                        }
                    }
                }
            }
        }
    }

    if !found {
        return None;
    }

    let temp_c = max_temp_mc / 1000;

    if temp_c >= 95 {
        Some(ProactiveAlert {
            category: AlertCategory::ThermalCpu,
            message: format!(
                "CPU a {}°C! Temperatura critica. Reduciendo rendimiento para proteger el hardware.",
                temp_c
            ),
            severity: AlertSeverity::Critical,
        })
    } else if temp_c >= 80 {
        Some(ProactiveAlert {
            category: AlertCategory::ThermalCpu,
            message: format!(
                "CPU a {}°C. Temperatura elevada. Verifica ventilacion.",
                temp_c
            ),
            severity: AlertSeverity::Warning,
        })
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Thermal monitoring (GPU via nvidia-smi)
// ---------------------------------------------------------------------------

async fn check_gpu_thermal() -> Option<ProactiveAlert> {
    let output = tokio::process::Command::new("nvidia-smi")
        .args([
            "--query-gpu=temperature.gpu",
            "--format=csv,noheader,nounits",
        ])
        .output()
        .await
        .ok()?;

    if !output.status.success() {
        return None; // No NVIDIA GPU or driver not loaded
    }

    let temp: u32 = String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse()
        .ok()?;

    if temp >= 100 {
        Some(ProactiveAlert {
            category: AlertCategory::ThermalGpu,
            message: format!(
                "GPU a {}°C! Temperatura critica. Posible daño al hardware.",
                temp
            ),
            severity: AlertSeverity::Critical,
        })
    } else if temp >= 85 {
        Some(ProactiveAlert {
            category: AlertCategory::ThermalGpu,
            message: format!("GPU a {}°C. Temperatura elevada.", temp),
            severity: AlertSeverity::Warning,
        })
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// SSD / NVMe health (via smartctl)
// ---------------------------------------------------------------------------

async fn check_ssd_health() -> Option<ProactiveAlert> {
    // Try smartctl JSON on the first NVMe device
    let output = tokio::process::Command::new("smartctl")
        .args(["-j", "-a", "/dev/nvme0n1"])
        .output()
        .await
        .ok()?;

    let text = String::from_utf8_lossy(&output.stdout);
    let json: serde_json::Value = serde_json::from_str(&text).ok()?;

    // NVMe percentage_used (0-100+, 100 = rated endurance consumed)
    let pct_used = json
        .pointer("/nvme_smart_health_information_log/percentage_used")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    // Media errors (unrecoverable data integrity errors)
    let media_errors = json
        .pointer("/nvme_smart_health_information_log/media_errors")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    // SSD temperature
    let ssd_temp = json
        .pointer("/temperature/current")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    if media_errors > 0 {
        return Some(ProactiveAlert {
            category: AlertCategory::SsdHealth,
            message: format!(
                "SSD tiene {} errores de datos irrecuperables! Haz backup AHORA. Vida usada: {}%.",
                media_errors, pct_used
            ),
            severity: AlertSeverity::Critical,
        });
    }

    if pct_used >= 90 {
        return Some(ProactiveAlert {
            category: AlertCategory::SsdHealth,
            message: format!(
                "SSD al {}% de vida util consumida. Planea reemplazo pronto.",
                pct_used
            ),
            severity: AlertSeverity::Critical,
        });
    }

    if pct_used >= 80 {
        return Some(ProactiveAlert {
            category: AlertCategory::SsdHealth,
            message: format!(
                "SSD al {}% de vida util. Considera planear reemplazo.",
                pct_used
            ),
            severity: AlertSeverity::Warning,
        });
    }

    if ssd_temp >= 70 {
        return Some(ProactiveAlert {
            category: AlertCategory::SsdHealth,
            message: format!(
                "SSD a {}°C. Temperatura elevada, puede reducir vida util.",
                ssd_temp
            ),
            severity: AlertSeverity::Warning,
        });
    }

    None
}

// ---------------------------------------------------------------------------
// Battery health (via sysfs / UPower)
// ---------------------------------------------------------------------------

async fn check_battery_health() -> Option<ProactiveAlert> {
    // Check if battery exists
    let energy_full_path = "/sys/class/power_supply/BAT0/energy_full";
    let energy_design_path = "/sys/class/power_supply/BAT0/energy_full_design";
    let cycle_path = "/sys/class/power_supply/BAT0/cycle_count";

    let energy_full: u64 = tokio::fs::read_to_string(energy_full_path)
        .await
        .ok()?
        .trim()
        .parse()
        .ok()?;
    let energy_design: u64 = tokio::fs::read_to_string(energy_design_path)
        .await
        .ok()?
        .trim()
        .parse()
        .ok()?;

    if energy_design == 0 {
        return None;
    }

    let health_pct = (energy_full as f64 / energy_design as f64 * 100.0) as u32;

    let cycles: u32 = tokio::fs::read_to_string(cycle_path)
        .await
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0);

    if health_pct < 70 {
        return Some(ProactiveAlert {
            category: AlertCategory::BatteryHealth,
            message: format!(
                "Bateria al {}% de capacidad original ({} ciclos). Considera reemplazarla.",
                health_pct, cycles
            ),
            severity: AlertSeverity::Critical,
        });
    }

    if health_pct < 80 {
        return Some(ProactiveAlert {
            category: AlertCategory::BatteryHealth,
            message: format!(
                "Bateria al {}% de capacidad original ({} ciclos). Degradacion notable.",
                health_pct, cycles
            ),
            severity: AlertSeverity::Warning,
        });
    }

    if cycles >= 500 {
        return Some(ProactiveAlert {
            category: AlertCategory::BatteryHealth,
            message: format!(
                "Bateria con {} ciclos de carga. Vida util estimada reducida (salud: {}%).",
                cycles, health_pct
            ),
            severity: AlertSeverity::Warning,
        });
    }

    None
}
