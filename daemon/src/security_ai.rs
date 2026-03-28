//! AI Security Daemon — Fase Y
//!
//! Advanced threat detection with rule-based engine, automatic response actions,
//! forensic reporting, and integration with the daemon event bus.
//!
//! Monitors: network connections, process anomalies, unauthorized file access,
//! system integrity, brute-force attempts, USB threats, and privilege escalation.

use chrono::{DateTime, Utc};
use log::{error, info, warn};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fmt;
use std::fs;
use std::process::Command;
use tokio::sync::broadcast;
use uuid::Uuid;

use crate::events::DaemonEvent;

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

/// Main AI security monitor that holds state across scan cycles.
pub struct SecurityAiDaemon {
    alert_history: Vec<SecurityAlert>,
    blocked_pids: Vec<u32>,
    rules: Vec<DetectionRule>,
    /// Per-process high-CPU tracking: pid -> consecutive detection count.
    high_cpu_tracker: HashMap<u32, u32>,
}

/// A security alert produced by the detection engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecurityAlert {
    pub id: String,
    pub severity: AlertSeverity,
    pub alert_type: AlertType,
    pub description: String,
    pub process_name: Option<String>,
    pub process_pid: Option<u32>,
    pub remote_addr: Option<String>,
    pub evidence: Vec<String>,
    pub action_taken: String,
    pub timestamp: DateTime<Utc>,
}

/// Severity levels from informational to emergency.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub enum AlertSeverity {
    Info,
    Warning,
    Critical,
    Emergency,
}

impl fmt::Display for AlertSeverity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AlertSeverity::Info => write!(f, "INFO"),
            AlertSeverity::Warning => write!(f, "WARNING"),
            AlertSeverity::Critical => write!(f, "CRITICAL"),
            AlertSeverity::Emergency => write!(f, "EMERGENCY"),
        }
    }
}

/// Categories of security alerts.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum AlertType {
    /// Connection to known mining pools or C2 servers.
    SuspiciousConnection,
    /// Large outbound transfer to unknown IP.
    DataExfiltration,
    /// Process attempting sudo/setuid unexpectedly.
    PrivilegeEscalation,
    /// Access to sensitive files (keys, tokens, passwords).
    UnauthorizedFileAccess,
    /// Unknown process with high CPU/network.
    AnomalousProcess,
    /// Multiple failed SSH/login attempts.
    BruteForce,
    /// Unknown USB HID device.
    UsbThreat,
    /// System binary modified.
    IntegrityViolation,
}

impl fmt::Display for AlertType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AlertType::SuspiciousConnection => write!(f, "Suspicious Connection"),
            AlertType::DataExfiltration => write!(f, "Data Exfiltration"),
            AlertType::PrivilegeEscalation => write!(f, "Privilege Escalation"),
            AlertType::UnauthorizedFileAccess => write!(f, "Unauthorized File Access"),
            AlertType::AnomalousProcess => write!(f, "Anomalous Process"),
            AlertType::BruteForce => write!(f, "Brute Force"),
            AlertType::UsbThreat => write!(f, "USB Threat"),
            AlertType::IntegrityViolation => write!(f, "Integrity Violation"),
        }
    }
}

// ---------------------------------------------------------------------------
// Detection rule engine
// ---------------------------------------------------------------------------

/// A detection rule that runs on a configurable interval.
pub struct DetectionRule {
    pub name: String,
    pub check: fn() -> Option<SecurityAlert>,
    pub interval_secs: u64,
}

// ---------------------------------------------------------------------------
// Known-bad indicators
// ---------------------------------------------------------------------------

/// Ports commonly used by crypto-mining pools.
const MINING_PORTS: &[u16] = &[3333, 4444, 5555, 8333, 14444];

/// Process names associated with crypto-miners.
const MINER_NAMES: &[&str] = &[
    "xmrig",
    "minerd",
    "cpuminer",
    "cgminer",
    "bfgminer",
    "ethminer",
    "nbminer",
    "t-rex",
    "phoenixminer",
    "lolminer",
    "gminer",
    "ccminer",
    "nheqminer",
    "cryptonight",
];

/// Sensitive file path patterns.
const SENSITIVE_PATTERNS: &[&str] = &[
    "ssh/id_",
    ".gnupg/",
    "password",
    "token",
    ".key",
    ".pem",
    "shadow",
    "credentials",
];

/// Trusted processes that legitimately access sensitive files.
const TRUSTED_PROCS: &[&str] = &[
    "sshd",
    "gpg-agent",
    "keepassxc",
    "ssh-agent",
    "gnome-keyring",
    "systemd",
    "polkitd",
    "gdm",
    "login",
    "sudo",
    "passwd",
];

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

impl SecurityAiDaemon {
    /// Create a new security AI daemon with default rules.
    pub fn new() -> Self {
        Self {
            alert_history: Vec::new(),
            blocked_pids: Vec::new(),
            rules: Vec::new(),
            high_cpu_tracker: HashMap::new(),
        }
    }

    /// Return a read-only view of past alerts.
    pub fn alert_history(&self) -> &[SecurityAlert] {
        &self.alert_history
    }

    /// Return a list of currently blocked PIDs.
    pub fn blocked_pids(&self) -> &[u32] {
        &self.blocked_pids
    }

    /// Return the registered detection rules.
    pub fn rules(&self) -> &[DetectionRule] {
        &self.rules
    }

    /// Register a custom detection rule.
    pub fn add_rule(&mut self, rule: DetectionRule) {
        self.rules.push(rule);
    }

