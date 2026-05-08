//! LifeOS Desktop Companion — system tray + wake-word relay.
//!
//! This binary runs under the user's `graphical-session.target`. It:
//!   1. Acquires a bootstrap token from the daemon's UDS handout socket.
//!   2. Probes `/api/v1/health` until the daemon is ready.
//!   3. Spawns a ksni system-tray icon (feature = "tray", default enabled).
//!   4. Spawns a 30s polling loop that pushes daemon status into the tray.
//!   5. Optionally runs a rustpotter wake-word listener that POSTs detections
//!      to `/api/v1/sensory/wake-word/trigger` (feature = "wake-word").
//!
//! On SIGTERM / SIGINT: cancel token fires → all tasks exit cleanly → exit 0.

use anyhow::{anyhow, Result};
use std::time::Duration;
use tokio_util::sync::CancellationToken;

pub mod bootstrap;
pub mod daemon_client;
pub mod supervisor;
#[cfg(feature = "tray")]
pub mod tray;
#[cfg(feature = "wake-word")]
pub mod wake_word;

/// Default poll interval for daemon status updates.
pub const DEFAULT_POLL_INTERVAL: Duration = Duration::from_secs(30);

/// Default base URL for the daemon API.
pub const DEFAULT_DAEMON_BASE: &str = "http://127.0.0.1:8081";

/// Default path for the dashboard (opened by tray menu).
pub const DEFAULT_DASHBOARD_URL: &str = "http://127.0.0.1:8081/dashboard";

/// Default path for the daemon bootstrap handout socket.
pub const DEFAULT_HANDOUT_SOCKET: &str = "/run/lifeos/lifeos-bootstrap.sock";

#[tokio::main]
async fn main() -> Result<()> {
    // ── Version / help (before any I/O) ──────────────────────────────────────
    if let Some(first_arg) = std::env::args().nth(1) {
        match first_arg.as_str() {
            "--version" | "-V" => {
                println!("lifeos-desktop {}", env!("CARGO_PKG_VERSION"));
                return Ok(());
            }
            "--help" | "-h" => {
                println!(
                    "lifeos-desktop {}\n\
                     LifeOS desktop companion — system tray + wake-word relay\n\
                     \n\
                     USAGE: lifeos-desktop [OPTIONS]\n\
                     \n\
                     OPTIONS:\n  \
                       --version    Print version\n  \
                       --help       Print this help\n\
                     \n\
                     ENVIRONMENT:\n  \
                       LIFEOS_HANDOUT_SOCKET    Bootstrap socket path (default: {})\n  \
                       LIFEOS_DESKTOP_POLL_SECS Poll interval in seconds (default: 30, clamp: 2-300)\n  \
                       LIFEOS_DASHBOARD_URL     Dashboard URL to open (default: {})\n  \
                       RUST_LOG                 Log level (default: info)\n",
                    env!("CARGO_PKG_VERSION"),
                    DEFAULT_HANDOUT_SOCKET,
                    DEFAULT_DASHBOARD_URL
                );
                return Ok(());
            }
            other => {
                return Err(anyhow!("Unknown argument: {} (run with --help)", other));
            }
        }
    }

    // ── Logging ───────────────────────────────────────────────────────────────
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    log::info!(
        "[desktop] lifeos-desktop {} starting",
        env!("CARGO_PKG_VERSION")
    );

    // ── Run ───────────────────────────────────────────────────────────────────
    run().await
}

