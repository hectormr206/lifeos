//! Matrix/Element bridge — Bidirectional communication with LifeOS via Matrix CS API.
//!
//! Supports: text, images (vision), push notifications, /do task commands, typing indicators.
//! Uses Matrix Client-Server API v3 over HTTP (no matrix-sdk dependency).

#[cfg(feature = "matrix")]
mod inner {
    use log::{error, info, warn};
    use std::sync::Arc;
    use tokio::sync::RwLock;

    use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest, TaskComplexity};
    use crate::supervisor::SupervisorNotification;
    use crate::task_queue::{TaskCreate, TaskPriority, TaskQueue};

    // -----------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------

    #[derive(Debug, Clone)]
    pub struct MatrixConfig {
        /// e.g. https://matrix.org
        pub homeserver: String,
        /// e.g. @axi:matrix.org
        pub user_id: String,
        /// Bearer access token obtained by logging in
        pub access_token: String,
        /// Rooms to listen in and send notifications to
        pub room_ids: Vec<String>,
    }

    impl MatrixConfig {
        /// Load configuration from environment variables. Returns `None` if any
        /// required variable is absent or empty.
        pub fn from_env() -> Option<Self> {
            let homeserver = std::env::var("LIFEOS_MATRIX_HOMESERVER")
                .ok()
                .filter(|s| !s.is_empty())?;
            let user_id = std::env::var("LIFEOS_MATRIX_USER_ID")
                .ok()
                .filter(|s| !s.is_empty())?;
            let access_token = std::env::var("LIFEOS_MATRIX_ACCESS_TOKEN")
                .ok()
                .filter(|s| !s.is_empty())?;
            let room_ids: Vec<String> = std::env::var("LIFEOS_MATRIX_ROOM_IDS")
                .unwrap_or_default()
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();

            Some(Self {
                homeserver: homeserver.trim_end_matches('/').to_string(),
                user_id,
                access_token,
                room_ids,
            })
        }
    }

    // -----------------------------------------------------------------------
    // Public entry point
    // -----------------------------------------------------------------------

    /// Start the Matrix bridge. This function runs forever (or until the
    /// broadcast channel is closed).
    ///
    /// * Spawns a background task that forwards `SupervisorNotification` to all
    ///   configured rooms.
    /// * Runs a sync loop in the foreground that processes incoming messages.
    pub async fn run_matrix_bridge(
        config: MatrixConfig,
        task_queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
        mut notify_rx: tokio::sync::broadcast::Receiver<SupervisorNotification>,
    ) {
        info!(
            "Starting Matrix bridge for {} in {} room(s)",
            config.user_id,
            config.room_ids.len()
        );

        let http = build_client();

        // ── Notification forwarder ──────────────────────────────────────────
        {
            let notify_cfg = config.clone();
            let notify_http = http.clone();
            tokio::spawn(async move {
                loop {
                    match notify_rx.recv().await {
                        Ok(notification) => {
                            let text = format_notification(&notification);
                            let html = notification_to_html(&notification);
                            for room_id in &notify_cfg.room_ids {
                                if let Err(e) = send_matrix_html(
                                    &notify_http,
                                    &notify_cfg,
                                    room_id,
                                    &html,
                                    &text,
                                )
                                .await
                                {
                                    error!("Matrix notification to {} failed: {}", room_id, e);
                                }
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            warn!("Matrix notifications lagged by {}", n);
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    }
                }
            });
        }

        // ── Sync loop ───────────────────────────────────────────────────────
        let mut since: Option<String> = None;

        // Build a minimal filter so we only receive m.room.message events in
        // the configured rooms and avoid downloading account-data / presence
        // noise on every poll.
        let filter = build_sync_filter(&config.room_ids);

        loop {
            let url = build_sync_url(&config, since.as_deref(), &filter);

            let response = http
                .get(&url)
                .bearer_auth(&config.access_token)
                .send()
                .await;

            let body = match response {
                Ok(r) if r.status().is_success() => match r.json::<serde_json::Value>().await {
                    Ok(v) => v,
                    Err(e) => {
                        error!("Matrix sync JSON parse error: {}", e);
                        tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;
                        continue;
                    }
                },
                Ok(r) => {
                    let status = r.status();
                    let body_text = r.text().await.unwrap_or_default();
                    error!("Matrix sync HTTP {}: {}", status, &body_text[..body_text.len().min(200)]);
                    tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;
                    continue;
                }
                Err(e) => {
                    error!("Matrix sync request failed: {}", e);
                    tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;
                    continue;
                }
            };

            // Persist the `next_batch` token for the next poll
            if let Some(token) = body.get("next_batch").and_then(|v| v.as_str()) {
                since = Some(token.to_string());
            }

            // Process room timeline events
            if let Some(rooms) = body.get("rooms").and_then(|r| r.get("join")) {
                if let Some(room_map) = rooms.as_object() {
                    for (room_id, room_data) in room_map {
                        // Only handle rooms we are configured to listen in
                        if !config.room_ids.contains(room_id) {
                            continue;
                        }

                        let events = room_data
                            .get("timeline")
                            .and_then(|t| t.get("events"))
                            .and_then(|e| e.as_array());

                        if let Some(events) = events {
                            for event in events {
                                handle_event(
                                    &http,
                                    &config,
                                    room_id,
                                    event,
                                    &task_queue,
                                    &router,
                                )
                                .await;
                            }
                        }
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Event dispatcher
    // -----------------------------------------------------------------------

    async fn handle_event(
        http: &reqwest::Client,
        config: &MatrixConfig,
        room_id: &str,
        event: &serde_json::Value,
        task_queue: &Arc<TaskQueue>,
        router: &Arc<RwLock<LlmRouter>>,
    ) {
        // Only process m.room.message events
        if event.get("type").and_then(|v| v.as_str()) != Some("m.room.message") {
            return;
        }

        // Skip our own messages
        let sender = event
            .get("sender")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        if sender == config.user_id {
            return;
        }

        let content = match event.get("content") {
            Some(c) => c,
            None => return,
        };

        let msg_type = content
            .get("msgtype")
            .and_then(|v| v.as_str())
            .unwrap_or_default();

        match msg_type {
            "m.text" => {
                let body = content
                    .get("body")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                if body.is_empty() {
                    return;
                }
                info!(
                    "Matrix [{}] {}: {}",
                    room_id,
                    sender,
                    &body[..body.len().min(100)]
                );
                handle_text(http, config, room_id, &body, task_queue, router).await;
            }
            "m.image" => {
                let caption = content
                    .get("body")
                    .and_then(|v| v.as_str())
                    .unwrap_or("Describe esta imagen en español.")
                    .to_string();
                let mxc_url = content
                    .get("url")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                if mxc_url.is_empty() {
                    return;
                }
                info!("Matrix [{}] {}: image {}", room_id, sender, mxc_url);
                handle_image(http, config, room_id, &mxc_url, &caption, router).await;
            }
            _ => {
                // m.video, m.audio, m.file, etc. — ignored for now
            }
        }
    }

    // -----------------------------------------------------------------------
    // Text message handler
    // -----------------------------------------------------------------------

    async fn handle_text(
        http: &reqwest::Client,
        config: &MatrixConfig,
        room_id: &str,
        text: &str,
        task_queue: &Arc<TaskQueue>,
        router: &Arc<RwLock<LlmRouter>>,
    ) {
        // /do and /task commands create supervisor tasks
        if text.starts_with("/do ") || text.starts_with("/task ") {
            let objective = text
                .strip_prefix("/do ")
                .or_else(|| text.strip_prefix("/task "))
                .unwrap_or(text)
                .to_string();
            handle_task_command(http, config, room_id, objective, task_queue).await;
            return;
        }

        if text.starts_with("/status") {
            handle_status_command(http, config, room_id, task_queue).await;
            return;
        }

        if text.starts_with("/help") || text.starts_with("/start") {
            handle_help_command(http, config, room_id).await;
            return;
        }

        // Default: route to LLM
        let _ = set_typing(http, config, room_id, true).await;

        let reply = chat_with_llm(router, text).await;

        let _ = set_typing(http, config, room_id, false).await;

        // Send in chunks if the response is very long (Matrix has a ~65 KB body limit, but
        // keep UI-friendly at ≤ 4 000 chars per message)
        for chunk in chunked(&reply, 4000) {
            if let Err(e) = send_matrix_message(http, config, room_id, chunk).await {
                error!("Matrix send failed in {}: {}", room_id, e);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Image handler
    // -----------------------------------------------------------------------

    async fn handle_image(
        http: &reqwest::Client,
        config: &MatrixConfig,
        room_id: &str,
        mxc_url: &str,
        caption: &str,
        router: &Arc<RwLock<LlmRouter>>,
    ) {
        let _ = set_typing(http, config, room_id, true).await;

        let reply = match download_matrix_media(http, config, mxc_url).await {
            Ok(bytes) => {
                use base64::Engine;
                let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
                // Guess MIME type from first bytes (JPEG magic = FF D8, PNG = 89 50)
                let mime = if bytes.starts_with(&[0xFF, 0xD8]) {
                    "image/jpeg"
                } else if bytes.starts_with(&[0x89, 0x50]) {
                    "image/png"
                } else {
                    "image/jpeg" // safe fallback
                };
                let data_url = format!("data:{};base64,{}", mime, b64);

                let request = RouterRequest {
                    messages: vec![
                        ChatMessage {
                            role: "system".into(),
                            content: serde_json::Value::String(
                                "Eres Axi, asistente visual de LifeOS. \
                                 Describe y analiza imágenes en español de forma concisa."
                                    .into(),
                            ),
                        },
                        ChatMessage {
                            role: "user".into(),
                            content: serde_json::json!([
                                { "type": "text", "text": caption },
                                { "type": "image_url", "image_url": { "url": data_url } }
                            ]),
                        },
                    ],
                    complexity: Some(TaskComplexity::Vision),
                    sensitivity: None,
                    preferred_provider: None,
                    max_tokens: Some(1024),
                };

                let r = router.read().await;
                match r.chat(&request).await {
                    Ok(resp) => format!("{}\n\n[{}]", resp.text, resp.provider),
                    Err(e) => format!("No pude analizar la imagen: {}", e),
                }
            }
            Err(e) => {
                error!("Matrix media download failed ({}): {}", mxc_url, e);
                format!("No pude descargar la imagen: {}", e)
            }
        };

        let _ = set_typing(http, config, room_id, false).await;

        for chunk in chunked(&reply, 4000) {
            if let Err(e) = send_matrix_message(http, config, room_id, chunk).await {
                error!("Matrix image reply failed in {}: {}", room_id, e);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Command handlers
    // -----------------------------------------------------------------------

    async fn handle_task_command(
        http: &reqwest::Client,
        config: &MatrixConfig,
        room_id: &str,
        objective: String,
        task_queue: &Arc<TaskQueue>,
    ) {
        match task_queue.enqueue(TaskCreate {
            objective: objective.clone(),
            priority: TaskPriority::Normal,
            source: "matrix".into(),
            max_attempts: 3,
        }) {
            Ok(task) => {
                let msg = format!(
                    "Tarea creada:\n{}\n\nID: {}\nTe avisaré cuando termine.",
                    objective, task.id
                );
                if let Err(e) = send_matrix_message(http, config, room_id, &msg).await {
                    error!("Matrix task ack failed: {}", e);
                }
            }
            Err(e) => {
                let msg = format!("Error al crear tarea: {}", e);
                let _ = send_matrix_message(http, config, room_id, &msg).await;
            }
        }
    }

    async fn handle_status_command(
        http: &reqwest::Client,
        config: &MatrixConfig,
        room_id: &str,
        task_queue: &Arc<TaskQueue>,
    ) {
        let summary = task_queue.summary().unwrap_or_default();
        let recent = task_queue.list(None, 5).unwrap_or_default();
        let mut reply = format!(
            "Estado de LifeOS:\n{}",
            serde_json::to_string_pretty(&summary).unwrap_or_else(|_| "{}".into())
        );
        if !recent.is_empty() {
            reply.push_str("\n\nÚltimas tareas:");
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
        if let Err(e) = send_matrix_message(http, config, room_id, &reply).await {
            error!("Matrix status reply failed: {}", e);
        }
    }

    async fn handle_help_command(
        http: &reqwest::Client,
        config: &MatrixConfig,
        room_id: &str,
    ) {
        let help = "Soy Axi, tu asistente de LifeOS.\n\n\
                    Comandos:\n\
                    /do <tarea> — Crear tarea para el supervisor\n\
                    /task <tarea> — Igual que /do\n\
                    /status — Ver estado de tareas\n\
                    /help — Este mensaje\n\n\
                    También puedes:\n\
                    - Enviar texto y te respondo\n\
                    - Enviar imagen y la analizo\n\n\
                    Las notificaciones de tareas llegan automáticamente a este canal.";
        if let Err(e) = send_matrix_message(http, config, room_id, help).await {
            error!("Matrix help reply failed: {}", e);
        }
    }

    // -----------------------------------------------------------------------
    // Public helper functions
    // -----------------------------------------------------------------------

    /// Send a plain-text `m.room.message` to `room_id`.
    pub async fn send_matrix_message(
        http: &reqwest::Client,
        config: &MatrixConfig,
        room_id: &str,
        text: &str,
    ) -> Result<(), String> {
        let txn_id = new_txn_id();
        let url = format!(
            "{}/_matrix/client/v3/rooms/{}/send/m.room.message/{}",
            config.homeserver,
            urlencoded(room_id),
            txn_id,
        );

        let body = serde_json::json!({
            "msgtype": "m.text",
            "body": text,
        });

        let response = http
            .put(&url)
            .bearer_auth(&config.access_token)
            .json(&body)
            .send()
            .await
            .map_err(|e| e.to_string())?;

        if response.status().is_success() {
            Ok(())
        } else {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            Err(format!("HTTP {}: {}", status, &body[..body.len().min(200)]))
        }
    }

    /// Send an HTML-formatted `m.room.message` to `room_id`.
    ///
    /// `html` is the formatted body; `plain` is the plain-text fallback.
    pub async fn send_matrix_html(
        http: &reqwest::Client,
        config: &MatrixConfig,
        room_id: &str,
        html: &str,
        plain: &str,
    ) -> Result<(), String> {
        let txn_id = new_txn_id();
        let url = format!(
            "{}/_matrix/client/v3/rooms/{}/send/m.room.message/{}",
            config.homeserver,
            urlencoded(room_id),
            txn_id,
        );

        let body = serde_json::json!({
            "msgtype": "m.text",
            "body": plain,
            "format": "org.matrix.custom.html",
            "formatted_body": html,
        });

        let response = http
            .put(&url)
            .bearer_auth(&config.access_token)
            .json(&body)
            .send()
            .await
            .map_err(|e| e.to_string())?;

        if response.status().is_success() {
            Ok(())
        } else {
            let status = response.status();
            let body_text = response.text().await.unwrap_or_default();
            Err(format!(
                "HTTP {}: {}",
                status,
                &body_text[..body_text.len().min(200)]
            ))
        }
    }

    /// Download media from the Matrix content repository.
    ///
    /// Accepts `mxc://server/media_id` URLs and converts them to the
    /// `/_matrix/media/v3/download/{server}/{media_id}` endpoint.
    pub async fn download_matrix_media(
        http: &reqwest::Client,
        config: &MatrixConfig,
        mxc_url: &str,
    ) -> Result<Vec<u8>, String> {
        // mxc_url format: mxc://<server>/<media_id>
        let without_scheme = mxc_url
            .strip_prefix("mxc://")
            .ok_or_else(|| format!("Invalid mxc URL: {}", mxc_url))?;

        let url = format!(
            "{}/_matrix/media/v3/download/{}",
            config.homeserver, without_scheme
        );

        let response = http
            .get(&url)
            .bearer_auth(&config.access_token)
            .send()
            .await
            .map_err(|e| e.to_string())?;

        if response.status().is_success() {
            response.bytes().await.map(|b| b.to_vec()).map_err(|e| e.to_string())
        } else {
            let status = response.status();
            Err(format!("Media download HTTP {}", status))
        }
    }

    /// Send or cancel a typing indicator in `room_id`.
    ///
    /// `typing = true` sets a 30-second typing window; `false` cancels immediately.
    pub async fn set_typing(
        http: &reqwest::Client,
        config: &MatrixConfig,
        room_id: &str,
        typing: bool,
    ) -> Result<(), String> {
        let url = format!(
            "{}/_matrix/client/v3/rooms/{}/typing/{}",
            config.homeserver,
            urlencoded(room_id),
            urlencoded(&config.user_id),
        );

        let body = if typing {
            serde_json::json!({ "typing": true, "timeout": 30000 })
        } else {
            serde_json::json!({ "typing": false })
        };

        let response = http
            .put(&url)
            .bearer_auth(&config.access_token)
            .json(&body)
            .send()
            .await
            .map_err(|e| e.to_string())?;

        if response.status().is_success() {
            Ok(())
        } else {
            let status = response.status();
            Err(format!("Typing indicator HTTP {}", status))
        }
    }

    // -----------------------------------------------------------------------
    // LLM helper
    // -----------------------------------------------------------------------

    async fn chat_with_llm(router: &Arc<RwLock<LlmRouter>>, text: &str) -> String {
        let request = RouterRequest {
            messages: vec![
                ChatMessage {
                    role: "system".into(),
                    content: serde_json::Value::String(
                        "Eres Axi, el asistente AI de LifeOS. \
                         Responde de forma concisa y útil en español."
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
            Err(e) => format!("Error al procesar tu mensaje: {}", e),
        }
    }

    // -----------------------------------------------------------------------
    // Notification formatting
    // -----------------------------------------------------------------------

    fn format_notification(n: &SupervisorNotification) -> String {
        match n {
            SupervisorNotification::TaskStarted { objective, .. } => {
                format!("⏳ Trabajando en: {}", truncate(objective, 100))
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
                    "✅ Tarea completada ({}/{})\n{}\n\nResultado:\n{}\n\n({}ms)",
                    steps_ok,
                    steps_total,
                    truncate(objective, 80),
                    truncate(result, 3000),
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
                    "Sin más reintentos."
                };
                format!(
                    "❌ Tarea fallida\n{}\n\nError: {}\n{}",
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
                    "📊 Reporte diario de LifeOS\nUptime: {:.1}h\nTareas: {}",
                    uptime_hours,
                    serde_json::to_string_pretty(summary).unwrap_or_else(|_| "{}".into()),
                )
            }
            SupervisorNotification::ApprovalRequired {
                action_description, ..
            } => {
                format!(
                    "⚠️ Aprobación requerida:\n{}",
                    truncate(action_description, 500)
                )
            }
        }
    }

    fn notification_to_html(n: &SupervisorNotification) -> String {
        match n {
            SupervisorNotification::TaskStarted { objective, .. } => {
                format!(
                    "<p>⏳ <strong>Trabajando en:</strong> {}</p>",
                    html_escape(truncate(objective, 100))
                )
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
                    "<p>✅ <strong>Tarea completada</strong> ({}/{})<br/>{}</p>\
                     <p><strong>Resultado:</strong><br/><pre>{}</pre></p>\
                     <p><em>{}ms</em></p>",
                    steps_ok,
                    steps_total,
                    html_escape(truncate(objective, 80)),
                    html_escape(truncate(result, 3000)),
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
                    "Sin más reintentos."
                };
                format!(
                    "<p>❌ <strong>Tarea fallida</strong><br/>{}</p>\
                     <p><strong>Error:</strong> {}</p><p>{}</p>",
                    html_escape(truncate(objective, 80)),
                    html_escape(truncate(error, 500)),
                    retry,
                )
            }
            SupervisorNotification::Heartbeat {
                summary,
                uptime_hours,
            } => {
                format!(
                    "<p>📊 <strong>Reporte diario de LifeOS</strong><br/>\
                     Uptime: {:.1}h</p><pre>{}</pre>",
                    uptime_hours,
                    html_escape(
                        &serde_json::to_string_pretty(summary).unwrap_or_else(|_| "{}".into())
                    ),
                )
            }
            SupervisorNotification::ApprovalRequired {
                action_description, ..
            } => {
                format!(
                    "<p>⚠️ <strong>Aprobación requerida:</strong><br/>{}</p>",
                    html_escape(truncate(action_description, 500))
                )
            }
        }
    }

    // -----------------------------------------------------------------------
    // Sync URL construction + filter
    // -----------------------------------------------------------------------

    /// Build a `/_matrix/client/v3/sync` URL with optional `since` token.
    fn build_sync_url(config: &MatrixConfig, since: Option<&str>, filter: &str) -> String {
        let mut url = format!(
            "{}/_matrix/client/v3/sync?timeout=30000&filter={}",
            config.homeserver,
            urlencoded(filter),
        );
        if let Some(s) = since {
            url.push_str("&since=");
            url.push_str(&urlencoded(s));
        }
        url
    }

    /// Build a compact JSON sync filter string.
    ///
    /// We only request timeline events of type `m.room.message` in the
    /// configured rooms, and suppress presence, account-data, and typing
    /// notifications to keep payloads small.
    fn build_sync_filter(room_ids: &[String]) -> String {
        let filter = serde_json::json!({
            "room": {
                "rooms": room_ids,
                "timeline": {
                    "types": ["m.room.message"],
                    "limit": 20
                },
                "state": { "types": [], "limit": 0 },
                "ephemeral": { "types": [], "limit": 0 },
                "account_data": { "types": [], "limit": 0 }
            },
            "presence": { "types": [], "limit": 0 },
            "account_data": { "types": [], "limit": 0 }
        });
        filter.to_string()
    }

    // -----------------------------------------------------------------------
    // Small utilities
    // -----------------------------------------------------------------------

    fn build_client() -> reqwest::Client {
        reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(60))
            .user_agent("LifeOS/1.0 matrix-bridge")
            .build()
            .expect("Failed to build reqwest client")
    }

    /// Generate a unique transaction ID for Matrix PUT requests.
    fn new_txn_id() -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0);
        let millis = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        format!("lifeos-{}-{}", millis, nanos)
    }

    /// Percent-encode a string for use in URL path segments or query values.
    fn urlencoded(s: &str) -> String {
        let mut out = String::with_capacity(s.len());
        for byte in s.bytes() {
            match byte {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                    out.push(byte as char);
                }
                _ => {
                    out.push('%');
                    out.push_str(&format!("{:02X}", byte));
                }
            }
        }
        out
    }

    fn html_escape(s: &str) -> String {
        s.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('"', "&quot;")
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

    /// Split `text` into chunks of at most `max` bytes, splitting on char boundaries.
    fn chunked(text: &str, max: usize) -> Vec<&str> {
        let mut chunks = Vec::new();
        let mut start = 0;
        while start < text.len() {
            let end = (start + max).min(text.len());
            let mut end = end;
            while end > start && !text.is_char_boundary(end) {
                end -= 1;
            }
            if end == start {
                break; // safety: avoid infinite loop on unusual input
            }
            chunks.push(&text[start..end]);
            start = end;
        }
        chunks
    }
}

#[cfg(feature = "matrix")]
pub use inner::*;

// ---------------------------------------------------------------------------
// Stub for when the `matrix` feature is disabled
// ---------------------------------------------------------------------------

#[cfg(not(feature = "matrix"))]
pub mod stub {
    pub struct MatrixConfig;

    impl MatrixConfig {
        pub fn from_env() -> Option<Self> {
            None
        }
    }

    pub async fn run_matrix_bridge(
        _config: MatrixConfig,
        _tq: std::sync::Arc<crate::task_queue::TaskQueue>,
        _router: std::sync::Arc<tokio::sync::RwLock<crate::llm_router::LlmRouter>>,
        _notify_rx: tokio::sync::broadcast::Receiver<crate::supervisor::SupervisorNotification>,
    ) {
    }
}
