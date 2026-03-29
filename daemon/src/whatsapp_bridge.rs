//! WhatsApp bridge — Bidirectional multimedia communication with LifeOS via WhatsApp Cloud API.
//!
//! Uses the Meta Business Platform (Graph API v19+) via HTTP with reqwest.
//! Webhook listener runs on 127.0.0.1:8085 (reverse-proxied from a public HTTPS endpoint).
//!
//! Supports: text messages, incoming images (vision), push notifications to allowed numbers,
//! and /do commands to create tasks.

#[cfg(feature = "whatsapp")]
mod inner {
    use axum::extract::{Query, State};
    use axum::http::StatusCode;
    use axum::response::IntoResponse;
    use axum::routing::{get, post};
    use axum::{Json, Router};
    use log::{error, info, warn};
    use serde::{Deserialize, Serialize};
    use std::sync::Arc;
    use tokio::sync::RwLock;

    use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest, TaskComplexity};
    use crate::supervisor::SupervisorNotification;
    use crate::task_queue::{TaskCreate, TaskPriority, TaskQueue};

    // -----------------------------------------------------------------------
    // Config
    // -----------------------------------------------------------------------

    #[derive(Debug, Clone)]
    pub struct WhatsAppConfig {
        /// Permanent access token from Meta Business Platform.
        pub token: String,
        /// Phone Number ID (not the actual E.164 phone number).
        pub phone_id: String,
        /// Arbitrary secret to validate incoming webhooks from Meta.
        pub verify_token: String,
        /// E.164-formatted phone numbers allowed to interact with the bridge.
        pub allowed_numbers: Vec<String>,
    }

    impl WhatsAppConfig {
        pub fn from_env() -> Option<Self> {
            let token = std::env::var("LIFEOS_WHATSAPP_TOKEN").ok()?;
            if token.is_empty() {
                return None;
            }
            let phone_id = std::env::var("LIFEOS_WHATSAPP_PHONE_ID").ok()?;
            if phone_id.is_empty() {
                return None;
            }
            let verify_token = std::env::var("LIFEOS_WHATSAPP_VERIFY_TOKEN").unwrap_or_else(|_| {
                warn!("LIFEOS_WHATSAPP_VERIFY_TOKEN not set — webhook verification disabled");
                String::new()
            });
            let allowed_numbers: Vec<String> = std::env::var("LIFEOS_WHATSAPP_ALLOWED_NUMBERS")
                .unwrap_or_default()
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            Some(Self {
                token,
                phone_id,
                verify_token,
                allowed_numbers,
            })
        }
    }

    // -----------------------------------------------------------------------
    // Shared state passed to Axum handlers
    // -----------------------------------------------------------------------

    #[derive(Clone)]
    struct BridgeState {
        config: WhatsAppConfig,
        task_queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
    }

    // -----------------------------------------------------------------------
    // WhatsApp Cloud API — incoming webhook payload shapes
    // -----------------------------------------------------------------------

    #[derive(Debug, Deserialize)]
    struct WebhookPayload {
        entry: Option<Vec<WebhookEntry>>,
    }

    #[derive(Debug, Deserialize)]
    struct WebhookEntry {
        changes: Option<Vec<WebhookChange>>,
    }

    #[derive(Debug, Deserialize)]
    struct WebhookChange {
        value: Option<WebhookValue>,
    }

    #[derive(Debug, Deserialize)]
    struct WebhookValue {
        messages: Option<Vec<IncomingMessage>>,
    }

    #[derive(Debug, Deserialize)]
    struct IncomingMessage {
        /// E.164 sender phone number (e.g. "521234567890")
        from: String,
        #[serde(rename = "type")]
        msg_type: String,
        text: Option<TextContent>,
        image: Option<MediaContent>,
        audio: Option<MediaContent>,
        video: Option<MediaContent>,
        document: Option<MediaContent>,
    }

    #[derive(Debug, Deserialize)]
    struct TextContent {
        body: String,
    }

    #[derive(Debug, Deserialize)]
    struct MediaContent {
        id: String,
        caption: Option<String>,
        mime_type: Option<String>,
    }

    // -----------------------------------------------------------------------
    // WhatsApp Cloud API — outgoing payload shapes
    // -----------------------------------------------------------------------

    #[derive(Debug, Serialize)]
    struct SendTextPayload {
        messaging_product: &'static str,
        recipient_type: &'static str,
        to: String,
        #[serde(rename = "type")]
        msg_type: &'static str,
        text: TextBody,
    }

    #[derive(Debug, Serialize)]
    struct TextBody {
        preview_url: bool,
        body: String,
    }

    #[derive(Debug, Serialize)]
    struct SendImagePayload {
        messaging_product: &'static str,
        recipient_type: &'static str,
        to: String,
        #[serde(rename = "type")]
        msg_type: &'static str,
        image: ImageBody,
    }

    #[derive(Debug, Serialize)]
    struct ImageBody {
        link: String,
        caption: String,
    }

    // -----------------------------------------------------------------------
    // Webhook verification query params (GET /webhook)
    // -----------------------------------------------------------------------

    #[derive(Debug, Deserialize)]
    struct VerifyParams {
        #[serde(rename = "hub.mode")]
        mode: Option<String>,
        #[serde(rename = "hub.verify_token")]
        verify_token: Option<String>,
        #[serde(rename = "hub.challenge")]
        challenge: Option<String>,
    }

    // -----------------------------------------------------------------------
    // Main entry point
    // -----------------------------------------------------------------------

    pub async fn run_whatsapp_bridge(
        config: WhatsAppConfig,
        task_queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
        mut notify_rx: tokio::sync::broadcast::Receiver<SupervisorNotification>,
    ) {
        info!("Starting WhatsApp bridge on 127.0.0.1:8085...");

        let state = BridgeState {
            config: config.clone(),
            task_queue,
            router,
        };

        // Spawn notification forwarder — runs independently of the HTTP server.
        let notify_token = config.token.clone();
        let notify_phone_id = config.phone_id.clone();
        let notify_numbers = config.allowed_numbers.clone();
        tokio::spawn(async move {
            loop {
                match notify_rx.recv().await {
                    Ok(notification) => {
                        let text = format_notification(&notification);
                        for number in &notify_numbers {
                            if let Err(e) = send_whatsapp_message(
                                &notify_token,
                                &notify_phone_id,
                                number,
                                &text,
                            )
                            .await
                            {
                                error!("WhatsApp notification to {} failed: {}", number, e);
                            }
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        warn!("WhatsApp notifications lagged by {}", n);
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
        });

        // Build Axum router with shared state.
        let app = Router::new()
            .route("/webhook", get(handle_verify))
            .route("/webhook", post(handle_incoming))
            .with_state(state);

        let listener = match tokio::net::TcpListener::bind("127.0.0.1:8085").await {
            Ok(l) => l,
            Err(e) => {
                error!("WhatsApp bridge: failed to bind 127.0.0.1:8085: {}", e);
                return;
            }
        };

        info!("WhatsApp webhook listener ready on 127.0.0.1:8085/webhook");

        if let Err(e) = axum::serve(listener, app).await {
            error!("WhatsApp bridge server error: {}", e);
        }
    }

    // -----------------------------------------------------------------------
    // GET /webhook — Meta webhook verification handshake
    // -----------------------------------------------------------------------

    async fn handle_verify(
        State(state): State<BridgeState>,
        Query(params): Query<VerifyParams>,
    ) -> impl IntoResponse {
        let mode = params.mode.as_deref().unwrap_or("");
        let token = params.verify_token.as_deref().unwrap_or("");
        let challenge = params.challenge.as_deref().unwrap_or("").to_string();

        if mode == "subscribe" {
            let token_ok =
                state.config.verify_token.is_empty() || token == state.config.verify_token;
            if token_ok {
                info!("WhatsApp webhook verification succeeded");
                return (StatusCode::OK, challenge);
            } else {
                warn!("WhatsApp webhook verification failed: token mismatch");
                return (StatusCode::FORBIDDEN, "Forbidden".to_string());
            }
        }

        (StatusCode::BAD_REQUEST, "Bad Request".to_string())
    }

    // -----------------------------------------------------------------------
    // POST /webhook — incoming messages from Meta
    // -----------------------------------------------------------------------

    async fn handle_incoming(
        State(state): State<BridgeState>,
        Json(payload): Json<WebhookPayload>,
    ) -> StatusCode {
        let entries = match payload.entry {
            Some(e) => e,
            None => return StatusCode::OK,
        };

        for entry in entries {
            let changes = match entry.changes {
                Some(c) => c,
                None => continue,
            };
            for change in changes {
                let value = match change.value {
                    Some(v) => v,
                    None => continue,
                };
                let messages = match value.messages {
                    Some(m) => m,
                    None => continue,
                };
                for msg in messages {
                    // Auth check — reject numbers not in the allow-list.
                    if !state.config.allowed_numbers.is_empty()
                        && !state.config.allowed_numbers.contains(&msg.from)
                    {
                        warn!(
                            "WhatsApp: message from unauthorised number {}; ignoring",
                            msg.from
                        );
                        let token = state.config.token.clone();
                        let phone_id = state.config.phone_id.clone();
                        let from = msg.from.clone();
                        tokio::spawn(async move {
                            let _ =
                                send_whatsapp_message(&token, &phone_id, &from, "No autorizado.")
                                    .await;
                        });
                        continue;
                    }

                    let state_clone = state.clone();
                    let from = msg.from.clone();

                    match msg.msg_type.as_str() {
                        "text" => {
                            if let Some(text_content) = msg.text {
                                tokio::spawn(async move {
                                    handle_text_message(state_clone, from, text_content.body).await;
                                });
                            }
                        }
                        "image" => {
                            if let Some(image) = msg.image {
                                tokio::spawn(async move {
                                    handle_image_message(state_clone, from, image).await;
                                });
                            }
                        }
                        other => {
                            info!("WhatsApp: unhandled message type '{}' from {}", other, from);
                            let token = state.config.token.clone();
                            let phone_id = state.config.phone_id.clone();
                            tokio::spawn(async move {
                                let _ = send_whatsapp_message(
                                    &token,
                                    &phone_id,
                                    &from,
                                    "Acepto texto e imagenes.",
                                )
                                .await;
                            });
                        }
                    }
                }
            }
        }

        StatusCode::OK
    }

    // -----------------------------------------------------------------------
    // Text message handler
    // -----------------------------------------------------------------------

    async fn handle_text_message(state: BridgeState, from: String, text: String) {
        let trimmed = text.trim().to_string();
        if trimmed.is_empty() {
            return;
        }

        info!(
            "WhatsApp [{}]: {}",
            from,
            &trimmed[..trimmed.len().min(100)]
        );

        if trimmed.starts_with("/do ") || trimmed.starts_with("/task ") {
            let objective = trimmed
                .strip_prefix("/do ")
                .or_else(|| trimmed.strip_prefix("/task "))
                .unwrap_or(&trimmed)
                .to_string();
            handle_task(&state, &from, objective).await;
            return;
        }

        if trimmed.starts_with("/status") {
            handle_status(&state, &from).await;
            return;
        }

        if trimmed.starts_with("/help") || trimmed.starts_with("/start") {
            handle_help(&state, &from).await;
            return;
        }

        handle_chat(&state, &from, trimmed).await;
    }

    // -----------------------------------------------------------------------
    // Image message handler (vision)
    // -----------------------------------------------------------------------

    async fn handle_image_message(state: BridgeState, from: String, image: MediaContent) {
        info!("WhatsApp [{}]: image received (id={})", from, image.id);

        let caption = image
            .caption
            .as_deref()
            .unwrap_or("Describe esta imagen en español de forma concisa.")
            .to_string();

        // Download media bytes from Graph API.
        let img_bytes = match download_whatsapp_media(&state.config.token, &image.id).await {
            Ok(b) => b,
            Err(e) => {
                error!("WhatsApp: failed to download media {}: {}", image.id, e);
                let _ = send_whatsapp_message(
                    &state.config.token,
                    &state.config.phone_id,
                    &from,
                    "No pude descargar la imagen.",
                )
                .await;
                return;
            }
        };

        // Build a data URL for the vision model.
        let mime = image.mime_type.as_deref().unwrap_or("image/jpeg");
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&img_bytes);
        let data_url = format!("data:{};base64,{}", mime, b64);

        let request = RouterRequest {
            messages: vec![
                ChatMessage {
                    role: "system".into(),
                    content: serde_json::Value::String(
                        "Eres Axi, asistente visual de LifeOS. Describe y analiza imagenes en español de forma concisa.".into(),
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

        let reply = {
            let router = state.router.read().await;
            match router.chat(&request).await {
                Ok(r) => format!("{}\n\n[{}]", r.text, r.provider),
                Err(e) => format!("No pude analizar la imagen: {}", e),
            }
        };

        send_in_chunks(&state.config.token, &state.config.phone_id, &from, &reply).await;
    }

    // -----------------------------------------------------------------------
    // Command handlers
    // -----------------------------------------------------------------------

    async fn handle_task(state: &BridgeState, from: &str, objective: String) {
        match state.task_queue.enqueue(TaskCreate {
            objective: objective.clone(),
            priority: TaskPriority::Normal,
            source: "whatsapp".into(),
            max_attempts: 3,
        }) {
            Ok(task) => {
                let reply = format!(
                    "Tarea creada:\n{}\n\nID: {}\nTe avisare cuando termine.",
                    objective, task.id
                );
                let _ = send_whatsapp_message(
                    &state.config.token,
                    &state.config.phone_id,
                    from,
                    &reply,
                )
                .await;
            }
            Err(e) => {
                let reply = format!("Error al crear tarea: {}", e);
                let _ = send_whatsapp_message(
                    &state.config.token,
                    &state.config.phone_id,
                    from,
                    &reply,
                )
                .await;
            }
        }
    }

    async fn handle_status(state: &BridgeState, from: &str) {
        let summary = state.task_queue.summary().unwrap_or_default();
        let recent = state.task_queue.list(None, 5).unwrap_or_default();
        let mut reply = format!(
            "Estado de LifeOS:\n{}",
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
        send_in_chunks(&state.config.token, &state.config.phone_id, from, &reply).await;
    }

    async fn handle_help(state: &BridgeState, from: &str) {
        let text = "Soy Axi, tu asistente de LifeOS via WhatsApp.\n\n\
            Comandos:\n\
            /do <tarea> — Crear tarea para el supervisor\n\
            /task <tarea> — Igual que /do\n\
            /status — Ver estado de tareas\n\
            /help — Este mensaje\n\n\
            Tambien puedes:\n\
            - Enviar texto y te respondo\n\
            - Enviar una imagen y la analizo\n\n\
            Cuando una tarea termine, te aviso automaticamente.";
        let _ =
            send_whatsapp_message(&state.config.token, &state.config.phone_id, from, text).await;
    }

    async fn handle_chat(state: &BridgeState, from: &str, text: String) {
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
                    content: serde_json::Value::String(text),
                },
            ],
            complexity: Some(TaskComplexity::Medium),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(1024),
        };

        let reply = {
            let router = state.router.read().await;
            match router.chat(&request).await {
                Ok(r) => format!("{}\n\n[{}]", r.text, r.provider),
                Err(e) => format!("Error: {}", e),
            }
        };

        send_in_chunks(&state.config.token, &state.config.phone_id, from, &reply).await;
    }

    // -----------------------------------------------------------------------
    // Graph API helpers — public so callers can send messages/images directly
    // -----------------------------------------------------------------------

    /// Send a plain text message via WhatsApp Cloud API (Graph v19).
    pub async fn send_whatsapp_message(
        token: &str,
        phone_id: &str,
        to: &str,
        text: &str,
    ) -> Result<(), String> {
        let client = reqwest::Client::new();
        let url = format!("https://graph.facebook.com/v19.0/{}/messages", phone_id);
        let payload = SendTextPayload {
            messaging_product: "whatsapp",
            recipient_type: "individual",
            to: to.to_string(),
            msg_type: "text",
            text: TextBody {
                preview_url: false,
                body: text.to_string(),
            },
        };

        let res = client
            .post(&url)
            .bearer_auth(token)
            .json(&payload)
            .send()
            .await
            .map_err(|e| format!("HTTP error: {}", e))?;

        if res.status().is_success() {
            Ok(())
        } else {
            let status = res.status();
            let body = res.text().await.unwrap_or_default();
            Err(format!("Graph API {} — {}", status, body))
        }
    }

    /// Send an image (by public URL) with an optional caption.
    pub async fn send_whatsapp_image(
        token: &str,
        phone_id: &str,
        to: &str,
        image_url: &str,
        caption: &str,
    ) -> Result<(), String> {
        let client = reqwest::Client::new();
        let url = format!("https://graph.facebook.com/v19.0/{}/messages", phone_id);
        let payload = SendImagePayload {
            messaging_product: "whatsapp",
            recipient_type: "individual",
            to: to.to_string(),
            msg_type: "image",
            image: ImageBody {
                link: image_url.to_string(),
                caption: caption.to_string(),
            },
        };

        let res = client
            .post(&url)
            .bearer_auth(token)
            .json(&payload)
            .send()
            .await
            .map_err(|e| format!("HTTP error: {}", e))?;

        if res.status().is_success() {
            Ok(())
        } else {
            let status = res.status();
            let body = res.text().await.unwrap_or_default();
            Err(format!("Graph API {} — {}", status, body))
        }
    }

    /// Download raw bytes for an incoming WhatsApp media object.
    ///
    /// Step 1 — resolve the temporary download URL via the media ID endpoint.
    /// Step 2 — fetch the bytes from that URL (also requires the bearer token).
    pub async fn download_whatsapp_media(token: &str, media_id: &str) -> Result<Vec<u8>, String> {
        let client = reqwest::Client::new();

        // Step 1 — resolve media URL.
        let meta_url = format!("https://graph.facebook.com/v19.0/{}", media_id);
        let meta_res = client
            .get(&meta_url)
            .bearer_auth(token)
            .send()
            .await
            .map_err(|e| format!("Media metadata request failed: {}", e))?;

        if !meta_res.status().is_success() {
            let status = meta_res.status();
            let body = meta_res.text().await.unwrap_or_default();
            return Err(format!("Media metadata {} — {}", status, body));
        }

        let meta: serde_json::Value = meta_res
            .json()
            .await
            .map_err(|e| format!("Media metadata JSON parse error: {}", e))?;

        let download_url = meta["url"]
            .as_str()
            .ok_or_else(|| "Media metadata response missing 'url' field".to_string())?
            .to_string();

        // Step 2 — download bytes.
        let bytes_res = client
            .get(&download_url)
            .bearer_auth(token)
            .send()
            .await
            .map_err(|e| format!("Media download request failed: {}", e))?;

        if !bytes_res.status().is_success() {
            let status = bytes_res.status();
            let body = bytes_res.text().await.unwrap_or_default();
            return Err(format!("Media download {} — {}", status, body));
        }

        bytes_res
            .bytes()
            .await
            .map(|b| b.to_vec())
            .map_err(|e| format!("Reading media bytes failed: {}", e))
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// Split long replies into chunks of at most 4 096 bytes, respecting UTF-8
    /// character boundaries, and send each chunk as a separate message.
    async fn send_in_chunks(token: &str, phone_id: &str, to: &str, text: &str) {
        const MAX_BYTES: usize = 4096;
        if text.len() <= MAX_BYTES {
            if let Err(e) = send_whatsapp_message(token, phone_id, to, text).await {
                error!("WhatsApp send to {} failed: {}", to, e);
            }
            return;
        }
        let mut start = 0;
        while start < text.len() {
            let mut end = (start + MAX_BYTES).min(text.len());
            while end > start && !text.is_char_boundary(end) {
                end -= 1;
            }
            let chunk = &text[start..end];
            if let Err(e) = send_whatsapp_message(token, phone_id, to, chunk).await {
                error!("WhatsApp send chunk to {} failed: {}", to, e);
                break;
            }
            start = end;
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
                    "Aprobacion requerida:\n{}
            SupervisorNotification::TaskProgress {
                step_index,
                steps_total,
                description,
                ..
            } => {
                format!("Paso {}/{}: {}", step_index + 1, steps_total, &description[..description.len().min(200)])
            }\n\nResponde /do approve:<id> para aprobar.",
                    truncate(action_description, 500)
                )
            }
        }
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

#[cfg(feature = "whatsapp")]
pub use inner::*;

// ---------------------------------------------------------------------------
// No-feature stub — keeps call sites compiling when the whatsapp feature is
// not enabled.
// ---------------------------------------------------------------------------

#[cfg(not(feature = "whatsapp"))]
pub mod stub {
    pub struct WhatsAppConfig;

    impl WhatsAppConfig {
        pub fn from_env() -> Option<Self> {
            None
        }
    }

    pub async fn run_whatsapp_bridge(
        _config: WhatsAppConfig,
        _tq: std::sync::Arc<crate::task_queue::TaskQueue>,
        _router: std::sync::Arc<tokio::sync::RwLock<crate::llm_router::LlmRouter>>,
        _notify_rx: tokio::sync::broadcast::Receiver<crate::supervisor::SupervisorNotification>,
    ) {
    }
}
