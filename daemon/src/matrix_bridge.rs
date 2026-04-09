//! Matrix bridge — Chat with Axi via a local Conduit homeserver.
//!
//! Connects to a self-hosted Conduit instance (Matrix homeserver) running on
//! localhost:6167 and dispatches messages through the same agentic tool system
//! used by the Telegram bridge.  Uses raw HTTP calls to the Matrix Client-Server
//! API via reqwest — no heavy SDK dependency.
//!
//! Activation: The bridge starts only when `/etc/lifeos/matrix-axi-credentials`
//! exists (created by `lifeos-matrix-setup.sh` during Conduit first boot).

#[cfg(feature = "telegram")]
mod inner {
    use log::{error, info, warn};
    use serde::{Deserialize, Serialize};
    use std::path::Path;
    use std::sync::Arc;
    use tokio::sync::RwLock;

    use crate::llm_router::LlmRouter;
    use crate::memory_plane::MemoryPlaneManager;
    use crate::task_queue::TaskQueue;
    use crate::telegram_tools::{
        self, ConversationHistory, CronStore, RateLimiter, SddStore, ToolContext,
    };

    /// Credentials file written by `lifeos-matrix-setup.sh`.
    const CREDENTIALS_PATH: &str = "/etc/lifeos/matrix-axi-credentials";
    /// Conduit default port.
    const CONDUIT_PORT: u16 = 6167;
    /// Long-poll timeout for /sync (seconds).
    const SYNC_TIMEOUT_MS: u64 = 30_000;
    /// Pause between sync errors to avoid tight loops.
    const ERROR_BACKOFF_SECS: u64 = 10;
    /// Fixed "chat_id" for the Matrix channel (conversation history key).
    const MATRIX_CHAT_ID: i64 = 0x4D41_5452_4958_0001; // "MATRIX01"

    // -----------------------------------------------------------------------
    // Config
    // -----------------------------------------------------------------------

    #[derive(Debug, Clone)]
    pub struct MatrixConfig {
        pub homeserver_url: String,
        pub user_id: String,
        pub password: String,
    }

    impl MatrixConfig {
        /// Read credentials from the file written by the setup script.
        /// Format (one value per line):
        ///   server_name
        ///   password
        pub fn from_credentials_file() -> Option<Self> {
            let path = Path::new(CREDENTIALS_PATH);
            if !path.exists() {
                return None;
            }
            let content = std::fs::read_to_string(path).ok()?;
            let mut lines = content.lines();
            let server_name = lines.next()?.trim().to_string();
            let password = lines.next()?.trim().to_string();
            if server_name.is_empty() || password.is_empty() {
                return None;
            }
            Some(Self {
                homeserver_url: format!("http://127.0.0.1:{}", CONDUIT_PORT),
                user_id: format!("@axi:{}", server_name),
                password,
            })
        }
    }

    // -----------------------------------------------------------------------
    // Matrix CS API types (minimal)
    // -----------------------------------------------------------------------

    #[derive(Debug, Serialize)]
    struct LoginRequest {
        r#type: String,
        user: String,
        password: String,
    }

    #[derive(Debug, Deserialize)]
    struct LoginResponse {
        access_token: Option<String>,
        user_id: Option<String>,
    }

    #[derive(Debug, Deserialize)]
    struct SyncResponse {
        next_batch: Option<String>,
        rooms: Option<RoomsResponse>,
    }

    #[derive(Debug, Deserialize)]
    struct RoomsResponse {
        join: Option<std::collections::HashMap<String, JoinedRoom>>,
        invite: Option<std::collections::HashMap<String, serde_json::Value>>,
    }

    #[derive(Debug, Deserialize)]
    struct JoinedRoom {
        timeline: Option<Timeline>,
    }

    #[derive(Debug, Deserialize)]
    struct Timeline {
        events: Option<Vec<TimelineEvent>>,
    }

    #[derive(Debug, Deserialize)]
    struct TimelineEvent {
        r#type: Option<String>,
        sender: Option<String>,
        content: Option<EventContent>,
        event_id: Option<String>,
    }

    #[derive(Debug, Deserialize)]
    struct EventContent {
        msgtype: Option<String>,
        body: Option<String>,
    }

    #[derive(Debug, Serialize)]
    struct MessageContent {
        msgtype: String,
        body: String,
    }

