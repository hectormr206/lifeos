//! System monitoring module
//! Collects system metrics and provides health information

use sysinfo::System;
use std::collections::HashMap;

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
    pub network_rx_mb: u64,
    pub network_tx_mb: u64,
    pub load_average: (f64, f64, f64),
    pub uptime_seconds: u64,
    pub process_count: usize,
}

/// System monitor
#[derive(Debug)]
pub struct SystemMonitor {
    system: System,
}

impl SystemMonitor {
    pub fn new() -> Self {
        let mut system = System::new_all();
        system.refresh_all();
        
        Self { system }
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
        
        // Uptime
        let uptime = System::uptime();
        
        // Process count
        let process_count = self.system.processes().len();
        
        Ok(SystemMetrics {
            timestamp: chrono::Local::now(),
            cpu_usage,
            memory_usage,
            memory_used_mb: memory_used / 1024,
            memory_total_mb: memory_total / 1024,
            disk_usage: 0.0,  // Simplified
            disk_used_gb: 0,
            disk_total_gb: 0,
            network_rx_mb: 0,
            network_tx_mb: 0,
            load_average: (0.0, 0.0, 0.0),  // Simplified
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_system_monitor_creation() {
        let _monitor = SystemMonitor::new();
        // Just verify it doesn't panic
        assert!(true);
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
