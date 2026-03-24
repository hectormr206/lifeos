//! System monitoring module
//! Collects system metrics and provides health information

use std::time::Instant;
use sysinfo::System;

/// System metrics snapshot
#[derive(Debug, Clone)]
pub struct SystemMetrics {
    pub timestamp: chrono::DateTime<chrono::Local>,
    pub cpu_usage: f32,
    pub memory_usage: f32,
    pub memory_used_mb: u64,
    pub memory_total_mb: u64,
    pub disk_usage: f32,
    pub disk_used_gb: u64,
    pub disk_total_gb: u64,
    pub network_rx_mbps: f32,
    pub network_tx_mbps: f32,
    pub load_average: (f64, f64, f64),
    pub uptime_seconds: u64,
    pub process_count: usize,
}

/// System monitor
#[derive(Debug)]
pub struct SystemMonitor {
    system: System,
    last_network_sample: Option<NetworkSample>,
}

#[derive(Debug, Clone, Copy)]
struct NetworkSample {
    rx_bytes: u64,
    tx_bytes: u64,
    at: Instant,
}

impl SystemMonitor {
    pub fn new() -> Self {
        let mut system = System::new_all();
        system.refresh_all();

        Self {
            system,
            last_network_sample: None,
        }
    }

    /// Collect current system metrics
    pub fn collect_metrics(&mut self) -> anyhow::Result<SystemMetrics> {
        // Refresh system information
        self.system.refresh_all();

        // CPU usage (global)
        let cpu_usage = self.system.global_cpu_info().cpu_usage();

        // Memory usage
        let memory_used = self.system.used_memory();
        let memory_total = self.system.total_memory();
        let memory_usage = if memory_total > 0 {
            (memory_used as f32 / memory_total as f32) * 100.0
        } else {
            0.0
        };

        let (disk_used_gb, disk_total_gb, disk_usage) = read_disk_usage().unwrap_or((0, 0, 0.0));

        let (network_rx_mbps, network_tx_mbps) = self.read_network_rates().unwrap_or((0.0, 0.0));

        let load = System::load_average();

        // Uptime
        let uptime = System::uptime();

        // Process count
        let process_count = self.system.processes().len();

        Ok(SystemMetrics {
            timestamp: chrono::Local::now(),
            cpu_usage,
            memory_usage,
            memory_used_mb: memory_used / (1024 * 1024),
            memory_total_mb: memory_total / (1024 * 1024),
            disk_usage,
            disk_used_gb,
            disk_total_gb,
            network_rx_mbps,
            network_tx_mbps,
            load_average: (load.one, load.five, load.fifteen),
            uptime_seconds: uptime,
            process_count,
        })
    }

    /// Check if system is healthy
    pub fn is_healthy(&mut self) -> anyhow::Result<bool> {
        let metrics = self.collect_metrics()?;

        // Health thresholds
        let cpu_ok = metrics.cpu_usage < 90.0;
        let memory_ok = metrics.memory_usage < 95.0;

        Ok(cpu_ok && memory_ok)
    }

    fn read_network_rates(&mut self) -> anyhow::Result<(f32, f32)> {
        let (rx_bytes, tx_bytes) = read_network_totals()?;
        let now = Instant::now();

        if let Some(prev) = self.last_network_sample {
            let elapsed = now.duration_since(prev.at).as_secs_f32();
            self.last_network_sample = Some(NetworkSample {
                rx_bytes,
                tx_bytes,
                at: now,
            });

            if elapsed <= 0.0 {
                return Ok((0.0, 0.0));
            }

            let rx_delta = rx_bytes.saturating_sub(prev.rx_bytes) as f32;
            let tx_delta = tx_bytes.saturating_sub(prev.tx_bytes) as f32;
            let rx_mbps = (rx_delta * 8.0) / (elapsed * 1_000_000.0);
            let tx_mbps = (tx_delta * 8.0) / (elapsed * 1_000_000.0);
            Ok((rx_mbps, tx_mbps))
        } else {
            self.last_network_sample = Some(NetworkSample {
                rx_bytes,
                tx_bytes,
                at: now,
            });
            Ok((0.0, 0.0))
        }
    }
}

impl Default for SystemMonitor {
    fn default() -> Self {
        Self::new()
    }
}

fn read_disk_usage() -> anyhow::Result<(u64, u64, f32)> {
    // On bootc/composefs systems, `/` is an immutable composefs view that often
    // reports 100% usage. `/var` reflects the real mutable storage users care about.
    let output = std::process::Command::new("df")
        .args(["-Pk", "/var"])
        .output()?;
    if !output.status.success() {
        anyhow::bail!("df command failed");
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout
        .lines()
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("Unable to parse df output"))?;
    let cols: Vec<&str> = line.split_whitespace().collect();
    if cols.len() < 6 {
        anyhow::bail!("Unexpected df output");
    }

    let total_kb: u64 = cols[1].parse()?;
    let used_kb: u64 = cols[2].parse()?;
    let used_percent = if total_kb == 0 {
        0.0
    } else {
        (used_kb as f32 / total_kb as f32) * 100.0
    };

    Ok((used_kb / 1024 / 1024, total_kb / 1024 / 1024, used_percent))
}

fn read_network_totals() -> anyhow::Result<(u64, u64)> {
    let content = std::fs::read_to_string("/proc/net/dev")?;
    let mut rx_total = 0u64;
    let mut tx_total = 0u64;

    for line in content.lines().skip(2) {
        let parts: Vec<&str> = line
            .split(|c: char| c.is_whitespace() || c == ':')
            .filter(|p| !p.is_empty())
            .collect();
        if parts.len() < 10 {
            continue;
        }
        rx_total = rx_total.saturating_add(parts[1].parse::<u64>().unwrap_or(0));
        tx_total = tx_total.saturating_add(parts[9].parse::<u64>().unwrap_or(0));
    }

    Ok((rx_total, tx_total))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_system_monitor_creation() {
        let mut monitor = SystemMonitor::new();
        assert!(monitor.collect_metrics().is_ok());
    }

    #[test]
    fn test_collect_metrics() {
        let mut monitor = SystemMonitor::new();
        let metrics = monitor.collect_metrics().unwrap();

        // Verify basic structure
        assert!(metrics.memory_total_mb > 0);
        assert!(metrics.timestamp.timestamp() > 0);
    }
}
