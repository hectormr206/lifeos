//! Telegram bridge — Bidirectional communication with LifeOS via Telegram bot.
//!
//! Receives text/voice messages, routes them through the task queue or LLM router,
//! and sends back results. Listens for supervisor notifications to push results.

#[cfg(feature = "telegram")]
mod inner {
    use log::{error, info, warn};
    use std::sync::Arc;
    use teloxide::prelude::*;
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
    }

    /// Start the Telegram bot + notification listener. Blocks until stopped.
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

        // Spawn notification listener — pushes supervisor results to Telegram
        tokio::spawn(async move {
            loop {
                match notify_rx.recv().await {
                    Ok(notification) => {
                        let text = format_notification(&notification);
                        for &chat_id in &notify_chat_ids {
                            if let Err(e) = notify_bot.send_message(ChatId(chat_id), &text).await {
                                error!("Failed to send Telegram notification: {}", e);
                            }
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        warn!("Telegram notification listener lagged by {} messages", n);
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        info!("Supervisor notification channel closed");
                        break;
                    }
                }
            }
        });

        let ctx = BotCtx {
            task_queue,
            router,
            allowed_ids: config.allowed_chat_ids,
        };

        let handler =
            Update::filter_message().endpoint(|bot: Bot, msg: Message, ctx: BotCtx| async move {
                handle_message(bot, msg, ctx).await
            });

        Dispatcher::builder(bot, handler)
            .dependencies(dptree::deps![ctx])
            .enable_ctrlc_handler()
            .build()
            .dispatch()
            .await;
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
                let retry_msg = if *will_retry {
                    "Reintentando..."
                } else {
                    "Sin mas reintentos."
                };
                format!(
                    "Tarea fallida\n{}\n\nError: {}\n{}",
                    truncate(objective, 80),
                    truncate(error, 500),
                    retry_msg,
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
        // Find a valid char boundary at or before max
        let mut end = max;
        while end > 0 && !s.is_char_boundary(end) {
            end -= 1;
        }
        &s[..end]
    }

    async fn handle_message(
        bot: Bot,
        msg: Message,
        ctx: BotCtx,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let chat_id = msg.chat.id;

        if !ctx.allowed_ids.is_empty() && !ctx.allowed_ids.contains(&chat_id.0) {
            bot.send_message(chat_id, "No autorizado.").await?;
            warn!(
                "Rejected Telegram message from unauthorized chat_id: {}",
                chat_id
            );
            return Ok(());
        }

        let text = match msg.text() {
            Some(t) => t.to_string(),
            None => {
                bot.send_message(chat_id, "Por ahora solo acepto mensajes de texto.")
                    .await?;
                return Ok(());
            }
        };

        info!("Telegram [{}]: {}", chat_id, text);

        // /task or /do — create task for supervisor
        if text.starts_with("/task ") || text.starts_with("/do ") {
            let objective = text
                .strip_prefix("/task ")
                .or_else(|| text.strip_prefix("/do "))
                .unwrap_or(&text)
                .to_string();

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
            return Ok(());
        }

        // /status
        if text.starts_with("/status") {
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
                        serde_json::to_value(&t.status)
                            .unwrap_or_default()
                            .as_str()
                            .unwrap_or("?"),
                        &t.objective[..t.objective.len().min(60)],
                    ));
                }
            }
            bot.send_message(chat_id, reply).await?;
            return Ok(());
        }

        // /help or /start
        if text.starts_with("/help") || text.starts_with("/start") {
            bot.send_message(
                chat_id,
                "Soy Axi, tu asistente de LifeOS.\n\n\
                 Comandos:\n\
                 /do <tarea> — Crear tarea para el supervisor\n\
                 /task <tarea> — Igual que /do\n\
                 /status — Ver estado de tareas\n\
                 /help — Este mensaje\n\n\
                 O simplemente escribeme y te respondo.\n\
                 Cuando una tarea termine, te aviso automaticamente.",
            )
            .await?;
            return Ok(());
        }

        // Default: chat via LLM router
        bot.send_chat_action(chat_id, teloxide::types::ChatAction::Typing)
            .await
            .ok();

        let request = RouterRequest {
            messages: vec![
                ChatMessage {
                    role: "system".into(),
                    content: serde_json::Value::String(
                        "Eres Axi, el asistente AI de LifeOS. Responde de forma concisa y util en español.".into(),
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

        let router_guard = ctx.router.read().await;
        match router_guard.chat(&request).await {
            Ok(response) => {
                let reply = format!("{}\n\n[{}]", response.text, response.provider);
                for chunk in reply.as_bytes().chunks(4000) {
                    let chunk_str = String::from_utf8_lossy(chunk);
                    bot.send_message(chat_id, chunk_str.to_string()).await?;
                }
            }
            Err(e) => {
                bot.send_message(chat_id, format!("Error: {}", e)).await?;
            }
        }

        Ok(())
    }
}

#[cfg(feature = "telegram")]
pub use inner::*;

// When telegram feature is disabled, this module is intentionally empty.
