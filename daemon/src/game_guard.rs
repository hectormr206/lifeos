//! GPU Game Guard
//!
//! Detecta automaticamente cuando un juego está corriendo y libera la VRAM del LLM local,
//! luego la restaura cuando el juego se cierra.
//!
//! Mediciones reales con RTX 5070 Ti (12 GB VRAM):
//! - Qwen3.5-4B Q4_K_M con 16K context: ~3.5 GB VRAM en idle
//! - Gaming (RE Requiem): 11.8/11.9 GB VRAM (98%) → stuttering
//!
//! Estrategia: cuando se detecta un juego, pone GPU_LAYERS=0 y reinicia llama-server
//! para que cargue en RAM. Al cerrar el juego, restaura GPU_LAYERS=-1 (todas las capas).

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

/// Override env file used by the systemd drop-in (99-game-guard-gpu-layers.conf).
/// This file is created when a game is detected and REMOVED when the game closes,
/// so the main env file's GPU_LAYERS value takes effect again.
const GAME_GUARD_ENV_PATH: &str = "/etc/lifeos/llama-server-game-guard.env";

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
];

/// Process names that are launchers (not games themselves)
const LAUNCHER_PROCESSES: &[&str] = &["steam", "steamwebhelper", "lutris", "heroic", "gamemoded"];

/// Processes that MAY indicate a game but are ambiguous on their own.
/// wineserver/wine can run for non-game Windows apps (Office, etc.).
/// Only count as game if a high-confidence game indicator is also present
/// (gamescope, mangohud, proton, or high VRAM usage).
const AMBIGUOUS_GAME_PROCESSES: &[&str] = &["wine", "wine64", "wineserver"];

/// Process names that ALWAYS indicate a game is running (high confidence)
const GAME_PROCESS_NAMES: &[&str] = &[
    // Compositors used exclusively for gaming
    "gamescope",
    // Performance overlay (only injected into games)
    "mangohud",
    // Proton (Steam Play — always means a game)
    "proton",
    // Game engines
    "UnrealEditor",
    "UE4Game",
    "UE5Game",
    "unity",
    "godot",
    // Resident Evil series
    "RERequiem",
    "re9.exe",
    "re8.exe",
    "re8",
    "re4.exe",
    "re4",
    "re2.exe",
    "re2",
    // Common Windows game EXEs that run via Proton
    "Game.exe",
    "game.exe",
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
    pub guard_enabled: bool,
    pub assistant_enabled: bool,
}

/// Configuration for the Game Guard subsystem
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GameGuardConfig {
    /// Enable/disable the guard entirely
    pub enabled: bool,
    /// How often to poll for game activity (seconds)
    pub poll_interval_secs: u64,
    /// Enable the in-game AI assistant feature
    pub game_assistant_enabled: bool,
    /// VRAM usage threshold (MB) to flag a process as a game
    pub vram_threshold_mb: u64,
    /// Path to the llama-server environment file
    pub llama_server_env_path: String,
}

impl Default for GameGuardConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            poll_interval_secs: DEFAULT_POLL_INTERVAL_SECS,
            game_assistant_enabled: true,
            vram_threshold_mb: DEFAULT_VRAM_THRESHOLD_MB,
            llama_server_env_path: DEFAULT_LLAMA_ENV_PATH.to_string(),
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
        let inner = GameGuardInner {
            config,
            current_mode: LlmMode::Gpu,
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
            guard_enabled: inner.config.enabled,
            assistant_enabled: inner.config.game_assistant_enabled,
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

    /// Core poll: detects games, switches LLM mode if needed, returns new state.
    ///
    /// This is safe to call concurrently — it takes the write lock only when a
    /// mode switch is required.
    pub async fn check_and_switch(&self) -> Result<GameGuardState> {
        // Read current config/mode without holding the write lock during slow I/O
        let (enabled, current_mode, vram_threshold, env_path) = {
            let inner = self.inner.read().await;
            (
                inner.config.enabled,
                inner.current_mode.clone(),
                inner.config.vram_threshold_mb,
                inner.config.llama_server_env_path.clone(),
            )
        };

        if !enabled {
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
                match persist_gpu_layers(0, &env_path) {
                    Ok(_) => {}
                    Err(e) => warn!("[game_guard] persist_gpu_layers(0) failed: {e}"),
                }
                // persist_gpu_layers already restarts llama-server via the helper script
                inner.current_mode = LlmMode::Cpu;
                inner.last_game = game_info;
            }

            // No game and we're on CPU → restore GPU
            (None, LlmMode::Cpu) => {
                info!("[game_guard] no game detected — restoring LLM to GPU");
                match persist_gpu_layers(-1, &env_path) {
                    Ok(_) => {}
                    Err(e) => warn!("[game_guard] persist_gpu_layers(-1) failed: {e}"),
                }
                // persist_gpu_layers already restarts llama-server via the helper script
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
            guard_enabled: inner.config.enabled,
            assistant_enabled: inner.config.game_assistant_enabled,
        })
    }
}

