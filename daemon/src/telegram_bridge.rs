//! Telegram bridge — Natural language AI assistant with tool execution.
//!
//! Axi understands natural language and can perform real actions on the system
//! without requiring /commands. Supports: text, voice (STT+TTS), photos (vision),
//! groups, push notifications, heartbeat proactive monitoring.

#[cfg(feature = "telegram")]
mod inner {
    use log::{error, info, warn};
    use std::collections::HashMap;
    use std::path::PathBuf;
    use std::sync::Arc;
    use teloxide::net::Download;
    use teloxide::prelude::*;
    use teloxide::types::{
        BotCommand, ChatAction, InlineKeyboardButton, InlineKeyboardMarkup, InputFile, MediaKind,
        MessageKind,
    };
    use tokio::sync::RwLock;

    use crate::llm_router::LlmRouter;
    use crate::memory_plane::MemoryPlaneManager;
    use crate::supervisor::SupervisorNotification;
    use crate::task_queue::TaskQueue;
    use crate::telegram_tools::{self, ConversationHistory, CronStore, SddStore, ToolContext};
    use crate::user_model::UserModel;

    /// Heartbeat interval — how often Axi proactively checks system health.
    const HEARTBEAT_INTERVAL_SECS: u64 = 30 * 60; // 30 minutes
    /// Cron check interval — how often we check for due cron jobs.
    const CRON_CHECK_INTERVAL_SECS: u64 = 60; // every minute
    /// Pairing code TTL in seconds (10 minutes).
    const PAIRING_TTL_SECS: u64 = 600;
    /// Retry budget for bot identity lookups during startup.
    const BOT_USERNAME_LOOKUP_ATTEMPTS: usize = 3;

    // -----------------------------------------------------------------------
    // Pairing store — allows authorized users to invite new users via /pair
    // -----------------------------------------------------------------------

    struct PendingPair {
        created_by: i64,
        created_at: std::time::Instant,
    }

    #[derive(Clone)]
    struct PairingStore {
        /// Pending codes: code -> PendingPair
        pending: Arc<RwLock<HashMap<u32, PendingPair>>>,
        /// Dynamically added chat IDs (persisted to disk on changes)
        dynamic_ids: Arc<RwLock<Vec<i64>>>,
    }

    impl PairingStore {
        fn new() -> Self {
            let dynamic: Vec<i64> = Self::load_dynamic_ids().unwrap_or_default();
            Self {
                pending: Arc::new(RwLock::new(HashMap::new())),
                dynamic_ids: Arc::new(RwLock::new(dynamic)),
            }
        }

        /// Generate a pairing code for an authorized user.
        async fn create_code(&self, created_by: i64) -> u32 {
            let code: u32 = rand::random::<u32>() % 900_000 + 100_000;
            let mut pending = self.pending.write().await;
            pending.insert(
                code,
                PendingPair {
                    created_by,
                    created_at: std::time::Instant::now(),
                },
            );
            code
        }

        /// Try to redeem a pairing code. Returns the inviter's chat_id on success.
        async fn try_redeem(&self, code_text: &str) -> Option<i64> {
            let code: u32 = code_text.trim().parse().ok()?;
            let mut pending = self.pending.write().await;
            if let Some(pair) = pending.remove(&code) {
                if pair.created_at.elapsed().as_secs() <= PAIRING_TTL_SECS {
                    return Some(pair.created_by);
                }
            }
            None
        }

        /// Add a chat_id to the dynamic allowed list and persist.
        async fn add_dynamic_id(&self, chat_id: i64) {
            let mut ids = self.dynamic_ids.write().await;
            if !ids.contains(&chat_id) {
                ids.push(chat_id);
                Self::save_dynamic_ids(&ids);
            }
        }

        /// Check if a chat_id is in the dynamic list.
        async fn is_dynamic_allowed(&self, chat_id: i64) -> bool {
            self.dynamic_ids.read().await.contains(&chat_id)
        }

        /// Purge expired codes periodically.
        async fn purge_expired(&self) {
            let mut pending = self.pending.write().await;
            pending.retain(|_, p| p.created_at.elapsed().as_secs() <= PAIRING_TTL_SECS);
        }

        fn dynamic_ids_path() -> std::path::PathBuf {
            let data_dir = std::env::var("LIFEOS_DATA_DIR")
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|_| std::path::PathBuf::from("/var/lib/lifeos"));
            data_dir.join("telegram-paired-ids.json")
        }

        fn load_dynamic_ids() -> Option<Vec<i64>> {
            let path = Self::dynamic_ids_path();
            let content = std::fs::read_to_string(path).ok()?;
            serde_json::from_str(&content).ok()
        }

