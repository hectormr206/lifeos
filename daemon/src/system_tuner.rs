//! System Tuner — Fase U: automated sysctl optimization, resource prediction,
//! tuning metrics, and model fine-tuning scheduling.
//!
//! Monitors system performance, benchmarks kernel parameter changes, predicts
//! resource usage patterns, and schedules model fine-tuning during idle hours.

use chrono::{DateTime, Utc};
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

// ---------------------------------------------------------------------------
// 1. System Config Optimizer
// ---------------------------------------------------------------------------

/// Manages sysctl parameter optimization with before/after benchmarking.
pub struct SystemTuner {
    results_dir: PathBuf,
    history: Vec<TuningResult>,
}

/// Result of a single parameter tuning attempt.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TuningResult {
    pub parameter: String,
    pub old_value: String,
    pub new_value: String,
    pub benchmark_before: f64,
    pub benchmark_after: f64,
    pub improvement_pct: f64,
    pub applied: bool,
    pub timestamp: DateTime<Utc>,
}

impl SystemTuner {
    /// Create a new `SystemTuner`, loading history from disk if available.
    pub fn new(results_dir: PathBuf) -> Self {
        let history_path = results_dir.join("tuning-history.json");
        let history = if history_path.exists() {
            match std::fs::read_to_string(&history_path) {
                Ok(data) => serde_json::from_str(&data).unwrap_or_else(|e| {
                    warn!("Failed to parse tuning history: {e}");
                    Vec::new()
                }),
                Err(e) => {
                    warn!("Failed to read tuning history: {e}");
                    Vec::new()
                }
            }
        } else {
            Vec::new()
        };

        Self {
            results_dir,
            history,
        }
    }

    /// Persist current history to disk.
    fn save_history(&self) {
        let path = self.results_dir.join("tuning-history.json");
        if let Err(e) = std::fs::create_dir_all(&self.results_dir) {
            warn!("Cannot create results dir: {e}");
            return;
        }
        match serde_json::to_string_pretty(&self.history) {
            Ok(json) => {
                if let Err(e) = std::fs::write(&path, json) {
                    warn!("Failed to write tuning history: {e}");
                }
            }
            Err(e) => warn!("Failed to serialize tuning history: {e}"),
        }
    }

    /// Read a sysctl parameter from `/proc/sys/…`.
    pub fn read_sysctl(param: &str) -> Result<String, String> {
        let proc_path = format!("/proc/sys/{}", param.replace('.', "/"));
        std::fs::read_to_string(&proc_path)
            .map(|v| v.trim().to_string())
            .map_err(|e| format!("Failed to read {proc_path}: {e}"))
    }

