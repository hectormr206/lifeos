//! GPU Game Guard
//!
//! Detecta automaticamente cuando un juego está corriendo y libera la VRAM del LLM local,
//! luego la restaura cuando el juego se cierra.
//!
//! Mediciones reales con RTX 5070 Ti (12 GB VRAM):
//! - Qwen3.5-4B Q4_K_M con 16K context: ~3.5 GB VRAM en idle
//! - Gaming (RE Requiem): 11.8/11.9 GB VRAM (98%) → stuttering
//!
//! Estrategia: cuando se detecta un juego, aplica un perfil CPU/RAM completo
//! via override env y reinicia llama-server. Al cerrar el juego, limpia el
//! override para restaurar el perfil normal del runtime.

use crate::ai_runtime_profile::RuntimeSettings;
use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use log::{error, info, warn};
use serde::{Deserialize, Serialize};
use std::fs;
use std::process::Command;
use std::sync::Arc;
use tokio::sync::RwLock;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Interval between game-detection polls (seconds)
const DEFAULT_POLL_INTERVAL_SECS: u64 = 10;

/// VRAM threshold (MB) above which a process is considered a game candidate
const DEFAULT_VRAM_THRESHOLD_MB: u64 = 500;

/// Default path to llama-server environment file
const DEFAULT_LLAMA_ENV_PATH: &str = "/etc/lifeos/llama-server.env";

/// Processes that use GPU but are NOT games
const NON_GAME_GPU_PROCESSES: &[&str] = &[
    "llama-server",
    "llama_server",
    "Xorg",
    "Xwayland",
    "gnome-shell",
    "cosmic-comp",
    "cosmic-panel",
    "kwin_wayland",
    "kwin_x11",
    "mutter",
    "firefox",
    "chrome",
    "chromium",
    "electron",
    "code", // VSCode
    "Discord",
    "plasmashell",
    "sway",
    "hyprland",
    "waybar",
    "obs",
    "blender",
    "mpv",
    "vlc",
];

/// Process names that are launchers (not games themselves)
const LAUNCHER_PROCESSES: &[&str] = &["steam", "steamwebhelper", "lutris", "heroic", "gamemoded"];

/// Processes that often appear alongside games, but are not the game binary itself.
const SUPPORT_PROCESS_NAMES: &[&str] = &["gamescope", "mangohud", "proton"];

/// Processes that MAY indicate a game but are ambiguous on their own.
/// wineserver/wine can run for non-game Windows apps (Office, etc.).
/// Only count as game if a high-confidence game indicator is also present
/// (gamescope, mangohud, proton, or high VRAM usage).
const AMBIGUOUS_GAME_PROCESSES: &[&str] = &["wine", "wine64", "wineserver"];

/// Process names that ALWAYS indicate a game is running (high confidence)
const GAME_PROCESS_NAMES: &[&str] = &[
    "UE4Game",
    "UE5Game",
    // Resident Evil series
    "RERequiem",
    "re9.exe",
    "re8.exe",
    "re8",
    "re4.exe",
    "re4",
    "re2.exe",
    "re2",
];

/// Extremely generic executable names that only count as games when the
/// executable/cmdline clearly points at a game installation directory.
const GENERIC_GAME_EXECUTABLES: &[&str] = &["Game.exe", "game.exe"];

/// Safe path markers that strongly suggest the process comes from a game install.
/// Kept intentionally narrow to favor precision over recall.
const GAME_INSTALL_PATH_MARKERS: &[&str] = &[
    "steamapps/common",
    "steamapps/compatdata",
    "/heroic/",
    "/lutris/",
    "/legendary/",
    "/games/",
    "/opt/games/",
];

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// LLM execution mode: either on the GPU or on the CPU
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LlmMode {
    /// LLM runs entirely on GPU (normal operation)
    Gpu,
    /// LLM runs on CPU/RAM (game is using the VRAM)
    Cpu,
}

/// How the game was detected
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DetectionMethod {
    /// GameMode D-Bus / gamemoded daemon reported active
    GameMode,
    /// Known game process name found in /proc
    ProcessName,
    /// Process consuming >threshold MB of VRAM via nvidia-smi pmon
    VramUsage,
}

/// Information about the detected game
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GameInfo {
    pub pid: u32,
    pub name: String,
    pub window_title: Option<String>,
    pub detection_method: DetectionMethod,
}

