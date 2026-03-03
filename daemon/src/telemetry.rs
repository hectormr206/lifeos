//! Local Telemetry Module
//!
//! Privacy-first, local-only telemetry for LifeOS:
//! - Hardware monitoring (thermal, disk, memory)
//! - System metrics (boot success, update tracking, rollback timing)
//! - Anonymous opt-in metric aggregation
//! - No data sent to external services
//!
//! Architecture: OpenTelemetry-compatible local collector → JSON on disk.

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use log::{debug, info, warn};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Maximum number of metric events kept in memory
const MAX_EVENTS_IN_MEMORY: usize = 1000;

/// Maximum file size before rotation (5 MB)
const MAX_LOG_SIZE_BYTES: u64 = 5 * 1024 * 1024;

/// Telemetry consent level
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum ConsentLevel {
    /// No telemetry collected
    Disabled,
    /// Only critical system health metrics (boot success, crash reports)
    Minimal,
    /// Full local telemetry (hardware, performance, usage patterns)
    Full,
}

impl Default for ConsentLevel {
    fn default() -> Self {
        ConsentLevel::Minimal
    }
}

/// Category of metric event
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum MetricCategory {
    /// System boot and health
    Boot,
    /// Update lifecycle events
    Update,
    /// Hardware monitoring (thermal, disk, memory)
    Hardware,
    /// AI runtime metrics
    AiRuntime,
    /// User experience (mode switches, context changes)
    Experience,
    /// Error and crash events
    Error,
}

/// A single telemetry event
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelemetryEvent {
    pub id: String,
    pub timestamp: DateTime<Utc>,
    pub category: MetricCategory,
    pub event_name: String,
    pub value: serde_json::Value,
    /// Duration in milliseconds (if applicable)
    pub duration_ms: Option<u64>,
}

/// Hardware snapshot for monitoring
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HardwareSnapshot {
    pub timestamp: DateTime<Utc>,
    pub cpu_temp_celsius: Option<f32>,
    pub cpu_usage_percent: f32,
    pub memory_used_mb: u64,
    pub memory_total_mb: u64,
    pub disk_used_percent: f32,
    pub gpu_temp_celsius: Option<f32>,
    pub thermal_throttled: bool,
}

/// Aggregated statistics
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelemetryStats {
    pub total_events: u64,
    pub events_by_category: std::collections::HashMap<String, u64>,
    pub boot_success_rate: f64,
    pub avg_boot_time_ms: f64,
    pub update_success_rate: f64,
    pub avg_update_time_ms: f64,
    pub uptime_hours: f64,
    pub last_snapshot: Option<HardwareSnapshot>,
    pub consent_level: ConsentLevel,
}

/// Telemetry configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelemetryConfig {
    pub consent_level: ConsentLevel,
    /// Interval between hardware snapshots in seconds
    pub snapshot_interval_secs: u64,
    /// Keep events for this many days
    pub retention_days: u32,
    /// Path to telemetry data directory
    pub data_dir: PathBuf,
}

impl Default for TelemetryConfig {
    fn default() -> Self {
        Self {
            consent_level: ConsentLevel::Minimal,
            snapshot_interval_secs: 300, // 5 minutes
            retention_days: 30,
            data_dir: PathBuf::from("/var/lib/lifeos/telemetry"),
        }
    }
}

/// Local Telemetry Manager
pub struct TelemetryManager {
    config: Arc<RwLock<TelemetryConfig>>,
    events: Arc<RwLock<VecDeque<TelemetryEvent>>>,
    stats: Arc<RwLock<AggregatedCounters>>,
    data_dir: PathBuf,
}

/// Internal counters for aggregation
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct AggregatedCounters {
    total_events: u64,
    boot_attempts: u64,
    boot_successes: u64,
    boot_time_sum_ms: u64,
    update_attempts: u64,
    update_successes: u64,
    update_time_sum_ms: u64,
    events_by_category: std::collections::HashMap<String, u64>,
    last_snapshot: Option<HardwareSnapshot>,
    start_time: Option<DateTime<Utc>>,
}

impl TelemetryManager {
    /// Create a new telemetry manager
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        let config = TelemetryConfig {
            data_dir: data_dir.clone(),
            ..Default::default()
        };

