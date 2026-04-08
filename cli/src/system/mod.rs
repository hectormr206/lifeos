//! System health and bootc integration module
use serde::Serialize;
use std::fs;
use std::process::Command;

#[cfg(test)]
mod tests;

/// Disk usage threshold (percentage) above which we report a problem.
const DISK_USAGE_THRESHOLD: u8 = 90;

/// System health status
#[derive(Debug, Serialize, Clone)]
pub enum HealthStatus {
    Healthy,
    Degraded(String),
    Unhealthy(String),
}

impl std::fmt::Display for HealthStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HealthStatus::Healthy => write!(f, "healthy"),
            HealthStatus::Degraded(msg) => write!(f, "degraded: {}", msg),
            HealthStatus::Unhealthy(msg) => write!(f, "unhealthy: {}", msg),
        }
    }
}

/// Bootc slot information
#[derive(Debug, Serialize, Clone)]
pub struct BootcSlot {
    pub name: String,
    pub version: String,
    pub image: Option<String>,
    pub booted: bool,
    pub rollback: bool,
}

/// Complete system status
#[derive(Debug, Serialize, Clone)]
#[allow(dead_code)]
pub struct SystemStatus {
    pub version: String,
    pub slot: String,
    pub channel: String,
    pub mode: String,
    pub health: HealthStatus,
    pub updates_available: bool,
    pub bootc_status: Option<BootcStatus>,
}

/// Bootc status output
#[derive(Debug, Serialize, Clone)]
pub struct BootcStatus {
    pub slots: Vec<BootcSlot>,
    pub booted_slot: String,
    pub rollback_slot: Option<String>,
    pub staged: Option<BootcSlot>,
}

fn parse_image_reference(value: Option<&serde_json::Value>) -> Option<String> {
    let value = value?;
    value
        .get("image")
        .and_then(|v| v.as_str())
        .or_else(|| value.get("reference").and_then(|v| v.as_str()))
        .or_else(|| value.as_str())
        .map(|s| s.to_string())
}

fn parse_bootc_status_text(output: &str) -> anyhow::Result<BootcStatus> {
    let mut booted_image = None;
    let mut booted_version = None;
    let mut rollback_image = None;
    let mut rollback_version = None;
    let mut current = "";

    for raw_line in output.lines() {
        let line = raw_line.trim();

        if let Some(value) = line.strip_prefix("Booted image:") {
            booted_image = Some(value.trim().to_string());
            current = "booted";
            continue;
        }

        if let Some(value) = line.strip_prefix("Rollback image:") {
            rollback_image = Some(value.trim().to_string());
            current = "rollback";
            continue;
        }

        if let Some(value) = line.strip_prefix("Version:") {
            match current {
                "booted" => booted_version = Some(value.trim().to_string()),
                "rollback" => rollback_version = Some(value.trim().to_string()),
                _ => {}
            }
        }
    }

    let booted_image = booted_image.ok_or_else(|| anyhow::anyhow!("Missing booted image"))?;
    let booted_version = booted_version.unwrap_or_else(|| "unknown".to_string());

    let mut slots = vec![BootcSlot {
        name: "booted".to_string(),
        version: booted_version,
        image: Some(booted_image.clone()),
        booted: true,
        rollback: false,
    }];

    if let Some(image) = rollback_image.clone() {
        slots.push(BootcSlot {
            name: "rollback".to_string(),
            version: rollback_version.unwrap_or_else(|| "unknown".to_string()),
            image: Some(image),
            booted: false,
            rollback: true,
        });
    }

    Ok(BootcStatus {
        slots,
        booted_slot: booted_image,
        rollback_slot: rollback_image,
        staged: None,
    })
}

/// Check if bootc is available on the system
pub fn is_bootc_available() -> bool {
    Command::new("bootc")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Check if running as root
fn is_root() -> bool {
    unsafe { libc::geteuid() == 0 }
}

/// Run a command, falling back to sudo if it fails with a permission error.
fn run_with_sudo_fallback(cmd: &str, args: &[&str]) -> std::io::Result<std::process::Output> {
    let output = Command::new(cmd).args(args).output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("root") || stderr.contains("permission") || stderr.contains("Permission")
        {
            return Command::new("sudo").arg(cmd).args(args).output();
        }
    }
    Ok(output)
}

