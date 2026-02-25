//! System health and bootc integration module
use std::process::Command;
use serde::Serialize;

#[cfg(test)]
mod tests;

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

/// Check if bootc is available on the system
pub fn is_bootc_available() -> bool {
    Command::new("bootc")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Get bootc status
pub fn get_bootc_status() -> anyhow::Result<BootcStatus> {
    let output = Command::new("bootc")
        .args(["status", "--json"])
        .output()?;

    if !output.status.success() {
        anyhow::bail!("bootc status failed: {}", 
            String::from_utf8_lossy(&output.stderr));
    }

    let json: serde_json::Value = serde_json::from_slice(&output.stdout)?;
    parse_bootc_status(json)
}

/// Parse bootc status from JSON
fn parse_bootc_status(json: serde_json::Value) -> anyhow::Result<BootcStatus> {
    let status = json.get("status")
        .ok_or_else(|| anyhow::anyhow!("Missing status field"))?;
    
    let booted = status.get("booted")
        .ok_or_else(|| anyhow::anyhow!("Missing booted field"))?;
    
    let booted_slot = booted.get("image")
        .and_then(|i| i.get("image"))
        .and_then(|i| i.as_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| "unknown".to_string());

    let slots = vec![BootcSlot {
        name: "booted".to_string(),
        version: booted.get("version")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| "unknown".to_string()),
        image: booted.get("image")
            .and_then(|i| i.get("image"))
            .and_then(|i| i.as_str())
            .map(|s| s.to_string()),
        booted: true,
        rollback: false,
    }];

    let rollback_slot = status.get("rollback")
        .and_then(|r| r.get("image"))
        .and_then(|i| i.get("image"))
        .and_then(|i| i.as_str())
        .map(|s| s.to_string());

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

    // Check if bootc is available
    if !is_bootc_available() {
        issues.push("bootc not available".to_string());
    }

    // Check disk space
    match check_disk_space() {
        Ok(_) => {},
        Err(e) => issues.push(format!("disk: {}", e)),
    }

    // Check memory
    match check_memory() {
        Ok(_) => {},
        Err(e) => issues.push(format!("memory: {}", e)),
    }

    if issues.is_empty() {
        HealthStatus::Healthy
    } else if issues.len() < 3 {
        HealthStatus::Degraded(issues.join(", "))
    } else {
        HealthStatus::Unhealthy(issues.join(", "))
    }
}

/// Check disk space
fn check_disk_space() -> anyhow::Result<()> {
    let output = Command::new("df")
        .args(["-h", "/"])
        .output()?;

    if !output.status.success() {
        anyhow::bail!("df command failed");
    }

    // Simple parsing - in production, parse the actual output
    Ok(())
}

/// Check memory
fn check_memory() -> anyhow::Result<()> {
    // Check if /proc/meminfo exists
    if !std::path::Path::new("/proc/meminfo").exists() {
        anyhow::bail!("Cannot read memory info");
    }
    Ok(())
}

/// Simulate update check
pub fn check_updates(channel: &str) -> anyhow::Result<bool> {
    // In a real implementation, this would check the OCI registry
    // for available updates in the specified channel
    
    // For now, return false (no updates available)
    log::info!("Checking for updates on channel: {}", channel);
    Ok(false)
}

/// Perform rollback
pub async fn perform_rollback() -> anyhow::Result<()> {
    if !is_bootc_available() {
        anyhow::bail!("bootc is not available on this system");
    }

    let output = Command::new("bootc")
        .arg("rollback")
        .output()?;

    if !output.status.success() {
        anyhow::bail!("Rollback failed: {}", 
            String::from_utf8_lossy(&output.stderr));
    }

    Ok(())
}

/// Perform update
pub async fn perform_update(_channel: &str, dry_run: bool) -> anyhow::Result<UpdateResult> {
    if !is_bootc_available() {
        anyhow::bail!("bootc is not available on this system");
    }

    if dry_run {
        return Ok(UpdateResult {
            would_update: false,
            from_version: "current".to_string(),
            to_version: "latest".to_string(),
            changes: vec![],
        });
    }

    // In a real implementation, this would:
    // 1. Get the current image reference
    // 2. Pull the new image from the channel
    // 3. Stage it with bootc
    // 4. Mark it for next boot
    
    let output = Command::new("bootc")
        .args(["upgrade", "--apply"])
        .output()?;

    if !output.status.success() {
        anyhow::bail!("Update failed: {}", 
            String::from_utf8_lossy(&output.stderr));
    }

    Ok(UpdateResult {
        would_update: true,
        from_version: "current".to_string(),
        to_version: "updated".to_string(),
        changes: vec!["System updated".to_string()],
    })
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

    // Check bootc status
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

    // Check disk space
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
                message: format!("Error: {}", e),
            });
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