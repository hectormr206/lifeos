//! LifeOS System Daemon (lifeosd)
//!
//! Provides:
//! - System health monitoring
//! - Auto-update checks
//! - Health monitoring
//! - Notification system
//! - D-Bus interface for system integration
//! - REST API for mobile companion app

use chrono::Timelike;
use log::{debug, error, info, warn};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::signal;
use tokio::sync::RwLock;

mod accessibility;
mod agent_loop;
mod agent_roles;
mod agent_runtime;
mod ai;
mod ai_runtime_profile;
mod api;
mod async_workers;
mod atspi_layer;
mod audio_frontend;
mod autonomous_agent;
mod axi_tools;
mod axi_tray;
mod backup_monitor;
mod battery_manager;
mod browser_automation;
mod calendar;
mod circuit_breaker;
mod computer_use;
mod config_store;
mod context_policies;
mod control_layers;
mod desktop_operator;
mod email_bridge;
mod events;
mod exec_whitelist;
mod experience_modes;
mod eye_health;
mod follow_along;
mod food_lookup;
mod game_guard;
mod git_workflow;
mod health;
mod health_tracking;
#[cfg(feature = "homeassistant")]
mod home_assistant;
mod lab;
#[cfg_attr(not(feature = "messaging"), allow(dead_code))]
mod llm_debate;
mod llm_router;
mod mcp_server;
#[allow(dead_code)] // Used via Telegram tools #80-83 + dashboard API
mod meeting_archive;
#[allow(dead_code)] // Used via Telegram tools + event bus + main loop
mod meeting_assistant;
mod memory_plane;
mod message_dedupe;
#[cfg(feature = "ui-overlay")]
mod mini_widget;
mod models;
mod notifications;
mod overlay;
#[cfg(feature = "dbus")]
mod permissions;
#[cfg(feature = "dbus")]
mod portal;
mod privacy_filter;
mod privacy_hygiene;
mod proactive;
mod reliability;
mod safe_mode;
mod scheduled_tasks;
mod screen_capture;
mod security_ai;
mod self_improving;
mod sensory_memory;
mod sensory_pipeline;
mod session_store;
#[cfg(feature = "messaging")]
mod simplex_bridge;
mod single_instance;
mod skill_generator;
mod skill_registry;
mod sleep_watch;
mod speaker_id;
mod sqlite_protection;
mod storage_housekeeping;
mod str_utils;
mod supervisor;
mod system;
mod system_tuner;
mod task_queue;
mod telemetry;
mod thermal_manager;
mod time_context;
mod translation;
mod tuf;
mod update_scheduler;
mod updates;
#[cfg_attr(not(feature = "messaging"), allow(dead_code))]
mod user_model;
mod visual_comfort;
mod wake_word;
#[cfg(feature = "http-api")]
mod ws_gateway;

use accessibility::AccessibilityManager;
use agent_runtime::AgentRuntimeManager;
use context_policies::ContextPoliciesManager;
use experience_modes::ExperienceManager;
use follow_along::FollowAlongManager;
use health::HealthMonitor;
use lab::LabManager;
use memory_plane::MemoryPlaneManager;
use notifications::NotificationManager;
use overlay::OverlayManager;
use screen_capture::ScreenCapture;
use sensory_pipeline::{AlwaysOnCycle, SensoryPipelineManager, SensoryRuntimeSync};
use system::SystemMonitor;
use telemetry::TelemetryManager;
use update_scheduler::UpdateScheduler;
use updates::UpdateChecker;
use visual_comfort::VisualComfortManager;

/// Daemon configuration
#[derive(Debug, Clone)]
pub struct DaemonConfig {
    pub health_check_interval: Duration,
    pub update_check_interval: Duration,
    pub metrics_collection_interval: Duration,
    pub enable_notifications: bool,
    pub enable_auto_updates: bool,
    pub enable_api: bool,
    pub api_bind_address: SocketAddr,
}

impl Default for DaemonConfig {
    fn default() -> Self {
        Self {
            health_check_interval: Duration::from_secs(300), // 5 minutes
            update_check_interval: Duration::from_secs(86400), // 24 hours
            metrics_collection_interval: Duration::from_secs(60), // 1 minute
            enable_notifications: true,
            enable_auto_updates: true,
            enable_api: true,
            api_bind_address: "127.0.0.1:8081".parse().unwrap(),
        }
    }
}

/// Helper to generate and save bootstrap token
fn generate_bootstrap_token() -> std::io::Result<String> {
    use std::fmt::Write;
    use std::fs::File;
    use std::io::Read;
    use std::os::unix::fs::PermissionsExt;

    let mut buf = [0u8; 16];
    let mut f = File::open("/dev/urandom")?;
    f.read_exact(&mut buf)?;
    let mut token = String::with_capacity(buf.len() * 2);
    for byte in buf {
        write!(&mut token, "{:02x}", byte)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    }

    let runtime_dir = bootstrap_runtime_dir_candidates()
        .into_iter()
        .find(|candidate| runtime_dir_is_writable(candidate.as_path()))
        .ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "No writable bootstrap runtime directory found",
            )
        })?;
    let dir = runtime_dir.as_path();
    let path = dir.join("bootstrap.token");
    std::fs::create_dir_all(dir)?;
    if let Ok(metadata) = std::fs::metadata(dir) {
        let mut dir_perms = metadata.permissions();
        dir_perms.set_mode(0o700);
        let _ = std::fs::set_permissions(dir, dir_perms);
    }

    std::fs::write(&path, &token)?;

    let mut perms = std::fs::metadata(&path)?.permissions();
    perms.set_mode(0o600); // Only owner can read/write
    std::fs::set_permissions(&path, perms)?;

    // Also write to persistent candidate directories so the CLI can find
    // the token after a reboot (when /run tmpfs is cleared).
    // SAFETY: only write to directories owned by the current user to avoid
    // permission conflicts (e.g. sentinel running as root creating dirs
    // that lifeosd as user can't later modify).
    let my_uid = unsafe { libc::getuid() };
    for candidate in bootstrap_runtime_dir_candidates() {
        let candidate_path = candidate.join("bootstrap.token");
        if candidate_path == path {
            continue; // Already written above
        }
        // Only mirror to dirs we own or can safely create
        let owned = candidate
            .metadata()
            .map(|m| {
                use std::os::unix::fs::MetadataExt;
                m.uid() == my_uid
            })
            .unwrap_or(true); // If dir doesn't exist yet, we'll create it as ourselves
        if !owned {
            log::debug!(
                "Skipping bootstrap mirror to {} (not owned by uid {})",
                candidate.display(),
                my_uid
            );
            continue;
        }
        if std::fs::create_dir_all(&candidate).is_ok()
            && std::fs::write(&candidate_path, &token).is_ok()
        {
            let _ =
                std::fs::set_permissions(&candidate_path, std::fs::Permissions::from_mode(0o600));
            log::debug!("Bootstrap token mirrored to {}", candidate_path.display());
        }
    }

    log::info!("Bootstrap token generated at {}", path.display());
    Ok(token)
}

fn bootstrap_runtime_dir_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();

    if let Ok(runtime_dir) = std::env::var("LIFEOS_RUNTIME_DIR") {
        let runtime_dir = runtime_dir.trim();
        if !runtime_dir.is_empty() {
            candidates.push(PathBuf::from(runtime_dir));
        }
    }

    if let Ok(xdg_runtime_dir) = std::env::var("XDG_RUNTIME_DIR") {
        let xdg_runtime_dir = xdg_runtime_dir.trim();
        if !xdg_runtime_dir.is_empty() {
            candidates.push(PathBuf::from(xdg_runtime_dir).join("lifeos"));
        }
    }

    if let Ok(home) = std::env::var("HOME") {
        let home = home.trim();
        if !home.is_empty() {
            candidates.push(PathBuf::from(home).join(".local/state/lifeos/runtime"));
        }
    }

    candidates.push(PathBuf::from("/run/lifeos"));
    candidates
}