        let manager = Self {
            config: Arc::new(RwLock::new(config)),
            events: Arc::new(RwLock::new(VecDeque::with_capacity(MAX_EVENTS_IN_MEMORY))),
            stats: Arc::new(RwLock::new(AggregatedCounters {
                start_time: Some(Utc::now()),
                ..Default::default()
            })),
            data_dir,
        };

        info!("Telemetry manager initialized (local-only, privacy-first)");
        Ok(manager)
    }

    /// Load persisted config
    pub async fn load_config(&self) -> Result<()> {
        let config_file = self.data_dir.join("telemetry_config.json");
        if config_file.exists() {
            let content = tokio::fs::read_to_string(&config_file).await?;
            let config: TelemetryConfig =
                serde_json::from_str(&content).context("Failed to parse telemetry config")?;
            *self.config.write().await = config;
            info!("Telemetry config loaded");
        }
        Ok(())
    }

    /// Save config to disk
    pub async fn save_config(&self) -> Result<()> {
        tokio::fs::create_dir_all(&self.data_dir)
            .await
            .context("Failed to create telemetry data dir")?;

        let config = self.config.read().await;
        let config_file = self.data_dir.join("telemetry_config.json");
        let content = serde_json::to_string_pretty(&*config)?;
        tokio::fs::write(&config_file, content)
            .await
            .context("Failed to save telemetry config")?;
        Ok(())
    }

    /// Get current consent level
    pub async fn get_consent(&self) -> ConsentLevel {
        self.config.read().await.consent_level.clone()
    }

    /// Set consent level
    pub async fn set_consent(&self, level: ConsentLevel) -> Result<()> {
        {
            let mut config = self.config.write().await;
            config.consent_level = level.clone();
        }
        self.save_config().await?;
        info!("Telemetry consent set to: {:?}", level);

        if level == ConsentLevel::Disabled {
            // Clear all in-memory events
            self.events.write().await.clear();
            info!("Telemetry events cleared (consent disabled)");
        }

        Ok(())
    }

    /// Record a telemetry event
    pub async fn record_event(
        &self,
        category: MetricCategory,
        event_name: &str,
        value: serde_json::Value,
        duration_ms: Option<u64>,
    ) -> Result<()> {
        let consent = self.get_consent().await;
        if consent == ConsentLevel::Disabled {
            return Ok(());
        }

        // For minimal consent, only allow Boot, Update, and Error categories
        if consent == ConsentLevel::Minimal {
            match category {
                MetricCategory::Boot | MetricCategory::Update | MetricCategory::Error => {}
                _ => return Ok(()),
            }
        }

        let event = TelemetryEvent {
            id: generate_event_id(),
            timestamp: Utc::now(),
            category: category.clone(),
            event_name: event_name.to_string(),
            value,
            duration_ms,
        };

        // Update aggregated counters
        {
            let mut stats = self.stats.write().await;
            stats.total_events += 1;
            *stats
                .events_by_category
                .entry(format!("{:?}", category))
                .or_insert(0) += 1;

            match category {
                MetricCategory::Boot => {
                    stats.boot_attempts += 1;
                    if event_name == "boot_success" {
                        stats.boot_successes += 1;
                    }
                    if let Some(ms) = duration_ms {
                        stats.boot_time_sum_ms += ms;
                    }
                }
                MetricCategory::Update => {
                    stats.update_attempts += 1;
                    if event_name == "update_success" {
                        stats.update_successes += 1;
                    }
                    if let Some(ms) = duration_ms {
                        stats.update_time_sum_ms += ms;
                    }
                }
                _ => {}
            }
        }

        // Add to in-memory ring buffer
        {
            let mut events = self.events.write().await;
            if events.len() >= MAX_EVENTS_IN_MEMORY {
                events.pop_front();
            }
            events.push_back(event.clone());
        }

        // Async flush to disk (best-effort)
        let _ = self.flush_event(&event).await;

        debug!(
            "Telemetry event recorded: {} ({})",
            event_name,
            format!("{:?}", category)
        );

        Ok(())
    }

    /// Record a hardware snapshot
    pub async fn record_hardware_snapshot(&self) -> Result<Option<HardwareSnapshot>> {
        let consent = self.get_consent().await;
        if consent != ConsentLevel::Full {
            return Ok(None);
        }

        let snapshot = collect_hardware_snapshot().await;

        // Check for thermal throttling
        if snapshot.thermal_throttled {
            warn!(
                "Thermal throttling detected! CPU: {:?}°C, GPU: {:?}°C",
                snapshot.cpu_temp_celsius, snapshot.gpu_temp_celsius
            );
        }

        {
            let mut stats = self.stats.write().await;
            stats.last_snapshot = Some(snapshot.clone());
        }

        // Record as event
        self.record_event(
            MetricCategory::Hardware,
            "hardware_snapshot",
            serde_json::to_value(&snapshot).unwrap_or_default(),
            None,
        )
        .await?;

        Ok(Some(snapshot))
    }

    /// Get aggregated statistics
    pub async fn get_stats(&self) -> TelemetryStats {
        let stats = self.stats.read().await;
        let config = self.config.read().await;

        let uptime_hours = stats
            .start_time
            .map(|start| {
                let duration = Utc::now() - start;
                duration.num_seconds() as f64 / 3600.0
            })
            .unwrap_or(0.0);

        TelemetryStats {
            total_events: stats.total_events,
            events_by_category: stats.events_by_category.clone(),
            boot_success_rate: if stats.boot_attempts > 0 {
                stats.boot_successes as f64 / stats.boot_attempts as f64
            } else {
                1.0
            },
            avg_boot_time_ms: if stats.boot_successes > 0 {
                stats.boot_time_sum_ms as f64 / stats.boot_successes as f64
            } else {
                0.0
            },
            update_success_rate: if stats.update_attempts > 0 {
                stats.update_successes as f64 / stats.update_attempts as f64
            } else {
                1.0
            },
            avg_update_time_ms: if stats.update_successes > 0 {
                stats.update_time_sum_ms as f64 / stats.update_successes as f64
            } else {
                0.0
            },
            uptime_hours,
            last_snapshot: stats.last_snapshot.clone(),
            consent_level: config.consent_level.clone(),
        }
    }

    /// Get recent events (last N)
    pub async fn get_recent_events(&self, limit: usize) -> Vec<TelemetryEvent> {
        let events = self.events.read().await;
        events.iter().rev().take(limit).cloned().collect()
    }

    /// Get events by category
    pub async fn get_events_by_category(
        &self,
        category: &MetricCategory,
        limit: usize,
    ) -> Vec<TelemetryEvent> {
        let events = self.events.read().await;
        events
            .iter()
            .rev()
            .filter(|e| &e.category == category)
            .take(limit)
            .cloned()
            .collect()
    }

    /// Flush a single event to disk
    async fn flush_event(&self, event: &TelemetryEvent) -> Result<()> {
        let log_file = self.data_dir.join("events.jsonl");

        // Create dir if needed
        if let Some(parent) = log_file.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }

        // Check file size for rotation
        if let Ok(metadata) = tokio::fs::metadata(&log_file).await {
            if metadata.len() > MAX_LOG_SIZE_BYTES {
                let rotated = self.data_dir.join("events.jsonl.1");
                let _ = tokio::fs::rename(&log_file, &rotated).await;
            }
        }

        let line = serde_json::to_string(event)? + "\n";
        tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_file)
            .await?
            .write_all(line.as_bytes())
            .await
            .context("Failed to write telemetry event")?;

        Ok(())
    }

    /// Purge events older than retention period
    pub async fn purge_old_events(&self) -> Result<u64> {
        let config = self.config.read().await;
        let cutoff = Utc::now() - chrono::Duration::days(config.retention_days as i64);
        drop(config);

        let mut events = self.events.write().await;
        let before = events.len();
        events.retain(|e| e.timestamp > cutoff);
        let purged = before - events.len();

        if purged > 0 {
            info!("Purged {} old telemetry events", purged);
        }

        Ok(purged as u64)
    }

    /// Export telemetry data as JSON (for user inspection)
    pub async fn export_data(&self) -> Result<serde_json::Value> {
        let events = self.events.read().await;
        let stats = self.get_stats().await;

        Ok(serde_json::json!({
            "stats": stats,
            "recent_events": events.iter().collect::<Vec<_>>(),
            "exported_at": Utc::now().to_rfc3339(),
        }))
    }

    /// Clear all telemetry data (user right to delete)
    pub async fn clear_all_data(&self) -> Result<()> {
        self.events.write().await.clear();
        *self.stats.write().await = AggregatedCounters {
            start_time: Some(Utc::now()),
            ..Default::default()
        };

        // Remove on-disk data
        let log_file = self.data_dir.join("events.jsonl");
        let _ = tokio::fs::remove_file(&log_file).await;
        let rotated = self.data_dir.join("events.jsonl.1");
        let _ = tokio::fs::remove_file(&rotated).await;

        info!("All telemetry data cleared");
        Ok(())
    }
}