/// Runtime state snapshot (returned by the API, sent via broadcast)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GameGuardState {
    pub game_detected: bool,
    pub game_name: Option<String>,
    pub game_pid: Option<u32>,
    pub game_window_title: Option<String>,
    pub llm_mode: LlmMode,
    pub last_check: DateTime<Utc>,
    pub supported: bool,
    pub guard_enabled: bool,
    pub assistant_enabled: bool,
}

/// Configuration for the Game Guard subsystem
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GameGuardConfig {
    /// Enable/disable the guard entirely
    pub enabled: bool,
    /// Whether the current machine/runtime profile can actually use Game Guard
    pub supported: bool,
    /// How often to poll for game activity (seconds)
    pub poll_interval_secs: u64,
    /// Enable the in-game AI assistant feature
    pub game_assistant_enabled: bool,
    /// VRAM usage threshold (MB) to flag a process as a game
    pub vram_threshold_mb: u64,
    /// Path to the llama-server environment file
    pub llama_server_env_path: String,
    /// CPU fallback profile used while a game is active.
    pub cpu_fallback_profile: Option<RuntimeSettings>,
}

impl Default for GameGuardConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            supported: true,
            poll_interval_secs: DEFAULT_POLL_INTERVAL_SECS,
            game_assistant_enabled: true,
            vram_threshold_mb: DEFAULT_VRAM_THRESHOLD_MB,
            llama_server_env_path: DEFAULT_LLAMA_ENV_PATH.to_string(),
            cpu_fallback_profile: None,
        }
    }
}

// ---------------------------------------------------------------------------
// Internal mutable state (held inside RwLock)
// ---------------------------------------------------------------------------

struct GameGuardInner {
    config: GameGuardConfig,
    current_mode: LlmMode,
    last_game: Option<GameInfo>,
    last_check: DateTime<Utc>,
}

// ---------------------------------------------------------------------------
// GameGuard
// ---------------------------------------------------------------------------

/// GPU Game Guard — monitors for game processes and switches LLM to CPU when needed.
pub struct GameGuard {
    inner: Arc<RwLock<GameGuardInner>>,
}

impl GameGuard {
    /// Create a new `GameGuard` with the given configuration.
    pub fn new(config: GameGuardConfig) -> Self {
        let current_mode =
            llm_mode_from_layers(effective_gpu_layers(&config.llama_server_env_path));
        let inner = GameGuardInner {
            config,
            current_mode,
            last_game: None,
            last_check: Utc::now(),
        };
        Self {
            inner: Arc::new(RwLock::new(inner)),
        }
    }

    /// Returns a snapshot of the current guard state.
    pub async fn state(&self) -> GameGuardState {
        let inner = self.inner.read().await;
        GameGuardState {
            game_detected: inner.last_game.is_some(),
            game_name: inner.last_game.as_ref().map(|g| g.name.clone()),
            game_pid: inner.last_game.as_ref().map(|g| g.pid),
            game_window_title: inner
                .last_game
                .as_ref()
                .and_then(|g| g.window_title.clone()),
            llm_mode: inner.current_mode.clone(),
            last_check: inner.last_check,
            supported: inner.config.supported,
            guard_enabled: inner.config.enabled && inner.config.supported,
            assistant_enabled: inner.config.game_assistant_enabled && inner.config.supported,
        }
    }

    /// Enable or disable the guard at runtime.
    pub async fn set_enabled(&self, enabled: bool) {
        let mut inner = self.inner.write().await;
        inner.config.enabled = enabled;
        info!(
            "[game_guard] guard {}",
            if enabled { "enabled" } else { "disabled" }
        );
    }

    /// Enable or disable the game assistant at runtime.
    pub async fn set_assistant_enabled(&self, enabled: bool) {
        let mut inner = self.inner.write().await;
        inner.config.game_assistant_enabled = enabled;
        info!(
            "[game_guard] game assistant {}",
            if enabled { "enabled" } else { "disabled" }
        );
    }

    /// Sync runtime support and fallback profile when Axi recalculates hardware tuning.
    pub async fn sync_runtime_profile(
        &self,
        supported: bool,
        cpu_fallback_profile: Option<RuntimeSettings>,
    ) {
        let mut inner = self.inner.write().await;
        inner.config.supported = supported;
        inner.config.cpu_fallback_profile = cpu_fallback_profile;
        if !supported {
            if let Err(e) = crate::ai_runtime_profile::clear_game_guard_override() {
                warn!("[game_guard] failed to clear stale override while disabling support: {e}");
            }
            inner.last_game = None;
            inner.current_mode =
                llm_mode_from_layers(effective_gpu_layers(&inner.config.llama_server_env_path));
        }
    }

