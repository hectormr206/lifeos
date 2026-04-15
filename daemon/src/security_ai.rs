//! AI Security Daemon — Fase Y
//!
//! Advanced threat detection with rule-based engine, automatic response actions,
//! forensic reporting, and integration with the daemon event bus.
//!
//! Monitors: network connections, process anomalies, unauthorized file access,
//! system integrity, brute-force attempts, USB threats, and privilege escalation.

use chrono::{DateTime, Utc};
use log::warn;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::fs;
use std::process::Command;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

/// Maximum number of recent alerts retained in the in-memory ring buffer.
pub const ALERT_BUFFER_CAP: usize = 50;

/// Shared ring buffer of the most recent security alerts.
///
/// Populated by the security monitor task on each cycle and read by the
/// dashboard API. A plain `std::sync::Mutex` is sufficient — critical
/// sections are short and never cross an await point.
pub type AlertBuffer = Arc<Mutex<VecDeque<SecurityAlert>>>;

/// Create an empty alert buffer.
pub fn new_alert_buffer() -> AlertBuffer {
    Arc::new(Mutex::new(VecDeque::with_capacity(ALERT_BUFFER_CAP)))
}

/// Append alerts to the ring buffer, evicting the oldest entries to stay
/// within `ALERT_BUFFER_CAP`.
pub fn push_alerts(buffer: &AlertBuffer, alerts: &[SecurityAlert]) {
    if alerts.is_empty() {
        return;
    }
    if let Ok(mut guard) = buffer.lock() {
        for alert in alerts {
            if guard.len() == ALERT_BUFFER_CAP {
                guard.pop_front();
            }
            guard.push_back(alert.clone());
        }
    }
}

/// Snapshot of the most recent alerts, newest last.
pub fn recent_alerts(buffer: &AlertBuffer) -> Vec<SecurityAlert> {
    buffer
        .lock()
        .map(|g| g.iter().cloned().collect())
        .unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

/// Main AI security monitor that holds state across scan cycles.
pub struct SecurityAiDaemon {
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
            high_cpu_tracker: HashMap::new(),
        }
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

                // Previously this flagged every connection to a high port
                // (>10000) where `ss -tnp` could not resolve the process
                // name. On a desktop session that matches dozens of entirely
                // benign flows per cycle (WebRTC, flatpak-sandboxed browsers,
                // per-user daemons ss can't introspect without root). The
                // signal-to-noise ratio was zero: one real mining connection
                // is already caught by MINING_PORTS above, and a proc_name
                // of None simply means "ss lacks permission to read
                // /proc/<pid>/comm", NOT "malicious". Dropping this heuristic
                // wholesale; revisit with a real anomaly model (baseline of
                // expected peers per process) rather than a flat threshold.
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
                        // Filter to REAL integrity violations. rpm -V reports a
                        // 9-column flag string: S.5.....T. where each position
                        // means {S}ize, {M}ode, {5}digest, {D}evice, {L}ink,
                        // {U}ser, {G}roup, {T}ime, ca{P}abilities. On bootc
                        // systems ostree rewrites mtimes on deploy so every
                        // package shows "T"-only changes — that's benign noise.
                        // Config files marked `c` (e.g. /etc/sudoers) are
                        // expected to be edited locally so mode/digest diffs
                        // on them are also not security events.
                        // Real violations for a SECURITY monitor are:
                        //   - digest (5) diff on a non-config file, OR
                        //   - mode (M) diff on a non-config file
                        // Everything else is either expected customization or
                        // bootc-specific mtime rewrites.
                        let real_changes: Vec<String> = stdout
                            .lines()
                            .filter(|line| !line.trim().is_empty())
                            .filter(|line| is_real_rpm_integrity_violation(line))
                            .map(|l| l.to_string())
                            .collect();

                        if !real_changes.is_empty() {
                            alerts.push(SecurityAlert {
                                id: Uuid::new_v4().to_string(),
                                severity: AlertSeverity::Emergency,
                                alert_type: AlertType::IntegrityViolation,
                                description: format!(
                                    "Package '{}' has modified files ({} real changes)",
                                    pkg,
                                    real_changes.len()
                                ),
                                process_name: None,
                                process_pid: None,
                                remote_addr: None,
                                evidence: real_changes,
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

/// Decide whether a `rpm -V` output line represents a REAL integrity
/// violation worth alerting on.
///
/// rpm -V output format: `SM5DLUGTP c /path/to/file`, where each of the
/// first characters is either `.` (matches) or a letter denoting the kind
/// of difference. After the 9 flag characters there's optionally a file
/// attribute marker (`c` = config, `d` = doc, `l` = license, `r` = readme,
/// `g` = ghost), then the path.
///
/// On bootc systems ostree rewrites file mtimes at deploy time so every
/// file in every package shows `.......T.` — mtime-only changes that are
/// purely cosmetic. `/etc/machine-id` is regenerated on first boot
/// (`.M.......`). Config files (the `c` attribute) are expected to be
/// customized by the sysadmin so any change there is not a security event.
///
/// A REAL integrity violation is: a digest (5) or mode (M) change on a
/// non-config file. That's the signature of a tampered binary.
fn is_real_rpm_integrity_violation(line: &str) -> bool {
    // Expect at least "FLAGS ATTR? PATH"
    let trimmed = line.trim_start();
    let mut parts = trimmed.splitn(2, |c: char| c.is_whitespace());
    let flags = match parts.next() {
        Some(f) if f.len() >= 8 => f,
        _ => return false,
    };
    let rest = parts.next().unwrap_or("");

    // If the rest starts with a single attribute letter followed by
    // whitespace, this is a config/doc/license/etc file — skip.
    let mut rest_chars = rest.chars();
    let is_config_like = match (rest_chars.next(), rest_chars.next()) {
        (Some(attr), Some(next)) => matches!(attr, 'c' | 'd' | 'l' | 'r' | 'g') && next == ' ',
        _ => false,
    };
    if is_config_like {
        return false;
    }

    // Flag chars at fixed positions. We only care about digest (pos 2 = '5')
    // and mode (pos 1 = 'M'). Anything else is noise for a security monitor.
    let flag_bytes = flags.as_bytes();
    let has_digest_change = flag_bytes.get(2).copied() == Some(b'5');
    let has_mode_change =
        flag_bytes.first().copied() == Some(b'S') || flag_bytes.get(1).copied() == Some(b'M');
    // Note: pos 0 is 'S' (size). Genuine tampering almost always flips
    // digest, so digest alone is sufficient — mode/size are kept for extra
    // safety on odd edge cases.
    has_digest_change || has_mode_change
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_daemon() {
        let daemon = SecurityAiDaemon::new();
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
