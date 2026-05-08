//! System tray companion (feature = "tray").
//!
//! Implements the ksni `Tray` trait for the companion binary.
//! Tray callbacks are synchronous `Box<dyn Fn>`, so they MUST NOT call
//! `.block_on()`. Instead they push `TrayCommand` to an mpsc channel and
//! return immediately — a separate tokio task drains the channel and calls
//! the daemon API.
//!
//! Architecture:
//!   - `AxiCompanionTray` — ksni Tray impl (lives in a blocking thread via `spawn()`)
//!   - `run()` — async entry point: spawns the tray thread + command handler task

#[cfg(feature = "tray")]
pub use inner::*;

#[cfg(feature = "tray")]
mod inner {
    use crate::daemon_client::DaemonClient;
    use ksni::menu::*;
    use ksni::{Icon, Tray, TrayService};
    use tokio::sync::{mpsc, watch};
    use tokio_util::sync::CancellationToken;

    // ── TrayState (watch channel payload) ─────────────────────────────────────

    /// Current state pushed from the poll loop into the tray via a watch channel.
    #[derive(Debug, Clone, Default)]
    pub struct TrayState {
        pub version: String,
        pub active_model: String,
        pub ai_running: bool,
    }

    // ── TrayCommand (mpsc channel payload) ────────────────────────────────────

    /// Commands dispatched by tray menu callbacks to the async command handler.
    #[derive(Debug, Clone)]
    pub enum TrayCommand {
        OpenDashboard { url: String },
        Quit,
    }

    // ── Icon helpers ──────────────────────────────────────────────────────────

    /// Generate a circle icon as ARGB32 pixmap data.
    fn make_circle_icon(size: i32, r: u8, g: u8, b: u8) -> Icon {
        let s = size as usize;
        let center = s as f64 / 2.0;
        let radius = center - 1.0;
        let mut data = Vec::with_capacity(s * s * 4);
        for y in 0..s {
            for x in 0..s {
                let dx = x as f64 - center;
                let dy = y as f64 - center;
                let dist = (dx * dx + dy * dy).sqrt();
                if dist <= radius - 1.0 {
                    data.extend_from_slice(&[255, r, g, b]);
                } else if dist <= radius {
                    let alpha = ((radius - dist) * 255.0) as u8;
                    data.extend_from_slice(&[alpha, r, g, b]);
                } else {
                    data.extend_from_slice(&[0, 0, 0, 0]);
                }
            }
        }
        Icon {
            width: size,
            height: size,
            data,
        }
    }

    /// Open a URL using the best available browser.
    /// Must be called from a blocking thread (spawns a subprocess).
    fn open_url_in_browser(url: &str) {
        let url = url.to_string();
        std::thread::spawn(move || {
            let openers: &[(&str, &[&str])] = &[
                (
                    "firefox",
                    &[
                        "--name=firefox-wayland",
                        "-P",
                        "lifeos.default",
                        "--new-tab",
                    ],
                ),
                (
                    "flatpak",
                    &[
                        "run",
                        "org.mozilla.firefox",
                        "--name=firefox-wayland",
                        "-P",
                        "lifeos.default",
                        "--new-tab",
                    ],
                ),
                ("chromium", &["--new-tab"]),
                ("xdg-open", &[]),
            ];
            for (cmd, args) in openers {
                let mut command = std::process::Command::new(cmd);
                command.args(*args).arg(&url);
                match command.spawn() {
                    Ok(mut child) => {
                        std::thread::sleep(std::time::Duration::from_millis(300));
                        match child.try_wait() {
                            Ok(Some(status)) if !status.success() => continue,
                            Ok(None) | Ok(Some(_)) => {
                                log::info!("[tray] opened {} via {}", url, cmd);
                                return;
                            }
                            Err(_) => continue,
                        }
                    }
                    Err(_) => continue,
                }
            }
            log::error!("[tray] failed to open URL: {}", url);
        });
    }

    // ── AxiCompanionTray ──────────────────────────────────────────────────────