fn runtime_dir_is_writable(path: &std::path::Path) -> bool {
    if std::fs::create_dir_all(path).is_err() {
        return false;
    }
    let probe = path.join(".probe");
    match std::fs::write(&probe, b"ok") {
        Ok(_) => {
            let _ = std::fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

/// Load LLM provider API keys from env files, creating the template if it doesn't exist.
///
/// Reads from two locations (system-wide + per-user override):
///   /etc/lifeos/llm-providers.env
///   ~/.config/lifeos/llm-providers.env
///
/// For each KEY=VALUE line where the env var is not yet set, injects it into the process.
/// Creates the file with an empty template on first run so future edits or dashboard
/// updates have a canonical location to write to.
fn ensure_llm_provider_env() {
    // Search paths in priority order: system → user config → repo dev copy
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let config_dir =
        std::env::var("XDG_CONFIG_HOME").unwrap_or_else(|_| format!("{}/.config", home));
    let env_paths = [
        PathBuf::from("/etc/lifeos/llm-providers.env"),
        PathBuf::from(&config_dir).join("lifeos/llm-providers.env"),
        // Dev/repo copy — keys file the user edited during development
        PathBuf::from(&home)
            .join("personalProjects/gama/lifeos/files/etc/lifeos/llm-providers.env"),
    ];

    let mut loaded_any = false;

    for path in &env_paths {
        if path.exists() {
            if let Ok(content) = std::fs::read_to_string(path) {
                for line in content.lines() {
                    let line = line.trim();
                    if line.is_empty() || line.starts_with('#') {
                        continue;
                    }
                    if let Some((key, value)) = line.split_once('=') {
                        let key = key.trim();
                        let value = value.trim();
                        if !value.is_empty() && std::env::var(key).unwrap_or_default().is_empty() {
                            // SAFETY: called early in main() before threads are spawned.
                            unsafe { std::env::set_var(key, value) };
                            info!("Loaded {} from {}", key, path.display());
                            loaded_any = true;
                        }
                    }
                }
            }
        }
    }

    // Create the system-wide template if it doesn't exist (for dashboard/user to fill in).
    let system_env = &env_paths[0];
    if !system_env.exists() {
        if let Some(parent) = system_env.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let template = "\
# LifeOS LLM Provider API Keys
# Edita este archivo o usa el Dashboard para configurar las keys.
# El daemon se reinicia automaticamente al detectar cambios.

# Cerebras (gratis, zero data retention, 2000+ tok/s)
CEREBRAS_API_KEY=

# Groq (gratis, zero data retention, 500-1000 tok/s)
GROQ_API_KEY=

# OpenRouter (multiple providers)
OPENROUTER_API_KEY=

# Email (opcional — outbound notifications via dashboard/agent tools)
LIFEOS_EMAIL_IMAP_HOST=
LIFEOS_EMAIL_IMAP_USER=
LIFEOS_EMAIL_IMAP_PASS=
LIFEOS_EMAIL_SMTP_HOST=

# WhatsApp Cloud API (opcional)
LIFEOS_WHATSAPP_TOKEN=
LIFEOS_WHATSAPP_PHONE_ID=
LIFEOS_WHATSAPP_VERIFY_TOKEN=
LIFEOS_WHATSAPP_ALLOWED_NUMBERS=

# Signal (opcional, requiere signal-cli daemon)
LIFEOS_SIGNAL_CLI_URL=http://127.0.0.1:8086
LIFEOS_SIGNAL_PHONE=
LIFEOS_SIGNAL_ALLOWED_NUMBERS=

# Home Assistant (opcional)
LIFEOS_HA_URL=
LIFEOS_HA_TOKEN=
";
        match std::fs::write(system_env, template) {
            Ok(()) => {
                let _ = std::fs::set_permissions(
                    system_env,
                    std::os::unix::fs::PermissionsExt::from_mode(0o600),
                );
                info!(
                    "Created LLM providers template at {} — edit it to enable Cerebras, Groq, etc.",
                    system_env.display()
                );
            }
            Err(e) => {
                // /etc may be read-only on bootc — try user config dir instead
                let user_env = &env_paths[1];
                if !user_env.exists() {
                    if let Some(parent) = user_env.parent() {
                        let _ = std::fs::create_dir_all(parent);
                    }
                    if let Err(e2) = std::fs::write(user_env, template) {
                        warn!(
                            "Could not create LLM providers env at {} or {}: {}, {}",
                            system_env.display(),
                            user_env.display(),
                            e,
                            e2
                        );
                    } else {
                        info!("Created LLM providers template at {}", user_env.display());
                    }
                }
            }
        }
    }

    if !loaded_any {
        info!("No LLM provider keys found. Configure them in /etc/lifeos/llm-providers.env or via the Dashboard.");
    }
}

#[cfg(feature = "ui-overlay")]
fn ensure_graphical_environment() {
    if std::env::var("WAYLAND_DISPLAY").is_ok() || std::env::var("DISPLAY").is_ok() {
        return;
    }

    let runtime_dir = match std::env::var("XDG_RUNTIME_DIR") {
        Ok(value) if !value.trim().is_empty() => value,
        _ => return,
    };

    let mut sockets = match std::fs::read_dir(&runtime_dir) {
        Ok(entries) => entries
            .filter_map(|entry| entry.ok())
            .filter_map(|entry| entry.file_name().into_string().ok())
            .filter(|name| name.starts_with("wayland-"))
            .collect::<Vec<_>>(),
        Err(_) => return,
    };

    sockets.sort();
    if let Some(socket) = sockets.into_iter().next() {
        // SAFETY: called early in main() before any threads are spawned.
        unsafe { std::env::set_var("WAYLAND_DISPLAY", &socket) };
        info!("Recovered graphical session via {}", socket);
    }
}

/// Daemon state shared across tasks
pub struct DaemonState {
    pub data_dir: PathBuf,
    pub config: DaemonConfig,
    pub system_monitor: Arc<RwLock<SystemMonitor>>,
    pub health_monitor: Arc<HealthMonitor>,
    pub update_checker: Arc<RwLock<UpdateChecker>>,
    pub notification_manager: Arc<NotificationManager>,
    pub ai_manager: Arc<RwLock<ai::AiManager>>,
    pub overlay_manager: Arc<RwLock<OverlayManager>>,
    pub screen_capture: Arc<RwLock<ScreenCapture>>,
    pub sensory_pipeline_manager: Arc<RwLock<SensoryPipelineManager>>,
    pub experience_manager: Arc<RwLock<ExperienceManager>>,
    pub update_scheduler: Arc<RwLock<UpdateScheduler>>,
    pub follow_along_manager: Arc<RwLock<FollowAlongManager>>,
    pub context_policies_manager: Arc<RwLock<ContextPoliciesManager>>,
    pub telemetry_manager: Arc<RwLock<TelemetryManager>>,
    pub agent_runtime_manager: Arc<RwLock<AgentRuntimeManager>>,
    pub memory_plane_manager: Arc<RwLock<MemoryPlaneManager>>,
    pub visual_comfort_manager: Arc<RwLock<VisualComfortManager>>,
    pub accessibility_manager: Arc<RwLock<AccessibilityManager>>,
    pub lab_manager: Arc<RwLock<LabManager>>,
    pub llm_router: Arc<RwLock<llm_router::LlmRouter>>,
    pub task_queue: Arc<task_queue::TaskQueue>,
    pub supervisor: Arc<supervisor::Supervisor>,
    pub scheduled_tasks: Arc<scheduled_tasks::ScheduledTaskManager>,
    pub health_tracker: Arc<tokio::sync::Mutex<health_tracking::HealthTracker>>,
    pub calendar: Arc<calendar::CalendarManager>,
    pub meeting_archive: Arc<meeting_archive::MeetingArchive>,
    pub bootstrap_token: Option<String>,
    pub last_health_check: RwLock<Option<chrono::DateTime<chrono::Local>>>,
    pub last_update_check: RwLock<Option<chrono::DateTime<chrono::Local>>>,
    pub wake_word_detector: Option<Arc<wake_word::WakeWordDetector>>,
    pub wake_word_notify: Arc<tokio::sync::Notify>,
    /// Broadcasts a shutdown request to long-running background tasks so
    /// they can drain gracefully before the process exits. Sensory runtime
    /// in particular uses this to finish the current camera/screen capture
    /// cycle instead of being `.abort()`ed mid-analysis.
    pub shutdown_notify: Arc<tokio::sync::Notify>,
    pub event_bus: tokio::sync::broadcast::Sender<events::DaemonEvent>,
    pub security_alert_buffer: security_ai::AlertBuffer,
    pub session_store: Arc<session_store::SessionStore>,
    pub game_guard: Option<Arc<RwLock<game_guard::GameGuard>>>,
    pub skill_registry_v2: Arc<skill_registry::SkillRegistry>,
    pub config_store: Arc<config_store::ConfigStore>,
    pub circuit_breaker: Arc<circuit_breaker::CircuitBreaker>,
}

/// Notify systemd watchdog that the daemon is alive.
/// Uses the NOTIFY_SOCKET env var directly (no crate dependency).
fn notify_watchdog() {
    if let Ok(socket_path) = std::env::var("NOTIFY_SOCKET") {
        use std::os::unix::net::UnixDatagram;
        let sock = UnixDatagram::unbound().ok();
        if let Some(s) = sock {
            let _ = s.send_to(b"WATCHDOG=1", &socket_path);
        }
    }
}

/// Notify systemd that the daemon is fully initialized and ready.
fn notify_ready() {
    if let Ok(socket_path) = std::env::var("NOTIFY_SOCKET") {
        use std::os::unix::net::UnixDatagram;
        let sock = UnixDatagram::unbound().ok();
        if let Some(s) = sock {
            let _ = s.send_to(b"READY=1", &socket_path);
        }
    }
}

/// Notify systemd that the daemon is stopping.
fn notify_stopping() {
    if let Ok(socket_path) = std::env::var("NOTIFY_SOCKET") {
        use std::os::unix::net::UnixDatagram;
        let sock = UnixDatagram::unbound().ok();
        if let Some(s) = sock {
            let _ = s.send_to(b"STOPPING=1", &socket_path);
        }
    }
}

fn print_usage() {
    println!(
        "Usage: lifeosd [OPTIONS]\n\n\
         Options:\n  \
         -V, --version    Print version and exit\n  \
         -h, --help       Print this help and exit\n\n\
         With no options, lifeosd runs as the LifeOS user-session daemon."
    );
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Parse CLI flags BEFORE any side-effectful init (logging, D-Bus, tray).
    // Running `lifeosd --version` must not spawn a second daemon.
    for arg in std::env::args().skip(1) {
        match arg.as_str() {
            "--version" | "-V" => {
                println!("lifeosd {}", env!("CARGO_PKG_VERSION"));
                return Ok(());
            }
            "--help" | "-h" => {
                print_usage();
                return Ok(());
            }
            _ => {
                // Unknown / positional args: fall through for backwards compat.
            }
        }
    }

    // Initialize logging
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info,zbus=warn,tracing=warn"),
    )
    .init();

    // Single-instance lock. Held for the lifetime of `main` via `_pidfile_guard`;
    // releasing happens on drop (graceful or panic).
    let _pidfile_guard = match single_instance::acquire_lock() {
        Ok(single_instance::LockOutcome::Acquired(guard)) => Some(guard),
        Ok(single_instance::LockOutcome::AlreadyRunning(pid)) => {
            info!(
                "Another lifeosd instance is already running (pid={}). Exiting.",
                pid
            );
            return Ok(());
        }
        Err(e) => {
            warn!("Failed to acquire single-instance lock: {}. Continuing.", e);
            None
        }
    };

    info!("╔══════════════════════════════════════════════════════════════╗");
    info!("║                                                              ║");
    info!("║              LifeOS System Daemon (lifeosd)                  ║");
    info!("║                        v0.1.0                                ║");
    info!("║                                                              ║");
    info!("╚══════════════════════════════════════════════════════════════╝");

    // Auto-load LLM provider keys from env files (creates template if missing).
    // This ensures keys are available even when systemd EnvironmentFile didn't load
    // (e.g. first boot before the file existed, or when running outside systemd).
    ensure_llm_provider_env();

    #[cfg(feature = "ui-overlay")]
    ensure_graphical_environment();

    // Load configuration
    let config = load_config().await?;
    info!("Configuration loaded: {:?}", config);

    // Generate bootstrap token for initial restricted IPC
    let bootstrap_token = match generate_bootstrap_token() {
        Ok(token) => Some(token),
        Err(e) => {
            warn!("Failed to generate bootstrap token: {}", e);
            None
        }
    };

    // Initialize wake word detector (rustpotter) if available.
    let wake_word_notify = Arc::new(tokio::sync::Notify::new());
    let shutdown_notify = Arc::new(tokio::sync::Notify::new());
    let wake_word_detector = {
        if !wake_word::WakeWordDetector::available() {
            info!("Wake word feature not compiled — using Whisper-based detection");
            None
        } else if let Some(model_path) = wake_word::resolve_model_path() {
            match wake_word::WakeWordDetector::new(model_path.clone(), None) {
                Ok(detector) => {
                    info!(
                        "Rustpotter wake word detector initialized (model: {})",
                        model_path.display()
                    );
                    Some(Arc::new(detector))
                }
                Err(e) => {
                    warn!("Rustpotter wake word detector unavailable: {}", e);
                    None
                }
            }
        } else {
            info!("No wake word model found — using Whisper-based detection");
            None
        }
    };

    // Event bus for real-time UI updates (SSE, mini-widget).
    let (event_tx, _) = tokio::sync::broadcast::channel::<events::DaemonEvent>(256);

    // Persistent data directory — /var/lib/lifeos in production, fallback for dev.
    let data_dir = std::env::var("LIFEOS_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let prod = PathBuf::from("/var/lib/lifeos");
            // Test if we can actually write to the production directory.
            if std::fs::create_dir_all(&prod).is_ok() {
                let probe = prod.join(".probe");
                if std::fs::write(&probe, b"ok").is_ok() {
                    let _ = std::fs::remove_file(&probe);
                    return prod;
                }
            }
            let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
            let fallback = PathBuf::from(home).join(".local/share/lifeos");
            info!("Using dev data directory: {}", fallback.display());
            fallback
        });

    // --- Safe mode: detect repeated crashes before spawning background tasks ---
    let in_safe_mode = safe_mode::init(&data_dir).await.unwrap_or(false);

    let runtime_profile_bootstrap = match ai_runtime_profile::bootstrap_runtime_profile(&data_dir) {
        Ok(outcome) => {
            if outcome.profile_changed || outcome.env_changed {
                if let Err(e) = ai_runtime_profile::restart_llama_server_sync() {
                    warn!(
                        "[ai_runtime] failed to restart llama-server after bootstrap: {}",
                        e
                    );
                }
            }
            Some(outcome)
        }
        Err(e) => {
            warn!("[ai_runtime] failed to bootstrap runtime profile: {}", e);
            None
        }
    };

    let game_guard_requested = std::env::var("LIFEOS_AI_GAME_GUARD")
        .map(|value| value != "false" && value != "0")
        .unwrap_or(true);
    let game_assistant_requested = std::env::var("LIFEOS_AI_GAME_ASSISTANT")
        .map(|value| value != "false" && value != "0")
        .unwrap_or(true);
    let game_guard_supported = runtime_profile_bootstrap
        .as_ref()
        .map(|outcome| outcome.profile.supports_game_guard())
        .unwrap_or(false);
    let game_guard_cpu_fallback = runtime_profile_bootstrap
        .as_ref()
        .and_then(|outcome| outcome.profile.profiles.game_guard_cpu_fallback.clone());

    // Shared instances for supervisor integration
    let shared_privacy = Arc::new(privacy_filter::PrivacyFilter::new(
        privacy_filter::PrivacyLevel::default(),
    ));
    let shared_router = Arc::new(RwLock::new(llm_router::LlmRouter::new(
        privacy_filter::PrivacyLevel::default(),
    )));
    let shared_tq = Arc::new(task_queue::TaskQueue::new(&data_dir).unwrap_or_else(|e| {
        warn!("Failed to open task queue, using /tmp fallback: {}", e);
        task_queue::TaskQueue::new(std::path::Path::new("/tmp/lifeos"))
            .expect("fallback task queue must work")
    }));
    // Sweep tasks orphaned by a previous crash or restart. Any task still
    // Running when a new daemon starts up was owned by a worker that no
    // longer exists, so it cannot possibly finish. A 60-second floor keeps
    // the sweep away from tasks started by a previous daemon seconds ago
    // that may still have in-flight state flushed to disk. Without this,
    // Hector ended up with tasks stuck in "running" for 17 days and the
    // proactive alert kept firing about them forever.
    match shared_tq.clear_stuck(60) {
        Ok(0) => {}
        Ok(n) => info!("[startup] cleared {} orphaned running task(s)", n),
        Err(e) => warn!("[startup] failed to clear orphaned running tasks: {}", e),
    }
    let shared_ai_manager = Arc::new(ai::AiManager::new());
    let shared_memory = Arc::new(RwLock::new(
        MemoryPlaneManager::with_ai_manager(data_dir.clone(), Some(shared_ai_manager.clone()))
            .unwrap_or_else(|e| {
                warn!("Failed to initialize MemoryPlaneManager: {}", e);
                MemoryPlaneManager::with_ai_manager(
                    PathBuf::from("/tmp/lifeos"),
                    Some(shared_ai_manager.clone()),
                )
                .unwrap()
            }),
    ));

    // Initialize session store (durable conversation sessions)
    let shared_session_store = Arc::new(session_store::SessionStore::new(&data_dir));
    if let Err(e) = shared_session_store.init().await {
        warn!("Failed to initialize SessionStore: {}", e);
    }

    // Initialize state
    let state = Arc::new(DaemonState {
        data_dir: data_dir.clone(),
        config: config.clone(),
        system_monitor: Arc::new(RwLock::new(SystemMonitor::new())),
        health_monitor: Arc::new(HealthMonitor::new()),
        update_checker: Arc::new(RwLock::new(UpdateChecker::new())),
        notification_manager: Arc::new(NotificationManager::new(config.enable_notifications)),
        ai_manager: Arc::new(RwLock::new(ai::AiManager::new())),
        overlay_manager: Arc::new(RwLock::new(OverlayManager::new(
            data_dir.join("screenshots"),
        ))),
        screen_capture: Arc::new(RwLock::new(ScreenCapture::new(
            data_dir.join("screenshots"),
        ))),
        sensory_pipeline_manager: Arc::new(RwLock::new({
            let mut spm = SensoryPipelineManager::new(data_dir.clone()).unwrap_or_else(|e| {
                warn!("Failed to initialize SensoryPipelineManager: {}", e);
                SensoryPipelineManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
            });
            spm.set_privacy_filter(shared_privacy.clone());
            spm
        })),
        experience_manager: Arc::new(RwLock::new(ExperienceManager::new(data_dir.clone()))),
        update_scheduler: Arc::new(RwLock::new(UpdateScheduler::new(data_dir.clone()))),
        follow_along_manager: Arc::new(RwLock::new(
            FollowAlongManager::new(data_dir.clone()).unwrap_or_else(|e| {
                warn!("Failed to initialize FollowAlongManager: {}", e);
                FollowAlongManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
            }),
        )),
        context_policies_manager: Arc::new(RwLock::new(
            ContextPoliciesManager::new(data_dir.clone()).unwrap_or_else(|e| {
                warn!("Failed to initialize ContextPoliciesManager: {}", e);
                ContextPoliciesManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
            }),
        )),
        telemetry_manager: Arc::new(RwLock::new(
            TelemetryManager::new(data_dir.clone()).unwrap_or_else(|e| {
                warn!("Failed to initialize TelemetryManager: {}", e);
                TelemetryManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
            }),
        )),
        agent_runtime_manager: Arc::new(RwLock::new(
            AgentRuntimeManager::new(data_dir.clone()).unwrap_or_else(|e| {
                warn!("Failed to initialize AgentRuntimeManager: {}", e);
                AgentRuntimeManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
            }),
        )),
        memory_plane_manager: shared_memory.clone(),
        visual_comfort_manager: Arc::new(RwLock::new(VisualComfortManager::new(data_dir.clone()))),
        accessibility_manager: Arc::new(RwLock::new(AccessibilityManager::new())),
        lab_manager: Arc::new(RwLock::new(
            LabManager::new(lab::LabConfig::default()).unwrap_or_else(|e| {
                warn!("Failed to initialize LabManager: {}", e);
                LabManager::new(lab::LabConfig {
                    workspace_path: PathBuf::from("/tmp/lifeos/lab"),
                    ..Default::default()
                })
                .unwrap()
            }),
        )),
        llm_router: shared_router.clone(),
        task_queue: shared_tq.clone(),
        supervisor: Arc::new(supervisor::Supervisor::with_memory(
            shared_tq.clone(),
            shared_router.clone(),
            shared_privacy.clone(),
            Some(shared_memory.clone()),
        )),
        scheduled_tasks: Arc::new(
            scheduled_tasks::ScheduledTaskManager::new(&data_dir).unwrap_or_else(|e| {
                warn!("Failed to init ScheduledTaskManager: {}", e);
                scheduled_tasks::ScheduledTaskManager::new(&std::env::temp_dir()).unwrap()
            }),
        ),
        health_tracker: Arc::new(tokio::sync::Mutex::new(
            health_tracking::HealthTracker::new(),
        )),
        calendar: Arc::new(
            calendar::CalendarManager::new(&data_dir).unwrap_or_else(|e| {
                warn!("Failed to init CalendarManager: {}", e);
                calendar::CalendarManager::new(&std::env::temp_dir()).unwrap()
            }),
        ),
        meeting_archive: Arc::new(meeting_archive::MeetingArchive::new(&data_dir)),
        bootstrap_token,
        last_health_check: RwLock::new(None),
        last_update_check: RwLock::new(None),
        wake_word_detector,
        wake_word_notify: wake_word_notify.clone(),
        shutdown_notify: shutdown_notify.clone(),
        event_bus: event_tx,
        security_alert_buffer: security_ai::new_alert_buffer(),
        session_store: shared_session_store,
        game_guard: Some(Arc::new(RwLock::new(game_guard::GameGuard::new(
            game_guard::GameGuardConfig {
                enabled: game_guard_requested,
                supported: game_guard_supported,
                poll_interval_secs: game_guard::GameGuardConfig::default().poll_interval_secs,
                game_assistant_enabled: game_assistant_requested,
                vram_threshold_mb: game_guard::GameGuardConfig::default().vram_threshold_mb,
                llama_server_env_path: game_guard::GameGuardConfig::default().llama_server_env_path,
                cpu_fallback_profile: game_guard_cpu_fallback,
            },
        )))),
        skill_registry_v2: Arc::new(skill_registry::SkillRegistry::from_defaults()),
        config_store: Arc::new(config_store::ConfigStore::new(&data_dir)),
        circuit_breaker: Arc::new(circuit_breaker::CircuitBreaker::new()),
    });

    // Apply gentle boot default (95% on laptops, 100% on desktops).
    // The reactive thermal manager loop below will adjust dynamically
    // based on actual CPU temperature once it starts.
    thermal_manager::apply_boot_default();

    // Initialize config store (creates checkpoint directories).
    if let Err(e) = state.config_store.init().await {
        warn!("Failed to initialize ConfigStore: {}", e);
    }

    // Attach scheduled tasks manager to supervisor.
    state
        .supervisor
        .set_scheduler(state.scheduled_tasks.clone());

    // Attach event bus to overlay manager for real-time UI broadcasts.
    {
        let mut overlay = state.overlay_manager.write().await;
        overlay.set_event_bus(state.event_bus.clone());
    }

    // Initialize persisted manager state.
    {
        let follow_along = state.follow_along_manager.read().await;
        if let Err(e) = follow_along.initialize().await {
            warn!("Failed to initialize FollowAlong state: {}", e);
        }
    }
    {
        let context_policies = state.context_policies_manager.read().await;
        if let Err(e) = context_policies.initialize().await {
            warn!("Failed to initialize context policies state: {}", e);
        }
    }
    {
        let agent_runtime = state.agent_runtime_manager.read().await;
        if let Err(e) = agent_runtime.initialize().await {
            warn!("Failed to initialize agent runtime state: {}", e);
        }
        // Auto-grant FollowAlong consent when sensory capture is enabled,
        // so the dashboard and migrations can activate sensors without a
        // separate consent step.
        let sensory = agent_runtime.sensory_capture_runtime().await;
        if sensory.enabled {
            let fa = state.follow_along_manager.read().await;
            if let Err(e) = fa.set_consent(true).await {
                warn!("Failed to auto-grant FollowAlong consent: {}", e);
            } else {
                info!("FollowAlong consent auto-granted (sensory capture enabled)");
            }
        }
    }
    {
        let memory_plane = state.memory_plane_manager.read().await;
        if let Err(e) = memory_plane.initialize().await {
            warn!("Failed to initialize memory plane state: {}", e);
        }
    }
    {
        let visual_comfort = state.visual_comfort_manager.read().await;
        if let Err(e) = visual_comfort.initialize().await {
            warn!("Failed to initialize visual comfort state: {}", e);
        }
    }
    {
        let lab = state.lab_manager.read().await;
        if let Err(e) = lab.initialize().await {
            warn!("Failed to initialize lab state: {}", e);
        }
    }
    {
        let sensory = state.sensory_pipeline_manager.read().await;
        if let Err(e) = sensory.initialize().await {
            warn!("Failed to initialize sensory pipeline state: {}", e);
        }
    }

    // Run an accessibility audit at startup to validate built-in themes.
    let mut accessibility_manager = AccessibilityManager::new();
    accessibility_manager.set_settings(accessibility::AccessibilitySettings::default());
    let _ = accessibility_manager.get_settings();
    let audit_results = accessibility_manager.audit_default_themes();
    info!(
        "Accessibility audit complete: {} theme reports generated",
        audit_results.len()
    );

    // --- Safe mode notification ---
    if in_safe_mode {
        warn!("SAFE MODE ACTIVE — self-improvement and autonomous actions disabled");
        let _ = state.event_bus.send(events::DaemonEvent::SafeModeEntered {
            reason: "Crashes repetidos detectados al arrancar".into(),
        });
        let _ = state.event_bus.send(events::DaemonEvent::Notification {
            priority: "warning".into(),
            message: "Axi entro en modo seguro tras crashes repetidos. Respondo mensajes pero no hare cambios autonomos. Di 'exit safe mode' cuando quieras.".into(),
        });
    }

    // API server is started later (after shared variables are initialized)

    // Start D-Bus service
    let dbus_handle = tokio::spawn(async move {
        if let Err(e) = permissions::start_broker().await {
            error!("Fail to start D-Bus Permission Broker: {}", e);
        } else {
            // Keep the task alive while the broker serves requests
            log::info!("Permission Broker running on D-Bus Session.");
            futures_lite::future::pending::<()>().await;
        }
    });

    // Start Portal D-Bus service
    let portal_handle = tokio::spawn(async move {
        if let Err(e) = portal::start_portal().await {
            error!("Failed to start D-Bus Portal: {}", e);
        } else {
            log::info!("Portal running on D-Bus Session.");
            futures_lite::future::pending::<()>().await;
        }
    });

    // Start wake word detector if available.
    let wake_word_handle = if let Some(ref detector) = state.wake_word_detector {
        let handle = detector.run();
        info!("Rustpotter wake word listener started");
        Some(handle)
    } else {
        None
    };

    // Mini-widget: floating GTK4 orb ("Eye of Axi").
    // Controlled by overlay config `mini_widget_visible`. Defaults to hidden.
    // The tray icon (ksni) is the primary indicator; the widget is optional.
    #[cfg(feature = "ui-overlay")]
    {
        let widget_visible = {
            let overlay = state.overlay_manager.read().await;
            let cfg = overlay.get_config().await;
            cfg.mini_widget_visible
        };
        if widget_visible {
            let widget_state = state.clone();
            let widget_token = state.bootstrap_token.clone().unwrap_or_default();
            let widget_api_base =
                format!("http://127.0.0.1:{}", state.config.api_bind_address.port(),);
            let widget_dashboard = format!("{}/dashboard?token={}", widget_api_base, widget_token);
            let current_axi_state = {
                let overlay = widget_state.overlay_manager.read().await;
                let s = overlay.get_state().await;
                format!("{:?}", s.axi_state)
            };
            let widget_bus = state.event_bus.clone();
            info!("[widget] Spawning Axi mini-widget (Eye of Axi)");
            mini_widget::spawn_mini_widget(
                widget_bus,
                widget_dashboard,
                true,
                current_axi_state,
                None,
                "teal".to_string(),
            );
        } else {
            info!("[widget] Mini-widget disabled in config (use /api/v1/overlay/toggle to enable)");
        }
    }

    // Launch Axi system tray icon (StatusNotifierItem — top panel)
    #[cfg(feature = "tray")]
    {
        let tray_state = state.clone();
        tokio::spawn(async move {
            // Keep waiting until the graphical session is actually ready.
            // On some boots lifeosd starts before COSMIC exports DISPLAY/
            // WAYLAND_DISPLAY; disabling the tray after 30s leaves Axi without
            // an icon for the entire session.
            loop {
                let mut display_ready = false;
                let mut attempts = 0usize;
                while !display_ready {
                    if std::env::var("WAYLAND_DISPLAY").is_ok() || std::env::var("DISPLAY").is_ok()
                    {
                        break;
                    }
                    // Try to discover Wayland socket dynamically
                    if let Ok(runtime_dir) = std::env::var("XDG_RUNTIME_DIR") {
                        if let Ok(entries) = std::fs::read_dir(&runtime_dir) {
                            for entry in entries.flatten() {
                                if let Ok(name) = entry.file_name().into_string() {
                                    if name.starts_with("wayland-") && !name.ends_with(".lock") {
                                        unsafe { std::env::set_var("WAYLAND_DISPLAY", &name) };
                                        info!("Discovered Wayland socket: {}", name);
                                        display_ready = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    if display_ready {
                        break;
                    }
                    if attempts == 0 {
                        info!("[tray] Waiting for display server...");
                    } else if attempts % 15 == 0 {
                        warn!("[tray] Display still unavailable, retrying tray startup...");
                    }
                    attempts += 1;
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                }

                // Spawn tray with health monitoring — re-spawn on failure
                info!("[tray] Spawning Axi system tray icon");
                let tray_token = tray_state.bootstrap_token.clone().unwrap_or_default();
                let tray_api_base = format!(
                    "http://127.0.0.1:{}",
                    tray_state.config.api_bind_address.port(),
                );
                let tray_dashboard = format!("{}/dashboard?token={}", tray_api_base, tray_token,);
                let current_state = {
                    let overlay = tray_state.overlay_manager.read().await;
                    let s = overlay.get_state().await;
                    format!("{:?}", s.axi_state)
                };
                // Read persisted sensor state so tray doesn't revert to hardcoded defaults
                let sensors = {
                    let arm = tray_state.agent_runtime_manager.read().await;
                    let runtime = arm.sensory_capture_runtime().await;
                    let always_on = arm.always_on_runtime().await;
                    axi_tray::InitialSensorState {
                        mic: runtime.audio_enabled,
                        camera: runtime.camera_enabled,
                        screen: runtime.screen_enabled,
                        always_on: always_on.enabled,
                        tts: runtime.tts_enabled,
                    }
                };
                let tray_rx = tray_state.event_bus.subscribe();
                axi_tray::spawn_tray(
                    tray_rx,
                    tray_dashboard,
                    tray_api_base,
                    tray_token,
                    current_state,
                    sensors,
                )
                .await;
                // spawn_tray now actually blocks until the tray exits
                warn!("[tray] Tray icon exited, re-spawning in 5s...");
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            }
        });
    }

    // Start background tasks
    // Sensory memory listener — persists significant sensory events to MemoryPlane
    {
        let sensory_mem = state.memory_plane_manager.clone();
        let sensory_rx = state.event_bus.subscribe();
        tokio::spawn(async move {
            sensory_memory::run_sensory_memory_listener(sensory_rx, sensory_mem).await;
        });
        info!("Sensory memory listener started");
    }

    {
        let runtime_profile_data_dir = data_dir.clone();
        let runtime_profile_game_guard = state.game_guard.clone();
        let runtime_profile_event_tx = state.event_bus.clone();
        tokio::spawn(async move {
            ai_runtime_profile::run_runtime_profile_manager(
                runtime_profile_data_dir,
                runtime_profile_game_guard,
                runtime_profile_event_tx,
            )
            .await;
        });
        info!("AI runtime profile manager started");
    }

    let health_handle = tokio::spawn(run_health_checks(state.clone()));
    let update_handle = tokio::spawn(run_update_checks(state.clone()));
    let metrics_handle = tokio::spawn(run_metrics_collection(state.clone()));
    let sensory_handle = tokio::spawn(run_sensory_runtime(state.clone()));

    // Gate camera captures across suspend/hibernate. A failed bus connection
    // (no login1 available) is logged and ignored — the capture loop still
    // works, it just loses the suspend safety net.
    let sleep_sensory = state.sensory_pipeline_manager.clone();
    let sleep_ai = state.ai_manager.clone();
    let sleep_watch_handle = tokio::spawn(async move {
        if let Err(err) = sleep_watch::watch_prepare_for_sleep(sleep_sensory, sleep_ai).await {
            warn!("[sleep-watch] watcher exited: {}", err);
        }
    });

    // Proactive notifications loop — checks every 5 minutes
    let proactive_state = state.clone();
    let _proactive_handle = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(300));
        loop {
            interval.tick().await;
            let alerts = proactive::check_all(
                Some(&proactive_state.task_queue),
                Some(&proactive_state.calendar),
            )
            .await;
            for alert in &alerts {
                warn!("Proactive alert [{:?}]: {}", alert.severity, alert.message);
                // Send as notification via event bus
                let _ = proactive_state
                    .event_bus
                    .send(events::DaemonEvent::Notification {
                        priority: match alert.severity {
                            proactive::AlertSeverity::Critical => "critical".into(),
                            proactive::AlertSeverity::Warning => "warning".into(),
                            proactive::AlertSeverity::Info => "info".into(),
                        },
                        message: alert.message.clone(),
                    });
            }
            // AQ.3 — Proactive personalization suggestions
            {
                let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
                let data_dir = std::path::PathBuf::from(format!("{}/.local/share/lifeos", home));
                let model = crate::user_model::UserModel::load_from_dir(&data_dir).await;
                let hour = chrono::Local::now().hour() as u8;
                let pending = proactive_state
                    .task_queue
                    .list(Some(crate::task_queue::TaskStatus::Pending), 100)
                    .unwrap_or_default()
                    .len();
                let suggestions = crate::user_model::generate_suggestions(&model, hour, pending);
                for s in &suggestions {
                    let _ = proactive_state
                        .event_bus
                        .send(events::DaemonEvent::Notification {
                            priority: "info".into(),
                            message: s.message.clone(),
                        });
                }
            }
        }
    });

    // Health tracking tick — increments active minutes every 60s
    let health_tracking_state = state.clone();
    let _health_tracking_handle = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(60));
        loop {
            interval.tick().await;
            let mut tracker = health_tracking_state.health_tracker.lock().await;
            tracker.tick_active();
            let reminders = tracker.check_reminders();
            for reminder in &reminders {
                let _ = health_tracking_state
                    .event_bus
                    .send(events::DaemonEvent::Notification {
                        priority: "info".into(),
                        message: reminder.message.clone(),
                    });
            }
        }
    });

    // Calendar reminder check — every 60s checks for due reminders.
    //
    // Reminders created by Axi via `reminder_add` stash the originating chat_id
    // in the event description as `__chat:<id>`. When we see that tag we emit a
    // `ReminderDue` event so the channel bridges (SimpleX, dashboard)
    // can route the notification back to the chat that asked for it. Reminders
    // without a chat tag fall through to the old desktop Notification path.
    let calendar_state = state.clone();
    let _calendar_handle = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(60));
        loop {
            interval.tick().await;
            if let Ok(reminders) = calendar_state.calendar.due_reminders() {
                for event in &reminders {
                    // Parse routing tag from description, if any.
                    let chat_id: Option<i64> = event
                        .description
                        .split_whitespace()
                        .find_map(|tok| tok.strip_prefix("__chat:").and_then(|s| s.parse().ok()));

                    if let Some(cid) = chat_id {
                        let _ = calendar_state
                            .event_bus
                            .send(events::DaemonEvent::ReminderDue {
                                chat_id: cid,
                                title: event.title.clone(),
                                event_id: event.id.clone(),
                                start_time: event.start_time.clone(),
                            });
                        // Record the reminder so it doesn't re-fire every minute.
                        let _ = calendar_state.calendar.record_reminder(
                            &event.id,
                            &event.title,
                            "chat",
                        );
                    } else {
                        let _ = calendar_state
                            .event_bus
                            .send(events::DaemonEvent::Notification {
                                priority: "info".into(),
                                message: format!(
                                    "Recordatorio: {} a las {}",
                                    event.title, event.start_time
                                ),
                            });
                        let _ = calendar_state.calendar.record_reminder(
                            &event.id,
                            &event.title,
                            "desktop",
                        );
                    }
                }
            }
        }
    });

    // Autonomous agent — check user presence every 30s, activate when screen locked
    let autonomous_event_bus = state.event_bus.clone();
    let autonomous_tq = state.task_queue.clone();
    let autonomous_router = state.llm_router.clone();
    let _autonomous_handle = tokio::spawn(async move {
        let mut agent = autonomous_agent::AutonomousAgent::new();
        let mut loop_state = agent_loop::AgentLoopState::new();
        let agent_loop_enabled = agent_loop::is_enabled();
        let mut was_working = false;
        let mut interval = tokio::time::interval(Duration::from_secs(30));
        if agent_loop_enabled {
            info!("[agent_loop] Agent loop enabled (LIFEOS_AGENT_LOOP=true)");
        }
        loop {
            interval.tick().await;
            if safe_mode::is_safe_mode() {
                debug!("[safe_mode] Skipping autonomous agent tick — safe mode active");
                continue;
            }
            let presence_ok = agent.check_presence().await.is_ok();
            let should_work = presence_ok && agent.should_work();

            // Transition: was working → no longer working = reset session
            if was_working && !should_work {
                info!(
                    "[agent_loop] User returned — session ended ({} tasks enqueued)",
                    loop_state.tasks_enqueued()
                );
                loop_state.reset();
            }
            was_working = should_work;

            if should_work {
                let _ = autonomous_event_bus.send(events::DaemonEvent::Notification {
                    priority: "info".into(),
                    message: "Axi en modo autonomo — trabajando mientras estas ausente.".into(),
                });

                // Agent loop: generate and enqueue proactive tasks
                if agent_loop_enabled {
                    match agent_loop::try_generate_task(
                        &mut loop_state,
                        &autonomous_tq,
                        &autonomous_router,
                    )
                    .await
                    {
                        Ok(true) => {
                            info!("[agent_loop] Task enqueued successfully");
                        }
                        Ok(false) => {
                            debug!(
                                "[agent_loop] No task generated (limits/cooldown/nothing to do)"
                            );
                        }
                        Err(e) => {
                            warn!("[agent_loop] Task generation failed: {}", e);
                        }
                    }
                }
            }
        }
    });

    // Meeting archive — structured SQLite storage for meeting records.
    // Constructed inside DaemonState above so the API server (which receives
    // an Arc<DaemonState>) can expose it via /meetings/* endpoints.
    let meeting_archive = state.meeting_archive.clone();

    // Meeting assistant — check for active meetings every 15s
    let meeting_data_dir = data_dir.clone();
    let meeting_event_bus = state.event_bus.clone();
    let meeting_router = state.llm_router.clone();
    let meeting_memory = state.memory_plane_manager.clone();
    let shared_meeting_assistant = {
        let mut assistant = meeting_assistant::MeetingAssistant::new(
            meeting_data_dir,
            Some(meeting_event_bus.clone()),
            Some(meeting_router),
            Some(meeting_memory),
        );
        assistant.set_archive(meeting_archive.clone());
        // Share the speaker identification manager with the sensory pipeline so
        // meetings and live voice interactions resolve against the same profiles.
        let shared_speaker_id = state.sensory_pipeline_manager.read().await.speaker_id();
        assistant.set_speaker_id(shared_speaker_id);
        // Wire the agent runtime so meeting mode honors screen_enabled +
        // kill switch like every other sensory capture path does.
        assistant.set_agent_runtime(state.agent_runtime_manager.clone());
        std::sync::Arc::new(tokio::sync::RwLock::new(assistant))
    };
    let meeting_loop_assistant = shared_meeting_assistant.clone();
    let _meeting_handle = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(15));
        info!("[meeting] Detection loop started (every 15s)");
        loop {
            interval.tick().await;
            let mut assistant = meeting_loop_assistant.write().await;
            if !assistant.is_enabled() {
                continue;
            }
            match assistant.detect_meeting().await {
                Ok(true) => {
                    let state = assistant.state();
                    if state.recording && state.duration_secs < 2 {
                        let app = state.app_name.clone().unwrap_or_default();
                        let _ = meeting_event_bus.send(events::DaemonEvent::Notification {
                            priority: "info".into(),
                            message: format!(
                                "Reunion detectada ({}) — grabando automaticamente.",
                                app
                            ),
                        });
                    }
                }
                Ok(false) => {}
                Err(e) => {
                    warn!("[meeting] Detection error: {}", e);
                }
            }
        }
    });

    // --- Eye health: 20-20-20 rule check every 60s ---
    let eye_event_bus = state.event_bus.clone();
    let _eye_health_handle = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(60));
        let mut last_reminder: Option<std::time::Instant> = None;
        loop {
            interval.tick().await;
            if eye_health::should_remind_20_20_20(&last_reminder, 20) {
                last_reminder = Some(std::time::Instant::now());
                let _ = eye_event_bus.send(events::DaemonEvent::Notification {
                    priority: "info".into(),
                    message: "Regla 20-20-20: Mira algo a 6 metros por 20 segundos.".into(),
                });
                info!("[eye_health] 20-20-20 reminder sent");
            }
            // Auto-enable night mode in the evening
            if eye_health::is_evening() {
                if let Err(e) = eye_health::enable_night_mode(4500, 3500).await {
                    debug!("[eye_health] Night mode error: {}", e);
                }
            }
        }
    });
    info!("Eye health monitor started (20-20-20 rule every 20 min)");

    // --- Home Assistant: conditional init if env vars are set ---
    #[cfg(feature = "homeassistant")]
    {
        if let Some(ha_config) = home_assistant::homeassistant::HomeAssistantConfig::from_env() {
            info!(
                "[home_assistant] Connected to Home Assistant at {}",
                ha_config.url
            );
            // Client is available for API routes; no background bridge spawned yet.
        } else {
            info!("[home_assistant] LIFEOS_HA_URL/LIFEOS_HA_TOKEN not set, skipping");
        }
    }

    // --- Security AI: threat monitoring every 30s ---
    let security_event_bus = state.event_bus.clone();
    let security_alert_buffer_task = state.security_alert_buffer.clone();
    let _security_ai_handle = tokio::spawn(async move {
        let mut daemon = security_ai::SecurityAiDaemon::new();
        let mut interval = tokio::time::interval(Duration::from_secs(30));
        // De-dupe key: (alert_type, description). Each cycle we rebuild a
        // fresh set of observed keys; we only WARN on transitions (newly
        // appearing alerts) and INFO on cleared ones. This prevents the
        // per-cycle log storm that used to flood journald.
        use std::collections::HashSet;
        let mut prev_keys: HashSet<String> = HashSet::new();
        loop {
            interval.tick().await;
            // Run all security checks
            let mut alerts = Vec::new();
            alerts.extend(daemon.check_suspicious_connections().await);
            alerts.extend(daemon.check_anomalous_processes().await);
            alerts.extend(daemon.check_unauthorized_file_access().await);
            alerts.extend(daemon.check_system_integrity().await);
            security_ai::push_alerts(&security_alert_buffer_task, &alerts);

            // Fire notifications + compute the current key set for de-dupe.
            let mut cur_keys: HashSet<String> = HashSet::new();
            for alert in &alerts {
                let key = format!("{:?}|{}", alert.alert_type, alert.description);
                cur_keys.insert(key.clone());
                // Only notify on NEW alerts — avoids waking the user on the
                // same recurring condition every 30s.
                if prev_keys.contains(&key) {
                    continue;
                }
                let priority = match alert.severity {
                    security_ai::AlertSeverity::Emergency
                    | security_ai::AlertSeverity::Critical => "critical",
                    security_ai::AlertSeverity::Warning => "warning",
                    security_ai::AlertSeverity::Info => "info",
                };
                let _ = security_event_bus.send(events::DaemonEvent::Notification {
                    priority: priority.into(),
                    message: format!("[security] {}", alert.description),
                });
                warn!(
                    "[security_ai] NEW alert {:?}: {}",
                    alert.severity, alert.description
                );
            }
            // Report cleared alerts at INFO.
            for cleared in prev_keys.difference(&cur_keys) {
                log::info!("[security_ai] cleared: {}", cleared);
            }
            prev_keys = cur_keys;
        }
    });
    info!("Security AI monitor started (every 30s)");

    // --- Privacy hygiene: daily scan ---
    let privacy_event_bus = state.event_bus.clone();
    let _privacy_hygiene_handle = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(86400)); // 24h
        loop {
            interval.tick().await;
            let report = privacy_hygiene::run_privacy_scan().await;
            info!(
                "[privacy_hygiene] Scan complete: cache={:.0}MB, exposed={}, breaches={}",
                report.browser_cache_mb,
                report.sensitive_files_exposed.len(),
                report.breach_alerts.len()
            );
            if !report.sensitive_files_exposed.is_empty() || !report.breach_alerts.is_empty() {
                let _ = privacy_event_bus.send(events::DaemonEvent::Notification {
                    priority: "warning".into(),
                    message: format!(
                        "Privacy scan: {} archivos sensibles expuestos, {} brechas detectadas.",
                        report.sensitive_files_exposed.len(),
                        report.breach_alerts.len()
                    ),
                });
            }
        }
    });
    info!("Privacy hygiene scanner started (daily)");

    // --- System tuner: optimize when idle (check every hour) ---
    let tuner_data_dir = data_dir.clone();
    let tuner_event_bus = state.event_bus.clone();
    let _system_tuner_handle = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(3600)); // 1h
        let mut tuner = system_tuner::SystemTuner::new(tuner_data_dir.join("tuning"));
        loop {
            interval.tick().await;
            // Only optimize if system is idle (low CPU)
            if let Ok(load) = std::fs::read_to_string("/proc/loadavg") {
                if let Some(avg_str) = load.split_whitespace().next() {
                    if let Ok(avg) = avg_str.parse::<f64>() {
                        let cpus = num_cpus::get() as f64;
                        if avg < cpus * 0.3 {
                            info!(
                                "[system_tuner] System idle (load {:.2}), running optimization",
                                avg
                            );
                            let results = tuner.optimize_vm_settings();
                            if !results.is_empty() {
                                let summary = tuner.get_improvement_summary();
                                let _ = tuner_event_bus.send(events::DaemonEvent::Notification {
                                    priority: "info".into(),
                                    message: format!("[system_tuner] {}", summary),
                                });
                            }
                        }
                    }
                }
            }
        }
    });
    info!("System tuner started (hourly idle check)");

    // --- Backup monitor: daily health check ---
    let backup_event_bus = state.event_bus.clone();
    let _backup_monitor_handle = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(86400)); // 24h
        loop {
            interval.tick().await;
            let status = backup_monitor::check_backup_health().await;
            info!(
                "[backup_monitor] Check: tool={}, age={:?}h",
                status.tool, status.last_backup_age_hours
            );
            if status.tool == "none" {
                let _ = backup_event_bus.send(events::DaemonEvent::Notification {
                    priority: "warning".into(),
                    message:
                        "No se detecta herramienta de backup (restic/borg). Configura backups."
                            .into(),
                });
            } else if let Some(age) = status.last_backup_age_hours {
                if age > 48.0 {
                    let _ = backup_event_bus.send(events::DaemonEvent::Notification {
                        priority: "warning".into(),
                        message: format!(
                            "Backup atrasado: ultimo backup hace {:.0} horas ({}).",
                            age, status.tool
                        ),
                    });
                }
            }
        }
    });
    info!("Backup monitor started (daily check)");

    // --- Storage housekeeping: enforce file limits + purge old data (every 6h) ---
    let housekeeping_data_dir = data_dir.clone();
    let housekeeping_memory = state.memory_plane_manager.clone();
    let housekeeping_router = state.llm_router.clone();
    let housekeeping_ai = shared_ai_manager.clone();
    let _housekeeping_handle = tokio::spawn(async move {
        // Wait 5 minutes after boot before first housekeeping run
        tokio::time::sleep(Duration::from_secs(300)).await;
        let mut interval = tokio::time::interval(Duration::from_secs(6 * 3600)); // 6 hours
                                                                                 // Memory decay runs once per day; throttle by counting ticks (4 * 6h = 24h).
        let mut decay_tick: u32 = 0;
        loop {
            interval.tick().await;
            storage_housekeeping::run_housekeeping(&housekeeping_data_dir).await;
            sqlite_protection::backup_all_databases(&housekeeping_data_dir).await;
            sqlite_protection::check_all_databases(&housekeeping_data_dir).await;

            // Memory hygiene runs once per day (every 4th tick of the 6h
            // loop). Three-stage pipeline:
            //
            //   1. filter_garbage: drop entries with <30 ciphertext bytes
            //      (proxy for plaintext < ~10 chars: "ok", "gracias",
            //      etc.) and entries tagged/sourced as filler.
            //   2. apply_decay: Ebbinghaus exponential curve + connection
            //      bonus, plus garbage-collect of low-importance old
            //      entries. See `MemoryPlaneManager::apply_decay`.
            //   3. dedup_similar(0.92): merge memory pairs whose
            //      embeddings are within cosine 0.08 of each other,
            //      keeping the higher-importance one. The 0.92 threshold
            //      is conservative — it only fuses near-duplicates
            //      ("recordame X" / "recuérdame X") and leaves
            //      distinct-but-related memories alone.
            //
            // The same three functions are also exposed via the
            // `/memory_cleanup` Telegram tool for manual runs.
            decay_tick = decay_tick.wrapping_add(1);
            if decay_tick % 4 == 0 {
                let mem = housekeeping_memory.read().await;

                let garbage = mem.filter_garbage().await.unwrap_or(0);
                if garbage > 0 {
                    info!("memory_plane: filter_garbage removed {} entries", garbage);
                }

                match mem.boost_frequent_access().await {
                    Ok(boosted) if boosted > 0 => {
                        info!(
                            "memory_plane: boosted {} frequently-accessed entries",
                            boosted
                        );
                    }
                    Ok(_) => {}
                    Err(e) => warn!("memory_plane: boost_frequent_access failed: {}", e),
                }

                match mem.apply_decay().await {
                    Ok(report) => info!(
                        "memory_plane: decay pass complete (decayed={}, deleted={})",
                        report.decayed, report.deleted
                    ),
                    Err(e) => warn!("memory_plane: apply_decay failed: {}", e),
                }

                match mem.dedup_similar(0.92).await {
                    Ok(merged) if merged > 0 => info!(
                        "memory_plane: dedup_similar merged {} near-duplicate entries",
                        merged
                    ),
                    Ok(_) => {}
                    Err(e) => warn!("memory_plane: dedup_similar failed: {}", e),
                }

                // Cluster summarization runs in a tighter window (only
                // when the local hour is 02:00-04:59) so the LLM is not
                // burning cycles while the user is active. We also gate
                // it behind the daily decay tick — so it runs at most
                // once per day, and only on days where the housekeeping
                // tick lands inside the night window.
                //
                // Local time is intentional: bedtime is local, not UTC.
                use chrono::Timelike;
                let hour = chrono::Local::now().hour();
                if (2..5).contains(&hour) {
                    // Hold the read guard a bit longer for the LLM call.
                    // Cluster summarisation is bounded: max 3 clusters
                    // per pass, max 30 entries per cluster — keeps the
                    // nightly window predictable even on busy DBs.
                    let router = housekeeping_router.read().await;
                    match mem.summarize_clusters_with_router(&router, 3, 30).await {
                        Ok(report) if report.clusters_processed > 0 => info!(
                            "memory_plane: cluster summary pass complete (clusters={}, originals_archived={})",
                            report.clusters_processed, report.originals_archived
                        ),
                        Ok(_) => {}
                        Err(e) => {
                            warn!("memory_plane: summarize_clusters_with_router failed: {}", e)
                        }
                    }

                    // Cross-link recent memories via LLM-extracted triples.
                    match mem.cross_link_recent(&Some(housekeeping_ai.clone())).await {
                        Ok(links) if links > 0 => {
                            info!(
                                "memory_plane: cross_link_recent generated {} new links",
                                links
                            );
                        }
                        Ok(_) => {}
                        Err(e) => warn!("memory_plane: cross_link_recent failed: {}", e),
                    }
                }
            }
        }
    });
    info!("Storage housekeeping started (every 6h, 120-file limit per dir, daily memory hygiene: garbage+decay+dedup, nightly LLM cluster summary 02-05h)");

    // --- Self-improvement loop (Fase U): tick every 6 hours ---
    {
        let si_data_dir = data_dir.clone();
        let si_event_bus = state.event_bus.clone();
        let si_circuit_breaker = state.circuit_breaker.clone();
        let _self_improving_handle = tokio::spawn(async move {
            let mut daemon = self_improving::SelfImprovingDaemon::new(si_data_dir);
            // Wait 10 minutes after boot before first tick
            tokio::time::sleep(Duration::from_secs(600)).await;
            let mut interval = tokio::time::interval(Duration::from_secs(6 * 3600)); // 6h
            loop {
                interval.tick().await;
                if safe_mode::is_safe_mode() {
                    debug!("[self_improving] Skipping tick — safe mode active");
                    continue;
                }
                if !si_circuit_breaker.allow_modification().await {
                    debug!("[self_improving] Skipping tick — circuit breaker open");
                    continue;
                }
                // Record each self-improvement tick as a workflow action
                let _ = daemon.record_action("self-improvement-tick", "periodic");

                match daemon.tick() {
                    Ok(()) => {
                        // Log full status snapshot for observability
                        let status = daemon.get_status();
                        info!(
                            "[self_improving] Tick OK — {} metrics, {} patterns, last_tick={}",
                            status.prompt_metrics.len(),
                            status.detected_patterns.len(),
                            status.last_tick
                        );

                        // Check for prompt improvement suggestions and emit as events
                        if let Ok(suggestions) = daemon.suggest_prompt_improvements() {
                            for suggestion in &suggestions {
                                info!(
                                    "[self_improving] Prompt improvement: {} (success rate: {:.0}%)",
                                    suggestion.action,
                                    suggestion.success_rate * 100.0
                                );
                            }
                            if !suggestions.is_empty() {
                                let _ = si_event_bus.send(events::DaemonEvent::Notification {
                                    priority: "info".into(),
                                    message: format!(
                                        "Self-improvement: {} prompt improvement(s) suggested",
                                        suggestions.len()
                                    ),
                                });
                            }
                        }
                        // Check for workflow skill suggestions
                        let skills = daemon.suggest_skills();
                        if !skills.is_empty() {
                            info!(
                                "[self_improving] {} workflow skill(s) detected",
                                skills.len()
                            );
                        }
                    }
                    Err(e) => {
                        warn!("[self_improving] Tick failed: {e}");
                    }
                }
            }
        });
        info!("Self-improvement loop started (Fase U, every 6h)");
    }

    // --- Skill learning from supervisor task completions (Fix O) ---
    {
        let wl_data_dir = data_dir.clone();
        let mut wl_notify_rx = state.supervisor.subscribe();
        let wl_event_bus = state.event_bus.clone();
        tokio::spawn(async move {
            let learner = self_improving::SelfImprovingDaemon::new(wl_data_dir);
            loop {
                match wl_notify_rx.recv().await {
                    Ok(notification) => {
                        match &notification {
                            supervisor::SupervisorNotification::TaskCompleted {
                                objective,
                                result,
                                ..
                            } => {
                                let action = format!(
                                    "task_completed:{}",
                                    crate::str_utils::truncate_bytes_safe(objective, 80)
                                );
                                let context = format!(
                                    "result={}",
                                    crate::str_utils::truncate_bytes_safe(result, 120)
                                );
                                if let Err(e) = learner.record_action(&action, &context) {
                                    warn!("[workflow_learner] Failed to record completion: {e}");
                                }
                                // AQ.6 — Check if this action triggers a learned procedure
                                if let Some((proc_name, steps)) =
                                    learner.check_auto_trigger(&action, &context)
                                {
                                    info!(
                                        "[workflow_learner] Auto-trigger matched '{}': {} steps",
                                        proc_name,
                                        steps.len()
                                    );
                                }
                                // Also emit typed event for dashboard (Fix AL)
                                let _ = wl_event_bus.send(events::DaemonEvent::TaskCompleted {
                                    task_id: String::new(),
                                    objective: objective.clone(),
                                    result: result.clone(),
                                });
                            }
                            supervisor::SupervisorNotification::TaskFailed {
                                objective,
                                error,
                                ..
                            } => {
                                let action = format!(
                                    "task_failed:{}",
                                    crate::str_utils::truncate_bytes_safe(objective, 80)
                                );
                                let context = format!(
                                    "error={}",
                                    crate::str_utils::truncate_bytes_safe(error, 120)
                                );
                                if let Err(e) = learner.record_action(&action, &context) {
                                    warn!("[workflow_learner] Failed to record failure: {e}");
                                }
                                let _ = wl_event_bus.send(events::DaemonEvent::TaskFailed {
                                    task_id: String::new(),
                                    objective: objective.clone(),
                                    error: error.clone(),
                                });
                            }
                            _ => {}
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        warn!("[workflow_learner] Lagged {n} supervisor notifications");
                    }
                    Err(_) => break,
                }
            }
        });
        info!("Workflow learner wired to supervisor task completions");
    }

    // --- Config file watcher: auto-reload llm-providers.toml on change (polling) ---
    {
        let config_router = state.llm_router.clone();
        tokio::spawn(async move {
            let toml_paths = [
                std::path::PathBuf::from("/etc/lifeos/llm-providers.toml"),
                std::env::var("HOME")
                    .ok()
                    .map(|h| std::path::PathBuf::from(h).join(".config/lifeos/llm-providers.toml"))
                    .unwrap_or_default(),
            ];

            let mut last_modified: std::collections::HashMap<
                std::path::PathBuf,
                std::time::SystemTime,
            > = std::collections::HashMap::new();

            // Initialize timestamps
            for path in &toml_paths {
                if let Ok(meta) = tokio::fs::metadata(path).await {
                    if let Ok(modified) = meta.modified() {
                        last_modified.insert(path.clone(), modified);
                    }
                }
            }

            loop {
                tokio::time::sleep(Duration::from_secs(30)).await;

                for path in &toml_paths {
                    if let Ok(meta) = tokio::fs::metadata(path).await {
                        if let Ok(modified) = meta.modified() {
                            let changed = last_modified
                                .get(path)
                                .map(|lm| modified > *lm)
                                .unwrap_or(true);
                            if changed {
                                info!(
                                    "[config] {} changed, reloading providers...",
                                    path.display()
                                );
                                let mut router = config_router.write().await;
                                match router.reload_providers() {
                                    Ok(n) => info!("[config] Reloaded {} providers", n),
                                    Err(e) => {
                                        log::warn!("[config] Provider reload failed: {}", e)
                                    }
                                }
                                last_modified.insert(path.clone(), modified);
                            }
                        }
                    }
                }
            }
        });
        info!("Config file watcher started (polls every 30s)");
    }

    // --- AQ.1: Auto-update UserModel every 30 min ---
    {
        tokio::spawn(async move {
            // Wait 5 minutes after boot before first refresh
            tokio::time::sleep(Duration::from_secs(5 * 60)).await;
            loop {
                let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
                let data_dir = std::path::PathBuf::from(format!("{}/.local/share/lifeos", home));
                let mut model = crate::user_model::UserModel::load_from_dir(&data_dir).await;
                model.updated_at = Some(chrono::Utc::now());
                model.save(&data_dir).await.ok();
                info!("[user_model] Periodic refresh completed");
                tokio::time::sleep(Duration::from_secs(30 * 60)).await;
            }
        });
        info!("UserModel periodic refresh scheduled (every 30min, starts after 5min)");
    }

    // --- AQ.5: Night Shift via wlsunset ---
    {
        tokio::spawn(async move {
            // Wait 2 minutes after boot
            tokio::time::sleep(Duration::from_secs(2 * 60)).await;
            loop {
                let hour = chrono::Local::now().hour();
                if !(6..20).contains(&hour) {
                    // Night time — start wlsunset if not already running
                    let already_running = tokio::process::Command::new("pgrep")
                        .arg("wlsunset")
                        .output()
                        .await
                        .map(|o| o.status.success())
                        .unwrap_or(false);
                    if !already_running {
                        match tokio::process::Command::new("wlsunset")
                            .args(["-t", "3500", "-T", "6500"])
                            .spawn()
                        {
                            Ok(_) => info!("[night_shift] Started wlsunset (hour={})", hour),
                            Err(e) => warn!("[night_shift] Failed to start wlsunset: {e}"),
                        }
                    } else {
                        debug!("[night_shift] wlsunset already running (hour={})", hour);
                    }
                } else {
                    // Daytime — kill wlsunset if running
                    match tokio::process::Command::new("pkill")
                        .args(["wlsunset"])
                        .output()
                        .await
                    {
                        Ok(o) if o.status.success() => {
                            info!("[night_shift] Stopped wlsunset (hour={})", hour);
                        }
                        _ => {
                            debug!("[night_shift] wlsunset not running (hour={})", hour);
                        }
                    }
                }
                tokio::time::sleep(Duration::from_secs(30 * 60)).await;
            }
        });
        info!("Night shift (wlsunset) scheduler started (every 30min, starts after 2min)");
    }

    // Start supervisor loop with self-healing (restarts on panic)
    let supervisor_state = state.clone();
    let supervisor_handle = tokio::spawn(async move {
        let mut restart_count = 0u32;
        loop {
            info!("Starting supervisor loop (restart #{})", restart_count);
            let sv = supervisor_state.supervisor.clone();
            let result = tokio::spawn(async move { sv.run().await }).await;
            match result {
                Ok(()) => {
                    info!("Supervisor loop exited cleanly");
                    break;
                }
                Err(e) => {
                    error!("Supervisor panicked: {}. Restarting in 5s...", e);
                    restart_count += 1;
                    if restart_count > 10 {
                        error!("Supervisor restarted {} times, giving up", restart_count);
                        break;
                    }
                    tokio::time::sleep(Duration::from_secs(5)).await;
                }
            }
        }
    });

    // Start reactive thermal manager (reads actual CPU temp, adjusts cap dynamically)
    let thermal_mgr = Arc::new(thermal_manager::ThermalManager::new());
    let thermal_handle = {
        let tm = thermal_mgr.clone();
        tokio::spawn(async move { tm.run_loop().await })
    };

    // Attach thermal manager to Game Guard so it can switch to Gaming mode
    if let Some(ref gg) = state.game_guard {
        let g = gg.read().await;
        g.set_thermal_manager(thermal_mgr.clone()).await;
    }

    // Start GPU Game Guard loop (auto-offload LLM to RAM when gaming)
    let game_guard_handle = if let Some(ref gg) = state.game_guard {
        let game_guard_clone = gg.clone();
        let game_guard_event_tx = state.event_bus.clone();
        Some(tokio::spawn(async move {
            game_guard::run_game_guard_loop(game_guard_clone, game_guard_event_tx).await;
        }))
    } else {
        None
    };

    // ── Shared cross-bridge instances ──────────────────────────────────
    //
    // ConversationHistory, UserModel, and CronStore must be shared across
    // ALL bridges (SimpleX, Email) so that Axi has the
    // same context regardless of which channel the user writes from.
    // Previously each bridge created its own instance — this caused
    // conversation context, user preferences, and cron jobs to be siloed
    // per channel and invisible to other channels.
    #[cfg(feature = "messaging")]
    let shared_history = Arc::new(axi_tools::ConversationHistory::new());
    #[cfg(feature = "messaging")]
    let shared_cron_store = Arc::new(axi_tools::CronStore::new());
    let shared_user_model = {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/lifeos".into());
        let data_dir = std::path::PathBuf::from(format!("{}/.local/share/lifeos", home));
        let model = user_model::UserModel::load_from_dir(&data_dir).await;
        Arc::new(RwLock::new(model))
    };

    // Start SimpleX bridge if the CLI WebSocket is reachable (requires telegram
    // feature because it reuses the agentic chat infrastructure from axi_tools).
    //
    // Parity note: SimpleX is our privacy-first primary channel, so it must have
    // the SAME capability set as the former Telegram bridge. We pass ALL optional stores
    // (session, user_model, meetings, calendar) so agentic tools that depend on
    // them do not silently degrade when invoked through SimpleX.
    #[cfg(feature = "messaging")]
    let _simplex_handle = {
        if simplex_bridge::is_simplex_available().await {
            let tq = state.task_queue.clone();
            let router = state.llm_router.clone();
            let memory = Some(state.memory_plane_manager.clone());
            let ss = Some(state.session_store.clone());
            let um = Some(shared_user_model.clone());
            let ma = Some(meeting_archive.clone());
            let mast = Some(shared_meeting_assistant.clone());
            let cal = Some(state.calendar.clone());
            let hist = shared_history.clone();
            let cron = shared_cron_store.clone();
            let ev = state.event_bus.clone();
            Some(tokio::spawn(async move {
                simplex_bridge::run_simplex_bridge(
                    tq,
                    router,
                    memory,
                    ss,
                    um,
                    ma,
                    mast,
                    cal,
                    hist,
                    cron,
                    Some(ev),
                )
                .await;
            }))
        } else {
            info!("SimpleX bridge: CLI WebSocket not reachable on port 5226, skipping");
            None
        }
    };
    #[cfg(not(feature = "messaging"))]
    let _simplex_handle: Option<tokio::task::JoinHandle<()>> = None;

    // Start API server if enabled (must be after shared variables are initialized)
    let api_handle = if config.enable_api {
        info!("Starting REST API server on {}", config.api_bind_address);
        let bridge_state = SharedBridgeState {
            user_model: shared_user_model.clone(),
            meeting_assistant: shared_meeting_assistant.clone(),
            #[cfg(feature = "messaging")]
            conversation_history: shared_history.clone(),
            #[cfg(feature = "messaging")]
            cron_store: shared_cron_store.clone(),
        };
        Some(tokio::spawn(start_api_server(state.clone(), bridge_state)))
    } else {
        info!("REST API server disabled");
        None
    };

    // Notify systemd that the daemon is fully initialized
    notify_ready();
    info!("Notified systemd: READY=1");

    // Watchdog: ping systemd every 15s to prove we're alive
    tokio::spawn(async {
        loop {
            notify_watchdog();
            tokio::time::sleep(Duration::from_secs(15)).await;
        }
    });

    // SIGHUP handler — reload LLM providers without restarting the daemon
    {
        let sighup_router = state.llm_router.clone();
        tokio::spawn(async move {
            let mut sighup = signal::unix::signal(signal::unix::SignalKind::hangup())
                .expect("failed to create SIGHUP handler");
            loop {
                sighup.recv().await;
                info!("[main] SIGHUP received — reloading LLM providers");
                let mut router = sighup_router.write().await;
                match router.reload_providers() {
                    Ok(n) => info!("[main] Reloaded {} providers", n),
                    Err(e) => warn!("[main] Provider reload failed: {}", e),
                }
            }
        });
    }

    // Wait for shutdown signal
    info!("Daemon running. Press Ctrl+C to stop.");

    let mut sigint = signal::unix::signal(signal::unix::SignalKind::interrupt())?;
    let mut sigterm = signal::unix::signal(signal::unix::SignalKind::terminate())?;

    tokio::select! {
        _ = sigint.recv() => {
            info!("Received SIGINT, shutting down...");
        }
        _ = sigterm.recv() => {
            info!("Received SIGTERM, shutting down...");
        }
    }

    // Graceful shutdown
    info!("Stopping background tasks...");
    notify_stopping();

    if let Some(ref detector) = state.wake_word_detector {
        detector.stop();
    }

    // Ask long-running background loops to drain their current iteration
    // before we hit them with .abort(). This lets the sensory runtime
    // finish an in-flight camera capture + analyze + retention sweep
    // instead of leaving a partial JPG on disk.
    state.shutdown_notify.notify_waiters();

    // Cancel all tasks
    health_handle.abort();
    update_handle.abort();
    metrics_handle.abort();
    let mut sensory_handle = sensory_handle;
    match tokio::time::timeout(Duration::from_secs(3), &mut sensory_handle).await {
        Ok(Ok(())) => info!("Sensory runtime drained cleanly"),
        Ok(Err(e)) => warn!("Sensory runtime task ended with join error: {}", e),
        Err(_) => {
            warn!("Sensory runtime did not drain within 3s; aborting");
            sensory_handle.abort();
        }
    }
    state.supervisor.stop();
    supervisor_handle.abort();
    thermal_handle.abort();
    sleep_watch_handle.abort();
    if let Some(h) = game_guard_handle {
        h.abort();
    }
    dbus_handle.abort();
    portal_handle.abort();

    if let Some(handle) = api_handle {
        handle.abort();
    }

    if let Some(handle) = wake_word_handle {
        match tokio::time::timeout(Duration::from_secs(5), handle).await {
            Ok(Ok(())) => info!("Wake word detector stopped cleanly"),
            Ok(Err(e)) => warn!("Wake word detector task ended with join error: {}", e),
            Err(_) => warn!("Wake word detector did not stop within 5 seconds"),
        }
    }

    info!("Daemon stopped.");
    std::process::exit(0)
}

