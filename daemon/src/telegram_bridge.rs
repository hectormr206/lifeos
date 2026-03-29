//! Telegram bridge — Natural language AI assistant with tool execution.
//!
//! Axi understands natural language and can perform real actions on the system
//! without requiring /commands. Supports: text, voice (STT+TTS), photos (vision),
//! groups, push notifications, heartbeat proactive monitoring.

#[cfg(feature = "telegram")]
mod inner {
    use log::{error, info, warn};
    use std::path::PathBuf;
    use std::sync::Arc;
    use teloxide::net::Download;
    use teloxide::prelude::*;
    use teloxide::types::{
        BotCommand, ChatAction, InlineKeyboardButton, InlineKeyboardMarkup, InputFile, MediaKind,
        MessageKind,
    };
    use tokio::sync::RwLock;

    use crate::knowledge_graph::KnowledgeGraph;
    use crate::llm_router::LlmRouter;
    use crate::memory_plane::MemoryPlaneManager;
    use crate::supervisor::SupervisorNotification;
    use crate::task_queue::TaskQueue;
    use crate::telegram_tools::{self, ConversationHistory, CronStore, SddStore, ToolContext};

    /// Heartbeat interval — how often Axi proactively checks system health.
    const HEARTBEAT_INTERVAL_SECS: u64 = 30 * 60; // 30 minutes
    /// Cron check interval — how often we check for due cron jobs.
    const CRON_CHECK_INTERVAL_SECS: u64 = 60; // every minute

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
        tool_ctx: ToolContext,
        dedupe: Arc<crate::message_dedupe::MessageDedupe>,
        allowed_ids: Vec<i64>,
        bot_username: String,
        /// Group policy: "mention_only" (default), "all", or "none"
        group_policy: String,
        /// Allowed group IDs (empty = all groups with valid chat IDs)
        group_ids: Vec<i64>,
    }

    pub async fn run_telegram_bot(
        config: TelegramConfig,
        task_queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
        memory: Option<Arc<RwLock<MemoryPlaneManager>>>,
        knowledge_graph: Option<Arc<RwLock<KnowledgeGraph>>>,
        mut notify_rx: tokio::sync::broadcast::Receiver<SupervisorNotification>,
    ) {
        info!("Starting Telegram bridge (natural language mode)...");

        // Group policy configuration from environment
        let group_policy =
            std::env::var("LIFEOS_TELEGRAM_GROUP_POLICY").unwrap_or_else(|_| "mention_only".into());
        let group_ids: Vec<i64> = std::env::var("LIFEOS_TELEGRAM_GROUP_IDS")
            .unwrap_or_default()
            .split(',')
            .filter_map(|s| s.trim().parse().ok())
            .collect();
        info!(
            "Telegram group policy: {}, allowed groups: {:?}",
            group_policy, group_ids
        );

        let bot = Bot::new(&config.bot_token);
        let notify_bot = bot.clone();
        let heartbeat_bot = bot.clone();
        let notify_chat_ids = config.allowed_chat_ids.clone();
        let heartbeat_chat_ids = config.allowed_chat_ids.clone();

        // Get bot username for group mention detection
        let bot_username = bot
            .get_me()
            .await
            .map(|me| me.username.clone().unwrap_or_default())
            .unwrap_or_default();
        info!("Telegram bot username: @{}", bot_username);

        // Register bot commands so Telegram shows a "/" menu
        bot.set_my_commands(vec![
            BotCommand::new("help", "Ayuda y comandos disponibles"),
            BotCommand::new("new", "Nueva conversacion (limpiar historial)"),
            BotCommand::new("status", "Estado del sistema"),
            BotCommand::new("btw", "Conversacion lateral (no guarda historial)"),
            BotCommand::new("do", "Ejecutar tarea del supervisor"),
        ])
        .await
        .ok();

        // Supervisor notification listener
        tokio::spawn(async move {
            loop {
                match notify_rx.recv().await {
                    Ok(notification) => {
                        if let SupervisorNotification::ApprovalRequired {
                            ref task_id,
                            ref action_description,
                            ..
                        } = notification
                        {
                            for &chat_id in &notify_chat_ids {
                                if let Err(e) = send_approval_request(
                                    &notify_bot,
                                    ChatId(chat_id),
                                    action_description,
                                    task_id,
                                )
                                .await
                                {
                                    error!("Telegram approval request failed: {}", e);
                                }
                            }
                        } else {
                            let text = format_notification(&notification);
                            for &chat_id in &notify_chat_ids {
                                if let Err(e) =
                                    notify_bot.send_message(ChatId(chat_id), &text).await
                                {
                                    error!("Telegram notification failed: {}", e);
                                }
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

        // Shared state for conversation history, cron, and SDD sessions
        let history = Arc::new(ConversationHistory::new());
        let cron_store = Arc::new(CronStore::new());
        let sdd_store = Arc::new(SddStore::new());

        let heartbeat_tool_ctx = ToolContext {
            router: router.clone(),
            task_queue: task_queue.clone(),
            memory: memory.clone(),
            knowledge_graph: knowledge_graph.clone(),
            history: history.clone(),
            cron_store: cron_store.clone(),
            sdd_store: sdd_store.clone(),
        };

        // Heartbeat — configurable HEARTBEAT.md evaluation loop
        let heartbeat_ctx = heartbeat_tool_ctx.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(60)).await;
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(HEARTBEAT_INTERVAL_SECS)).await;

                match telegram_tools::run_heartbeat(&heartbeat_ctx).await {
                    Some(report) => {
                        for &chat_id in &heartbeat_chat_ids {
                            if let Err(e) =
                                heartbeat_bot.send_message(ChatId(chat_id), &report).await
                            {
                                error!("Heartbeat notification failed: {}", e);
                            }
                        }
                    }
                    None => {
                        info!("[heartbeat] All clear, no notification needed");
                    }
                }
            }
        });

        // Cron runner — checks every minute for due cron jobs
        let cron_bot = bot.clone();
        let cron_ctx = heartbeat_tool_ctx.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(30)).await;
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(CRON_CHECK_INTERVAL_SECS)).await;

                let due = cron_ctx.cron_store.due_jobs().await;
                for job in due {
                    info!("[cron] Running job: {} -> {}", job.name, job.action);
                    cron_ctx.cron_store.mark_run(&job.name).await;

                    // Execute the cron action through the agentic loop
                    let (response, _screenshot) =
                        telegram_tools::agentic_chat(&cron_ctx, job.chat_id, &job.action, None)
                            .await;

                    // Send result to the chat that created the cron job
                    if job.chat_id != 0 {
                        let msg = format!("[Cron: {}]\n\n{}", job.name, response);
                        if let Err(e) = cron_bot.send_message(ChatId(job.chat_id), &msg).await {
                            error!("Cron notification failed: {}", e);
                        }
                    }
                }
            }
        });

        // Memory consolidation — runs every 6 hours (nocturnal consolidation)
        let consolidation_memory = memory.clone();
        tokio::spawn(async move {
            // Wait 5 minutes before first consolidation
            tokio::time::sleep(std::time::Duration::from_secs(300)).await;
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(6 * 3600)).await;

                if let Some(ref mem) = consolidation_memory {
                    let m = mem.read().await;
                    // Standard consolidation: boost/degrade/forget
                    match m.consolidate().await {
                        Ok((boosted, degraded, deleted)) => {
                            info!(
                                "[consolidation] Memory maintenance: boosted={}, degraded={}, deleted={}",
                                boosted, degraded, deleted
                            );
                        }
                        Err(e) => {
                            warn!("[consolidation] Failed: {}", e);
                        }
                    }
                    // Cross-memory consolidation: auto-generate graph links from recent memories
                    match m.cross_link_recent(&None).await {
                        Ok(links) if links > 0 => {
                            info!("[consolidation] Cross-linked {} new relationships", links);
                        }
                        _ => {}
                    }
                }
            }
        });

        let tool_ctx = ToolContext {
            router,
            task_queue,
            memory,
            knowledge_graph,
            history,
            cron_store,
            sdd_store,
        };

        let ctx = BotCtx {
            tool_ctx,
            dedupe: Arc::new(crate::message_dedupe::MessageDedupe::new()),
            allowed_ids: config.allowed_chat_ids,
            bot_username,
            group_policy,
            group_ids,
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

    // -----------------------------------------------------------------------
    // Message handler — ALL messages go through the agentic loop
    // -----------------------------------------------------------------------

    async fn handle_message(
        bot: Bot,
        msg: Message,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let chat_id = msg.chat.id;
        let is_group = msg.chat.is_group() || msg.chat.is_supergroup();

        // Auth check
        if is_group {
            // Group policy: "none" ignores all groups, "all" responds to everything,
            // "mention_only" (default) requires @mention or reply-to-bot
            if ctx.group_policy == "none" {
                return Ok(());
            }
            // If group_ids is set, only allow listed groups
            if !ctx.group_ids.is_empty() && !ctx.group_ids.contains(&chat_id.0) {
                return Ok(());
            }
            if ctx.group_policy != "all" && !is_addressed_to_bot(&msg, &ctx.bot_username) {
                return Ok(());
            }
        } else if !ctx.allowed_ids.is_empty() && !ctx.allowed_ids.contains(&chat_id.0) {
            bot.send_message(chat_id, "No autorizado.").await?;
            return Ok(());
        }

        // Deduplication check — drop retried/duplicate messages
        let dedupe_key = crate::message_dedupe::DedupeKey {
            channel: "telegram".to_string(),
            peer_id: chat_id.0.to_string(),
            message_id: msg.id.0.to_string(),
        };
        if ctx.dedupe.is_duplicate(dedupe_key).await {
            log::debug!(
                "Telegram: duplicate message {} from {}, skipping",
                msg.id.0,
                chat_id.0
            );
            return Ok(());
        }

        // Voice messages: transcribe, then process as natural language
        if let Some(voice) = msg.voice() {
            return handle_voice(bot, msg.clone(), chat_id, voice.file.id.clone(), ctx).await;
        }

        // Videos: extract frame, then vision analysis through agentic loop
        if let Some(video) = msg.video() {
            let caption = msg
                .caption()
                .map(|s| s.to_string())
                .unwrap_or_else(|| "Describe este video en español.".into());
            return handle_video(bot, chat_id, &video.file.id, &caption, ctx).await;
        }

        // Photos: vision analysis through agentic loop
        if let Some(photo_id) = largest_photo(&msg) {
            let caption = msg
                .caption()
                .map(|s| s.to_string())
                .unwrap_or_else(|| "Describe esta imagen en español.".into());
            return handle_photo(bot, chat_id, photo_id, &caption, ctx).await;
        }

        // Text messages
        let text = match msg.text() {
            Some(t) => {
                let mut t = t.to_string();
                if is_group {
                    t = t
                        .replace(&format!("@{}", ctx.bot_username), "")
                        .trim()
                        .to_string();
                }
                t
            }
            None => {
                bot.send_message(chat_id, "Acepto texto, voz, fotos y videos.")
                    .await?;
                return Ok(());
            }
        };

        if text.is_empty() {
            return Ok(());
        }

        info!("Telegram [{}]: {}", chat_id, &text[..text.len().min(100)]);

        // Legacy commands still work for backwards compatibility
        if text == "/help" || text == "/start" {
            return handle_help(bot, chat_id).await;
        }
        if text == "/new" || text == "/reset" {
            // Save session summary before clearing
            let old_messages = ctx.tool_ctx.history.clear(chat_id.0).await;
            if !old_messages.is_empty() {
                telegram_tools::save_session_summary(&ctx.tool_ctx, chat_id.0, &old_messages).await;
            }
            bot.send_message(chat_id, "Conversacion guardada en memoria y reiniciada.")
                .await?;
            return Ok(());
        }
        if text == "/status" || text.starts_with("/status ") {
            return handle_status(bot, chat_id, &ctx).await;
        }

        // /do trust: — execute task with auto-approval (no manual confirmation needed)
        if text.starts_with("/do trust:") || text.starts_with("/do trust ") {
            let task_text = text
                .strip_prefix("/do trust:")
                .or_else(|| text.strip_prefix("/do trust "))
                .unwrap_or(&text)
                .trim();
            if task_text.is_empty() {
                bot.send_message(chat_id, "Uso: /do trust: <objetivo>")
                    .await?;
                return Ok(());
            }
            bot.send_message(
                chat_id,
                format!("Modo trust activado. Ejecutando: {}", task_text),
            )
            .await?;
            // Set auto-approve env for this session
            std::env::set_var("LIFEOS_AUTO_APPROVE_MEDIUM", "true");
            let (response, screenshot_path) = with_typing(&bot, chat_id, async {
                telegram_tools::agentic_chat(&ctx.tool_ctx, chat_id.0, task_text, None).await
            })
            .await;
            if let Some(ref path) = screenshot_path {
                let screenshot_file = std::path::Path::new(path);
                if screenshot_file.exists() {
                    bot.send_photo(chat_id, InputFile::file(screenshot_file))
                        .await
                        .ok();
                    tokio::fs::remove_file(screenshot_file).await.ok();
                }
            }
            send_chunked(&bot, chat_id, &response).await?;
            return Ok(());
        }

        // /btw — side conversation that doesn't pollute main history
        if text.starts_with("/btw ") {
            let side_text = text.strip_prefix("/btw ").unwrap_or(&text);
            // Use a separate "side" chat_id so it doesn't mix with main history
            let side_id = chat_id.0 ^ 0x7F7F_7F7F; // XOR to create distinct ID
            let (response, screenshot_path) = with_typing(&bot, chat_id, async {
                telegram_tools::agentic_chat(&ctx.tool_ctx, side_id, side_text, None).await
            })
            .await;
            // Clear the side conversation immediately after (no summary for /btw)
            let _ = ctx.tool_ctx.history.clear(side_id).await;

            if let Some(ref path) = screenshot_path {
                let screenshot_file = std::path::Path::new(path);
                if screenshot_file.exists() {
                    bot.send_photo(chat_id, InputFile::file(screenshot_file))
                        .await
                        .ok();
                    tokio::fs::remove_file(screenshot_file).await.ok();
                }
            }
            send_chunked(&bot, chat_id, &response).await?;
            return Ok(());
        }

        // Thread/topic support: use composite key when message is in a forum topic
        let history_key = msg
            .thread_id
            .map(|tid| chat_id.0 ^ (tid.0 .0 as i64))
            .unwrap_or(chat_id.0);

        // Everything else goes through the agentic loop (with conversation history)
        let (response, screenshot_path) = with_typing(&bot, chat_id, async {
            telegram_tools::agentic_chat(&ctx.tool_ctx, history_key, &text, None).await
        })
        .await;

        // If SDD checkpoint, send inline buttons for approval
        if response.contains("--- CHECKPOINT ---") {
            // Extract SDD ID from response
            if let Some(sdd_id) = response
                .lines()
                .find(|l| l.starts_with("SDD ID: "))
                .map(|l| l.strip_prefix("SDD ID: ").unwrap_or("").trim().to_string())
            {
                // Send result up to checkpoint (without the CHECKPOINT marker)
                let clean_response = response
                    .split("--- CHECKPOINT ---")
                    .next()
                    .unwrap_or(&response);
                send_chunked(&bot, chat_id, clean_response).await?;

                // Send approval buttons
                let keyboard = InlineKeyboardMarkup::new(vec![vec![
                    InlineKeyboardButton::callback(
                        "Continuar SDD",
                        format!("sdd_approve:{}", sdd_id),
                    ),
                    InlineKeyboardButton::callback("Abortar SDD", format!("sdd_reject:{}", sdd_id)),
                ]]);

                let phase_name =
                    if response.contains("Proponer") && !response.contains("Especificar") {
                        "Proponer"
                    } else {
                        "Disenar"
                    };

                bot.send_message(
                    chat_id,
                    format!(
                        "Fase {} completada. Quieres que continue con las siguientes fases?",
                        phase_name
                    ),
                )
                .reply_markup(keyboard)
                .await?;

                return Ok(());
            }
        }

        // If a screenshot was taken, send it as a photo
        if let Some(ref path) = screenshot_path {
            let screenshot_file = std::path::Path::new(path);
            if screenshot_file.exists() {
                bot.send_photo(chat_id, InputFile::file(screenshot_file))
                    .await
                    .ok();
                tokio::fs::remove_file(screenshot_file).await.ok();
            }
        }

        // Check for send_file marker in the response
        if response.contains("__SEND_FILE__:") {
            for part in response.split("__SEND_FILE__:").skip(1) {
                let file_path = part.lines().next().unwrap_or("").trim();
                if !file_path.is_empty() && std::path::Path::new(file_path).exists() {
                    bot.send_document(chat_id, InputFile::file(file_path))
                        .await
                        .ok();
                }
            }
            // Send text response without the markers
            let clean = response
                .lines()
                .filter(|l| !l.contains("__SEND_FILE__:"))
                .collect::<Vec<_>>()
                .join("\n");
            if !clean.trim().is_empty() {
                send_chunked(&bot, chat_id, &clean).await?;
            }
        } else {
            // Send the text response (chunked for Telegram's 4096 limit)
            send_chunked(&bot, chat_id, &response).await?;
        }

        Ok(())
    }

    // -----------------------------------------------------------------------
    // Voice handling — transcribe then run through agentic loop
    // -----------------------------------------------------------------------

    async fn handle_voice(
        bot: Bot,
        _msg: Message,
        chat_id: ChatId,
        file_id: String,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        info!("Telegram [{}]: voice message received", chat_id);
        bot.send_chat_action(chat_id, ChatAction::Typing).await.ok();

        let file = bot.get_file(&file_id).await?;
        let tmp_dir = std::env::temp_dir().join("lifeos-telegram");
        tokio::fs::create_dir_all(&tmp_dir).await.ok();
        let ogg_path = tmp_dir.join(format!("voice-{}.ogg", chrono::Utc::now().timestamp()));
        let mut ogg_file = tokio::fs::File::create(&ogg_path).await?;
        bot.download_file(&file.path, &mut ogg_file).await?;

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
            bot.send_message(chat_id, "No pude convertir el audio.")
                .await?;
            return Ok(());
        };

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

        // Process transcription through agentic loop (natural language!)
        let (response, screenshot_path) = with_typing(&bot, chat_id, async {
            telegram_tools::agentic_chat(&ctx.tool_ctx, chat_id.0, &transcription, None).await
        })
        .await;

        // Send screenshot if one was taken
        if let Some(ref path) = screenshot_path {
            let screenshot_file = std::path::Path::new(path);
            if screenshot_file.exists() {
                bot.send_photo(chat_id, InputFile::file(screenshot_file))
                    .await
                    .ok();
                tokio::fs::remove_file(screenshot_file).await.ok();
            }
        }

        // Always try to send a voice response for voice messages.
        // Try Piper first, then fall back to espeak-ng.
        let voice_path = match text_to_voice(&response).await {
            Some(path) => Some(path),
            None => {
                warn!("Piper TTS failed for Telegram voice reply, trying espeak-ng fallback");
                text_to_voice_espeak(&response).await
            }
        };

        if let Some(audio_path) = voice_path {
            bot.send_voice(chat_id, InputFile::file(&audio_path))
                .await
                .ok();
            tokio::fs::remove_file(&audio_path).await.ok();
        }

        // Always send text so the user can read the response too.
        bot.send_message(
            chat_id,
            format!(
                "{}\n\n(tu dijiste: {})",
                &response[..response.len().min(3500)],
                &transcription[..transcription.len().min(200)]
            ),
        )
        .await?;

        Ok(())
    }

    // -----------------------------------------------------------------------
    // Photo handling — through agentic loop with vision
    // -----------------------------------------------------------------------

    async fn handle_photo(
        bot: Bot,
        chat_id: ChatId,
        file_id: String,
        caption: &str,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        info!("Telegram [{}]: photo received", chat_id);
        let file = bot.get_file(&file_id).await?;
        let tmp_dir = std::env::temp_dir().join("lifeos-telegram");
        tokio::fs::create_dir_all(&tmp_dir).await.ok();
        let img_path = tmp_dir.join(format!("photo-{}.jpg", chrono::Utc::now().timestamp()));
        let mut img_file = tokio::fs::File::create(&img_path).await?;
        bot.download_file(&file.path, &mut img_file).await?;

        let img_bytes = tokio::fs::read(&img_path).await?;
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&img_bytes);
        let data_url = format!("data:image/jpeg;base64,{}", b64);

        tokio::fs::remove_file(&img_path).await.ok();

        // Process through agentic loop with image
        let (response, screenshot_path) = with_typing(&bot, chat_id, async {
            telegram_tools::agentic_chat(&ctx.tool_ctx, chat_id.0, caption, Some(&data_url)).await
        })
        .await;

        if let Some(ref path) = screenshot_path {
            let screenshot_file = std::path::Path::new(path);
            if screenshot_file.exists() {
                bot.send_photo(chat_id, InputFile::file(screenshot_file))
                    .await
                    .ok();
                tokio::fs::remove_file(screenshot_file).await.ok();
            }
        }

        send_chunked(&bot, chat_id, &response).await?;

        Ok(())
    }

    // -----------------------------------------------------------------------
    // Video handling — extract frame then vision analysis
    // -----------------------------------------------------------------------

    async fn handle_video(
        bot: Bot,
        chat_id: ChatId,
        video_file_id: &str,
        caption: &str,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        info!("Telegram [{}]: video received", chat_id);
        bot.send_chat_action(chat_id, ChatAction::Typing).await.ok();
        let _ = bot.send_message(chat_id, "Analizando video...").await;

        let file = bot.get_file(video_file_id).await?;
        let tmp_dir = std::env::temp_dir().join("lifeos-telegram");
        tokio::fs::create_dir_all(&tmp_dir).await.ok();
        let video_path = tmp_dir.join(format!("video-{}.mp4", chrono::Utc::now().timestamp()));
        let frame_path = tmp_dir.join(format!("frame-{}.jpg", chrono::Utc::now().timestamp()));
        let mut dst = tokio::fs::File::create(&video_path).await?;
        bot.download_file(&file.path, &mut dst).await?;

        // Extract middle frame (frame #5)
        let ffmpeg = tokio::process::Command::new("ffmpeg")
            .args([
                "-y",
                "-i",
                video_path.to_str().unwrap_or_default(),
                "-vf",
                "select=eq(n\\,5)",
                "-frames:v",
                "1",
                frame_path.to_str().unwrap_or_default(),
            ])
            .output()
            .await;

        if ffmpeg.is_err() || !frame_path.exists() {
            // Fallback: just take first frame
            let _ = tokio::process::Command::new("ffmpeg")
                .args([
                    "-y",
                    "-i",
                    video_path.to_str().unwrap_or_default(),
                    "-vframes",
                    "1",
                    frame_path.to_str().unwrap_or_default(),
                ])
                .output()
                .await;
        }

        if frame_path.exists() {
            let bytes = tokio::fs::read(&frame_path).await?;
            use base64::Engine;
            let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
            let data_url = format!("data:image/jpeg;base64,{}", b64);

            let (response, screenshot_path) = with_typing(&bot, chat_id, async {
                telegram_tools::agentic_chat(&ctx.tool_ctx, chat_id.0, caption, Some(&data_url))
                    .await
            })
            .await;

            if let Some(ref path) = screenshot_path {
                let screenshot_file = std::path::Path::new(path);
                if screenshot_file.exists() {
                    bot.send_photo(chat_id, InputFile::file(screenshot_file))
                        .await
                        .ok();
                    tokio::fs::remove_file(screenshot_file).await.ok();
                }
            }

            send_chunked(&bot, chat_id, &response).await?;
        } else {
            bot.send_message(chat_id, "No pude extraer un frame del video.")
                .await?;
        }

        // Cleanup
        let _ = tokio::fs::remove_file(&video_path).await;
        let _ = tokio::fs::remove_file(&frame_path).await;

        Ok(())
    }

    // -----------------------------------------------------------------------
    // Callback query handler (inline button presses for approvals)
    // -----------------------------------------------------------------------

    async fn handle_callback(
        bot: Bot,
        q: CallbackQuery,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        bot.answer_callback_query(&q.id).await?;

        let data = q.data.unwrap_or_default();
        let chat_id = q.message.as_ref().map(|m| m.chat().id).unwrap_or(ChatId(0));

        if let Some(sdd_id) = data.strip_prefix("sdd_approve:") {
            info!("Telegram: SDD {} approved, continuing...", sdd_id);
            bot.send_chat_action(chat_id, ChatAction::Typing).await.ok();
            bot.send_message(chat_id, "Continuando con las siguientes fases SDD...")
                .await?;

            match telegram_tools::sdd_continue(&ctx.tool_ctx, sdd_id).await {
                Some((result, paused, new_id, _chat)) => {
                    if paused {
                        // Another checkpoint — send buttons again
                        let clean = result.split("--- CHECKPOINT ---").next().unwrap_or(&result);
                        send_chunked(&bot, chat_id, clean).await?;

                        let keyboard = InlineKeyboardMarkup::new(vec![vec![
                            InlineKeyboardButton::callback(
                                "Continuar SDD",
                                format!("sdd_approve:{}", new_id),
                            ),
                            InlineKeyboardButton::callback(
                                "Abortar SDD",
                                format!("sdd_reject:{}", new_id),
                            ),
                        ]]);
                        bot.send_message(chat_id, "Fase completada. Continuar?")
                            .reply_markup(keyboard)
                            .await?;
                    } else {
                        // SDD complete
                        send_chunked(&bot, chat_id, &result).await?;
                        bot.send_message(chat_id, "SDD completado y guardado en memoria.")
                            .await?;
                    }
                }
                None => {
                    bot.send_message(chat_id, "Sesion SDD no encontrada (puede haber expirado).")
                        .await?;
                }
            }
        } else if let Some(sdd_id) = data.strip_prefix("sdd_reject:") {
            info!("Telegram: SDD {} rejected", sdd_id);
            match telegram_tools::sdd_abort(&ctx.tool_ctx, sdd_id).await {
                Some(msg) => {
                    send_chunked(&bot, chat_id, &msg).await?;
                }
                None => {
                    bot.send_message(chat_id, "SDD abortado.").await?;
                }
            }
        } else if let Some(task_id) = data.strip_prefix("approve:") {
            info!("Telegram: task {} approved via button", task_id);
            use crate::task_queue::{TaskCreate, TaskPriority};
            match ctx.tool_ctx.task_queue.enqueue(TaskCreate {
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

    // -----------------------------------------------------------------------
    // Help (the only remaining /command — everything else is natural language)
    // -----------------------------------------------------------------------

    async fn handle_help(
        bot: Bot,
        chat_id: ChatId,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        bot.send_message(
            chat_id,
            "Soy Axi, tu asistente de LifeOS.\n\n\
             Hablame de forma natural, como a un amigo. Puedo:\n\n\
             - Ver cuantos archivos tienes en una carpeta\n\
             - Buscar informacion en internet\n\
             - Tomar y enviarte capturas de pantalla\n\
             - Navegar paginas web y analizarlas\n\
             - Instalar aplicaciones\n\
             - Ejecutar comandos en tu sistema\n\
             - Escribir y leer archivos\n\
             - Controlar tu computadora (teclado, mouse)\n\
             - Recordar cosas que me digas\n\
             - Programar tareas recurrentes (cron)\n\
             - Monitorear tu sistema y avisarte si algo anda mal\n\
             - Analizar fotos que me envies\n\
             - Responder notas de voz con voz\n\n\
             Recuerdo la conversacion — puedes hacer follow-ups.\n\n\
             Ejemplos:\n\
             \"Cuantos archivos tengo en Descargas?\"\n\
             \"Busca el clima de hoy en mi ciudad\"\n\
             \"Abre google.com y dime que ves\"\n\
             \"Cada dia a las 7am dame un resumen del sistema\"\n\n\
             /new — Reiniciar conversacion\n\
             /status — Estado del sistema (sin LLM)\n\
             /btw <texto> — Conversacion lateral\n\
             /do <tarea> — Ejecutar tarea\n\
             /help — Este mensaje\n\n\
             En grupos, mencioname con @ o responde a mis mensajes. Te monitoreo cada 30 min.",
        )
        .await?;
        Ok(())
    }

    /// Quick system status without going through the LLM agentic loop.
    async fn handle_status(
        bot: Bot,
        chat_id: ChatId,
        ctx: &BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let mut monitor = crate::system::SystemMonitor::new();
        let metrics = monitor
            .collect_metrics()
            .unwrap_or_else(|_| crate::system::SystemMetrics {
                timestamp: chrono::Local::now(),
                cpu_usage: 0.0,
                memory_usage: 0.0,
                memory_used_mb: 0,
                memory_total_mb: 0,
                disk_usage: 0.0,
                disk_used_gb: 0,
                disk_total_gb: 0,
                network_rx_mbps: 0.0,
                network_tx_mbps: 0.0,
                load_average: (0.0, 0.0, 0.0),
                uptime_seconds: 0,
                process_count: 0,
            });

        // Format uptime as human-readable
        let uptime_h = metrics.uptime_seconds / 3600;
        let uptime_m = (metrics.uptime_seconds % 3600) / 60;
        let uptime_str = if uptime_h > 0 {
            format!("{}h {}m", uptime_h, uptime_m)
        } else {
            format!("{}m", uptime_m)
        };

        // Local model: check what llama-server is running
        let local_model = std::env::var("LIFEOS_LOCAL_MODEL")
            .or_else(|_| std::env::var("LIFEOS_LLM_MODEL"))
            .unwrap_or_else(|_| "desconocido".into());

        // Active providers count
        let providers_count = ctx.tool_ctx.router.read().await.cost_summary().len();

        // Pending tasks
        let tasks_summary = ctx.tool_ctx.task_queue.summary().unwrap_or_default();
        let tasks_pending = tasks_summary
            .get("pending")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let tasks_running = tasks_summary
            .get("running")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);

        let status_text = format!(
            "Estado de LifeOS\n\n\
             Uptime: {}\n\
             CPU: {:.1}%\n\
             RAM: {} MB / {} MB ({:.0}%)\n\
             Disco: {} GB / {} GB ({:.0}%)\n\
             Load: {:.2} {:.2} {:.2}\n\
             Procesos: {}\n\
             Modelo local: {}\n\
             Providers activos: {}\n\
             Tareas pendientes: {} | ejecutando: {}",
            uptime_str,
            metrics.cpu_usage,
            metrics.memory_used_mb,
            metrics.memory_total_mb,
            metrics.memory_usage,
            metrics.disk_used_gb,
            metrics.disk_total_gb,
            metrics.disk_usage,
            metrics.load_average.0,
            metrics.load_average.1,
            metrics.load_average.2,
            metrics.process_count,
            local_model,
            providers_count,
            tasks_pending,
            tasks_running,
        );

        bot.send_message(chat_id, status_text).await?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Shared helpers
    // -----------------------------------------------------------------------

    /// Run a future while keeping the Telegram "typing..." indicator alive.
    ///
    /// Telegram's typing indicator expires after ~5 seconds, so we re-send it
    /// every 4 seconds until the future completes.
    async fn with_typing<F, T>(bot: &Bot, chat_id: ChatId, fut: F) -> T
    where
        F: std::future::Future<Output = T>,
    {
        let bot_clone = bot.clone();
        let typing_handle = tokio::spawn(async move {
            loop {
                bot_clone
                    .send_chat_action(chat_id, ChatAction::Typing)
                    .await
                    .ok();
                tokio::time::sleep(tokio::time::Duration::from_secs(4)).await;
            }
        });

        let result = fut.await;
        typing_handle.abort();
        result
    }

    /// Convert basic markdown to Telegram-safe HTML.
    fn markdown_to_html(text: &str) -> String {
        use std::borrow::Cow;

        // First, escape HTML special chars in the raw text (but not our tags)
        let escaped: Cow<'_, str> = Cow::Owned(
            text.replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;"),
        );

        let mut result = String::with_capacity(escaped.len());
        let mut chars = escaped.chars().peekable();

        while let Some(ch) = chars.next() {
            if ch == '`' {
                // Check for ``` code blocks
                if chars.peek() == Some(&'`') {
                    chars.next();
                    if chars.peek() == Some(&'`') {
                        chars.next();
                        // Skip optional language tag on the same line
                        while chars.peek().map(|c| *c != '\n').unwrap_or(false) {
                            chars.next();
                        }
                        if chars.peek() == Some(&'\n') {
                            chars.next();
                        }
                        // Collect until closing ```
                        let mut code = String::new();
                        loop {
                            match chars.next() {
                                Some('`') if chars.peek() == Some(&'`') => {
                                    chars.next();
                                    if chars.peek() == Some(&'`') {
                                        chars.next();
                                        break;
                                    }
                                    code.push_str("``");
                                }
                                Some(c) => code.push(c),
                                None => break,
                            }
                        }
                        result.push_str("<pre>");
                        result.push_str(code.trim_end());
                        result.push_str("</pre>");
                        continue;
                    }
                    // Two backticks but not three — treat as inline
                    result.push_str("``");
                    continue;
                }
                // Inline code
                let mut code = String::new();
                loop {
                    match chars.next() {
                        Some('`') => break,
                        Some(c) => code.push(c),
                        None => break,
                    }
                }
                result.push_str("<code>");
                result.push_str(&code);
                result.push_str("</code>");
            } else if ch == '*' && chars.peek() == Some(&'*') {
                chars.next(); // consume second *
                let mut bold = String::new();
                loop {
                    match chars.next() {
                        Some('*') if chars.peek() == Some(&'*') => {
                            chars.next();
                            break;
                        }
                        Some(c) => bold.push(c),
                        None => break,
                    }
                }
                result.push_str("<b>");
                result.push_str(&bold);
                result.push_str("</b>");
            } else {
                result.push(ch);
            }
        }

        result
    }

    /// Send a long message in chunks (Telegram has 4096 char limit), using HTML parse mode.
    async fn send_chunked(
        bot: &Bot,
        chat_id: ChatId,
        text: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let html = markdown_to_html(text);
        // Split on char boundaries respecting Telegram's limit
        let max = 4000;
        let mut start = 0;
        while start < html.len() {
            let mut end = (start + max).min(html.len());
            // Find char boundary
            while end > start && !html.is_char_boundary(end) {
                end -= 1;
            }
            if end == start {
                break;
            }
            bot.send_message(chat_id, &html[start..end])
                .parse_mode(teloxide::types::ParseMode::Html)
                .await?;
            start = end;
        }
        Ok(())
    }

    /// Convert text to voice using Piper TTS. Returns path to OGG file or None.
    async fn text_to_voice(text: &str) -> Option<PathBuf> {
        let tmp_dir = std::env::temp_dir().join("lifeos-telegram");
        tokio::fs::create_dir_all(&tmp_dir).await.ok();
        let wav_path = tmp_dir.join(format!("tts-{}.wav", chrono::Utc::now().timestamp()));
        let ogg_path = wav_path.with_extension("ogg");

        // Strip provider tag for TTS
        let clean_text = if let Some(pos) = text.rfind("\n\n[") {
            &text[..pos]
        } else {
            text
        };

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
                    .write_all(clean_text[..clean_text.len().min(500)].as_bytes())
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

    /// Fallback TTS using espeak-ng when Piper is unavailable.
    /// Returns path to OGG file or None.
    async fn text_to_voice_espeak(text: &str) -> Option<PathBuf> {
        let tmp_dir = std::env::temp_dir().join("lifeos-telegram");
        tokio::fs::create_dir_all(&tmp_dir).await.ok();
        let wav_path = tmp_dir.join(format!("tts-espeak-{}.wav", chrono::Utc::now().timestamp()));
        let ogg_path = wav_path.with_extension("ogg");

        let clean_text = if let Some(pos) = text.rfind("\n\n[") {
            &text[..pos]
        } else {
            text
        };

        let espeak = tokio::process::Command::new("espeak-ng")
            .args([
                "-v",
                "es",
                "-w",
                &wav_path.to_string_lossy(),
                &clean_text[..clean_text.len().min(500)],
            ])
            .output()
            .await;

        if !espeak.map(|o| o.status.success()).unwrap_or(false) {
            return None;
        }

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
        // Reply-to-bot: if user is replying to one of Axi's own messages, treat as addressed
        if let Some(reply) = msg.reply_to_message() {
            if reply.from.as_ref().map(|u| u.is_bot).unwrap_or(false) {
                return true;
            }
        }
        if let Some(text) = msg.text() {
            if text.contains(&format!("@{}", bot_username)) {
                return true;
            }
            if text.starts_with('/') {
                return true;
            }
        }
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

    /// Send an approval request with inline buttons.
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
                "Accion requiere aprobacion:\n\n{}\n\nQuieres ejecutarla?",
                task_description
            ),
        )
        .reply_markup(keyboard)
        .await?;

        Ok(())
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
                    "Aprobacion requerida:\n{}",
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