    /// Core poll: detects games, switches LLM mode if needed, returns new state.
    ///
    /// This is safe to call concurrently — it takes the write lock only when a
    /// mode switch is required.
    pub async fn check_and_switch(&self) -> Result<GameGuardState> {
        // Read current config/mode without holding the write lock during slow I/O
        let (enabled, supported, current_mode, vram_threshold) = {
            let inner = self.inner.read().await;
            (
                inner.config.enabled,
                inner.config.supported,
                inner.current_mode.clone(),
                inner.config.vram_threshold_mb,
            )
        };

        if !enabled || !supported {
            return Ok(self.state().await);
        }

        // Detect game (blocking I/O — run in a blocking thread to not starve Tokio)
        let game_info = tokio::task::spawn_blocking(move || detect_game(vram_threshold))
            .await
            .context("game detection task panicked")?;

        let mut inner = self.inner.write().await;
        inner.last_check = Utc::now();

        match (&game_info, &current_mode) {
            // Game appeared and we're still on GPU → switch to CPU
            (Some(game), LlmMode::Gpu) => {
                info!(
                    "[game_guard] game detected: '{}' (pid {}, method {:?}) — offloading LLM to CPU",
                    game.name, game.pid, game.detection_method
                );
                match persist_game_guard_override(inner.config.cpu_fallback_profile.as_ref()) {
                    Ok(_) => {}
                    Err(e) => warn!("[game_guard] persist_game_guard_override failed: {e}"),
                }
                inner.current_mode = LlmMode::Cpu;
                inner.last_game = game_info;
            }

            // No game and we're on CPU → restore GPU
            (None, LlmMode::Cpu) => {
                info!("[game_guard] no game detected — restoring LLM to GPU");
                match clear_game_guard_override_and_restart() {
                    Ok(_) => {}
                    Err(e) => warn!("[game_guard] clear_game_guard_override failed: {e}"),
                }
                inner.current_mode = LlmMode::Gpu;
                inner.last_game = None;
            }

            // Game still running on CPU — update game info but don't restart
            (Some(game), LlmMode::Cpu) => {
                inner.last_game = Some(game.clone());
            }

            // No game, already on GPU — nothing to do
            (None, LlmMode::Gpu) => {
                inner.last_game = None;
            }
        }

        Ok(GameGuardState {
            game_detected: inner.last_game.is_some(),
            game_name: inner.last_game.as_ref().map(|g| g.name.clone()),
            game_pid: inner.last_game.as_ref().map(|g| g.pid),
            game_window_title: inner
                .last_game
                .as_ref()
                .and_then(|g| g.window_title.clone()),
            llm_mode: inner.current_mode.clone(),
            last_check: inner.last_check,
            supported: inner.config.supported,
            guard_enabled: inner.config.enabled && inner.config.supported,
            assistant_enabled: inner.config.game_assistant_enabled && inner.config.supported,
        })
    }
}

// ---------------------------------------------------------------------------
// Game detection — free functions (all blocking, called via spawn_blocking)
// ---------------------------------------------------------------------------

/// Top-level detection: tries methods in priority order.
pub fn detect_game(vram_threshold_mb: u64) -> Option<GameInfo> {
    let gamemode_active = detect_gamemode_active();
    let support_process_active = proc_has_any(SUPPORT_PROCESS_NAMES);

    // 1. GameMode D-Bus / gamemoded
    if gamemode_active {
        // Find the actual game process while GameMode is active.
        if let Some(info) = find_gamemoded_child() {
            return Some(info);
        }
    }

    // 2. Known real game process names in /proc (precision-first).
    let proc_games = detect_game_processes();
    if let Some(info) = proc_games.into_iter().next() {
        return Some(info);
    }

    // 3. VRAM-heavy graphics processes via nvidia-smi pmon.
    // Support/game-mode signals allow us to accept game-install-path markers
    // for binaries whose short process names are not in our curated list.
    let vram_games = detect_vram_heavy_processes_with_markers(
        vram_threshold_mb,
        gamemode_active || support_process_active,
    );
    if let Some(info) = vram_games.into_iter().next() {
        return Some(info);
    }

    // 4. Ambiguous processes (wine/wineserver) — only count as game if a
    //    high-confidence indicator is ALSO present and we can locate a
    //    corroborating child/candidate process.
    let has_wine = has_ambiguous_game_process();
    if has_wine {
        let has_strong_signal = gamemode_active || support_process_active;
        if has_strong_signal {
            if let Some(info) = find_gamemoded_child() {
                return Some(info);
            }
            if let Some(info) = detect_game_processes().into_iter().next() {
                return Some(info);
            }
        }
    }

    None
}

