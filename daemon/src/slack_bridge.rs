//! Slack bridge — Bidirectional communication with LifeOS via Slack Bot API.
//!
//! Uses Socket Mode (WebSocket) to receive events without a public webhook.
//! Sends replies via `chat.postMessage` REST endpoint.
//!
//! Supports: text messages, push notifications, /do commands.

#[cfg(feature = "slack")]
mod inner {
    use log::{error, info, warn};
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::sync::RwLock;

    use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest, TaskComplexity};
    use crate::supervisor::SupervisorNotification;
    use crate::task_queue::{TaskCreate, TaskPriority, TaskQueue};

    // -----------------------------------------------------------------------
    // Config
    // -----------------------------------------------------------------------

    #[derive(Debug, Clone)]
    pub struct SlackConfig {
        /// Bot User OAuth Token (xoxb-...)
        pub bot_token: String,
        /// App-Level Token (xapp-...) for Socket Mode
        pub app_token: String,
        /// Channel IDs allowed to interact with the bridge
        pub allowed_channels: Vec<String>,
    }

    impl SlackConfig {
        pub fn from_env() -> Option<Self> {
            let bot_token = std::env::var("LIFEOS_SLACK_BOT_TOKEN")
                .ok()
                .filter(|s| !s.is_empty())?;
            let app_token = std::env::var("LIFEOS_SLACK_APP_TOKEN")
                .ok()
                .filter(|s| !s.is_empty())?;
            let allowed_channels: Vec<String> = std::env::var("LIFEOS_SLACK_ALLOWED_CHANNELS")
                .unwrap_or_default()
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            Some(Self {
                bot_token,
                app_token,
                allowed_channels,
            })
        }
    }

    // -----------------------------------------------------------------------
    // Public entry point
    // -----------------------------------------------------------------------

    pub async fn run_slack_bridge(
        config: SlackConfig,
        task_queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
        mut notify_rx: tokio::sync::broadcast::Receiver<SupervisorNotification>,
    ) {
        info!(
            "Starting Slack bridge ({} allowed channel(s))",
            config.allowed_channels.len()
        );

        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("Failed to build HTTP client for Slack bridge");

        let config = Arc::new(config);

        // ---- Notification forwarder ----
        {
            let notify_cfg = config.clone();
            let notify_http = http.clone();
            tokio::spawn(async move {
                loop {
                    match notify_rx.recv().await {
                        Ok(notification) => {
                            let text = format_notification(&notification);
                            for channel in &notify_cfg.allowed_channels {
                                if let Err(e) = send_slack_message(
                                    &notify_http,
                                    &notify_cfg.bot_token,
                                    channel,
                                    &text,
                                )
                                .await
                                {
                                    error!("Slack notification to {} failed: {}", channel, e);
                                }
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            warn!("Slack notifications lagged by {}", n);
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    }
                }
            });
        }

        // ---- Socket Mode loop ----
        // Obtain a WebSocket URL via apps.connections.open
        loop {
            let ws_url = match open_socket_mode_connection(&http, &config.app_token).await {
                Ok(url) => url,
                Err(e) => {
                    error!("Slack Socket Mode: failed to open connection: {}", e);
                    tokio::time::sleep(Duration::from_secs(10)).await;
                    continue;
                }
            };

            info!("Slack Socket Mode: connecting to WebSocket...");

            match run_socket_mode(&ws_url, &config, &http, &task_queue, &router).await {
                Ok(()) => {
                    info!("Slack Socket Mode: connection closed cleanly, reconnecting...");
                }
                Err(e) => {
                    error!("Slack Socket Mode error: {}", e);
                }
            }

            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    }

    // -----------------------------------------------------------------------
    // Socket Mode connection
    // -----------------------------------------------------------------------

    /// Call `apps.connections.open` to get a WebSocket URL for Socket Mode.
    async fn open_socket_mode_connection(
        http: &reqwest::Client,
        app_token: &str,
    ) -> Result<String, String> {
        let resp = http
            .post("https://slack.com/api/apps.connections.open")
            .bearer_auth(app_token)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .send()
            .await
            .map_err(|e| format!("HTTP error: {}", e))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(format!("apps.connections.open HTTP {}: {}", status, body));
        }

        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| format!("JSON parse error: {}", e))?;

        if body.get("ok").and_then(|v| v.as_bool()) != Some(true) {
            return Err(format!(
                "apps.connections.open failed: {}",
                body.get("error")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown")
            ));
        }

        body.get("url")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .ok_or_else(|| "apps.connections.open: missing 'url' field".to_string())
    }

    /// Run the Socket Mode WebSocket loop. Returns when the connection is closed.
    async fn run_socket_mode(
        ws_url: &str,
        config: &Arc<SlackConfig>,
        http: &reqwest::Client,
        task_queue: &Arc<TaskQueue>,
        router: &Arc<RwLock<LlmRouter>>,
    ) -> Result<(), String> {
        use tokio_tungstenite::connect_async;
        use tokio_tungstenite::tungstenite::Message;

        let (ws_stream, _) = connect_async(ws_url)
            .await
            .map_err(|e| format!("WebSocket connect error: {}", e))?;

        info!("Slack Socket Mode: connected");

        use futures_util::{SinkExt, StreamExt};
        let (mut write, mut read) = ws_stream.split();

        while let Some(msg_result) = read.next().await {
            let msg = match msg_result {
                Ok(m) => m,
                Err(e) => {
                    error!("Slack Socket Mode read error: {}", e);
                    break;
                }
            };

            let text = match msg {
                Message::Text(t) => t,
                Message::Ping(data) => {
                    let _ = write.send(Message::Pong(data)).await;
                    continue;
                }
                Message::Close(_) => {
                    info!("Slack Socket Mode: server sent close frame");
                    break;
                }
                _ => continue,
            };

            let envelope: serde_json::Value = match serde_json::from_str(&text) {
                Ok(v) => v,
                Err(e) => {
                    warn!("Slack Socket Mode: invalid JSON: {}", e);
                    continue;
                }
            };

            // Acknowledge the envelope immediately
            if let Some(envelope_id) = envelope.get("envelope_id").and_then(|v| v.as_str()) {
                let ack = serde_json::json!({ "envelope_id": envelope_id });
                if let Err(e) = write.send(Message::Text(ack.to_string().into())).await {
                    error!("Slack Socket Mode: failed to send ack: {}", e);
                }
            }

            // Process event
            let event_type = envelope.get("type").and_then(|v| v.as_str()).unwrap_or("");

            match event_type {
                "events_api" => {
                    if let Some(payload) = envelope.get("payload") {
                        let event = payload.get("event");
                        if let Some(event) = event {
                            let config_clone = config.clone();
                            let http_clone = http.clone();
                            let tq_clone = task_queue.clone();
                            let router_clone = router.clone();
                            let event_clone = event.clone();

                            tokio::spawn(async move {
                                handle_slack_event(
                                    &config_clone,
                                    &http_clone,
                                    &event_clone,
                                    &tq_clone,
                                    &router_clone,
                                )
                                .await;
                            });
                        }
                    }
                }
                "hello" => {
                    info!("Slack Socket Mode: received hello");
                }
                "disconnect" => {
                    info!("Slack Socket Mode: server requested disconnect, will reconnect");
                    break;
                }
                _ => {
                    // slash_commands, interactive, etc. — ignore for now
                }
            }
        }

        Ok(())
    }

    // -----------------------------------------------------------------------
    // Event handler
    // -----------------------------------------------------------------------

    async fn handle_slack_event(
        config: &SlackConfig,
        http: &reqwest::Client,
        event: &serde_json::Value,
        task_queue: &Arc<TaskQueue>,
        router: &Arc<RwLock<LlmRouter>>,
    ) {
        let event_type = event.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if event_type != "message" {
            return;
        }

        // Skip bot messages and message_changed subtypes
        if event.get("subtype").is_some() {
            return;
        }

        let channel = event
            .get("channel")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        let text = event
            .get("text")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .trim()
            .to_string();
        let _user = event
            .get("user")
            .and_then(|v| v.as_str())
            .unwrap_or_default();

        if text.is_empty() || channel.is_empty() {
            return;
        }

        // Auth check — reject channels not in the allow-list
        if !config.allowed_channels.is_empty()
            && !config.allowed_channels.contains(&channel.to_string())
        {
            warn!(
                "Slack: message from non-allowed channel {}; ignoring",
                channel
            );
            return;
        }

        info!("Slack [{}]: {}", channel, &text[..text.len().min(100)]);

        if text.starts_with("/do ") || text.starts_with("/task ") {
            let objective = text
                .strip_prefix("/do ")
                .or_else(|| text.strip_prefix("/task "))
                .unwrap_or(&text)
                .to_string();
            handle_task(config, http, channel, objective, task_queue).await;
        } else if text.starts_with("/status") {
            handle_status(config, http, channel, task_queue).await;
        } else if text.starts_with("/help") || text == "/start" {
            handle_help(config, http, channel).await;
        } else {
            handle_chat(config, http, channel, &text, router).await;
        }
    }

    // -----------------------------------------------------------------------
    // Command handlers
    // -----------------------------------------------------------------------

    async fn handle_task(
        config: &SlackConfig,
        http: &reqwest::Client,
        channel: &str,
        objective: String,
        task_queue: &Arc<TaskQueue>,
    ) {
        match task_queue.enqueue(TaskCreate {
            objective: objective.clone(),
            priority: TaskPriority::Normal,
            source: "slack".into(),
            max_attempts: 3,
        }) {
            Ok(task) => {
                let reply = format!(
                    "Tarea creada:\n{}\n\nID: {}\nTe avisare cuando termine.",
                    objective, task.id
                );
                if let Err(e) = send_slack_message(http, &config.bot_token, channel, &reply).await {
                    error!(
                        "Slack: failed to confirm task creation in {}: {}",
                        channel, e
                    );
                }
            }
            Err(e) => {
                let reply = format!("Error al crear tarea: {}", e);
                let _ = send_slack_message(http, &config.bot_token, channel, &reply).await;
            }
        }
    }

    async fn handle_status(
        config: &SlackConfig,
        http: &reqwest::Client,
        channel: &str,
        task_queue: &Arc<TaskQueue>,
    ) {
        let summary = task_queue.summary().unwrap_or_default();
        let recent = task_queue.list(None, 5).unwrap_or_default();
        let mut reply = format!(
            "Estado de LifeOS:\n```{}```",
            serde_json::to_string_pretty(&summary).unwrap_or_else(|_| "{}".into())
        );
        if !recent.is_empty() {
            reply.push_str("\n\nUltimas tareas:");
            for t in &recent {
                reply.push_str(&format!(
                    "\n- [{}] {}",
                    serde_json::to_value(t.status)
                        .unwrap_or_default()
                        .as_str()
                        .unwrap_or("?"),
                    &t.objective[..t.objective.len().min(60)],
                ));
            }
        }
        if let Err(e) = send_slack_message(http, &config.bot_token, channel, &reply).await {
            error!("Slack: failed to send status in {}: {}", channel, e);
        }
    }

    async fn handle_help(config: &SlackConfig, http: &reqwest::Client, channel: &str) {
        let help = "Soy Axi, tu asistente de LifeOS via Slack.\n\n\
             Comandos:\n\
             `/do <tarea>` — Crear tarea para el supervisor\n\
             `/task <tarea>` — Igual que /do\n\
             `/status` — Ver estado de tareas\n\
             `/help` — Este mensaje\n\n\
             Tambien puedes enviar texto y te respondo con IA.\n\
             Las notificaciones de tareas llegan automaticamente a este canal.";
        if let Err(e) = send_slack_message(http, &config.bot_token, channel, help).await {
            error!("Slack: failed to send help in {}: {}", channel, e);
        }
    }

    async fn handle_chat(
        config: &SlackConfig,
        http: &reqwest::Client,
        channel: &str,
        text: &str,
        router: &Arc<RwLock<LlmRouter>>,
    ) {
        let reply = chat_with_llm(router, text).await;
        for chunk in split_message(&reply, 3000) {
            if let Err(e) = send_slack_message(http, &config.bot_token, channel, chunk).await {
                error!("Slack: failed to send chat reply in {}: {}", channel, e);
                break;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Slack API helpers
    // -----------------------------------------------------------------------

    /// Send a text message via Slack's `chat.postMessage` API.
    pub async fn send_slack_message(
        http: &reqwest::Client,
        bot_token: &str,
        channel: &str,
        text: &str,
    ) -> Result<(), String> {
        let body = serde_json::json!({
            "channel": channel,
            "text": text,
        });

        let resp = http
            .post("https://slack.com/api/chat.postMessage")
            .bearer_auth(bot_token)
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("HTTP error: {}", e))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(format!("Slack API HTTP {}: {}", status, body));
        }

        let result: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| format!("JSON parse error: {}", e))?;

        if result.get("ok").and_then(|v| v.as_bool()) != Some(true) {
            return Err(format!(
                "Slack API error: {}",
                result
                    .get("error")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown")
            ));
        }

        Ok(())
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    async fn chat_with_llm(router: &Arc<RwLock<LlmRouter>>, text: &str) -> String {
        let request = RouterRequest {
            messages: vec![
                ChatMessage {
                    role: "system".into(),
                    content: serde_json::Value::String(
                        "Eres Axi, el asistente AI de LifeOS. Responde conciso y util en español."
                            .into(),
                    ),
                },
                ChatMessage {
                    role: "user".into(),
                    content: serde_json::Value::String(text.into()),
                },
            ],
            complexity: Some(TaskComplexity::Medium),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(1024),
        };

        let r = router.read().await;
        match r.chat(&request).await {
            Ok(resp) => format!("{}\n\n[{}]", resp.text, resp.provider),
            Err(e) => format!("Error: {}", e),
        }
    }

    fn format_notification(n: &SupervisorNotification) -> String {
        match n {
            SupervisorNotification::TaskStarted { objective, .. } => {
                format!("Trabajando en: {}", truncate(objective, 100))
            }
            SupervisorNotification::TaskCompleted {
                objective,
                result,
                steps_total,
                steps_ok,
                duration_ms,
                ..
            } => {
                format!(
                    "Tarea completada ({}/{})\n{}\n\nResultado:\n{}\n\n({}ms)",
                    steps_ok,
                    steps_total,
                    truncate(objective, 80),
                    truncate(result, 2000),
                    duration_ms,
                )
            }
            SupervisorNotification::TaskFailed {
                objective,
                error,
                will_retry,
                ..
            } => {
                let retry = if *will_retry {
                    "Reintentando..."
                } else {
                    "Sin mas reintentos."
                };
                format!(
                    "Tarea fallida\n{}\n\nError: {}\n{}",
                    truncate(objective, 80),
                    truncate(error, 500),
                    retry,
                )
            }
            SupervisorNotification::Heartbeat {
                summary,
                uptime_hours,
            } => {
                format!(
                    "Reporte diario de LifeOS\nUptime: {:.1}h\nTareas: {}",
                    uptime_hours,
                    serde_json::to_string_pretty(summary).unwrap_or_else(|_| "{}".into()),
                )
            }
            SupervisorNotification::ApprovalRequired {
                action_description, ..
            } => {
                format!(
                    "Aprobacion requerida:\n{}\n\nResponde con /do [approve|reject] para proceder.",
                    truncate(action_description, 500)
                )
            }
            SupervisorNotification::TaskProgress {
                step_index,
                steps_total,
                description,
                ..
            } => {
                format!(
                    "Paso {}/{}: {}",
                    step_index + 1,
                    steps_total,
                    truncate(description, 200)
                )
            }
        }
    }

    fn split_message(text: &str, max_bytes: usize) -> Vec<&str> {
        let mut chunks = Vec::new();
        let mut start = 0;
        while start < text.len() {
            let mut end = (start + max_bytes).min(text.len());
            while end > start && !text.is_char_boundary(end) {
                end -= 1;
            }
            if end == start {
                end = start + 1;
            }
            chunks.push(&text[start..end]);
            start = end;
        }
        chunks
    }

    fn truncate(s: &str, max: usize) -> &str {
        if s.len() <= max {
            return s;
        }
        let mut end = max;
        while end > 0 && !s.is_char_boundary(end) {
            end -= 1;
        }
        &s[..end]
    }
}

#[cfg(feature = "slack")]
pub use inner::*;

// ---------------------------------------------------------------------------
// Stub — when the "slack" feature is not enabled
// ---------------------------------------------------------------------------

#[cfg(not(feature = "slack"))]
pub mod stub {
    pub struct SlackConfig;

    impl SlackConfig {
        pub fn from_env() -> Option<Self> {
            None
        }
    }

    pub async fn run_slack_bridge(
        _config: SlackConfig,
        _tq: std::sync::Arc<crate::task_queue::TaskQueue>,
        _router: std::sync::Arc<tokio::sync::RwLock<crate::llm_router::LlmRouter>>,
        _notify_rx: tokio::sync::broadcast::Receiver<crate::supervisor::SupervisorNotification>,
    ) {
    }
}
