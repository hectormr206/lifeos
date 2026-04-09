use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

const PROFILE_SCHEMA_VERSION: u32 = 1;
const PROFILE_CHECK_INTERVAL_SECS: u64 = 15 * 60;
const PROFILE_RETRY_INTERVAL_SECS: u64 = 5 * 60;
const INITIAL_BENCHMARK_DELAY_SECS: u64 = 45;
const DEFAULT_MODEL: &str = "Qwen3.5-4B-Q4_K_M.gguf";
const DEFAULT_ALIAS: &str = "lifeos";
const DEFAULT_PORT: u16 = 8082;
const DEFAULT_CTX_SIZE: u32 = 16384;
const DEFAULT_GPU_LAYERS: i32 = 99;
const DEFAULT_GAME_GUARD_VRAM_THRESHOLD_MB: u64 = 500;
const RUNTIME_ENV_DROPIN_NAME: &str = "99-lifeos-runtime-envs.conf";
const USER_LLAMA_UNIT_NAME: &str = "llama-server.service";
const LLAMA_PREFLIGHT_REASON_PATH: &str = "/var/lib/lifeos/llama-server-preflight.reason";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LlamaServiceScope {
    System,
    User,
}

impl LlamaServiceScope {
    fn label(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::User => "user",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RuntimeSettings {
    pub ctx_size: u32,
    pub threads: u32,
    pub gpu_layers: i32,
    pub parallel: u32,
    pub batch_size: u32,
    pub ubatch_size: u32,
}

impl RuntimeSettings {
    pub fn to_env_lines(&self) -> Vec<String> {
        vec![
            format!("LIFEOS_AI_CTX_SIZE={}", self.ctx_size),
            format!("LIFEOS_AI_THREADS={}", self.threads),
            format!("LIFEOS_AI_GPU_LAYERS={}", self.gpu_layers),
            format!("LIFEOS_AI_PARALLEL={}", self.parallel),
            format!("LIFEOS_AI_BATCH_SIZE={}", self.batch_size),
            format!("LIFEOS_AI_UBATCH_SIZE={}", self.ubatch_size),
        ]
    }

    pub fn to_env_content(&self, header: &str) -> String {
        format!("# {header}\n{}\n", self.to_env_lines().join("\n"))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RuntimeInputs {
    pub model: String,
    pub alias: String,
    pub port: u16,
    pub requested_ctx_size: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HardwareFingerprint {
    pub cpu_model: String,
    pub logical_cpus: usize,
    pub physical_cpus: usize,
    pub total_ram_mb: u64,
    pub accelerator_backend: Option<String>,
    pub accelerator_name: Option<String>,
    pub accelerator_total_mem_mb: Option<u64>,
    pub dedicated_gpu: bool,
    pub driver_version: Option<String>,
    pub llama_server_version: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RuntimeProfiles {
    pub cpu_ram: RuntimeSettings,
    pub normal_gpu: Option<RuntimeSettings>,
    pub game_guard_cpu_fallback: Option<RuntimeSettings>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BenchmarkMeasurement {
    pub target: String,
    pub candidate: String,
    pub average_latency_ms: u64,
    pub sample_count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeProfile {
    pub schema_version: u32,
    pub daemon_version: String,
    pub fingerprint: HardwareFingerprint,
    pub inputs: RuntimeInputs,
    pub source: String,
    pub benchmark_completed: bool,
    pub last_benchmark_at: Option<DateTime<Utc>>,
    pub last_benchmark_error: Option<String>,
    pub updated_at: DateTime<Utc>,
    pub measurements: Vec<BenchmarkMeasurement>,
    pub profiles: RuntimeProfiles,
}

impl RuntimeProfile {
    pub fn active_settings(&self) -> RuntimeSettings {
        self.profiles
            .normal_gpu
            .clone()
            .unwrap_or_else(|| self.profiles.cpu_ram.clone())
    }

    pub fn supports_game_guard(&self) -> bool {
        self.fingerprint.dedicated_gpu && self.profiles.game_guard_cpu_fallback.is_some()
    }
}

#[derive(Debug, Clone)]
pub struct BootstrapOutcome {
    pub profile: RuntimeProfile,
    pub profile_changed: bool,
    pub env_changed: bool,
    pub benchmark_pending: bool,
}

#[derive(Debug, Clone)]
struct AcceleratorInfo {
    backend: String,
    name: String,
    total_mem_mb: u64,
}

#[derive(Debug, Clone)]
struct RuntimeCandidate {
    name: String,
    settings: RuntimeSettings,
}

pub fn llama_env_path() -> PathBuf {
    std::env::var("LIFEOS_LLAMA_ENV")
        .ok()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/etc/lifeos/llama-server.env"))
}

pub fn runtime_override_env_path() -> PathBuf {
    std::env::var("LIFEOS_AI_RUNTIME_ENV_PATH")
        .ok()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/lib/lifeos/llama-server-runtime-profile.env"))
}

pub fn game_guard_override_env_path() -> PathBuf {
    std::env::var("LIFEOS_AI_GAME_GUARD_ENV_PATH")
        .ok()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/lib/lifeos/llama-server-game-guard.env"))
}

pub fn runtime_profile_path(data_dir: &Path) -> PathBuf {
    data_dir.join("ai/runtime-profile.json")
}

pub fn bootstrap_runtime_profile(data_dir: &Path) -> Result<BootstrapOutcome> {
    if let Err(error) = ensure_llama_service_runtime_env_files() {
        warn!("[ai_runtime] failed to ensure llama-server env compatibility: {error}");
    }

    let current_profile = current_runtime_profile()?;
    let profile_path = runtime_profile_path(data_dir);
    let existing = load_runtime_profile(&profile_path).ok().flatten();

    let (profile, profile_changed) = match existing {
        Some(profile) if !runtime_profile_is_stale(&profile, &current_profile) => (profile, false),
        _ => (build_heuristic_profile(&current_profile), true),
    };

    if profile_changed {
        save_runtime_profile(&profile_path, &profile)?;
    }

    let env_changed = apply_runtime_env(&profile.active_settings())?;
    Ok(BootstrapOutcome {
        benchmark_pending: !profile.benchmark_completed,
        profile,
        profile_changed,
        env_changed,
    })
}

pub async fn run_runtime_profile_manager(
    data_dir: PathBuf,
    game_guard: Option<std::sync::Arc<tokio::sync::RwLock<crate::game_guard::GameGuard>>>,
    event_tx: tokio::sync::broadcast::Sender<crate::events::DaemonEvent>,
) {
    tokio::time::sleep(Duration::from_secs(INITIAL_BENCHMARK_DELAY_SECS)).await;

    loop {
        let sleep_secs =
            match reconcile_runtime_profile_once(&data_dir, game_guard.as_ref(), &event_tx).await {
                Ok(pending) => {
                    if pending {
                        PROFILE_RETRY_INTERVAL_SECS
                    } else {
                        PROFILE_CHECK_INTERVAL_SECS
                    }
                }
                Err(error) => {
                    warn!("[ai_runtime] runtime profile reconcile failed: {error}");
                    PROFILE_RETRY_INTERVAL_SECS
                }
            };

        tokio::time::sleep(Duration::from_secs(sleep_secs)).await;
    }
}

pub fn clear_game_guard_override() -> Result<()> {
    let path = game_guard_override_env_path();
    match fs::remove_file(&path) {
        Ok(_) => {
            info!(
                "[ai_runtime] removed Game Guard override {}",
                path.display()
            );
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(error).with_context(|| format!("failed to remove {}", path.display()));
        }
    }
    Ok(())
}

pub fn write_game_guard_override(profile: &RuntimeSettings) -> Result<()> {
    write_override_env(
        &game_guard_override_env_path(),
        profile,
        "Auto-generated by lifeosd while Game Guard is active.",
    )?;
    Ok(())
}

pub fn restart_llama_server_sync() -> Result<()> {
    let scope = match ensure_llama_service_runtime_env_files() {
        Ok(scope) => scope,
        Err(error) => {
            warn!("[ai_runtime] failed to refresh llama-server env compatibility: {error}");
            LlamaServiceScope::System
        }
    };

    match scope {
        LlamaServiceScope::System => stop_user_llama_service_if_present(),
        LlamaServiceScope::User => stop_system_llama_service_if_active(),
    }

    let _ = systemctl_command(scope)
        .args(["reset-failed", USER_LLAMA_UNIT_NAME])
        .output();

    let action = if llama_service_is_active(scope).unwrap_or(false) {
        "restart"
    } else {
        "start"
    };
    let status = systemctl_command(scope)
        .args([action, USER_LLAMA_UNIT_NAME])
        .status()
        .with_context(|| {
            format!(
                "failed to {action} {} {}",
                scope.label(),
                USER_LLAMA_UNIT_NAME
            )
        })?;

    if !status.success() {
        anyhow::bail!(
            "systemctl {}{} {} failed",
            if matches!(scope, LlamaServiceScope::User) {
                "--user "
            } else {
                ""
            },
            action,
            USER_LLAMA_UNIT_NAME
        );
    }

    Ok(())
}

async fn reconcile_runtime_profile_once(
    data_dir: &Path,
    game_guard: Option<&std::sync::Arc<tokio::sync::RwLock<crate::game_guard::GameGuard>>>,
    event_tx: &tokio::sync::broadcast::Sender<crate::events::DaemonEvent>,
) -> Result<bool> {
    let outcome = bootstrap_runtime_profile(data_dir)?;
    if outcome.profile_changed || outcome.env_changed {
        restart_llama_server_sync()?;
    }

    sync_game_guard(game_guard, &outcome.profile).await;

    if !outcome.benchmark_pending {
        return Ok(false);
    }

    if !benchmark_can_run(&outcome.profile) {
        return Ok(true);
    }

    let profile_path = runtime_profile_path(data_dir);
    let mut profile = outcome.profile.clone();
    match benchmark_runtime_profile(&mut profile).await {
        Ok(true) => {
            save_runtime_profile(&profile_path, &profile)?;
            let changed = apply_runtime_env(&profile.active_settings())?;
            if changed {
                restart_llama_server_sync()?;
            }
            sync_game_guard(game_guard, &profile).await;
            let _ = event_tx.send(crate::events::DaemonEvent::Notification {
                priority: "info".into(),
                message: "Axi optimizo el runtime local del modelo para este hardware.".into(),
            });
        }
        Ok(false) => {
            save_runtime_profile(&profile_path, &profile)?;
            sync_game_guard(game_guard, &profile).await;
        }
        Err(error) => {
            profile.last_benchmark_error = Some(error.to_string());
            profile.updated_at = Utc::now();
            save_runtime_profile(&profile_path, &profile)?;
            sync_game_guard(game_guard, &profile).await;
        }
    }

    Ok(!profile.benchmark_completed)
}

async fn sync_game_guard(
    game_guard: Option<&std::sync::Arc<tokio::sync::RwLock<crate::game_guard::GameGuard>>>,
    profile: &RuntimeProfile,
) {
    if let Some(game_guard) = game_guard {
        let guard = game_guard.read().await;
        guard
            .sync_runtime_profile(
                profile.supports_game_guard(),
                profile.profiles.game_guard_cpu_fallback.clone(),
            )
            .await;
    }
}

fn current_runtime_profile() -> Result<(HardwareFingerprint, RuntimeInputs)> {
    Ok((detect_hardware_fingerprint()?, read_runtime_inputs()?))
}

fn runtime_profile_is_stale(
    existing: &RuntimeProfile,
    current: &(HardwareFingerprint, RuntimeInputs),
) -> bool {
    existing.schema_version != PROFILE_SCHEMA_VERSION
        || existing.daemon_version != env!("CARGO_PKG_VERSION")
        || existing.fingerprint != current.0
        || existing.inputs != current.1
}

fn load_runtime_profile(path: &Path) -> Result<Option<RuntimeProfile>> {
    if !path.exists() {
        return Ok(None);
    }
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    let profile = serde_json::from_str(&content)
        .with_context(|| format!("failed to parse {}", path.display()))?;
    Ok(Some(profile))
}

fn save_runtime_profile(path: &Path, profile: &RuntimeProfile) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    let serialized = serde_json::to_string_pretty(profile)?;
    fs::write(path, serialized).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn build_heuristic_profile(current: &(HardwareFingerprint, RuntimeInputs)) -> RuntimeProfile {
    let fingerprint = current.0.clone();
    let inputs = current.1.clone();
    let cpu_profile = heuristic_cpu_profile(&fingerprint, &inputs);
    let gpu_profile = heuristic_gpu_profile(&fingerprint, &inputs);
    let game_guard_profile = heuristic_game_guard_profile(&fingerprint, &inputs);
    RuntimeProfile {
        schema_version: PROFILE_SCHEMA_VERSION,
        daemon_version: env!("CARGO_PKG_VERSION").to_string(),
        fingerprint,
        inputs,
        source: "heuristic".into(),
        benchmark_completed: false,
        last_benchmark_at: None,
        last_benchmark_error: None,
        updated_at: Utc::now(),
        measurements: Vec::new(),
        profiles: RuntimeProfiles {
            cpu_ram: cpu_profile,
            normal_gpu: gpu_profile,
            game_guard_cpu_fallback: game_guard_profile,
        },
    }
}

fn heuristic_cpu_profile(
    fingerprint: &HardwareFingerprint,
    inputs: &RuntimeInputs,
) -> RuntimeSettings {
    let physical = fingerprint.physical_cpus.max(1) as u32;
    let threads = physical.clamp(2, 8);
    let batch_size = if fingerprint.total_ram_mb >= 32 * 1024 {
        512
    } else if fingerprint.total_ram_mb >= 16 * 1024 {
        384
    } else {
        256
    };
    let ubatch_size = if batch_size >= 512 { 256 } else { 128 };
    let ctx_size = if fingerprint.total_ram_mb >= 32 * 1024 {
        inputs.requested_ctx_size.min(8192)
    } else if fingerprint.total_ram_mb >= 16 * 1024 {
        inputs.requested_ctx_size.min(6144)
    } else {
        inputs.requested_ctx_size.min(4096)
    };

    RuntimeSettings {
        ctx_size,
        threads,
        gpu_layers: 0,
        parallel: 1,
        batch_size,
        ubatch_size,
    }
}

fn heuristic_gpu_profile(
    fingerprint: &HardwareFingerprint,
    inputs: &RuntimeInputs,
) -> Option<RuntimeSettings> {
    if !fingerprint.dedicated_gpu {
        return None;
    }

    let physical = fingerprint.physical_cpus.max(1) as u32;
    let vram_mb = fingerprint.accelerator_total_mem_mb.unwrap_or_default();
    let gpu_layers = if vram_mb >= 6 * 1024 {
        DEFAULT_GPU_LAYERS
    } else if vram_mb >= 4 * 1024 {
        40
    } else {
        0
    };
    if gpu_layers == 0 {
        return None;
    }

    let parallel = if vram_mb >= 8 * 1024 { 2 } else { 1 };
    let batch_size = if vram_mb >= 8 * 1024 { 1024 } else { 512 };
    let ubatch_size = if vram_mb >= 12 * 1024 {
        512
    } else if vram_mb >= 8 * 1024 {
        256
    } else {
        128
    };

    Some(RuntimeSettings {
        ctx_size: inputs.requested_ctx_size,
        threads: physical.clamp(4, 8),
        gpu_layers,
        parallel,
        batch_size,
        ubatch_size,
    })
}

fn heuristic_game_guard_profile(
    fingerprint: &HardwareFingerprint,
    inputs: &RuntimeInputs,
) -> Option<RuntimeSettings> {
    if !fingerprint.dedicated_gpu {
        return None;
    }

    let physical = fingerprint.physical_cpus.max(1) as u32;
    let batch_size = if fingerprint.total_ram_mb >= 32 * 1024 {
        512
    } else {
        384
    };
    Some(RuntimeSettings {
        ctx_size: inputs.requested_ctx_size.min(4096),
        threads: physical.clamp(4, 12),
        gpu_layers: 0,
        parallel: 1,
        batch_size,
        ubatch_size: 128,
    })
}

fn read_runtime_inputs() -> Result<RuntimeInputs> {
    let content = fs::read_to_string(llama_env_path()).unwrap_or_default();
    Ok(RuntimeInputs {
        model: read_env_var(&content, "LIFEOS_AI_MODEL")
            .unwrap_or_else(|| DEFAULT_MODEL.to_string()),
        alias: read_env_var(&content, "LIFEOS_AI_ALIAS")
            .unwrap_or_else(|| DEFAULT_ALIAS.to_string()),
        port: read_env_var(&content, "LIFEOS_AI_PORT")
            .and_then(|value| value.parse::<u16>().ok())
            .unwrap_or(DEFAULT_PORT),
        requested_ctx_size: read_env_var(&content, "LIFEOS_AI_CTX_SIZE")
            .and_then(|value| value.parse::<u32>().ok())
            .unwrap_or(DEFAULT_CTX_SIZE),
    })
}

fn read_env_var(content: &str, key: &str) -> Option<String> {
    let prefix = format!("{key}=");
    content.lines().find_map(|line| {
        line.strip_prefix(&prefix)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
    })
}

fn detect_hardware_fingerprint() -> Result<HardwareFingerprint> {
    let cpu_model = read_cpu_model();
    let logical_cpus = num_cpus::get();
    let physical_cpus = num_cpus::get_physical();
    let total_ram_mb = read_total_ram_mb().unwrap_or(0);
    let accelerator = detect_accelerator();
    let driver_version = detect_nvidia_driver_version();
    let llama_server_version = detect_llama_server_version();

    Ok(HardwareFingerprint {
        cpu_model,
        logical_cpus,
        physical_cpus,
        total_ram_mb,
        accelerator_backend: accelerator.as_ref().map(|device| device.backend.clone()),
        accelerator_name: accelerator.as_ref().map(|device| device.name.clone()),
        accelerator_total_mem_mb: accelerator.as_ref().map(|device| device.total_mem_mb),
        dedicated_gpu: accelerator.as_ref().map(is_dedicated_gpu).unwrap_or(false),
        driver_version,
        llama_server_version,
    })
}

fn read_cpu_model() -> String {
    fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|content| {
            content.lines().find_map(|line| {
                line.split_once(':').and_then(|(key, value)| {
                    if key.trim() == "model name" {
                        Some(value.trim().to_string())
                    } else {
                        None
                    }
                })
            })
        })
        .unwrap_or_else(|| "unknown".into())
}

fn read_total_ram_mb() -> Option<u64> {
    fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|content| {
            content.lines().find_map(|line| {
                line.strip_prefix("MemTotal:").and_then(|value| {
                    value
                        .split_whitespace()
                        .next()
                        .and_then(|kb| kb.parse::<u64>().ok())
                        .map(|kb| kb / 1024)
                })
            })
        })
}

fn detect_accelerator() -> Option<AcceleratorInfo> {
    if llama_binary_has_sigill_guard() {
        return None;
    }

    let output = Command::new("llama-server")
        .arg("--list-devices")
        .output()
        .or_else(|_| {
            Command::new("/usr/sbin/llama-server")
                .arg("--list-devices")
                .output()
        })
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut best: Option<AcceleratorInfo> = None;
    for device in parse_llama_list_devices_output(&stdout) {
        let device_is_dedicated = is_dedicated_gpu(&device);
        match &best {
            None => best = Some(device),
            Some(current) if device_is_dedicated && !is_dedicated_gpu(current) => {
                best = Some(device)
            }
            Some(current) if device.total_mem_mb > current.total_mem_mb => best = Some(device),
            _ => {}
        }
    }

    best
}

fn is_dedicated_gpu(device: &AcceleratorInfo) -> bool {
    let name = device.name.to_ascii_lowercase();
    !(name.contains("intel") || name.contains("apple"))
}

fn parse_llama_list_devices_output(output: &str) -> Vec<AcceleratorInfo> {
    let mut devices = Vec::new();
    for raw_line in output.lines() {
        let line = raw_line.trim();
        if line.is_empty() || !line.contains(':') || !line.contains('(') || !line.contains("MiB") {
            continue;
        }
        let (label, rest) = match line.split_once(':') {
            Some(parts) => parts,
            None => continue,
        };
        let (name, memory_block) = match rest.rsplit_once('(') {
            Some(parts) => parts,
            None => continue,
        };
        let name = name.trim();
        if name.is_empty() {
            continue;
        }
        let total_mem_mb = memory_block
            .split("MiB")
            .next()
            .and_then(|value| value.trim().parse::<u64>().ok());
        let Some(total_mem_mb) = total_mem_mb else {
            continue;
        };
        let backend = label
            .trim()
            .trim_end_matches(|ch: char| ch.is_ascii_digit())
            .to_ascii_lowercase();
        devices.push(AcceleratorInfo {
            backend,
            name: name.to_string(),
            total_mem_mb,
        });
    }
    devices
}

fn detect_nvidia_driver_version() -> Option<String> {
    let output = Command::new("nvidia-smi")
        .args(["--query-gpu=driver_version", "--format=csv,noheader"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn detect_llama_server_version() -> Option<String> {
    if llama_binary_has_sigill_guard() {
        return None;
    }

    let output = Command::new("llama-server")
        .arg("--version")
        .output()
        .or_else(|_| {
            Command::new("/usr/sbin/llama-server")
                .arg("--version")
                .output()
        })
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout
        .lines()
        .find(|line| !line.trim().is_empty())
        .map(|line| line.trim().to_string())
}

fn apply_runtime_env(settings: &RuntimeSettings) -> Result<bool> {
    write_override_env(
        &runtime_override_env_path(),
        settings,
        "Auto-generated by lifeosd for hardware-tuned llama-server settings.",
    )
}

fn ensure_llama_service_runtime_env_files() -> Result<LlamaServiceScope> {
    let runtime_path = runtime_override_env_path();
    let guard_path = game_guard_override_env_path();
    let loaded = llama_service_environment_files()?;

    let runtime_loaded = loaded.iter().any(|path| path == &runtime_path);
    let guard_loaded = loaded.iter().any(|path| path == &guard_path);
    if runtime_loaded && guard_loaded {
        return Ok(LlamaServiceScope::System);
    }

    match install_llama_runtime_dropin() {
        Ok(()) => {
            stop_user_llama_service_if_present();
            Ok(LlamaServiceScope::System)
        }
        Err(system_error) => {
            warn!(
                "[ai_runtime] system llama-server cannot load runtime envs, falling back to user service: {system_error}"
            );
            ensure_user_llama_service()?;
            Ok(LlamaServiceScope::User)
        }
    }
}

fn install_llama_runtime_dropin() -> Result<()> {
    let content = llama_runtime_env_dropin_content();
    let mut child = Command::new("systemctl")
        .args([
            "edit",
            "--runtime",
            "--force",
            "--drop-in",
            RUNTIME_ENV_DROPIN_NAME,
            "--stdin",
            USER_LLAMA_UNIT_NAME,
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to spawn systemctl edit for llama-server.service")?;

    let mut stdin = child
        .stdin
        .take()
        .context("failed to open systemctl edit stdin")?;
    stdin
        .write_all(content.as_bytes())
        .context("failed to write llama-server runtime drop-in")?;
    drop(stdin);

    let output = child
        .wait_with_output()
        .context("failed to wait for systemctl edit")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        anyhow::bail!("systemctl edit failed: {stderr}");
    }

    let _ = Command::new("systemctl").arg("daemon-reload").output();
    info!(
        "[ai_runtime] installed runtime env compatibility drop-in for {}",
        USER_LLAMA_UNIT_NAME
    );
    Ok(())
}

fn write_override_env(path: &Path, settings: &RuntimeSettings, header: &str) -> Result<bool> {
    let content = settings.to_env_content(header);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    let existing = fs::read_to_string(path).unwrap_or_default();
    if existing == content {
        return Ok(false);
    }
    fs::write(path, content).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(true)
}

fn systemctl_command(scope: LlamaServiceScope) -> Command {
    let mut command = Command::new("systemctl");
    if matches!(scope, LlamaServiceScope::User) {
        command.arg("--user");
    }
    command
}

fn llama_service_is_active(scope: LlamaServiceScope) -> Result<bool> {
    let status = systemctl_command(scope)
        .args(["is-active", "--quiet", USER_LLAMA_UNIT_NAME])
        .status()
        .with_context(|| format!("failed to inspect {} llama-server service", scope.label()))?;
    Ok(status.success())
}

fn llama_user_unit_path() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("LIFEOS_LLAMA_USER_UNIT_PATH") {
        return Ok(PathBuf::from(path));
    }
    let home = std::env::var_os("HOME").context("HOME is not set for user llama-server unit")?;
    Ok(PathBuf::from(home).join(".config/systemd/user/llama-server.service"))
}

fn ensure_user_llama_service() -> Result<()> {
    let unit_path = llama_user_unit_path()?;
    let content = llama_user_service_content();
    if let Some(parent) = unit_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    let existing = fs::read_to_string(&unit_path).unwrap_or_default();
    if existing != content {
        fs::write(&unit_path, content)
            .with_context(|| format!("failed to write {}", unit_path.display()))?;
    }

    let status = systemctl_command(LlamaServiceScope::User)
        .arg("daemon-reload")
        .status()
        .context("failed to reload user systemd daemon")?;
    if !status.success() {
        anyhow::bail!("systemctl --user daemon-reload failed");
    }

    info!(
        "[ai_runtime] prepared user fallback for {} at {}",
        USER_LLAMA_UNIT_NAME,
        unit_path.display()
    );
    Ok(())
}

fn stop_user_llama_service_if_present() {
    let unit_path = match llama_user_unit_path() {
        Ok(path) => path,
        Err(_) => return,
    };
    if !unit_path.exists() {
        return;
    }
    let _ = systemctl_command(LlamaServiceScope::User)
        .args(["stop", USER_LLAMA_UNIT_NAME])
        .status();
}

fn stop_system_llama_service_if_active() {
    let _ = Command::new("systemctl")
        .args(["stop", USER_LLAMA_UNIT_NAME])
        .status();
}

fn llama_service_environment_files() -> Result<Vec<PathBuf>> {
    let output = Command::new("systemctl")
        .args([
            "show",
            "llama-server.service",
            "-p",
            "EnvironmentFiles",
            "--value",
        ])
        .output()
        .context("failed to inspect llama-server.service environment files")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        anyhow::bail!("systemctl show failed: {stderr}");
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(parse_environment_files_output(&stdout))
}

fn parse_environment_files_output(output: &str) -> Vec<PathBuf> {
    output
        .lines()
        .filter_map(|line| {
            let raw = line
                .trim()
                .strip_prefix("EnvironmentFiles=")
                .unwrap_or(line.trim());
            let path = raw.split_whitespace().next().unwrap_or("").trim();
            if path.starts_with('/') {
                Some(PathBuf::from(path))
            } else {
                None
            }
        })
        .collect()
}

fn llama_runtime_env_dropin_content() -> String {
    format!(
        "[Service]\nEnvironmentFile=-{}\nEnvironmentFile=-{}\n",
        runtime_override_env_path().display(),
        game_guard_override_env_path().display()
    )
}

fn llama_user_service_content() -> String {
    format!(
        "\
[Unit]
Description=LifeOS AI Inference Server (llama.cpp) [user fallback]
Documentation=https://github.com/ggml-org/llama.cpp
After=default.target
ConditionPathExists={}

[Service]
Type=simple
EnvironmentFile=-{}
EnvironmentFile=-{}
EnvironmentFile=-{}
Environment=VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json
Environment=VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json
Environment=__NV_PRIME_RENDER_OFFLOAD=1
Environment=__VK_LAYER_NV_optimus=NVIDIA_only
ExecCondition=/usr/local/bin/lifeos-llama-preflight.sh
ExecStart=/usr/sbin/llama-server \\\n    --model /var/lib/lifeos/models/${{LIFEOS_AI_MODEL}} \\\n    --mmproj /var/lib/lifeos/models/${{LIFEOS_AI_MMPROJ}} \\\n    --alias ${{LIFEOS_AI_ALIAS}} \\\n    --host ${{LIFEOS_AI_HOST}} \\\n    --port ${{LIFEOS_AI_PORT}} \\\n    --ctx-size ${{LIFEOS_AI_CTX_SIZE}} \\\n    --threads ${{LIFEOS_AI_THREADS}} \\\n    --n-gpu-layers ${{LIFEOS_AI_GPU_LAYERS}} \\\n    --parallel ${{LIFEOS_AI_PARALLEL}} \\\n    --batch-size ${{LIFEOS_AI_BATCH_SIZE}} \\\n    --ubatch-size ${{LIFEOS_AI_UBATCH_SIZE}} \\\n    --n-predict 2048 \\\n    --flash-attn auto \\\n    --cache-type-k q8_0 \\\n    --cache-type-v q8_0 \\\n    -sm none \\\n    -mg 0 \\\n    --temp 0.6 \\\n    --top-p 0.95 \\\n    --top-k 20 \\\n    --min-p 0.0 \\\n    --presence-penalty 0.0 \\\n    --repeat-penalty 1.0 \\\n    --reasoning-budget 0 \\\n    --jinja
Restart=always
RestartSec=10
TimeoutStartSec=120
StandardOutput=journal
StandardError=journal
SyslogIdentifier=llama-server

[Install]
WantedBy=default.target
",
        llama_env_path().display(),
        llama_env_path().display(),
        runtime_override_env_path().display(),
        game_guard_override_env_path().display()
    )
}

fn llama_binary_has_sigill_guard() -> bool {
    let mut candidate_paths = vec![PathBuf::from(LLAMA_PREFLIGHT_REASON_PATH)];
    if let Some(runtime_dir) = std::env::var_os("XDG_RUNTIME_DIR") {
        candidate_paths
            .push(PathBuf::from(runtime_dir).join("lifeos/llama-server-preflight.reason"));
    }
    if let Some(home_dir) = std::env::var_os("HOME") {
        candidate_paths
            .push(PathBuf::from(home_dir).join(".cache/lifeos/llama-server-preflight.reason"));
    }

    candidate_paths.into_iter().any(|path| {
        fs::read_to_string(path)
            .map(|reason| {
                reason.contains("SIGILL") || reason.contains("unsupported by this machine")
            })
            .unwrap_or(false)
    })
}

fn benchmark_can_run(profile: &RuntimeProfile) -> bool {
    if llama_binary_has_sigill_guard() {
        return false;
    }

    let model_path = Path::new("/var/lib/lifeos/models").join(&profile.inputs.model);
    if !model_path.exists() {
        return false;
    }

    if profile.fingerprint.dedicated_gpu
        && crate::game_guard::detect_game(DEFAULT_GAME_GUARD_VRAM_THRESHOLD_MB).is_some()
    {
        return false;
    }

    if battery_below_threshold(20) {
        return false;
    }

    true
}

fn battery_below_threshold(threshold_percent: u8) -> bool {
    let Ok(entries) = fs::read_dir("/sys/class/power_supply") else {
        return false;
    };

    for entry in entries.flatten() {
        let path = entry.path();
        let supply_type = fs::read_to_string(path.join("type")).unwrap_or_default();
        if supply_type.trim() != "Battery" {
            continue;
        }
        let capacity = fs::read_to_string(path.join("capacity"))
            .ok()
            .and_then(|value| value.trim().parse::<u8>().ok());
        let status = fs::read_to_string(path.join("status")).unwrap_or_default();
        if capacity.is_some_and(|value| value <= threshold_percent)
            && !status.trim().eq_ignore_ascii_case("charging")
        {
            return true;
        }
    }

    false
}

async fn benchmark_runtime_profile(profile: &mut RuntimeProfile) -> Result<bool> {
    let original_settings = profile.active_settings();
    let mut measurements = Vec::new();

    let benchmark_result = async {
        if profile.fingerprint.dedicated_gpu {
            if let Some(best_gpu) = benchmark_target(
                "normal_gpu",
                &build_gpu_candidates(profile),
                &profile.inputs,
                &mut measurements,
            )
            .await?
            {
                profile.profiles.normal_gpu = Some(best_gpu);
            }

            if let Some(best_cpu) = benchmark_target(
                "game_guard_cpu_fallback",
                &build_game_guard_candidates(profile),
                &profile.inputs,
                &mut measurements,
            )
            .await?
            {
                profile.profiles.cpu_ram = best_cpu.clone();
                profile.profiles.game_guard_cpu_fallback = Some(best_cpu);
            }
        } else if let Some(best_cpu) = benchmark_target(
            "cpu_ram",
            &build_cpu_candidates(profile),
            &profile.inputs,
            &mut measurements,
        )
        .await?
        {
            profile.profiles.cpu_ram = best_cpu;
            profile.profiles.normal_gpu = None;
            profile.profiles.game_guard_cpu_fallback = None;
        }

        Ok::<(), anyhow::Error>(())
    }
    .await;

    match benchmark_result {
        Ok(()) => {
            profile.source = "microbenchmark".into();
            profile.benchmark_completed = !measurements.is_empty();
            profile.last_benchmark_at = Some(Utc::now());
            profile.last_benchmark_error = if profile.benchmark_completed {
                None
            } else {
                Some("no benchmark candidates completed successfully".into())
            };
            profile.measurements = measurements;
            profile.updated_at = Utc::now();
            apply_runtime_env(&profile.active_settings())?;
            if profile.benchmark_completed {
                info!(
                    "[ai_runtime] restoring active runtime profile after microbenchmark candidate restarts"
                );
                restart_llama_server_sync()?;
            }
            Ok(profile.benchmark_completed)
        }
        Err(error) => {
            let _ = apply_runtime_env(&original_settings);
            let _ = restart_llama_server_sync();
            Err(error)
        }
    }
}

async fn benchmark_target(
    target: &str,
    candidates: &[RuntimeCandidate],
    inputs: &RuntimeInputs,
    measurements: &mut Vec<BenchmarkMeasurement>,
) -> Result<Option<RuntimeSettings>> {
    if candidates.is_empty() {
        return Ok(None);
    }

    let mut best: Option<(u64, RuntimeSettings)> = None;
    for candidate in candidates {
        let measurement = match benchmark_candidate(candidate, inputs).await {
            Ok(measurement) => measurement,
            Err(error) => {
                warn!(
                    "[ai_runtime] benchmark candidate '{}' for {} failed: {}",
                    candidate.name, target, error
                );
                continue;
            }
        };
        measurements.push(BenchmarkMeasurement {
            target: target.to_string(),
            candidate: candidate.name.clone(),
            average_latency_ms: measurement,
            sample_count: 2,
        });
        match &best {
            Some((best_latency, _)) if *best_latency <= measurement => {}
            _ => best = Some((measurement, candidate.settings.clone())),
        }
    }

    Ok(best.map(|(_, settings)| settings))
}

async fn benchmark_candidate(candidate: &RuntimeCandidate, inputs: &RuntimeInputs) -> Result<u64> {
    apply_runtime_env(&candidate.settings)?;
    restart_llama_server_sync()?;

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(180))
        .build()?;

    wait_for_server_ready(&client, inputs).await?;
    let _ = run_benchmark_request(&client, inputs, 8).await?;
    let first = run_benchmark_request(&client, inputs, 16).await?;
    let second = run_benchmark_request(&client, inputs, 16).await?;

    Ok((first + second) / 2)
}

async fn wait_for_server_ready(client: &reqwest::Client, inputs: &RuntimeInputs) -> Result<()> {
    let deadline = std::time::Instant::now() + Duration::from_secs(180);
    loop {
        match run_benchmark_request(client, inputs, 4).await {
            Ok(_) => return Ok(()),
            Err(error) if std::time::Instant::now() < deadline => {
                warn!("[ai_runtime] waiting for llama-server: {error}");
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
            Err(error) => return Err(error),
        }
    }
}

async fn run_benchmark_request(
    client: &reqwest::Client,
    inputs: &RuntimeInputs,
    max_tokens: u32,
) -> Result<u64> {
    let endpoint = format!("http://127.0.0.1:{}/v1/chat/completions", inputs.port);
    let payload = serde_json::json!({
        "model": inputs.alias,
        "messages": [
            {"role": "system", "content": "Reply tersely."},
            {"role": "user", "content": "Reply with exactly: bench ok"}
        ],
        "temperature": 0.0,
        "top_p": 1.0,
        "max_tokens": max_tokens,
        "stream": false
    });

    let started_at = std::time::Instant::now();
    let response = client
        .post(&endpoint)
        .json(&payload)
        .send()
        .await
        .with_context(|| format!("failed to call {endpoint}"))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!("server returned {status}: {body}");
    }

    Ok(started_at.elapsed().as_millis() as u64)
}

fn build_cpu_candidates(profile: &RuntimeProfile) -> Vec<RuntimeCandidate> {
    let physical = profile.fingerprint.physical_cpus.max(1) as u32;
    let ctx_size = profile.profiles.cpu_ram.ctx_size;
    let ram_mb = profile.fingerprint.total_ram_mb;
    let ubatch_large = if ram_mb >= 32 * 1024 { 256 } else { 128 };

    dedupe_candidates(vec![
        RuntimeCandidate {
            name: "cpu-balanced".into(),
            settings: RuntimeSettings {
                ctx_size,
                threads: physical.clamp(2, 4),
                gpu_layers: 0,
                parallel: 1,
                batch_size: 256,
                ubatch_size: 128,
            },
        },
        RuntimeCandidate {
            name: "cpu-throughput".into(),
            settings: RuntimeSettings {
                ctx_size,
                threads: physical.clamp(4, 8),
                gpu_layers: 0,
                parallel: 1,
                batch_size: if ram_mb >= 16 * 1024 { 384 } else { 256 },
                ubatch_size: 128,
            },
        },
        RuntimeCandidate {
            name: "cpu-max".into(),
            settings: RuntimeSettings {
                ctx_size,
                threads: physical.clamp(6, 12),
                gpu_layers: 0,
                parallel: 1,
                batch_size: if ram_mb >= 16 * 1024 { 512 } else { 384 },
                ubatch_size: ubatch_large,
            },
        },
    ])
}

fn build_game_guard_candidates(profile: &RuntimeProfile) -> Vec<RuntimeCandidate> {
    let physical = profile.fingerprint.physical_cpus.max(1) as u32;
    let ctx_size = profile
        .profiles
        .game_guard_cpu_fallback
        .as_ref()
        .map(|settings| settings.ctx_size)
        .unwrap_or_else(|| profile.inputs.requested_ctx_size.min(4096));
    let ram_mb = profile.fingerprint.total_ram_mb;

    dedupe_candidates(vec![
        RuntimeCandidate {
            name: "guard-fast-return".into(),
            settings: RuntimeSettings {
                ctx_size,
                threads: physical.clamp(4, 6),
                gpu_layers: 0,
                parallel: 1,
                batch_size: 256,
                ubatch_size: 128,
            },
        },
        RuntimeCandidate {
            name: "guard-balanced".into(),
            settings: RuntimeSettings {
                ctx_size,
                threads: physical.clamp(6, 10),
                gpu_layers: 0,
                parallel: 1,
                batch_size: if ram_mb >= 16 * 1024 { 384 } else { 256 },
                ubatch_size: 128,
            },
        },
        RuntimeCandidate {
            name: "guard-max".into(),
            settings: RuntimeSettings {
                ctx_size,
                threads: physical.clamp(8, 12),
                gpu_layers: 0,
                parallel: 1,
                batch_size: if ram_mb >= 32 * 1024 { 512 } else { 384 },
                ubatch_size: 128,
            },
        },
    ])
}

fn build_gpu_candidates(profile: &RuntimeProfile) -> Vec<RuntimeCandidate> {
    let Some(base) = profile.profiles.normal_gpu.clone() else {
        return Vec::new();
    };
    let physical = profile.fingerprint.physical_cpus.max(1) as u32;
    let vram_mb = profile
        .fingerprint
        .accelerator_total_mem_mb
        .unwrap_or_default();

    dedupe_candidates(vec![
        RuntimeCandidate {
            name: "gpu-latency".into(),
            settings: RuntimeSettings {
                threads: physical.clamp(4, 6),
                parallel: 1,
                batch_size: 512,
                ubatch_size: 128,
                ..base.clone()
            },
        },
        RuntimeCandidate {
            name: "gpu-balanced".into(),
            settings: RuntimeSettings {
                threads: physical.clamp(4, 8),
                parallel: if vram_mb >= 8 * 1024 { 2 } else { 1 },
                batch_size: if vram_mb >= 8 * 1024 { 768 } else { 512 },
                ubatch_size: if vram_mb >= 8 * 1024 { 256 } else { 128 },
                ..base.clone()
            },
        },
        RuntimeCandidate {
            name: "gpu-throughput".into(),
            settings: RuntimeSettings {
                threads: physical.clamp(6, 8),
                parallel: if vram_mb >= 8 * 1024 { 2 } else { 1 },
                batch_size: if vram_mb >= 12 * 1024 { 1024 } else { 768 },
                ubatch_size: if vram_mb >= 12 * 1024 { 512 } else { 256 },
                ..base
            },
        },
    ])
}

fn dedupe_candidates(candidates: Vec<RuntimeCandidate>) -> Vec<RuntimeCandidate> {
    let mut unique = Vec::new();
    for candidate in candidates {
        if unique
            .iter()
            .any(|existing: &RuntimeCandidate| existing.settings == candidate.settings)
        {
            continue;
        }
        unique.push(candidate);
    }
    unique
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_llama_list_devices_prefers_real_devices() {
        let sample = "\
Available devices:
  Vulkan0: Intel(R) Graphics (RPL-S) (72188 MiB, 64969 MiB free)
  Vulkan1: NVIDIA GeForce RTX 5070 Ti Laptop GPU (12227 MiB, 11767 MiB free)
";
        let parsed = parse_llama_list_devices_output(sample);
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].backend, "vulkan");
        assert_eq!(parsed[1].name, "NVIDIA GeForce RTX 5070 Ti Laptop GPU");
        assert!(is_dedicated_gpu(&parsed[1]));
        assert!(!is_dedicated_gpu(&parsed[0]));
    }

    #[test]
    fn runtime_settings_serialize_to_env_lines() {
        let settings = RuntimeSettings {
            ctx_size: 4096,
            threads: 6,
            gpu_layers: 0,
            parallel: 1,
            batch_size: 384,
            ubatch_size: 128,
        };
        let content = settings.to_env_content("test");
        assert!(content.contains("LIFEOS_AI_CTX_SIZE=4096"));
        assert!(content.contains("LIFEOS_AI_THREADS=6"));
        assert!(content.contains("LIFEOS_AI_UBATCH_SIZE=128"));
    }

    #[test]
    fn stale_profile_detects_hardware_and_input_changes() {
        let fingerprint = HardwareFingerprint {
            cpu_model: "cpu".into(),
            logical_cpus: 8,
            physical_cpus: 4,
            total_ram_mb: 16384,
            accelerator_backend: None,
            accelerator_name: None,
            accelerator_total_mem_mb: None,
            dedicated_gpu: false,
            driver_version: None,
            llama_server_version: Some("llama 1".into()),
        };
        let inputs = RuntimeInputs {
            model: "Qwen3.5-4B-Q4_K_M.gguf".into(),
            alias: "lifeos".into(),
            port: 8082,
            requested_ctx_size: 8192,
        };
        let profile = RuntimeProfile {
            schema_version: PROFILE_SCHEMA_VERSION,
            daemon_version: env!("CARGO_PKG_VERSION").into(),
            fingerprint: fingerprint.clone(),
            inputs: inputs.clone(),
            source: "heuristic".into(),
            benchmark_completed: false,
            last_benchmark_at: None,
            last_benchmark_error: None,
            updated_at: Utc::now(),
            measurements: Vec::new(),
            profiles: RuntimeProfiles {
                cpu_ram: RuntimeSettings {
                    ctx_size: 4096,
                    threads: 4,
                    gpu_layers: 0,
                    parallel: 1,
                    batch_size: 256,
                    ubatch_size: 128,
                },
                normal_gpu: None,
                game_guard_cpu_fallback: None,
            },
        };
        assert!(!runtime_profile_is_stale(
            &profile,
            &(fingerprint.clone(), inputs.clone())
        ));

        let mut changed_inputs = inputs.clone();
        changed_inputs.requested_ctx_size = 16384;
        assert!(runtime_profile_is_stale(
            &profile,
            &(fingerprint.clone(), changed_inputs)
        ));

        let mut changed_fingerprint = fingerprint.clone();
        changed_fingerprint.accelerator_name = Some("GPU".into());
        assert!(runtime_profile_is_stale(
            &profile,
            &(changed_fingerprint, inputs)
        ));
    }

    #[test]
    fn heuristic_profiles_disable_game_guard_without_dedicated_gpu() {
        let fingerprint = HardwareFingerprint {
            cpu_model: "cpu".into(),
            logical_cpus: 16,
            physical_cpus: 8,
            total_ram_mb: 32768,
            accelerator_backend: Some("vulkan".into()),
            accelerator_name: Some("Intel(R) Graphics".into()),
            accelerator_total_mem_mb: Some(8192),
            dedicated_gpu: false,
            driver_version: None,
            llama_server_version: None,
        };
        let inputs = RuntimeInputs {
            model: DEFAULT_MODEL.into(),
            alias: DEFAULT_ALIAS.into(),
            port: DEFAULT_PORT,
            requested_ctx_size: DEFAULT_CTX_SIZE,
        };
        let profile = build_heuristic_profile(&(fingerprint, inputs));
        assert!(profile.profiles.normal_gpu.is_none());
        assert!(profile.profiles.game_guard_cpu_fallback.is_none());
        assert!(!profile.supports_game_guard());
    }

    #[test]
    fn dedupe_candidates_removes_identical_profiles() {
        let settings = RuntimeSettings {
            ctx_size: 4096,
            threads: 4,
            gpu_layers: 0,
            parallel: 1,
            batch_size: 256,
            ubatch_size: 128,
        };
        let deduped = dedupe_candidates(vec![
            RuntimeCandidate {
                name: "a".into(),
                settings: settings.clone(),
            },
            RuntimeCandidate {
                name: "b".into(),
                settings,
            },
        ]);
        assert_eq!(deduped.len(), 1);
    }

    #[test]
    fn parse_environment_files_output_accepts_show_formats() {
        let output = "\
EnvironmentFiles=/etc/lifeos/llama-server.env (ignore_errors=yes)
/var/lib/lifeos/llama-server-runtime-profile.env
EnvironmentFiles=/var/lib/lifeos/llama-server-game-guard.env (ignore_errors=yes)
";
        let parsed = parse_environment_files_output(output);
        assert_eq!(
            parsed,
            vec![
                PathBuf::from("/etc/lifeos/llama-server.env"),
                PathBuf::from("/var/lib/lifeos/llama-server-runtime-profile.env"),
                PathBuf::from("/var/lib/lifeos/llama-server-game-guard.env"),
            ]
        );
    }

    #[test]
    fn runtime_dropin_content_points_to_runtime_and_guard_envs() {
        let content = llama_runtime_env_dropin_content();
        assert!(
            content.contains("EnvironmentFile=-/var/lib/lifeos/llama-server-runtime-profile.env")
        );
        assert!(content.contains("EnvironmentFile=-/var/lib/lifeos/llama-server-game-guard.env"));
    }

    #[test]
    fn user_service_content_points_to_runtime_and_guard_envs() {
        let content = llama_user_service_content();
        assert!(content.contains("EnvironmentFile=-/etc/lifeos/llama-server.env"));
        assert!(
            content.contains("EnvironmentFile=-/var/lib/lifeos/llama-server-runtime-profile.env")
        );
        assert!(content.contains("EnvironmentFile=-/var/lib/lifeos/llama-server-game-guard.env"));
        assert!(content.contains("--n-gpu-layers ${LIFEOS_AI_GPU_LAYERS}"));
        assert!(content.contains("Environment=__NV_PRIME_RENDER_OFFLOAD=1"));
    }
}