/// Get bootc status (tries sudo if not root)
pub fn get_bootc_status() -> anyhow::Result<BootcStatus> {
    let output = if is_root() {
        Command::new("bootc").args(["status", "--json"]).output()?
    } else {
        run_with_sudo_fallback("bootc", &["status", "--json"])?
    };

    if !output.status.success() {
        let text_output = if is_root() {
            Command::new("bootc").arg("status").output()?
        } else {
            run_with_sudo_fallback("bootc", &["status"])?
        };

        if !text_output.status.success() {
            anyhow::bail!(
                "bootc status failed: {}",
                String::from_utf8_lossy(&text_output.stderr)
            );
        }

        let stdout = String::from_utf8(text_output.stdout)?;
        return parse_bootc_status_text(&stdout);
    }

    match serde_json::from_slice::<serde_json::Value>(&output.stdout) {
        Ok(json) => parse_bootc_status(json),
        Err(_) => {
            let stdout = String::from_utf8(output.stdout)?;
            parse_bootc_status_text(&stdout)
        }
    }
}

/// Parse bootc status from JSON
fn parse_bootc_status(json: serde_json::Value) -> anyhow::Result<BootcStatus> {
    let status = json
        .get("status")
        .ok_or_else(|| anyhow::anyhow!("Missing status field"))?;

    let booted = status
        .get("booted")
        .ok_or_else(|| anyhow::anyhow!("Missing booted field"))?;

    let booted_slot =
        parse_image_reference(booted.get("image")).unwrap_or_else(|| "unknown".to_string());

    let slots = vec![BootcSlot {
        name: "booted".to_string(),
        version: booted
            .get("version")
            .and_then(|v| v.as_str())
            .or_else(|| {
                booted
                    .get("image")
                    .and_then(|i| i.get("version"))
                    .and_then(|v| v.as_str())
            })
            .map(|s| s.to_string())
            .unwrap_or_else(|| "unknown".to_string()),
        image: parse_image_reference(booted.get("image")),
        booted: true,
        rollback: false,
    }];

    let rollback_slot = status
        .get("rollback")
        .and_then(|r| parse_image_reference(r.get("image")));

    Ok(BootcStatus {
        slots,
        booted_slot,
        rollback_slot,
        staged: None,
    })
}

/// Check system health
pub fn check_health() -> HealthStatus {
    let mut issues = Vec::new();

    if !is_bootc_available() {
        issues.push("bootc not available".to_string());
    }

    if let Err(e) = check_disk_space() {
        issues.push(format!("disk: {}", e));
    }

    if let Err(e) = check_memory() {
        issues.push(format!("memory: {}", e));
    }

    if !check_network() {
        issues.push("no network default route".to_string());
    }

    if let Some(ai_issue) = check_ai_service_issue() {
        issues.push(ai_issue);
    }

    if issues.is_empty() {
        HealthStatus::Healthy
    } else if issues.len() < 3 {
        HealthStatus::Degraded(issues.join(", "))
    } else {
        HealthStatus::Unhealthy(issues.join(", "))
    }
}