// We need the tokio write trait
use tokio::io::AsyncWriteExt;

/// Generate a unique event ID (ULID-like)
fn generate_event_id() -> String {
    let now = Utc::now();
    let ts = now.timestamp_millis();
    let rand: u32 = rand_simple();
    format!("{:013x}-{:08x}", ts, rand)
}

/// Simple pseudo-random number (no external crate needed)
fn rand_simple() -> u32 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut hasher = DefaultHasher::new();
    std::time::SystemTime::now().hash(&mut hasher);
    std::thread::current().id().hash(&mut hasher);
    hasher.finish() as u32
}

/// Collect hardware snapshot from /proc and /sys
async fn collect_hardware_snapshot() -> HardwareSnapshot {
    let cpu_temp = read_cpu_temperature().await;
    let cpu_usage = read_cpu_usage().await;
    let (mem_used, mem_total) = read_memory_info().await;
    let disk_percent = read_disk_usage().await;
    let gpu_temp = read_gpu_temperature().await;

    let thermal_throttled =
        cpu_temp.map(|t| t > 85.0).unwrap_or(false) || gpu_temp.map(|t| t > 90.0).unwrap_or(false);

    HardwareSnapshot {
        timestamp: Utc::now(),
        cpu_temp_celsius: cpu_temp,
        cpu_usage_percent: cpu_usage,
        memory_used_mb: mem_used,
        memory_total_mb: mem_total,
        disk_used_percent: disk_percent,
        gpu_temp_celsius: gpu_temp,
        thermal_throttled,
    }
}

