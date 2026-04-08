//! Axi System Tray — StatusNotifierItem icon in the desktop panel.
//!
//! Shows Axi as an icon in the system tray (top panel) with:
//! - Color-changing icon based on Axi state (green=idle, cyan=listening, etc.)
//! - Right-click menu with status info, sensor toggles, dashboard link
//! - Sensor controls: always-on, mic, TTS, camera, screen capture, kill switch
//!
//! Uses the freedesktop StatusNotifierItem protocol via `ksni` crate.
//! Works with COSMIC, KDE Plasma, GNOME (with AppIndicator extension).

#[cfg(feature = "tray")]
pub mod inner {
    use ksni::menu::*;
    use ksni::{Icon, Tray, TrayService};
    use log::info;
    use tokio::sync::broadcast;

    use crate::events::DaemonEvent;

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

    fn state_to_rgb(state: &str) -> (u8, u8, u8) {
        match state.to_lowercase().as_str() {
            "idle" => (46, 214, 115),
            "listening" => (0, 209, 212),
            "thinking" => (255, 166, 3),
            "speaking" => (56, 66, 250),
            "watching" => (26, 189, 156),
            "error" => (255, 71, 87),
            "offline" => (100, 110, 115),
            "night" => (95, 38, 204),
            _ => (46, 214, 115),
        }
    }

    fn state_to_label(state: &str) -> &str {
        match state.to_lowercase().as_str() {
            "idle" => "En espera",
            "listening" => "Escuchando",
            "thinking" => "Pensando",
            "speaking" => "Hablando",
            "watching" => "Observando",
            "error" => "Atencion",
            "offline" => "Desconectado",
            "night" => "Modo nocturno",
            _ => "Axi",
        }
    }

    /// Call the daemon API to toggle a sensor. Uses curl to avoid reqwest::blocking dependency.
    fn call_api(api_base: &str, token: &str, endpoint: &str, body: serde_json::Value) {
        let url = format!("{}/api/v1{}", api_base, endpoint);
        let token = token.to_string();
        let body_str = serde_json::to_string(&body).unwrap_or_default();
        std::thread::spawn(move || {
            std::process::Command::new("curl")
                .args([
                    "-sS",
                    "-X",
                    "POST",
                    "-H",
                    "Content-Type: application/json",
                    "-H",
                    &format!("x-bootstrap-token: {}", token),
                    "-d",
                    &body_str,
                    &url,
                ])
                .output()
                .ok();
        });
    }

    pub struct AxiTray {
        state: String,
        mic: bool,
        camera: bool,
        screen: bool,
        always_on: bool,
        tts: bool,
        kill_switch: bool,
        dashboard_url: String,
        api_base: String,
        api_token: String,
    }

    impl Tray for AxiTray {
        fn id(&self) -> String {
            "lifeos-axi".into()
        }

        fn title(&self) -> String {
            format!("Axi — {}", state_to_label(&self.state))
        }

        fn status(&self) -> ksni::Status {
            if self.kill_switch {
                return ksni::Status::Passive;
            }
            match self.state.as_str() {
                "error" => ksni::Status::NeedsAttention,
                "offline" => ksni::Status::Passive,
                _ => ksni::Status::Active,
            }
        }

        fn icon_pixmap(&self) -> Vec<Icon> {
            if self.kill_switch {
                return vec![make_circle_icon(22, 100, 110, 115)]; // gray when killed
            }
            let (r, g, b) = state_to_rgb(&self.state);
            vec![make_circle_icon(22, r, g, b)]
        }

        fn attention_icon_pixmap(&self) -> Vec<Icon> {
            vec![make_circle_icon(22, 255, 71, 87)]
        }

        fn tool_tip(&self) -> ksni::ToolTip {
            let sensors = format!(
                "Mic: {} | Cam: {} | Pantalla: {} | Always-On: {} | Habla: {} | Kill: {}",
                if self.mic { "ON" } else { "off" },
                if self.camera { "ON" } else { "off" },
                if self.screen { "ON" } else { "off" },
                if self.always_on { "ON" } else { "off" },
                if self.tts { "ON" } else { "off" },
                if self.kill_switch { "ACTIVO" } else { "off" },
            );
            ksni::ToolTip {
                title: format!("Axi — {}", state_to_label(&self.state)),
                description: sensors,
                icon_name: String::new(),
                icon_pixmap: Vec::new(),
            }
        }

