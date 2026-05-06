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
/// How long after lifeosd boots before the auto-benchmark fires.
///
/// Engram bug #793: each benchmark candidate calls `apply_runtime_env` +
/// `restart_llama_server_sync` to measure latency, which means
/// `/var/lib/lifeos/llama-server-runtime-profile.env` and the actually-running
/// llama-server process flip between cpu_ram, normal_gpu, and
/// game_guard_cpu_fallback candidates over the benchmark window. If the user
/// chats with Axi during that window, their turn lands on whichever candidate
/// happens to be loaded — which can be Qwen3.5-4B in CPU at full ctx, painfully
/// slow for prefill (~50 tok/s), and prone to router timeouts.
///
/// The proper fix is sidecar benchmarks (run candidates as child processes on
/// a separate port, never touch the main llama-server). That is tracked as a
/// follow-up. For now we mitigate by deferring the auto-benchmark long enough
/// that a user who just booted the laptop is overwhelmingly unlikely to be
/// actively chatting when it fires. 30 minutes is a balance: the benchmark
/// still runs unattended on most laptops, but the most common
/// "boot → log into COSMIC → ping Axi" flow finishes long before.
const INITIAL_BENCHMARK_DELAY_SECS: u64 = 30 * 60;
const DEFAULT_MODEL: &str = "Qwen3.5-4B-Q4_K_M.gguf";
const DEFAULT_ALIAS: &str = "lifeos";
const DEFAULT_PORT: u16 = 8082;
const DEFAULT_CTX_SIZE: u32 = 131_072;
/// Sane bounds for any user-supplied ctx-size override.
pub const USER_CTX_SIZE_MIN: u32 = 1024;
pub const USER_CTX_SIZE_MAX: u32 = 524_288;
/// Descending ladder of ctx-sizes the GPU benchmarker probes. The largest
/// value that successfully boots `llama-server` (with GPU layers > 0) is
/// kept as the runtime ctx-size. Tweak with care: each rung that fails
/// costs roughly one llama-server restart cycle. Capped at the user-facing
/// default so we never silently exceed what `LIFEOS_AI_CTX_SIZE` advertises.
const CTX_SIZE_PROBE_LADDER: &[u32] = &[131_072, 65_536, 32_768, 16_384, 8_192];
const DEFAULT_GPU_LAYERS: i32 = 99;
const DEFAULT_GAME_GUARD_VRAM_THRESHOLD_MB: u64 = 500;
const RUNTIME_ENV_DROPIN_NAME: &str = "99-lifeos-runtime-envs.conf";
/// Canonical systemd unit name for chat inference. Phase 4 of the
/// architecture pivot moved llama-server from the legacy host service
/// `llama-server.service` to the `lifeos-llama-server.service` Quadlet.
/// The constant name is kept for legacy reasons (it predates the rename
/// and refers to the unit name regardless of scope, not the user-scope
/// path which is a deprecated fallback handled separately below).
const USER_LLAMA_UNIT_NAME: &str = "lifeos-llama-server.service";
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
    /// Model GGUF filename to load with this profile. None = inherit from
    /// /etc/lifeos/llama-server.env (the base config). Set per-profile when
    /// a different model is preferred — e.g. `game_guard_cpu_fallback` runs
    /// a smaller 4B model on CPU while the game keeps the GPU, vs. the 9B
    /// that `normal_gpu` uses with full GPU offload.
    #[serde(default)]
    pub model: Option<String>,
    /// Multimodal projector filename. Must match the model's architecture
    /// (a 4B mmproj will not load alongside a 9B base model). None = inherit.
    #[serde(default)]
    pub mmproj: Option<String>,
}