/// Check disk space — fails if mutable storage usage exceeds threshold.
/// Uses /var instead of / because on bootc systems the root is a composefs
/// overlay that always reports 100% usage.
fn check_disk_space() -> anyhow::Result<()> {
    let output = Command::new("df").args(["-Pk", "/var"]).output()?;

    if !output.status.success() {
        anyhow::bail!("df command failed");
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    // df -Pk output: second line, 5th column is "Use%"
    // Example: "/dev/sda1  1000000  500000  500000  50% /"
    let usage = stdout
        .lines()
        .nth(1)
        .and_then(|line| line.split_whitespace().nth(4))
        .and_then(|pct| pct.trim_end_matches('%').parse::<u8>().ok());

    match usage {
        Some(pct) if pct >= DISK_USAGE_THRESHOLD => {
            anyhow::bail!(
                "root filesystem {}% full (threshold: {}%)",
                pct,
                DISK_USAGE_THRESHOLD
            );
        }
        Some(_) => Ok(()),
        None => {
            anyhow::bail!("could not parse disk usage from df output");
        }
    }
}

/// Check memory — fails if /proc/meminfo is not readable.
fn check_memory() -> anyhow::Result<()> {
    if !std::path::Path::new("/proc/meminfo").exists() {
        anyhow::bail!("Cannot read memory info");
    }
    Ok(())
}

/// Check if a default network route exists.
fn check_network() -> bool {
    std::fs::read_to_string("/proc/net/route")
        .map(|content| {
            content.lines().skip(1).any(|line| {
                // Column 2 (Destination) == "00000000" means default route
                line.split_whitespace()
                    .nth(1)
                    .map(|dest| dest == "00000000")
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

fn systemd_unit_is_active(args: &[&str]) -> bool {
    Command::new(args[0])
        .args(&args[1..])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn restart_unit(args: &[&str]) -> bool {
    Command::new(args[0])
        .args(&args[1..])
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

fn is_lifeosd_running() -> bool {
    systemd_unit_is_active(&[
        "systemctl",
        "--user",
        "is-active",
        "--quiet",
        "lifeosd.service",
    ]) || systemd_unit_is_active(&["systemctl", "is-active", "--quiet", "lifeosd.service"])
}

fn lifeosd_status_message(is_running: bool) -> String {
    if is_running {
        "lifeosd is running".to_string()
    } else if systemd_unit_is_active(&[
        "systemctl",
        "--user",
        "is-enabled",
        "--quiet",
        "lifeosd.service",
    ]) {
        "lifeosd user service is enabled but not running".to_string()
    } else {
        "lifeosd is not running".to_string()
    }
}

/// Check the AI service state and return a human-readable issue when degraded.
fn check_ai_service_issue() -> Option<String> {
    if systemd_unit_is_active(&["systemctl", "is-active", "--quiet", "llama-server.service"])
        || systemd_unit_is_active(&[
            "systemctl",
            "--user",
            "is-active",
            "--quiet",
            "llama-server.service",
        ])
    {
        return None;
    }

    let mut candidate_paths = vec!["/var/lib/lifeos/llama-server-preflight.reason".to_string()];
    if let Ok(runtime_dir) = std::env::var("XDG_RUNTIME_DIR") {
        candidate_paths.push(format!(
            "{runtime_dir}/lifeos/llama-server-preflight.reason"
        ));
    }

    for path in candidate_paths {
        if let Ok(reason) = fs::read_to_string(path) {
            let reason = reason.trim();
            if !reason.is_empty() {
                return Some(reason.to_string());
            }
        }
    }

    Some("llama-server not running".to_string())
}

/// Check for available updates via bootc.
pub fn check_updates(_channel: &str) -> anyhow::Result<bool> {
    if !is_bootc_available() {
        return Ok(false);
    }

    let output = if is_root() {
        Command::new("bootc")
            .args(["upgrade", "--check"])
            .output()?
    } else {
        run_with_sudo_fallback("bootc", &["upgrade", "--check"])?
    };

    if !output.status.success() {
        // bootc upgrade --check exits non-zero if no updates or on error
        return Ok(false);
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let combined = format!("{}{}", stdout, stderr);

    // bootc prints info about available updates when there are some
    Ok(combined.contains("Update available")
        || combined.contains("Diff")
        || combined.contains("upgrade") && !combined.contains("No update"))
}

/// Perform rollback
pub async fn perform_rollback() -> anyhow::Result<()> {
    if !is_bootc_available() {
        anyhow::bail!("bootc is not available on this system");
    }

    let output = if is_root() {
        Command::new("bootc").arg("rollback").output()?
    } else {
        run_with_sudo_fallback("bootc", &["rollback"])?
    };

    if !output.status.success() {
        anyhow::bail!(
            "Rollback failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    Ok(())
}

/// Perform update
pub async fn perform_update(_channel: &str, dry_run: bool) -> anyhow::Result<UpdateResult> {
    if !is_bootc_available() {
        anyhow::bail!("bootc is not available on this system");
    }

    if dry_run {
        let output = if is_root() {
            Command::new("bootc")
                .args(["upgrade", "--check"])
                .output()?
        } else {
            run_with_sudo_fallback("bootc", &["upgrade", "--check"])?
        };
        let has_update = output.status.success();
        return Ok(UpdateResult {
            would_update: has_update,
            from_version: "current".to_string(),
            to_version: if has_update {
                "available".to_string()
            } else {
                "current".to_string()
            },
            changes: vec![],
        });
    }

    if let Err(e) = create_pre_update_snapshot() {
        log::warn!("Pre-update snapshot failed: {}. Continuing update.", e);
    }

    let output = if is_root() {
        Command::new("bootc")
            .args(["upgrade", "--apply"])
            .output()?
    } else {
        run_with_sudo_fallback("bootc", &["upgrade", "--apply"])?
    };

    if !output.status.success() {
        anyhow::bail!("Update failed: {}", String::from_utf8_lossy(&output.stderr));
    }

    Ok(UpdateResult {
        would_update: true,
        from_version: "current".to_string(),
        to_version: "updated".to_string(),
        changes: vec!["System updated".to_string()],
    })
}

/// Create a readonly Btrfs snapshot before attempting an update.
fn create_pre_update_snapshot() -> anyhow::Result<()> {
    let snapshot_script = "/usr/local/bin/lifeos-btrfs-snapshot.sh";
    if !std::path::Path::new(snapshot_script).exists() {
        return Ok(());
    }

    let output = Command::new(snapshot_script).arg("pre-update").output()?;

    if !output.status.success() {
        anyhow::bail!("{}", String::from_utf8_lossy(&output.stderr).trim());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    if !stdout.trim().is_empty() {
        log::info!("{}", stdout.trim());
    }

    Ok(())
}

/// Update result
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct UpdateResult {
    pub would_update: bool,
    pub from_version: String,
    pub to_version: String,
    pub changes: Vec<String>,
}

/// Perform recovery checks and repairs
pub async fn perform_recovery() -> anyhow::Result<RecoveryReport> {
    let mut report = RecoveryReport {
        checks: vec![],
        repairs: vec![],
        needs_reboot: false,
    };

    // 1. Check bootc status
    match get_bootc_status() {
        Ok(status) => {
            report.checks.push(HealthCheck {
                name: "bootc".to_string(),
                passed: true,
                message: format!("Booted: {}", status.booted_slot),
            });
        }
        Err(e) => {
            report.checks.push(HealthCheck {
                name: "bootc".to_string(),
                passed: false,
                message: format!("Error: {}", e),
            });
        }
    }

    // 2. Check disk space with real threshold
    match check_disk_space() {
        Ok(_) => {
            report.checks.push(HealthCheck {
                name: "disk".to_string(),
                passed: true,
                message: "Disk space OK".to_string(),
            });
        }
        Err(e) => {
            report.checks.push(HealthCheck {
                name: "disk".to_string(),
                passed: false,
                message: format!("{}", e),
            });
        }
    }

    // 3. Check network connectivity
    let net_ok = check_network();
    report.checks.push(HealthCheck {
        name: "network".to_string(),
        passed: net_ok,
        message: if net_ok {
            "Default route present".to_string()
        } else {
            "No default route found".to_string()
        },
    });

    // 4. Check AI service (llama-server)
    let ai_running = check_ai_service();
    report.checks.push(HealthCheck {
        name: "ai-service".to_string(),
        passed: ai_running,
        message: if ai_running {
            "llama-server is running".to_string()
        } else {
            "llama-server is not running".to_string()
        },
    });

    // 5. Check lifeosd daemon
    let daemon_running = is_lifeosd_running();
    report.checks.push(HealthCheck {
        name: "lifeosd".to_string(),
        passed: daemon_running,
        message: lifeosd_status_message(daemon_running),
    });

    // --- Repair actions for failed services ---
    if !ai_running {
        if restart_unit(&["systemctl", "restart", "llama-server.service"]) {
            report.repairs.push("Restarted ai-service".to_string());
        } else {
            report.repairs.push(
                "Failed to restart ai-service (try: sudo systemctl restart llama-server.service)"
                    .to_string(),
            );
        }
    }

    if !daemon_running {
        if restart_unit(&["systemctl", "--user", "restart", "lifeosd.service"])
            || restart_unit(&["systemctl", "--user", "start", "lifeosd.service"])
        {
            report.repairs.push("Restarted lifeosd".to_string());
        } else if restart_unit(&["systemctl", "restart", "lifeosd.service"]) {
            report.repairs.push("Restarted lifeosd".to_string());
        } else {
            report.repairs.push(
                "Failed to restart lifeosd (try: systemctl --user restart lifeosd.service)"
                    .to_string(),
            );
        }
    }

    Ok(report)
}

/// Health check result
#[derive(Debug, Clone)]
pub struct HealthCheck {
    pub name: String,
    pub passed: bool,
    pub message: String,
}

/// Recovery report
#[derive(Debug, Clone)]
pub struct RecoveryReport {
    pub checks: Vec<HealthCheck>,
    pub repairs: Vec<String>,
    pub needs_reboot: bool,
}