/// Main runtime: bootstrap → spawn surfaces → wait for signal.
pub async fn run() -> Result<()> {
    use crate::daemon_client::DaemonClient;
    use crate::supervisor::Supervisor;

    // ── Env config ────────────────────────────────────────────────────────────
    let socket_path = std::env::var("LIFEOS_HANDOUT_SOCKET")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from(DEFAULT_HANDOUT_SOCKET));

    let poll_interval = parse_poll_secs();

    let dashboard_url =
        std::env::var("LIFEOS_DASHBOARD_URL").unwrap_or_else(|_| DEFAULT_DASHBOARD_URL.to_string());

    let daemon_base = DEFAULT_DAEMON_BASE.to_string();

    // ── State A: wait for socket ───────────────────────────────────────────────
    bootstrap::wait_for_socket(&socket_path, Duration::from_secs(30)).await?;

    // ── State B: read bootstrap token ─────────────────────────────────────────
    let token = bootstrap::read_bootstrap_token(&socket_path).await?;
    log::info!("[desktop] bootstrap token acquired");

    // ── State C: probe health ─────────────────────────────────────────────────
    let client = DaemonClient::new(daemon_base, token)?;
    bootstrap::probe_health_until_ready(&client, Duration::from_secs(30)).await?;
    log::info!("[desktop] daemon healthy — spawning surfaces");

    // ── State D: spawn supervisor ─────────────────────────────────────────────
    let cancel = CancellationToken::new();
    let mut supervisor = Supervisor::new(cancel.clone());

    // Status watch channel: poll loop → tray
    #[cfg(feature = "tray")]
    let (status_tx, status_rx) = tokio::sync::watch::channel(tray::TrayState::default());

    // Spawn tray (feature = "tray")
    #[cfg(feature = "tray")]
    {
        let client_clone = client.clone();
        supervisor.spawn(
            "tray",
            tray::run(
                status_rx,
                client_clone,
                dashboard_url.clone(),
                cancel.clone(),
            ),
        );
    }

    // Spawn poll loop
    #[cfg(feature = "tray")]
    supervisor.spawn(
        "poll",
        poll_loop(
            client.clone(),
            status_tx.clone(),
            poll_interval,
            cancel.clone(),
        ),
    );

    #[cfg(not(feature = "tray"))]
    supervisor.spawn(
        "poll",
        poll_loop_no_tray(client.clone(), poll_interval, cancel.clone()),
    );

    // Spawn wake-word listener (feature = "wake-word")
    #[cfg(feature = "wake-word")]
    {
        let client_clone = client.clone();
        supervisor.spawn("wake-word", wake_word::run(client_clone, cancel.clone()));
    }

    // ── State E: wait for signal ──────────────────────────────────────────────
    supervisor.run_until_signal().await;

    log::info!("[desktop] shutdown complete");
    Ok(())
}

/// Polling loop: every `interval`, fetch system_status + ai_status.
/// When the "tray" feature is enabled, pushes updates into the watch channel.
async fn poll_loop(
    client: daemon_client::DaemonClient,
    #[cfg(feature = "tray")] status_tx: tokio::sync::watch::Sender<tray::TrayState>,
    interval: Duration,
    cancel: CancellationToken,
) {
    let mut ticker = tokio::time::interval(interval);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = cancel.cancelled() => {
                log::debug!("[desktop] poll loop cancelled");
                break;
            }
            _ = ticker.tick() => {
                // Fetch status in parallel (types inferred from DaemonClient methods)
                let sys_fut = client.system_status();
                let ai_fut = client.ai_status();
                let (sys_res, ai_res) = tokio::join!(sys_fut, ai_fut);

                match (sys_res, ai_res) {
                    (Ok(sys), Ok(ai)) => {
                        log::debug!(
                            "[desktop] poll ok version={} model={:?}",
                            sys.version,
                            ai.active_model
                        );
                        #[cfg(feature = "tray")]
                        {
                            let state = tray::TrayState {
                                version: sys.version,
                                active_model: ai.active_model.unwrap_or_default(),
                                ai_running: ai.running,
                            };
                            let _ = status_tx.send(state);
                        }
                        #[cfg(not(feature = "tray"))]
                        {
                            let _ = sys; // suppress unused warning
                            let _ = ai;
                        }
                    }
                    (Err(e), _) | (_, Err(e)) => {
                        log::warn!("[desktop] poll error: {}", e);
                    }
                }
            }
        }
    }
}

/// Poll loop when tray feature is disabled — just polls for log output.
#[cfg(not(feature = "tray"))]
async fn poll_loop_no_tray(
    client: daemon_client::DaemonClient,
    interval: Duration,
    cancel: CancellationToken,
) {
    let mut ticker = tokio::time::interval(interval);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = cancel.cancelled() => break,
            _ = ticker.tick() => {
                match client.system_status().await {
                    Ok(sys) => log::debug!("[desktop] poll ok version={}", sys.version),
                    Err(e) => log::warn!("[desktop] poll error: {}", e),
                }
            }
        }
    }
}

/// Parse `LIFEOS_DESKTOP_POLL_SECS` env var, clamping to 2-300s.
fn parse_poll_secs() -> Duration {
    let secs = std::env::var("LIFEOS_DESKTOP_POLL_SECS")
        .ok()
        .and_then(|v| {
            v.parse::<u64>().map_err(|e| {
                log::warn!(
                    "[desktop] LIFEOS_DESKTOP_POLL_SECS='{}' is not a valid u64: {} — using default {}s",
                    v,
                    e,
                    DEFAULT_POLL_INTERVAL.as_secs()
                );
                e
            }).ok()
        })
        .unwrap_or(DEFAULT_POLL_INTERVAL.as_secs());

    let clamped = secs.clamp(2, 300);
    if clamped != secs {
        log::warn!(
            "[desktop] LIFEOS_DESKTOP_POLL_SECS={} clamped to {}",
            secs,
            clamped
        );
    }
    Duration::from_secs(clamped)
}