impl RuntimeSettings {
    pub fn to_env_lines(&self) -> Vec<String> {
        let mut lines = vec![
            format!("LIFEOS_AI_CTX_SIZE={}", self.ctx_size),
            format!("LIFEOS_AI_THREADS={}", self.threads),
            format!("LIFEOS_AI_GPU_LAYERS={}", self.gpu_layers),
            format!("LIFEOS_AI_PARALLEL={}", self.parallel),
            format!("LIFEOS_AI_BATCH_SIZE={}", self.batch_size),
            format!("LIFEOS_AI_UBATCH_SIZE={}", self.ubatch_size),
        ];
        if let Some(model) = &self.model {
            lines.push(format!("LIFEOS_AI_MODEL={model}"));
        }
        if let Some(mmproj) = &self.mmproj {
            lines.push(format!("LIFEOS_AI_MMPROJ={mmproj}"));
        }
        // GPU-vs-CPU device split for the lifeos-llama-server Quadlet's Exec
        // line. The Quadlet expands these literally into the llama-server
        // command, so empty is fine — but keeping `-mg 0 --cache-type-* q8_0`
        // hardcoded in the Quadlet causes "invalid value for main_gpu: 0
        // (available devices: 0)" the moment Vulkan can't enumerate a
        // device (every CPU-only deploy + every host where lifeos-nvidia-
        // drivers ships without proper headless Vulkan support).
        // --cache-type-k/v q8_0 are GOOD for both CPU and GPU paths
        // (they cut KV cache memory ~2× regardless of backend), so they
        // live in the unconditional part of the Quadlet's Exec= line.
        // Only the truly GPU-specific flags (`-sm none -mg 0
        // --flash-attn auto`) need parameterising — those error on a
        // CPU-only binary that can't enumerate a Vulkan/CUDA device.
        if self.gpu_layers == 0 {
            lines.push("LIFEOS_AI_DEVICE_FLAGS=--device none".to_string());
            lines.push("LIFEOS_AI_GPU_TUNING=".to_string());
        } else {
            lines.push("LIFEOS_AI_DEVICE_FLAGS=".to_string());
            lines.push("LIFEOS_AI_GPU_TUNING=-sm none -mg 0 --flash-attn auto".to_string());
        }
        lines
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
    /// Probe cache. Survives `daemon_version` bumps so we don't burn 5×
    /// llama-server restarts on every release. Invalidated only by
    /// hardware fingerprint or runtime-input change (see
    /// [`runtime_profile_is_stale`] vs the dedicated probe-cache helper).
    #[serde(default)]
    pub probe_completed: bool,
    #[serde(default)]
    pub probed_ctx_size: Option<u32>,
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

/// User-writable override for llama-server env vars.
///
/// Loaded AFTER the runtime profile via the systemd drop-in
/// `95-user-override.conf`, so any `LIFEOS_AI_*` value here wins. Today
/// the dashboard / API only ever writes `LIFEOS_AI_CTX_SIZE`, but the file
/// is generic so future tunables can live here.
pub fn user_override_env_path() -> PathBuf {
    std::env::var("LIFEOS_AI_USER_OVERRIDE_ENV_PATH")
        .ok()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/lib/lifeos/llama-server-user-override.env"))
}

/// True when a user override file exists with a parseable LIFEOS_AI_CTX_SIZE.
///
/// The benchmarker uses this to leave the user's choice untouched when it
/// regenerates the runtime profile.
pub fn user_ctx_size_override() -> Option<u32> {
    let path = user_override_env_path();
    let content = fs::read_to_string(&path).ok()?;
    read_env_var(&content, "LIFEOS_AI_CTX_SIZE")
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|&v| (USER_CTX_SIZE_MIN..=USER_CTX_SIZE_MAX).contains(&v))
}

/// Write (or replace) the user override file with a single CTX_SIZE entry.
///
/// Mode 0644 owned by the daemon user. Validated against [`USER_CTX_SIZE_MIN`,
/// `USER_CTX_SIZE_MAX`].
pub fn write_user_ctx_size_override(value: u32) -> Result<()> {
    if !(USER_CTX_SIZE_MIN..=USER_CTX_SIZE_MAX).contains(&value) {
        anyhow::bail!("ctx_size {value} out of range [{USER_CTX_SIZE_MIN}, {USER_CTX_SIZE_MAX}]");
    }
    let path = user_override_env_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    let content = format!(
        "# Auto-generated by lifeosd from a user request (dashboard / API).\n\
         # Loaded AFTER the runtime profile via 95-user-override.conf so this\n\
         # value wins. Delete this file (or DELETE /api/v1/llm/ctx-size) to\n\
         # revert to the hardware-tuned runtime profile.\n\
         LIFEOS_AI_CTX_SIZE={value}\n"
    );
    fs::write(&path, content).with_context(|| format!("failed to write {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o644));
    }
    Ok(())
}

/// Remove the user override file. Returns Ok(()) even when the file is absent.
pub fn clear_user_ctx_size_override() -> Result<()> {
    let path = user_override_env_path();
    match fs::remove_file(&path) {
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| format!("failed to remove {}", path.display())),
    }
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

    // Defensive recovery for engram bug #793: if a previous lifeosd instance
    // died mid-benchmark, the on-disk runtime-profile.env can be left holding
    // a candidate's settings (e.g. game_guard_cpu_fallback shape — gpu_layers=0,
    // 4B model, threads=12). The unconditional write below already overwrites
    // it with `active_settings()` (= normal_gpu when GPU is available), so
    // boot is self-healing. But we ALSO log when we detect that drift, so the
    // bug is observable in journals if it happens again under new code paths.
    if let Some(found_drift) = detect_stale_candidate_in_runtime_env(&profile) {
        warn!(
            "[ai_runtime] runtime-profile.env had stale {found_drift} candidate state at boot — \
             overwriting with active_settings (engram #793 recovery)"
        );
    }

    let env_changed = apply_runtime_env(&profile.active_settings())?;
    Ok(BootstrapOutcome {
        benchmark_pending: !profile.benchmark_completed,
        profile,
        profile_changed,
        env_changed,
    })
}

/// Inspect the on-disk runtime env file and report which (if any) candidate
/// shape it currently holds, instead of the active profile. Returns the
/// candidate-name string (e.g. "game_guard_cpu_fallback", "cpu_ram") when the
/// file diverges from active_settings, or `None` when the file is already
/// aligned (or missing). Used purely for the boot-time observability log
/// added for engram bug #793; the unconditional `apply_runtime_env` that
/// follows it heals the file regardless.
fn detect_stale_candidate_in_runtime_env(profile: &RuntimeProfile) -> Option<&'static str> {
    let path = runtime_override_env_path();
    let content = std::fs::read_to_string(&path).ok()?;
    let active = profile.active_settings();
    let active_lines = active.to_env_lines();
    // If the file already matches active settings byte-for-byte, no drift.
    if active_lines.iter().all(|line| content.contains(line)) {
        return None;
    }
    // Otherwise, see which candidate it most closely resembles.
    if let Some(g) = profile.profiles.game_guard_cpu_fallback.as_ref() {
        if g.to_env_lines().iter().all(|line| content.contains(line)) {
            return Some("game_guard_cpu_fallback");
        }
    }
    let cpu_lines = profile.profiles.cpu_ram.to_env_lines();
    if cpu_lines.iter().all(|line| content.contains(line)) {
        return Some("cpu_ram");
    }
    Some("unknown candidate")
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
        probe_completed: false,
        probed_ctx_size: None,
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
    // CPU-only ceiling. Conservative by design: the GPU path can probe with
    // direct child spawns (see probe_run_llama_server) to find the largest
    // viable ctx, but the CPU path has no equivalent because OOMing the
    // host RAM is far more disruptive than VRAM (kernel oom-killer can
    // reap unrelated processes). The user can always raise this via the
    // dashboard / API user override, and it will be respected by
    // apply_runtime_env. If you raise these defaults, attach a measurement
    // — Hector trusts numbers over assumptions.
    let ctx_size = if fingerprint.total_ram_mb >= 32 * 1024 {
        inputs.requested_ctx_size.min(8_192)
    } else if fingerprint.total_ram_mb >= 16 * 1024 {
        inputs.requested_ctx_size.min(6_144)
    } else {
        inputs.requested_ctx_size.min(4_096)
    };