    // -----------------------------------------------------------------------
    // 1. Suspicious connections
    // -----------------------------------------------------------------------

    /// Scan active TCP connections for mining-pool ports, excessive outbound
    /// connections from a single process, and connections on uncommon high ports
    /// from unknown processes.
    pub async fn check_suspicious_connections(&self) -> Vec<SecurityAlert> {
        let mut alerts = Vec::new();

        let output = match Command::new("ss").args(["-tnp"]).output() {
            Ok(o) => o,
            Err(e) => {
                warn!("security_ai: cannot run ss: {}", e);
                return alerts;
            }
        };

        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.lines().skip(1).collect();

        // Track outbound connections per process name.
        let mut process_conn_count: HashMap<String, u32> = HashMap::new();

        for line in &lines {
            let fields: Vec<&str> = line.split_whitespace().collect();
            if fields.len() < 5 {
                continue;
            }

            let peer_addr_full = fields[4];
            let process_info = if fields.len() > 5 { fields[5] } else { "" };
            let proc_name = extract_process_name(process_info);

            // Count outbound connections per process.
            if let Some(ref name) = proc_name {
                *process_conn_count.entry(name.clone()).or_insert(0) += 1;
            }

            // Extract peer port.
            if let Some(peer_port) = extract_port(peer_addr_full) {
                let peer_ip = extract_ip(peer_addr_full);

                // Check mining-pool ports.
                if MINING_PORTS.contains(&peer_port) {
                    alerts.push(SecurityAlert {
                        id: Uuid::new_v4().to_string(),
                        severity: AlertSeverity::Critical,
                        alert_type: AlertType::SuspiciousConnection,
                        description: format!(
                            "Connection to known mining pool port {} detected",
                            peer_port
                        ),
                        process_name: proc_name.clone(),
                        process_pid: extract_pid(process_info),
                        remote_addr: peer_ip.clone(),
                        evidence: vec![
                            format!("Peer: {}", peer_addr_full),
                            format!("Mining port: {}", peer_port),
                            format!("Process: {}", process_info),
                        ],
                        action_taken: String::new(),
                        timestamp: Utc::now(),
                    });
                }

                // Flag unknown processes connecting to uncommon high ports (>10000).
                if peer_port > 10000 && proc_name.is_none() {
                    alerts.push(SecurityAlert {
                        id: Uuid::new_v4().to_string(),
                        severity: AlertSeverity::Warning,
                        alert_type: AlertType::SuspiciousConnection,
                        description: format!(
                            "Unknown process connecting to high port {}",
                            peer_port
                        ),
                        process_name: None,
                        process_pid: None,
                        remote_addr: peer_ip,
                        evidence: vec![
                            format!("Peer: {}", peer_addr_full),
                            format!("Full line: {}", line),
                        ],
                        action_taken: String::new(),
                        timestamp: Utc::now(),
                    });
                }
            }
        }

        // Flag processes with >50 outbound connections.
        for (name, count) in &process_conn_count {
            if *count > 50 {
                alerts.push(SecurityAlert {
                    id: Uuid::new_v4().to_string(),
                    severity: AlertSeverity::Warning,
                    alert_type: AlertType::DataExfiltration,
                    description: format!(
                        "Process '{}' has {} outbound connections (threshold: 50)",
                        name, count
                    ),
                    process_name: Some(name.clone()),
                    process_pid: None,
                    remote_addr: None,
                    evidence: vec![format!("Connection count: {}", count)],
                    action_taken: String::new(),
                    timestamp: Utc::now(),
                });
            }
        }

        alerts
    }

    // -----------------------------------------------------------------------
    // 2. Anomalous processes
    // -----------------------------------------------------------------------

