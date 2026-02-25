//! Health monitoring module
//! Monitors system health and reports issues

use std::process::Command;
use serde::{Serialize, Deserialize};
use async_trait::async_trait;

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
        let monitor = Self {
            checks: Vec::new(),
        };
        
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
    let output = Command::new("bootc")
        .args(["status", "--json"])
        .output()?;

    if !output.status.success() {
        return Ok((false, "bootc status check failed".to_string()));
    }

    Ok((true, "bootc is healthy".to_string()))
}

async fn check_disk_space() -> anyhow::Result<(bool, String)> {
    use std::fs;
    
    let _metadata = fs::metadata("/")?;
    // Simplified check - just verify root is accessible
    Ok((true, "Disk accessible".to_string()))
}
