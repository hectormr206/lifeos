//! LifeOS System Daemon (lifeosd)
//!
//! Provides:
//! - System health monitoring
//! - Auto-update checks
//! - Health monitoring
//! - Notification system
//! - D-Bus interface for system integration
//! - REST API for mobile companion app

use log::{debug, error, info, warn};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::signal;
use tokio::sync::RwLock;

mod accessibility;
mod agent_roles;
mod agent_runtime;
mod ai;
mod api;
#[allow(dead_code)]
mod app_contracts;
#[allow(dead_code)]
mod autonomous_agent;
#[allow(dead_code)]
mod backup_monitor;
#[allow(dead_code)]
mod battery_manager;
#[allow(dead_code)]
mod browser_automation;
#[allow(dead_code)]
mod calendar;
#[allow(dead_code)]
mod comm_bridges;
mod computer_use;
#[allow(dead_code)]
mod connector_registry;
mod context_policies;
#[allow(dead_code)]
mod cosmic_control;
#[allow(dead_code)]
mod desktop_operator;
#[allow(dead_code)]
mod email_bridge;
#[allow(dead_code)]
mod ergonomics;
mod events;
#[allow(dead_code)]
mod exec_whitelist;
mod experience_modes;
#[allow(dead_code)]
mod eye_health;
mod follow_along;
#[allow(dead_code)]
mod game_assistant;
mod game_guard;
#[allow(dead_code)]
mod gaming_agent;
#[allow(dead_code)]
mod git_workflow;
mod health;
#[allow(dead_code)]
mod health_tracking;
#[allow(dead_code)]
mod home_assistant;
#[allow(dead_code)]
mod intent_parser;
#[cfg(feature = "ui-overlay")]
#[allow(dead_code)]
mod keyboard_shortcut;
#[allow(dead_code)]
mod knowledge_graph;
mod lab;
mod llm_router;
#[allow(dead_code)]
mod matrix_bridge;
#[allow(dead_code)]
mod mcp_server;
#[allow(dead_code)]
mod meeting_assistant;
mod memory_plane;
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
#[allow(dead_code)]
mod privacy_hygiene;
#[allow(dead_code)]
mod proactive;
#[allow(dead_code)]
mod prompt_tuner;
#[allow(dead_code)]
mod scheduled_tasks;
mod screen_capture;
#[allow(dead_code)]
mod security_daemon;
#[allow(dead_code)]
mod self_improving;
mod sensory_pipeline;
#[allow(dead_code)]
mod signal_bridge;
#[allow(dead_code)]
mod skill_generator;
#[allow(dead_code)]
mod speaker_id;
mod supervisor;
mod system;
mod task_queue;
mod telegram_bridge;
mod telemetry;
mod tuf;
mod update_scheduler;
mod updates;
#[allow(dead_code)]
mod usb_guard;
mod visual_comfort;
mod wake_word;
#[allow(dead_code)]
mod whatsapp_bridge;

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
            update_check_interval: Duration::from_secs(3600), // 1 hour
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

# Telegram Bot (obten tu token de @BotFather)
LIFEOS_TELEGRAM_BOT_TOKEN=
LIFEOS_TELEGRAM_CHAT_ID=

# Email (opcional, para bridge de email)
LIFEOS_EMAIL_IMAP_HOST=
LIFEOS_EMAIL_IMAP_USER=
LIFEOS_EMAIL_IMAP_PASS=
LIFEOS_EMAIL_SMTP_HOST=

# WhatsApp Cloud API (opcional)
LIFEOS_WHATSAPP_TOKEN=
LIFEOS_WHATSAPP_PHONE_ID=
LIFEOS_WHATSAPP_VERIFY_TOKEN=
LIFEOS_WHATSAPP_ALLOWED_NUMBERS=

