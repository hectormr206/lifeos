//! SimpleX Chat bridge — Chat with Axi via the most private messenger.
//!
//! Connects to a local SimpleX CLI running in headless/WebSocket mode on
//! port 5226 and dispatches messages through the same agentic tool system
//! used by the Telegram and Matrix bridges.
//!
//! SimpleX has NO user identifiers — privacy by design. The CLI exposes a
//! JSON-over-WebSocket API that we use to receive messages and send replies.
//!
//! Activation: The bridge starts only when the SimpleX CLI WebSocket is
//! reachable on `ws://127.0.0.1:5226`.

#[cfg(feature = "telegram")]
mod inner {
    use futures_util::{SinkExt, StreamExt};
    use log::{error, info, warn};
    use serde::{Deserialize, Serialize};
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::sync::RwLock;
    use tokio_tungstenite::connect_async;

    use crate::llm_router::LlmRouter;
    use crate::memory_plane::MemoryPlaneManager;
    use crate::task_queue::TaskQueue;
    use crate::telegram_tools::{
        self, ConversationHistory, CronStore, RateLimiter, SddStore, ToolContext,
    };

    /// WebSocket endpoint for the SimpleX CLI headless API.
    const SIMPLEX_WS_URL: &str = "ws://127.0.0.1:5226";
    /// Reconnect delay after connection failure.
    const RECONNECT_DELAY_SECS: u64 = 15;
    /// Fixed "chat_id" for the SimpleX channel (conversation history key).
    const SIMPLEX_CHAT_ID: i64 = 0x534D_504C_5800_0001; // "SMPLX001"
    /// Path where the invite link is persisted for the dashboard.
    const INVITE_LINK_PATH: &str = "/etc/lifeos/simplex-invite-link";

    // -----------------------------------------------------------------------
    // SimpleX CLI WebSocket protocol types (minimal subset)
    // -----------------------------------------------------------------------

    /// Outgoing command to the SimpleX CLI.
    #[derive(Debug, Serialize)]
    struct SimplexCommand {
        #[serde(rename = "corrId")]
        corr_id: String,
        cmd: String,
    }

    /// Incoming event from the SimpleX CLI.
    #[derive(Debug, Deserialize)]
    struct SimplexEvent {
        #[serde(rename = "resp")]
        resp: Option<SimplexResponse>,
    }

    #[derive(Debug, Deserialize)]
    #[serde(tag = "type")]
    enum SimplexResponse {
        /// A new message was received from a contact.
        #[serde(rename = "newChatItems")]
        NewChatItems {
            #[serde(rename = "chatItems")]
            chat_items: Vec<ChatItem>,
        },
        /// Invitation link created.
        #[serde(rename = "invitation")]
        Invitation {
            #[serde(rename = "connReqInvitation")]
            conn_req_invitation: Option<String>,
        },
        /// Contact connected.
        #[serde(rename = "contactConnected")]
        ContactConnected { contact: Option<ContactInfo> },
        /// Catch-all for events we don't handle yet.
        #[serde(other)]
        Other,
    }

    #[derive(Debug, Deserialize)]
    struct ChatItem {
        #[serde(rename = "chatItem")]
        chat_item: Option<ChatItemInner>,
    }

    #[derive(Debug, Deserialize)]
    struct ChatItemInner {
        content: Option<ChatContent>,
        #[serde(rename = "chatDir")]
        chat_dir: Option<ChatDirection>,
    }

    #[derive(Debug, Deserialize)]
    struct ChatContent {
        #[serde(rename = "msgContent")]
        msg_content: Option<MsgContent>,
    }

    #[derive(Debug, Deserialize)]
    struct MsgContent {
        text: Option<String>,
    }

    #[derive(Debug, Deserialize)]
    struct ChatDirection {
        #[serde(rename = "contactId")]
        contact_id: Option<i64>,
    }

    #[derive(Debug, Deserialize)]
    struct ContactInfo {
        #[serde(rename = "contactId")]
        contact_id: Option<i64>,
        #[serde(rename = "localDisplayName")]
        local_display_name: Option<String>,
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// Send a command to the SimpleX CLI via WebSocket.
    async fn send_command(
        ws: &mut futures_util::stream::SplitSink<
            tokio_tungstenite::WebSocketStream<
                tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
            >,
            tokio_tungstenite::tungstenite::Message,
        >,
        cmd: &str,
    ) -> anyhow::Result<String> {
        let corr_id = uuid::Uuid::new_v4().to_string();
        let command = SimplexCommand {
            corr_id: corr_id.clone(),
            cmd: cmd.to_string(),
        };
        let json = serde_json::to_string(&command)?;
        ws.send(tokio_tungstenite::tungstenite::Message::Text(json.into()))
            .await?;
        Ok(corr_id)
    }

    /// Maximum number of retries when requesting an invitation link.
    const INVITE_RETRY_COUNT: u32 = 3;
    /// Delay between invite link creation retries.
    const INVITE_RETRY_DELAY_SECS: u64 = 5;