/// Check whether GameMode (feralinteractive) is currently active.
pub fn detect_gamemode_active() -> bool {
    // Try gamemoded --status first (fast path)
    if let Ok(output) = Command::new("gamemoded").arg("--status").output() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        return gamemode_status_is_active(&stdout);
    }

    false
}

fn gamemode_status_is_active(stdout: &str) -> bool {
    let normalized = stdout.trim().to_ascii_lowercase();
    !normalized.contains("inactive") && normalized.contains("active")
}

/// Find a real game process that is a descendant of gamemoded / Steam.
fn find_gamemoded_child() -> Option<GameInfo> {
    let proc_dir = fs::read_dir("/proc").ok()?;
    let mut marker_candidate: Option<GameInfo> = None;

    for entry in proc_dir.flatten() {
        let pid: u32 = match entry.file_name().to_string_lossy().parse() {
            Ok(p) => p,
            Err(_) => continue,
        };
        let comm = match read_proc_comm(pid) {
            Some(c) => c,
            None => continue,
        };

        if is_non_game_gpu_process(&comm)
            || is_launcher_process(&comm)
            || is_support_process(&comm)
            || is_ambiguous_game_process(&comm)
        {
            continue;
        }

        if is_explicit_game_process(&comm) {
            let window_title = get_game_window_title(pid);
            return Some(GameInfo {
                pid,
                name: comm,
                window_title,
                detection_method: DetectionMethod::GameMode,
            });
        }

        if is_generic_game_executable(&comm) && process_has_game_install_markers(pid) {
            marker_candidate.get_or_insert_with(|| GameInfo {
                pid,
                name: comm,
                window_title: get_game_window_title(pid),
                detection_method: DetectionMethod::GameMode,
            });
        }
    }

    marker_candidate
}

/// Scan /proc for known game process names.
pub fn detect_game_processes() -> Vec<GameInfo> {
    let mut results = Vec::new();

    let proc_dir = match fs::read_dir("/proc") {
        Ok(d) => d,
        Err(e) => {
            warn!("[game_guard] cannot read /proc: {e}");
            return results;
        }
    };

    for entry in proc_dir.flatten() {
        let file_name = entry.file_name();
        let pid_str = file_name.to_string_lossy();

        // Only numeric entries are processes
        let pid: u32 = match pid_str.parse() {
            Ok(p) => p,
            Err(_) => continue,
        };

        let comm = match read_proc_comm(pid) {
            Some(c) => c,
            None => continue,
        };

        // Skip launcher-only processes
        if is_launcher_process(&comm) || is_support_process(&comm) {
            continue;
        }

        // Skip ambiguous processes (wine/wineserver) — they are NOT games by themselves.
        // They only count if a high-confidence indicator is also present (checked later).
        if is_ambiguous_game_process(&comm) {
            continue;
        }

        // Match against known game process names (high confidence only).
        if is_explicit_game_process(&comm)
            || (is_generic_game_executable(&comm) && process_has_game_install_markers(pid))
        {
            let window_title = get_game_window_title(pid);
            results.push(GameInfo {
                pid,
                name: comm,
                window_title,
                detection_method: DetectionMethod::ProcessName,
            });
        }
    }

    results
}

/// Check if any ambiguous game process (wine/wineserver) is running.
fn has_ambiguous_game_process() -> bool {
    let proc_dir = match fs::read_dir("/proc") {
        Ok(d) => d,
        Err(_) => return false,
    };
    for entry in proc_dir.flatten() {
        let pid: u32 = match entry.file_name().to_string_lossy().parse() {
            Ok(p) => p,
            Err(_) => continue,
        };
        if let Some(comm) = read_proc_comm(pid) {
            if AMBIGUOUS_GAME_PROCESSES
                .iter()
                .any(|a| comm.eq_ignore_ascii_case(a))
            {
                return true;
            }
        }
    }
    false
}

/// Check if any process matching the given names exists in /proc.
fn proc_has_any(names: &[&str]) -> bool {
    let proc_dir = match fs::read_dir("/proc") {
        Ok(d) => d,
        Err(_) => return false,
    };
    for entry in proc_dir.flatten() {
        let pid: u32 = match entry.file_name().to_string_lossy().parse() {
            Ok(p) => p,
            Err(_) => continue,
        };
        if let Some(comm) = read_proc_comm(pid) {
            if names.iter().any(|n| comm.eq_ignore_ascii_case(n)) {
                return true;
            }
        }
    }
    false
}

