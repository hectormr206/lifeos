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
mod experience_modes;
mod follow_along;
mod health;
#[cfg(feature = "ui-overlay")]
#[allow(dead_code)]
mod keyboard_shortcut;
mod lab;
mod memory_plane;
mod models;
mod notifications;
mod overlay;
#[cfg(feature = "ui-overlay")]
#[allow(dead_code)]
mod overlay_window;
#[cfg(feature = "dbus")]
mod permissions;
#[cfg(feature = "dbus")]
mod portal;
mod screen_capture;
mod system;
mod telemetry;
mod tuf;
mod update_scheduler;
mod updates;
mod visual_comfort;

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
            enable_auto_updates: false,
            enable_api: true,
            api_bind_address: "127.0.0.1:8081".parse().unwrap(),
        }
    }
}

/// Helper to generate and save bootstrap token
fn generate_bootstrap_token() -> std::io::Result<String> {
    use std::fs::File;
    use std::io::Read;
    use std::os::unix::fs::PermissionsExt;

    let mut buf = [0u8; 16];
    let mut f = File::open("/dev/urandom")?;
    f.read_exact(&mut buf)?;
    let token = buf.iter().map(|b| format!("{:02x}", b)).collect::<String>();

    let runtime_dir =
        std::env::var("LIFEOS_RUNTIME_DIR").unwrap_or_else(|_| "/run/lifeos".to_string());
    let dir = std::path::Path::new(&runtime_dir);
    let path = dir.join("bootstrap.token");
    std::fs::create_dir_all(dir)?;
    let mut dir_perms = std::fs::metadata(dir)?.permissions();
    dir_perms.set_mode(0o700);
    std::fs::set_permissions(dir, dir_perms)?;

    std::fs::write(&path, &token)?;

    let mut perms = std::fs::metadata(&path)?.permissions();
    perms.set_mode(0o600); // Only owner can read/write
    std::fs::set_permissions(&path, perms)?;

    log::info!("Bootstrap token generated at {}", path.display());
    Ok(token)
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
    pub experience_manager: Arc<RwLock<ExperienceManager>>,
    pub update_scheduler: Arc<RwLock<UpdateScheduler>>,
    pub follow_along_manager: Arc<RwLock<FollowAlongManager>>,
    pub context_policies_manager: Arc<RwLock<ContextPoliciesManager>>,
    pub telemetry_manager: Arc<RwLock<TelemetryManager>>,
    pub agent_runtime_manager: Arc<RwLock<AgentRuntimeManager>>,
    pub memory_plane_manager: Arc<RwLock<MemoryPlaneManager>>,
    pub visual_comfort_manager: Arc<RwLock<VisualComfortManager>>,
    pub lab_manager: Arc<RwLock<LabManager>>,
    pub bootstrap_token: Option<String>,
    pub last_health_check: RwLock<Option<chrono::DateTime<chrono::Local>>>,
    pub last_update_check: RwLock<Option<chrono::DateTime<chrono::Local>>>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Initialize logging
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

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

    // Initialize state
    let state = Arc::new(DaemonState {
        config: config.clone(),
        system_monitor: Arc::new(RwLock::new(SystemMonitor::new())),
        health_monitor: Arc::new(HealthMonitor::new()),
        update_checker: Arc::new(RwLock::new(UpdateChecker::new())),
        notification_manager: Arc::new(NotificationManager::new(config.enable_notifications)),
        ai_manager: Arc::new(RwLock::new(ai::AiManager::new())),
        overlay_manager: Arc::new(RwLock::new(OverlayManager::new(PathBuf::from(
            "/var/lib/lifeos/screenshots",
        )))),
        screen_capture: Arc::new(RwLock::new(ScreenCapture::new(PathBuf::from(
            "/var/lib/lifeos/screenshots",
        )))),
        experience_manager: Arc::new(RwLock::new(ExperienceManager::new(PathBuf::from(
            "/var/lib/lifeos",
        )))),
        update_scheduler: Arc::new(RwLock::new(UpdateScheduler::new(PathBuf::from(
            "/var/lib/lifeos",
        )))),
        follow_along_manager: Arc::new(RwLock::new(
            FollowAlongManager::new(PathBuf::from("/var/lib/lifeos")).unwrap_or_else(|e| {
                warn!("Failed to initialize FollowAlongManager: {}", e);
                FollowAlongManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
            }),
        )),
        context_policies_manager: Arc::new(RwLock::new(
            ContextPoliciesManager::new(PathBuf::from("/var/lib/lifeos")).unwrap_or_else(|e| {
                warn!("Failed to initialize ContextPoliciesManager: {}", e);
                ContextPoliciesManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
            }),
        )),
        telemetry_manager: Arc::new(RwLock::new(
            TelemetryManager::new(PathBuf::from("/var/lib/lifeos")).unwrap_or_else(|e| {
                warn!("Failed to initialize TelemetryManager: {}", e);
                TelemetryManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
            }),
        )),
        agent_runtime_manager: Arc::new(RwLock::new(
            AgentRuntimeManager::new(PathBuf::from("/var/lib/lifeos")).unwrap_or_else(|e| {
                warn!("Failed to initialize AgentRuntimeManager: {}", e);
                AgentRuntimeManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
            }),
        )),
        memory_plane_manager: Arc::new(RwLock::new(
            MemoryPlaneManager::new(PathBuf::from("/var/lib/lifeos")).unwrap_or_else(|e| {
                warn!("Failed to initialize MemoryPlaneManager: {}", e);
                MemoryPlaneManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
            }),
        )),
        visual_comfort_manager: Arc::new(RwLock::new(VisualComfortManager::new(PathBuf::from(
            "/var/lib/lifeos",
        )))),
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
    });

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

    // Start background tasks
    let health_handle = tokio::spawn(run_health_checks(state.clone()));
    let update_handle = tokio::spawn(run_update_checks(state.clone()));
    let metrics_handle = tokio::spawn(run_metrics_collection(state.clone()));

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
        experience_manager: state.experience_manager.clone(),
        update_scheduler: state.update_scheduler.clone(),
        follow_along_manager: state.follow_along_manager.clone(),
        context_policies_manager: state.context_policies_manager.clone(),
        telemetry_manager: state.telemetry_manager.clone(),
        agent_runtime_manager: state.agent_runtime_manager.clone(),
        memory_plane_manager: state.memory_plane_manager.clone(),
        visual_comfort_manager: state.visual_comfort_manager.clone(),
        lab_manager: state.lab_manager.clone(),
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
    let config_path = std::path::PathBuf::from("/etc/lifeos/daemon.toml");

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
    #[serde(default)]
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