    /// Write a sysctl parameter via `sysctl -w`. Requires root privileges.
    pub fn write_sysctl(param: &str, value: &str) -> Result<(), String> {
        warn!("write_sysctl: attempting to set {param}={value} (requires sudo)");
        let output = std::process::Command::new("sysctl")
            .arg("-w")
            .arg(format!("{param}={value}"))
            .output()
            .map_err(|e| format!("Failed to execute sysctl: {e}"))?;

        if output.status.success() {
            info!("sysctl: set {param}={value}");
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("sysctl -w {param}={value} failed: {stderr}"))
        }
    }

    /// Benchmark sequential I/O throughput (MB/s) using `dd`.
    pub fn benchmark_io() -> Result<f64, String> {
        let output = std::process::Command::new("dd")
            .args([
                "if=/dev/zero",
                "of=/tmp/lifeos-bench",
                "bs=1M",
                "count=256",
                "oflag=dsync",
            ])
            .output()
            .map_err(|e| format!("dd benchmark failed: {e}"))?;

        // dd writes stats to stderr
        let stderr = String::from_utf8_lossy(&output.stderr);

        // Clean up temp file
        let _ = std::fs::remove_file("/tmp/lifeos-bench");

        // Parse patterns like "123 MB/s" or "1.2 GB/s"
        Self::parse_dd_throughput(&stderr)
    }

    /// Parse MB/s from dd stderr output.
    fn parse_dd_throughput(stderr: &str) -> Result<f64, String> {
        // Try "X.Y GB/s"
        if let Some(pos) = stderr.find("GB/s") {
            let before = &stderr[..pos].trim_end();
            if let Some(num_str) = before.rsplit([' ', ',']).next() {
                if let Ok(gb) = num_str.trim().parse::<f64>() {
                    return Ok(gb * 1024.0);
                }
            }
        }
        // Try "X.Y MB/s"
        if let Some(pos) = stderr.find("MB/s") {
            let before = &stderr[..pos].trim_end();
            if let Some(num_str) = before.rsplit([' ', ',']).next() {
                if let Ok(mb) = num_str.trim().parse::<f64>() {
                    return Ok(mb);
                }
            }
        }
        Err(format!("Could not parse dd throughput from: {stderr}"))
    }

    /// Try several `vm.*` sysctl values, benchmark each, keep winners.
    pub fn optimize_vm_settings(&mut self) -> Vec<TuningResult> {
        let mut results = Vec::new();

        let params = [
            ("vm.swappiness", &["10", "30", "60"][..]),
            ("vm.dirty_ratio", &["10", "20", "40"][..]),
            ("vm.dirty_background_ratio", &["5", "10", "20"][..]),
        ];

        for (param, candidates) in &params {
            let old_value = match Self::read_sysctl(param) {
                Ok(v) => v,
                Err(e) => {
                    warn!("Skipping {param}: {e}");
                    continue;
                }
            };

            let baseline = match Self::benchmark_io() {
                Ok(v) => v,
                Err(e) => {
                    warn!("Baseline benchmark failed for {param}: {e}");
                    continue;
                }
            };

            let mut best_value = old_value.clone();
            let mut best_score = baseline;

            for &candidate in *candidates {
                if candidate == old_value {
                    continue;
                }
                if let Err(e) = Self::write_sysctl(param, candidate) {
                    warn!("Could not test {param}={candidate}: {e}");
                    continue;
                }

                if let Ok(score) = Self::benchmark_io() {
                    if score > best_score {
                        best_score = score;
                        best_value = candidate.to_string();
                    }
                }

                // Restore original while testing others
                let _ = Self::write_sysctl(param, &old_value);
            }

            let applied = best_value != old_value;
            if applied {
                let _ = Self::write_sysctl(param, &best_value);
            }

            let improvement_pct = if baseline > 0.0 {
                ((best_score - baseline) / baseline) * 100.0
            } else {
                0.0
            };

            let result = TuningResult {
                parameter: param.to_string(),
                old_value,
                new_value: best_value,
                benchmark_before: baseline,
                benchmark_after: best_score,
                improvement_pct,
                applied,
                timestamp: Utc::now(),
            };
            results.push(result.clone());
            self.history.push(result);
        }

        self.save_history();
        results
    }

    /// Human-readable summary of all improvements applied so far.
    pub fn get_improvement_summary(&self) -> String {
        if self.history.is_empty() {
            return "No tuning results recorded yet.".to_string();
        }

        let applied: Vec<&TuningResult> = self.history.iter().filter(|r| r.applied).collect();
        let total = self.history.len();
        let improved = applied.len();

        let mut summary =
            format!("System Tuning Summary: {improved}/{total} parameters improved.\n");

        for r in &applied {
            summary.push_str(&format!(
                "  - {}: {} -> {} ({:+.1}% at {})\n",
                r.parameter,
                r.old_value,
                r.new_value,
                r.improvement_pct,
                r.timestamp.format("%Y-%m-%d %H:%M"),
            ));
        }

        if applied.is_empty() {
            summary.push_str("  (all parameters were already optimal)\n");
        }

        summary
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_dd_throughput_mb() {
        let stderr = "268435456 bytes (268 MB, 256 MiB) copied, 1.23 s, 218 MB/s\n";
        let result = SystemTuner::parse_dd_throughput(stderr).unwrap();
        assert!((result - 218.0).abs() < 0.1);
    }

    #[test]
    fn test_parse_dd_throughput_gb() {
        let stderr = "268435456 bytes copied, 0.12 s, 2.1 GB/s\n";
        let result = SystemTuner::parse_dd_throughput(stderr).unwrap();
        assert!((result - 2150.4).abs() < 1.0);
    }

    #[test]
    fn test_improvement_summary_empty() {
        let dir = std::env::temp_dir().join("lifeos-test-summary");
        let tuner = SystemTuner::new(dir);
        assert!(tuner
            .get_improvement_summary()
            .contains("No tuning results"));
    }

    #[test]
    fn test_improvement_summary_with_results() {
        let dir = std::env::temp_dir().join("lifeos-test-summary-2");
        let mut tuner = SystemTuner::new(dir);
        tuner.history.push(TuningResult {
            parameter: "vm.swappiness".to_string(),
            old_value: "60".to_string(),
            new_value: "10".to_string(),
            benchmark_before: 100.0,
            benchmark_after: 115.0,
            improvement_pct: 15.0,
            applied: true,
            timestamp: Utc::now(),
        });
        let summary = tuner.get_improvement_summary();
        assert!(summary.contains("1/1 parameters improved"));
        assert!(summary.contains("vm.swappiness"));
    }
}