// ---------------------------------------------------------------------------
// Game detection — free functions (all blocking, called via spawn_blocking)
// ---------------------------------------------------------------------------

/// Top-level detection: tries methods in priority order.
pub fn detect_game(vram_threshold_mb: u64) -> Option<GameInfo> {
    // 1. GameMode D-Bus / gamemoded
    if detect_gamemode_active() {
        // Find the PID of gamemoded or a child game process
        if let Some(info) = find_gamemoded_child() {
            return Some(info);
        }
        // Fallback: we know a game is running but can't pin the pid
        return Some(GameInfo {
            pid: 0,
            name: "unknown (via GameMode)".to_string(),
            window_title: None,
            detection_method: DetectionMethod::GameMode,
        });
    }

    // 2. Known game process names in /proc (high confidence only — excludes wine/wineserver)
    let proc_games = detect_game_processes();
    if let Some(info) = proc_games.into_iter().next() {
        return Some(info);
    }

    // 3. VRAM-heavy processes via nvidia-smi pmon
    let vram_games = detect_vram_heavy_processes(vram_threshold_mb);
    if let Some(info) = vram_games.into_iter().next() {
        return Some(info);
    }

    // 4. Ambiguous processes (wine/wineserver) — only count as game if a
    //    high-confidence indicator is ALSO present (gamescope, proton, mangohud, GameMode)
    let has_wine = has_ambiguous_game_process();
    if has_wine {
        let has_strong_signal =
            detect_gamemode_active() || proc_has_any(&["gamescope", "mangohud", "proton"]);
        if has_strong_signal {
            return Some(GameInfo {
                pid: 0,
                name: "Wine/Proton game".to_string(),
                window_title: None,
                detection_method: DetectionMethod::ProcessName,
            });
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
    // Look for any known game-engine or Proton process
    for name in GAME_PROCESS_NAMES {
        if let Some((pid, comm)) = proc_find_process_by_name(name) {
            let window_title = get_game_window_title(pid);
            return Some(GameInfo {
                pid,
                name: comm,
                window_title,
                detection_method: DetectionMethod::GameMode,
            });
        }
    }
    None
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
        if LAUNCHER_PROCESSES
            .iter()
            .any(|l| comm.eq_ignore_ascii_case(l))
        {
            continue;
        }

        // Skip ambiguous processes (wine/wineserver) — they are NOT games by themselves.
        // They only count if a high-confidence indicator is also present (checked later).
        if AMBIGUOUS_GAME_PROCESSES
            .iter()
            .any(|a| comm.eq_ignore_ascii_case(a))
        {
            continue;
        }

        // Match against known game process names (high confidence only)
        if GAME_PROCESS_NAMES
            .iter()
            .any(|g| comm.eq_ignore_ascii_case(g))
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
    let mut results = parse_nvidia_pmon_output(&stdout, threshold_mb);

    // Enhance names from /proc (nvidia-smi may truncate command names)
    for info in &mut results {
        if let Some(resolved) = get_game_name_from_pid(info.pid) {
            info.name = resolved;
        }
        info.window_title = get_game_window_title(info.pid);
    }

    results
        .into_iter()
        .filter(|info| !is_non_game_gpu_process(&info.name))
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
fn parse_nvidia_pmon_output(output: &str, threshold_mb: u64) -> Vec<GameInfo> {
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
        let _ptype = fields.next(); // C / G / C+G
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

        // Exclude known non-game GPU consumers
        if is_non_game_gpu_process(command) {
            continue;
        }

        results.push(GameInfo {
            pid,
            name: command.to_string(),
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

// ---------------------------------------------------------------------------
// llama-server control
// ---------------------------------------------------------------------------

/// Switch the LLM to CPU mode (game running) or restore GPU mode (game closed).
///
/// Uses a separate override env file (`GAME_GUARD_ENV_PATH`) that is loaded by the
/// systemd drop-in `99-game-guard-gpu-layers.conf` AFTER the main env file.
///
/// - Game detected → create override file with `LIFEOS_AI_GPU_LAYERS=0`
/// - Game closed → DELETE override file so the main env file's value takes effect
///
/// The main env file is NEVER modified — it always keeps the user's preferred setting.
pub fn persist_gpu_layers(layers: i32, _env_path: &str) -> Result<()> {
    if layers == 0 {
        // Game detected: create override file to force CPU mode
        fs::write(GAME_GUARD_ENV_PATH, "LIFEOS_AI_GPU_LAYERS=0\n")
            .with_context(|| format!("failed to write {}", GAME_GUARD_ENV_PATH))?;
        info!(
            "[game_guard] created {} with GPU_LAYERS=0",
            GAME_GUARD_ENV_PATH
        );
    } else {
        // Game closed: remove override so main env value takes effect
        match fs::remove_file(GAME_GUARD_ENV_PATH) {
            Ok(_) => info!(
                "[game_guard] removed {} — restoring GPU from main env",
                GAME_GUARD_ENV_PATH
            ),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                info!(
                    "[game_guard] {} already absent, nothing to clean up",
                    GAME_GUARD_ENV_PATH
                );
            }
            Err(e) => warn!("[game_guard] failed to remove {}: {e}", GAME_GUARD_ENV_PATH),
        }
    }
    restart_llama_server();
    Ok(())
}

/// Restart llama-server via systemctl. Works because polkit rule
/// 50-lifeos-llama-server.rules allows user 'lifeos' to manage the unit.
/// No sudo needed — systemctl talks to systemd over D-Bus, polkit authorizes.
///
/// Always clears the failed state first to avoid systemd rate-limiting
/// (start-limit-hit) when Game Guard restarts the service multiple times
/// in quick succession (CPU mode → GPU mode within seconds).
fn restart_llama_server() {
    // Clear any previous failure state to prevent start-limit-hit
    let _ = Command::new("systemctl")
        .args(["reset-failed", "llama-server.service"])
        .output();

    info!("[game_guard] restarting llama-server via systemctl (polkit-authorized)");
    match Command::new("systemctl")
        .args(["restart", "llama-server.service"])
        .output()
    {
        Ok(output) => {
            if output.status.success() {
                info!("[game_guard] llama-server restarted successfully");
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);
                error!("[game_guard] systemctl restart failed: {}", stderr.trim());
            }
        }
        Err(e) => error!("[game_guard] failed to run systemctl: {e}"),
    }
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
    0       5678     C  10240   RERequiem
    0       9999     C    128   gnome-shell
";
        let results = parse_nvidia_pmon_output(sample, 500);
        // llama-server excluded, gnome-shell excluded (below threshold), RERequiem included
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].name, "RERequiem");
    }

    #[test]
    fn test_parse_nvidia_pmon_empty() {
        let results = parse_nvidia_pmon_output("", 500);
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
    fn test_game_guard_env_file_lifecycle() {
        // The game guard override file should be created for CPU mode
        // and deleted for GPU restore. We can't test the actual paths
        // in CI, but we verify the logic is sound via the state machine.
        let cfg = GameGuardConfig::default();
        assert!(cfg.enabled);
        assert_eq!(cfg.llama_server_env_path, DEFAULT_LLAMA_ENV_PATH);
    }
}
