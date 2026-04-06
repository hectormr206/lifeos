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
    CalendarContext,
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
    calendar: Option<&Arc<crate::calendar::CalendarManager>>,
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

    if let Some(alert) = check_network_security().await {
        alerts.push(alert);
    }

    if let Some(alert) = check_selinux_status().await {
        alerts.push(alert);
    }

    if let Some(alert) = check_pending_security_updates().await {
        alerts.push(alert);
    }

    if let Some(alert) = check_audio_volume().await {
        alerts.push(alert);
    }

    if let Some(tq) = task_queue {
        if let Some(alert) = check_stuck_tasks(tq).await {
            alerts.push(alert);
        }
    }

    if let Some(cal) = calendar {
        alerts.extend(check_calendar_context(cal).await);
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
    // Check ACTUAL user activity via idle time, not just system uptime.
    // Uses xprintidle (X11) or the GNOME/COSMIC idle API to determine
    // how long the user has been ACTIVELY using the computer.
    // If idle > 15 min, the user is not really "active".

    // First, check if user is actually present (not idle)
    let idle_ms = get_user_idle_ms().await;
    if idle_ms > 15 * 60 * 1000 {
        // User has been idle for >15 min — don't count this as active time
        return None;
    }

    // Use loginctl to get actual session duration (not system uptime)
    let output = tokio::process::Command::new("loginctl")
        .args(["show-session", "auto", "--property=Timestamp"])
        .output()
        .await
        .ok()?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    // Parse "Timestamp=<datetime>"
    let session_start = stdout.trim().strip_prefix("Timestamp=")?;
    let start_dt =
        chrono::DateTime::parse_from_str(session_start.trim(), "%a %Y-%m-%d %H:%M:%S %Z")
            .ok()
            .or_else(|| {
                // Fallback: try RFC3339 or other formats
                chrono::DateTime::parse_from_rfc3339(session_start.trim()).ok()
            })?;

    let hours = (chrono::Utc::now()
        .signed_duration_since(start_dt)
        .num_minutes() as f64
        / 60.0) as u32;

    if hours >= 6 {
        Some(ProactiveAlert {
            category: AlertCategory::LongSession,
            message: format!(
                "Llevas {} horas de sesion activa. Recuerda tomar un descanso, hidratarte y estirar.",
                hours
            ),
            severity: AlertSeverity::Info,
        })
    } else {
        None
    }
}

/// Get user idle time in milliseconds via multiple detection methods.
async fn get_user_idle_ms() -> u64 {
    // Method 1: GNOME/COSMIC idle via D-Bus (Wayland-compatible)
    if let Ok(output) = tokio::process::Command::new("dbus-send")
        .args([
            "--print-reply",
            "--dest=org.gnome.Mutter.IdleMonitor",
            "/org/gnome/Mutter/IdleMonitor/Core",
            "org.gnome.Mutter.IdleMonitor.GetIdletime",
        ])
        .output()
        .await
    {
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            // Parse "uint64 <ms>" from dbus response
            if let Some(ms_str) = stdout.split_whitespace().last() {
                if let Ok(ms) = ms_str.parse::<u64>() {
                    return ms;
                }
            }
        }
    }

    // Method 2: xprintidle (X11 fallback)
    if let Ok(output) = tokio::process::Command::new("xprintidle").output().await {
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            if let Ok(ms) = stdout.trim().parse::<u64>() {
                return ms;
            }
        }
    }

    // If we can't detect idle time, assume user is active (0 idle)
    0
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
// Calendar context checks (BD.7 — Smart Reminders)
// ---------------------------------------------------------------------------