        fn menu(&self) -> Vec<MenuItem<Self>> {
            let state_label = state_to_label(&self.state);
            let dashboard = self.dashboard_url.clone();

            // Clone API info for each closure that needs it
            let api_ao = self.api_base.clone();
            let tok_ao = self.api_token.clone();
            let api_mic = self.api_base.clone();
            let tok_mic = self.api_token.clone();
            let api_tts = self.api_base.clone();
            let tok_tts = self.api_token.clone();
            let api_cam = self.api_base.clone();
            let tok_cam = self.api_token.clone();
            let api_scr = self.api_base.clone();
            let tok_scr = self.api_token.clone();
            let api_ks = self.api_base.clone();
            let tok_ks = self.api_token.clone();

            let mut items: Vec<MenuItem<Self>> = vec![
                // ---- Header ----
                StandardItem {
                    label: format!("AXI — {}", state_label),
                    enabled: false,
                    ..Default::default()
                }
                .into(),
                MenuItem::Separator,
                // ---- Dashboard ----
                StandardItem {
                    label: "Abrir Dashboard".into(),
                    activate: Box::new(move |_| {
                        let url = dashboard.clone();
                        std::thread::spawn(move || {
                            // Try multiple browser openers in order.
                            // xdg-open often fails silently in COSMIC DE without
                            // proper portal configuration, so we try direct browsers
                            // as fallback.
                            let openers: &[(&str, &[&str])] = &[
                                ("xdg-open", &[]),
                                ("gio", &["open"]),
                                ("firefox", &["--new-tab"]),
                                ("flatpak", &["run", "org.mozilla.firefox", "--new-tab"]),
                                ("chromium", &["--new-tab"]),
                                ("flatpak", &["run", "org.chromium.Chromium", "--new-tab"]),
                                (
                                    "flatpak",
                                    &[
                                        "run",
                                        "io.github.ungoogled_software.ungoogled_chromium",
                                        "--new-tab",
                                    ],
                                ),
                            ];
                            for (cmd, args) in openers {
                                let mut command = std::process::Command::new(cmd);
                                command.args(*args).arg(&url);
                                if let Ok(mut child) = command.spawn() {
                                    // Give the command a moment to fail fast
                                    std::thread::sleep(std::time::Duration::from_millis(300));
                                    match child.try_wait() {
                                        Ok(Some(status)) if status.success() => return,
                                        Ok(Some(_)) => continue, // Failed, try next
                                        Ok(None) => return,      // Still running = success
                                        Err(_) => continue,
                                    }
                                }
                            }
                            log::warn!(
                                "[tray] Failed to open dashboard — no browser opener worked"
                            );
                        });
                    }),
                    ..Default::default()
                }
                .into(),
                MenuItem::Separator,
                // ---- Sentidos ----
                StandardItem {
                    label: "Sentidos".into(),
                    enabled: false,
                    ..Default::default()
                }
                .into(),
            ];

            // Always-On (wake word listening)
            items.push(
                CheckmarkItem {
                    label: "Always-On (escucha activa)".into(),
                    checked: self.always_on,
                    activate: Box::new(move |this: &mut Self| {
                        this.always_on = !this.always_on;
                        call_api(
                            &api_ao,
                            &tok_ao,
                            "/runtime/always-on",
                            serde_json::json!({"enabled": this.always_on}),
                        );
                    }),
                    ..Default::default()
                }
                .into(),
            );

            // Mic toggle — only send the changed field
            items.push(
                CheckmarkItem {
                    label: "Microfono".into(),
                    checked: self.mic,
                    activate: Box::new(move |this: &mut Self| {
                        this.mic = !this.mic;
                        call_api(
                            &api_mic,
                            &tok_mic,
                            "/runtime/sensory",
                            serde_json::json!({
                                "audio_enabled": this.mic
                            }),
                        );
                    }),
                    ..Default::default()
                }
                .into(),
            );

            // TTS / Habla — toggle TTS output
            items.push(
                CheckmarkItem {
                    label: "Habla (voz por bocinas)".into(),
                    checked: self.tts,
                    activate: Box::new(move |this: &mut Self| {
                        this.tts = !this.tts;
                        call_api(
                            &api_tts,
                            &tok_tts,
                            "/runtime/sensory",
                            serde_json::json!({
                                "tts_enabled": this.tts
                            }),
                        );
                    }),
                    ..Default::default()
                }
                .into(),
            );

            // Camera toggle — syncs with dashboard via /runtime/sensory
            items.push(
                CheckmarkItem {
                    label: "Camara".into(),
                    checked: self.camera,
                    activate: Box::new(move |this: &mut Self| {
                        this.camera = !this.camera;
                        call_api(
                            &api_cam,
                            &tok_cam,
                            "/runtime/sensory",
                            serde_json::json!({
                                "camera_enabled": this.camera
                            }),
                        );
                    }),
                    ..Default::default()
                }
                .into(),
            );

            // Screen capture toggle — only send the changed field
            items.push(
                CheckmarkItem {
                    label: "Captura de pantalla".into(),
                    checked: self.screen,
                    activate: Box::new(move |this: &mut Self| {
                        this.screen = !this.screen;
                        call_api(
                            &api_scr,
                            &tok_scr,
                            "/runtime/sensory",
                            serde_json::json!({
                                "screen_enabled": this.screen
                            }),
                        );
                    }),
                    ..Default::default()
                }
                .into(),
            );

            items.push(MenuItem::Separator);

            // Kill switch — master toggle
            items.push(
                StandardItem {
                    label: if self.kill_switch {
                        "Reactivar todos los sentidos".into()
                    } else {
                        "DESACTIVAR todos los sentidos".into()
                    },
                    activate: Box::new(move |this: &mut Self| {
                        this.kill_switch = !this.kill_switch;
                        if this.kill_switch {
                            // Disable all senses
                            this.mic = false;
                            this.camera = false;
                            this.screen = false;
                            this.always_on = false;
                            this.tts = false;
                        } else {
                            // Re-enable all senses
                            this.mic = true;
                            this.camera = true;
                            this.screen = true;
                            this.always_on = true;
                            this.tts = true;
                        }
                        // API endpoint now toggles: activates or releases based on current state
                        call_api(
                            &api_ks,
                            &tok_ks,
                            "/sensory/kill-switch",
                            serde_json::json!({"actor": "tray-menu"}),
                        );
                    }),
                    ..Default::default()
                }
                .into(),
            );

            items.push(MenuItem::Separator);

            // Footer
            items.push(
                StandardItem {
                    label: "LifeOS AI Assistant".into(),
                    enabled: false,
                    ..Default::default()
                }
                .into(),
            );

            items
        }
    }

