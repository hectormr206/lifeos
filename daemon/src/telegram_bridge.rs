//! Telegram bridge — Bidirectional multimedia communication with LifeOS.
//!
//! Supports: text, voice (STT+TTS), photos (vision), groups, push notifications.

#[cfg(feature = "telegram")]
mod inner {
    use log::{error, info, warn};
    use std::path::PathBuf;
    use std::sync::Arc;
    use teloxide::net::Download;
    use teloxide::prelude::*;
    use teloxide::types::{
        ChatAction, InlineKeyboardButton, InlineKeyboardMarkup, InputFile, MediaKind, MessageKind,
    };
    use tokio::sync::RwLock;

    use crate::llm_router::{ChatMessage, LlmRouter, RouterRequest, TaskComplexity};
    use crate::supervisor::SupervisorNotification;
    use crate::task_queue::{TaskCreate, TaskPriority, TaskQueue};

    #[derive(Debug, Clone)]
    pub struct TelegramConfig {
        pub bot_token: String,
        pub allowed_chat_ids: Vec<i64>,
    }

    impl TelegramConfig {
        pub fn from_env() -> Option<Self> {
            let token = std::env::var("LIFEOS_TELEGRAM_BOT_TOKEN").ok()?;
            if token.is_empty() {
                return None;
            }
            let allowed: Vec<i64> = std::env::var("LIFEOS_TELEGRAM_CHAT_ID")
                .unwrap_or_default()
                .split(',')
                .filter_map(|s| s.trim().parse().ok())
                .collect();
            Some(Self {
                bot_token: token,
                allowed_chat_ids: allowed,
            })
        }
    }

    #[derive(Clone)]
    struct BotCtx {
        task_queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
        allowed_ids: Vec<i64>,
        bot_username: String,
    }