    /// Try to read or create an invitation link with retries.
    async fn ensure_invite_link(
        ws: &mut futures_util::stream::SplitSink<
            tokio_tungstenite::WebSocketStream<
                tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
            >,
            tokio_tungstenite::tungstenite::Message,
        >,
    ) {
        // If we already have an invite link on disk, we're good.
        if std::path::Path::new(INVITE_LINK_PATH).exists() {
            info!(
                "[simplex_bridge] Invite link already exists at {}",
                INVITE_LINK_PATH
            );
            return;
        }

        // Ask SimpleX CLI to create an invitation, retrying on failure.
        for attempt in 1..=INVITE_RETRY_COUNT {
            match send_command(ws, "/c").await {
                Ok(_) => {
                    info!(
                        "[simplex_bridge] Requested invitation link creation (attempt {}/{})",
                        attempt, INVITE_RETRY_COUNT
                    );
                    return;
                }
                Err(e) => {
                    warn!(
                        "[simplex_bridge] Failed to request invite link (attempt {}/{}): {}",
                        attempt, INVITE_RETRY_COUNT, e
                    );
                    if attempt < INVITE_RETRY_COUNT {
                        tokio::time::sleep(Duration::from_secs(INVITE_RETRY_DELAY_SECS)).await;
                    }
                }
            }
        }
        warn!(
            "[simplex_bridge] Exhausted all {} attempts to create invite link",
            INVITE_RETRY_COUNT
        );
    }

    /// Save the invitation link to disk so the dashboard can read it.
    fn persist_invite_link(link: &str) {
        if let Some(parent) = std::path::Path::new(INVITE_LINK_PATH).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        match std::fs::write(INVITE_LINK_PATH, link) {
            Ok(()) => {
                info!("[simplex_bridge] Invite link saved to {}", INVITE_LINK_PATH);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ = std::fs::set_permissions(
                        INVITE_LINK_PATH,
                        std::fs::Permissions::from_mode(0o600),
                    );
                }
            }
            Err(e) => error!("[simplex_bridge] Failed to save invite link: {}", e),
        }
    }