/// Use `nvidia-smi pmon -c 1 -s m` to find processes consuming significant VRAM.
pub fn detect_vram_heavy_processes(threshold_mb: u64) -> Vec<GameInfo> {
    detect_vram_heavy_processes_with_markers(threshold_mb, false)
}

/// Use `nvidia-smi pmon -c 1 -s m` to find processes consuming significant VRAM.
pub fn detect_vram_heavy_processes_with_markers(
    threshold_mb: u64,
    allow_marker_based: bool,
) -> Vec<GameInfo> {
    let output = match Command::new("nvidia-smi")
        .args(["pmon", "-c", "1", "-s", "m"])
        .output()
    {
        Ok(o) => o,
        Err(e) => {
            // nvidia-smi not present (non-NVIDIA system) — silently skip
            if e.kind() != std::io::ErrorKind::NotFound {
                warn!("[game_guard] nvidia-smi pmon failed: {e}");
            }
            return Vec::new();
        }
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut results = parse_nvidia_pmon_output(&stdout, threshold_mb, allow_marker_based);

    // Enhance names from /proc (nvidia-smi may truncate command names)
    for info in &mut results {
        if let Some(resolved) = get_game_name_from_pid(info.pid) {
            info.name = resolved;
        }
        info.window_title = get_game_window_title(info.pid);
    }

    results
        .into_iter()
        .filter(|info| {
            !is_non_game_gpu_process(&info.name)
                && !is_launcher_process(&info.name)
                && !is_support_process(&info.name)
                && !is_ambiguous_game_process(&info.name)
        })
        .collect()
}

/// Parse the output of `nvidia-smi pmon -c 1 -s m`.
///
/// Example line:
/// ```
/// # gpu        pid  type    fb   command
///     0       1234     C   2816   llama-server
///     0       5678     C  10240   RERequiem
/// ```
fn parse_nvidia_pmon_output(
    output: &str,
    threshold_mb: u64,
    allow_marker_based: bool,
) -> Vec<GameInfo> {
    let mut results = Vec::new();

    for line in output.lines() {
        let line = line.trim();

        // Skip headers and comment lines
        if line.starts_with('#') || line.is_empty() {
            continue;
        }

        // Columns: gpu  pid  type  fb(MiB)  command
        let mut fields = line.split_whitespace();
        let _gpu = match fields.next() {
            Some(g) => g,
            None => continue,
        };
        let pid_str = match fields.next() {
            Some(p) => p,
            None => continue,
        };
        let ptype = fields.next().unwrap_or("-"); // C / G / C+G
        let fb_str = match fields.next() {
            Some(f) => f,
            None => continue,
        };
        let command = fields.next().unwrap_or("-");

        let pid: u32 = match pid_str.parse() {
            Ok(p) => p,
            Err(_) => continue,
        };

        // "-" means the process has no VRAM usage listed
        if fb_str == "-" {
            continue;
        }

        let fb_mb: u64 = match fb_str.parse() {
            Ok(v) => v,
            Err(_) => continue,
        };

        if fb_mb < threshold_mb {
            continue;
        }

        let resolved_name = get_game_name_from_pid(pid).unwrap_or_else(|| command.to_string());

        // Exclude known non-game GPU consumers and support processes.
        if is_non_game_gpu_process(command)
            || is_non_game_gpu_process(&resolved_name)
            || is_launcher_process(command)
            || is_launcher_process(&resolved_name)
            || is_support_process(command)
            || is_support_process(&resolved_name)
            || is_ambiguous_game_process(command)
            || is_ambiguous_game_process(&resolved_name)
        {
            continue;
        }

        let has_graphics_context = ptype.contains('G');
        let explicit_game =
            is_explicit_game_process(command) || is_explicit_game_process(&resolved_name);
        let generic_exe_game = (is_generic_game_executable(command)
            || is_generic_game_executable(&resolved_name))
            && process_has_game_install_markers(pid);
        let marker_based_game =
            allow_marker_based && has_graphics_context && process_has_game_install_markers(pid);

        // Precision first: only accept explicit game binaries, generic *.exe
        // names backed by known game-install paths, or graphics-heavy processes
        // with strong path markers when a support signal already exists.
        if !explicit_game && !generic_exe_game && !marker_based_game {
            continue;
        }

        results.push(GameInfo {
            pid,
            name: resolved_name,
            window_title: None,
            detection_method: DetectionMethod::VramUsage,
        });
    }

    results
}

fn is_non_game_gpu_process(name: &str) -> bool {
    NON_GAME_GPU_PROCESSES
        .iter()
        .any(|candidate| name.eq_ignore_ascii_case(candidate))
}

fn is_launcher_process(name: &str) -> bool {
    LAUNCHER_PROCESSES
        .iter()
        .any(|candidate| name.eq_ignore_ascii_case(candidate))
}

fn is_support_process(name: &str) -> bool {
    SUPPORT_PROCESS_NAMES
        .iter()
        .any(|candidate| name.eq_ignore_ascii_case(candidate))
}

fn is_ambiguous_game_process(name: &str) -> bool {
    AMBIGUOUS_GAME_PROCESSES
        .iter()
        .any(|candidate| name.eq_ignore_ascii_case(candidate))
}

fn is_explicit_game_process(name: &str) -> bool {
    GAME_PROCESS_NAMES
        .iter()
        .any(|candidate| name.eq_ignore_ascii_case(candidate))
}

fn is_generic_game_executable(name: &str) -> bool {
    GENERIC_GAME_EXECUTABLES
        .iter()
        .any(|candidate| name.eq_ignore_ascii_case(candidate))
}

// ---------------------------------------------------------------------------
// /proc helpers
// ---------------------------------------------------------------------------

/// Read the short command name from `/proc/{pid}/comm`.
pub fn read_proc_comm(pid: u32) -> Option<String> {
    let path = format!("/proc/{pid}/comm");
    fs::read_to_string(&path).ok().map(|s| s.trim().to_string())
}

/// Read the full command line from `/proc/{pid}/cmdline` (NUL-separated).
fn read_proc_cmdline(pid: u32) -> Option<String> {
    let path = format!("/proc/{pid}/cmdline");
    fs::read(&path).ok().map(|bytes| {
        // NUL bytes separate argv entries; replace with space for readability
        String::from_utf8_lossy(&bytes)
            .replace('\0', " ")
            .trim()
            .to_string()
    })
}

/// Read the executable path for `/proc/{pid}/exe`.
fn read_proc_exe_path(pid: u32) -> Option<String> {
    let path = format!("/proc/{pid}/exe");
    fs::read_link(path)
        .ok()
        .map(|target| target.to_string_lossy().to_string())
}

fn contains_game_install_marker(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    GAME_INSTALL_PATH_MARKERS
        .iter()
        .any(|marker| lower.contains(marker))
}

fn process_has_game_install_markers(pid: u32) -> bool {
    read_proc_exe_path(pid)
        .into_iter()
        .chain(read_proc_cmdline(pid))
        .any(|value| contains_game_install_marker(&value))
}

/// Get the best available name for a PID (comm, falling back to cmdline basename).
pub fn get_game_name_from_pid(pid: u32) -> Option<String> {
    if let Some(comm) = read_proc_comm(pid) {
        if !comm.is_empty() {
            return Some(comm);
        }
    }

    // Fallback: first token of cmdline
    read_proc_cmdline(pid).and_then(|cmdline| {
        cmdline.split_whitespace().next().and_then(|arg| {
            std::path::Path::new(arg)
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
        })
    })
}

/// Find a process by comm name; returns `(pid, comm)` if found.
fn proc_find_process_by_name(name: &str) -> Option<(u32, String)> {
    let proc_dir = fs::read_dir("/proc").ok()?;
    for entry in proc_dir.flatten() {
        let pid_str = entry.file_name();
        let pid: u32 = match pid_str.to_string_lossy().parse() {
            Ok(p) => p,
            Err(_) => continue,
        };
        if let Some(comm) = read_proc_comm(pid) {
            if comm.eq_ignore_ascii_case(name) {
                return Some((pid, comm));
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Window title
// ---------------------------------------------------------------------------

/// Try to obtain the window title for the given PID using xdotool or /proc.
pub fn get_game_window_title(pid: u32) -> Option<String> {
    // Try xdotool first (works on X11 and XWayland)
    if let Ok(wid_output) = Command::new("xdotool")
        .args(["search", "--pid", &pid.to_string(), "--name", ""])
        .output()
    {
        let wid = String::from_utf8_lossy(&wid_output.stdout)
            .lines()
            .next()
            .unwrap_or("")
            .trim()
            .to_string();

        if !wid.is_empty() {
            if let Ok(title_output) = Command::new("xdotool")
                .args(["getwindowname", &wid])
                .output()
            {
                let title = String::from_utf8_lossy(&title_output.stdout)
                    .trim()
                    .to_string();
                if !title.is_empty() {
                    return Some(title);
                }
            }
        }
    }

    // Fallback: use the full cmdline as a rough title
    read_proc_cmdline(pid).filter(|s| !s.is_empty())
}

fn read_gpu_layers_from_file(path: &str) -> Option<i32> {
    fs::read_to_string(path).ok()?.lines().find_map(|line| {
        line.trim()
            .strip_prefix("LIFEOS_AI_GPU_LAYERS=")
            .and_then(|value| value.trim().parse::<i32>().ok())
    })
}

fn read_game_guard_override_layers() -> Option<i32> {
    read_gpu_layers_from_file(
        crate::ai_runtime_profile::game_guard_override_env_path()
            .to_string_lossy()
            .as_ref(),
    )
}

fn read_runtime_override_layers() -> Option<i32> {
    read_gpu_layers_from_file(
        crate::ai_runtime_profile::runtime_override_env_path()
            .to_string_lossy()
            .as_ref(),
    )
}

fn llm_mode_from_layers(layers: Option<i32>) -> LlmMode {
    if layers == Some(0) {
        LlmMode::Cpu
    } else {
        LlmMode::Gpu
    }
}

pub fn effective_gpu_layers(env_path: &str) -> Option<i32> {
    read_game_guard_override_layers()
        .or_else(read_runtime_override_layers)
        .or_else(|| read_gpu_layers_from_file(env_path))
}

// ---------------------------------------------------------------------------
// llama-server control
// ---------------------------------------------------------------------------

/// Writes the Game Guard override env with a CPU fallback profile.
pub fn persist_game_guard_override(profile: Option<&RuntimeSettings>) -> Result<()> {
    let profile = profile.cloned().unwrap_or(RuntimeSettings {
        ctx_size: 4096,
        threads: 4,
        gpu_layers: 0,
        parallel: 1,
        batch_size: 256,
        ubatch_size: 128,
    });
    crate::ai_runtime_profile::write_game_guard_override(&profile)?;
    restart_llama_server()?;
    Ok(())
}

fn clear_game_guard_override_and_restart() -> Result<()> {
    crate::ai_runtime_profile::clear_game_guard_override()?;
    restart_llama_server()?;
    Ok(())
}

fn restart_llama_server() -> Result<()> {
    info!("[game_guard] restarting llama-server with active runtime profile");
    crate::ai_runtime_profile::restart_llama_server_sync()
        .context("failed to restart llama-server from Game Guard")?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Background loop
// ---------------------------------------------------------------------------

/// Spawns the game-guard poll loop as a long-running async task.
///
/// Sends broadcast events on state transitions:
/// - `"game_detected:{game_name}"` when a game starts
/// - `"game_closed:{game_name}"` when the game exits
pub async fn run_game_guard_loop(
    guard: Arc<RwLock<GameGuard>>,
    event_tx: tokio::sync::broadcast::Sender<crate::events::DaemonEvent>,
) {
    info!("[game_guard] background loop started");

    let mut previous_game: Option<String> = None;

    loop {
        let poll_secs = {
            let g = guard.read().await;
            let inner = g.inner.read().await;
            inner.config.poll_interval_secs
        };

        tokio::time::sleep(tokio::time::Duration::from_secs(poll_secs)).await;

        let state = {
            let g = guard.read().await;
            match g.check_and_switch().await {
                Ok(s) => s,
                Err(e) => {
                    error!("[game_guard] check_and_switch error: {e}");
                    continue;
                }
            }
        };

        // Emit events on transitions
        let current_game = state.game_name.clone();

        match (&previous_game, &current_game) {
            // New game detected
            (None, Some(name)) => {
                info!("[game_guard] game detected: {name}");
                let _ = event_tx.send(crate::events::DaemonEvent::GameGuardChanged {
                    game_detected: true,
                    game_name: Some(name.clone()),
                    llm_mode: format!("{:?}", state.llm_mode),
                });
            }
            // Game closed
            (Some(name), None) => {
                info!("[game_guard] game closed: {name}");
                let _ = event_tx.send(crate::events::DaemonEvent::GameGuardChanged {
                    game_detected: false,
                    game_name: Some(name.clone()),
                    llm_mode: format!("{:?}", state.llm_mode),
                });
            }
            // Different game
            (Some(_prev), Some(curr)) if _prev != curr => {
                let _ = event_tx.send(crate::events::DaemonEvent::GameGuardChanged {
                    game_detected: true,
                    game_name: Some(curr.clone()),
                    llm_mode: format!("{:?}", state.llm_mode),
                });
            }
            _ => {}
        }

        previous_game = current_game;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let cfg = GameGuardConfig::default();
        assert!(cfg.enabled);
        assert!(cfg.supported);
        assert_eq!(cfg.poll_interval_secs, DEFAULT_POLL_INTERVAL_SECS);
        assert_eq!(cfg.vram_threshold_mb, DEFAULT_VRAM_THRESHOLD_MB);
        assert_eq!(cfg.llama_server_env_path, DEFAULT_LLAMA_ENV_PATH);
    }

    #[test]
    fn test_llm_mode_serde() {
        let mode = LlmMode::Cpu;
        let json = serde_json::to_string(&mode).unwrap();
        assert_eq!(json, "\"cpu\"");
        let back: LlmMode = serde_json::from_str(&json).unwrap();
        assert_eq!(back, LlmMode::Cpu);
    }

    #[tokio::test]
    async fn test_game_guard_initial_state() {
        let guard = GameGuard::new(GameGuardConfig::default());
        let state = guard.state().await;
        assert!(!state.game_detected);
        assert_eq!(state.llm_mode, LlmMode::Gpu);
        assert!(state.supported);
        assert!(state.guard_enabled);
        assert!(state.assistant_enabled);
    }

    #[tokio::test]
    async fn test_set_enabled() {
        let guard = GameGuard::new(GameGuardConfig::default());
        guard.set_enabled(false).await;
        let state = guard.state().await;
        assert!(!state.guard_enabled);
    }

    #[tokio::test]
    async fn test_set_assistant_enabled() {
        let guard = GameGuard::new(GameGuardConfig::default());
        guard.set_assistant_enabled(false).await;
        let state = guard.state().await;
        assert!(!state.assistant_enabled);
    }

    #[test]
    fn test_parse_nvidia_pmon_output() {
        let sample = "\
# gpu        pid  type    fb   command
    0       1234     C   2816   llama-server
    0       5678     G  10240   RERequiem
    0       9999     G    128   gnome-shell
";
        let results = parse_nvidia_pmon_output(sample, 500, false);
        // llama-server excluded, gnome-shell excluded (below threshold), RERequiem included
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].name, "RERequiem");
    }

    #[test]
    fn test_parse_nvidia_pmon_empty() {
        let results = parse_nvidia_pmon_output("", 500, false);
        assert!(results.is_empty());
    }

    #[test]
    fn test_gamemode_status_requires_real_active_state() {
        assert!(gamemode_status_is_active("gamemode is active"));
        assert!(gamemode_status_is_active("GameMode is ACTIVE\n"));
        assert!(!gamemode_status_is_active("gamemode is inactive"));
        assert!(!gamemode_status_is_active(""));
    }

    #[test]
    fn test_is_non_game_gpu_process_matches_llama_server_variants() {
        assert!(is_non_game_gpu_process("llama-server"));
        assert!(is_non_game_gpu_process("LLAMA-SERVER"));
        assert!(is_non_game_gpu_process("cosmic-comp"));
        assert!(!is_non_game_gpu_process("RERequiem"));
    }

    #[test]
    fn test_precision_first_game_name_lists() {
        assert!(is_support_process("gamescope"));
        assert!(is_support_process("mangohud"));
        assert!(!is_explicit_game_process("gamescope"));
        assert!(!is_explicit_game_process("mangohud"));
        assert!(!is_explicit_game_process("unity"));
        assert!(!is_explicit_game_process("godot"));
        assert!(!is_explicit_game_process("UnrealEditor"));
        assert!(is_generic_game_executable("game.exe"));
    }

    #[test]
    fn test_parse_nvidia_pmon_ignores_compute_only_unknown_processes() {
        let sample = "\
# gpu        pid  type    fb   command
    0       7777     C   4096   python
";
        let results = parse_nvidia_pmon_output(sample, 500, false);
        assert!(results.is_empty());
    }

    #[test]
    fn test_llm_mode_from_layers_treats_only_zero_as_cpu() {
        assert_eq!(llm_mode_from_layers(Some(0)), LlmMode::Cpu);
        assert_eq!(llm_mode_from_layers(Some(-1)), LlmMode::Gpu);
        assert_eq!(llm_mode_from_layers(Some(20)), LlmMode::Gpu);
        assert_eq!(llm_mode_from_layers(None), LlmMode::Gpu);
    }

    #[test]
    fn test_game_guard_env_file_lifecycle() {
        let cfg = GameGuardConfig::default();
        assert!(cfg.enabled);
        assert!(cfg.supported);
        assert_eq!(cfg.llama_server_env_path, DEFAULT_LLAMA_ENV_PATH);
    }
}
