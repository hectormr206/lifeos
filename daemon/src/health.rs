//! Health monitoring module
//! Monitors system health and reports issues

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::process::Command;

#[cfg(test)]
mod health_tests;

/// Health check report
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthReport {
    pub healthy: bool,
    pub timestamp: chrono::DateTime<chrono::Local>,
    pub issues: Vec<HealthIssue>,
    pub checks: Vec<CheckResult>,
}

/// Health issue
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthIssue {
    pub severity: Severity,
    pub component: String,
    pub message: String,
    pub suggestion: Option<String>,
}

/// Issue severity
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum Severity {
    Info,
    Warning,
    Critical,
}

/// Individual check result
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckResult {
    pub name: String,
    pub passed: bool,
    pub message: String,
}

/// Health monitor
pub struct HealthMonitor {
    #[allow(dead_code)]
    checks: Vec<Box<dyn HealthCheck + Send + Sync>>,
}

impl std::fmt::Debug for HealthMonitor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HealthMonitor")
            .field("checks_count", &self.checks.len())
            .finish()
    }
}

impl HealthMonitor {
    pub fn new() -> Self {
        let monitor = Self { checks: Vec::new() };

        // Note: Health checks disabled due to async trait complexity
        // Can be re-enabled with proper async_trait implementation

        monitor
    }

    /// Run basic health checks
    pub async fn check_all(&self) -> anyhow::Result<HealthReport> {
        let mut issues = Vec::new();
        let mut check_results = Vec::new();

        // Bootc check
        match check_bootc().await {
            Ok((passed, msg)) => {
                if !passed {
                    issues.push(HealthIssue {
                        severity: Severity::Warning,
                        component: "bootc".to_string(),
                        message: msg.clone(),
                        suggestion: Some("Verify bootc installation".to_string()),
                    });
                }
                check_results.push(CheckResult {
                    name: "bootc".to_string(),
                    passed,
                    message: msg,
                });
            }
            Err(e) => {
                check_results.push(CheckResult {
                    name: "bootc".to_string(),
                    passed: false,
                    message: format!("Error: {}", e),
                });
            }
        }

        // Disk space check
        match check_filesystem_integrity().await {
            Ok((passed, msg)) => {
                if !passed {
                    issues.push(HealthIssue {
                        severity: Severity::Critical,
                        component: "filesystem-integrity".to_string(),
                        message: msg.clone(),
                        suggestion: Some(
                            "Verify composefs/fs-verity configuration for /usr".to_string(),
                        ),
                    });
                }
                check_results.push(CheckResult {
                    name: "filesystem-integrity".to_string(),
                    passed,
                    message: msg,
                });
            }
            Err(e) => {
                check_results.push(CheckResult {
                    name: "filesystem-integrity".to_string(),
                    passed: false,
                    message: format!("Error: {}", e),
                });
            }
        }

        // Platform baseline check (Secure Boot + LUKS2)
        match check_security_baseline().await {
            Ok((passed, msg)) => {
                if !passed {
                    issues.push(HealthIssue {
                        severity: Severity::Critical,
                        component: "security-baseline".to_string(),
                        message: msg.clone(),
                        suggestion: Some(
                            "Enable Secure Boot and install on LUKS2-encrypted root".to_string(),
                        ),
                    });
                }
                check_results.push(CheckResult {
                    name: "security-baseline".to_string(),
                    passed,
                    message: msg,
                });
            }
            Err(e) => {
                check_results.push(CheckResult {
                    name: "security-baseline".to_string(),
                    passed: false,
                    message: format!("Error: {}", e),
                });
            }
        }

        // Disk space check
        match check_disk_space().await {
            Ok((passed, msg)) => {
                if !passed {
                    issues.push(HealthIssue {
                        severity: Severity::Critical,
                        component: "disk".to_string(),
                        message: msg.clone(),
                        suggestion: Some("Free up disk space".to_string()),
                    });
                }
                check_results.push(CheckResult {
                    name: "disk".to_string(),
                    passed,
                    message: msg,
                });
            }
            Err(e) => {
                check_results.push(CheckResult {
                    name: "disk".to_string(),
                    passed: false,
                    message: format!("Error: {}", e),
                });
            }
        }

        // Network health check
        match check_network().await {
            Ok((passed, msg)) => {
                if !passed {
                    issues.push(HealthIssue {
                        severity: Severity::Warning,
                        component: "network".to_string(),
                        message: msg.clone(),
                        suggestion: Some(
                            "Ensure NetworkManager is active and a default route exists"
                                .to_string(),
                        ),
                    });
                }
                check_results.push(CheckResult {
                    name: "network".to_string(),
                    passed,
                    message: msg,
                });
            }
            Err(e) => {
                check_results.push(CheckResult {
                    name: "network".to_string(),
                    passed: false,
                    message: format!("Error: {}", e),
                });
            }
        }

        // AI service check (llama-server)
        match check_ai_service().await {
            Ok((passed, msg)) => {
                if !passed {
                    issues.push(HealthIssue {
                        severity: Severity::Warning,
                        component: "ai".to_string(),
                        message: msg.clone(),
                        suggestion: Some("Restart llama-server service".to_string()),
                    });
                }
                check_results.push(CheckResult {
                    name: "ai-service".to_string(),
                    passed,
                    message: msg,
                });
            }
            Err(e) => {
                check_results.push(CheckResult {
                    name: "ai-service".to_string(),
                    passed: false,
                    message: format!("Error: {}", e),
                });
            }
        }

        let all_healthy = issues.iter().all(|i| i.severity != Severity::Critical);

        Ok(HealthReport {
            healthy: all_healthy,
            timestamp: chrono::Local::now(),
            issues,
            checks: check_results,
        })
    }
}