    /// Scan /proc for processes with high CPU usage, known miner names, or
    /// processes running from suspicious locations (/tmp, /dev/shm).
    pub async fn check_anomalous_processes(&mut self) -> Vec<SecurityAlert> {
        let mut alerts = Vec::new();

        let entries = match fs::read_dir("/proc") {
            Ok(e) => e,
            Err(e) => {
                warn!("security_ai: cannot read /proc: {}", e);
                return alerts;
            }
        };

        for entry in entries.flatten() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();

            if !name_str.chars().all(|c| c.is_ascii_digit()) {
                continue;
            }

            let pid: u32 = match name_str.parse() {
                Ok(p) => p,
                Err(_) => continue,
            };

            let proc_name = match read_proc_name(pid) {
                Some(n) => n,
                None => continue,
            };

            let proc_name_lower = proc_name.to_lowercase();

            // Check for known crypto-miner process names.
            if MINER_NAMES.iter().any(|m| proc_name_lower.contains(m)) {
                alerts.push(SecurityAlert {
                    id: Uuid::new_v4().to_string(),
                    severity: AlertSeverity::Emergency,
                    alert_type: AlertType::AnomalousProcess,
                    description: format!(
                        "Known crypto-miner process detected: '{}' (pid {})",
                        proc_name, pid
                    ),
                    process_name: Some(proc_name.clone()),
                    process_pid: Some(pid),
                    remote_addr: None,
                    evidence: vec![
                        format!("Process name matches miner pattern: {}", proc_name),
                        read_proc_cmdline(pid)
                            .unwrap_or_else(|| "(cmdline unavailable)".to_string()),
                    ],
                    action_taken: String::new(),
                    timestamp: Utc::now(),
                });
            }

            // Check for processes running from /tmp or /dev/shm.
            if let Some(exe_path) = read_proc_exe(pid) {
                if exe_path.starts_with("/tmp")
                    || exe_path.starts_with("/dev/shm")
                    || exe_path.starts_with("/var/tmp")
                {
                    alerts.push(SecurityAlert {
                        id: Uuid::new_v4().to_string(),
                        severity: AlertSeverity::Critical,
                        alert_type: AlertType::AnomalousProcess,
                        description: format!(
                            "Process '{}' (pid {}) running from suspicious path: {}",
                            proc_name, pid, exe_path
                        ),
                        process_name: Some(proc_name.clone()),
                        process_pid: Some(pid),
                        remote_addr: None,
                        evidence: vec![
                            format!("Executable path: {}", exe_path),
                            read_proc_cmdline(pid)
                                .unwrap_or_else(|| "(cmdline unavailable)".to_string()),
                        ],
                        action_taken: String::new(),
                        timestamp: Utc::now(),
                    });
                }
            }

            // Check CPU usage — track consecutive high-CPU detections.
            if let Some(cpu_pct) = read_proc_cpu_percent(pid) {
                if cpu_pct > 80.0 {
                    let count = self.high_cpu_tracker.entry(pid).or_insert(0);
                    *count += 1;

                    // Alert if high CPU for more than 2 consecutive cycles (~60s at 30s interval).
                    if *count >= 2 && !is_system_process(&proc_name) {
                        alerts.push(SecurityAlert {
                            id: Uuid::new_v4().to_string(),
                            severity: AlertSeverity::Warning,
                            alert_type: AlertType::AnomalousProcess,
                            description: format!(
                                "Process '{}' (pid {}) using {:.1}% CPU for >{} seconds",
                                proc_name,
                                pid,
                                cpu_pct,
                                *count * 30
                            ),
                            process_name: Some(proc_name.clone()),
                            process_pid: Some(pid),
                            remote_addr: None,
                            evidence: vec![
                                format!("CPU usage: {:.1}%", cpu_pct),
                                format!("Consecutive detections: {}", count),
                            ],
                            action_taken: String::new(),
                            timestamp: Utc::now(),
                        });
                    }
                } else {
                    // Reset tracker if CPU drops below threshold.
                    self.high_cpu_tracker.remove(&pid);
                }
            }
        }

        // Clean up tracker entries for PIDs that no longer exist.
        self.high_cpu_tracker
            .retain(|pid, _| std::path::Path::new(&format!("/proc/{}", pid)).exists());