    /// Initial sensor state passed to the tray at spawn time.
    /// Read from AgentRuntimeManager (persisted to disk) so user toggles survive restarts.
    pub struct InitialSensorState {
        pub mic: bool,
        pub camera: bool,
        pub screen: bool,
        pub always_on: bool,
        pub tts: bool,
    }

    /// Spawn the system tray icon. Blocks until the tray exits.
    /// Must be called from a blocking context (e.g. `spawn_blocking`).
    pub async fn spawn_tray(
        mut event_rx: broadcast::Receiver<DaemonEvent>,
        dashboard_url: String,
        api_base: String,
        api_token: String,
        initial_state: String,
        sensors: InitialSensorState,
    ) {
        info!("[tray] Spawning Axi system tray icon");

        let tray = AxiTray {
            state: initial_state,
            mic: sensors.mic,
            camera: sensors.camera,
            screen: sensors.screen,
            always_on: sensors.always_on,
            tts: sensors.tts,
            kill_switch: false,
            dashboard_url,
            api_base,
            api_token,
        };

        let service = TrayService::new(tray);
        let handle = service.handle();

        // Listen for state and sensor updates
        tokio::spawn(async move {
            loop {
                match event_rx.recv().await {
                    Ok(DaemonEvent::AxiStateChanged { state, .. }) => {
                        handle.update(|tray: &mut AxiTray| {
                            tray.state = state.clone();
                        });
                    }
                    Ok(DaemonEvent::SensorChanged {
                        mic,
                        camera,
                        screen,
                        always_on,
                        tts,
                        kill_switch,
                    }) => {
                        handle.update(|tray: &mut AxiTray| {
                            tray.mic = mic;
                            tray.camera = camera;
                            tray.screen = screen;
                            if let Some(always_on) = always_on {
                                tray.always_on = always_on;
                            }
                            if let Some(tts) = tts {
                                tray.tts = tts;
                            }
                            tray.kill_switch = kill_switch;
                        });
                    }
                    Ok(_) => {}
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        log::warn!("[tray] Lagged {} events", n);
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });

        // run() blocks the current thread until the tray service exits.
        // We use spawn_blocking so we don't block the tokio runtime.
        info!("[tray] Axi tray icon active");
        let run_result = tokio::task::spawn_blocking(move || {
            if let Err(e) = service.run() {
                log::error!("[tray] Tray service error: {}", e);
            }
        })
        .await;

        if let Err(e) = run_result {
            log::error!("[tray] Tray service panicked: {}", e);
        }
        info!("[tray] Tray service exited");
    }
}

#[cfg(feature = "tray")]
pub use inner::*;