# Matrix/Element (opcional)
LIFEOS_MATRIX_HOMESERVER=
LIFEOS_MATRIX_USER_ID=
LIFEOS_MATRIX_ACCESS_TOKEN=
LIFEOS_MATRIX_ROOM_IDS=

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
                    "Created LLM providers template at {} — edit it to enable Telegram, Cerebras, etc.",
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
#[allow(dead_code)]
pub struct DaemonState {
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
    pub bootstrap_token: Option<String>,
    pub last_health_check: RwLock<Option<chrono::DateTime<chrono::Local>>>,
    pub last_update_check: RwLock<Option<chrono::DateTime<chrono::Local>>>,
    pub wake_word_detector: Option<Arc<wake_word::WakeWordDetector>>,
    pub wake_word_notify: Arc<tokio::sync::Notify>,
    pub event_bus: tokio::sync::broadcast::Sender<events::DaemonEvent>,
    pub game_guard: Option<Arc<RwLock<game_guard::GameGuard>>>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Initialize logging
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info,zbus=warn,tracing=warn"),
    )
    .init();

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
    let shared_memory = Arc::new(RwLock::new(
        MemoryPlaneManager::new(data_dir.clone()).unwrap_or_else(|e| {
            warn!("Failed to initialize MemoryPlaneManager: {}", e);
            MemoryPlaneManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
        }),
    ));

    // Initialize state
    let state = Arc::new(DaemonState {
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
        sensory_pipeline_manager: Arc::new(RwLock::new(
            SensoryPipelineManager::new(data_dir.clone()).unwrap_or_else(|e| {
                warn!("Failed to initialize SensoryPipelineManager: {}", e);
                SensoryPipelineManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
            }),
        )),
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
        bootstrap_token,
        last_health_check: RwLock::new(None),
        last_update_check: RwLock::new(None),
        wake_word_detector,
        wake_word_notify: wake_word_notify.clone(),
        event_bus: event_tx,
        game_guard: Some(Arc::new(RwLock::new(game_guard::GameGuard::new(
            game_guard::GameGuardConfig::default(),
        )))),
    });

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

    // Start API server if enabled
    let api_handle = if config.enable_api {
        info!("Starting REST API server on {}", config.api_bind_address);
        Some(tokio::spawn(start_api_server(state.clone())))
    } else {
        info!("REST API server disabled");
        None
    };

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
    if let Some(ref detector) = state.wake_word_detector {
        detector.run();
        info!("Rustpotter wake word listener started");
    }

    // Launch the floating mini-widget ("Eye of Axi") on a GTK thread.
    // Only when a graphical display is available (skip in CI / headless).
    #[cfg(feature = "ui-overlay")]
    {
        ensure_graphical_environment();
        let has_display =
            std::env::var("WAYLAND_DISPLAY").is_ok() || std::env::var("DISPLAY").is_ok();
        if has_display {
            let token_for_widget = state.bootstrap_token.clone().unwrap_or_default();
            let widget_state = {
                let overlay = state.overlay_manager.read().await;
                overlay.get_state().await
            };
            let dashboard_url = format!(
                "http://127.0.0.1:{}/dashboard?token={}",
                state.config.api_bind_address.port(),
                token_for_widget,
            );
            mini_widget::spawn_mini_widget(
                state.event_bus.clone(),
                dashboard_url,
                widget_state.mini_widget.visible,
                format!("{:?}", widget_state.axi_state),
                widget_state.mini_widget.badge,
                widget_state.mini_widget.aura,
            );
            info!("Mini-widget (Eye of Axi) launched");
        } else {
            info!("No graphical display detected — mini-widget disabled");
        }
    }

    // Start background tasks
    let health_handle = tokio::spawn(run_health_checks(state.clone()));
    let update_handle = tokio::spawn(run_update_checks(state.clone()));
    let metrics_handle = tokio::spawn(run_metrics_collection(state.clone()));
    let sensory_handle = tokio::spawn(run_sensory_runtime(state.clone()));

    // Proactive notifications loop — checks every 5 minutes
    let proactive_state = state.clone();
    let _proactive_handle = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(300));
        loop {
            interval.tick().await;
            let alerts = proactive::check_all(Some(&proactive_state.task_queue)).await;
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

    // Calendar reminder check — every 60s checks for due reminders
    let calendar_state = state.clone();
    let _calendar_handle = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(60));
        loop {
            interval.tick().await;
            if let Ok(reminders) = calendar_state.calendar.due_reminders() {
                for event in &reminders {
                    let _ = calendar_state
                        .event_bus
                        .send(events::DaemonEvent::Notification {
                            priority: "info".into(),
                            message: format!(
                                "Recordatorio: {} a las {}",
                                event.title, event.start_time
                            ),
                        });
                }
            }
        }
    });

    // Autonomous agent — check user presence every 30s, activate when screen locked
    let autonomous_event_bus = state.event_bus.clone();
    let _autonomous_handle = tokio::spawn(async move {
        let mut agent = autonomous_agent::AutonomousAgent::new();
        let mut interval = tokio::time::interval(Duration::from_secs(30));
        loop {
            interval.tick().await;
            if agent.check_presence().await.is_ok() && agent.should_work() {
                let _ = autonomous_event_bus.send(events::DaemonEvent::Notification {
                    priority: "info".into(),
                    message: "Axi en modo autonomo — trabajando mientras estas ausente.".into(),
                });
            }
        }
    });

    // Meeting assistant — check for active meetings every 15s
    let meeting_data_dir = data_dir.clone();
    let meeting_event_bus = state.event_bus.clone();
    let _meeting_handle = tokio::spawn(async move {
        let mut assistant = meeting_assistant::MeetingAssistant::new(meeting_data_dir);
        let mut interval = tokio::time::interval(Duration::from_secs(15));
        loop {
            interval.tick().await;
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
                    log::debug!("Meeting detection error: {}", e);
                }
            }
        }
    });

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

    // Start Telegram bridge if configured
    #[cfg(feature = "telegram")]
    let telegram_handle = {
        if let Some(tg_config) = telegram_bridge::TelegramConfig::from_env() {
            let tq = state.task_queue.clone();
            let router = state.llm_router.clone();
            let notify_rx = state.supervisor.subscribe();
            Some(tokio::spawn(async move {
                telegram_bridge::run_telegram_bot(tg_config, tq, router, notify_rx).await;
            }))
        } else {
            info!("Telegram bridge: LIFEOS_TELEGRAM_BOT_TOKEN not set, skipping");
            None
        }
    };
    #[cfg(not(feature = "telegram"))]
    let telegram_handle: Option<tokio::task::JoinHandle<()>> = None;

    // Start WhatsApp bridge if configured
    #[cfg(feature = "whatsapp")]
    let whatsapp_handle = {
        if let Some(wa_config) = whatsapp_bridge::WhatsAppConfig::from_env() {
            let tq = state.task_queue.clone();
            let router = state.llm_router.clone();
            let notify_rx = state.supervisor.subscribe();
            Some(tokio::spawn(async move {
                whatsapp_bridge::run_whatsapp_bridge(wa_config, tq, router, notify_rx).await;
            }))
        } else {
            info!("WhatsApp bridge: LIFEOS_WHATSAPP_TOKEN not set, skipping");
            None
        }
    };
    #[cfg(not(feature = "whatsapp"))]
    let whatsapp_handle: Option<tokio::task::JoinHandle<()>> = None;

    // Start Matrix bridge if configured
    #[cfg(feature = "matrix")]
    let matrix_handle = {
        if let Some(mx_config) = matrix_bridge::MatrixConfig::from_env() {
            let tq = state.task_queue.clone();
            let router = state.llm_router.clone();
            let notify_rx = state.supervisor.subscribe();
            Some(tokio::spawn(async move {
                matrix_bridge::run_matrix_bridge(mx_config, tq, router, notify_rx).await;
            }))
        } else {
            info!("Matrix bridge: LIFEOS_MATRIX_ACCESS_TOKEN not set, skipping");
            None
        }
    };
    #[cfg(not(feature = "matrix"))]
    let matrix_handle: Option<tokio::task::JoinHandle<()>> = None;

    // Start Signal bridge if configured
    #[cfg(feature = "signal")]
    let signal_handle = {
        if let Some(sig_config) = signal_bridge::SignalConfig::from_env() {
            let tq = state.task_queue.clone();
            let router = state.llm_router.clone();
            let notify_rx = state.supervisor.subscribe();
            Some(tokio::spawn(async move {
                signal_bridge::run_signal_bridge(sig_config, tq, router, notify_rx).await;
            }))
        } else {
            info!("Signal bridge: LIFEOS_SIGNAL_PHONE not set, skipping");
            None
        }
    };
    #[cfg(not(feature = "signal"))]
    let signal_handle: Option<tokio::task::JoinHandle<()>> = None;

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

    // Cancel all tasks
    health_handle.abort();
    update_handle.abort();
    metrics_handle.abort();
    sensory_handle.abort();
    state.supervisor.stop();
    supervisor_handle.abort();
    if let Some(h) = game_guard_handle {
        h.abort();
    }
    if let Some(h) = telegram_handle {
        h.abort();
    }
    if let Some(h) = whatsapp_handle {
        h.abort();
    }
    if let Some(h) = matrix_handle {
        h.abort();
    }
    if let Some(h) = signal_handle {
        h.abort();
    }
    dbus_handle.abort();
    portal_handle.abort();

    if let Some(handle) = api_handle {
        handle.abort();
    }

    info!("Daemon stopped.");
    Ok(())
}

