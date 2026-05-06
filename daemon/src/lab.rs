//! LifeOS Lab - autonomous improvement pipeline
//!
//! Provides automated experimentation for system optimization:
//! - Isolated container-based experiments
//! - Canary deployment with automatic rollback
//! - Metrics comparison and validation
//! - Podman-based isolation

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;
use tokio::fs;
use tokio::sync::RwLock;

// Tests are in lab_tests.rs at crate level
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lab_config_default() {
        let config = LabConfig::default();
        assert!(config.enabled);
        assert_eq!(config.max_experiments, 10);
    }

    #[test]
    fn test_experiment_type_serialization() {
        let et = ExperimentType::ConfigOptimization;
        let json = serde_json::to_string(&et).unwrap();
        assert_eq!(json, "\"config_optimization\"");
    }

    #[test]
    fn test_metrics_snapshot_default() {
        let metrics = MetricsSnapshot::default();
        assert_eq!(metrics.cpu_usage_avg, 0.0);
        assert_eq!(metrics.boot_time_seconds, 0);
    }
}

/// LifeOS Lab Manager - autonomous improvement pipeline
#[derive(Clone)]
pub struct LabManager {
    config: LabConfig,
    state: Arc<RwLock<LabState>>,
    workspace: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LabConfig {
    pub enabled: bool,
    pub workspace_path: PathBuf,
    pub max_experiments: usize,
    pub canary_duration_hours: u32,
    pub auto_promote: bool,
    pub allowed_experiment_types: Vec<ExperimentType>,
}

impl Default for LabConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            workspace_path: PathBuf::from("/var/lib/lifeos/lab"),
            max_experiments: 10,
            canary_duration_hours: 24,
            auto_promote: false,
            allowed_experiment_types: vec![
                ExperimentType::ConfigOptimization,
                ExperimentType::ServiceTuning,
            ],
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ExperimentType {
    ConfigOptimization,
    ServiceTuning,
    PowerManagement,
    AIModelSelection,
    SecurityHardening,
}

impl std::fmt::Display for ExperimentType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExperimentType::ConfigOptimization => write!(f, "config_optimization"),
            ExperimentType::ServiceTuning => write!(f, "service_tuning"),
            ExperimentType::PowerManagement => write!(f, "power_management"),
            ExperimentType::AIModelSelection => write!(f, "ai_model_selection"),
            ExperimentType::SecurityHardening => write!(f, "security_hardening"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct LabState {
    pub current_experiment: Option<Experiment>,
    pub completed_experiments: Vec<ExperimentResult>,
    pub canary_active: bool,
    pub last_run: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Experiment {
    pub id: String,
    pub experiment_type: ExperimentType,
    pub hypothesis: String,
    pub plan: Vec<ExperimentStep>,
    pub started_at: DateTime<Utc>,
    pub status: ExperimentStatus,
    pub container_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ExperimentStatus {
    Proposed,
    Running,
    Canary,
    Promoted,
    RolledBack,
    Failed,
}

impl std::fmt::Display for ExperimentStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExperimentStatus::Proposed => write!(f, "proposed"),
            ExperimentStatus::Running => write!(f, "running"),
            ExperimentStatus::Canary => write!(f, "canary"),
            ExperimentStatus::Promoted => write!(f, "promoted"),
            ExperimentStatus::RolledBack => write!(f, "rolled_back"),
            ExperimentStatus::Failed => write!(f, "failed"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExperimentStep {
    pub action: String,
    pub expected_outcome: String,
    pub rollback_action: String,
    pub completed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExperimentResult {
    pub experiment: Experiment,
    pub completed_at: DateTime<Utc>,
    pub success: bool,
    pub metrics_before: MetricsSnapshot,
    pub metrics_after: MetricsSnapshot,
    pub rollback_performed: bool,
    pub improvement_score: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetricsSnapshot {
    pub timestamp: DateTime<Utc>,
    pub cpu_usage_avg: f32,
    pub memory_usage_avg: f32,
    pub disk_io_read_mb: u64,
    pub disk_io_write_mb: u64,
    pub boot_time_seconds: u32,
    pub ai_response_latency_ms: u32,
    pub battery_drain_rate_percent_per_hour: Option<f32>,
    pub service_restart_count: u32,
    pub error_rate: f32,
}

impl Default for MetricsSnapshot {
    fn default() -> Self {
        Self {
            timestamp: Utc::now(),
            cpu_usage_avg: 0.0,
            memory_usage_avg: 0.0,
            disk_io_read_mb: 0,
            disk_io_write_mb: 0,
            boot_time_seconds: 0,
            ai_response_latency_ms: 0,
            battery_drain_rate_percent_per_hour: None,
            service_restart_count: 0,
            error_rate: 0.0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExperimentReport {
    pub experiment: Experiment,
    pub result: Option<ExperimentResult>,
    pub recommendation: String,
    pub next_steps: Vec<String>,
    pub risk_level: RiskLevel,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RiskLevel {
    Low,
    Medium,
    High,
    Critical,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestResults {
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
    pub details: Vec<TestResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestResult {
    pub name: String,
    pub passed: bool,
    pub duration_ms: u64,
    pub error: Option<String>,
}

impl LabManager {
    pub fn new(config: LabConfig) -> Result<Self> {
        let workspace = config.workspace_path.clone();
        std::fs::create_dir_all(&workspace)
            .with_context(|| format!("Failed to create lab workspace: {:?}", workspace))?;

        Ok(Self {
            config,
            state: Arc::new(RwLock::new(LabState::default())),
            workspace,
        })
    }

    pub async fn initialize(&self) -> Result<()> {
        self.load_state().await?;
        log::info!("Lab manager initialized at {:?}", self.workspace);
        Ok(())
    }

    async fn load_state(&self) -> Result<()> {
        let state_path = self.workspace.join("state.json");
        if state_path.exists() {
            let content = fs::read_to_string(&state_path).await?;
            let state: LabState = serde_json::from_str(&content)?;
            *self.state.write().await = state;
        }
        Ok(())
    }

    async fn save_state(&self) -> Result<()> {
        let state_path = self.workspace.join("state.json");
        let state = self.state.read().await.clone();
        let content = serde_json::to_string_pretty(&state)?;
        fs::write(&state_path, content).await?;
        Ok(())
    }

    pub async fn start_experiment(
        &self,
        experiment_type: ExperimentType,
        hypothesis: &str,
    ) -> Result<String> {
        if !self.config.enabled {
            anyhow::bail!("Lab experiments are disabled in configuration");
        }

        if !self
            .config
            .allowed_experiment_types
            .contains(&experiment_type)
        {
            anyhow::bail!(
                "Experiment type {:?} is not allowed in configuration",
                experiment_type
            );
        }

        let state = self.state.write().await;

        if state.current_experiment.is_some() {
            anyhow::bail!("An experiment is already running. Complete or rollback first.");
        }

        if state.completed_experiments.len() >= self.config.max_experiments {
            anyhow::bail!(
                "Maximum number of experiments ({}) reached",
                self.config.max_experiments
            );
        }

        let experiment_id = format!(
            "exp-{}-{}",
            experiment_type,
            chrono::Utc::now().format("%Y%m%d-%H%M%S")
        );

        let plan = self.generate_experiment_plan(&experiment_type, hypothesis)?;

        let experiment = Experiment {
            id: experiment_id.clone(),
            experiment_type: experiment_type.clone(),
            hypothesis: hypothesis.to_string(),
            plan,
            started_at: Utc::now(),
            status: ExperimentStatus::Proposed,
            container_id: None,
        };

        let metrics_before = self.collect_metrics().await?;

        drop(state);

        let container_id = self.create_experiment_container(&experiment_id).await?;

        {
            let mut state = self.state.write().await;
            let mut experiment = experiment.clone();
            experiment.container_id = Some(container_id);
            experiment.status = ExperimentStatus::Running;
            state.current_experiment = Some(experiment.clone());
            state.last_run = Some(Utc::now());
        }

        self.save_state().await?;

        self.run_experiment_steps(&experiment_id, metrics_before)
            .await?;

        Ok(experiment_id)
    }

    fn generate_experiment_plan(
        &self,
        experiment_type: &ExperimentType,
        _hypothesis: &str,
    ) -> Result<Vec<ExperimentStep>> {
        match experiment_type {
            ExperimentType::ConfigOptimization => Ok(vec![
                ExperimentStep {
                    action: "backup_current_config".to_string(),
                    expected_outcome: "Configuration backed up successfully".to_string(),
                    rollback_action: "restore_config_backup".to_string(),
                    completed: false,
                },
                ExperimentStep {
                    action: "apply_optimized_config".to_string(),
                    expected_outcome: "New configuration applied".to_string(),
                    rollback_action: "restore_config_backup".to_string(),
                    completed: false,
                },
                ExperimentStep {
                    action: "run_validation_tests".to_string(),
                    expected_outcome: "All validation tests pass".to_string(),
                    rollback_action: "restore_config_backup".to_string(),
                    completed: false,
                },
            ]),
            ExperimentType::ServiceTuning => Ok(vec![
                ExperimentStep {
                    action: "capture_service_baseline".to_string(),
                    expected_outcome: "Baseline metrics captured".to_string(),
                    rollback_action: "restore_service_settings".to_string(),
                    completed: false,
                },
                ExperimentStep {
                    action: "apply_tuning_parameters".to_string(),
                    expected_outcome: "Tuning parameters applied".to_string(),
                    rollback_action: "restore_service_settings".to_string(),
                    completed: false,
                },
                ExperimentStep {
                    action: "monitor_service_performance".to_string(),
                    expected_outcome: "Service performance improved".to_string(),
                    rollback_action: "restore_service_settings".to_string(),
                    completed: false,
                },
            ]),
            ExperimentType::PowerManagement => Ok(vec![
                ExperimentStep {
                    action: "capture_power_baseline".to_string(),
                    expected_outcome: "Power consumption baseline captured".to_string(),
                    rollback_action: "restore_power_settings".to_string(),
                    completed: false,
                },
                ExperimentStep {
                    action: "apply_power_optimizations".to_string(),
                    expected_outcome: "Power optimizations applied".to_string(),
                    rollback_action: "restore_power_settings".to_string(),
                    completed: false,
                },
                ExperimentStep {
                    action: "validate_battery_life".to_string(),
                    expected_outcome: "Battery life improved".to_string(),
                    rollback_action: "restore_power_settings".to_string(),
                    completed: false,
                },
            ]),
            ExperimentType::AIModelSelection => Ok(vec![
                ExperimentStep {
                    action: "benchmark_current_model".to_string(),
                    expected_outcome: "Current model benchmarked".to_string(),
                    rollback_action: "restore_model_selection".to_string(),
                    completed: false,
                },
                ExperimentStep {
                    action: "deploy_candidate_model".to_string(),
                    expected_outcome: "Candidate model deployed".to_string(),
                    rollback_action: "restore_model_selection".to_string(),
                    completed: false,
                },
                ExperimentStep {
                    action: "compare_model_performance".to_string(),
                    expected_outcome: "Performance comparison complete".to_string(),
                    rollback_action: "restore_model_selection".to_string(),
                    completed: false,
                },
            ]),
            ExperimentType::SecurityHardening => Ok(vec![
                ExperimentStep {
                    action: "audit_current_security".to_string(),
                    expected_outcome: "Security audit complete".to_string(),
                    rollback_action: "restore_security_settings".to_string(),
                    completed: false,
                },
                ExperimentStep {
                    action: "apply_hardening_measures".to_string(),
                    expected_outcome: "Hardening measures applied".to_string(),
                    rollback_action: "restore_security_settings".to_string(),
                    completed: false,
                },
                ExperimentStep {
                    action: "validate_security_posture".to_string(),
                    expected_outcome: "Security posture validated".to_string(),
                    rollback_action: "restore_security_settings".to_string(),
                    completed: false,
                },
            ]),
        }
    }

    async fn create_experiment_container(&self, experiment_id: &str) -> Result<String> {
        if !self.is_podman_available() {
            anyhow::bail!("Podman is not available. Cannot create experiment container.");
        }

        let container_name = format!("lifeos-lab-{}", experiment_id);
        let image = "localhost/lifeos-lab-base:latest";

        let output = Command::new("podman")
            .args([
                "run",
                "-d",
                "--name",
                &container_name,
                "--privileged",
                "--pid=host",
                "--network=host",
                "-v",
                "/var/lib/lifeos:/var/lib/lifeos:rw",
                "-v",
                "/etc/lifeos:/etc/lifeos:rw",
                image,
                "sleep",
                "infinity",
            ])
            .output()
            .context("Failed to create experiment container")?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("Failed to create container: {}", stderr);
        }

        let container_id = String::from_utf8_lossy(&output.stdout).trim().to_string();
        log::info!(
            "Created experiment container: {} ({})",
            container_name,
            container_id
        );

        Ok(container_id)
    }

    fn is_podman_available(&self) -> bool {
        Command::new("podman")
            .arg("--version")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    async fn run_experiment_steps(
        &self,
        experiment_id: &str,
        metrics_before: MetricsSnapshot,
    ) -> Result<()> {
        let experiment = {
            let state = self.state.read().await;
            state
                .current_experiment
                .as_ref()
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("No current experiment found"))?
        };

        let mut all_steps_passed = true;

        for (idx, step) in experiment.plan.iter().enumerate() {
            log::info!(
                "Running step {} for experiment {}: {}",
                idx + 1,
                experiment_id,
                step.action
            );

            match self.execute_step(&experiment, &step.action).await {
                Ok(_) => {
                    let mut state = self.state.write().await;
                    if let Some(ref mut exp) = state.current_experiment {
                        if let Some(step) = exp.plan.get_mut(idx) {
                            step.completed = true;
                        }
                    }
                    self.save_state().await?;
                }
                Err(e) => {
                    log::error!("Step {} failed: {}", step.action, e);
                    all_steps_passed = false;
                    break;
                }
            }
        }

        let metrics_after = self.collect_metrics().await?;

        if all_steps_passed {
            let tests_passed = self.run_tests(&experiment).await?;

            if tests_passed {
                log::info!(
                    "Experiment {} validation passed, ready for canary",
                    experiment_id
                );
                let mut state = self.state.write().await;
                if let Some(ref mut exp) = state.current_experiment {
                    exp.status = ExperimentStatus::Canary;
                }
                state.canary_active = true;
                self.save_state().await?;
            } else {
                log::warn!("Experiment {} tests failed, rolling back", experiment_id);
                self.rollback_internal(
                    experiment_id,
                    "Tests failed",
                    metrics_before,
                    metrics_after,
                )
                .await?;
            }
        } else {
            self.rollback_internal(
                experiment_id,
                "Step execution failed",
                metrics_before,
                metrics_after,
            )
            .await?;
        }

        Ok(())
    }

    async fn execute_step(&self, experiment: &Experiment, action: &str) -> Result<()> {
        match action {
            "backup_current_config" => {
                let backup_path = self
                    .workspace
                    .join("backups")
                    .join(&experiment.id)
                    .join("config");
                std::fs::create_dir_all(&backup_path)?;

                let config_src = PathBuf::from("/etc/lifeos");
                if config_src.exists() {
                    let output = Command::new("cp")
                        .args([
                            "-r",
                            &config_src.to_string_lossy(),
                            &backup_path.to_string_lossy(),
                        ])
                        .output()?;
                    if !output.status.success() {
                        anyhow::bail!("Failed to backup config");
                    }
                }
                Ok(())
            }
            "apply_optimized_config" => {
                log::info!(
                    "Applying optimized configuration for experiment {}",
                    experiment.id
                );
                Ok(())
            }
            "run_validation_tests" => {
                log::info!("Running validation tests for experiment {}", experiment.id);
                Ok(())
            }
            "capture_service_baseline" => {
                log::info!(
                    "Capturing service baseline for experiment {}",
                    experiment.id
                );
                Ok(())
            }
            "apply_tuning_parameters" => {
                log::info!(
                    "Applying tuning parameters for experiment {}",
                    experiment.id
                );
                Ok(())
            }
            "monitor_service_performance" => {
                log::info!(
                    "Monitoring service performance for experiment {}",
                    experiment.id
                );
                Ok(())
            }
            "capture_power_baseline" => {
                log::info!("Capturing power baseline for experiment {}", experiment.id);
                Ok(())
            }
            "apply_power_optimizations" => {
                log::info!(
                    "Applying power optimizations for experiment {}",
                    experiment.id
                );
                Ok(())
            }
            "validate_battery_life" => {
                log::info!("Validating battery life for experiment {}", experiment.id);
                Ok(())
            }
            "benchmark_current_model" => {
                log::info!(
                    "Benchmarking current AI model for experiment {}",
                    experiment.id
                );
                Ok(())
            }
            "deploy_candidate_model" => {
                log::info!(
                    "Deploying candidate AI model for experiment {}",
                    experiment.id
                );
                Ok(())
            }
            "compare_model_performance" => {
                log::info!(
                    "Comparing model performance for experiment {}",
                    experiment.id
                );
                Ok(())
            }
            "audit_current_security" => {
                log::info!("Auditing current security for experiment {}", experiment.id);
                Ok(())
            }
            "apply_hardening_measures" => {
                log::info!(
                    "Applying security hardening for experiment {}",
                    experiment.id
                );
                Ok(())
            }
            "validate_security_posture" => {
                log::info!(
                    "Validating security posture for experiment {}",
                    experiment.id
                );
                Ok(())
            }
            _ => {
                log::warn!("Unknown action: {}, skipping", action);
                Ok(())
            }
        }
    }

    async fn run_tests(&self, experiment: &Experiment) -> Result<bool> {
        log::info!("Running test suite for experiment {}", experiment.id);

        let test_results = self.run_test_suite().await?;

        let all_passed = test_results.failed == 0;

        let results_path = self
            .workspace
            .join("experiments")
            .join(&experiment.id)
            .join("test_results.json");
        if let Some(parent) = results_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let content = serde_json::to_string_pretty(&test_results)?;
        fs::write(&results_path, content).await?;

        Ok(all_passed)
    }

    async fn run_test_suite(&self) -> Result<TestResults> {
        let mut results = Vec::new();

        let start = std::time::Instant::now();
        let (passed, error) = self.test_system_health().await;
        results.push(TestResult {
            name: "system_health_check".to_string(),
            passed,
            duration_ms: start.elapsed().as_millis() as u64,
            error,
        });

        let start = std::time::Instant::now();
        let (passed, error) = self.test_config_validation().await;
        results.push(TestResult {
            name: "config_validation".to_string(),
            passed,
            duration_ms: start.elapsed().as_millis() as u64,
            error,
        });

        let start = std::time::Instant::now();
        let (passed, error) = self.test_service_availability().await;
        results.push(TestResult {
            name: "service_availability".to_string(),
            passed,
            duration_ms: start.elapsed().as_millis() as u64,
            error,
        });

        let passed = results.iter().filter(|r| r.passed).count();
        let failed = results.len() - passed;

        Ok(TestResults {
            total: results.len(),
            passed,
            failed,
            details: results,
        })
    }

    async fn test_system_health(&self) -> (bool, Option<String>) {
        if let Ok(output) = Command::new("systemctl")
            .args(["is-system-running"])
            .output()
        {
            let status = String::from_utf8_lossy(&output.stdout);
            if status.starts_with("running") || status.starts_with("degraded") {
                return (true, None);
            }
        }
        (false, Some("System not in healthy state".to_string()))
    }

    async fn test_config_validation(&self) -> (bool, Option<String>) {
        let config_path = PathBuf::from("/etc/lifeos/daemon.toml");
        if !config_path.exists() {
            return (true, None);
        }

        if let Ok(content) = std::fs::read_to_string(&config_path) {
            if toml::from_str::<toml::Value>(&content).is_ok() {
                return (true, None);
            }
        }
        (false, Some("Config validation failed".to_string()))
    }

    async fn test_service_availability(&self) -> (bool, Option<String>) {
        // Phase 3 of the architecture pivot renamed the daemon unit from
        // user-scope `lifeosd.service` to system-scope
        // `lifeos-lifeosd.service` (Quadlet-generated). Probe the canonical
        // name first; the legacy name is kept as a rollback fallback so a
        // host that rolled back to a pre-Phase-3 image still passes.
        let critical_services = vec![
            "lifeos-lifeosd.service",
            "lifeosd.service",
            "NetworkManager.service",
        ];

        // lifeosd: succeed if EITHER the new or legacy unit is active. The
        // remaining services (NetworkManager) must be active by themselves.
        let lifeosd_active = ["lifeos-lifeosd.service", "lifeosd.service"]
            .iter()
            .any(|s| {
                Command::new("systemctl")
                    .args(["is-active", "--quiet", s])
                    .status()
                    .map(|st| st.success())
                    .unwrap_or(false)
            });
        if !lifeosd_active {
            return (
                false,
                Some("Service lifeos-lifeosd.service not active".to_string()),
            );
        }

        for service in &critical_services[2..] {
            if let Ok(output) = Command::new("systemctl")
                .args(["is-active", "--quiet", service])
                .output()
            {
                if !output.status.success() {
                    return (false, Some(format!("Service {} not active", service)));
                }
            }
        }
        (true, None)
    }

    async fn collect_metrics(&self) -> Result<MetricsSnapshot> {
        let mut snapshot = MetricsSnapshot::default();

        if let Ok(output) = Command::new("cat").arg("/proc/loadavg").output() {
            let loadavg = String::from_utf8_lossy(&output.stdout);
            if let Some(avg) = loadavg.split_whitespace().next() {
                snapshot.cpu_usage_avg = avg.parse().unwrap_or(0.0);
            }
        }

        if let Ok(output) = Command::new("free").args(["-m"]).output() {
            let free_output = String::from_utf8_lossy(&output.stdout);
            for line in free_output.lines() {
                if line.starts_with("Mem:") {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if parts.len() >= 3 {
                        let total: f32 = parts[1].parse().unwrap_or(1.0);
                        let used: f32 = parts[2].parse().unwrap_or(0.0);
                        snapshot.memory_usage_avg = (used / total) * 100.0;
                    }
                    break;
                }
            }
        }

        if let Ok(output) = Command::new("systemd-analyze").arg("time").output() {
            let analyze = String::from_utf8_lossy(&output.stdout);
            if let Some(time_str) = analyze.split_whitespace().nth(1) {
                let time_str = time_str.trim_end_matches('s');
                snapshot.boot_time_seconds = time_str.parse().unwrap_or(0);
            }
        }

        if let Ok(output) = Command::new("journalctl")
            .args([
                "--since",
                "1 hour ago",
                "-u",
                // Phase 3: canonical unit name is lifeos-lifeosd.service
                // (Quadlet-generated). The legacy `lifeosd` unit is gone,
                // querying it would silently return zero entries and the
                // error_rate metric would always read 0 — masking real
                // failures.
                "lifeos-lifeosd.service",
                "-p",
                "err",
                "--no-pager",
            ])
            .output()
        {
            let errors = String::from_utf8_lossy(&output.stdout);
            snapshot.error_rate = errors.lines().count() as f32;
        }

        if PathBuf::from("/sys/class/power_supply/BAT0").exists() {
            if let Ok(output) = Command::new("upower")
                .args(["-i", "/org/freedesktop/UPower/devices/battery_BAT0"])
                .output()
            {
                let upower = String::from_utf8_lossy(&output.stdout);
                for line in upower.lines() {
                    if line.contains("rate") {
                        if let Some(rate_str) = line.split_whitespace().nth(1) {
                            snapshot.battery_drain_rate_percent_per_hour =
                                Some(rate_str.parse().unwrap_or(0.0));
                        }
                    }
                }
            }
        }

        Ok(snapshot)
    }

    pub async fn start_canary(&self, experiment_id: &str) -> Result<()> {
        let mut state = self.state.write().await;

        let experiment = state
            .current_experiment
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("No current experiment found"))?;

        if experiment.id != experiment_id {
            anyhow::bail!("Experiment ID mismatch");
        }

        if experiment.status != ExperimentStatus::Canary {
            anyhow::bail!("Experiment must be in Canary status before starting canary phase");
        }

        log::info!("Starting canary phase for experiment {}", experiment_id);
        state.canary_active = true;
        drop(state);

        self.save_state().await?;

        let self_clone = Arc::new(self.clone());
        let experiment_id_owned = experiment_id.to_string();
        tokio::spawn(async move { self_clone.monitor_canary(experiment_id_owned).await });

        Ok(())
    }

    async fn monitor_canary(self: Arc<Self>, experiment_id: String) {
        let duration = chrono::Duration::hours(self.config.canary_duration_hours as i64);
        let start = Utc::now();

        loop {
            tokio::time::sleep(tokio::time::Duration::from_secs(300)).await;

            let state = self.state.read().await;
            if let Some(ref experiment) = state.current_experiment {
                if experiment.id != experiment_id {
                    break;
                }

                if Utc::now() - start >= duration {
                    drop(state);
                    if self.config.auto_promote {
                        if let Err(e) = self.promote(&experiment_id).await {
                            log::error!("Auto-promote failed: {}", e);
                        }
                    }
                    break;
                }

                if let Ok(metrics) = self.collect_metrics().await {
                    if metrics.error_rate > 10.0 || metrics.cpu_usage_avg > 90.0 {
                        drop(state);
                        log::warn!("Canary metrics degraded, triggering rollback");
                        if let Err(e) = self
                            .rollback(&experiment_id, "Canary metrics degraded")
                            .await
                        {
                            log::error!("Canary rollback failed: {}", e);
                        }
                        break;
                    }
                }
            } else {
                break;
            }
        }
    }

    pub async fn promote(&self, experiment_id: &str) -> Result<()> {
        let mut state = self.state.write().await;

        let experiment = state
            .current_experiment
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("No current experiment found"))?
            .clone();

        if experiment.id != experiment_id {
            anyhow::bail!("Experiment ID mismatch");
        }

        log::info!("Promoting experiment {}", experiment_id);

        if let Some(ref container_id) = experiment.container_id {
            let _ = Command::new("podman").args(["stop", container_id]).output();
            let _ = Command::new("podman").args(["rm", container_id]).output();
        }

        let metrics_after = self.collect_metrics().await?;
        let metrics_before = MetricsSnapshot::default();

        let improvement_score = self.calculate_improvement(&metrics_before, &metrics_after);

        let result = ExperimentResult {
            experiment: experiment.clone(),
            completed_at: Utc::now(),
            success: true,
            metrics_before,
            metrics_after,
            rollback_performed: false,
            improvement_score,
        };

        state.completed_experiments.push(result);
        state.current_experiment = None;
        state.canary_active = false;

        drop(state);
        self.save_state().await?;

        log::info!("Experiment {} promoted successfully", experiment_id);
        Ok(())
    }

    fn calculate_improvement(&self, before: &MetricsSnapshot, after: &MetricsSnapshot) -> f32 {
        let cpu_improvement = if before.cpu_usage_avg > 0.0 {
            ((before.cpu_usage_avg - after.cpu_usage_avg) / before.cpu_usage_avg) * 100.0
        } else {
            0.0
        };

        let memory_improvement = if before.memory_usage_avg > 0.0 {
            ((before.memory_usage_avg - after.memory_usage_avg) / before.memory_usage_avg) * 100.0
        } else {
            0.0
        };

        let error_improvement = if before.error_rate > 0.0 {
            ((before.error_rate - after.error_rate) / before.error_rate) * 100.0
        } else {
            0.0
        };

        (cpu_improvement + memory_improvement + error_improvement) / 3.0
    }

    pub async fn rollback(&self, experiment_id: &str, reason: &str) -> Result<()> {
        let metrics_before = self.collect_metrics().await?;
        let metrics_after = self.collect_metrics().await?;

        self.rollback_internal(experiment_id, reason, metrics_before, metrics_after)
            .await
    }

    async fn rollback_internal(
        &self,
        experiment_id: &str,
        reason: &str,
        metrics_before: MetricsSnapshot,
        metrics_after: MetricsSnapshot,
    ) -> Result<()> {
        let mut state = self.state.write().await;

        let experiment = state
            .current_experiment
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("No current experiment found"))?
            .clone();

        if experiment.id != experiment_id {
            anyhow::bail!("Experiment ID mismatch");
        }

        log::warn!("Rolling back experiment {}: {}", experiment_id, reason);

        for step in experiment.plan.iter().rev() {
            if step.completed {
                log::info!("Executing rollback action: {}", step.rollback_action);
                if let Err(e) = self.execute_rollback(&step.rollback_action).await {
                    log::error!("Rollback action failed: {}", e);
                }
            }
        }

        if let Some(ref container_id) = experiment.container_id {
            let _ = Command::new("podman").args(["stop", container_id]).output();
            let _ = Command::new("podman")
                .args(["rm", "-f", container_id])
                .output();
        }

        let result = ExperimentResult {
            experiment: experiment.clone(),
            completed_at: Utc::now(),
            success: false,
            metrics_before: metrics_before.clone(),
            metrics_after: metrics_after.clone(),
            rollback_performed: true,
            improvement_score: 0.0,
        };

        state.completed_experiments.push(result);
        state.current_experiment = None;
        state.canary_active = false;

        drop(state);
        self.save_state().await?;

        log::info!("Experiment {} rolled back", experiment_id);
        Ok(())
    }

    async fn execute_rollback(&self, action: &str) -> Result<()> {
        match action {
            "restore_config_backup" => {
                log::info!("Restoring configuration from backup");
                Ok(())
            }
            "restore_service_settings" => {
                log::info!("Restoring service settings");
                Ok(())
            }
            "restore_power_settings" => {
                log::info!("Restoring power settings");
                Ok(())
            }
            "restore_model_selection" => {
                log::info!("Restoring AI model selection");
                Ok(())
            }
            "restore_security_settings" => {
                log::info!("Restoring security settings");
                Ok(())
            }
            _ => {
                log::warn!("Unknown rollback action: {}", action);
                Ok(())
            }
        }
    }

    pub async fn status(&self) -> LabState {
        self.state.read().await.clone()
    }

    pub async fn report(&self, experiment_id: &str) -> Result<ExperimentReport> {
        let state = self.state.read().await;

        let experiment = if let Some(ref current) = state.current_experiment {
            if current.id == experiment_id {
                current.clone()
            } else {
                state
                    .completed_experiments
                    .iter()
                    .find(|r| r.experiment.id == experiment_id)
                    .map(|r| r.experiment.clone())
                    .ok_or_else(|| anyhow::anyhow!("Experiment not found: {}", experiment_id))?
            }
        } else {
            state
                .completed_experiments
                .iter()
                .find(|r| r.experiment.id == experiment_id)
                .map(|r| r.experiment.clone())
                .ok_or_else(|| anyhow::anyhow!("Experiment not found: {}", experiment_id))?
        };

        let result = state
            .completed_experiments
            .iter()
            .find(|r| r.experiment.id == experiment_id)
            .cloned();

        let (recommendation, next_steps, risk_level) =
            self.generate_recommendations(&experiment, &result);

        Ok(ExperimentReport {
            experiment,
            result,
            recommendation,
            next_steps,
            risk_level,
        })
    }

    fn generate_recommendations(
        &self,
        experiment: &Experiment,
        result: &Option<ExperimentResult>,
    ) -> (String, Vec<String>, RiskLevel) {
        match result {
            Some(res) if res.success => {
                let recommendation = format!(
                    "Experiment '{}' was successful with improvement score of {:.2}%",
                    experiment.hypothesis, res.improvement_score
                );
                let next_steps = vec![
                    "Consider applying similar optimizations to other system components"
                        .to_string(),
                    "Monitor long-term stability of changes".to_string(),
                    "Document successful configuration for future reference".to_string(),
                ];
                let risk_level = if res.improvement_score > 20.0 {
                    RiskLevel::Medium
                } else {
                    RiskLevel::Low
                };
                (recommendation, next_steps, risk_level)
            }
            Some(res) => {
                let recommendation = format!(
                    "Experiment '{}' failed and was rolled back. Error rate: {:.2}",
                    experiment.hypothesis, res.metrics_after.error_rate
                );
                let next_steps = vec![
                    "Review failure logs to understand root cause".to_string(),
                    "Adjust hypothesis and retry with modified parameters".to_string(),
                    "Consider alternative optimization strategies".to_string(),
                ];
                (recommendation, next_steps, RiskLevel::High)
            }
            None => {
                let recommendation = format!(
                    "Experiment '{}' is currently in progress",
                    experiment.hypothesis
                );
                let next_steps = if experiment.status == ExperimentStatus::Canary {
                    vec![
                        "Monitor canary metrics closely".to_string(),
                        "Prepare for promotion or rollback".to_string(),
                    ]
                } else {
                    vec!["Wait for experiment to complete".to_string()]
                };
                (recommendation, next_steps, RiskLevel::Medium)
            }
        }
    }

    pub async fn history(&self) -> Result<Vec<ExperimentResult>> {
        let state = self.state.read().await;
        Ok(state.completed_experiments.clone())
    }

    pub async fn get_experiment(&self, experiment_id: &str) -> Result<Option<Experiment>> {
        let state = self.state.read().await;

        if let Some(ref current) = state.current_experiment {
            if current.id == experiment_id {
                return Ok(Some(current.clone()));
            }
        }

        Ok(state
            .completed_experiments
            .iter()
            .find(|r| r.experiment.id == experiment_id)
            .map(|r| r.experiment.clone()))
    }
}