    /// Send a text message to a SimpleX contact.
    async fn send_message(
        ws: &mut futures_util::stream::SplitSink<
            tokio_tungstenite::WebSocketStream<
                tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
            >,
            tokio_tungstenite::tungstenite::Message,
        >,
        contact_id: i64,
        text: &str,
    ) -> anyhow::Result<()> {
        let cmd = format!("@{} {}", contact_id, text);
        send_command(ws, &cmd).await?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Main loop
    // -----------------------------------------------------------------------

    pub async fn run_simplex_bridge(
        task_queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
        memory: Option<Arc<RwLock<MemoryPlaneManager>>>,
    ) {
        info!(
            "[simplex_bridge] Starting SimpleX bridge (ws={})",
            SIMPLEX_WS_URL
        );

        // Build tool context (same pattern as matrix_bridge)
        let tool_ctx = ToolContext {
            router,
            task_queue,
            memory,
            history: Arc::new(ConversationHistory::new()),
            cron_store: Arc::new(CronStore::new()),
            sdd_store: Arc::new(SddStore::new()),
            session_store: None,
            user_model: None,
            meeting_archive: None,
            meeting_assistant: None,
            calendar: None,
            rate_limiter: RateLimiter::new(),
        };

        loop {
            match connect_async(SIMPLEX_WS_URL).await {
                Ok((ws_stream, _)) => {
                    info!("[simplex_bridge] Connected to SimpleX CLI WebSocket");
                    let (mut sink, mut stream) = ws_stream.split();

                    // Ensure we have an invite link for the dashboard.
                    ensure_invite_link(&mut sink).await;

                    let mut ping_interval = tokio::time::interval(Duration::from_secs(30));
                    // Consume the first immediate tick so we don't ping right away.
                    ping_interval.tick().await;

                    loop {
                        let msg = tokio::select! {
                            msg_result = stream.next() => {
                                match msg_result {
                                    Some(Ok(m)) => m,
                                    Some(Err(e)) => {
                                        warn!("[simplex_bridge] WebSocket error: {}", e);
                                        break;
                                    }
                                    None => {
                                        info!("[simplex_bridge] WebSocket stream ended");
                                        break;
                                    }
                                }
                            }
                            _ = ping_interval.tick() => {
                                if let Err(e) = sink.send(
                                    tokio_tungstenite::tungstenite::Message::Ping(vec![].into())
                                ).await {
                                    warn!("[simplex_bridge] Ping failed, reconnecting: {}", e);
                                    break;
                                }
                                continue;
                            }
                        };

                        let text = match msg {
                            tokio_tungstenite::tungstenite::Message::Text(t) => t,
                            tokio_tungstenite::tungstenite::Message::Close(_) => {
                                info!("[simplex_bridge] WebSocket closed by server");
                                break;
                            }
                            _ => continue,
                        };

                        // Try to parse the event
                        let event: SimplexEvent = match serde_json::from_str(&text) {
                            Ok(e) => e,
                            Err(e) => {
                                log::debug!(
                                    "[simplex_bridge] Unparseable event: {} — {}",
                                    e,
                                    &text[..text.len().min(200)]
                                );
                                continue;
                            }
                        };

                        let resp = match event.resp {
                            Some(r) => r,
                            None => continue,
                        };

                        match resp {
                            SimplexResponse::Invitation {
                                conn_req_invitation: Some(link),
                            } => {
                                info!(
                                    "[simplex_bridge] Invitation link: {}",
                                    &link.chars().take(60).collect::<String>()
                                );
                                if link.is_empty() || link.len() > 2000 {
                                    warn!(
                                        "[simplex_bridge] Invalid invite link length ({}), skipping persist",
                                        link.len()
                                    );
                                } else if !link.starts_with("simplex://")
                                    && !link.starts_with("https://simplex.chat")
                                {
                                    warn!(
                                        "[simplex_bridge] Invite link has unexpected format, skipping persist"
                                    );
                                } else {
                                    persist_invite_link(&link);
                                }
                            }
                            SimplexResponse::ContactConnected { contact: Some(c) } => {
                                info!(
                                    "[simplex_bridge] Contact connected: {} (id={:?})",
                                    c.local_display_name.as_deref().unwrap_or("unknown"),
                                    c.contact_id
                                );
                            }
                            SimplexResponse::ContactConnected { contact: None } => {}
                            SimplexResponse::NewChatItems { chat_items } => {
                                for item in &chat_items {
                                    let inner = match &item.chat_item {
                                        Some(i) => i,
                                        None => continue,
                                    };

                                    // Extract message text
                                    let msg_text = inner
                                        .content
                                        .as_ref()
                                        .and_then(|c| c.msg_content.as_ref())
                                        .and_then(|m| m.text.as_deref())
                                        .unwrap_or("");

                                    if msg_text.is_empty() {
                                        continue;
                                    }

                                    // Get contact ID for replying
                                    let contact_id = inner
                                        .chat_dir
                                        .as_ref()
                                        .and_then(|d| d.contact_id)
                                        .unwrap_or(0);

                                    if contact_id == 0 {
                                        log::warn!(
                                            "[simplex_bridge] Message with no contact_id, skipping"
                                        );
                                        continue;
                                    }

                                    info!(
                                        "[simplex_bridge] Message from contact {}: {}",
                                        contact_id,
                                        &msg_text.chars().take(80).collect::<String>()
                                    );

                                    // Dispatch through the agentic chat system
                                    let (reply, _audio) = telegram_tools::agentic_chat(
                                        &tool_ctx,
                                        SIMPLEX_CHAT_ID,
                                        msg_text,
                                        None, // no image support in MVP
                                    )
                                    .await;

                                    // Send the response back
                                    match send_message(&mut sink, contact_id, &reply).await {
                                        Ok(()) => {
                                            info!(
                                                "[simplex_bridge] Reply sent to contact {} ({} chars)",
                                                contact_id,
                                                reply.len()
                                            );
                                        }
                                        Err(e) => {
                                            error!(
                                                "[simplex_bridge] Failed to send reply to contact {}: {}",
                                                contact_id, e
                                            );
                                        }
                                    }
                                }
                            }
                            SimplexResponse::Other => {} // Ignore unhandled events
                            _ => {}
                        }
                    }

                    warn!(
                        "[simplex_bridge] Disconnected. Reconnecting in {}s...",
                        RECONNECT_DELAY_SECS
                    );
                }
                Err(e) => {
                    warn!(
                        "[simplex_bridge] Connection failed: {}. Retrying in {}s...",
                        e, RECONNECT_DELAY_SECS
                    );
                }
            }

            tokio::time::sleep(Duration::from_secs(RECONNECT_DELAY_SECS)).await;
        }
    }

    /// Check if the SimpleX CLI WebSocket is reachable.
    pub async fn is_simplex_available() -> bool {
        matches!(
            tokio::time::timeout(Duration::from_secs(3), connect_async(SIMPLEX_WS_URL)).await,
            Ok(Ok(_))
        )
    }
}

#[cfg(feature = "telegram")]
pub use inner::*;

// Stub when telegram feature is disabled — all items are used
// conditionally in main.rs behind the same feature gate.
#[cfg(not(feature = "telegram"))]
mod stubs {
    pub(crate) async fn run_simplex_bridge(
        _task_queue: std::sync::Arc<crate::task_queue::TaskQueue>,
        _router: std::sync::Arc<tokio::sync::RwLock<crate::llm_router::LlmRouter>>,
        _memory: Option<
            std::sync::Arc<tokio::sync::RwLock<crate::memory_plane::MemoryPlaneManager>>,
        >,
    ) {
    }

    pub(crate) async fn is_simplex_available() -> bool {
        false
    }
}

#[cfg(not(feature = "telegram"))]
pub(crate) use stubs::*;