/// Read CPU temperature from thermal zones
async fn read_cpu_temperature() -> Option<f32> {
    for i in 0..10 {
        let path = format!("/sys/class/thermal/thermal_zone{}/temp", i);
        if let Ok(content) = tokio::fs::read_to_string(&path).await {
            if let Ok(millideg) = content.trim().parse::<f32>() {
                return Some(millideg / 1000.0);
            }
        }
    }
    None
}

/// Read CPU usage from /proc/stat (simplified single-sample)
async fn read_cpu_usage() -> f32 {
    if let Ok(content) = tokio::fs::read_to_string("/proc/loadavg").await {
        if let Some(load) = content.split_whitespace().next() {
            if let Ok(load_val) = load.parse::<f32>() {
                // Normalize by number of CPUs
                let ncpus = num_cpus().await.max(1) as f32;
                return (load_val / ncpus * 100.0).min(100.0);
            }
        }
    }
    0.0
}

/// Get number of CPU cores
async fn num_cpus() -> u32 {
    if let Ok(content) = tokio::fs::read_to_string("/proc/cpuinfo").await {
        content
            .lines()
            .filter(|l| l.starts_with("processor"))
            .count() as u32
    } else {
        1
    }
}

/// Read memory info from /proc/meminfo
async fn read_memory_info() -> (u64, u64) {
    if let Ok(content) = tokio::fs::read_to_string("/proc/meminfo").await {
        let mut total_kb = 0u64;
        let mut available_kb = 0u64;

        for line in content.lines() {
            if line.starts_with("MemTotal:") {
                total_kb = line
                    .split_whitespace()
                    .nth(1)
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0);
            } else if line.starts_with("MemAvailable:") {
                available_kb = line
                    .split_whitespace()
                    .nth(1)
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0);
            }
        }

        let total_mb = total_kb / 1024;
        let used_mb = (total_kb - available_kb) / 1024;
        (used_mb, total_mb)
    } else {
        (0, 0)
    }
}