    // Pin the small Qwen 3.5 4B Q4_K_M as the CPU baseline: ~2.7 GB on disk,
    // ~3-4 GB RAM at runtime, runs at ~10-20 tokens/s on a Raptor Lake-S CPU
    // (measured 14 t/s on Hector's machine post-Phase-3 cutover before the
    // Vulkan-headless workaround landed). Without this default the daemon
    // would write a profile with no LIFEOS_AI_MODEL, and the
    // lifeos-llama-server Quadlet would crash-loop on `--model
    // /var/lib/lifeos/models/` (empty path).
    RuntimeSettings {
        ctx_size,
        threads,
        gpu_layers: 0,
        parallel: 1,
        batch_size,
        ubatch_size,
        model: Some("Qwen3.5-4B-Q4_K_M.gguf".into()),
        mmproj: Some("Qwen3.5-4B-mmproj-F16.gguf".into()),
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
        // 9B is the canonical LifeOS model for full-GPU operation; pin it
        // here so a profile-driven write of /var/lib/lifeos/llama-server-runtime-profile.env
        // restores the 9B even if game_guard had previously swapped to 4B.
        model: Some("Qwen3.5-9B-Q4_K_M.gguf".into()),
        mmproj: Some("Qwen3.5-9B-mmproj-F16.gguf".into()),
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
    // Game guard runs a smaller 4B model in CPU while the game keeps the GPU.
    // The user's request: keep the SAME large ctx (up to 131K) so tool-calling
    // and conversational state stay consistent across profile swaps. RAM cost
    // for 4B Q4 + Q8 KV cache at 131K ≈ ~6 GB; safe on 32GB+ machines.
    // Lower-RAM tiers fall back to a smaller ceiling.
    let ctx_size = if fingerprint.total_ram_mb >= 64 * 1024 {
        inputs.requested_ctx_size.min(131_072)
    } else if fingerprint.total_ram_mb >= 32 * 1024 {
        inputs.requested_ctx_size.min(65_536)
    } else if fingerprint.total_ram_mb >= 16 * 1024 {
        inputs.requested_ctx_size.min(16_384)
    } else {
        inputs.requested_ctx_size.min(4_096)
    };
    Some(RuntimeSettings {
        ctx_size,
        threads: physical.clamp(4, 12),
        gpu_layers: 0,
        parallel: 1,
        batch_size,
        ubatch_size: 128,
        // Smaller model so tool-calling and chat stay responsive on CPU while
        // the game holds the GPU. Same Qwen 3.5 family as the 9B → consistent
        // tool-calling templates and personality.
        model: Some("Qwen3.5-4B-Q4_K_M.gguf".into()),
        mmproj: Some("Qwen3.5-4B-mmproj-F16.gguf".into()),
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

    // Phase 4 of the architecture pivot moved llama-server into its own
    // Quadlet container, so the binary is no longer guaranteed to live next
    // to lifeosd. Try the binary first (still present on dev hosts and CPU
    // builds), and fall back to nvidia-smi for the headless-container case
    // where chat inference runs in lifeos-llama-server but lifeosd needs to
    // know the GPU exists to pick the right runtime profile.
    if let Some(info) = detect_accelerator_via_llama_server() {
        return Some(info);
    }
    detect_accelerator_via_nvidia_smi()
}

fn detect_accelerator_via_llama_server() -> Option<AcceleratorInfo> {
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

/// Probe the GPU directly through nvidia-smi. Used when no llama-server
/// binary is reachable (lifeosd runs in a Quadlet container with the
/// nvidia-smi tool injected by CDI, but no llama-server next to it).
/// Returns the highest-VRAM dedicated NVIDIA device or None. Tries the
/// PATH binary first then falls back to the toolkit's canonical
/// /usr/bin/nvidia-smi (CDI sometimes lands the binary at a path that
/// isn't on $PATH inside the daemon container).
fn detect_accelerator_via_nvidia_smi() -> Option<AcceleratorInfo> {
    let candidates = ["nvidia-smi", "/usr/bin/nvidia-smi"];
    for binary in candidates {
        let Ok(output) = Command::new(binary)
            .args([
                "--query-gpu=name,memory.total",
                "--format=csv,noheader,nounits",
            ])
            .output()
        else {
            continue;
        };
        if !output.status.success() {
            continue;
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        let parsed = parse_nvidia_smi_query(&stdout);
        if parsed.is_some() {
            return parsed;
        }
    }
    None
}

fn parse_nvidia_smi_query(output: &str) -> Option<AcceleratorInfo> {
    let mut best: Option<AcceleratorInfo> = None;
    for line in output.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // CSV format with `--format=csv,noheader,nounits`:
        //   "NVIDIA GeForce RTX 5070 Laptop GPU, 12227"
        // Bad rows must `continue`, never `?`-return — `?` exits the whole
        // function and silently drops every following GPU line. Locale-
        // formatted numbers (`12,227`) and `[N/A]` driver-init failures
        // would otherwise mask working GPUs further down the list.
        let mut parts = line.splitn(2, ',');
        let Some(name_raw) = parts.next() else {
            continue;
        };
        let name = name_raw.trim().to_string();
        if name.is_empty() {
            continue;
        }
        let Some(mem_raw) = parts.next() else {
            continue;
        };
        let Ok(mem) = mem_raw.trim().parse::<u64>() else {
            continue;
        };
        let candidate = AcceleratorInfo {
            backend: "nvidia".to_string(),
            name,
            total_mem_mb: mem,
        };
        // Only keep dedicated GPUs (skip Intel/Apple iGPUs that may show
        // up if nvidia-smi is replaced by a stub or on hybrid hosts).
        // Mirrors the llama-server selection logic above.
        if !is_dedicated_gpu(&candidate) {
            continue;
        }
        match &best {
            None => best = Some(candidate),
            Some(current) if candidate.total_mem_mb > current.total_mem_mb => best = Some(candidate),
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
    // Mirror detect_accelerator_via_nvidia_smi's two-candidate lookup so
    // the daemon's HardwareFingerprint stays consistent regardless of
    // whether `nvidia-smi` is on $PATH inside its container. CDI injects
    // it at /usr/bin/nvidia-smi; some container images don't include /usr/
    // bin in PATH for non-root users, so a bare Command::new("nvidia-smi")
    // returns Err and driver_version flips to None — that flip flips
    // PartialEq on HardwareFingerprint and triggers a benchmark re-run on
    // every restart.
    for binary in ["nvidia-smi", "/usr/bin/nvidia-smi"] {
        let Ok(output) = Command::new(binary)
            .args(["--query-gpu=driver_version", "--format=csv,noheader"])
            .output()
        else {
            continue;
        };
        if !output.status.success() {
            continue;
        }
        let parsed = String::from_utf8_lossy(&output.stdout)
            .lines()
            .next()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned);
        if parsed.is_some() {
            return parsed;
        }
    }
    None
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
    apply_runtime_env_inner(settings, false)
}

/// Variant of [`apply_runtime_env`] that ignores the user override.
///
/// Used by the ctx-size probe: when probing, we MUST honor the candidate's
/// ctx_size verbatim, otherwise the user override would silently rewrite
/// every probe back to the pinned value and the probe would be a no-op.
/// The probe path now spawns llama-server directly (not via systemd) so
/// the only caller today is the regression test in this module — kept
/// behind `cfg(test)` to avoid dead code in release builds.
#[cfg(test)]
fn apply_runtime_env_bypass_user_override(settings: &RuntimeSettings) -> Result<bool> {
    apply_runtime_env_inner(settings, true)
}

fn apply_runtime_env_inner(settings: &RuntimeSettings, bypass_user_override: bool) -> Result<bool> {
    // If the user has pinned a ctx_size via the dashboard / API, honor it
    // ALWAYS — even when the benchmarker regenerates the runtime profile.
    // We still emit the rest of the hardware-tuned settings (threads, gpu
    // layers, batch sizes) so a hardware change is picked up. The
    // `bypass_user_override` escape hatch exists for probe code that needs
    // to write a candidate ctx_size verbatim.
    let mut effective = settings.clone();
    if !bypass_user_override {
        if let Some(user_ctx) = user_ctx_size_override() {
            effective.ctx_size = user_ctx;
        }
    }
    write_override_env(
        &runtime_override_env_path(),
        &effective,
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
        .with_context(|| format!("failed to spawn systemctl edit for {USER_LLAMA_UNIT_NAME}"))?;

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
    Ok(PathBuf::from(home).join(".config/systemd/user/lifeos-llama-server.service"))
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
            USER_LLAMA_UNIT_NAME,
            "-p",
            "EnvironmentFiles",
            "--value",
        ])
        .output()
        .with_context(|| format!("failed to inspect {USER_LLAMA_UNIT_NAME} environment files"))?;
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
    // ORDER MATTERS: later EnvironmentFile= entries override earlier ones,
    // so the user override MUST come last so it always wins over both the
    // hardware-tuned runtime profile and the Game Guard override.
    format!(
        "[Service]\nEnvironmentFile=-{}\nEnvironmentFile=-{}\nEnvironmentFile=-{}\n",
        runtime_override_env_path().display(),
        game_guard_override_env_path().display(),
        user_override_env_path().display()
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
        game_guard_override_env_path().display(),
        user_override_env_path().display()
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
            // Probe descending ctx-sizes against the heuristic GPU base
            // until one boots successfully. The largest viable rung becomes
            // the ctx-size used by every subsequent perf candidate. If
            // every rung fails (and gpu_layers stays > 0 in our base),
            // fall through with the heuristic value — perf benchmarking
            // will then either succeed or fail downstream.
            //
            // Skip rules:
            //   1. User pinned a value via dashboard / API → respect it.
            //   2. Probe already completed for this hardware/inputs combo
            //      → reuse cached result; survives daemon version bumps.
            //   3. /usr/sbin/llama-server missing → can't probe; skip.
            let skip_probe_reason: Option<String> = if let Some(user_ctx) = user_ctx_size_override()
            {
                Some(format!("user override active ({user_ctx})"))
            } else if profile.probe_completed {
                if let Some(cached) = profile.probed_ctx_size {
                    if let Some(base) = profile.profiles.normal_gpu.as_mut() {
                        base.ctx_size = cached;
                    }
                }
                Some("probe cache hit".into())
            } else if !Path::new(LLAMA_SERVER_BIN).exists() {
                Some(format!("{LLAMA_SERVER_BIN} missing"))
            } else {
                None
            };

            if let Some(reason) = skip_probe_reason {
                info!("[ai_runtime] ctx probe skipped: {reason}");
            } else if let Some(probed_ctx) =
                probe_largest_viable_gpu_ctx(profile, &mut measurements).await?
            {
                if let Some(base) = profile.profiles.normal_gpu.as_mut() {
                    base.ctx_size = probed_ctx;
                }
                profile.probe_completed = true;
                profile.probed_ctx_size = Some(probed_ctx);
            } else {
                // Probe ran but all rungs failed — record the attempt so we
                // don't loop forever on every reconcile tick.
                profile.probe_completed = true;
                profile.probed_ctx_size = None;
            }

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

/// Build the descending ctx-size ladder we will probe on a GPU machine.
///
/// Cap is EXACTLY `requested_ctx_size` — never higher, even if the request
/// sits below [`USER_CTX_SIZE_MIN`]. If the request is below the safety
/// floor the ladder is empty (caller should treat this as "no probe
/// needed, honor the request as-is"). Otherwise the ladder is descending,
/// deduped, and includes the request as the first rung.
fn build_ctx_probe_ladder(requested_ctx_size: u32) -> Vec<u32> {
    if requested_ctx_size < USER_CTX_SIZE_MIN {
        // Requests below the floor get no ladder — the caller must decide
        // whether to honor or reject. We never silently inflate above the
        // requested value.
        return Vec::new();
    }
    let cap = requested_ctx_size;
    let mut ladder: Vec<u32> = CTX_SIZE_PROBE_LADDER
        .iter()
        .copied()
        .filter(|&v| v <= cap && v >= USER_CTX_SIZE_MIN)
        .collect();
    // Always include the requested value as the very first probe so we try
    // exactly what the user asked for before stepping down.
    if !ladder.iter().any(|&v| v == cap) {
        ladder.insert(0, cap);
    }
    ladder.sort_unstable_by(|a, b| b.cmp(a));
    ladder.dedup();
    ladder
}

/// Path to the `llama-server` binary used by the probe. Hardcoded to the
/// canonical absolute path because the probe runs out-of-band from systemd
/// (and from the unit's resolved PATH).
const LLAMA_SERVER_BIN: &str = "/usr/sbin/llama-server";

/// stderr substrings that signal the probe MUST fail this rung.
///
/// llama.cpp emits these on out-of-VRAM / out-of-host-RAM allocation
/// failure. Match is case-insensitive (we lowercase the haystack first).
const OOM_SIGNATURES: &[&str] = &[
    "oom",
    "cuda out of memory",
    "out of device memory",
    "errorоutofdevicememory", // safety net for unicode-mangled logs
    "vk::result::erroroutofdevicememory",
    "failed to allocate",
    "cudamalloc failed",
    "ggml_cuda_host_malloc",
    "vkallocatememory failed",
    "unable to allocate",
];

/// Outcome reported by a single probe run.
#[derive(Debug, Clone, PartialEq, Eq)]
enum ProbeOutcome {
    /// Server became ready within the timeout — this rung is viable.
    Ready,
    /// Hit an OOM-style stderr signature → not viable, step down.
    OutOfMemory(String),
    /// Process exited before becoming ready (and not via OOM signature).
    ProcessExitedEarly(String),
    /// Timed out waiting for readiness.
    Timeout,
    /// Setup failure (binary missing, spawn error, env write failure, etc.)
    SetupError(String),
}

impl ProbeOutcome {
    fn is_viable(&self) -> bool {
        matches!(self, ProbeOutcome::Ready)
    }
}

/// Async closure type used to inject a fake probe in tests. Real impl is
/// [`probe_run_llama_server`].
type ProbeFn = Box<
    dyn for<'a> Fn(
            &'a RuntimeSettings,
            &'a RuntimeInputs,
        )
            -> std::pin::Pin<Box<dyn std::future::Future<Output = ProbeOutcome> + Send + 'a>>
        + Send
        + Sync,
>;

/// Probe a descending ctx-size ladder against the heuristic GPU base.
/// Returns the FIRST ctx-size that boots `llama-server` successfully (i.e.
/// the largest viable). Returns Ok(None) when there is no GPU base or
/// every rung fails — the caller can then either fall back to the
/// heuristic ctx or downgrade to CPU-only.
async fn probe_largest_viable_gpu_ctx(
    profile: &RuntimeProfile,
    measurements: &mut Vec<BenchmarkMeasurement>,
) -> Result<Option<u32>> {
    let probe: ProbeFn = Box::new(|settings, inputs| {
        Box::pin(probe_run_llama_server(
            settings.clone(),
            inputs.clone(),
            Duration::from_secs(60),
        ))
    });
    probe_largest_viable_gpu_ctx_with(profile, measurements, &probe).await
}

/// Test-friendly inner loop: takes an injected probe closure so tests can
/// drive deterministic outcomes per rung without touching llama-server.
async fn probe_largest_viable_gpu_ctx_with(
    profile: &RuntimeProfile,
    measurements: &mut Vec<BenchmarkMeasurement>,
    probe: &ProbeFn,
) -> Result<Option<u32>> {
    let Some(base) = profile.profiles.normal_gpu.clone() else {
        return Ok(None);
    };
    if base.gpu_layers <= 0 {
        return Ok(None);
    }

    let ladder = build_ctx_probe_ladder(profile.inputs.requested_ctx_size);
    if ladder.is_empty() {
        return Ok(None);
    }

    for ctx in ladder {
        let candidate_settings = RuntimeSettings {
            ctx_size: ctx,
            ..base.clone()
        };
        let outcome = probe(&candidate_settings, &profile.inputs).await;
        let label = format!("ctx-probe-{ctx}");
        measurements.push(BenchmarkMeasurement {
            target: "ctx_probe".into(),
            candidate: format!("{label} -> {outcome:?}"),
            average_latency_ms: 0,
            sample_count: 1,
        });
        if outcome.is_viable() {
            info!(
                "[ai_runtime] ctx probe accepted ctx_size={} (largest viable)",
                ctx
            );
            return Ok(Some(ctx));
        }
        warn!(
            "[ai_runtime] ctx probe ctx_size={} rejected ({:?}), stepping down",
            ctx, outcome
        );
    }
    warn!(
        "[ai_runtime] ctx probe found NO viable rung, keeping heuristic ctx={}; may OOM at runtime",
        base.ctx_size
    );
    Ok(None)
}

/// RAII guard that always tries to kill its child on Drop.
///
/// Spawned llama-server probes MUST NOT survive the probe function — even
/// on panic or timeout — because a leaked child would compete with the
/// systemd-managed instance for VRAM (and the GPU port).
struct ChildGuard {
    child: Option<tokio::process::Child>,
}

impl ChildGuard {
    fn new(child: tokio::process::Child) -> Self {
        Self { child: Some(child) }
    }

    /// Best-effort terminate. Sends SIGKILL via `Child::start_kill` then
    /// drops the handle. We do NOT await `.wait()` here because `Drop`
    /// can't be async; the kernel will reap.
    fn terminate(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.start_kill();
        }
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        self.terminate();
    }
}

/// Spawn `llama-server` directly (NOT through systemd) with the given
/// settings, watch stderr for OOM signatures, poll `/v1/chat/completions`
/// for readiness, and report a [`ProbeOutcome`].
///
/// This intentionally bypasses the systemd unit because that unit has
/// `Restart=always`: an OOM-killed process would silently respawn and the
/// poll would eventually catch a brief "ready" window between crashes,
/// greenlighting a broken ctx_size. Direct spawn = direct truth.
async fn probe_run_llama_server(
    settings: RuntimeSettings,
    inputs: RuntimeInputs,
    timeout: Duration,
) -> ProbeOutcome {
    use tokio::io::{AsyncBufReadExt, BufReader};
    use tokio::process::Command as TokioCommand;

    if !Path::new(LLAMA_SERVER_BIN).exists() {
        return ProbeOutcome::SetupError(format!("{LLAMA_SERVER_BIN} not found"));
    }

    // Read the optional MMPROJ from the env file; absent is fine — we just
    // omit the flag.
    let env_content = fs::read_to_string(llama_env_path()).unwrap_or_default();
    let mmproj = read_env_var(&env_content, "LIFEOS_AI_MMPROJ");
    let host = read_env_var(&env_content, "LIFEOS_AI_HOST").unwrap_or_else(|| "127.0.0.1".into());

    let model_path = format!("/var/lib/lifeos/models/{}", inputs.model);
    let mut cmd = TokioCommand::new(LLAMA_SERVER_BIN);
    cmd.arg("--model").arg(&model_path);
    if let Some(mmproj) = mmproj {
        let mmproj_path = format!("/var/lib/lifeos/models/{mmproj}");
        if Path::new(&mmproj_path).exists() {
            cmd.arg("--mmproj").arg(&mmproj_path);
        }
    }
    cmd.arg("--alias")
        .arg(&inputs.alias)
        .arg("--host")
        .arg(&host)
        .arg("--port")
        .arg(inputs.port.to_string())
        .arg("--ctx-size")
        .arg(settings.ctx_size.to_string())
        .arg("--threads")
        .arg(settings.threads.to_string())
        .arg("--n-gpu-layers")
        .arg(settings.gpu_layers.to_string())
        .arg("--parallel")
        .arg(settings.parallel.to_string())
        .arg("--batch-size")
        .arg(settings.batch_size.to_string())
        .arg("--ubatch-size")
        .arg(settings.ubatch_size.to_string())
        .arg("--n-predict")
        .arg("16")
        .arg("--flash-attn")
        .arg("auto")
        .arg("--cache-type-k")
        .arg("q8_0")
        .arg("--cache-type-v")
        .arg("q8_0")
        .arg("-sm")
        .arg("none")
        .arg("-mg")
        .arg("0")
        .arg("--jinja")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);

    let child = match cmd.spawn() {
        Ok(child) => child,
        Err(error) => return ProbeOutcome::SetupError(format!("spawn failed: {error}")),
    };
    let mut guard = ChildGuard::new(child);
    let stderr = guard
        .child
        .as_mut()
        .and_then(|c| c.stderr.take())
        .map(BufReader::new);

    let oom_flag = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let oom_msg = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
    let stderr_task = if let Some(mut reader) = stderr {
        let oom_flag = oom_flag.clone();
        let oom_msg = oom_msg.clone();
        Some(tokio::spawn(async move {
            let mut buf = String::new();
            loop {
                buf.clear();
                match reader.read_line(&mut buf).await {
                    Ok(0) => break,
                    Ok(_) => {
                        let lower = buf.to_ascii_lowercase();
                        if OOM_SIGNATURES.iter().any(|sig| lower.contains(sig)) {
                            *oom_msg.lock().unwrap() = buf.trim().to_string();
                            oom_flag.store(true, std::sync::atomic::Ordering::SeqCst);
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        }))
    } else {
        None
    };

    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
    {
        Ok(c) => c,
        Err(error) => return ProbeOutcome::SetupError(format!("client build failed: {error}")),
    };

    let outcome = tokio::select! {
        biased;
        // Hard timeout for the whole probe.
        _ = tokio::time::sleep(timeout) => ProbeOutcome::Timeout,
        // Watch for OOM marker.
        _ = wait_for_oom(&oom_flag) => {
            let msg = oom_msg.lock().unwrap().clone();
            ProbeOutcome::OutOfMemory(msg)
        }
        // Watch for early child exit.
        exit = wait_child_exit(&mut guard) => exit,
        // Watch for server readiness.
        ready = poll_until_ready(&client, &inputs, timeout) => ready,
    };

    // Always kill the child before returning. Drop also covers this but be
    // explicit for clarity.
    guard.terminate();
    if let Some(handle) = stderr_task {
        handle.abort();
    }

    outcome
}

async fn wait_for_oom(flag: &std::sync::Arc<std::sync::atomic::AtomicBool>) {
    loop {
        if flag.load(std::sync::atomic::Ordering::SeqCst) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

async fn wait_child_exit(guard: &mut ChildGuard) -> ProbeOutcome {
    let Some(child) = guard.child.as_mut() else {
        return ProbeOutcome::ProcessExitedEarly("no child handle".into());
    };
    match child.wait().await {
        Ok(status) => ProbeOutcome::ProcessExitedEarly(format!("exit status: {status}")),
        Err(error) => ProbeOutcome::ProcessExitedEarly(format!("wait failed: {error}")),
    }
}

async fn poll_until_ready(
    client: &reqwest::Client,
    inputs: &RuntimeInputs,
    timeout: Duration,
) -> ProbeOutcome {
    let deadline = std::time::Instant::now() + timeout;
    let endpoint = format!("http://127.0.0.1:{}/v1/chat/completions", inputs.port);
    let payload = serde_json::json!({
        "model": inputs.alias,
        "messages": [{"role": "user", "content": "ok"}],
        "max_tokens": 1,
        "temperature": 0.0,
        "stream": false
    });
    while std::time::Instant::now() < deadline {
        match client.post(&endpoint).json(&payload).send().await {
            Ok(resp) if resp.status().is_success() => return ProbeOutcome::Ready,
            _ => {}
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    ProbeOutcome::Timeout
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
    let base = profile.profiles.cpu_ram.clone();
    let ctx_size = base.ctx_size;
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
                ..base.clone()
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
                ..base.clone()
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
                ..base
            },
        },
    ])
}

fn build_game_guard_candidates(profile: &RuntimeProfile) -> Vec<RuntimeCandidate> {
    let physical = profile.fingerprint.physical_cpus.max(1) as u32;
    let Some(base) = profile.profiles.game_guard_cpu_fallback.clone() else {
        return Vec::new();
    };
    let ctx_size = base.ctx_size;
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
                ..base.clone()
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
                ..base.clone()
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
                ..base
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
            model: None,
            mmproj: None,
        };
        let content = settings.to_env_content("test");
        assert!(content.contains("LIFEOS_AI_CTX_SIZE=4096"));
        assert!(content.contains("LIFEOS_AI_THREADS=6"));
        assert!(content.contains("LIFEOS_AI_UBATCH_SIZE=128"));
        // Without explicit model/mmproj, the env file must NOT pin them so
        // the base /etc/lifeos/llama-server.env wins.
        assert!(!content.contains("LIFEOS_AI_MODEL="));
        assert!(!content.contains("LIFEOS_AI_MMPROJ="));

        let with_model = RuntimeSettings {
            model: Some("Qwen3.5-4B-Q4_K_M.gguf".into()),
            mmproj: Some("Qwen3.5-4B-mmproj-F16.gguf".into()),
            ..settings
        };
        let content = with_model.to_env_content("test");
        assert!(content.contains("LIFEOS_AI_MODEL=Qwen3.5-4B-Q4_K_M.gguf"));
        assert!(content.contains("LIFEOS_AI_MMPROJ=Qwen3.5-4B-mmproj-F16.gguf"));

        // CPU profile (gpu_layers == 0) emits --device none and an empty
        // GPU tuning string so the lifeos-llama-server Quadlet's bash
        // wrapper short-circuits the GPU-only flags. Catches a regression
        // where a future refactor stops emitting these env vars and
        // llama-server crash-loops on '-mg 0 (available devices: 0)'.
        assert!(content.contains("LIFEOS_AI_DEVICE_FLAGS=--device none"));
        assert!(content.contains("LIFEOS_AI_GPU_TUNING=\n") || content.ends_with("LIFEOS_AI_GPU_TUNING=\n"));
    }

    #[test]
    fn runtime_settings_emits_gpu_tuning_when_gpu_layers_active() {
        // Mirror of the GPU branch — ensures GPU deploys keep getting
        // the same tuning flags the Quadlet used to hard-code.
        let settings = RuntimeSettings {
            ctx_size: 32_768,
            threads: 8,
            gpu_layers: 99,
            parallel: 2,
            batch_size: 1024,
            ubatch_size: 256,
            model: Some("Qwen3.5-9B-Q4_K_M.gguf".into()),
            mmproj: Some("Qwen3.5-9B-mmproj-F16.gguf".into()),
        };
        let content = settings.to_env_content("test");
        // Pin the EMPTY-line invariant precisely so a future regression
        // that emits `LIFEOS_AI_DEVICE_FLAGS=--device none` for a GPU
        // profile (CPU value swapped in) trips this test.
        assert!(content.contains("LIFEOS_AI_DEVICE_FLAGS=\n"));
        assert!(content.contains("LIFEOS_AI_GPU_TUNING=-sm none -mg 0 --flash-attn auto"));
    }

    #[test]
    fn parse_nvidia_smi_query_picks_highest_vram_dedicated_gpu() {
        // Multi-GPU csv output (one iGPU + one dGPU). is_dedicated_gpu
        // filters Intel out, so we MUST end up with the NVIDIA card even
        // though Intel reported more "memory" (it's shared system RAM and
        // unrelated to dedicated VRAM).
        let csv = "\
NVIDIA GeForce RTX 5070 Laptop GPU, 12227
Intel(R) Iris Xe Graphics, 32768
NVIDIA GeForce RTX 4060 Laptop GPU, 8192
";
        let dev = parse_nvidia_smi_query(csv).expect("expected an NVIDIA device");
        assert_eq!(dev.name, "NVIDIA GeForce RTX 5070 Laptop GPU");
        assert_eq!(dev.total_mem_mb, 12_227);
        assert_eq!(dev.backend, "nvidia");
    }

    #[test]
    fn parse_nvidia_smi_query_skips_malformed_rows_without_aborting() {
        // The pre-fix version used `?` and would early-return None at the
        // first malformed row, dropping every row after it. With let-else
        // continue, the second valid row is still found.
        let csv = "\
[N/A], [N/A]
NVIDIA GeForce RTX 5070, 12227
";
        let dev = parse_nvidia_smi_query(csv).expect("RTX 5070 must still be picked up");
        assert_eq!(dev.name, "NVIDIA GeForce RTX 5070");
    }

    #[test]
    fn parse_nvidia_smi_query_returns_none_on_empty_or_no_dgpu() {
        assert!(parse_nvidia_smi_query("").is_none());
        // Pure iGPU output — no dedicated GPU, must return None.
        assert!(parse_nvidia_smi_query("Intel(R) UHD Graphics, 8192\n").is_none());
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
                    model: None,
                    mmproj: None,
                },
                normal_gpu: None,
                game_guard_cpu_fallback: None,
            },
            probe_completed: false,
            probed_ctx_size: None,
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
            model: None,
            mmproj: None,
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
        assert!(
            content.contains("EnvironmentFile=-/var/lib/lifeos/llama-server-user-override.env"),
            "user override file must be in the dropin so the user value can win"
        );
        // Order matters: user override MUST appear after runtime profile.
        let runtime_idx = content
            .find("llama-server-runtime-profile.env")
            .expect("runtime entry");
        let user_idx = content
            .find("llama-server-user-override.env")
            .expect("user entry");
        assert!(
            user_idx > runtime_idx,
            "user override must be loaded AFTER runtime profile so it wins"
        );
    }

    #[test]
    fn write_and_read_user_ctx_size_override_roundtrip() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let path = tmp.path().join("override.env");
        std::env::set_var("LIFEOS_AI_USER_OVERRIDE_ENV_PATH", &path);
        // No file yet → no override.
        assert!(user_ctx_size_override().is_none());
        write_user_ctx_size_override(65536).expect("write");
        assert_eq!(user_ctx_size_override(), Some(65536));
        // Mode 0644 on unix.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o644);
        }
        clear_user_ctx_size_override().expect("clear");
        assert!(user_ctx_size_override().is_none());
        std::env::remove_var("LIFEOS_AI_USER_OVERRIDE_ENV_PATH");
    }

    #[test]
    fn user_ctx_size_override_rejects_out_of_range() {
        assert!(write_user_ctx_size_override(USER_CTX_SIZE_MIN - 1).is_err());
        assert!(write_user_ctx_size_override(USER_CTX_SIZE_MAX + 1).is_err());
    }

    #[test]
    fn ctx_probe_ladder_descending_capped_by_request() {
        let ladder = build_ctx_probe_ladder(131_072);
        assert!(
            ladder.windows(2).all(|w| w[0] > w[1]),
            "must be strictly descending: {:?}",
            ladder
        );
        assert_eq!(ladder.first().copied(), Some(131_072));
        // No rung exceeds the request.
        assert!(ladder.iter().all(|&v| v <= 131_072));
        // Stays above the safety floor.
        assert!(ladder.iter().all(|&v| v >= USER_CTX_SIZE_MIN));
    }

    #[test]
    fn ctx_probe_ladder_caps_below_default_rung() {
        let ladder = build_ctx_probe_ladder(20_000);
        // Requested value should be the FIRST rung; no rung larger.
        assert_eq!(ladder.first().copied(), Some(20_000));
        assert!(ladder.iter().all(|&v| v <= 20_000));
        // The next rung from CTX_SIZE_PROBE_LADDER below 20_000 is 16_384.
        assert!(ladder.contains(&16_384));
    }

    #[test]
    fn ctx_probe_ladder_includes_request_when_off_ladder() {
        let ladder = build_ctx_probe_ladder(48_000);
        assert!(ladder.contains(&48_000));
        assert!(ladder.windows(2).all(|w| w[0] > w[1]));
    }

    #[test]
    fn cpu_heuristic_ceiling_stays_conservative_without_probe() {
        // CPU mode can't safely probe (host-RAM OOM is destructive), so
        // ceilings stay conservative: 8K / 6K / 4K. Users can raise via
        // dashboard / API override.
        let fp_32gb = HardwareFingerprint {
            cpu_model: "cpu".into(),
            logical_cpus: 16,
            physical_cpus: 8,
            total_ram_mb: 32 * 1024,
            accelerator_backend: None,
            accelerator_name: None,
            accelerator_total_mem_mb: None,
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
        assert_eq!(heuristic_cpu_profile(&fp_32gb, &inputs).ctx_size, 8_192);

        let mut fp_16gb = fp_32gb.clone();
        fp_16gb.total_ram_mb = 16 * 1024;
        assert_eq!(heuristic_cpu_profile(&fp_16gb, &inputs).ctx_size, 6_144);

        let mut fp_low = fp_32gb;
        fp_low.total_ram_mb = 8 * 1024;
        assert_eq!(heuristic_cpu_profile(&fp_low, &inputs).ctx_size, 4_096);
    }

    #[test]
    fn default_ctx_size_matches_user_facing_baseline() {
        // The benchmarker default MUST track the user-facing baseline in
        // image/files/etc/lifeos/llama-server.env (PR #48 = 131072).
        // If you change one, change the other.
        assert_eq!(DEFAULT_CTX_SIZE, 131_072);
    }

    #[test]
    fn ctx_probe_ladder_is_empty_when_request_below_floor() {
        // C3 fix: cap is EXACTLY requested_ctx_size, never inflated to the
        // floor. Below-floor requests get an empty ladder.
        let ladder = build_ctx_probe_ladder(USER_CTX_SIZE_MIN - 1);
        assert!(
            ladder.is_empty(),
            "below-floor request must NOT inflate cap above the request: got {ladder:?}"
        );
    }

    #[test]
    fn ctx_probe_ladder_cap_never_exceeds_request() {
        for &request in &[USER_CTX_SIZE_MIN, 2_000u32, 16_384, 50_000, 131_072] {
            let ladder = build_ctx_probe_ladder(request);
            assert!(
                ladder.iter().all(|&v| v <= request),
                "ladder for request={request} must not exceed request: {ladder:?}"
            );
        }
    }

    fn dummy_gpu_profile(requested: u32) -> RuntimeProfile {
        let fp = HardwareFingerprint {
            cpu_model: "cpu".into(),
            logical_cpus: 16,
            physical_cpus: 8,
            total_ram_mb: 32 * 1024,
            accelerator_backend: Some("vulkan".into()),
            accelerator_name: Some("NVIDIA Test GPU".into()),
            accelerator_total_mem_mb: Some(8192),
            dedicated_gpu: true,
            driver_version: None,
            llama_server_version: None,
        };
        let inputs = RuntimeInputs {
            model: DEFAULT_MODEL.into(),
            alias: DEFAULT_ALIAS.into(),
            port: DEFAULT_PORT,
            requested_ctx_size: requested,
        };
        let mut profile = build_heuristic_profile(&(fp, inputs));
        // build_heuristic_profile may not set normal_gpu when dedicated_gpu
        // is true but vram is below threshold; force it on for the test.
        if profile.profiles.normal_gpu.is_none() {
            profile.profiles.normal_gpu = Some(RuntimeSettings {
                ctx_size: requested,
                threads: 4,
                gpu_layers: 99,
                parallel: 1,
                batch_size: 512,
                ubatch_size: 256,
                model: Some("Qwen3.5-9B-Q4_K_M.gguf".into()),
                mmproj: Some("Qwen3.5-9B-mmproj-F16.gguf".into()),
            });
        }
        profile
    }

    fn make_probe(outcomes: Vec<ProbeOutcome>) -> ProbeFn {
        let cell = std::sync::Arc::new(std::sync::Mutex::new(outcomes.into_iter()));
        Box::new(move |_settings, _inputs| {
            let cell = cell.clone();
            Box::pin(async move {
                cell.lock()
                    .unwrap()
                    .next()
                    .unwrap_or(ProbeOutcome::SetupError("exhausted".into()))
            })
        })
    }

    #[tokio::test]
    async fn probe_returns_first_rung_when_largest_succeeds() {
        let profile = dummy_gpu_profile(131_072);
        let mut measurements = Vec::new();
        let probe = make_probe(vec![ProbeOutcome::Ready]);
        let result = probe_largest_viable_gpu_ctx_with(&profile, &mut measurements, &probe)
            .await
            .expect("probe ok");
        assert_eq!(result, Some(131_072));
        assert_eq!(measurements.len(), 1);
    }

    #[tokio::test]
    async fn probe_descends_to_smaller_when_largest_fails() {
        let profile = dummy_gpu_profile(131_072);
        let mut measurements = Vec::new();
        // 131072 OOM, 65536 OOM, 32768 OK.
        let probe = make_probe(vec![
            ProbeOutcome::OutOfMemory("cuda out of memory".into()),
            ProbeOutcome::OutOfMemory("cuda out of memory".into()),
            ProbeOutcome::Ready,
        ]);
        let result = probe_largest_viable_gpu_ctx_with(&profile, &mut measurements, &probe)
            .await
            .expect("probe ok");
        assert_eq!(result, Some(32_768));
        assert_eq!(measurements.len(), 3);
    }

    #[tokio::test]
    async fn probe_returns_none_when_all_rungs_fail() {
        let profile = dummy_gpu_profile(16_384);
        let mut measurements = Vec::new();
        // Every rung fails — 16384, 8192 (and the request itself if it
        // wasn't already in the ladder).
        let probe = make_probe(vec![
            ProbeOutcome::OutOfMemory("oom".into()),
            ProbeOutcome::OutOfMemory("oom".into()),
            ProbeOutcome::OutOfMemory("oom".into()),
            ProbeOutcome::OutOfMemory("oom".into()),
        ]);
        let result = probe_largest_viable_gpu_ctx_with(&profile, &mut measurements, &probe)
            .await
            .expect("probe ok");
        assert_eq!(result, None);
        assert!(!measurements.is_empty());
    }

    #[test]
    fn apply_runtime_env_bypass_skips_user_override() {
        // Regression test for C2: probe path MUST NOT silently rewrite the
        // candidate ctx_size with the user override.
        let tmp = tempfile::tempdir().expect("tmpdir");
        let user_path = tmp.path().join("user.env");
        let runtime_path = tmp.path().join("runtime.env");
        std::env::set_var("LIFEOS_AI_USER_OVERRIDE_ENV_PATH", &user_path);
        std::env::set_var("LIFEOS_AI_RUNTIME_ENV_PATH", &runtime_path);
        write_user_ctx_size_override(65536).expect("write user override");

        let candidate = RuntimeSettings {
            ctx_size: 16_384,
            threads: 4,
            gpu_layers: 99,
            parallel: 1,
            batch_size: 512,
            ubatch_size: 256,
            model: None,
            mmproj: None,
        };
        // Default path applies the user override (overwriting candidate).
        apply_runtime_env(&candidate).expect("apply");
        let normal = fs::read_to_string(&runtime_path).expect("read");
        assert!(normal.contains("LIFEOS_AI_CTX_SIZE=65536"), "{normal}");

        // Bypass path keeps the candidate verbatim.
        apply_runtime_env_bypass_user_override(&candidate).expect("apply bypass");
        let bypass = fs::read_to_string(&runtime_path).expect("read");
        assert!(bypass.contains("LIFEOS_AI_CTX_SIZE=16384"), "{bypass}");

        clear_user_ctx_size_override().expect("clear");
        std::env::remove_var("LIFEOS_AI_USER_OVERRIDE_ENV_PATH");
        std::env::remove_var("LIFEOS_AI_RUNTIME_ENV_PATH");
    }

    #[test]
    fn user_service_content_points_to_runtime_and_guard_envs() {
        let content = llama_user_service_content();
        assert!(content.contains("EnvironmentFile=-/etc/lifeos/llama-server.env"));
        assert!(
            content.contains("EnvironmentFile=-/var/lib/lifeos/llama-server-runtime-profile.env")
        );
        assert!(content.contains("EnvironmentFile=-/var/lib/lifeos/llama-server-game-guard.env"));
        assert!(content.contains("EnvironmentFile=-/var/lib/lifeos/llama-server-user-override.env"));
        assert!(content.contains("--n-gpu-layers ${LIFEOS_AI_GPU_LAYERS}"));
        assert!(content.contains("Environment=__NV_PRIME_RENDER_OFFLOAD=1"));
    }
}