    // -----------------------------------------------------------------------
    // HTTP helpers
    // -----------------------------------------------------------------------

    struct MatrixClient {
        http: reqwest::Client,
        homeserver: String,
        access_token: String,
        own_user_id: String,
    }

    impl MatrixClient {
        async fn login(homeserver: &str, user_id: &str, password: &str) -> anyhow::Result<Self> {
            let http = reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(45))
                .build()?;

            // Extract localpart from @axi:server_name
            let localpart = user_id
                .strip_prefix('@')
                .and_then(|s| s.split(':').next())
                .unwrap_or(user_id);

            let login_req = LoginRequest {
                r#type: "m.login.password".into(),
                user: localpart.to_string(),
                password: password.to_string(),
            };

            let resp = http
                .post(format!("{}/_matrix/client/v3/login", homeserver))
                .json(&login_req)
                .send()
                .await?;

            if !resp.status().is_success() {
                let status = resp.status();
                let body = resp.text().await.unwrap_or_default();
                anyhow::bail!("Matrix login failed ({}): {}", status, body);
            }

            let login_resp: LoginResponse = resp.json().await?;
            let access_token = login_resp
                .access_token
                .ok_or_else(|| anyhow::anyhow!("No access_token in login response"))?;
            let own_user_id = login_resp.user_id.unwrap_or_else(|| user_id.to_string());

            Ok(Self {
                http,
                homeserver: homeserver.to_string(),
                access_token,
                own_user_id,
            })
        }

        async fn sync(&self, since: Option<&str>) -> anyhow::Result<SyncResponse> {
            let mut url = format!(
                "{}/_matrix/client/v3/sync?timeout={}",
                self.homeserver, SYNC_TIMEOUT_MS
            );
            if let Some(token) = since {
                url.push_str(&format!("&since={}", urlencoded(token)));
            }
            // On first sync, use a filter to skip old messages
            if since.is_none() {
                // Only fetch the last 0 messages on initial sync (we don't want
                // to replay history).  We'll only see messages from the next batch.
                url.push_str("&filter={\"room\":{\"timeline\":{\"limit\":0}}}");
            }

            let resp = self
                .http
                .get(&url)
                .header("Authorization", format!("Bearer {}", self.access_token))
                .send()
                .await?;

            if !resp.status().is_success() {
                let status = resp.status();
                let body = resp.text().await.unwrap_or_default();
                anyhow::bail!("Matrix sync failed ({}): {}", status, body);
            }

            Ok(resp.json().await?)
        }

        async fn send_text_message(&self, room_id: &str, text: &str) -> anyhow::Result<()> {
            let txn_id = uuid::Uuid::new_v4().to_string();
            let url = format!(
                "{}/_matrix/client/v3/rooms/{}/send/m.room.message/{}",
                self.homeserver,
                urlencoded(room_id),
                txn_id
            );
            let msg = MessageContent {
                msgtype: "m.text".into(),
                body: text.to_string(),
            };

            let resp = self
                .http
                .put(&url)
                .header("Authorization", format!("Bearer {}", self.access_token))
                .json(&msg)
                .send()
                .await?;

            if !resp.status().is_success() {
                let status = resp.status();
                let body = resp.text().await.unwrap_or_default();
                warn!(
                    "[matrix_bridge] Failed to send message to {} ({}): {}",
                    room_id, status, body
                );
            }
            Ok(())
        }

