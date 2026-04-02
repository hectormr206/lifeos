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

    use crate::knowledge_graph::KnowledgeGraph;
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
        knowledge_graph: Option<Arc<RwLock<KnowledgeGraph>>>,
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
            BotCommand::new("pair", "Generar codigo para vincular nuevo usuario"),
        ])
        .await
        .ok();

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
            knowledge_graph: knowledge_graph.clone(),
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
            knowledge_graph,
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
                    let _ = mem
                        .add_entry(
                            "El usuario reacciono positivamente a mi respuesta",
                            "feedback",
                            &["reaction", "positive"],
                            50,
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
                    let _ = mem
                        .add_entry(
                            "El usuario reacciono negativamente — ajustar enfoque",
                            "feedback",
                            &["reaction", "negative"],
                            60,
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

        // Extract reply context: when user replies to a specific Axi message,
        // prepend the original message so Axi knows what the user is referring to.
        let text = if let Some(reply) = msg.reply_to_message() {
            if let Some(reply_text) = reply.text() {
                let reply_preview = if reply_text.len() > 300 {
                    format!("{}...", &reply_text[..300])
                } else {
                    reply_text.to_string()
                };
                format!(
                    "[Respondiendo a tu mensaje: \"{}\"]\n\n{}",
                    reply_preview, text
                )
            } else {
                text
            }
        } else {
            text
        };

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
            let worker_text = task_text.to_string();
            let cancel_flag = ctx.worker_pool.get_cancel_flag(&task_id).await;

            tokio::spawn(async move {
                worker_bot
                    .send_message(chat_id, "Ejecutando en modo trust...")
                    .await
                    .ok();

                // Set auto-approve env for this session
                std::env::set_var("LIFEOS_AUTO_APPROVE_MEDIUM", "true");

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

        // Thread/topic support: use composite key when message is in a forum topic
        let history_key = msg
            .thread_id
            .map(|tid| chat_id.0 ^ (tid.0 .0 as i64))
            .unwrap_or(chat_id.0);

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

        // Voice messages are always delegated to an async worker
        if !ctx.worker_pool.can_spawn(chat_id.0).await {
            bot.send_message(
                chat_id,
                "Tengo 3 tareas en proceso. Espera a que termine una.",
            )
            .await?;
            return Ok(());
        }

        let task_id = uuid::Uuid::new_v4().to_string();
        let desc = format!("voz: {}", &transcription[..transcription.len().min(60)]);
        ctx.worker_pool
            .register(task_id.clone(), chat_id.0, desc)
            .await;

        bot.send_message(
            chat_id,
            format!(
                "(tu dijiste: {})\n\nProcesando...",
                &transcription[..transcription.len().min(200)]
            ),
        )
        .await?;

        let worker_ctx = ctx.tool_ctx.clone();
        let worker_bot = bot.clone();
        let worker_pool = ctx.worker_pool.clone();

        tokio::spawn(async move {
            let (response, screenshot_path) =
                telegram_tools::agentic_chat(&worker_ctx, chat_id.0, &transcription, None).await;

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

        // Photos always go to async worker (vision analysis takes time)
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
        let worker_caption = caption.to_string();

        tokio::spawn(async move {
            let (response, screenshot_path) = telegram_tools::agentic_chat(
                &worker_ctx,
                chat_id.0,
                &worker_caption,
                Some(&data_url),
            )
            .await;

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

            // Videos always go to async worker (vision analysis takes time)
            if !ctx.worker_pool.can_spawn(chat_id.0).await {
                bot.send_message(
                    chat_id,
                    "Tengo 3 tareas en proceso. Espera a que termine una.",
                )
                .await?;
                let _ = tokio::fs::remove_file(&video_path).await;
                let _ = tokio::fs::remove_file(&frame_path).await;
                return Ok(());
            }

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
            let worker_caption = caption.to_string();

            tokio::spawn(async move {
                let (response, screenshot_path) = telegram_tools::agentic_chat(
                    &worker_ctx,
                    chat_id.0,
                    &worker_caption,
                    Some(&data_url),
                )
                .await;

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

                // Cleanup video/frame files
                let _ = tokio::fs::remove_file(&video_path).await;
                let _ = tokio::fs::remove_file(&frame_path).await;

                worker_pool.complete(&task_id).await;
            });
        } else {
            bot.send_message(chat_id, "No pude extraer un frame del video.")
                .await?;
            let _ = tokio::fs::remove_file(&video_path).await;
            let _ = tokio::fs::remove_file(&frame_path).await;
        }

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
            match action {
                "cleanup_cache" => {
                    info!("Telegram: cleanup_cache action triggered");
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
                    bot.send_message(chat_id, "Notificacion descartada.")
                        .await?;
                }
                _ => {
                    warn!("Unknown action callback: {}", action);
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
             /btw <texto> — Conversacion lateral\n\
             /do <tarea> — Ejecutar tarea\n\
             /pair — Generar codigo para vincular nuevo usuario\n\
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

    /// Build inline keyboard for actionable supervisor notifications.
    fn notification_action_keyboard(text: &str) -> Option<InlineKeyboardMarkup> {
        let lower = text.to_lowercase();

        // Disk space warnings
        if lower.contains("disco") || lower.contains("disk") || lower.contains("espacio") {
            return Some(InlineKeyboardMarkup::new(vec![vec![
                InlineKeyboardButton::callback("Limpiar cache", "action:cleanup_cache"),
                InlineKeyboardButton::callback("Ignorar", "action:dismiss"),
            ]]));
        }

        // Task failures — offer to dismiss
        if lower.contains("fallid") || lower.contains("error") {
            return Some(InlineKeyboardMarkup::new(vec![vec![
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