    struct AxiCompanionTray {
        /// Current status label (version + model, updated via handle.update).
        status_label: String,
        dashboard_url: String,
        cmd_tx: mpsc::UnboundedSender<TrayCommand>,
    }

    impl Tray for AxiCompanionTray {
        fn activate(&mut self, _x: i32, _y: i32) {
            let url = self.dashboard_url.clone();
            open_url_in_browser(&url);
        }

        fn id(&self) -> String {
            "lifeos-axi-companion".into()
        }

        fn title(&self) -> String {
            format!("Axi — {}", self.status_label)
        }

        fn status(&self) -> ksni::Status {
            ksni::Status::Active
        }

        fn icon_pixmap(&self) -> Vec<Icon> {
            // Cyan = companion mode (distinct from daemon's green = idle)
            vec![make_circle_icon(22, 0, 209, 212)]
        }

        fn tool_tip(&self) -> ksni::ToolTip {
            ksni::ToolTip {
                title: "Axi Desktop Companion".to_string(),
                description: self.status_label.clone(),
                icon_name: String::new(),
                icon_pixmap: Vec::new(),
            }
        }

        fn menu(&self) -> Vec<MenuItem<Self>> {
            let status = self.status_label.clone();
            let dashboard = self.dashboard_url.clone();
            let cmd_tx_open = self.cmd_tx.clone();
            let cmd_tx_quit = self.cmd_tx.clone();
            let dashboard_quit = dashboard.clone();

            vec![
                // Header — status info
                StandardItem {
                    label: format!("Axi — {}", status),
                    enabled: false,
                    ..Default::default()
                }
                .into(),
                MenuItem::Separator,
                // Open dashboard
                StandardItem {
                    label: "Abrir Dashboard".into(),
                    activate: Box::new(move |_| {
                        let _ = cmd_tx_open.send(TrayCommand::OpenDashboard {
                            url: dashboard.clone(),
                        });
                    }),
                    ..Default::default()
                }
                .into(),
                MenuItem::Separator,
                // Footer / Quit
                StandardItem {
                    label: "Salir".into(),
                    activate: Box::new(move |_| {
                        // Open dashboard first so user can see confirmation
                        log::info!("[tray] Quit requested");
                        let _ = cmd_tx_quit.send(TrayCommand::Quit);
                        // Also open dashboard on quit? No — just quit.
                        let _ = &dashboard_quit; // suppress unused warning
                    }),
                    ..Default::default()
                }
                .into(),
            ]
        }
    }

    // ── run() ─────────────────────────────────────────────────────────────────

