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
        let line = line.strip_prefix('●').map(str::trim).unwrap_or(line);

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

#[derive(Debug, Clone, PartialEq, Eq)]
struct SystemdUnitState {
    scope: &'static str,
    load_state: String,
    active_state: String,
    sub_state: String,
    result: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct AiServiceAssessment {
    issue: Option<String>,
    status_message: String,
    restart_recommended: bool,
}

fn systemd_unit_state(command: &[&str], scope: &'static str) -> Option<SystemdUnitState> {
    let output = Command::new(command[0]).args(&command[1..]).output().ok()?;
    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8(output.stdout).ok()?;
    let mut load_state = None;
    let mut active_state = None;
    let mut sub_state = None;
    let mut result = None;

    for line in stdout.lines() {
        let (key, value) = match line.split_once('=') {
            Some(parts) => parts,
            None => continue,
        };

        match key {
            "LoadState" => load_state = Some(value.to_string()),
            "ActiveState" => active_state = Some(value.to_string()),
            "SubState" => sub_state = Some(value.to_string()),
            "Result" => result = Some(value.to_string()),
            _ => {}
        }
    }

    Some(SystemdUnitState {
        scope,
        load_state: load_state.unwrap_or_else(|| "unknown".to_string()),
        active_state: active_state.unwrap_or_else(|| "unknown".to_string()),
        sub_state: sub_state.unwrap_or_else(|| "unknown".to_string()),
        result: result.unwrap_or_else(|| "unknown".to_string()),
    })
}

fn llama_reason_paths() -> Vec<String> {
    let mut candidate_paths = vec!["/var/lib/lifeos/llama-server-preflight.reason".to_string()];
    if let Ok(runtime_dir) = std::env::var("XDG_RUNTIME_DIR") {
        candidate_paths.push(format!(
            "{runtime_dir}/lifeos/llama-server-preflight.reason"
        ));
    }
    candidate_paths
}

fn persisted_llama_reason() -> Option<String> {
    for path in llama_reason_paths() {
        if let Ok(reason) = fs::read_to_string(path) {
            let reason = reason.trim();
            if !reason.is_empty() {
                return Some(reason.to_string());
            }
        }
    }
    None
}

fn format_failed_llama_service(state: &SystemdUnitState) -> String {
    if state.result != "unknown" && state.result != "success" {
        format!(
            "llama-server {scope} service failed ({result})",
            scope = state.scope,
            result = state.result
        )
    } else {
        format!(
            "llama-server {scope} service is {active}/{sub}",
            scope = state.scope,
            active = state.active_state,
            sub = state.sub_state
        )
    }
}

fn assess_ai_service(
    system_state: Option<SystemdUnitState>,
    user_state: Option<SystemdUnitState>,
    persisted_reason: Option<String>,
) -> AiServiceAssessment {
    let states = [system_state.as_ref(), user_state.as_ref()];

    if let Some(state) = states.iter().flatten().find(|state| {
        matches!(
            state.active_state.as_str(),
            "active" | "activating" | "reloading"
        )
    }) {
        return AiServiceAssessment {
            issue: None,
            status_message: format!("llama-server is running via {} systemd", state.scope),
            restart_recommended: false,
        };
    }

    if let Some(reason) = persisted_reason {
        return AiServiceAssessment {
            issue: Some(reason.clone()),
            status_message: reason,
            restart_recommended: false,
        };
    }

    if let Some(state) = states.iter().flatten().find(|state| {
        state.load_state == "loaded"
            && (state.active_state == "failed"
                || state.sub_state == "failed"
                || (state.active_state != "inactive" && state.result != "success"))
    }) {
        let message = format_failed_llama_service(state);
        return AiServiceAssessment {
            issue: Some(message.clone()),
            status_message: message,
            restart_recommended: true,
        };
    }

    if let Some(state) = states.iter().flatten().find(|state| {
        state.load_state == "loaded"
            && state.active_state == "inactive"
            && matches!(state.result.as_str(), "success" | "unknown")
    }) {
        return AiServiceAssessment {
            issue: None,
            status_message: format!(
                "llama-server is healthy but inactive ({scope} systemd, on-demand)",
                scope = state.scope
            ),
            restart_recommended: false,
        };
    }

    AiServiceAssessment {
        issue: Some("llama-server not running".to_string()),
        status_message: "llama-server not running".to_string(),
        restart_recommended: true,
    }
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
    assess_llama_service().issue
}

fn assess_llama_service() -> AiServiceAssessment {
    // Phase 4 of the architecture pivot: chat inference is the system
    // Quadlet `lifeos-llama-server.service`. We probe the new name first,
    // then fall back to the legacy `llama-server.service` so a host that
    // rolled back keeps reporting accurate status.
    let system_state = systemd_unit_state(
        &[
            "systemctl",
            "show",
            "lifeos-llama-server.service",
            "--property=LoadState,ActiveState,SubState,Result",
        ],
        "system",
    );
    let system_state = if system_state.is_some() {
        system_state
    } else {
        systemd_unit_state(
            &[
                "systemctl",
                "show",
                "llama-server.service",
                "--property=LoadState,ActiveState,SubState,Result",
            ],
            "system",
        )
    };
    assess_ai_service(
        system_state,
        systemd_unit_state(
            &[
                "systemctl",
                "--user",
                "show",
                "lifeos-llama-server.service",
                "--property=LoadState,ActiveState,SubState,Result",
            ],
            "user",
        ),
        persisted_llama_reason(),
    )
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
    let ai_assessment = assess_llama_service();
    let ai_running = ai_assessment.issue.is_none();
    report.checks.push(HealthCheck {
        name: "ai-service".to_string(),
        passed: ai_running,
        message: ai_assessment.status_message.clone(),
    });

    // 5. Check lifeosd daemon
    let daemon_running = is_lifeosd_running();
    report.checks.push(HealthCheck {
        name: "lifeosd".to_string(),
        passed: daemon_running,
        message: lifeosd_status_message(daemon_running),
    });

    // --- Repair actions for failed services ---
    // Phase 3/4 of the architecture pivot: lifeosd and llama-server are
    // now system Quadlets (lifeos-lifeosd.service, lifeos-llama-server.service).
    // Try the canonical names first, then the legacy host units for hosts
    // that rolled back to a pre-Quadlet image.
    if ai_assessment.restart_recommended {
        let restarted = restart_unit(&["systemctl", "restart", "lifeos-llama-server.service"])
            || restart_unit(&["systemctl", "restart", "llama-server.service"]);
        if restarted {
            report.repairs.push("Restarted ai-service".to_string());
        } else {
            report.repairs.push(
                "Failed to restart ai-service (try: sudo systemctl restart lifeos-llama-server.service)"
                    .to_string(),
            );
        }
    }

    if !daemon_running {
        let restarted_lifeosd =
            restart_unit(&["systemctl", "restart", "lifeos-lifeosd.service"])
                || restart_unit(&["systemctl", "--user", "restart", "lifeosd.service"])
                || restart_unit(&["systemctl", "--user", "start", "lifeosd.service"])
                || restart_unit(&["systemctl", "restart", "lifeosd.service"]);

        if restarted_lifeosd {
            report.repairs.push("Restarted lifeosd".to_string());
        } else {
            report.repairs.push(
                "Failed to restart lifeosd (try: sudo systemctl restart lifeos-lifeosd.service)"
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
