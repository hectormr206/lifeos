//! Discord bridge — Bidirectional communication with LifeOS via Discord Bot API.
//!
//! Uses Discord Gateway (WebSocket) to receive MESSAGE_CREATE events.
//! Sends replies via Discord REST API (`/channels/{id}/messages`).
//!
//! Supports: text messages, push notifications, /do commands.

#[cfg(feature = "discord")]
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
    pub struct DiscordConfig {
        /// Bot token from the Discord Developer Portal
        pub bot_token: String,
        /// Optional guild IDs to restrict the bot to
        pub allowed_guilds: Vec<String>,
        /// Channel IDs where notifications are sent (first one is default)
        pub notification_channels: Vec<String>,
    }

    impl DiscordConfig {
        pub fn from_env() -> Option<Self> {
            let bot_token = std::env::var("LIFEOS_DISCORD_BOT_TOKEN")
                .ok()
                .filter(|s| !s.is_empty())?;
            let allowed_guilds: Vec<String> = std::env::var("LIFEOS_DISCORD_ALLOWED_GUILDS")
                .unwrap_or_default()
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            let notification_channels: Vec<String> =
                std::env::var("LIFEOS_DISCORD_NOTIFICATION_CHANNELS")
                    .unwrap_or_default()
                    .split(',')
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect();
            Some(Self {
                bot_token,
                allowed_guilds,
                notification_channels,
            })
        }
    }

    // -----------------------------------------------------------------------
    // Discord Gateway opcodes
    // -----------------------------------------------------------------------

    const OP_DISPATCH: u64 = 0;
    const OP_HEARTBEAT: u64 = 1;
    const OP_IDENTIFY: u64 = 2;
    const OP_HELLO: u64 = 10;
    const OP_HEARTBEAT_ACK: u64 = 11;

    // Gateway intents: GUILDS (1<<0) | GUILD_MESSAGES (1<<9) | MESSAGE_CONTENT (1<<15)
    const INTENTS: u64 = (1 << 0) | (1 << 9) | (1 << 15);

    // -----------------------------------------------------------------------
    // Public entry point
    // -----------------------------------------------------------------------

    pub async fn run_discord_bridge(
        config: DiscordConfig,
        task_queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
        mut notify_rx: tokio::sync::broadcast::Receiver<SupervisorNotification>,
    ) {
        info!(
            "Starting Discord bridge ({} allowed guild(s))",
            config.allowed_guilds.len()
        );

        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("Failed to build HTTP client for Discord bridge");

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
                            for channel_id in &notify_cfg.notification_channels {
                                if let Err(e) = send_discord_message(
                                    &notify_http,
                                    &notify_cfg.bot_token,
                                    channel_id,
                                    &text,
                                )
                                .await
                                {
                                    error!("Discord notification to {} failed: {}", channel_id, e);
                                }
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            warn!("Discord notifications lagged by {}", n);
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    }
                }
            });
        }

        // ---- Gateway loop ----
        loop {
            // Get the gateway URL
            let gateway_url = match get_gateway_url(&http, &config.bot_token).await {
                Ok(url) => url,
                Err(e) => {
                    error!("Discord: failed to get gateway URL: {}", e);
                    tokio::time::sleep(Duration::from_secs(10)).await;
                    continue;
                }
            };

            info!("Discord Gateway: connecting...");

            match run_gateway(&gateway_url, &config, &http, &task_queue, &router).await {
                Ok(()) => {
                    info!("Discord Gateway: connection closed, reconnecting...");
                }
                Err(e) => {
                    error!("Discord Gateway error: {}", e);
                }
            }

            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    }

    // -----------------------------------------------------------------------
    // Gateway connection
    // -----------------------------------------------------------------------

    /// Fetch the WebSocket gateway URL from Discord's REST API.
    async fn get_gateway_url(http: &reqwest::Client, bot_token: &str) -> Result<String, String> {
        let resp = http
            .get("https://discord.com/api/v10/gateway/bot")
            .header("Authorization", format!("Bot {}", bot_token))
            .send()
            .await
            .map_err(|e| format!("HTTP error: {}", e))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(format!("Gateway/bot HTTP {}: {}", status, body));
        }

        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| format!("JSON parse error: {}", e))?;

        let url = body
            .get("url")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "Missing 'url' in gateway response".to_string())?;

        Ok(format!("{}/?v=10&encoding=json", url))
    }

    /// Run the Discord Gateway WebSocket loop.
    async fn run_gateway(
        ws_url: &str,
        config: &Arc<DiscordConfig>,
        http: &reqwest::Client,
        task_queue: &Arc<TaskQueue>,
        router: &Arc<RwLock<LlmRouter>>,
    ) -> Result<(), String> {
        use tokio_tungstenite::connect_async;
        use tokio_tungstenite::tungstenite::Message;

        let (ws_stream, _) = connect_async(ws_url)
            .await
            .map_err(|e| format!("WebSocket connect error: {}", e))?;

        info!("Discord Gateway: connected");

        use futures_util::{SinkExt, StreamExt};
        let (mut write, mut read) = ws_stream.split();

        let mut sequence: Option<u64> = None;
        let mut heartbeat_interval_ms: u64 = 41250;
        let mut bot_user_id = String::new();
        let mut identified = false;

        // We need a heartbeat task. We'll use an interval timer.
        let heartbeat_write = Arc::new(tokio::sync::Mutex::new(None::<u64>));

        loop {
            let timeout = Duration::from_millis(heartbeat_interval_ms + 5000);

            let msg = tokio::select! {
                msg = read.next() => {
                    match msg {
                        Some(Ok(m)) => m,
                        Some(Err(e)) => {
                            error!("Discord Gateway read error: {}", e);
                            break;
                        }
                        None => {
                            info!("Discord Gateway: stream ended");
                            break;
                        }
                    }
                }
                _ = tokio::time::sleep(timeout) => {
                    // Send heartbeat on timeout
                    let hb = serde_json::json!({
                        "op": OP_HEARTBEAT,
                        "d": sequence,
                    });
                    if let Err(e) = write.send(Message::Text(hb.to_string().into())).await {
                        error!("Discord Gateway: heartbeat send error: {}", e);
                        break;
                    }
                    continue;
                }
            };

            let text = match msg {
                Message::Text(t) => t,
                Message::Close(_) => {
                    info!("Discord Gateway: server sent close");
                    break;
                }
                _ => continue,
            };

            let payload: serde_json::Value = match serde_json::from_str(&text) {
                Ok(v) => v,
                Err(e) => {
                    warn!("Discord Gateway: invalid JSON: {}", e);
                    continue;
                }
            };

            let op = payload.get("op").and_then(|v| v.as_u64()).unwrap_or(99);

            // Update sequence number
            if let Some(s) = payload.get("s").and_then(|v| v.as_u64()) {
                sequence = Some(s);
                *heartbeat_write.lock().await = Some(s);
            }

            match op {
                OP_HELLO => {
                    // Extract heartbeat interval
                    if let Some(interval) = payload
                        .get("d")
                        .and_then(|d| d.get("heartbeat_interval"))
                        .and_then(|v| v.as_u64())
                    {
                        heartbeat_interval_ms = interval;
                    }

                    // Send initial heartbeat
                    let hb = serde_json::json!({
                        "op": OP_HEARTBEAT,
                        "d": serde_json::Value::Null,
                    });
                    if let Err(e) = write.send(Message::Text(hb.to_string().into())).await {
                        error!("Discord Gateway: initial heartbeat error: {}", e);
                        break;
                    }

                    // Send IDENTIFY
                    if !identified {
                        let identify = serde_json::json!({
                            "op": OP_IDENTIFY,
                            "d": {
                                "token": config.bot_token,
                                "intents": INTENTS,
                                "properties": {
                                    "os": "linux",
                                    "browser": "lifeos",
                                    "device": "lifeos"
                                }
                            }
                        });
                        if let Err(e) = write.send(Message::Text(identify.to_string().into())).await
                        {
                            error!("Discord Gateway: identify error: {}", e);
                            break;
                        }
                        identified = true;
                    }

                    // Spawn heartbeat task
                    let hb_write_ref = heartbeat_write.clone();
                    let hb_interval = heartbeat_interval_ms;
                    // We don't actually spawn a heartbeat sender here because we handle
                    // it via the timeout branch above. The interval drives re-sends.
                    let _ = (hb_write_ref, hb_interval);
                }
                OP_HEARTBEAT => {
                    // Server requests an immediate heartbeat
                    let hb = serde_json::json!({
                        "op": OP_HEARTBEAT,
                        "d": sequence,
                    });
                    if let Err(e) = write.send(Message::Text(hb.to_string().into())).await {
                        error!("Discord Gateway: heartbeat response error: {}", e);
                        break;
                    }
                }
                OP_HEARTBEAT_ACK => {
                    // Good — server acknowledged our heartbeat
                }
                OP_DISPATCH => {
                    let event_name = payload
                        .get("t")
                        .and_then(|v| v.as_str())
                        .unwrap_or_default();

                    match event_name {
                        "READY" => {
                            // Extract bot's own user ID to ignore self-messages
                            if let Some(uid) = payload
                                .get("d")
                                .and_then(|d| d.get("user"))
                                .and_then(|u| u.get("id"))
                                .and_then(|v| v.as_str())
                            {
                                bot_user_id = uid.to_string();
                                info!("Discord Gateway: READY as user {}", bot_user_id);
                            }
                        }
                        "MESSAGE_CREATE" => {
                            if let Some(d) = payload.get("d") {
                                // Skip own messages
                                let author_id = d
                                    .get("author")
                                    .and_then(|a| a.get("id"))
                                    .and_then(|v| v.as_str())
                                    .unwrap_or_default();
                                if author_id == bot_user_id {
                                    continue;
                                }
                                // Skip bot authors
                                let is_bot = d
                                    .get("author")
                                    .and_then(|a| a.get("bot"))
                                    .and_then(|v| v.as_bool())
                                    .unwrap_or(false);
                                if is_bot {
                                    continue;
                                }

                                let config_clone = config.clone();
                                let http_clone = http.clone();
                                let tq_clone = task_queue.clone();
                                let router_clone = router.clone();
                                let d_clone = d.clone();

                                tokio::spawn(async move {
                                    handle_message_create(
                                        &config_clone,
                                        &http_clone,
                                        &d_clone,
                                        &tq_clone,
                                        &router_clone,
                                    )
                                    .await;
                                });
                            }
                        }
                        _ => {
                            // Other events — ignore
                        }
                    }
                }
                _ => {}
            }
        }

        Ok(())
    }

    // -----------------------------------------------------------------------
    // Message handler
    // -----------------------------------------------------------------------

    async fn handle_message_create(
        config: &DiscordConfig,
        http: &reqwest::Client,
        msg: &serde_json::Value,
        task_queue: &Arc<TaskQueue>,
        router: &Arc<RwLock<LlmRouter>>,
    ) {
        let channel_id = msg
            .get("channel_id")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        let content = msg
            .get("content")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .trim()
            .to_string();
        let guild_id = msg
            .get("guild_id")
            .and_then(|v| v.as_str())
            .unwrap_or_default();

        if content.is_empty() || channel_id.is_empty() {
            return;
        }

        // Auth check — restrict to allowed guilds
        if !config.allowed_guilds.is_empty()
            && !guild_id.is_empty()
            && !config.allowed_guilds.contains(&guild_id.to_string())
        {
            warn!(
                "Discord: message from non-allowed guild {}; ignoring",
                guild_id
            );
            return;
        }

        info!(
            "Discord [{}]: {}",
            channel_id,
            &content[..content.len().min(100)]
        );

        if content.starts_with("/do ") || content.starts_with("/task ") {
            let objective = content
                .strip_prefix("/do ")
                .or_else(|| content.strip_prefix("/task "))
                .unwrap_or(&content)
                .to_string();
            handle_task(config, http, channel_id, objective, task_queue).await;
        } else if content.starts_with("/status") {
            handle_status(config, http, channel_id, task_queue).await;
        } else if content.starts_with("/help") || content == "/start" {
            handle_help(config, http, channel_id).await;
        } else {
            handle_chat(config, http, channel_id, &content, router).await;
        }
    }

    // -----------------------------------------------------------------------
    // Command handlers
    // -----------------------------------------------------------------------

    async fn handle_task(
        config: &DiscordConfig,
        http: &reqwest::Client,
        channel_id: &str,
        objective: String,
        task_queue: &Arc<TaskQueue>,
    ) {
        match task_queue.enqueue(TaskCreate {
            objective: objective.clone(),
            priority: TaskPriority::Normal,
            source: "discord".into(),
            max_attempts: 3,
        }) {
            Ok(task) => {
                let reply = format!(
                    "Tarea creada:\n{}\n\nID: {}\nTe avisare cuando termine.",
                    objective, task.id
                );
                if let Err(e) =
                    send_discord_message(http, &config.bot_token, channel_id, &reply).await
                {
                    error!(
                        "Discord: failed to confirm task creation in {}: {}",
                        channel_id, e
                    );
                }
            }
            Err(e) => {
                let reply = format!("Error al crear tarea: {}", e);
                let _ = send_discord_message(http, &config.bot_token, channel_id, &reply).await;
            }
        }
    }

    async fn handle_status(
        config: &DiscordConfig,
        http: &reqwest::Client,
        channel_id: &str,
        task_queue: &Arc<TaskQueue>,
    ) {
        let summary = task_queue.summary().unwrap_or_default();
        let recent = task_queue.list(None, 5).unwrap_or_default();
        let mut reply = format!(
            "Estado de LifeOS:\n```json\n{}```",
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
        if let Err(e) = send_discord_message(http, &config.bot_token, channel_id, &reply).await {
            error!("Discord: failed to send status in {}: {}", channel_id, e);
        }
    }

    async fn handle_help(config: &DiscordConfig, http: &reqwest::Client, channel_id: &str) {
        let help = "Soy Axi, tu asistente de LifeOS via Discord.\n\n\
             Comandos:\n\
             `/do <tarea>` -- Crear tarea para el supervisor\n\
             `/task <tarea>` -- Igual que /do\n\
             `/status` -- Ver estado de tareas\n\
             `/help` -- Este mensaje\n\n\
             Tambien puedes enviar texto y te respondo con IA.\n\
             Las notificaciones de tareas llegan automaticamente a este canal.";
        if let Err(e) = send_discord_message(http, &config.bot_token, channel_id, help).await {
            error!("Discord: failed to send help in {}: {}", channel_id, e);
        }
    }

    async fn handle_chat(
        config: &DiscordConfig,
        http: &reqwest::Client,
        channel_id: &str,
        text: &str,
        router: &Arc<RwLock<LlmRouter>>,
    ) {
        // Show typing indicator
        let _ = send_typing_indicator(http, &config.bot_token, channel_id).await;

        let reply = chat_with_llm(router, text).await;
        // Discord has a 2000-char message limit
        for chunk in split_message(&reply, 1900) {
            if let Err(e) = send_discord_message(http, &config.bot_token, channel_id, chunk).await {
                error!(
                    "Discord: failed to send chat reply in {}: {}",
                    channel_id, e
                );
                break;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Discord REST API helpers
    // -----------------------------------------------------------------------

    /// Send a text message to a Discord channel.
    pub async fn send_discord_message(
        http: &reqwest::Client,
        bot_token: &str,
        channel_id: &str,
        text: &str,
    ) -> Result<(), String> {
        let url = format!(
            "https://discord.com/api/v10/channels/{}/messages",
            channel_id
        );

        let body = serde_json::json!({
            "content": text,
        });

        let resp = http
            .post(&url)
            .header("Authorization", format!("Bot {}", bot_token))
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("HTTP error: {}", e))?;

        if resp.status().is_success() {
            Ok(())
        } else {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            Err(format!(
                "Discord API HTTP {}: {}",
                status,
                &body[..body.len().min(200)]
            ))
        }
    }

    /// Trigger a "typing" indicator in a Discord channel.
    pub async fn send_typing_indicator(
        http: &reqwest::Client,
        bot_token: &str,
        channel_id: &str,
    ) -> Result<(), String> {
        let url = format!("https://discord.com/api/v10/channels/{}/typing", channel_id);

        let resp = http
            .post(&url)
            .header("Authorization", format!("Bot {}", bot_token))
            .send()
            .await
            .map_err(|e| format!("HTTP error: {}", e))?;

        if resp.status().is_success() || resp.status().as_u16() == 204 {
            Ok(())
        } else {
            let status = resp.status();
            Err(format!("Discord typing indicator HTTP {}", status))
        }
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
                    truncate(result, 1500),
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

#[cfg(feature = "discord")]
pub use inner::*;

// ---------------------------------------------------------------------------
// Stub — when the "discord" feature is not enabled
// ---------------------------------------------------------------------------

#[cfg(not(feature = "discord"))]
pub mod stub {
    pub struct DiscordConfig;

    impl DiscordConfig {
        pub fn from_env() -> Option<Self> {
            None
        }
    }

    pub async fn run_discord_bridge(
        _config: DiscordConfig,
        _tq: std::sync::Arc<crate::task_queue::TaskQueue>,
        _router: std::sync::Arc<tokio::sync::RwLock<crate::llm_router::LlmRouter>>,
        _notify_rx: tokio::sync::broadcast::Receiver<crate::supervisor::SupervisorNotification>,
    ) {
    }
}