/// Health check trait
#[async_trait]
#[allow(dead_code)]
trait HealthCheck: Send + Sync {
    fn name(&self) -> &str;
    async fn check(&self) -> anyhow::Result<CheckOutput>;
}

/// Check output
#[allow(dead_code)]
struct CheckOutput {
    passed: bool,
    message: String,
    issue: Option<HealthIssue>,
}

async fn check_bootc() -> anyhow::Result<(bool, String)> {
    let output = Command::new("bootc").args(["status", "--json"]).output()?;

    if !output.status.success() {
        return Ok((false, "bootc status check failed".to_string()));
    }

    Ok((true, "bootc is healthy".to_string()))
}

async fn check_disk_space() -> anyhow::Result<(bool, String)> {
    // Use /var instead of / because on bootc systems the root (/) is a composefs
    // overlay that always reports 100% usage. /var is the real mutable storage.
    let output = Command::new("df").args(["-Pk", "/var"]).output()?;

    if !output.status.success() {
        return Ok((false, "df command failed".to_string()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout.lines().nth(1).unwrap_or_default();
    let cols: Vec<&str> = line.split_whitespace().collect();

    if cols.len() < 6 {
        return Ok((false, "Could not parse disk usage".to_string()));
    }

    let total = cols
        .get(1)
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(0.0);
    let available = cols
        .get(3)
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(0.0);

    if total <= 0.0 {
        return Ok((false, "Disk size reported as zero".to_string()));
    }

    let free_percent = (available / total) * 100.0;
    if free_percent < 10.0 {
        Ok((false, format!("Low disk space: {:.1}% free", free_percent)))
    } else {
        Ok((true, format!("Disk healthy: {:.1}% free", free_percent)))
    }
}

async fn check_ai_service() -> anyhow::Result<(bool, String)> {
    // Prefer systemd status when available.
    if let Ok(output) = Command::new("systemctl")
        .args(["is-active", "--quiet", "llama-server.service"])
        .output()
    {
        if output.status.success() {
            return Ok((true, "llama-server service is active".to_string()));
        }
    }

    // Fallback for environments without a full systemd session.
    let pgrep = Command::new("pgrep")
        .args(["-x", "llama-server"])
        .output()?;
    if pgrep.status.success() {
        Ok((true, "llama-server process is running".to_string()))
    } else {
        Ok((false, "llama-server is not running".to_string()))
    }
}

async fn check_filesystem_integrity() -> anyhow::Result<(bool, String)> {
    let script = "/usr/local/bin/lifeos-integrity-check.sh";
    if Path::new(script).exists() {
        let output = Command::new(script).arg("--quiet").output()?;
        if output.status.success() {
            return Ok((true, "composefs/fs-verity verification passed".to_string()));
        }

        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let message = if !stderr.is_empty() {
            stderr
        } else if !stdout.is_empty() {
            stdout
        } else {
            "composefs/fs-verity verification failed".to_string()
        };
        return Ok((false, message));
    }

    let fstype_output = Command::new("findmnt")
        .args(["-n", "-o", "FSTYPE", "/usr"])
        .output()?;
    if !fstype_output.status.success() {
        return Ok((false, "Could not inspect /usr filesystem type".to_string()));
    }

    let fstype = String::from_utf8_lossy(&fstype_output.stdout)
        .trim()
        .to_string();
    if fstype != "composefs" {
        return Ok((
            false,
            format!("/usr filesystem is '{fstype}', expected composefs"),
        ));
    }

    let options_output = Command::new("findmnt")
        .args(["-n", "-o", "OPTIONS", "/usr"])
        .output()?;
    if !options_output.status.success() {
        return Ok((false, "Could not inspect /usr mount options".to_string()));
    }

    let options = String::from_utf8_lossy(&options_output.stdout).to_string();
    let has_verity_hint = options.contains("digest=") || options.contains("verity");
    if !has_verity_hint {
        return Ok((
            false,
            "composefs mount missing verity/digest hints; fs-verity status unclear".to_string(),
        ));
    }

    Ok((
        true,
        "/usr is mounted with composefs and verity hints".to_string(),
    ))
}

async fn check_network() -> anyhow::Result<(bool, String)> {
    let routes = std::fs::read_to_string("/proc/net/route")?;
    let has_default_route = routes.lines().skip(1).any(|line| {
        let cols: Vec<&str> = line.split_whitespace().collect();
        cols.get(1).map(|v| *v == "00000000").unwrap_or(false)
    });

    if has_default_route {
        Ok((true, "Default route is configured".to_string()))
    } else {
        Ok((false, "No default route configured".to_string()))
    }
}

async fn check_security_baseline() -> anyhow::Result<(bool, String)> {
    let script = "/usr/local/bin/lifeos-security-baseline-check.sh";
    if !Path::new(script).exists() {
        return Ok((false, "Security baseline script not found".to_string()));
    }

    let output = Command::new(script).arg("--quiet").output()?;
    if output.status.success() {
        return Ok((true, "Secure Boot/LUKS2 baseline satisfied".to_string()));
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let message = if !stderr.is_empty() {
        stderr
    } else if !stdout.is_empty() {
        stdout
    } else {
        "Secure Boot/LUKS2 baseline check failed".to_string()
    };
    Ok((false, message))
}