        fn save_dynamic_ids(ids: &[i64]) {
            let path = Self::dynamic_ids_path();
            if let Ok(json) = serde_json::to_string(ids) {
                std::fs::write(path, json).ok();
            }
        }
    }

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
        worker_pool: Arc<crate::async_workers::WorkerPool>,
        allowed_ids: Vec<i64>,
        bot_username: String,
        /// Group policy: "mention_only" (default), "all", or "none"
        group_policy: String,
        /// Allowed group IDs (empty = all groups with valid chat IDs)
        group_ids: Vec<i64>,
        /// Pairing store for /pair command (invite new users)
        pairing: PairingStore,
        /// Event bus for dashboard notifications.
        event_bus: Option<tokio::sync::broadcast::Sender<crate::events::DaemonEvent>>,
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn run_telegram_bot(
        config: TelegramConfig,
        task_queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
        memory: Option<Arc<RwLock<MemoryPlaneManager>>>,
        mut notify_rx: tokio::sync::broadcast::Receiver<SupervisorNotification>,
        session_store: Option<Arc<crate::session_store::SessionStore>>,
        event_bus: Option<tokio::sync::broadcast::Sender<crate::events::DaemonEvent>>,
        user_model: Option<Arc<RwLock<UserModel>>>,
        meeting_archive: Option<Arc<crate::meeting_archive::MeetingArchive>>,
        meeting_assistant: Option<Arc<RwLock<crate::meeting_assistant::MeetingAssistant>>>,
        calendar: Option<Arc<crate::calendar::CalendarManager>>,
    ) {
        info!("Starting Telegram bridge (natural language mode)...");

        // NOTE(honesty): Webhook mode is NOT implemented. Setting LIFEOS_TELEGRAM_WEBHOOK_URL
        // only logs the configured URL. The bot always uses long-polling via teloxide's
        // Dispatcher. Webhook support would require an HTTPS reverse proxy (e.g. Caddy/nginx)
        // plus `bot.set_webhook(url)` — which is not wired yet.
        if let Ok(webhook_url) = std::env::var("LIFEOS_TELEGRAM_WEBHOOK_URL") {
            if !webhook_url.is_empty() {
                info!(
                    "[telegram] Webhook URL configured: {} (NOT active — webhook mode is not implemented. Using long-polling.)",
                    webhook_url
                );
            }
        }

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
        let bot_username = resolve_bot_username(&bot).await;
        if bot_username.is_empty() {
            warn!(
                "[telegram] Bot username unavailable after startup checks; group mention fallback will be limited to replies, slash commands, and 'Axi ...' invocations."
            );
        } else {
            info!("Telegram bot username: @{}", bot_username);
        }

        // Register bot commands so Telegram shows a "/" menu
        if let Err(err) = bot
            .set_my_commands(vec![
                BotCommand::new("help", "Ayuda y comandos disponibles"),
                BotCommand::new("new", "Nueva conversacion (limpiar historial)"),
                BotCommand::new("status", "Estado del sistema"),
                BotCommand::new("acciones", "Controles rapidos con botones"),
                BotCommand::new("btw", "Conversacion lateral (no guarda historial)"),
                BotCommand::new("do", "Ejecutar tarea del supervisor"),
                BotCommand::new("pair", "Generar codigo para vincular nuevo usuario"),
            ])
            .await
        {
            warn!("[telegram] Failed to register bot commands: {}", err);
        }

        // Supervisor notification listener
        let notify_session = session_store.clone();
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
                                // Record approval request in session transcript
                                if let Some(ref store) = notify_session {
                                    let key =
                                        crate::session_store::SessionKey::telegram_dm(chat_id);
                                    let turn = crate::session_store::TranscriptTurn::new(
                                        "assistant",
                                        &format!(
                                            "[Sistema] Aprobacion requerida: {}",
                                            action_description
                                        ),
                                        "telegram",
                                    );
                                    let _ = store.append_turn(&key, turn).await;
                                }
                            }
                        } else {
                            let text = format_notification(&notification);
                            // Add action buttons for specific notification types
                            let keyboard = notification_action_keyboard(&text);
                            for &chat_id in &notify_chat_ids {
                                let result = if let Some(ref kb) = keyboard {
                                    notify_bot
                                        .send_message(ChatId(chat_id), &text)
                                        .reply_markup(kb.clone())
                                        .await
                                } else {
                                    notify_bot.send_message(ChatId(chat_id), &text).await
                                };
                                if let Err(e) = result {
                                    error!("Telegram notification failed: {}", e);
                                }
                                // Record notification in session transcript for context continuity
                                if let Some(ref store) = notify_session {
                                    let key =
                                        crate::session_store::SessionKey::telegram_dm(chat_id);
                                    let turn = crate::session_store::TranscriptTurn::new(
                                        "assistant",
                                        &format!("[Notificacion automatica] {}", text),
                                        "telegram",
                                    );
                                    let _ = store.append_turn(&key, turn).await;
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
            history: history.clone(),
            cron_store: cron_store.clone(),
            sdd_store: sdd_store.clone(),
            session_store: session_store.clone(),
            user_model: user_model.clone(),
            meeting_archive: meeting_archive.clone(),
            meeting_assistant: meeting_assistant.clone(),
            calendar: calendar.clone(),
        };

        // Heartbeat — configurable HEARTBEAT.md evaluation loop
        let heartbeat_ctx = heartbeat_tool_ctx.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(60)).await;
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(HEARTBEAT_INTERVAL_SECS)).await;

                match telegram_tools::run_heartbeat(&heartbeat_ctx).await {
                    Some(report) => {
                        let keyboard = notification_action_keyboard(&report);
                        for &chat_id in &heartbeat_chat_ids {
                            let result = if let Some(ref kb) = keyboard {
                                heartbeat_bot
                                    .send_message(ChatId(chat_id), &report)
                                    .reply_markup(kb.clone())
                                    .await
                            } else {
                                heartbeat_bot.send_message(ChatId(chat_id), &report).await
                            };
                            if let Err(e) = result {
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
                        // Record cron message in session transcript for context continuity
                        if let Some(ref store) = cron_ctx.session_store {
                            let key = crate::session_store::SessionKey::telegram_dm(job.chat_id);
                            let turn = crate::session_store::TranscriptTurn::new(
                                "assistant",
                                &msg,
                                "telegram",
                            );
                            let _ = store.append_turn(&key, turn).await;
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
            history,
            cron_store,
            sdd_store,
            session_store,
            user_model,
            meeting_archive,
            meeting_assistant,
            calendar,
        };

        let worker_pool = Arc::new(if let Some(ref bus) = event_bus {
            crate::async_workers::WorkerPool::with_event_bus(bus.clone())
        } else {
            crate::async_workers::WorkerPool::new()
        });

        // Spawn background worker cleanup loop
        let cleanup_pool = (*worker_pool).clone();
        tokio::spawn(crate::async_workers::cleanup_loop(cleanup_pool));

        let pairing = PairingStore::new();

        // Spawn pairing code expiry cleanup loop
        let purge_pairing = pairing.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(60)).await;
                purge_pairing.purge_expired().await;
            }
        });

        let ctx = BotCtx {
            tool_ctx,
            dedupe: Arc::new(crate::message_dedupe::MessageDedupe::new()),
            worker_pool,
            allowed_ids: config.allowed_chat_ids,
            bot_username,
            group_policy,
            group_ids,
            pairing,
            event_bus,
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

        let reaction_handler = Update::filter_message_reaction_updated().endpoint(
            |bot: Bot, reaction: teloxide::types::MessageReactionUpdated, ctx: BotCtx| async move {
                handle_reaction(bot, reaction, ctx).await
            },
        );

        let handler = dptree::entry()
            .branch(message_handler)
            .branch(callback_handler)
            .branch(reaction_handler);

        Dispatcher::builder(bot, handler)
            .dependencies(dptree::deps![ctx])
            .enable_ctrlc_handler()
            .build()
            .dispatch()
            .await;
    }

    // -----------------------------------------------------------------------
    // Emoji reaction handler — Axi responds to emoji reactions
    // -----------------------------------------------------------------------

    async fn handle_reaction(
        bot: Bot,
        reaction: teloxide::types::MessageReactionUpdated,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        use teloxide::types::ReactionType;

        let chat_id = reaction.chat.id;

        // Only process new reactions (not removals)
        if reaction.new_reaction.is_empty() {
            return Ok(());
        }

        let emoji = match reaction.new_reaction.first() {
            Some(ReactionType::Emoji { emoji }) => emoji.clone(),
            _ => return Ok(()),
        };

        info!(
            "Telegram [{}]: reaction {} on message {}",
            chat_id, emoji, reaction.message_id.0
        );

        // Respond based on emoji type — Axi has personality!
        let response = match emoji.as_str() {
            // Positive reactions — Axi feels appreciated
            "❤" | "❤\u{200d}🔥" | "😍" | "🥰" | "💘" => {
                Some("Aww, gracias! Me alegra que te haya servido. Si necesitas algo mas, aqui estoy. 🩵".to_string())
            }
            "👍" | "👌" | "💯" | "🏆" => {
                // Save as positive feedback in memory
                if let Some(ref memory) = ctx.tool_ctx.memory {
                    let mem = memory.read().await;
                    let tags: Vec<String> =
                        vec!["reaction".into(), "positive".into()];
                    let _ = mem
                        .add_entry(
                            "feedback",
                            "telegram",
                            &tags,
                            Some("reaction"),
                            50,
                            "El usuario reacciono positivamente a mi respuesta",
                        )
                        .await;
                }
                Some("Perfecto, anotado! Seguire por esa linea.".to_string())
            }
            // Celebratory — Axi celebrates too
            "🎉" | "🤩" | "🔥" | "⚡" => {
                Some("Eso! A seguir con todo!".to_string())
            }
            // Thinking/confused — Axi offers to explain
            "🤔" | "🤨" | "😐" => {
                Some("Hmm, veo que no quedo claro. Quieres que te lo explique de otra forma?".to_string())
            }
            // Negative — Axi learns and adapts
            "👎" | "😢" | "💔" => {
                if let Some(ref memory) = ctx.tool_ctx.memory {
                    let mem = memory.read().await;
                    let tags: Vec<String> =
                        vec!["reaction".into(), "negative".into()];
                    let _ = mem
                        .add_entry(
                            "feedback",
                            "telegram",
                            &tags,
                            Some("reaction"),
                            60,
                            "El usuario reacciono negativamente — ajustar enfoque",
                        )
                        .await;
                }
                Some("Entendido, no fue lo que esperabas. Dime como puedo mejorar y lo corrijo.".to_string())
            }
            // Laughter — Axi is glad to amuse
            "😁" | "🤣" | "😂" => {
                Some("Jaja me da gusto que te haya sacado una sonrisa!".to_string())
            }
            // Praying/thanks — Axi is humble
            "🙏" | "🤗" | "🫡" => {
                Some("Para eso estoy! Siempre listo para ayudarte.".to_string())
            }
            // Surprise/shock — Axi is curious
            "🤯" | "😱" | "😨" => {
                Some("Impresionante verdad? Si tienes preguntas, dime!".to_string())
            }
            // Sleepy — Axi notices
            "😴" | "🥱" => {
                Some("Te noto cansado. Tal vez es buen momento para un descanso?".to_string())
            }
            // Other emojis — generic acknowledgment
            _ => None,
        };

        if let Some(text) = response {
            bot.send_message(chat_id, text).await?;
        }

        Ok(())
    }

    // -----------------------------------------------------------------------
    // Message classifier — decide how to handle each message
    // -----------------------------------------------------------------------

    #[derive(Debug)]
    enum MessageType {
        /// Respond immediately without LLM (greetings, acks, commands).
        Instant,
        /// Short LLM call — respond inline (questions, short chat).
        Quick,
        /// Long task — delegate to async worker so Axi stays free.
        Task,
    }

    fn classify_message(text: &str) -> MessageType {
        let lower = text.to_lowercase();
        let trimmed = lower.trim();

        // Instant responses (no LLM needed)
        if matches!(
            trimmed,
            "hola"
                | "hi"
                | "hey"
                | "hello"
                | "buenos dias"
                | "buenas tardes"
                | "buenas noches"
                | "gracias"
                | "thanks"
                | "ok"
                | "vale"
                | "perfecto"
        ) {
            return MessageType::Instant;
        }

        // Task indicators (delegate to async worker)
        let task_keywords = [
            "ejecuta",
            "busca",
            "resume",
            "analiza",
            "instala",
            "crea",
            "genera",
            "escribe",
            "programa",
            "compila",
            "investiga",
            "descarga",
            "configura",
            "/do",
            "haz",
            "hazme",
            "necesito que",
            "puedes hacer",
        ];

        for keyword in &task_keywords {
            if lower.contains(keyword) {
                return MessageType::Task;
            }
        }

        // Long messages (>200 chars) are likely tasks
        if text.len() > 200 {
            return MessageType::Task;
        }

        // Default: quick (short LLM response)
        MessageType::Quick
    }

    fn instant_response(text: &str) -> String {
        let lower = text.to_lowercase().trim().to_string();
        match lower.as_str() {
            "hola" | "hi" | "hey" | "hello" => "Hola! En que te puedo ayudar?".into(),
            "buenos dias" => "Buenos dias! Que necesitas?".into(),
            "buenas tardes" => "Buenas tardes! En que te ayudo?".into(),
            "buenas noches" => "Buenas noches! Dime.".into(),
            "gracias" | "thanks" => "De nada! Aqui estoy para lo que necesites.".into(),
            "ok" | "vale" | "perfecto" => "Perfecto!".into(),
            _ => {
                if lower.contains("hora") || lower.contains("time") {
                    crate::time_context::time_context()
                } else {
                    "En que te puedo ayudar?".into()
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Message handler — classifies and dispatches (never blocks on long tasks)
    // -----------------------------------------------------------------------

    async fn handle_message(
        bot: Bot,
        msg: Message,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let chat_id = msg.chat.id;
        let is_group = msg.chat.is_group() || msg.chat.is_supergroup();
        let history_key = history_key_for_message(&msg, chat_id.0);

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
        } else if !ctx.allowed_ids.is_empty()
            && !ctx.allowed_ids.contains(&chat_id.0)
            && !ctx.pairing.is_dynamic_allowed(chat_id.0).await
        {
            // Unknown user — check if their message is a pairing code
            if let Some(text) = msg.text() {
                let trimmed = text.trim();
                if trimmed.len() == 6 && trimmed.chars().all(|c| c.is_ascii_digit()) {
                    if let Some(inviter) = ctx.pairing.try_redeem(trimmed).await {
                        ctx.pairing.add_dynamic_id(chat_id.0).await;
                        bot.send_message(chat_id, "Vinculacion exitosa! Ya puedes hablar conmigo.")
                            .await?;
                        bot.send_message(
                            ChatId(inviter),
                            format!("Usuario {} vinculado exitosamente.", chat_id.0),
                        )
                        .await
                        .ok();
                        return Ok(());
                    }
                }
            }
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

        let reply_context = reply_context_prefix(&msg);

        // Voice messages: transcribe, then process as natural language
        if let Some(voice) = msg.voice() {
            return handle_voice(
                bot,
                chat_id,
                history_key,
                voice.file.id.clone(),
                reply_context,
                ctx,
            )
            .await;
        }

        // Videos: extract frame, then vision analysis through agentic loop
        if let Some(video) = msg.video() {
            let caption = sanitize_incoming_text(
                &msg.caption()
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| "Describe este video en español.".into()),
                &ctx.bot_username,
                is_group,
            );
            let prompt = apply_reply_context(&caption, reply_context.as_deref());
            return handle_video(bot, chat_id, history_key, &video.file.id, prompt, ctx).await;
        }

        // Photos: vision analysis through agentic loop
        if let Some(photo_id) = largest_photo(&msg) {
            let caption = sanitize_incoming_text(
                &msg.caption()
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| "Describe esta imagen en español.".into()),
                &ctx.bot_username,
                is_group,
            );
            let prompt = apply_reply_context(&caption, reply_context.as_deref());
            return handle_photo(bot, chat_id, history_key, photo_id, prompt, ctx).await;
        }

        // Text messages
        let text = match msg.text() {
            Some(t) => sanitize_incoming_text(t, &ctx.bot_username, is_group),
            None => {
                bot.send_message(chat_id, "Acepto texto, voz, fotos y videos.")
                    .await?;
                return Ok(());
            }
        };

        let text = apply_reply_context(&text, reply_context.as_deref());

        if text.is_empty() {
            return Ok(());
        }

        info!("Telegram [{}]: {}", chat_id, &text[..text.len().min(100)]);

        // Emit telegram_message event for dashboard feed
        if let Some(ref bus) = ctx.event_bus {
            let _ = bus.send(crate::events::DaemonEvent::TelegramMessage {
                text: text[..text.len().min(200)].to_string(),
                from: format!("{}", chat_id.0),
            });
        }

        // Legacy commands still work for backwards compatibility
        if text == "/help" || text == "/start" {
            return handle_help(bot, chat_id).await;
        }
        if text == "/actions" || text == "/acciones" {
            let keyboard = InlineKeyboardMarkup::new(vec![
                vec![
                    InlineKeyboardButton::callback("Estado del sistema", "action:system_status"),
                    InlineKeyboardButton::callback("Ver agenda", "action:show_agenda"),
                ],
                vec![
                    InlineKeyboardButton::callback("Volumen +", "action:volume_up"),
                    InlineKeyboardButton::callback("Volumen -", "action:volume_down"),
                ],
                vec![
                    InlineKeyboardButton::callback("Brillo +", "action:brightness_up"),
                    InlineKeyboardButton::callback("Brillo -", "action:brightness_down"),
                ],
                vec![
                    InlineKeyboardButton::callback("Captura pantalla", "action:screenshot"),
                    InlineKeyboardButton::callback("Bloquear pantalla", "action:lock_screen"),
                ],
                vec![
                    InlineKeyboardButton::callback("Estado firewall", "action:firewall_status"),
                    InlineKeyboardButton::callback("Limpiar cache", "action:cleanup_cache"),
                ],
            ]);
            bot.send_message(chat_id, "Acciones rapidas:")
                .reply_markup(keyboard)
                .await?;
            return Ok(());
        }
        if text == "/pair" || text.starts_with("/pair ") {
            let code = ctx.pairing.create_code(chat_id.0).await;
            bot.send_message(
                chat_id,
                format!(
                    "Codigo de vinculacion: {}\n\n\
                     Dale este codigo a la persona que quieres agregar. \
                     Tiene 10 minutos para enviarmelo.",
                    code
                ),
            )
            .await?;
            return Ok(());
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

        // Cancel active worker — "cancela", "para", "stop"
        {
            let lower = text.to_lowercase();
            let trimmed = lower.trim();
            if trimmed == "cancela" || trimmed == "para" || trimmed == "stop" || trimmed == "cancel"
            {
                let active = ctx.worker_pool.active_workers(chat_id.0).await;
                if let Some(latest) = active.last() {
                    let tid = latest.task_id.clone();
                    let desc = latest.description.clone();
                    if ctx.worker_pool.cancel(&tid).await {
                        bot.send_message(
                            chat_id,
                            format!("Tarea cancelada: {}", &desc[..desc.len().min(60)]),
                        )
                        .await?;
                    } else {
                        bot.send_message(chat_id, "No se pudo cancelar la tarea.")
                            .await?;
                    }
                } else {
                    bot.send_message(chat_id, "No hay tareas activas para cancelar.")
                        .await?;
                }
                return Ok(());
            }
        }

        // Steering — if there's an active worker, feed the message as context
        if let Some(active_tid) = ctx.worker_pool.active_worker_for_chat(chat_id.0).await {
            // Only steer if the message doesn't look like a new command
            if !text.starts_with('/') {
                ctx.worker_pool.steer(&active_tid, text.clone()).await;
                bot.send_message(
                    chat_id,
                    "Contexto adicional recibido. La tarea activa lo tomara en cuenta.",
                )
                .await?;
                return Ok(());
            }
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
            if !ctx.worker_pool.can_spawn(chat_id.0).await {
                bot.send_message(
                    chat_id,
                    "Tengo 3 tareas en proceso. Espera a que termine una.",
                )
                .await?;
                return Ok(());
            }

            let task_id = uuid::Uuid::new_v4().to_string();
            let desc = format!("trust: {}", &task_text[..task_text.len().min(60)]);
            ctx.worker_pool
                .register(task_id.clone(), chat_id.0, desc)
                .await;

            bot.send_message(
                chat_id,
                format!("Modo trust activado. Ejecutando: {}", task_text),
            )
            .await?;

            let worker_ctx = ctx.tool_ctx.clone();
            let worker_bot = bot.clone();
            let worker_pool = ctx.worker_pool.clone();
            let worker_text = build_trust_task_prompt(task_text);
            let cancel_flag = ctx.worker_pool.get_cancel_flag(&task_id).await;

            tokio::spawn(async move {
                worker_bot
                    .send_message(chat_id, "Ejecutando en modo trust...")
                    .await
                    .ok();

                // Check cancellation
                if let Some(ref flag) = cancel_flag {
                    if flag.load(std::sync::atomic::Ordering::SeqCst) {
                        worker_pool.cancel(&task_id).await;
                        return;
                    }
                }

                let (response, screenshot_path) =
                    telegram_tools::agentic_chat(&worker_ctx, chat_id.0, &worker_text, None).await;

                // Check cancellation after work
                if let Some(ref flag) = cancel_flag {
                    if flag.load(std::sync::atomic::Ordering::SeqCst) {
                        worker_bot
                            .send_message(chat_id, "Tarea cancelada.")
                            .await
                            .ok();
                        return;
                    }
                }

                send_full_response(&worker_bot, chat_id, &response, screenshot_path.as_deref())
                    .await
                    .ok();

                worker_pool.complete(&task_id).await;
            });

            return Ok(());
        }

        // /btw — side conversation that doesn't pollute main history
        if text.starts_with("/btw ") {
            let side_text = text.strip_prefix("/btw ").unwrap_or(&text);
            // Use a separate "side" chat_id so it doesn't mix with main history
            let side_id = chat_id.0 ^ 0x7F7F_7F7F; // XOR to create distinct ID

            if !ctx.worker_pool.can_spawn(chat_id.0).await {
                bot.send_message(
                    chat_id,
                    "Tengo 3 tareas en proceso. Espera a que termine una.",
                )
                .await?;
                return Ok(());
            }

            let task_id = uuid::Uuid::new_v4().to_string();
            ctx.worker_pool
                .register(
                    task_id.clone(),
                    chat_id.0,
                    "btw: conversacion lateral".into(),
                )
                .await;

            bot.send_message(chat_id, "Procesando (conversacion lateral)...")
                .await?;

            let worker_ctx = ctx.tool_ctx.clone();
            let worker_bot = bot.clone();
            let worker_pool = ctx.worker_pool.clone();
            let worker_text = side_text.to_string();

            tokio::spawn(async move {
                let (response, screenshot_path) =
                    telegram_tools::agentic_chat(&worker_ctx, side_id, &worker_text, None).await;
                // Clear the side conversation immediately after (no summary for /btw)
                let _ = worker_ctx.history.clear(side_id).await;

                send_full_response(&worker_bot, chat_id, &response, screenshot_path.as_deref())
                    .await
                    .ok();

                worker_pool.complete(&task_id).await;
            });

            return Ok(());
        }

        // Classify and dispatch — Axi never blocks on long tasks
        match classify_message(&text) {
            MessageType::Instant => {
                let response = instant_response(&text);
                bot.send_message(chat_id, &response).await?;
                return Ok(());
            }
            MessageType::Quick => {
                // Streaming UX: send placeholder, then edit with final response
                let placeholder = bot.send_message(chat_id, "...").await?;
                let (response, screenshot_path) = with_typing(&bot, chat_id, async {
                    telegram_tools::agentic_chat(&ctx.tool_ctx, history_key, &text, None).await
                })
                .await;
                // If response is short and has no special markers, edit the placeholder
                if screenshot_path.is_none()
                    && !response.contains("--- CHECKPOINT ---")
                    && !response.contains("__SEND_FILE__:")
                    && response.len() <= 4000
                {
                    let html = markdown_to_html(&response);
                    bot.edit_message_text(chat_id, placeholder.id, &html)
                        .parse_mode(teloxide::types::ParseMode::Html)
                        .await
                        .ok();
                } else {
                    // Complex response — delete placeholder and send full response
                    bot.delete_message(chat_id, placeholder.id).await.ok();
                    send_full_response(&bot, chat_id, &response, screenshot_path.as_deref())
                        .await?;
                }
            }
            MessageType::Task => {
                // Long task — delegate to async worker so Axi stays free
                if !ctx.worker_pool.can_spawn(chat_id.0).await {
                    bot.send_message(
                        chat_id,
                        "Tengo 3 tareas en proceso. Espera a que termine una.",
                    )
                    .await?;
                    return Ok(());
                }

                let task_id = uuid::Uuid::new_v4().to_string();
                let desc = text[..text.len().min(80)].to_string();
                ctx.worker_pool
                    .register(task_id.clone(), chat_id.0, desc)
                    .await;

                // Acknowledge immediately — Axi is free for more messages
                bot.send_message(chat_id, "Estoy en eso. Te aviso cuando termine.")
                    .await?;

                let worker_ctx = ctx.tool_ctx.clone();
                let worker_bot = bot.clone();
                let worker_pool = ctx.worker_pool.clone();
                let worker_text = text.clone();
                let cancel_flag = ctx.worker_pool.get_cancel_flag(&task_id).await;

                tokio::spawn(async move {
                    // Progress: starting
                    worker_bot.send_message(chat_id, "Analizando...").await.ok();

                    // Check cancellation before expensive work
                    if let Some(ref flag) = cancel_flag {
                        if flag.load(std::sync::atomic::Ordering::SeqCst) {
                            worker_pool.cancel(&task_id).await;
                            return;
                        }
                    }

                    let (response, screenshot_path) =
                        telegram_tools::agentic_chat(&worker_ctx, history_key, &worker_text, None)
                            .await;

                    // Check cancellation after work completes
                    if let Some(ref flag) = cancel_flag {
                        if flag.load(std::sync::atomic::Ordering::SeqCst) {
                            worker_bot
                                .send_message(chat_id, "Tarea cancelada.")
                                .await
                                .ok();
                            return;
                        }
                    }

                    if let Err(e) = send_full_response(
                        &worker_bot,
                        chat_id,
                        &response,
                        screenshot_path.as_deref(),
                    )
                    .await
                    {
                        error!("Worker send failed: {}", e);
                        worker_pool.fail(&task_id, e.to_string()).await;
                        return;
                    }

                    worker_pool.complete(&task_id).await;
                });

                return Ok(());
            }
        }

        Ok(())
    }

    // -----------------------------------------------------------------------
    // Voice handling — transcribe then run through agentic loop
    // -----------------------------------------------------------------------

    async fn handle_voice(
        bot: Bot,
        chat_id: ChatId,
        history_key: i64,
        file_id: String,
        reply_context: Option<String>,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        info!("Telegram [{}]: voice message received", chat_id);
        if !ctx.worker_pool.can_spawn(chat_id.0).await {
            bot.send_message(
                chat_id,
                "Tengo 3 tareas en proceso. Espera a que termine una.",
            )
            .await?;
            return Ok(());
        }

        let task_id = uuid::Uuid::new_v4().to_string();
        let desc = "voz: transcripcion y respuesta".to_string();
        ctx.worker_pool
            .register(task_id.clone(), chat_id.0, desc)
            .await;

        bot.send_message(chat_id, "Recibi tu audio. Lo estoy transcribiendo...")
            .await?;

        let worker_ctx = ctx.tool_ctx.clone();
        let worker_bot = bot.clone();
        let worker_pool = ctx.worker_pool.clone();
        let cancel_flag = ctx.worker_pool.get_cancel_flag(&task_id).await;

        tokio::spawn(async move {
            worker_bot
                .send_chat_action(chat_id, ChatAction::Typing)
                .await
                .ok();

            let tmp_dir = std::env::temp_dir().join("lifeos-telegram");
            tokio::fs::create_dir_all(&tmp_dir).await.ok();
            let ogg_path = tmp_dir.join(format!(
                "voice-{}-{}.ogg",
                chat_id.0,
                chrono::Utc::now().timestamp_millis()
            ));
            let wav_path = ogg_path.with_extension("wav");

            if let Some(ref flag) = cancel_flag {
                if flag.load(std::sync::atomic::Ordering::SeqCst) {
                    worker_pool.cancel(&task_id).await;
                    return;
                }
            }

            let file = match worker_bot.get_file(&file_id).await {
                Ok(file) => file,
                Err(err) => {
                    worker_bot
                        .send_message(chat_id, "No pude descargar tu audio de Telegram.")
                        .await
                        .ok();
                    worker_pool.fail(&task_id, err.to_string()).await;
                    return;
                }
            };

            let transcription_result = async {
                let mut ogg_file = tokio::fs::File::create(&ogg_path).await?;
                worker_bot.download_file(&file.path, &mut ogg_file).await?;

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
                    .await?;
                if !ffmpeg.status.success() {
                    anyhow::bail!("ffmpeg failed to convert voice note");
                }

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
                    .await?;
                if !output.status.success() {
                    anyhow::bail!("whisper-cli failed to transcribe voice note");
                }

                Ok::<String, anyhow::Error>(
                    String::from_utf8_lossy(&output.stdout).trim().to_string(),
                )
            }
            .await;

            tokio::fs::remove_file(&ogg_path).await.ok();
            tokio::fs::remove_file(&wav_path).await.ok();

            let transcription = match transcription_result {
                Ok(text) if !text.is_empty() => text,
                Ok(_) => {
                    worker_bot
                        .send_message(chat_id, "(Audio vacio o no se entendio)")
                        .await
                        .ok();
                    worker_pool.complete(&task_id).await;
                    return;
                }
                Err(err) => {
                    worker_bot
                        .send_message(chat_id, "No pude transcribir el audio.")
                        .await
                        .ok();
                    worker_pool.fail(&task_id, err.to_string()).await;
                    return;
                }
            };

            if let Some(ref flag) = cancel_flag {
                if flag.load(std::sync::atomic::Ordering::SeqCst) {
                    worker_pool.cancel(&task_id).await;
                    return;
                }
            }

            info!(
                "Telegram voice transcribed: {}",
                &transcription[..transcription.len().min(80)]
            );
            worker_bot
                .send_message(
                    chat_id,
                    format!(
                        "(tu dijiste: {})\n\nProcesando...",
                        &transcription[..transcription.len().min(200)]
                    ),
                )
                .await
                .ok();

            let prompt = apply_reply_context(&transcription, reply_context.as_deref());
            let (response, screenshot_path) =
                telegram_tools::agentic_chat(&worker_ctx, history_key, &prompt, None).await;

            if let Some(ref flag) = cancel_flag {
                if flag.load(std::sync::atomic::Ordering::SeqCst) {
                    worker_bot
                        .send_message(chat_id, "Tarea cancelada.")
                        .await
                        .ok();
                    worker_pool.cancel(&task_id).await;
                    return;
                }
            }

            // Send screenshot if one was taken
            if let Some(ref path) = screenshot_path {
                let screenshot_file = std::path::Path::new(path);
                if screenshot_file.exists() {
                    worker_bot
                        .send_document(chat_id, InputFile::file(screenshot_file))
                        .await
                        .ok();
                    tokio::fs::remove_file(screenshot_file).await.ok();
                }
            }

            // Try to send a voice response — Piper first, then espeak-ng fallback
            let voice_path = match text_to_voice(&response).await {
                Some(path) => Some(path),
                None => {
                    warn!("Piper TTS failed for Telegram voice reply, trying espeak-ng fallback");
                    text_to_voice_espeak(&response).await
                }
            };

            if let Some(audio_path) = voice_path {
                worker_bot
                    .send_voice(chat_id, InputFile::file(&audio_path))
                    .await
                    .ok();
                tokio::fs::remove_file(&audio_path).await.ok();
            }

            // Always send text so the user can read the response too
            send_chunked(&worker_bot, chat_id, &response).await.ok();

            worker_pool.complete(&task_id).await;
        });

        Ok(())
    }

    // -----------------------------------------------------------------------
    // Photo handling — through agentic loop with vision
    // -----------------------------------------------------------------------

    async fn handle_photo(
        bot: Bot,
        chat_id: ChatId,
        history_key: i64,
        file_id: String,
        prompt: String,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        info!("Telegram [{}]: photo received", chat_id);
        if !ctx.worker_pool.can_spawn(chat_id.0).await {
            bot.send_message(
                chat_id,
                "Tengo 3 tareas en proceso. Espera a que termine una.",
            )
            .await?;
            return Ok(());
        }

        let task_id = uuid::Uuid::new_v4().to_string();
        ctx.worker_pool
            .register(
                task_id.clone(),
                chat_id.0,
                "foto: analisis de imagen".into(),
            )
            .await;

        bot.send_message(chat_id, "Analizando imagen...").await?;

        let worker_ctx = ctx.tool_ctx.clone();
        let worker_bot = bot.clone();
        let worker_pool = ctx.worker_pool.clone();
        let cancel_flag = ctx.worker_pool.get_cancel_flag(&task_id).await;

        tokio::spawn(async move {
            let tmp_dir = std::env::temp_dir().join("lifeos-telegram");
            tokio::fs::create_dir_all(&tmp_dir).await.ok();
            let img_path = tmp_dir.join(format!(
                "photo-{}-{}.jpg",
                chat_id.0,
                chrono::Utc::now().timestamp_millis()
            ));

            if let Some(ref flag) = cancel_flag {
                if flag.load(std::sync::atomic::Ordering::SeqCst) {
                    worker_pool.cancel(&task_id).await;
                    return;
                }
            }

            let file = match worker_bot.get_file(&file_id).await {
                Ok(file) => file,
                Err(err) => {
                    worker_bot
                        .send_message(chat_id, "No pude descargar la imagen desde Telegram.")
                        .await
                        .ok();
                    worker_pool.fail(&task_id, err.to_string()).await;
                    return;
                }
            };

            let image_payload = async {
                let mut img_file = tokio::fs::File::create(&img_path).await?;
                worker_bot.download_file(&file.path, &mut img_file).await?;
                let img_bytes = tokio::fs::read(&img_path).await?;
                use base64::Engine;
                Ok::<String, anyhow::Error>(format!(
                    "data:image/jpeg;base64,{}",
                    base64::engine::general_purpose::STANDARD.encode(&img_bytes)
                ))
            }
            .await;
            tokio::fs::remove_file(&img_path).await.ok();

            let data_url = match image_payload {
                Ok(data_url) => data_url,
                Err(err) => {
                    worker_bot
                        .send_message(chat_id, "No pude preparar la imagen para analizarla.")
                        .await
                        .ok();
                    worker_pool.fail(&task_id, err.to_string()).await;
                    return;
                }
            };

            if let Some(ref flag) = cancel_flag {
                if flag.load(std::sync::atomic::Ordering::SeqCst) {
                    worker_pool.cancel(&task_id).await;
                    return;
                }
            }

            let (response, screenshot_path) =
                telegram_tools::agentic_chat(&worker_ctx, history_key, &prompt, Some(&data_url))
                    .await;

            if let Some(ref flag) = cancel_flag {
                if flag.load(std::sync::atomic::Ordering::SeqCst) {
                    worker_bot
                        .send_message(chat_id, "Tarea cancelada.")
                        .await
                        .ok();
                    worker_pool.cancel(&task_id).await;
                    return;
                }
            }

            if let Some(ref path) = screenshot_path {
                let screenshot_file = std::path::Path::new(path);
                if screenshot_file.exists() {
                    worker_bot
                        .send_document(chat_id, InputFile::file(screenshot_file))
                        .await
                        .ok();
                    tokio::fs::remove_file(screenshot_file).await.ok();
                }
            }

            send_chunked(&worker_bot, chat_id, &response).await.ok();
            worker_pool.complete(&task_id).await;
        });

        Ok(())
    }

    // -----------------------------------------------------------------------
    // Video handling — extract frame then vision analysis
    // -----------------------------------------------------------------------

    async fn handle_video(
        bot: Bot,
        chat_id: ChatId,
        history_key: i64,
        video_file_id: &str,
        prompt: String,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        info!("Telegram [{}]: video received", chat_id);
        if !ctx.worker_pool.can_spawn(chat_id.0).await {
            bot.send_message(
                chat_id,
                "Tengo 3 tareas en proceso. Espera a que termine una.",
            )
            .await?;
            return Ok(());
        }

        bot.send_chat_action(chat_id, ChatAction::Typing).await.ok();
        let _ = bot.send_message(chat_id, "Analizando video...").await;

        let task_id = uuid::Uuid::new_v4().to_string();
        ctx.worker_pool
            .register(
                task_id.clone(),
                chat_id.0,
                "video: analisis de frame".into(),
            )
            .await;

        let worker_ctx = ctx.tool_ctx.clone();
        let worker_bot = bot.clone();
        let worker_pool = ctx.worker_pool.clone();
        let video_file_id = video_file_id.to_string();
        let cancel_flag = ctx.worker_pool.get_cancel_flag(&task_id).await;

        tokio::spawn(async move {
            let tmp_dir = std::env::temp_dir().join("lifeos-telegram");
            tokio::fs::create_dir_all(&tmp_dir).await.ok();
            let video_path = tmp_dir.join(format!(
                "video-{}-{}.mp4",
                chat_id.0,
                chrono::Utc::now().timestamp_millis()
            ));
            let frame_path = tmp_dir.join(format!(
                "frame-{}-{}.jpg",
                chat_id.0,
                chrono::Utc::now().timestamp_millis()
            ));

            if let Some(ref flag) = cancel_flag {
                if flag.load(std::sync::atomic::Ordering::SeqCst) {
                    worker_pool.cancel(&task_id).await;
                    return;
                }
            }

            let file = match worker_bot.get_file(&video_file_id).await {
                Ok(file) => file,
                Err(err) => {
                    worker_bot
                        .send_message(chat_id, "No pude descargar el video desde Telegram.")
                        .await
                        .ok();
                    worker_pool.fail(&task_id, err.to_string()).await;
                    return;
                }
            };

            let video_payload = async {
                let mut dst = tokio::fs::File::create(&video_path).await?;
                worker_bot.download_file(&file.path, &mut dst).await?;

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
                    .await?;

                if !ffmpeg.status.success() || !frame_path.exists() {
                    let fallback = tokio::process::Command::new("ffmpeg")
                        .args([
                            "-y",
                            "-i",
                            video_path.to_str().unwrap_or_default(),
                            "-vframes",
                            "1",
                            frame_path.to_str().unwrap_or_default(),
                        ])
                        .output()
                        .await?;
                    if !fallback.status.success() || !frame_path.exists() {
                        anyhow::bail!("ffmpeg failed to extract preview frame from video");
                    }
                }

                let bytes = tokio::fs::read(&frame_path).await?;
                use base64::Engine;
                Ok::<String, anyhow::Error>(format!(
                    "data:image/jpeg;base64,{}",
                    base64::engine::general_purpose::STANDARD.encode(&bytes)
                ))
            }
            .await;

            let _ = tokio::fs::remove_file(&video_path).await;
            let _ = tokio::fs::remove_file(&frame_path).await;

            let data_url = match video_payload {
                Ok(data_url) => data_url,
                Err(err) => {
                    worker_bot
                        .send_message(chat_id, "No pude extraer un frame del video.")
                        .await
                        .ok();
                    worker_pool.fail(&task_id, err.to_string()).await;
                    return;
                }
            };

            if let Some(ref flag) = cancel_flag {
                if flag.load(std::sync::atomic::Ordering::SeqCst) {
                    worker_pool.cancel(&task_id).await;
                    return;
                }
            }

            let (response, screenshot_path) =
                telegram_tools::agentic_chat(&worker_ctx, history_key, &prompt, Some(&data_url))
                    .await;

            if let Some(ref flag) = cancel_flag {
                if flag.load(std::sync::atomic::Ordering::SeqCst) {
                    worker_bot
                        .send_message(chat_id, "Tarea cancelada.")
                        .await
                        .ok();
                    worker_pool.cancel(&task_id).await;
                    return;
                }
            }

            if let Some(ref path) = screenshot_path {
                let screenshot_file = std::path::Path::new(path);
                if screenshot_file.exists() {
                    worker_bot
                        .send_document(chat_id, InputFile::file(screenshot_file))
                        .await
                        .ok();
                    tokio::fs::remove_file(screenshot_file).await.ok();
                }
            }

            send_chunked(&worker_bot, chat_id, &response).await.ok();
            worker_pool.complete(&task_id).await;
        });

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
        } else if let Some(action) = data.strip_prefix("action:") {
            info!("Telegram: {} action triggered", action);
            match action {
                "cleanup_cache" => {
                    bot.send_message(chat_id, "Limpiando cache del sistema...")
                        .await?;
                    let (response, _) = telegram_tools::agentic_chat(
                        &ctx.tool_ctx,
                        chat_id.0,
                        "Limpia caches del sistema: journalctl --vacuum-size=200M, \
                         elimina /tmp/lifeos-* antiguos, y reporta espacio liberado.",
                        None,
                    )
                    .await;
                    send_chunked(&bot, chat_id, &response).await?;
                }
                "dismiss" => {
                    // Remove buttons from the original message
                    if let Some(msg) = q.message.as_ref() {
                        bot.edit_message_reply_markup(chat_id, msg.id()).await.ok();
                    }
                }
                a if a.starts_with("service_start:") => {
                    let service = a.strip_prefix("service_start:").unwrap_or("");
                    bot.send_message(chat_id, format!("Activando {}...", service))
                        .await?;
                    let args = serde_json::json!({"service": service, "action": "start"});
                    let result = telegram_tools::execute_tool(
                        &telegram_tools::ToolCall {
                            name: "service_manage".into(),
                            args,
                        },
                        &ctx.tool_ctx,
                    )
                    .await;
                    bot.send_message(chat_id, result.output).await?;
                }
                "top_processes" => {
                    bot.send_message(chat_id, "Consultando procesos...").await?;
                    let (response, _) = telegram_tools::agentic_chat(
                        &ctx.tool_ctx,
                        chat_id.0,
                        "Ejecuta: ps aux --sort=-%mem | head -10 y muestrame los procesos que mas recursos usan",
                        None,
                    )
                    .await;
                    send_chunked(&bot, chat_id, &response).await?;
                }
                "disk_usage" => {
                    bot.send_message(chat_id, "Consultando disco...").await?;
                    let (response, _) = telegram_tools::agentic_chat(
                        &ctx.tool_ctx,
                        chat_id.0,
                        "Ejecuta df -h /var y du -sh /var/lib/lifeos/* 2>/dev/null | sort -rh | head -10 para ver que ocupa mas espacio",
                        None,
                    )
                    .await;
                    send_chunked(&bot, chat_id, &response).await?;
                }
                "break_ack" => {
                    if let Some(msg) = q.message.as_ref() {
                        bot.edit_message_reply_markup(chat_id, msg.id()).await.ok();
                    }
                    bot.send_message(
                        chat_id,
                        "Perfecto! Disfruta tu descanso. Te aviso cuando vuelvas.",
                    )
                    .await?;
                }
                a if a.starts_with("snooze:") => {
                    let minutes: u64 = a
                        .strip_prefix("snooze:")
                        .and_then(|m| m.parse().ok())
                        .unwrap_or(15);
                    if let Some(msg) = q.message.as_ref() {
                        bot.edit_message_reply_markup(chat_id, msg.id()).await.ok();
                    }
                    bot.send_message(chat_id, format!("Te recuerdo en {} minutos.", minutes))
                        .await?;
                    // Schedule a delayed reminder
                    let snooze_bot = bot.clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(std::time::Duration::from_secs(minutes * 60)).await;
                        snooze_bot
                            .send_message(
                                chat_id,
                                "Recordatorio: ya pasaron tus minutos de gracia!",
                            )
                            .await
                            .ok();
                    });
                }
                "prompt_calendar" => {
                    bot.send_message(
                        chat_id,
                        "Dime que evento agregar. Ejemplo: 'Junta con equipo manana a las 10am'",
                    )
                    .await?;
                }
                "update" => {
                    bot.send_message(chat_id, "Verificando actualizaciones...")
                        .await?;
                    let (response, _) = telegram_tools::agentic_chat(
                        &ctx.tool_ctx,
                        chat_id.0,
                        "Ejecuta: sudo bootc upgrade --check y dime si hay actualizacion disponible",
                        None,
                    )
                    .await;
                    send_chunked(&bot, chat_id, &response).await?;
                }
                "meeting_summary" => {
                    bot.send_message(chat_id, "Buscando resumen de la ultima reunion...")
                        .await?;
                    let (response, _) = telegram_tools::agentic_chat(
                        &ctx.tool_ctx,
                        chat_id.0,
                        "Busca la reunion mas reciente y dame el resumen completo con action items",
                        None,
                    )
                    .await;
                    send_chunked(&bot, chat_id, &response).await?;
                }
                "free_ram" => {
                    bot.send_message(chat_id, "Liberando memoria...").await?;
                    let (response, _) = telegram_tools::agentic_chat(
                        &ctx.tool_ctx,
                        chat_id.0,
                        "Ejecuta: sync && echo 3 | sudo tee /proc/sys/vm/drop_caches. Luego muestra el estado actual con free -h",
                        None,
                    )
                    .await;
                    send_chunked(&bot, chat_id, &response).await?;
                }
                "retry_task" => {
                    bot.send_message(chat_id, "Reintentando tarea...").await?;
                    // Acknowledge — task context would be needed for a real retry
                }
                "system_status" => {
                    bot.send_message(chat_id, "Consultando estado del sistema...")
                        .await?;
                    let result = telegram_tools::execute_tool(
                        &telegram_tools::ToolCall {
                            name: "system_status".into(),
                            args: serde_json::json!({}),
                        },
                        &ctx.tool_ctx,
                    )
                    .await;
                    send_chunked(&bot, chat_id, &result.output).await?;
                }
                "show_agenda" => {
                    bot.send_message(chat_id, "Consultando agenda...").await?;
                    let (response, _) = telegram_tools::agentic_chat(
                        &ctx.tool_ctx,
                        chat_id.0,
                        "Muestrame mi agenda de hoy y manana con todos los eventos",
                        None,
                    )
                    .await;
                    send_chunked(&bot, chat_id, &response).await?;
                }
                "volume_up" => {
                    let result = telegram_tools::execute_tool(
                        &telegram_tools::ToolCall {
                            name: "run_command".into(),
                            args: serde_json::json!({"command": "wpctl set-volume @DEFAULT_AUDIO_SINK@ 10%+"}),
                        },
                        &ctx.tool_ctx,
                    )
                    .await;
                    bot.send_message(
                        chat_id,
                        if result.success {
                            "Volumen subido."
                        } else {
                            "No se pudo ajustar el volumen."
                        },
                    )
                    .await?;
                }
                "volume_down" => {
                    let result = telegram_tools::execute_tool(
                        &telegram_tools::ToolCall {
                            name: "run_command".into(),
                            args: serde_json::json!({"command": "wpctl set-volume @DEFAULT_AUDIO_SINK@ 10%-"}),
                        },
                        &ctx.tool_ctx,
                    )
                    .await;
                    bot.send_message(
                        chat_id,
                        if result.success {
                            "Volumen bajado."
                        } else {
                            "No se pudo ajustar el volumen."
                        },
                    )
                    .await?;
                }
                "brightness_up" => {
                    let result = telegram_tools::execute_tool(
                        &telegram_tools::ToolCall {
                            name: "run_command".into(),
                            args: serde_json::json!({"command": "brightnessctl set +10%"}),
                        },
                        &ctx.tool_ctx,
                    )
                    .await;
                    bot.send_message(
                        chat_id,
                        if result.success {
                            "Brillo aumentado."
                        } else {
                            "No se pudo ajustar el brillo."
                        },
                    )
                    .await?;
                }
                "brightness_down" => {
                    let result = telegram_tools::execute_tool(
                        &telegram_tools::ToolCall {
                            name: "run_command".into(),
                            args: serde_json::json!({"command": "brightnessctl set 10%-"}),
                        },
                        &ctx.tool_ctx,
                    )
                    .await;
                    bot.send_message(
                        chat_id,
                        if result.success {
                            "Brillo reducido."
                        } else {
                            "No se pudo ajustar el brillo."
                        },
                    )
                    .await?;
                }
                "screenshot" => {
                    bot.send_message(chat_id, "Tomando captura...").await?;
                    let result = telegram_tools::execute_tool(
                        &telegram_tools::ToolCall {
                            name: "screenshot".into(),
                            args: serde_json::json!({}),
                        },
                        &ctx.tool_ctx,
                    )
                    .await;
                    // The output contains the file path
                    let path = result.output.trim();
                    let screenshot_file = std::path::Path::new(path);
                    if screenshot_file.exists() {
                        bot.send_document(chat_id, InputFile::file(screenshot_file))
                            .await?;
                        tokio::fs::remove_file(screenshot_file).await.ok();
                    } else {
                        bot.send_message(chat_id, "No se pudo tomar la captura.")
                            .await?;
                    }
                }
                "lock_screen" => {
                    let result = telegram_tools::execute_tool(
                        &telegram_tools::ToolCall {
                            name: "run_command".into(),
                            args: serde_json::json!({"command": "loginctl lock-session"}),
                        },
                        &ctx.tool_ctx,
                    )
                    .await;
                    bot.send_message(
                        chat_id,
                        if result.success {
                            "Pantalla bloqueada."
                        } else {
                            "No se pudo bloquear la pantalla."
                        },
                    )
                    .await?;
                }
                "firewall_status" => {
                    bot.send_message(chat_id, "Consultando firewall...").await?;
                    let result = telegram_tools::execute_tool(
                        &telegram_tools::ToolCall {
                            name: "service_manage".into(),
                            args: serde_json::json!({"service": "nftables", "action": "status"}),
                        },
                        &ctx.tool_ctx,
                    )
                    .await;
                    send_chunked(&bot, chat_id, &result.output).await?;
                }
                _ => {
                    warn!("Unknown action callback: {}", action);
                    bot.send_message(chat_id, format!("Accion no reconocida: {}", action))
                        .await?;
                }
            }
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
             /acciones — Controles rapidos con botones\n\
             /btw <texto> — Conversacion lateral\n\
             /do <tarea> — Ejecutar tarea\n\
             /pair — Generar codigo para vincular nuevo usuario\n\
             /help — Este mensaje\n\n\
             Escribe /acciones para ver controles rapidos con botones.\n\n\
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

        // Active async workers
        let active_workers = ctx.worker_pool.active_workers(chat_id.0).await;
        let workers_count = active_workers.len();
        let worker_details: String = if active_workers.is_empty() {
            String::new()
        } else {
            let lines: Vec<String> = active_workers
                .iter()
                .map(|w| {
                    let elapsed = (chrono::Utc::now() - w.started_at).num_seconds();
                    format!("  - [{}] {} ({}s)", &w.task_id[..8], w.description, elapsed)
                })
                .collect();
            format!("\n{}", lines.join("\n"))
        };

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
             Tareas pendientes: {} | ejecutando: {}\n\
             Workers activos: {}{}",
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
            workers_count,
            worker_details,
        );

        bot.send_message(chat_id, status_text).await?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Shared helpers
    // -----------------------------------------------------------------------

    /// Send a full agentic response: screenshots, SDD checkpoints, file attachments, chunked text.
    async fn send_full_response(
        bot: &Bot,
        chat_id: ChatId,
        response: &str,
        screenshot_path: Option<&str>,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        // If SDD checkpoint, send inline buttons for approval
        if response.contains("--- CHECKPOINT ---") {
            if let Some(sdd_id) = response
                .lines()
                .find(|l| l.starts_with("SDD ID: "))
                .map(|l| l.strip_prefix("SDD ID: ").unwrap_or("").trim().to_string())
            {
                let clean_response = response
                    .split("--- CHECKPOINT ---")
                    .next()
                    .unwrap_or(response);
                send_chunked(bot, chat_id, clean_response).await?;

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
                        phase_name,
                    ),
                )
                .reply_markup(keyboard)
                .await?;

                return Ok(());
            }
        }

        // Send screenshot if one was taken
        if let Some(path) = screenshot_path {
            let screenshot_file = std::path::Path::new(path);
            if screenshot_file.exists() {
                bot.send_document(chat_id, InputFile::file(screenshot_file))
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
            let clean = response
                .lines()
                .filter(|l| !l.contains("__SEND_FILE__:"))
                .collect::<Vec<_>>()
                .join("\n");
            if !clean.trim().is_empty() {
                send_chunked(bot, chat_id, &clean).await?;
            }
        } else {
            send_chunked(bot, chat_id, response).await?;
        }

        Ok(())
    }

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
    /// Uses the same dynamic model resolution as sensory_pipeline for voice consistency.
    async fn text_to_voice(text: &str) -> Option<PathBuf> {
        use crate::sensory_pipeline::{resolve_binary, resolve_tts_model};

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

        // Resolve piper binary dynamically (same as sensory_pipeline)
        let piper_bin =
            resolve_binary("LIFEOS_TTS_BIN", &["lifeos-piper", "piper", "espeak-ng"]).await?;

        // Resolve voice model dynamically (same as sensory_pipeline)
        let model_path = resolve_tts_model(None).await?;

        let piper = tokio::process::Command::new(&piper_bin)
            .args([
                "--model",
                &model_path,
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
        use crate::sensory_pipeline::resolve_binary;

        let tmp_dir = std::env::temp_dir().join("lifeos-telegram");
        tokio::fs::create_dir_all(&tmp_dir).await.ok();
        let wav_path = tmp_dir.join(format!("tts-espeak-{}.wav", chrono::Utc::now().timestamp()));
        let ogg_path = wav_path.with_extension("ogg");

        let clean_text = if let Some(pos) = text.rfind("\n\n[") {
            &text[..pos]
        } else {
            text
        };

        // Resolve espeak binary dynamically
        let espeak_bin = resolve_binary("LIFEOS_TTS_FALLBACK_BIN", &["espeak-ng"])
            .await
            .unwrap_or_else(|| "espeak-ng".into());

        let espeak = tokio::process::Command::new(&espeak_bin)
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

    fn history_key_for_message(msg: &Message, chat_id: i64) -> i64 {
        msg.thread_id
            .map(|tid| chat_id ^ (tid.0 .0 as i64))
            .unwrap_or(chat_id)
    }

    fn sanitize_incoming_text(text: &str, bot_username: &str, is_group: bool) -> String {
        let mut value = text.to_string();
        if is_group && !bot_username.is_empty() {
            value = value.replace(&format!("@{}", bot_username), "");
        }
        if is_group && looks_like_axi_invocation(&value) {
            value = strip_axi_invocation_prefix(&value).to_string();
        }
        value.trim().to_string()
    }

    fn reply_context_prefix(msg: &Message) -> Option<String> {
        let reply = msg.reply_to_message()?;
        if let Some(reply_text) = reply.text() {
            return Some(format!(
                "[Respondiendo a este mensaje anterior: \"{}\"]",
                preview_text(reply_text, 300)
            ));
        }
        if let Some(caption) = reply.caption() {
            return Some(format!(
                "[Respondiendo a un mensaje con descripcion: \"{}\"]",
                preview_text(caption, 300)
            ));
        }
        if reply.voice().is_some() {
            return Some("[Respondiendo a un mensaje de voz anterior]".into());
        }
        if largest_photo(reply).is_some() {
            return Some("[Respondiendo a una imagen anterior]".into());
        }
        if reply.video().is_some() {
            return Some("[Respondiendo a un video anterior]".into());
        }
        if reply.document().is_some() {
            return Some("[Respondiendo a un archivo anterior]".into());
        }
        if reply.sticker().is_some() {
            return Some("[Respondiendo a un sticker anterior]".into());
        }
        Some("[Respondiendo a un mensaje anterior]".into())
    }

    fn preview_text(text: &str, limit: usize) -> String {
        if text.len() > limit {
            format!("{}...", &text[..limit])
        } else {
            text.to_string()
        }
    }

    fn apply_reply_context(text: &str, reply_context: Option<&str>) -> String {
        let trimmed = text.trim();
        match reply_context {
            Some(prefix) if !prefix.trim().is_empty() && !trimmed.is_empty() => {
                format!("{}\n\n{}", prefix.trim(), trimmed)
            }
            Some(prefix) if !prefix.trim().is_empty() => prefix.trim().to_string(),
            _ => trimmed.to_string(),
        }
    }

    async fn resolve_bot_username(bot: &Bot) -> String {
        let configured = configured_bot_username();
        for attempt in 1..=BOT_USERNAME_LOOKUP_ATTEMPTS {
            match bot.get_me().await {
                Ok(me) => {
                    if let Some(username) = me.username.as_deref().and_then(normalize_bot_username)
                    {
                        if let Some(ref fallback) = configured {
                            if fallback != &username {
                                warn!(
                                    "[telegram] LIFEOS_TELEGRAM_BOT_USERNAME=@{} does not match Telegram getMe=@{}; using Telegram value.",
                                    fallback, username
                                );
                            }
                        }
                        return username;
                    }
                    warn!(
                        "[telegram] getMe succeeded but returned no username on attempt {}.",
                        attempt
                    );
                }
                Err(err) => {
                    warn!(
                        "[telegram] getMe failed on attempt {}/{}: {}",
                        attempt, BOT_USERNAME_LOOKUP_ATTEMPTS, err
                    );
                }
            }

            if attempt < BOT_USERNAME_LOOKUP_ATTEMPTS {
                tokio::time::sleep(std::time::Duration::from_millis(250 * attempt as u64)).await;
            }
        }

        if let Some(username) = configured {
            warn!(
                "[telegram] Falling back to LIFEOS_TELEGRAM_BOT_USERNAME=@{} after getMe startup failures.",
                username
            );
            return username;
        }

        String::new()
    }

    fn configured_bot_username() -> Option<String> {
        std::env::var("LIFEOS_TELEGRAM_BOT_USERNAME")
            .ok()
            .and_then(|value| normalize_bot_username(&value))
    }

    fn normalize_bot_username(value: &str) -> Option<String> {
        let trimmed = value.trim().trim_start_matches('@');
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    }

    fn build_trust_task_prompt(task_text: &str) -> String {
        format!(
            "[Modo trust para esta tarea]\nEl usuario ya autorizo que ejecutes herramientas sin pedir una confirmacion adicional en Telegram para esta solicitud. Mantente dentro de los limites de seguridad y evita acciones destructivas no solicitadas.\n\n{}",
            task_text.trim()
        )
    }

    fn strip_axi_invocation_prefix(text: &str) -> &str {
        let trimmed = text.trim();
        if !looks_like_axi_invocation(trimmed) {
            return trimmed;
        }
        for prefix in ["Axi", "axi", "AXI", "Axí", "axí"] {
            if let Some(rest) = trimmed.strip_prefix(prefix) {
                let rest = rest.trim_start_matches(|c: char| c.is_whitespace());
                let rest = rest.trim_start_matches(|c| {
                    matches!(c, ',' | ':' | ';' | '!' | '?' | '.' | '-' | ' ')
                });
                if !rest.is_empty() {
                    return rest.trim();
                }
            }
        }
        trimmed
    }

    fn looks_like_axi_invocation(text: &str) -> bool {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return false;
        }
        for prefix in ["axi", "axí"] {
            if trimmed.eq_ignore_ascii_case(prefix) {
                return true;
            }

            let lower = trimmed.to_lowercase();
            if let Some(stripped) = lower.strip_prefix(prefix) {
                let suffix = stripped.chars().next();
                let boundary_ok = match suffix {
                    None => true,
                    Some(c) => c.is_whitespace() || ",:;!?.-".contains(c),
                };
                if boundary_ok {
                    return true;
                }
            }
        }
        false
    }

    fn is_addressed_to_bot(msg: &Message, bot_username: &str) -> bool {
        // Reply-to-bot: if user is replying to one of Axi's own messages, treat as addressed
        if let Some(reply) = msg.reply_to_message() {
            if reply.from.as_ref().map(|u| u.is_bot).unwrap_or(false) {
                return true;
            }
        }
        if let Some(text) = msg.text() {
            if text.starts_with('/') {
                return true;
            }
            if !bot_username.is_empty() && text.contains(&format!("@{}", bot_username)) {
                return true;
            }
            if looks_like_axi_invocation(text) {
                return true;
            }
        }
        if let Some(caption) = msg.caption() {
            if !bot_username.is_empty() && caption.contains(&format!("@{}", bot_username)) {
                return true;
            }
            if looks_like_axi_invocation(caption) {
                return true;
            }
        }
        false
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn axi_invocation_helpers_detect_prefix_without_false_positive_axioma() {
            assert!(looks_like_axi_invocation("Axi, abre Telegram"));
            assert!(looks_like_axi_invocation("axí responde"));
            assert!(!looks_like_axi_invocation("axioma interesante"));
            assert_eq!(
                strip_axi_invocation_prefix("Axi, abre Telegram"),
                "abre Telegram"
            );
            assert_eq!(
                strip_axi_invocation_prefix("axioma interesante"),
                "axioma interesante"
            );
        }

        #[test]
        fn normalize_bot_username_trims_at_prefix() {
            assert_eq!(
                normalize_bot_username("@LifeOSAxi"),
                Some("LifeOSAxi".into())
            );
            assert_eq!(normalize_bot_username("   "), None);
        }

        #[test]
        fn sanitize_incoming_text_removes_mentions_and_axi_prefix_in_groups() {
            assert_eq!(
                sanitize_incoming_text("@LifeOSAxi Axi, abre ajustes", "LifeOSAxi", true),
                "abre ajustes"
            );
            assert_eq!(
                sanitize_incoming_text("axioma interesante", "LifeOSAxi", true),
                "axioma interesante"
            );
        }

        #[test]
        fn apply_reply_context_wraps_media_and_text_prompts() {
            assert_eq!(
                apply_reply_context(
                    "Describe esta imagen",
                    Some("[Respondiendo a una imagen anterior]")
                ),
                "[Respondiendo a una imagen anterior]\n\nDescribe esta imagen"
            );
            assert_eq!(apply_reply_context(" hola ", None), "hola");
        }
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

    /// Build inline keyboard for actionable supervisor notifications.
    fn notification_action_keyboard(text: &str) -> Option<InlineKeyboardMarkup> {
        let lower = text.to_lowercase();

        // Firewall alerts
        if lower.contains("firewall") || lower.contains("nftables") {
            return Some(InlineKeyboardMarkup::new(vec![vec![
                InlineKeyboardButton::callback("Activar firewall", "action:service_start:nftables"),
                InlineKeyboardButton::callback("Ignorar", "action:dismiss"),
            ]]));
        }

        // CPU temperature
        if lower.contains("cpu") && (lower.contains("temperatura") || lower.contains("\u{00b0}c")) {
            return Some(InlineKeyboardMarkup::new(vec![vec![
                InlineKeyboardButton::callback("Ver procesos", "action:top_processes"),
                InlineKeyboardButton::callback("Ignorar", "action:dismiss"),
            ]]));
        }

        // Disk space warnings
        if lower.contains("disco") || lower.contains("disk") || lower.contains("espacio") {
            return Some(InlineKeyboardMarkup::new(vec![vec![
                InlineKeyboardButton::callback("Limpiar cache", "action:cleanup_cache"),
                InlineKeyboardButton::callback("Ver uso", "action:disk_usage"),
                InlineKeyboardButton::callback("Ignorar", "action:dismiss"),
            ]]));
        }

        // Session/break reminders
        if lower.contains("descanso")
            || lower.contains("horas activo")
            || lower.contains("hidratarte")
        {
            return Some(InlineKeyboardMarkup::new(vec![vec![
                InlineKeyboardButton::callback("Ya voy", "action:break_ack"),
                InlineKeyboardButton::callback("En 30 min", "action:snooze:30"),
                InlineKeyboardButton::callback("Ignorar", "action:dismiss"),
            ]]));
        }

        // Eye health 20-20-20
        if lower.contains("20-20-20") || lower.contains("ojos") || lower.contains("vista") {
            return Some(InlineKeyboardMarkup::new(vec![vec![
                InlineKeyboardButton::callback("Listo", "action:dismiss"),
                InlineKeyboardButton::callback("En 10 min", "action:snooze:10"),
            ]]));
        }

        // Calendar reminders
        if (lower.contains("evento") || lower.contains("cita") || lower.contains("reunion"))
            && lower.contains("minuto")
        {
            return Some(InlineKeyboardMarkup::new(vec![vec![
                InlineKeyboardButton::callback("Listo", "action:dismiss"),
                InlineKeyboardButton::callback("Posponer 15 min", "action:snooze:15"),
            ]]));
        }

        // Empty tomorrow
        if lower.contains("nada agendado")
            || (lower.contains("manana") && lower.contains("no tienes"))
        {
            return Some(InlineKeyboardMarkup::new(vec![vec![
                InlineKeyboardButton::callback("Agregar evento", "action:prompt_calendar"),
                InlineKeyboardButton::callback("OK", "action:dismiss"),
            ]]));
        }

        // Update available
        if lower.contains("actualizacion") || lower.contains("update") {
            return Some(InlineKeyboardMarkup::new(vec![vec![
                InlineKeyboardButton::callback("Actualizar", "action:update"),
                InlineKeyboardButton::callback("Despues", "action:dismiss"),
            ]]));
        }

        // Meeting ended
        if lower.contains("reunion finalizada")
            || (lower.contains("meeting") && lower.contains("finaliz"))
        {
            return Some(InlineKeyboardMarkup::new(vec![vec![
                InlineKeyboardButton::callback("Ver resumen", "action:meeting_summary"),
                InlineKeyboardButton::callback("OK", "action:dismiss"),
            ]]));
        }

        // Memory/RAM warnings
        if lower.contains("memoria") && (lower.contains("critica") || lower.contains("alta")) {
            return Some(InlineKeyboardMarkup::new(vec![vec![
                InlineKeyboardButton::callback("Liberar RAM", "action:free_ram"),
                InlineKeyboardButton::callback("Ver procesos", "action:top_processes"),
                InlineKeyboardButton::callback("Ignorar", "action:dismiss"),
            ]]));
        }

        // Task failures
        if lower.contains("fallid") || lower.contains("error") || lower.contains("stuck") {
            return Some(InlineKeyboardMarkup::new(vec![vec![
                InlineKeyboardButton::callback("Reintentar", "action:retry_task"),
                InlineKeyboardButton::callback("Descartar", "action:dismiss"),
            ]]));
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