/// Start REST API server
async fn start_api_server(state: Arc<DaemonState>) {
    let api_state = api::ApiState {
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
        event_bus: state.event_bus.clone(),
        config: api::ApiConfig {
            bind_address: state.config.api_bind_address,
            api_key: state.bootstrap_token.clone(),
            enable_cors: true,
            max_request_size: 10 * 1024 * 1024,
        },
        game_guard: state.game_guard.clone(),
        wake_word_detector: state.wake_word_detector.clone(),
    };

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
    3600
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

/// Run periodic update checks
async fn run_update_checks(state: Arc<DaemonState>) {
    // Skip update checks when bootc status is not accessible (needs root).
    let bootc_ok = std::process::Command::new("bootc")
        .args(["status", "--json"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !bootc_ok {
        info!("Update checks disabled (bootc status not accessible — run as root or via systemd)");
        return;
    }

    let mut interval = tokio::time::interval(state.config.update_check_interval);

    loop {
        interval.tick().await;

        debug!("Checking for updates...");

        let mut update_checker = state.update_checker.write().await;
        match update_checker.check_for_updates().await {
            Ok(result) => {
                if result.available {
                    info!(
                        "Update available: {} -> {}",
                        result.current_version, result.new_version
                    );

                    if let Err(e) = state
                        .notification_manager
                        .send_update_notification(&result.new_version)
                        .await
                    {
                        error!("Failed to send update notification: {}", e);
                    }

                    // Auto-update if enabled
                    if state.config.enable_auto_updates {
                        info!("Auto-updates enabled, staging update...");
                        if let Err(e) = update_checker.stage_update().await {
                            error!("Failed to stage update: {}", e);
                        }
                    }
                } else {
                    debug!("No updates available");
                }

                // Update last check timestamp
                *state.last_update_check.write().await = Some(chrono::Local::now());
            }
            Err(e) => {
                error!("Update check failed: {}", e);
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

    loop {
        // Wake immediately on rustpotter detection OR on interval tick.
        tokio::select! {
            _ = interval.tick() => {},
            _ = wake_notify.notified() => {},
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
                let cycle = AlwaysOnCycle {
                    ai_manager: &ai_manager,
                    overlay: &overlay_manager,
                    screen_capture: &screen_capture,
                    memory_plane: &memory_plane_manager,
                    telemetry: &telemetry_manager,
                    wake_word: always_on.wake_word.as_str(),
                    screen_enabled: runtime.screen_enabled,
                };

                // Dispatch: rustpotter (streaming) or legacy whisper-based detection.
                let rustpotter_detected = match state.wake_word_detector {
                    Some(ref d) => d.take_detection().await.is_some(),
                    None => false,
                };

                if rustpotter_detected {
                    let _ = state.event_bus.send(events::DaemonEvent::WakeWordDetected {
                        word: always_on.wake_word.clone(),
                    });
                    match sensory_manager.run_post_wakeword_cycle(cycle).await {
                        Ok(Some(_)) => continue,
                        Ok(None) => {}
                        Err(e) => warn!("Failed to run post-wakeword voice cycle: {}", e),
                    }
                } else if state.wake_word_detector.is_none() {
                    // No rustpotter — fall back to legacy capture-transcribe-match.
                    match sensory_manager.run_always_on_cycle(cycle).await {
                        Ok(Some(_)) => continue,
                        Ok(None) => {}
                        Err(e) => debug!("Failed to run always-on voice cycle: {}", e),
                    }
                }
                // If rustpotter is active but no detection, do nothing (it's listening).
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