        /// Auto-join any room we're invited to.
        async fn join_room(&self, room_id: &str) -> anyhow::Result<()> {
            let url = format!(
                "{}/_matrix/client/v3/join/{}",
                self.homeserver,
                urlencoded(room_id)
            );
            let resp = self
                .http
                .post(&url)
                .header("Authorization", format!("Bearer {}", self.access_token))
                .json(&serde_json::json!({}))
                .send()
                .await?;

            if resp.status().is_success() {
                info!("[matrix_bridge] Joined room {}", room_id);
            } else {
                let body = resp.text().await.unwrap_or_default();
                warn!("[matrix_bridge] Failed to join {}: {}", room_id, body);
            }
            Ok(())
        }
    }

    /// Percent-encode a room_id for use in URL paths.
    fn urlencoded(s: &str) -> String {
        percent_encoding::utf8_percent_encode(s, percent_encoding::NON_ALPHANUMERIC).to_string()
    }

    // -----------------------------------------------------------------------
    // Main loop
    // -----------------------------------------------------------------------

    pub async fn run_matrix_bridge(
        config: MatrixConfig,
        task_queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
        memory: Option<Arc<RwLock<MemoryPlaneManager>>>,
    ) {
        info!(
            "Starting Matrix bridge (homeserver={}, user={})",
            config.homeserver_url, config.user_id
        );

        // Login to the homeserver
        let client =
            match MatrixClient::login(&config.homeserver_url, &config.user_id, &config.password)
                .await
            {
                Ok(c) => {
                    info!("[matrix_bridge] Logged in as {}", c.own_user_id);
                    c
                }
                Err(e) => {
                    error!(
                        "[matrix_bridge] Login failed: {}. Bridge will not start.",
                        e
                    );
                    return;
                }
            };

        // Build tool context (same pattern as email_bridge)
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

        let mut since: Option<String> = None;

        loop {
            match client.sync(since.as_deref()).await {
                Ok(sync_resp) => {
                    // Update the sync token
                    if let Some(ref nb) = sync_resp.next_batch {
                        since = Some(nb.clone());
                    }

                    // Handle invites — auto-join
                    if let Some(ref rooms) = sync_resp.rooms {
                        if let Some(ref invites) = rooms.invite {
                            for room_id in invites.keys() {
                                if let Err(e) = client.join_room(room_id).await {
                                    warn!("[matrix_bridge] Error joining room {}: {}", room_id, e);
                                }
                            }
                        }

                        // Handle messages in joined rooms
                        if let Some(ref joined) = rooms.join {
                            for (room_id, room) in joined {
                                let events = room.timeline.as_ref().and_then(|t| t.events.as_ref());

                                if let Some(events) = events {
                                    for event in events {
                                        // Only process m.room.message events
                                        if event.r#type.as_deref() != Some("m.room.message") {
                                            continue;
                                        }
                                        // Skip our own messages
                                        if event.sender.as_deref() == Some(&client.own_user_id) {
                                            continue;
                                        }
                                        // Extract message body
                                        let body = event
                                            .content
                                            .as_ref()
                                            .and_then(|c| c.body.as_deref())
                                            .unwrap_or("");
                                        if body.is_empty() {
                                            continue;
                                        }

                                        let sender = event.sender.as_deref().unwrap_or("unknown");
                                        info!(
                                            "[matrix_bridge] Message from {} in {}: {}",
                                            sender,
                                            room_id,
                                            &body.chars().take(80).collect::<String>()
                                        );

                                        // Dispatch through the agentic chat system
                                        let (reply, _audio) = telegram_tools::agentic_chat(
                                            &tool_ctx,
                                            MATRIX_CHAT_ID,
                                            body,
                                            None, // no image support in MVP
                                        )
                                        .await;

                                        // Send the response back
                                        if let Err(e) =
                                            client.send_text_message(room_id, &reply).await
                                        {
                                            error!(
                                                "[matrix_bridge] Failed to send reply to {}: {}",
                                                room_id, e
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Err(e) => {
                    warn!(
                        "[matrix_bridge] Sync error: {}. Retrying in {}s...",
                        e, ERROR_BACKOFF_SECS
                    );
                    tokio::time::sleep(std::time::Duration::from_secs(ERROR_BACKOFF_SECS)).await;
                }
            }
        }
    }
}

// Re-export based on feature flag (same pattern as telegram_bridge.rs)
#[cfg(feature = "telegram")]
pub use inner::*;

// Stub when telegram feature is disabled
#[cfg(not(feature = "telegram"))]
pub mod stubs {
    #[derive(Debug, Clone)]
    pub struct MatrixConfig;

    impl MatrixConfig {
        pub fn from_credentials_file() -> Option<Self> {
            None
        }
    }

    pub async fn run_matrix_bridge(
        _config: MatrixConfig,
        _task_queue: std::sync::Arc<crate::task_queue::TaskQueue>,
        _router: std::sync::Arc<tokio::sync::RwLock<crate::llm_router::LlmRouter>>,
        _memory: Option<
            std::sync::Arc<tokio::sync::RwLock<crate::memory_plane::MemoryPlaneManager>>,
        >,
    ) {
    }
}

#[cfg(not(feature = "telegram"))]
pub use stubs::*;
