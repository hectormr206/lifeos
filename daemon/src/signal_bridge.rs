//! Signal bridge — Bidirectional communication with LifeOS via Signal messenger.
//!
//! Uses signal-cli's JSON-RPC HTTP daemon interface. signal-cli must be running
//! separately as: `signal-cli -u {phone} daemon --http localhost:8086`
//!
//! Supports: text messages, image attachments, push notifications, /do commands.

#[cfg(feature = "signal")]
mod inner {
    use log::{error, info, warn};
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::sync::RwLock;

    use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest, TaskComplexity};
    use crate::supervisor::SupervisorNotification;
    use crate::task_queue::{TaskCreate, TaskPriority, TaskQueue};

    // ---------------------------------------------------------------------------
    // Config
    // ---------------------------------------------------------------------------

    #[derive(Debug, Clone)]
    pub struct SignalConfig {
        /// Base URL of the signal-cli HTTP daemon (default: http://127.0.0.1:8086)
        pub cli_url: String,
        /// Registered phone number in E.164 format (e.g. +1234567890)
        pub phone: String,
        /// Numbers allowed to interact with the bridge
        pub allowed_numbers: Vec<String>,
    }

    impl SignalConfig {
        pub fn from_env() -> Option<Self> {
            let phone = std::env::var("LIFEOS_SIGNAL_PHONE").ok()?;
            if phone.is_empty() {
                return None;
            }
            let cli_url = std::env::var("LIFEOS_SIGNAL_CLI_URL")
                .unwrap_or_else(|_| "http://127.0.0.1:8086".into());
            let allowed_numbers: Vec<String> = std::env::var("LIFEOS_SIGNAL_ALLOWED_NUMBERS")
                .unwrap_or_default()
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            Some(Self {
                cli_url,
                phone,
                allowed_numbers,
            })
        }
    }

    // ---------------------------------------------------------------------------
    // signal-cli JSON-RPC types
    // ---------------------------------------------------------------------------

    /// Envelope returned by the receive endpoint.
    #[derive(Debug, serde::Deserialize)]
    pub struct SignalEnvelope {
        #[serde(default)]
        envelope: EnvelopeInner,
    }

    #[derive(Debug, Default, serde::Deserialize)]
    struct EnvelopeInner {
        #[serde(default)]
        source: String,
        #[serde(rename = "sourceNumber", default)]
        source_number: String,
        #[serde(rename = "dataMessage")]
        data_message: Option<DataMessage>,
    }

    #[derive(Debug, serde::Deserialize)]
    struct DataMessage {
        #[serde(default)]
        message: Option<String>,
        #[serde(default)]
        timestamp: u64,
        #[serde(default)]
        attachments: Vec<SignalAttachment>,
    }

    #[derive(Debug, serde::Deserialize)]
    struct SignalAttachment {
        #[serde(rename = "contentType", default)]
        content_type: String,
        #[serde(default)]
        filename: Option<String>,
        /// Local path on the machine running signal-cli
        #[serde(default)]
        id: String,
    }

    // ---------------------------------------------------------------------------
    // Public entrypoint
    // ---------------------------------------------------------------------------

    pub async fn run_signal_bridge(
        config: SignalConfig,
        task_queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
        mut notify_rx: tokio::sync::broadcast::Receiver<SupervisorNotification>,
    ) {
        info!(
            "Starting Signal bridge (phone: {}, cli: {})",
            config.phone, config.cli_url
        );

        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("Failed to build HTTP client for Signal bridge");

        let config = Arc::new(config);
        let notify_config = config.clone();
        let notify_http = http.clone();

        // ---- Notification forwarder ----
        tokio::spawn(async move {
            loop {
                match notify_rx.recv().await {
                    Ok(notification) => {
                        let text = format_notification(&notification);
                        for number in &notify_config.allowed_numbers {
                            if let Err(e) =
                                send_signal_message(&notify_config, &notify_http, number, &text)
                                    .await
                            {
                                error!("Signal notification to {} failed: {}", number, e);
                            }
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        warn!("Signal notifications lagged by {} messages", n);
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
        });

        // ---- Message receive loop ----
        loop {
            match receive_signal_messages(&config, &http).await {
                Ok(envelopes) => {
                    for env in envelopes {
                        let inner = &env.envelope;

                        // Determine sender — prefer sourceNumber, fall back to source
                        let sender = if !inner.source_number.is_empty() {
                            inner.source_number.clone()
                        } else {
                            inner.source.clone()
                        };

                        if sender.is_empty() {
                            continue;
                        }

                        let data = match &inner.data_message {
                            Some(d) => d,
                            None => continue,
                        };

                        // Auth check
                        if !config.allowed_numbers.is_empty()
                            && !config.allowed_numbers.contains(&sender)
                        {
                            warn!(
                                "Signal: rejected message from unauthorized number {}",
                                sender
                            );
                            if let Err(e) =
                                send_signal_message(&config, &http, &sender, "No autorizado.").await
                            {
                                error!("Signal: failed to send rejection to {}: {}", sender, e);
                            }
                            continue;
                        }

                        // React with "eyes" to acknowledge receipt
                        if data.timestamp > 0 {
                            let _ = send_signal_reaction(
                                &config,
                                &http,
                                &sender,
                                "\u{1F440}", // 👀
                                data.timestamp,
                            )
                            .await;
                        }

                        // Handle image attachments
                        if !data.attachments.is_empty() {
                            let caption = data
                                .message
                                .clone()
                                .unwrap_or_else(|| "Describe esta imagen en español.".into());
                            for attachment in &data.attachments {
                                if attachment.content_type.starts_with("image/") {
                                    handle_image_attachment(
                                        &config, &http, &sender, attachment, &caption, &router,
                                    )
                                    .await;
                                }
                            }
                            continue;
                        }

                        // Handle text message
                        let text = match &data.message {
                            Some(t) if !t.is_empty() => t.clone(),
                            _ => continue,
                        };

                        info!("Signal [{}]: {}", sender, &text[..text.len().min(100)]);

                        if text.starts_with("/do ") || text.starts_with("/task ") {
                            let objective = text
                                .strip_prefix("/do ")
                                .or_else(|| text.strip_prefix("/task "))
                                .unwrap_or(&text)
                                .to_string();
                            handle_task(&config, &http, &sender, objective, &task_queue).await;
                        } else if text.starts_with("/status") {
                            handle_status(&config, &http, &sender, &task_queue).await;
                        } else if text.starts_with("/help") || text == "/start" {
                            handle_help(&config, &http, &sender).await;
                        } else {
                            handle_chat(&config, &http, &sender, &text, &router).await;
                        }
                    }
                }
                Err(e) => {
                    error!("Signal receive error: {}", e);
                }
            }

            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }

    // ---------------------------------------------------------------------------
    // Message handlers
    // ---------------------------------------------------------------------------

    async fn handle_task(
        config: &SignalConfig,
        http: &reqwest::Client,
        sender: &str,
        objective: String,
        task_queue: &Arc<TaskQueue>,
    ) {
        match task_queue.enqueue(TaskCreate {
            objective: objective.clone(),
            priority: TaskPriority::Normal,
            source: "signal".into(),
            max_attempts: 3,
        }) {
            Ok(task) => {
                let reply = format!(
                    "Tarea creada:\n{}\n\nID: {}\nTe avisare cuando termine.",
                    objective, task.id
                );
                if let Err(e) = send_signal_message(config, http, sender, &reply).await {
                    error!(
                        "Signal: failed to confirm task creation to {}: {}",
                        sender, e
                    );
                }
            }
            Err(e) => {
                let reply = format!("Error al crear tarea: {}", e);
                if let Err(e) = send_signal_message(config, http, sender, &reply).await {
                    error!("Signal: failed to send error to {}: {}", sender, e);
                }
            }
        }
    }

    async fn handle_status(
        config: &SignalConfig,
        http: &reqwest::Client,
        sender: &str,
        task_queue: &Arc<TaskQueue>,
    ) {
        let summary = task_queue.summary().unwrap_or_default();
        let recent = task_queue.list(None, 5).unwrap_or_default();
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
        if let Err(e) = send_signal_message(config, http, sender, &reply).await {
            error!("Signal: failed to send status to {}: {}", sender, e);
        }
    }

    async fn handle_help(config: &SignalConfig, http: &reqwest::Client, sender: &str) {
        let help = "Soy Axi, tu asistente de LifeOS via Signal.\n\n\
             Comandos:\n\
             /do <tarea> — Crear tarea para el supervisor\n\
             /task <tarea> — Igual que /do\n\
             /status — Ver estado de tareas\n\
             /help — Este mensaje\n\n\
             Tambien puedes:\n\
             - Enviar texto y te respondo con IA\n\
             - Enviar imagen y la analizo\n\n\
             Cuando una tarea termine, te aviso automaticamente.";
        if let Err(e) = send_signal_message(config, http, sender, help).await {
            error!("Signal: failed to send help to {}: {}", sender, e);
        }
    }

    async fn handle_chat(
        config: &SignalConfig,
        http: &reqwest::Client,
        sender: &str,
        text: &str,
        router: &Arc<RwLock<LlmRouter>>,
    ) {
        let reply = chat_with_llm(router, text).await;
        for chunk in split_message(&reply, 1000) {
            if let Err(e) = send_signal_message(config, http, sender, chunk).await {
                error!("Signal: failed to send chat reply to {}: {}", sender, e);
                break;
            }
        }
    }

    async fn handle_image_attachment(
        config: &SignalConfig,
        http: &reqwest::Client,
        sender: &str,
        attachment: &SignalAttachment,
        caption: &str,
        router: &Arc<RwLock<LlmRouter>>,
    ) {
        info!(
            "Signal [{}]: image attachment received (id: {})",
            sender, attachment.id
        );

        // signal-cli stores attachments under its data directory
        // The `id` field is the local filename/path signal-cli provides
        let attachment_path = if attachment.id.starts_with('/') {
            PathBuf::from(&attachment.id)
        } else {
            // Default signal-cli attachments dir
            let home = std::env::var("HOME").unwrap_or_else(|_| "/root".into());
            PathBuf::from(format!(
                "{}/.local/share/signal-cli/attachments/{}",
                home, attachment.id
            ))
        };

        // Determine content type for the data URL
        let mime = if attachment.content_type.is_empty() {
            "image/jpeg"
        } else {
            attachment.content_type.as_str()
        };

        let img_bytes = match tokio::fs::read(&attachment_path).await {
            Ok(b) => b,
            Err(e) => {
                warn!(
                    "Signal: could not read attachment at {}: {}",
                    attachment_path.display(),
                    e
                );
                if let Err(e) =
                    send_signal_message(config, http, sender, "No pude leer el archivo adjunto.")
                        .await
                {
                    error!(
                        "Signal: failed to send attachment error to {}: {}",
                        sender, e
                    );
                }
                return;
            }
        };

        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&img_bytes);
        let data_url = format!("data:{};base64,{}", mime, b64);

        let request = RouterRequest {
            messages: vec![
                ChatMessage {
                    role: "system".into(),
                    content: serde_json::Value::String(
                        "Eres Axi, asistente visual de LifeOS. Describe y analiza imagenes en español de forma concisa."
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

        let reply = {
            let router_guard = router.read().await;
            match router_guard.chat(&request).await {
                Ok(r) => format!("{}\n\n[{}]", r.text, r.provider),
                Err(e) => format!("No pude analizar la imagen: {}", e),
            }
        };

        for chunk in split_message(&reply, 1000) {
            if let Err(e) = send_signal_message(config, http, sender, chunk).await {
                error!("Signal: failed to send image analysis to {}: {}", sender, e);
                break;
            }
        }
    }

    // ---------------------------------------------------------------------------
    // signal-cli HTTP JSON-RPC helpers
    // ---------------------------------------------------------------------------

    /// Send a text message via signal-cli daemon.
    pub async fn send_signal_message(
        config: &SignalConfig,
        http: &reqwest::Client,
        to: &str,
        text: &str,
    ) -> Result<(), anyhow::Error> {
        let url = format!("{}/api/v1/send", config.cli_url);
        let body = serde_json::json!({
            "message": text,
            "number": config.phone,
            "recipients": [to],
        });

        let resp = http
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("signal-cli send HTTP error: {}", e))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(anyhow::anyhow!(
                "signal-cli send failed ({}): {}",
                status,
                body
            ));
        }

        Ok(())
    }

    /// Send a reaction emoji to a specific message identified by its timestamp.
    pub async fn send_signal_reaction(
        config: &SignalConfig,
        http: &reqwest::Client,
        to: &str,
        emoji: &str,
        target_timestamp: u64,
    ) -> Result<(), anyhow::Error> {
        let url = format!("{}/api/v1/reactions/{}", config.cli_url, config.phone);
        let body = serde_json::json!({
            "reaction": emoji,
            "recipient": to,
            "target_author": to,
            "timestamp": target_timestamp,
        });

        let resp = http
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("signal-cli reaction HTTP error: {}", e))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(anyhow::anyhow!(
                "signal-cli reaction failed ({}): {}",
                status,
                body
            ));
        }

        Ok(())
    }

    /// Fetch all pending incoming messages from signal-cli daemon.
    pub async fn receive_signal_messages(
        config: &SignalConfig,
        http: &reqwest::Client,
    ) -> Result<Vec<SignalEnvelope>, anyhow::Error> {
        let url = format!("{}/api/v1/receive/{}", config.cli_url, config.phone);

        let resp = http
            .get(&url)
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("signal-cli receive HTTP error: {}", e))?;

        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            // No messages pending — not an error
            return Ok(vec![]);
        }

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(anyhow::anyhow!(
                "signal-cli receive failed ({}): {}",
                status,
                body
            ));
        }

        let text = resp
            .text()
            .await
            .map_err(|e| anyhow::anyhow!("signal-cli receive read error: {}", e))?;

        if text.trim().is_empty() {
            return Ok(vec![]);
        }

        // signal-cli returns one JSON object per line (NDJSON) or a JSON array
        let envelopes: Vec<SignalEnvelope> = if text.trim_start().starts_with('[') {
            serde_json::from_str(&text)
                .map_err(|e| anyhow::anyhow!("signal-cli receive JSON parse error: {}", e))?
        } else {
            text.lines()
                .filter(|l| !l.trim().is_empty())
                .filter_map(|line| {
                    serde_json::from_str::<SignalEnvelope>(line)
                        .map_err(|e| {
                            warn!("Signal: could not parse envelope line: {} — {}", line, e);
                        })
                        .ok()
                })
                .collect()
        };

        Ok(envelopes)
    }

    // ---------------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------------

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

        let router_guard = router.read().await;
        match router_guard.chat(&request).await {
            Ok(r) => format!("{}\n\n[{}]", r.text, r.provider),
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
                    truncate(result, 800),
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
                    truncate(error, 400),
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
            }\n\nResponde con /do [approve|reject] para proceder.",
                    truncate(action_description, 400)
                )
            }
        }
    }

    /// Split a long string into chunks no larger than `max_bytes`.
    /// Splits on char boundaries to avoid corrupting UTF-8.
    fn split_message(text: &str, max_bytes: usize) -> Vec<&str> {
        let mut chunks = Vec::new();
        let mut start = 0;
        while start < text.len() {
            let end = (start + max_bytes).min(text.len());
            // Walk back to a char boundary
            let mut end = end;
            while end > start && !text.is_char_boundary(end) {
                end -= 1;
            }
            if end == start {
                // Degenerate: just advance one byte to avoid infinite loop
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

#[cfg(feature = "signal")]
pub use inner::*;

// ---------------------------------------------------------------------------
// Stub — when the "signal" feature is not enabled
// ---------------------------------------------------------------------------

#[cfg(not(feature = "signal"))]
pub mod stub {
    pub struct SignalConfig;

    impl SignalConfig {
        pub fn from_env() -> Option<Self> {
            None
        }
    }

    pub async fn run_signal_bridge(
        _config: SignalConfig,
        _tq: std::sync::Arc<crate::task_queue::TaskQueue>,
        _router: std::sync::Arc<tokio::sync::RwLock<crate::llm_router::LlmRouter>>,
        _notify_rx: tokio::sync::broadcast::Receiver<crate::supervisor::SupervisorNotification>,
    ) {
    }
}