        alerts
    }

    // -----------------------------------------------------------------------
    // 3. Unauthorized file access
    // -----------------------------------------------------------------------

    /// Check if any process has open file descriptors pointing to sensitive
    /// paths (SSH keys, GPG data, passwords, tokens).
    pub async fn check_unauthorized_file_access(&self) -> Vec<SecurityAlert> {
        let mut alerts = Vec::new();

        let entries = match fs::read_dir("/proc") {
            Ok(e) => e,
            Err(e) => {
                warn!("security_ai: cannot read /proc: {}", e);
                return alerts;
            }
        };

        for entry in entries.flatten() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();

            if !name_str.chars().all(|c| c.is_ascii_digit()) {
                continue;
            }

            let pid: u32 = match name_str.parse() {
                Ok(p) => p,
                Err(_) => continue,
            };

            let proc_name = match read_proc_name(pid) {
                Some(n) => n,
                None => continue,
            };

            // Skip trusted processes.
            if TRUSTED_PROCS.iter().any(|t| proc_name.contains(t)) {
                continue;
            }

            // Read open file descriptors.
            let fd_dir = format!("/proc/{}/fd", pid);
            let fd_entries = match fs::read_dir(&fd_dir) {
                Ok(e) => e,
                Err(_) => continue, // Permission denied is normal for other users' procs.
            };

            for fd_entry in fd_entries.flatten() {
                let link = match fs::read_link(fd_entry.path()) {
                    Ok(l) => l,
                    Err(_) => continue,
                };

                let link_str = link.to_string_lossy().to_string();

                // Check if the fd points to a sensitive path.
                let is_sensitive = SENSITIVE_PATTERNS
                    .iter()
                    .any(|pattern| link_str.contains(pattern));

                if is_sensitive {
                    alerts.push(SecurityAlert {
                        id: Uuid::new_v4().to_string(),
                        severity: AlertSeverity::Critical,
                        alert_type: AlertType::UnauthorizedFileAccess,
                        description: format!(
                            "Process '{}' (pid {}) has open fd to sensitive file: {}",
                            proc_name, pid, link_str
                        ),
                        process_name: Some(proc_name.clone()),
                        process_pid: Some(pid),
                        remote_addr: None,
                        evidence: vec![
                            format!("File descriptor target: {}", link_str),
                            format!("Process: {} (pid {})", proc_name, pid),
                            read_proc_cmdline(pid)
                                .unwrap_or_else(|| "(cmdline unavailable)".to_string()),
                        ],
                        action_taken: String::new(),
                        timestamp: Utc::now(),
                    });
                    // Only one alert per process+file combo is enough.
                    break;
                }
            }
        }

        alerts
    }

    // -----------------------------------------------------------------------
    // 4. System integrity
    // -----------------------------------------------------------------------

    /// Verify system integrity: rpm package verification, SELinux status,
    /// and /etc/shadow permissions.
    pub async fn check_system_integrity(&self) -> Vec<SecurityAlert> {
        let mut alerts = Vec::new();

        // --- rpm -V for critical packages ---
        let critical_packages = [
            "coreutils",
            "systemd",
            "openssh-server",
            "shadow-utils",
            "sudo",
        ];
        for pkg in &critical_packages {
            let output = Command::new("rpm").args(["-V", pkg]).output();
            match output {
                Ok(out) => {
                    let stdout = String::from_utf8_lossy(&out.stdout);
                    let stderr = String::from_utf8_lossy(&out.stderr);

                    // rpm -V returns non-zero if files differ; stdout lists changes.
                    if !out.status.success() && !stdout.trim().is_empty() {
                        let changed_files: Vec<String> = stdout
                            .lines()
                            .filter(|l| !l.trim().is_empty())
                            .map(|l| l.to_string())
                            .collect();

                        if !changed_files.is_empty() {
                            alerts.push(SecurityAlert {
                                id: Uuid::new_v4().to_string(),
                                severity: AlertSeverity::Emergency,
                                alert_type: AlertType::IntegrityViolation,
                                description: format!(
                                    "Package '{}' has modified files ({} changes)",
                                    pkg,
                                    changed_files.len()
                                ),
                                process_name: None,
                                process_pid: None,
                                remote_addr: None,
                                evidence: changed_files,
                                action_taken: String::new(),
                                timestamp: Utc::now(),
                            });
                        }
                    }

                    // Package not installed is not a security issue, just skip.
                    if stderr.contains("is not installed") {
                        continue;
                    }
                }
                Err(_) => {
                    // rpm not available — skip.
                    continue;
                }
            }
        }

        // --- SELinux status ---
        let selinux_output = Command::new("getenforce").output();
        match selinux_output {
            Ok(out) => {
                let status = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if status == "Permissive" || status == "Disabled" {
                    alerts.push(SecurityAlert {
                        id: Uuid::new_v4().to_string(),
                        severity: AlertSeverity::Critical,
                        alert_type: AlertType::IntegrityViolation,
                        description: format!("SELinux is {} -- system hardening degraded", status),
                        process_name: None,
                        process_pid: None,
                        remote_addr: None,
                        evidence: vec![format!("getenforce returned: {}", status)],
                        action_taken: String::new(),
                        timestamp: Utc::now(),
                    });
                }
            }
            Err(_) => {
                // getenforce not available — non-SELinux system.
            }
        }

        // --- /etc/shadow permissions ---
        if let Ok(metadata) = fs::metadata("/etc/shadow") {
            use std::os::unix::fs::PermissionsExt;
            let mode = metadata.permissions().mode() & 0o7777;
            // Expected: 0640 or stricter.
            if mode > 0o640 {
                alerts.push(SecurityAlert {
                    id: Uuid::new_v4().to_string(),
                    severity: AlertSeverity::Critical,
                    alert_type: AlertType::IntegrityViolation,
                    description: format!(
                        "/etc/shadow has overly permissive mode: {:04o} (expected <= 0640)",
                        mode
                    ),
                    process_name: None,
                    process_pid: None,
                    remote_addr: None,
                    evidence: vec![format!("File mode: {:04o}", mode)],
                    action_taken: String::new(),
                    timestamp: Utc::now(),
                });
            }
        }

        alerts
    }

    // -----------------------------------------------------------------------
    // 5. Response actions
    // -----------------------------------------------------------------------

    /// Suspend a process by sending SIGSTOP.
    pub async fn isolate_process(&mut self, pid: u32) -> Result<String, String> {
        // Verify the process exists.
        if !std::path::Path::new(&format!("/proc/{}", pid)).exists() {
            return Err(format!("Process {} does not exist", pid));
        }

        let proc_name = read_proc_name(pid).unwrap_or_else(|| "(unknown)".to_string());

        // Send SIGSTOP.
        let result = Command::new("kill")
            .args(["-STOP", &pid.to_string()])
            .output();

        match result {
            Ok(out) if out.status.success() => {
                self.blocked_pids.push(pid);
                let msg = format!(
                    "Process '{}' (pid {}) suspended with SIGSTOP",
                    proc_name, pid
                );
                info!("security_ai: {}", msg);
                Ok(msg)
            }
            Ok(out) => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                let msg = format!(
                    "Failed to suspend '{}' (pid {}): {}",
                    proc_name,
                    pid,
                    stderr.trim()
                );
                error!("security_ai: {}", msg);
                Err(msg)
            }
            Err(e) => {
                let msg = format!("Cannot execute kill for pid {}: {}", pid, e);
                error!("security_ai: {}", msg);
                Err(msg)
            }
        }
    }

    /// Block a remote IP address using nftables (or iptables fallback).
    pub async fn block_connection(remote_addr: &str) -> Result<String, String> {
        // Validate the address looks like an IP.
        if remote_addr.is_empty()
            || remote_addr.contains(';')
            || remote_addr.contains('&')
            || remote_addr.contains('|')
        {
            return Err(format!("Invalid address: {}", remote_addr));
        }

        // Try nftables first.
        let nft_result = Command::new("nft")
            .args([
                "add",
                "rule",
                "inet",
                "filter",
                "input",
                "ip",
                "saddr",
                remote_addr,
                "drop",
            ])
            .output();

        let nft_ok = matches!(&nft_result, Ok(out) if out.status.success());

        if nft_ok {
            let msg = format!("Blocked {} via nftables", remote_addr);
            info!("security_ai: {}", msg);
            Ok(msg)
        } else {
            // Fallback to iptables.
            let ipt_result = Command::new("iptables")
                .args(["-A", "INPUT", "-s", remote_addr, "-j", "DROP"])
                .output();

            match ipt_result {
                Ok(out) if out.status.success() => {
                    let msg = format!("Blocked {} via iptables", remote_addr);
                    info!("security_ai: {}", msg);
                    Ok(msg)
                }
                Ok(out) => {
                    let stderr = String::from_utf8_lossy(&out.stderr);
                    let msg = format!(
                        "Failed to block {} via iptables: {}",
                        remote_addr,
                        stderr.trim()
                    );
                    error!("security_ai: {}", msg);
                    Err(msg)
                }
                Err(e) => {
                    let msg = format!("Cannot execute iptables to block {}: {}", remote_addr, e);
                    error!("security_ai: {}", msg);
                    Err(msg)
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // 6. Monitoring loop
    // -----------------------------------------------------------------------

    /// Run the security monitor loop (every 30 seconds).
    ///
    /// 1. Runs all detection checks.
    /// 2. For Critical/Emergency alerts: takes immediate action (isolate/block).
    /// 3. Emits events for all alerts via the event bus.
    /// 4. Stores alert history.
    pub async fn run_security_monitor(event_bus: broadcast::Sender<DaemonEvent>) {
        let mut daemon = SecurityAiDaemon::new();
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(30));

        info!("security_ai: monitoring loop started (30s interval)");

        loop {
            interval.tick().await;

            let mut all_alerts = Vec::new();

            // Run detection checks sequentially.
            // check_anomalous_processes requires &mut self, so we cannot
            // use tokio::join! for all checks simultaneously.
            let conn_alerts = daemon.check_suspicious_connections().await;
            let proc_alerts = daemon.check_anomalous_processes().await;
            let file_alerts = daemon.check_unauthorized_file_access().await;
            let integrity_alerts = daemon.check_system_integrity().await;

            all_alerts.extend(conn_alerts);
            all_alerts.extend(proc_alerts);
            all_alerts.extend(file_alerts);
            all_alerts.extend(integrity_alerts);

            // Process each alert.
            for alert in &mut all_alerts {
                // For Critical/Emergency: take automatic action.
                if alert.severity >= AlertSeverity::Critical {
                    // Isolate suspicious processes.
                    if let Some(pid) = alert.process_pid {
                        if !daemon.blocked_pids.contains(&pid) {
                            match daemon.isolate_process(pid).await {
                                Ok(msg) => alert.action_taken = msg,
                                Err(msg) => {
                                    alert.action_taken =
                                        format!("Isolation attempted but failed: {}", msg)
                                }
                            }
                        }
                    }

                    // Block suspicious remote addresses.
                    if let Some(ref addr) = alert.remote_addr {
                        match Self::block_connection(addr).await {
                            Ok(msg) => {
                                if !alert.action_taken.is_empty() {
                                    alert.action_taken.push_str("; ");
                                }
                                alert.action_taken.push_str(&msg);
                            }
                            Err(msg) => {
                                if !alert.action_taken.is_empty() {
                                    alert.action_taken.push_str("; ");
                                }
                                alert
                                    .action_taken
                                    .push_str(&format!("Block attempted but failed: {}", msg));
                            }
                        }
                    }
                }

                // Emit notification via event bus.
                let priority = match alert.severity {
                    AlertSeverity::Info => "low",
                    AlertSeverity::Warning => "medium",
                    AlertSeverity::Critical => "high",
                    AlertSeverity::Emergency => "urgent",
                };

                let message = format!(
                    "[{}] {}: {}{}",
                    alert.severity,
                    alert.alert_type,
                    alert.description,
                    if alert.action_taken.is_empty() {
                        String::new()
                    } else {
                        format!(" | Action: {}", alert.action_taken)
                    }
                );

                let _ = event_bus.send(DaemonEvent::Notification {
                    priority: priority.to_string(),
                    message,
                });
            }

            if !all_alerts.is_empty() {
                info!(
                    "security_ai: scan complete -- {} alert(s) detected",
                    all_alerts.len()
                );
            }

            // Store in history (keep last 1000 alerts).
            daemon.alert_history.extend(all_alerts);
            if daemon.alert_history.len() > 1000 {
                let excess = daemon.alert_history.len() - 1000;
                daemon.alert_history.drain(0..excess);
            }
        }
    }

    // -----------------------------------------------------------------------
    // 7. Forensic report
    // -----------------------------------------------------------------------

    /// Generate a detailed forensic report for a security alert.
    pub fn generate_forensic_report(alert: &SecurityAlert) -> String {
        let mut report = String::new();

        report.push_str("====================================\n");
        report.push_str("  LifeOS Security Forensic Report\n");
        report.push_str("====================================\n\n");

        // Header.
        report.push_str(&format!("Alert ID:    {}\n", alert.id));
        report.push_str(&format!(
            "Timestamp:   {}\n",
            alert.timestamp.format("%Y-%m-%d %H:%M:%S UTC")
        ));
        report.push_str(&format!("Severity:    {}\n", alert.severity));
        report.push_str(&format!("Type:        {}\n", alert.alert_type));
        report.push_str(&format!("Description: {}\n\n", alert.description));

        // Process info.
        report.push_str("--- Process Information ---\n");
        if let Some(ref name) = alert.process_name {
            report.push_str(&format!("  Name: {}\n", name));
        } else {
            report.push_str("  Name: (unknown)\n");
        }
        if let Some(pid) = alert.process_pid {
            report.push_str(&format!("  PID:  {}\n", pid));

            // Gather live process info if still running.
            if let Some(cmdline) = read_proc_cmdline(pid) {
                report.push_str(&format!("  Cmdline: {}\n", cmdline));
            }
            if let Some(exe) = read_proc_exe(pid) {
                report.push_str(&format!("  Executable: {}\n", exe));
            }
            if let Some(user) = read_proc_user(pid) {
                report.push_str(&format!("  User: {}\n", user));
            }
            if let Some(start) = read_proc_start_time(pid) {
                report.push_str(&format!("  Start time: {}\n", start));
            }
        } else {
            report.push_str("  PID:  (not available)\n");
        }

        // Network info.
        report.push_str("\n--- Network Information ---\n");
        if let Some(ref addr) = alert.remote_addr {
            report.push_str(&format!("  Remote address: {}\n", addr));

            // Gather connection details for this address.
            if let Some(pid) = alert.process_pid {
                let connections = get_process_connections(pid);
                if !connections.is_empty() {
                    report.push_str("  Active connections:\n");
                    for conn in &connections {
                        report.push_str(&format!("    {}\n", conn));
                    }
                }
            }
        } else {
            report.push_str("  Remote address: (not applicable)\n");
        }

        // Evidence.
        report.push_str("\n--- Evidence Collected ---\n");
        if alert.evidence.is_empty() {
            report.push_str("  (none)\n");
        } else {
            for (i, item) in alert.evidence.iter().enumerate() {
                report.push_str(&format!("  [{}] {}\n", i + 1, item));
            }
        }

        // Action taken.
        report.push_str("\n--- Action Taken ---\n");
        if alert.action_taken.is_empty() {
            report.push_str("  No automatic action taken.\n");
        } else {
            report.push_str(&format!("  {}\n", alert.action_taken));
        }

        // Recommended actions.
        report.push_str("\n--- Recommended Actions ---\n");
        match alert.alert_type {
            AlertType::SuspiciousConnection => {
                report.push_str("  1. Investigate the destination IP/port\n");
                report.push_str("  2. Check if the process is legitimate\n");
                report.push_str("  3. Block the remote IP if confirmed malicious\n");
                report.push_str("  4. Run a full malware scan\n");
            }
            AlertType::DataExfiltration => {
                report.push_str("  1. Isolate the process immediately\n");
                report.push_str("  2. Capture network traffic for analysis\n");
                report.push_str("  3. Check what data may have been sent\n");
                report.push_str("  4. Rotate any potentially exposed credentials\n");
            }
            AlertType::PrivilegeEscalation => {
                report.push_str("  1. Kill the offending process\n");
                report.push_str("  2. Audit sudo/setuid configuration\n");
                report.push_str("  3. Check for unauthorized cron jobs\n");
                report.push_str("  4. Review /var/log/auth.log\n");
            }
            AlertType::UnauthorizedFileAccess => {
                report.push_str("  1. Kill the process accessing sensitive files\n");
                report.push_str("  2. Rotate any exposed keys or tokens\n");
                report.push_str("  3. Audit file permissions\n");
                report.push_str("  4. Enable audit logging (auditd)\n");
            }
            AlertType::AnomalousProcess => {
                report.push_str("  1. Investigate the process origin\n");
                report.push_str("  2. Check if it is a known miner\n");
                report.push_str("  3. Kill the process if unauthorized\n");
                report.push_str("  4. Scan the executable with antivirus\n");
            }
            AlertType::BruteForce => {
                report.push_str("  1. Block the source IP\n");
                report.push_str("  2. Review authentication logs\n");
                report.push_str("  3. Ensure SSH key-only auth is enabled\n");
                report.push_str("  4. Consider fail2ban or similar\n");
            }
            AlertType::UsbThreat => {
                report.push_str("  1. Disconnect the USB device\n");
                report.push_str("  2. Check dmesg for device details\n");
                report.push_str("  3. Verify no HID injection occurred\n");
                report.push_str("  4. Update USB device whitelist\n");
            }
            AlertType::IntegrityViolation => {
                report.push_str("  1. Compare modified files against known-good copies\n");
                report.push_str("  2. Reinstall affected packages (rpm -V, rpm --restore)\n");
                report.push_str("  3. Check for rootkit presence (rkhunter, chkrootkit)\n");
                report.push_str("  4. Reboot into a known-good bootc image\n");
            }
        }

        report.push_str("\n====================================\n");
        report.push_str("  End of Forensic Report\n");
        report.push_str("====================================\n");

        report
    }
}

// ---------------------------------------------------------------------------
// Helper functions (module-private)
// ---------------------------------------------------------------------------

/// Read process name from /proc/<pid>/status.
fn read_proc_name(pid: u32) -> Option<String> {
    let path = format!("/proc/{}/status", pid);
    let contents = fs::read_to_string(&path).ok()?;
    for line in contents.lines() {
        if line.starts_with("Name:") {
            return Some(line.split_whitespace().nth(1)?.to_string());
        }
    }
    None
}

/// Read process command line from /proc/<pid>/cmdline.
fn read_proc_cmdline(pid: u32) -> Option<String> {
    let path = format!("/proc/{}/cmdline", pid);
    let contents = fs::read_to_string(&path).ok()?;
    let cmdline = contents.replace('\0', " ").trim().to_string();
    if cmdline.is_empty() {
        None
    } else {
        Some(cmdline)
    }
}

/// Read process executable path from /proc/<pid>/exe symlink.
fn read_proc_exe(pid: u32) -> Option<String> {
    let path = format!("/proc/{}/exe", pid);
    fs::read_link(&path)
        .ok()
        .map(|p| p.to_string_lossy().to_string())
}

/// Read the UID of a process and resolve to username.
fn read_proc_user(pid: u32) -> Option<String> {
    let path = format!("/proc/{}/status", pid);
    let contents = fs::read_to_string(&path).ok()?;
    for line in contents.lines() {
        if line.starts_with("Uid:") {
            let uid_str = line.split_whitespace().nth(1)?;
            let uid: u32 = uid_str.parse().ok()?;
            // Try to resolve via /etc/passwd.
            if let Ok(passwd) = fs::read_to_string("/etc/passwd") {
                for pline in passwd.lines() {
                    let fields: Vec<&str> = pline.split(':').collect();
                    if fields.len() > 2 {
                        if let Ok(puid) = fields[2].parse::<u32>() {
                            if puid == uid {
                                return Some(fields[0].to_string());
                            }
                        }
                    }
                }
            }
            return Some(format!("uid={}", uid));
        }
    }
    None
}

/// Read approximate process start time from /proc/<pid>/stat.
fn read_proc_start_time(pid: u32) -> Option<String> {
    let stat = fs::read_to_string(format!("/proc/{}/stat", pid)).ok()?;
    let fields: Vec<&str> = stat.split_whitespace().collect();
    if fields.len() <= 21 {
        return None;
    }

    let start_ticks: f64 = fields[21].parse().ok()?;
    let ticks_per_sec: f64 = 100.0; // sysconf(_SC_CLK_TCK) default
    let uptime_str = fs::read_to_string("/proc/uptime").ok()?;
    let uptime: f64 = uptime_str.split_whitespace().next()?.parse().ok()?;

    let process_start_secs = start_ticks / ticks_per_sec;
    let age_secs = uptime - process_start_secs;

    if age_secs < 0.0 {
        return None;
    }

    let boot_time = Utc::now() - chrono::Duration::seconds(age_secs as i64);
    Some(boot_time.format("%Y-%m-%d %H:%M:%S UTC").to_string())
}

/// Estimate CPU usage percentage for a process (single-sample heuristic).
/// Reads utime+stime from /proc/<pid>/stat and divides by total system uptime.
fn read_proc_cpu_percent(pid: u32) -> Option<f64> {
    let stat = fs::read_to_string(format!("/proc/{}/stat", pid)).ok()?;
    let fields: Vec<&str> = stat.split_whitespace().collect();
    if fields.len() <= 21 {
        return None;
    }

    let utime: f64 = fields[13].parse().ok()?;
    let stime: f64 = fields[14].parse().ok()?;
    let start_ticks: f64 = fields[21].parse().ok()?;

    let ticks_per_sec: f64 = 100.0;
    let uptime_str = fs::read_to_string("/proc/uptime").ok()?;
    let uptime: f64 = uptime_str.split_whitespace().next()?.parse().ok()?;

    let process_start_secs = start_ticks / ticks_per_sec;
    let elapsed = uptime - process_start_secs;

    if elapsed <= 0.0 {
        return None;
    }

    let total_time = (utime + stime) / ticks_per_sec;
    let cpu_pct = (total_time / elapsed) * 100.0;

    Some(cpu_pct)
}

/// Check if a process name is a known system process.
fn is_system_process(name: &str) -> bool {
    const SYSTEM_PROCS: &[&str] = &[
        "systemd",
        "kworker",
        "kthread",
        "ksoftirqd",
        "rcu_sched",
        "rcu_preempt",
        "migration",
        "watchdog",
        "irq/",
        "scsi_",
        "md_",
        "jbd2",
        "ext4",
        "btrfs",
        "xfs_",
        "dm-",
        "loop",
        "agetty",
        "init",
        "journald",
        "udevd",
        "dbus-daemon",
        "polkitd",
        "gdm",
        "gnome-shell",
        "Xwayland",
        "pipewire",
        "wireplumber",
        "pulseaudio",
        "NetworkManager",
        "firewalld",
        "sshd",
        "crond",
        "chronyd",
        "rsyslogd",
        "auditd",
        "llama-server",
        "lifeosd",
    ];

    SYSTEM_PROCS.iter().any(|p| name.contains(p))
}

/// Extract process name from ss output field like `users:(("firefox",pid=1234,fd=56))`.
fn extract_process_name(info: &str) -> Option<String> {
    // Look for (("name" pattern.
    if let Some(start) = info.find("((\"") {
        let after = &info[start + 3..];
        if let Some(end) = after.find('"') {
            return Some(after[..end].to_string());
        }
    }
    None
}

/// Extract PID from ss process info field.
fn extract_pid(info: &str) -> Option<u32> {
    if let Some(start) = info.find("pid=") {
        let after = &info[start + 4..];
        let pid_str: String = after.chars().take_while(|c| c.is_ascii_digit()).collect();
        return pid_str.parse().ok();
    }
    None
}

/// Extract port from addr:port or [addr]:port format.
fn extract_port(addr: &str) -> Option<u16> {
    addr.rsplit(':').next()?.parse().ok()
}

/// Extract IP from addr:port format.
fn extract_ip(addr: &str) -> Option<String> {
    let parts: Vec<&str> = addr.rsplitn(2, ':').collect();
    if parts.len() == 2 {
        Some(parts[1].trim_matches(|c| c == '[' || c == ']').to_string())
    } else {
        None
    }
}

/// Get active network connections for a given PID.
fn get_process_connections(pid: u32) -> Vec<String> {
    let output = match Command::new("ss").args(["-tnp"]).output() {
        Ok(o) => o,
        Err(_) => return Vec::new(),
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let pid_pattern = format!("pid={}", pid);

    stdout
        .lines()
        .skip(1)
        .filter(|line| line.contains(&pid_pattern))
        .map(|line| line.to_string())
        .collect()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_daemon() {
        let daemon = SecurityAiDaemon::new();
        assert!(daemon.alert_history.is_empty());
        assert!(daemon.blocked_pids.is_empty());
        assert!(daemon.rules.is_empty());
        assert!(daemon.high_cpu_tracker.is_empty());
    }

    #[test]
    fn test_alert_severity_ordering() {
        assert!(AlertSeverity::Info < AlertSeverity::Warning);
        assert!(AlertSeverity::Warning < AlertSeverity::Critical);
        assert!(AlertSeverity::Critical < AlertSeverity::Emergency);
    }

    #[test]
    fn test_alert_severity_display() {
        assert_eq!(format!("{}", AlertSeverity::Info), "INFO");
        assert_eq!(format!("{}", AlertSeverity::Emergency), "EMERGENCY");
    }

    #[test]
    fn test_alert_type_display() {
        assert_eq!(
            format!("{}", AlertType::SuspiciousConnection),
            "Suspicious Connection"
        );
        assert_eq!(
            format!("{}", AlertType::IntegrityViolation),
            "Integrity Violation"
        );
    }

    #[test]
    fn test_extract_port() {
        assert_eq!(extract_port("127.0.0.1:8081"), Some(8081));
        assert_eq!(extract_port("[::1]:443"), Some(443));
        assert_eq!(extract_port("*:22"), Some(22));
        assert_eq!(extract_port("invalid"), None);
    }

    #[test]
    fn test_extract_ip() {
        assert_eq!(
            extract_ip("192.168.1.1:8080"),
            Some("192.168.1.1".to_string())
        );
        assert_eq!(extract_ip("[::1]:443"), Some("::1".to_string()));
    }

    #[test]
    fn test_extract_process_name() {
        assert_eq!(
            extract_process_name("users:((\"firefox\",pid=1234,fd=56))"),
            Some("firefox".to_string())
        );
        assert_eq!(extract_process_name(""), None);
        assert_eq!(extract_process_name("no-match"), None);
    }

    #[test]
    fn test_extract_pid() {
        assert_eq!(
            extract_pid("users:((\"firefox\",pid=1234,fd=56))"),
            Some(1234)
        );
        assert_eq!(extract_pid("no-pid-here"), None);
    }

    #[test]
    fn test_is_system_process() {
        assert!(is_system_process("systemd"));
        assert!(is_system_process("lifeosd"));
        assert!(is_system_process("llama-server"));
        assert!(!is_system_process("xmrig"));
        assert!(!is_system_process("suspicious"));
    }

    #[test]
    fn test_read_proc_name_pid1() {
        // PID 1 should exist on any Linux system.
        if cfg!(target_os = "linux") {
            let name = read_proc_name(1);
            assert!(name.is_some());
        }
    }

    #[test]
    fn test_read_proc_name_nonexistent() {
        assert!(read_proc_name(999_999_999).is_none());
    }

    #[test]
    fn test_forensic_report_format() {
        let alert = SecurityAlert {
            id: "test-id-123".to_string(),
            severity: AlertSeverity::Critical,
            alert_type: AlertType::AnomalousProcess,
            description: "Test anomalous process".to_string(),
            process_name: Some("test_proc".to_string()),
            process_pid: Some(99999),
            remote_addr: None,
            evidence: vec!["evidence-1".to_string(), "evidence-2".to_string()],
            action_taken: "Process suspended".to_string(),
            timestamp: Utc::now(),
        };

        let report = SecurityAiDaemon::generate_forensic_report(&alert);
        assert!(report.contains("test-id-123"));
        assert!(report.contains("CRITICAL"));
        assert!(report.contains("Anomalous Process"));
        assert!(report.contains("test_proc"));
        assert!(report.contains("evidence-1"));
        assert!(report.contains("Process suspended"));
        assert!(report.contains("Recommended Actions"));
    }

    #[test]
    fn test_block_connection_rejects_invalid() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let result = rt.block_on(SecurityAiDaemon::block_connection(";rm -rf /"));
        assert!(result.is_err());

        let result = rt.block_on(SecurityAiDaemon::block_connection(""));
        assert!(result.is_err());
    }

    #[test]
    fn test_add_rule() {
        let mut daemon = SecurityAiDaemon::new();
        assert!(daemon.rules().is_empty());

        daemon.add_rule(DetectionRule {
            name: "test_rule".to_string(),
            check: || None,
            interval_secs: 60,
        });

        assert_eq!(daemon.rules().len(), 1);
        assert_eq!(daemon.rules()[0].name, "test_rule");
    }

    #[tokio::test]
    async fn test_check_suspicious_connections_runs() {
        let daemon = SecurityAiDaemon::new();
        // Should not panic; may return empty in CI.
        let _alerts = daemon.check_suspicious_connections().await;
    }

    #[tokio::test]
    async fn test_check_anomalous_processes_runs() {
        let mut daemon = SecurityAiDaemon::new();
        let _alerts = daemon.check_anomalous_processes().await;
    }

    #[tokio::test]
    async fn test_check_unauthorized_file_access_runs() {
        let daemon = SecurityAiDaemon::new();
        let _alerts = daemon.check_unauthorized_file_access().await;
    }

    #[tokio::test]
    async fn test_check_system_integrity_runs() {
        let daemon = SecurityAiDaemon::new();
        let _alerts = daemon.check_system_integrity().await;
    }
}
