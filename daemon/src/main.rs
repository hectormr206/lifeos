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
mod agent_runtime;
mod ai;
mod api;
mod computer_use;
mod context_policies;
mod events;
mod experience_modes;
mod follow_along;
mod health;
#[cfg(feature = "ui-overlay")]
#[allow(dead_code)]
mod keyboard_shortcut;
mod lab;
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
mod screen_capture;
mod sensory_pipeline;
mod system;
mod telemetry;
mod tuf;
mod update_scheduler;
mod updates;
mod visual_comfort;
mod wake_word;

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
    pub bootstrap_token: Option<String>,
    pub last_health_check: RwLock<Option<chrono::DateTime<chrono::Local>>>,
    pub last_update_check: RwLock<Option<chrono::DateTime<chrono::Local>>>,
    pub wake_word_detector: Option<Arc<wake_word::WakeWordDetector>>,
    pub wake_word_notify: Arc<tokio::sync::Notify>,
    pub event_bus: tokio::sync::broadcast::Sender<events::DaemonEvent>,
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
        let model_path = std::path::PathBuf::from(wake_word::RUSTPOTTER_MODEL_PATH);
        if wake_word::WakeWordDetector::available() && model_path.exists() {
            match wake_word::WakeWordDetector::new(model_path, None) {
                Ok(detector) => {
                    info!("Rustpotter wake word detector initialized");
                    Some(Arc::new(detector))
                }
                Err(e) => {
                    warn!("Rustpotter wake word detector unavailable: {}", e);
                    None
                }
            }
        } else {
            if !wake_word::WakeWordDetector::available() {
                info!("Wake word feature not compiled — using Whisper-based detection");
            } else {
                info!(
                    "Rustpotter model not found at {} — using Whisper-based detection",
                    wake_word::RUSTPOTTER_MODEL_PATH
                );
            }
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
        memory_plane_manager: Arc::new(RwLock::new(
            MemoryPlaneManager::new(data_dir.clone()).unwrap_or_else(|e| {
                warn!("Failed to initialize MemoryPlaneManager: {}", e);
                MemoryPlaneManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
            }),
        )),
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
        bootstrap_token,
        last_health_check: RwLock::new(None),
        last_update_check: RwLock::new(None),
        wake_word_detector,
        wake_word_notify: wake_word_notify.clone(),
        event_bus: event_tx,
    });

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
        event_bus: state.event_bus.clone(),
        config: api::ApiConfig {
            bind_address: state.config.api_bind_address,
            api_key: state.bootstrap_token.clone(),
            enable_cors: true,
            max_request_size: 10 * 1024 * 1024,
        },
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
            warn!("Failed to refresh sensory capabilities: {}", e);
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
                        Err(e) => warn!("Failed to run always-on voice cycle: {}", e),
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