/// Shared infrastructure passed from main to the API server so that all
/// bridges (SimpleX, API) use the same instances.
struct SharedBridgeState {
    user_model: Arc<RwLock<user_model::UserModel>>,
    #[allow(dead_code)]
    meeting_assistant: Arc<tokio::sync::RwLock<meeting_assistant::MeetingAssistant>>,
    #[cfg(feature = "messaging")]
    conversation_history: Arc<axi_tools::ConversationHistory>,
    #[cfg(feature = "messaging")]
    cron_store: Arc<axi_tools::CronStore>,
}

/// Start REST API server
async fn start_api_server(state: Arc<DaemonState>, shared: SharedBridgeState) {
    let api_state = api::ApiState {
        data_dir: state.data_dir.clone(),
        system_monitor: state.system_monitor.clone(),
        health_monitor: state.health_monitor.clone(),
        ai_manager: state.ai_manager.clone(),
        notification_manager: state.notification_manager.clone(),
        overlay_manager: state.overlay_manager.clone(),
        screen_capture: state.screen_capture.clone(),
        sensory_pipeline_manager: state.sensory_pipeline_manager.clone(),
        experience_manager: state.experience_manager.clone(),
        update_scheduler: state.update_scheduler.clone(),
        follow_along_manager: state.follow_along_manager.clone(),
        context_policies_manager: state.context_policies_manager.clone(),
        telemetry_manager: state.telemetry_manager.clone(),
        agent_runtime_manager: state.agent_runtime_manager.clone(),
        memory_plane_manager: state.memory_plane_manager.clone(),
        visual_comfort_manager: state.visual_comfort_manager.clone(),
        accessibility_manager: state.accessibility_manager.clone(),
        lab_manager: state.lab_manager.clone(),
        llm_router: state.llm_router.clone(),
        task_queue: state.task_queue.clone(),
        supervisor: state.supervisor.clone(),
        scheduled_tasks: state.scheduled_tasks.clone(),
        health_tracker: state.health_tracker.clone(),
        calendar: state.calendar.clone(),
        meeting_archive: state.meeting_archive.clone(),
        event_bus: state.event_bus.clone(),
        config: api::ApiConfig {
            bind_address: state.config.api_bind_address,
            api_key: state.bootstrap_token.clone(),
            max_request_size: 10 * 1024 * 1024,
        },
        game_guard: state.game_guard.clone(),
        wake_word_detector: state.wake_word_detector.clone(),
        skill_registry: skill_generator::SkillRegistry::from_defaults(),
        user_model: shared.user_model.clone(),
        #[cfg(feature = "messaging")]
        conversation_history: shared.conversation_history.clone(),
        #[cfg(feature = "messaging")]
        cron_store: shared.cron_store.clone(),
        #[cfg(feature = "messaging")]
        sdd_store: Arc::new(axi_tools::SddStore::new()),
        session_store: state.session_store.clone(),
        #[cfg(feature = "messaging")]
        meeting_assistant: Some(shared.meeting_assistant.clone()),
        security_alert_buffer: state.security_alert_buffer.clone(),
    };

    // Perform initial skill registry load and start file watcher
    if let Err(e) = api_state.skill_registry.reload().await {
        log::warn!("Initial skill registry load failed: {}", e);
    }
    let watcher_registry = api_state.skill_registry.clone();
    tokio::spawn(async move {
        watcher_registry
            .watch_loop(std::time::Duration::from_secs(30))
            .await;
    });

    if let Err(e) = api::start_api_server(api_state).await {
        error!("API server error: {}", e);
    }
}