async fn check_calendar_context(
    calendar: &Arc<crate::calendar::CalendarManager>,
) -> Vec<ProactiveAlert> {
    let mut alerts = Vec::new();
    let now = chrono::Utc::now();

    // (a) Upcoming event warning — event in the next 30 minutes
    if let Ok(upcoming) = calendar.upcoming(1) {
        for event in &upcoming {
            if let Ok(start) = chrono::DateTime::parse_from_rfc3339(&event.start_time) {
                let until = start.signed_duration_since(now);
                let mins = until.num_minutes();
                if (0..=30).contains(&mins) {
                    alerts.push(ProactiveAlert {
                        category: AlertCategory::CalendarContext,
                        message: format!(
                            "Tu evento '{}' empieza en {} minutos.",
                            event.title, mins
                        ),
                        severity: AlertSeverity::Info,
                    });
                }
            }
        }
    }

    // (b) Empty tomorrow — no events scheduled
    // Query events for the next 2 days and filter to only those starting tomorrow
    if let Ok(upcoming_2d) = calendar.upcoming(2) {
        let tomorrow = (chrono::Local::now() + chrono::Duration::days(1))
            .format("%Y-%m-%d")
            .to_string();
        let has_tomorrow_events = upcoming_2d.iter().any(|e| {
            chrono::DateTime::parse_from_rfc3339(&e.start_time)
                .map(|dt| {
                    dt.with_timezone(&chrono::Local)
                        .format("%Y-%m-%d")
                        .to_string()
                        == tomorrow
                })
                .unwrap_or(false)
        });
        if !has_tomorrow_events {
            alerts.push(ProactiveAlert {
                category: AlertCategory::CalendarContext,
                message: "No tienes nada agendado para manana.".into(),
                severity: AlertSeverity::Info,
            });
        }
    }

    // (c) Busy day warning — 5+ events today
    if let Ok(today_events) = calendar.today() {
        let count = today_events.len();
        if count >= 5 {
            alerts.push(ProactiveAlert {
                category: AlertCategory::CalendarContext,
                message: format!("Dia ocupado — tienes {} eventos hoy.", count),
                severity: AlertSeverity::Warning,
            });
        }

        // (d) Late event — started >10 min ago with no end_time
        for event in &today_events {
            if event.end_time.is_none() {
                if let Ok(start) = chrono::DateTime::parse_from_rfc3339(&event.start_time) {
                    let elapsed = now.signed_duration_since(start);
                    let mins = elapsed.num_minutes();
                    if mins > 10 {
                        alerts.push(ProactiveAlert {
                            category: AlertCategory::CalendarContext,
                            message: format!(
                                "Tu evento '{}' empezo hace {} minutos. Todo bien?",
                                event.title, mins
                            ),
                            severity: AlertSeverity::Info,
                        });
                    }
                }
            }
        }
    }

    alerts
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
    } else if temp_c >= 90 {
        // Threshold raised to 90°C — many laptops idle at 80-85°C under load.
        // 80°C was causing constant alerts on normal hardware.
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

// ---------------------------------------------------------------------------
// Network security monitoring
// ---------------------------------------------------------------------------

async fn check_network_security() -> Option<ProactiveAlert> {
    // Check for suspicious listening ports
    let output = tokio::process::Command::new("ss")
        .args(["-tulnp"])
        .output()
        .await
        .ok()?;

    let text = String::from_utf8_lossy(&output.stdout);

    // Known suspicious ports (cryptomining, C2 servers)
    let suspicious_ports = [
        "3333", "4444", "5555", "8333", "14444", // Mining pools
        "4443", "8443", "9090", // Common C2
    ];

    let mut suspicious_lines = Vec::new();
    for line in text.lines().skip(1) {
        let lower = line.to_lowercase();
        for port in &suspicious_ports {
            if lower.contains(&format!(":{}", port)) && lower.contains("listen") {
                suspicious_lines.push(line.trim().to_string());
            }
        }
    }

    if !suspicious_lines.is_empty() {
        return Some(ProactiveAlert {
            category: AlertCategory::SystemHealth,
            message: format!(
                "Puertos sospechosos detectados ({} servicios). Verifica: {}",
                suspicious_lines.len(),
                suspicious_lines.first().unwrap_or(&String::new())
            ),
            severity: AlertSeverity::Warning,
        });
    }

    // Check if firewall is active (firewalld or nftables).
    // Fedora uses firewalld by default (manages nftables underneath).
    // Check firewalld first — if active, the system is protected.
    let firewalld_active = tokio::process::Command::new("systemctl")
        .args(["is-active", "firewalld"])
        .output()
        .await
        .map(|o| o.status.success())
        .unwrap_or(false);

    if !firewalld_active {
        // firewalld not running — check nftables directly (with sudo for read access)
        let nft_output = tokio::process::Command::new("sudo")
            .args(["nft", "list", "ruleset"])
            .output()
            .await
            .ok();

        let has_rules = nft_output
            .map(|o| o.status.success() && !o.stdout.is_empty())
            .unwrap_or(false);

        if !has_rules {
            return Some(ProactiveAlert {
                category: AlertCategory::SecurityUpdate,
                message: "Firewall no activo (ni firewalld ni nftables). Sistema expuesto.".into(),
                severity: AlertSeverity::Warning,
            });
        }
    }

    None
}

// ---------------------------------------------------------------------------
// SELinux status check
// ---------------------------------------------------------------------------

async fn check_selinux_status() -> Option<ProactiveAlert> {
    let output = tokio::process::Command::new("getenforce")
        .output()
        .await
        .ok()?;

    let status = String::from_utf8_lossy(&output.stdout)
        .trim()
        .to_lowercase();

    if status == "disabled" {
        return Some(ProactiveAlert {
            category: AlertCategory::SecurityUpdate,
            message:
                "SELinux esta deshabilitado. El sistema tiene menos proteccion contra exploits."
                    .into(),
            severity: AlertSeverity::Warning,
        });
    }

    if status == "permissive" {
        return Some(ProactiveAlert {
            category: AlertCategory::SecurityUpdate,
            message: "SELinux en modo permisivo. Solo registra violaciones, no las bloquea.".into(),
            severity: AlertSeverity::Info,
        });
    }

    None
}

// ---------------------------------------------------------------------------
// Pending security updates
// ---------------------------------------------------------------------------

async fn check_pending_security_updates() -> Option<ProactiveAlert> {
    let output = tokio::process::Command::new("dnf")
        .args(["updateinfo", "list", "security", "--available", "-q"])
        .output()
        .await
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let text = String::from_utf8_lossy(&output.stdout);
    let count = text.lines().filter(|l| !l.trim().is_empty()).count();

    if count >= 5 {
        Some(ProactiveAlert {
            category: AlertCategory::SecurityUpdate,
            message: format!(
                "{} actualizaciones de seguridad pendientes. Ejecuta: sudo dnf update --security",
                count
            ),
            severity: AlertSeverity::Warning,
        })
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Audio volume health (hearing protection per WHO guidelines)
// ---------------------------------------------------------------------------

async fn check_audio_volume() -> Option<ProactiveAlert> {
    let output = tokio::process::Command::new("wpctl")
        .args(["get-volume", "@DEFAULT_AUDIO_SINK@"])
        .output()
        .await
        .ok()?;

    let text = String::from_utf8_lossy(&output.stdout);
    let volume: f64 = text
        .split_whitespace()
        .last()?
        .trim_end_matches(']')
        .parse()
        .ok()?;

    let volume_pct = (volume * 100.0) as u32;

    if volume_pct > 85 {
        Some(ProactiveAlert {
            category: AlertCategory::SystemHealth,
            message: format!(
                "Volumen al {}%. La OMS recomienda no superar 85% para proteger tu audicion.",
                volume_pct
            ),
            severity: AlertSeverity::Warning,
        })
    } else {
        None
    }
}