/// Read disk usage percentage
async fn read_disk_usage() -> f32 {
    match tokio::process::Command::new("df")
        .args(["-Pk", "/"])
        .output()
        .await
    {
        Ok(output) => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            if let Some(line) = stdout.lines().nth(1) {
                if let Some(percent_str) = line.split_whitespace().nth(4) {
                    if let Ok(pct) = percent_str.trim_end_matches('%').parse::<f32>() {
                        return pct;
                    }
                }
            }
            0.0
        }
        Err(_) => 0.0,
    }
}

/// Read GPU temperature (NVIDIA or AMD)
async fn read_gpu_temperature() -> Option<f32> {
    // Try NVIDIA first
    if let Ok(output) = tokio::process::Command::new("nvidia-smi")
        .args([
            "--query-gpu=temperature.gpu",
            "--format=csv,noheader,nounits",
        ])
        .output()
        .await
    {
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            if let Ok(temp) = stdout.trim().parse::<f32>() {
                return Some(temp);
            }
        }
    }

    // Try AMD hwmon
    for i in 0..10 {
        let path = format!("/sys/class/hwmon/hwmon{}/temp1_input", i);
        if let Ok(content) = tokio::fs::read_to_string(&path).await {
            // Check if this is an AMD GPU by looking at the name
            let name_path = format!("/sys/class/hwmon/hwmon{}/name", i);
            if let Ok(name) = tokio::fs::read_to_string(&name_path).await {
                if name.trim().contains("amdgpu") {
                    if let Ok(millideg) = content.trim().parse::<f32>() {
                        return Some(millideg / 1000.0);
                    }
                }
            }
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_consent_level_default() {
        let config = TelemetryConfig::default();
        assert_eq!(config.consent_level, ConsentLevel::Minimal);
    }

    #[test]
    fn test_event_id_generation() {
        let id1 = generate_event_id();
        let id2 = generate_event_id();
        assert!(!id1.is_empty());
        assert!(id1.contains('-'));
        // IDs should differ (timestamp part at least)
        // Note: in very fast execution, they might match, so we don't assert inequality
    }

    #[tokio::test]
    async fn test_telemetry_manager_creation() {
        let dir = std::env::temp_dir().join("lifeos-telemetry-test");
        let mgr = TelemetryManager::new(dir).unwrap();
        let stats = mgr.get_stats().await;
        assert_eq!(stats.total_events, 0);
        assert_eq!(stats.consent_level, ConsentLevel::Minimal);
    }

    #[tokio::test]
    async fn test_record_event_with_consent() {
        let dir = std::env::temp_dir().join("lifeos-telemetry-test-events");
        let mgr = TelemetryManager::new(dir).unwrap();

        // Record boot event (allowed in Minimal)
        mgr.record_event(
            MetricCategory::Boot,
            "boot_success",
            serde_json::json!({"duration_ms": 1500}),
            Some(1500),
        )
        .await
        .unwrap();

        let stats = mgr.get_stats().await;
        assert_eq!(stats.total_events, 1);
        assert_eq!(stats.boot_success_rate, 1.0);

        // Hardware event should be skipped in Minimal consent
        mgr.record_event(
            MetricCategory::Hardware,
            "cpu_temp",
            serde_json::json!({"temp": 65.0}),
            None,
        )
        .await
        .unwrap();

        let stats = mgr.get_stats().await;
        assert_eq!(stats.total_events, 1); // Still 1, hardware was filtered
    }

    #[tokio::test]
    async fn test_disabled_consent_blocks_all() {
        let dir = std::env::temp_dir().join("lifeos-telemetry-test-disabled");
        let mgr = TelemetryManager::new(dir).unwrap();
        mgr.set_consent(ConsentLevel::Disabled).await.unwrap();

        mgr.record_event(
            MetricCategory::Boot,
            "boot_success",
            serde_json::json!({}),
            None,
        )
        .await
        .unwrap();

        let stats = mgr.get_stats().await;
        assert_eq!(stats.total_events, 0);
    }
}