/// Load daemon configuration from file
async fn load_config() -> anyhow::Result<DaemonConfig> {
    let config_path = std::env::var("LIFEOS_DAEMON_CONFIG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from("/etc/lifeos/daemon.toml"));

    if config_path.exists() {
        let contents = tokio::fs::read_to_string(config_path).await?;
        let config: DaemonConfigFile = toml::from_str(&contents)?;

        let api_bind = config
            .api_bind_address
            .parse()
            .unwrap_or_else(|_| "127.0.0.1:8081".parse().unwrap());

        return Ok(DaemonConfig {
            health_check_interval: Duration::from_secs(config.health_check_interval_secs),
            update_check_interval: Duration::from_secs(config.update_check_interval_secs),
            metrics_collection_interval: Duration::from_secs(
                config.metrics_collection_interval_secs,
            ),
            enable_notifications: config.enable_notifications,
            enable_auto_updates: config.enable_auto_updates,
            enable_api: config.enable_api,
            api_bind_address: api_bind,
        });
    }

    Ok(DaemonConfig::default())
}

/// Configuration file structure
#[derive(Debug, serde::Deserialize)]
struct DaemonConfigFile {
    #[serde(default = "default_health_interval")]
    health_check_interval_secs: u64,
    #[serde(default = "default_update_interval")]
    update_check_interval_secs: u64,
    #[serde(default = "default_metrics_interval")]
    metrics_collection_interval_secs: u64,
    #[serde(default = "default_true")]
    enable_notifications: bool,
    #[serde(default = "default_true")]
    enable_auto_updates: bool,
    #[serde(default = "default_true")]
    enable_api: bool,
    #[serde(default = "default_api_bind")]
    api_bind_address: String,
}

fn default_health_interval() -> u64 {
    300
}
fn default_update_interval() -> u64 {
    86400
}
fn default_metrics_interval() -> u64 {
    60
}
fn default_true() -> bool {
    true
}
fn default_api_bind() -> String {
    "127.0.0.1:8081".to_string()
}

/// Run periodic health checks
async fn run_health_checks(state: Arc<DaemonState>) {
    let mut interval = tokio::time::interval(state.config.health_check_interval);

    loop {
        interval.tick().await;

        debug!("Running health check...");

        match state.health_monitor.check_all().await {
            Ok(report) => {
                let status = if report.healthy {
                    "ok"
                } else {
                    "issues_detected"
                };
                let issue_strings: Vec<String> =
                    report.issues.iter().map(|i| format!("{:?}", i)).collect();

                // Emit typed health_check event for the dashboard
                let _ = state.event_bus.send(events::DaemonEvent::HealthCheck {
                    status: status.to_string(),
                    issues: issue_strings,
                });

                if !report.healthy {
                    warn!("Health check detected issues: {:?}", report.issues);

                    for issue in &report.issues {
                        if let Err(e) = state.notification_manager.send_health_alert(issue).await {
                            error!("Failed to send health notification: {}", e);
                        }
                    }
                } else {
                    debug!("Health check passed");
                }

                // Update last check timestamp
                *state.last_health_check.write().await = Some(chrono::Local::now());
            }
            Err(e) => {
                error!("Health check failed: {}", e);
            }
        }
    }
}

/// Run periodic update checks by reading the cached state file written by the
/// system-level `lifeos-update-check.service` (which runs daily as root via a
/// systemd timer). The user daemon never calls `bootc` directly, because
/// `bootc status` requires root even for read-only access.
async fn run_update_checks(state: Arc<DaemonState>) {
    // Wait 10 minutes after boot before first check to avoid slowing startup
    // and to give the system timer a chance to populate the cache on fresh
    // installs.
    tokio::time::sleep(Duration::from_secs(600)).await;

    let mut interval = tokio::time::interval(state.config.update_check_interval);
    let mut last_notified_version: Option<String> = None;
    let mut warned_missing_cache = false;

    loop {
        interval.tick().await;

        debug!("Checking for updates (from cached state)...");

        let mut update_checker = state.update_checker.write().await;
        match update_checker.check_from_cached_state() {
            Ok(Some(result)) => {
                warned_missing_cache = false;

                if result.available {
                    info!(
                        "Update available: {} -> {}",
                        result.current_version, result.new_version
                    );

                    // Only notify once per distinct new_version to avoid spam
                    // on every poll.
                    let should_notify =
                        last_notified_version.as_deref() != Some(result.new_version.as_str());

                    if should_notify {
                        // Desktop notification via notify-rust
                        if let Err(e) = state
                            .notification_manager
                            .send_update_notification(&result.new_version)
                            .await
                        {
                            error!("Failed to send update notification: {}", e);
                        }

                        // Broadcast on event bus so dashboard/SimpleX/SSE subscribers see it
                        let _ = state.event_bus.send(events::DaemonEvent::Notification {
                            priority: "info".into(),
                            message: format!(
                                "Actualizacion de LifeOS disponible ({} -> {}). Ejecuta 'bootc upgrade' para actualizar.",
                                result.current_version, result.new_version
                            ),
                        });

                        last_notified_version = Some(result.new_version.clone());
                    }
                } else {
                    debug!("No updates available");
                    last_notified_version = None;
                }

                // Update last check timestamp
                *state.last_update_check.write().await = Some(chrono::Local::now());
            }
            Ok(None) => {
                if !warned_missing_cache {
                    info!(
                        "Update state cache not yet available at {} — waiting for lifeos-update-check.service to run",
                        updates::UPDATE_STATE_CACHE_PATH
                    );
                    warned_missing_cache = true;
                }
            }
            Err(e) => {
                error!("Update check failed (cached state): {}", e);
            }
        }
    }
}

/// Run periodic metrics collection
async fn run_metrics_collection(state: Arc<DaemonState>) {
    let mut interval = tokio::time::interval(state.config.metrics_collection_interval);

    loop {
        interval.tick().await;

        let mut system_monitor = state.system_monitor.write().await;
        match system_monitor.collect_metrics() {
            Ok(metrics) => {
                debug!(
                    "Collected metrics: CPU {:.1}%, Memory {:.1}%",
                    metrics.cpu_usage, metrics.memory_usage
                );

                // Store metrics (in a real implementation, this would go to a time-series DB)
                // For now, just check thresholds and alert if needed

                if metrics.cpu_usage > 90.0 {
                    warn!("High CPU usage: {:.1}%", metrics.cpu_usage);
                }

                if metrics.memory_usage > 90.0 {
                    warn!("High memory usage: {:.1}%", metrics.memory_usage);
                }

                if metrics.disk_usage > 90.0 {
                    warn!("High disk usage: {:.1}%", metrics.disk_usage);
                    if let Err(e) = state
                        .notification_manager
                        .send_disk_warning(metrics.disk_usage)
                        .await
                    {
                        error!("Failed to send disk warning: {}", e);
                    }
                }
            }
            Err(e) => {
                error!("Failed to collect metrics: {}", e);
            }
        }
    }
}

/// Run periodic sensory housekeeping: awareness refresh, presence updates and GPU sync.
async fn run_sensory_runtime(state: Arc<DaemonState>) {
    let mut interval = tokio::time::interval(Duration::from_secs(5));
    let wake_notify = state.wake_word_notify.clone();
    let shutdown_notify = state.shutdown_notify.clone();

    loop {
        // Wake immediately on rustpotter detection OR on interval tick.
        // Exit BETWEEN iterations on shutdown so the current cycle (which
        // may be mid-camera-capture / mid-analyze) finishes cleanly rather
        // than being aborted with a partial JPG on disk.
        tokio::select! {
            _ = interval.tick() => {},
            _ = wake_notify.notified() => {},
            _ = shutdown_notify.notified() => {
                info!("[sensory] shutdown requested; draining loop");
                return;
            },
        }

        let ai_manager = *state.ai_manager.read().await;
        let overlay_manager = state.overlay_manager.read().await.clone();
        let screen_capture = state.screen_capture.read().await.clone();
        let sensory_manager = state.sensory_pipeline_manager.read().await.clone();
        let follow_along_manager = state.follow_along_manager.read().await.clone();
        let memory_plane_manager = state.memory_plane_manager.read().await.clone();
        let agent_runtime_manager = state.agent_runtime_manager.read().await.clone();
        let telemetry_manager = state.telemetry_manager.read().await.clone();

        if let Err(e) = sensory_manager.refresh_capabilities(&ai_manager).await {
            debug!("Failed to refresh sensory capabilities: {}", e);
            continue;
        }

        let runtime = agent_runtime_manager.sensory_capture_runtime().await;
        let always_on = agent_runtime_manager.always_on_runtime().await;
        if let Err(e) = sensory_manager
            .sync_runtime(
                SensoryRuntimeSync {
                    audio_enabled: runtime.audio_enabled,
                    screen_enabled: runtime.screen_enabled,
                    camera_enabled: runtime.camera_enabled,
                    tts_enabled: runtime.tts_enabled,
                    kill_switch_active: runtime.kill_switch_active,
                    capture_interval_seconds: runtime.capture_interval_seconds,
                    always_on_active: always_on.enabled,
                    wake_word: Some(always_on.wake_word.as_str()),
                },
                &overlay_manager,
            )
            .await
        {
            warn!("Failed to sync sensory runtime state: {}", e);
        }

        // Refresh meeting/call detection state.
        let prev_meeting_active = {
            let st = sensory_manager.status().await;
            st.meeting.active
        };
        let meeting = sensory_manager.refresh_meeting_state().await;
        if meeting.active != prev_meeting_active {
            let _ = state
                .event_bus
                .send(events::DaemonEvent::MeetingStateChanged {
                    active: meeting.active,
                    app: meeting.conferencing_app.clone(),
                });
        }

        if runtime.audio_enabled && !runtime.kill_switch_active && always_on.enabled {
            // Sync hotword_enabled state with the wake word detector.
            // Pause wake word during meetings to prevent false triggers.
            if let Some(ref detector) = state.wake_word_detector {
                if meeting.active {
                    detector.pause();
                } else if always_on.hotword_enabled {
                    detector.resume();
                } else {
                    detector.pause();
                }
                // Update audio source if it changed (BT connect/disconnect).
                let new_source = {
                    let st = sensory_manager.status().await;
                    st.capabilities.always_on_source.clone()
                };
                detector.set_source(new_source);
            }

            // Skip voice detection entirely during a meeting.
            if !meeting.active {
                // Dispatch: rustpotter (streaming) or legacy whisper-based detection.
                let rustpotter_detected = match state.wake_word_detector {
                    Some(ref d) => d.take_detection().await.is_some(),
                    None => false,
                };

                if rustpotter_detected {
                    let _ = state.event_bus.send(events::DaemonEvent::WakeWordDetected {
                        word: always_on.wake_word.clone(),
                    });
                    let cycle = AlwaysOnCycle {
                        ai_manager: &ai_manager,
                        overlay: &overlay_manager,
                        screen_capture: &screen_capture,
                        memory_plane: &memory_plane_manager,
                        telemetry: &telemetry_manager,
                        wake_word: always_on.wake_word.as_str(),
                        hotword_triggered: true,
                        screen_enabled: runtime.screen_enabled,
                        wake_word_detector: state.wake_word_detector.as_ref().map(|d| d.as_ref()),
                    };
                    match sensory_manager.run_post_wakeword_cycle(cycle).await {
                        Ok(Some(_)) => continue,
                        Ok(None) => {}
                        Err(e) => warn!("Failed to run post-wakeword voice cycle: {}", e),
                    }
                } else if state.wake_word_detector.is_some() {
                    // Rustpotter active but no wake word — check continuous conversation window.
                    let in_continuous = sensory_manager.is_continuous_listen_active().await;
                    if in_continuous {
                        let cycle = AlwaysOnCycle {
                            ai_manager: &ai_manager,
                            overlay: &overlay_manager,
                            screen_capture: &screen_capture,
                            memory_plane: &memory_plane_manager,
                            telemetry: &telemetry_manager,
                            wake_word: always_on.wake_word.as_str(),
                            hotword_triggered: false,
                            screen_enabled: runtime.screen_enabled,
                            wake_word_detector: state
                                .wake_word_detector
                                .as_ref()
                                .map(|d| d.as_ref()),
                        };
                        match sensory_manager.run_post_wakeword_cycle(cycle).await {
                            Ok(Some(_)) => continue,
                            Ok(None) => {}
                            Err(e) => debug!("Continuous conversation cycle failed: {}", e),
                        }
                    }
                    // Otherwise rustpotter is listening, do nothing.
                } else {
                    // No rustpotter — fall back to legacy capture-transcribe-match.
                    let cycle = AlwaysOnCycle {
                        ai_manager: &ai_manager,
                        overlay: &overlay_manager,
                        screen_capture: &screen_capture,
                        memory_plane: &memory_plane_manager,
                        telemetry: &telemetry_manager,
                        wake_word: always_on.wake_word.as_str(),
                        hotword_triggered: false,
                        screen_enabled: runtime.screen_enabled,
                        wake_word_detector: state.wake_word_detector.as_ref().map(|d| d.as_ref()),
                    };
                    match sensory_manager.run_always_on_cycle(cycle).await {
                        Ok(Some(_)) => continue,
                        Ok(None) => {}
                        Err(e) => debug!("Failed to run always-on voice cycle: {}", e),
                    }
                }
            }
        }

        // Poll compositor for active window (lightweight, no screenshot).
        if !runtime.kill_switch_active {
            if let Some((app, title)) = sensory_manager.update_active_window().await {
                follow_along_manager
                    .record_window_change(&app, &title)
                    .await;
                let _ = state.event_bus.send(events::DaemonEvent::WindowChanged {
                    app: app.clone(),
                    title,
                });
            }
        }

        if runtime.screen_enabled
            && !runtime.kill_switch_active
            && sensory_manager
                .is_screen_awareness_due(runtime.capture_interval_seconds)
                .await
        {
            if let Err(e) = sensory_manager
                .run_screen_awareness_cycle(
                    &ai_manager,
                    &overlay_manager,
                    &screen_capture,
                    &memory_plane_manager,
                    Some(&follow_along_manager),
                )
                .await
            {
                warn!("Failed to run screen awareness cycle: {}", e);
            }
        }

        if runtime.camera_enabled
            && !runtime.kill_switch_active
            && sensory_manager
                .is_presence_refresh_due(runtime.capture_interval_seconds)
                .await
        {
            if let Err(e) = sensory_manager
                .update_presence(
                    &ai_manager,
                    &overlay_manager,
                    &follow_along_manager,
                    &memory_plane_manager,
                )
                .await
            {
                warn!("Failed to update camera presence: {}", e);
            }
        }
    }
}
// trigger ci