    pub async fn run_telegram_bot(
        config: TelegramConfig,
        task_queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
        mut notify_rx: tokio::sync::broadcast::Receiver<SupervisorNotification>,
    ) {
        info!("Starting Telegram bridge...");

        let bot = Bot::new(&config.bot_token);
        let notify_bot = bot.clone();
        let notify_chat_ids = config.allowed_chat_ids.clone();

        // Get bot username for group mention detection
        let bot_username = bot
            .get_me()
            .await
            .map(|me| me.username.clone().unwrap_or_default())
            .unwrap_or_default();
        info!("Telegram bot username: @{}", bot_username);

        // Notification listener
        tokio::spawn(async move {
            loop {
                match notify_rx.recv().await {
                    Ok(notification) => {
                        let text = format_notification(&notification);
                        for &chat_id in &notify_chat_ids {
                            if let Err(e) = notify_bot.send_message(ChatId(chat_id), &text).await {
                                error!("Telegram notification failed: {}", e);
                            }
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        warn!("Telegram notifications lagged by {}", n);
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
        });

        let ctx = BotCtx {
            task_queue,
            router,
            allowed_ids: config.allowed_chat_ids,
            bot_username,
        };

        let message_handler =
            Update::filter_message().endpoint(|bot: Bot, msg: Message, ctx: BotCtx| async move {
                handle_message(bot, msg, ctx).await
            });

        let callback_handler =
            Update::filter_callback_query().endpoint(
                |bot: Bot, q: CallbackQuery, ctx: BotCtx| async move {
                    handle_callback(bot, q, ctx).await
                },
            );

        let handler = dptree::entry()
            .branch(message_handler)
            .branch(callback_handler);

        Dispatcher::builder(bot, handler)
            .dependencies(dptree::deps![ctx])
            .enable_ctrlc_handler()
            .build()
            .dispatch()
            .await;
    }

    async fn handle_message(
        bot: Bot,
        msg: Message,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let chat_id = msg.chat.id;
        let is_group = msg.chat.is_group() || msg.chat.is_supergroup();

        // Auth check — in groups, only respond if mentioned or command
        if is_group {
            let dominated = is_addressed_to_bot(&msg, &ctx.bot_username);
            if !dominated {
                return Ok(()); // silently ignore non-addressed group messages
            }
        } else if !ctx.allowed_ids.is_empty() && !ctx.allowed_ids.contains(&chat_id.0) {
            bot.send_message(chat_id, "No autorizado.").await?;
            return Ok(());
        }

        // Dispatch by message content type
        if let Some(voice) = msg.voice() {
            return handle_voice(bot, msg.clone(), chat_id, voice.file.id.clone(), ctx).await;
        }

        if let Some(photo_sizes) = largest_photo(&msg) {
            let caption = msg
                .caption()
                .map(|s| s.to_string())
                .unwrap_or_else(|| "Describe esta imagen en español.".into());
            return handle_photo(bot, chat_id, photo_sizes, &caption, ctx).await;
        }

        let text = match msg.text() {
            Some(t) => {
                let mut t = t.to_string();
                // Strip bot mention from group messages
                if is_group {
                    t = t
                        .replace(&format!("@{}", ctx.bot_username), "")
                        .trim()
                        .to_string();
                }
                t
            }
            None => {
                bot.send_message(chat_id, "Acepto texto, voz y fotos.")
                    .await?;
                return Ok(());
            }
        };

        if text.is_empty() {
            return Ok(());
        }

        info!("Telegram [{}]: {}", chat_id, &text[..text.len().min(100)]);

        // Commands
        if text.starts_with("/task ") || text.starts_with("/do ") {
            let objective = text
                .strip_prefix("/task ")
                .or_else(|| text.strip_prefix("/do "))
                .unwrap_or(&text)
                .to_string();
            return handle_task(bot, chat_id, objective, ctx).await;
        }
        if text.starts_with("/status") {
            return handle_status(bot, chat_id, ctx).await;
        }
        if text.starts_with("/help") || text.starts_with("/start") {
            return handle_help(bot, chat_id).await;
        }
        if text.starts_with("/screenshot") || text.starts_with("/captura") {
            return handle_screenshot(bot, chat_id).await;
        }
        if text.starts_with("/search ") {
            let query = text.strip_prefix("/search ").unwrap_or("").to_string();
            return handle_search(bot, chat_id, query, ctx).await;
        }

        // Default: chat
        handle_chat(bot, chat_id, text, ctx).await
    }

    // ---- Voice handling ----

    async fn handle_voice(
        bot: Bot,
        _msg: Message,
        chat_id: ChatId,
        file_id: String,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        info!("Telegram [{}]: voice message received", chat_id);
        bot.send_chat_action(chat_id, ChatAction::Typing).await.ok();

        // Download voice file
        let file = bot.get_file(&file_id).await?;
        let tmp_dir = std::env::temp_dir().join("lifeos-telegram");
        tokio::fs::create_dir_all(&tmp_dir).await.ok();
        let ogg_path = tmp_dir.join(format!("voice-{}.ogg", chrono::Utc::now().timestamp()));
        let mut ogg_file = tokio::fs::File::create(&ogg_path).await?;
        bot.download_file(&file.path, &mut ogg_file).await?;

        // Convert OGG to WAV for Whisper
        let wav_path = ogg_path.with_extension("wav");
        let ffmpeg = tokio::process::Command::new("ffmpeg")
            .args([
                "-i",
                &ogg_path.to_string_lossy(),
                "-ar",
                "16000",
                "-ac",
                "1",
                "-y",
                &wav_path.to_string_lossy(),
            ])
            .output()
            .await;

        let transcription = if ffmpeg.map(|o| o.status.success()).unwrap_or(false) {
            // Run Whisper STT
            let output = tokio::process::Command::new("whisper-cli")
                .args([
                    "-m",
                    "/var/lib/lifeos/models/whisper/ggml-base.bin",
                    "-f",
                    &wav_path.to_string_lossy(),
                    "--no-timestamps",
                    "-l",
                    "es",
                ])
                .output()
                .await;

            match output {
                Ok(o) if o.status.success() => {
                    String::from_utf8_lossy(&o.stdout).trim().to_string()
                }
                _ => {
                    bot.send_message(chat_id, "No pude transcribir el audio.")
                        .await?;
                    return Ok(());
                }
            }
        } else {
            bot.send_message(
                chat_id,
                "No pude convertir el audio (ffmpeg no disponible).",
            )
            .await?;
            return Ok(());
        };

        // Cleanup temp files
        tokio::fs::remove_file(&ogg_path).await.ok();
        tokio::fs::remove_file(&wav_path).await.ok();

        if transcription.is_empty() {
            bot.send_message(chat_id, "(Audio vacio o no se entendio)")
                .await?;
            return Ok(());
        }

        info!(
            "Telegram voice transcribed: {}",
            &transcription[..transcription.len().min(80)]
        );

        // Process transcription through LLM
        let response_text = chat_with_llm(&ctx, &transcription).await;

        // Try to respond with audio via Piper TTS
        if let Some(audio_path) = text_to_voice(&response_text).await {
            bot.send_voice(chat_id, InputFile::file(&audio_path))
                .await
                .ok();
            // Also send as text for readability
            bot.send_message(
                chat_id,
                format!(
                    "{}\n\n(transcripcion de tu voz: {})",
                    &response_text[..response_text.len().min(3500)],
                    &transcription[..transcription.len().min(200)]
                ),
            )
            .await?;
            tokio::fs::remove_file(&audio_path).await.ok();
        } else {
            // Fallback: text only
            bot.send_message(
                chat_id,
                format!(
                    "(Tu dijiste: {})\n\n{}",
                    &transcription[..transcription.len().min(200)],
                    &response_text[..response_text.len().min(3500)]
                ),
            )
            .await?;
        }

        Ok(())
    }

    // ---- Photo handling ----

    async fn handle_photo(
        bot: Bot,
        chat_id: ChatId,
        file_id: String,
        caption: &str,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        info!("Telegram [{}]: photo received", chat_id);
        bot.send_chat_action(chat_id, ChatAction::Typing).await.ok();

        // Download photo
        let file = bot.get_file(&file_id).await?;
        let tmp_dir = std::env::temp_dir().join("lifeos-telegram");
        tokio::fs::create_dir_all(&tmp_dir).await.ok();
        let img_path = tmp_dir.join(format!("photo-{}.jpg", chrono::Utc::now().timestamp()));
        let mut img_file = tokio::fs::File::create(&img_path).await?;
        bot.download_file(&file.path, &mut img_file).await?;

        // Encode to base64 for LLM vision
        let img_bytes = tokio::fs::read(&img_path).await?;
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&img_bytes);
        let data_url = format!("data:image/jpeg;base64,{}", b64);

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

        let router = ctx.router.read().await;
        let reply = match router.chat(&request).await {
            Ok(r) => format!("{}\n\n[{}]", r.text, r.provider),
            Err(e) => format!("No pude analizar la imagen: {}", e),
        };

        tokio::fs::remove_file(&img_path).await.ok();

        for chunk in reply.as_bytes().chunks(4000) {
            bot.send_message(chat_id, String::from_utf8_lossy(chunk).to_string())
                .await?;
        }

        Ok(())
    }

    // ---- Search ----

    async fn handle_search(
        bot: Bot,
        chat_id: ChatId,
        query: String,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        info!("Telegram [{}]: /search {}", chat_id, query);
        bot.send_chat_action(chat_id, ChatAction::Typing).await.ok();

        // Use Serper if available, otherwise use LLM with search instruction
        let serper_key = std::env::var("SERPER_API_KEY").unwrap_or_default();

        let search_results = if !serper_key.is_empty() {
            // Direct Serper search
            let client = reqwest::Client::new();
            let res = client
                .post("https://google.serper.dev/search")
                .header("X-API-KEY", &serper_key)
                .json(&serde_json::json!({"q": query, "num": 5}))
                .send()
                .await;

            match res {
                Ok(r) if r.status().is_success() => {
                    let body: serde_json::Value = r.json().await.unwrap_or_default();
                    let organic = body["organic"]
                        .as_array()
                        .map(|arr| {
                            arr.iter()
                                .take(5)
                                .map(|item| {
                                    format!(
                                        "- {} ({})\n  {}",
                                        item["title"].as_str().unwrap_or(""),
                                        item["link"].as_str().unwrap_or(""),
                                        item["snippet"].as_str().unwrap_or("")
                                    )
                                })
                                .collect::<Vec<_>>()
                                .join("\n")
                        })
                        .unwrap_or_else(|| "Sin resultados".into());
                    format!("Resultados para '{}':\n\n{}", query, organic)
                }
                _ => "Error en busqueda Serper".into(),
            }
        } else {
            // Fallback: ask LLM to search (works if Groq compound is available)
            chat_with_llm(
                &ctx,
                &format!(
                    "Busca en internet informacion actualizada sobre: {}. Dame los resultados mas relevantes.",
                    query
                ),
            )
            .await
        };

        for chunk in search_results.as_bytes().chunks(4000) {
            bot.send_message(chat_id, String::from_utf8_lossy(chunk).to_string())
                .await?;
        }
        Ok(())
    }

    // ---- Task, Status, Help, Chat handlers ----

    async fn handle_screenshot(
        bot: Bot,
        chat_id: ChatId,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        info!("Telegram [{}]: screenshot requested", chat_id);
        bot.send_chat_action(chat_id, ChatAction::UploadPhoto)
            .await
            .ok();

        let tmp_dir = std::env::temp_dir().join("lifeos-telegram");
        tokio::fs::create_dir_all(&tmp_dir).await.ok();
        let path = tmp_dir.join(format!("screen-{}.png", chrono::Utc::now().timestamp()));

        let output = tokio::process::Command::new("grim")
            .arg(&path)
            .output()
            .await;

        let captured = match output {
            Ok(o) if o.status.success() => true,
            _ => {
                // Fallback
                tokio::process::Command::new("gnome-screenshot")
                    .args(["-f", &path.to_string_lossy()])
                    .output()
                    .await
                    .map(|o| o.status.success())
                    .unwrap_or(false)
            }
        };

        if captured && path.exists() {
            bot.send_photo(chat_id, InputFile::file(&path)).await?;
            tokio::fs::remove_file(&path).await.ok();
        } else {
            bot.send_message(chat_id, "No pude capturar la pantalla.")
                .await?;
        }
        Ok(())
    }

    async fn handle_task(
        bot: Bot,
        chat_id: ChatId,
        objective: String,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        match ctx.task_queue.enqueue(TaskCreate {
            objective: objective.clone(),
            priority: TaskPriority::Normal,
            source: "telegram".into(),
            max_attempts: 3,
        }) {
            Ok(task) => {
                bot.send_message(
                    chat_id,
                    format!(
                        "Tarea creada:\n{}\n\nID: {}\nTe avisare cuando termine.",
                        objective, task.id
                    ),
                )
                .await?;
            }
            Err(e) => {
                bot.send_message(chat_id, format!("Error: {}", e)).await?;
            }
        }
        Ok(())
    }

    async fn handle_status(
        bot: Bot,
        chat_id: ChatId,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let summary = ctx.task_queue.summary().unwrap_or_default();
        let recent = ctx.task_queue.list(None, 5).unwrap_or_default();
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
        bot.send_message(chat_id, reply).await?;
        Ok(())
    }

    async fn handle_help(
        bot: Bot,
        chat_id: ChatId,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        bot.send_message(
            chat_id,
            "Soy Axi, tu asistente de LifeOS.\n\n\
             Comandos:\n\
             /do <tarea> — Crear tarea para el supervisor\n\
             /task <tarea> — Igual que /do\n\
             /search <query> — Buscar en internet\n\
             /screenshot — Capturar pantalla y enviarla\n\
             /status — Ver estado de tareas\n\
             /help — Este mensaje\n\n\
             Tambien puedes:\n\
             - Enviar texto y te respondo\n\
             - Enviar nota de voz y te respondo con voz\n\
             - Enviar foto y la analizo\n\
             - En grupos, mencioname con @\n\n\
             Cuando una tarea termine, te aviso automaticamente.",
        )
        .await?;
        Ok(())
    }

    async fn handle_chat(
        bot: Bot,
        chat_id: ChatId,
        text: String,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        bot.send_chat_action(chat_id, ChatAction::Typing).await.ok();

        let reply = chat_with_llm(&ctx, &text).await;
        for chunk in reply.as_bytes().chunks(4000) {
            bot.send_message(chat_id, String::from_utf8_lossy(chunk).to_string())
                .await?;
        }
        Ok(())
    }

    // ---- Callback query handler (inline button presses) ----

    async fn handle_callback(
        bot: Bot,
        q: CallbackQuery,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        bot.answer_callback_query(&q.id).await?;

        let data = q.data.unwrap_or_default();
        let chat_id = q.message.as_ref().map(|m| m.chat().id).unwrap_or(ChatId(0));

        if let Some(task_id) = data.strip_prefix("approve:") {
            info!("Telegram: task {} approved via button", task_id);
            // Re-enqueue the task (it was waiting for approval)
            match ctx.task_queue.enqueue(TaskCreate {
                objective: format!("[APPROVED] {}", task_id),
                priority: TaskPriority::High,
                source: "telegram-approval".into(),
                max_attempts: 3,
            }) {
                Ok(_) => {
                    bot.send_message(chat_id, "Tarea aprobada. Ejecutando...")
                        .await?;
                }
                Err(e) => {
                    bot.send_message(chat_id, format!("Error: {}", e)).await?;
                }
            }
        } else if let Some(task_id) = data.strip_prefix("reject:") {
            info!("Telegram: task {} rejected via button", task_id);
            bot.send_message(chat_id, "Tarea rechazada.").await?;
        }

        Ok(())
    }

    /// Send an approval request with inline buttons.
    /// Used by the supervisor for medium-risk actions.
    #[allow(dead_code)]
    pub async fn send_approval_request(
        bot: &Bot,
        chat_id: ChatId,
        task_description: &str,
        task_id: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let keyboard = InlineKeyboardMarkup::new(vec![vec![
            InlineKeyboardButton::callback("Aprobar", format!("approve:{}", task_id)),
            InlineKeyboardButton::callback("Rechazar", format!("reject:{}", task_id)),
        ]]);

        bot.send_message(
            chat_id,
            format!(
                "Accion de riesgo medio requiere aprobacion:\n\n{}\n\nQuieres ejecutarla?",
                task_description
            ),
        )
        .reply_markup(keyboard)
        .await?;

        Ok(())
    }

    // ---- Shared helpers ----

    async fn chat_with_llm(ctx: &BotCtx, text: &str) -> String {
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

        let router = ctx.router.read().await;
        match router.chat(&request).await {
            Ok(r) => format!("{}\n\n[{}]", r.text, r.provider),
            Err(e) => format!("Error: {}", e),
        }
    }

    /// Convert text to voice using Piper TTS. Returns path to OGG file or None.
    async fn text_to_voice(text: &str) -> Option<PathBuf> {
        let tmp_dir = std::env::temp_dir().join("lifeos-telegram");
        tokio::fs::create_dir_all(&tmp_dir).await.ok();
        let wav_path = tmp_dir.join(format!("tts-{}.wav", chrono::Utc::now().timestamp()));
        let ogg_path = wav_path.with_extension("ogg");

        // Piper TTS: text -> WAV
        let piper = tokio::process::Command::new("/opt/lifeos/piper-tts/piper")
            .args([
                "--model",
                "/opt/lifeos/piper-tts/es_MX-claude-high.onnx",
                "--output_file",
                &wav_path.to_string_lossy(),
            ])
            .stdin(std::process::Stdio::piped())
            .spawn();

        if let Ok(mut child) = piper {
            if let Some(mut stdin) = child.stdin.take() {
                use tokio::io::AsyncWriteExt;
                stdin
                    .write_all(text[..text.len().min(500)].as_bytes())
                    .await
                    .ok();
                drop(stdin);
            }
            let status = child.wait().await.ok()?;
            if !status.success() {
                return None;
            }
        } else {
            return None;
        }

        // Convert WAV -> OGG (Telegram requires OGG/OPUS for voice)
        let ffmpeg = tokio::process::Command::new("ffmpeg")
            .args([
                "-i",
                &wav_path.to_string_lossy(),
                "-c:a",
                "libopus",
                "-y",
                &ogg_path.to_string_lossy(),
            ])
            .output()
            .await;

        tokio::fs::remove_file(&wav_path).await.ok();

        if ffmpeg.map(|o| o.status.success()).unwrap_or(false) {
            Some(ogg_path)
        } else {
            None
        }
    }

    fn is_addressed_to_bot(msg: &Message, bot_username: &str) -> bool {
        if bot_username.is_empty() {
            return false;
        }
        // Check text for @mention or /command
        if let Some(text) = msg.text() {
            if text.contains(&format!("@{}", bot_username)) {
                return true;
            }
            if text.starts_with('/') {
                return true; // all /commands in groups are addressed
            }
        }
        // Check caption for mention
        if let Some(caption) = msg.caption() {
            if caption.contains(&format!("@{}", bot_username)) {
                return true;
            }
        }
        false
    }

    fn largest_photo(msg: &Message) -> Option<String> {
        if let MessageKind::Common(common) = &msg.kind {
            if let MediaKind::Photo(photo) = &common.media_kind {
                return photo.photo.last().map(|p| p.file.id.clone());
            }
        }
        None
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

#[cfg(feature = "telegram")]
pub use inner::*;

// When telegram feature is disabled, this module is intentionally empty.