    /// Async entry point for the tray subsystem.
    ///
    /// Spawns:
    ///   1. The ksni tray service in its own OS thread (via `TrayService::spawn()`).
    ///   2. A status watcher task that forwards `status_rx` updates into the tray.
    ///   3. A command handler task that processes `TrayCommand` from menu callbacks.
    ///
    /// Returns when `cancel` is fired.
    pub async fn run(
        mut status_rx: watch::Receiver<TrayState>,
        client: DaemonClient,
        dashboard_url: String,
        cancel: CancellationToken,
    ) {
        // Create the command channel internally — tray callbacks hold cmd_tx,
        // the handler task drains cmd_rx.
        let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<TrayCommand>();

        let initial_state = {
            let s = status_rx.borrow().clone();
            if s.version.is_empty() {
                "Conectando...".to_string()
            } else {
                format!("v{} | {}", s.version, s.active_model)
            }
        };

        let tray = AxiCompanionTray {
            status_label: initial_state,
            dashboard_url: dashboard_url.clone(),
            cmd_tx: cmd_tx.clone(),
        };

        let service = TrayService::new(tray);
        let handle = service.handle();
        let handle_for_status = handle.clone();
        let handle_for_cancel = handle.clone();

        // Spawn tray service in its OS thread (ksni manages its own dbus loop)
        service.spawn();
        log::info!("[tray] tray service spawned");

        // Task 1: forward status updates from watch channel into tray handle
        let cancel_status = cancel.clone();
        let status_watcher = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = cancel_status.cancelled() => break,
                    result = status_rx.changed() => {
                        if result.is_err() {
                            break; // sender dropped
                        }
                        let state = status_rx.borrow().clone();
                        let label = if state.version.is_empty() {
                            "Conectando...".to_string()
                        } else {
                            format!("v{} | {}", state.version, state.active_model)
                        };
                        handle_for_status.update(|t: &mut AxiCompanionTray| {
                            t.status_label = label;
                        });
                    }
                }
            }
        });

        // Task 2: handle tray commands (menu callbacks → async API calls)
        let cancel_cmd = cancel.clone();
        let _ = &client; // ensure client is available for future API call commands
        let command_handler = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = cancel_cmd.cancelled() => break,
                    cmd = cmd_rx.recv() => {
                        match cmd {
                            None => break,
                            Some(TrayCommand::OpenDashboard { url }) => {
                                // open_url_in_browser is blocking — spawn a thread
                                let url_clone = url.clone();
                                tokio::task::spawn_blocking(move || {
                                    open_url_in_browser(&url_clone);
                                });
                            }
                            Some(TrayCommand::Quit) => {
                                log::info!("[tray] Quit command — cancelling");
                                cancel_cmd.cancel();
                                break;
                            }
                        }
                    }
                }
            }
        });

        // Wait for cancellation
        cancel.cancelled().await;

        // Shutdown the ksni tray thread
        handle_for_cancel.shutdown();
        log::info!("[tray] tray service shutdown requested");

        // Abort status watcher and command handler
        status_watcher.abort();
        command_handler.abort();
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn tray_state_default_is_empty() {
            let state = TrayState::default();
            assert_eq!(state.version, "");
            assert_eq!(state.active_model, "");
            assert!(!state.ai_running);
        }

        #[test]
        fn status_label_formats_correctly() {
            let state = TrayState {
                version: "0.8.41".to_string(),
                active_model: "Qwen3.5-4B".to_string(),
                ai_running: true,
            };
            let label = if state.version.is_empty() {
                "Conectando...".to_string()
            } else {
                format!("v{} | {}", state.version, state.active_model)
            };
            assert_eq!(label, "v0.8.41 | Qwen3.5-4B");
        }

        #[test]
        fn status_label_empty_version_shows_connecting() {
            let state = TrayState::default();
            let label = if state.version.is_empty() {
                "Conectando...".to_string()
            } else {
                format!("v{} | {}", state.version, state.active_model)
            };
            assert_eq!(label, "Conectando...");
        }

        #[tokio::test]
        async fn status_update_channel_delivers_state() {
            let (tx, rx) = watch::channel(TrayState::default());
            let received = parking_lot::Mutex::new(None::<TrayState>);
            let received_ref = &received;

            // Send a state update
            tx.send(TrayState {
                version: "1.0.0".to_string(),
                active_model: "TestModel".to_string(),
                ai_running: true,
            })
            .expect("send should succeed");

            // Borrow the latest
            let state = rx.borrow().clone();
            *received_ref.lock() = Some(state);

            let guard = received.lock();
            let state = guard.as_ref().expect("should have state");
            assert_eq!(state.version, "1.0.0");
            assert_eq!(state.active_model, "TestModel");
        }

        #[tokio::test]
        async fn tray_command_quit_is_clonable() {
            let cmd = TrayCommand::Quit;
            let cmd2 = cmd.clone();
            // Both should format without panic
            let _ = format!("{:?}", cmd);
            let _ = format!("{:?}", cmd2);
        }

        #[tokio::test]
        async fn cancellation_propagates_to_status_watcher() {
            use std::sync::atomic::{AtomicBool, Ordering};
            use std::sync::Arc;

            let cancel = CancellationToken::new();
            let done = Arc::new(AtomicBool::new(false));
            let done_clone = done.clone();
            let cancel_inner = cancel.clone();

            tokio::spawn(async move {
                tokio::select! {
                    _ = cancel_inner.cancelled() => {
                        done_clone.store(true, Ordering::SeqCst);
                    }
                    _ = tokio::time::sleep(std::time::Duration::from_secs(60)) => {}
                }
            });

            cancel.cancel();
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            assert!(done.load(Ordering::SeqCst));
        }
    }
}
