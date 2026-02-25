//! LifeOS System Daemon (lifeosd)
//! 
//! Provides:
//! - System health monitoring
//! - Auto-update checks
//! - Health monitoring
//! - Notification system
//! - D-Bus interface for system integration
//! - REST API for mobile companion app

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;
use tokio::signal;
use log::{info, warn, error, debug};

mod system;
mod ai;
mod notifications;
mod health;
mod updates;
mod api;
mod models;
mod permissions;

use system::SystemMonitor;
use health::HealthMonitor;
use updates::UpdateChecker;
use notifications::NotificationManager;

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
            health_check_interval: Duration::from_secs(300),      // 5 minutes
            update_check_interval: Duration::from_secs(3600),     // 1 hour
            metrics_collection_interval: Duration::from_secs(60), // 1 minute
            enable_notifications: true,
            enable_auto_updates: false,
            enable_api: true,
            api_bind_address: "0.0.0.0:8080".parse().unwrap(),
        }
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
    pub last_health_check: RwLock<Option<chrono::DateTime<chrono::Local>>>,
    pub last_update_check: RwLock<Option<chrono::DateTime<chrono::Local>>>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Initialize logging
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
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

    // Initialize state
    let state = Arc::new(DaemonState {
        config: config.clone(),
        system_monitor: Arc::new(RwLock::new(SystemMonitor::new())),
        health_monitor: Arc::new(HealthMonitor::new()),
        update_checker: Arc::new(RwLock::new(UpdateChecker::new())),
        notification_manager: Arc::new(NotificationManager::new(config.enable_notifications)),
        ai_manager: Arc::new(RwLock::new(ai::AiManager::new())),
        last_health_check: RwLock::new(None),
        last_update_check: RwLock::new(None),
    });

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
        config: api::ApiConfig {
            bind_address: state.config.api_bind_address,
            api_key: None,
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
        
        let api_bind = config.api_bind_address.parse()
            .unwrap_or_else(|_| "0.0.0.0:8080".parse().unwrap());
        
        return Ok(DaemonConfig {
            health_check_interval: Duration::from_secs(config.health_check_interval_secs),
            update_check_interval: Duration::from_secs(config.update_check_interval_secs),
            metrics_collection_interval: Duration::from_secs(config.metrics_collection_interval_secs),
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

fn default_health_interval() -> u64 { 300 }
fn default_update_interval() -> u64 { 3600 }
fn default_metrics_interval() -> u64 { 60 }
fn default_true() -> bool { true }
fn default_api_bind() -> String { "0.0.0.0:8080".to_string() }

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
                    info!("Update available: {} -> {}", result.current_version, result.new_version);
                    
                    if let Err(e) = state.notification_manager.send_update_notification(&result.new_version
                    ).await {
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
                debug!("Collected metrics: CPU {:.1}%, Memory {:.1}%", 
                    metrics.cpu_usage, metrics.memory_usage);
                
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
                    if let Err(e) = state.notification_manager.send_disk_warning(
                        metrics.disk_usage
                    ).await {
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

