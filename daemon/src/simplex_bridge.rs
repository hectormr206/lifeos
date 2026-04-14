//! SimpleX Chat bridge — Chat with Axi via the most private messenger.
//!
//! Connects to a local SimpleX CLI running in headless/WebSocket mode on
//! port 5226 and dispatches messages through the same agentic tool system
//! used by the Telegram and Matrix bridges.
//!
//! SimpleX has NO user identifiers — privacy by design. The CLI exposes a
//! JSON-over-WebSocket API that we use to receive messages and send replies.
//!
//! ## Multimedia support
//!
//! - **Receive text**: dispatched through agentic chat
//! - **Receive images**: inline base64 thumbnail passed to multimodal LLM;
//!   full-resolution file auto-accepted via XFTP
//! - **Receive voice notes**: auto-accepted, transcribed with Whisper, then
//!   dispatched as text through agentic chat
//! - **Receive video**: thumbnail extracted and processed as image
//! - **Send files**: camera photos, screenshots, TTS audio via `/f @name path`
//!
//! Activation: The bridge starts only when the SimpleX CLI WebSocket is
//! reachable on `ws://127.0.0.1:5226`.

#[cfg(feature = "messaging")]
mod inner {
    use futures_util::{SinkExt, StreamExt};
    use log::{error, info, warn};
    use serde::{Deserialize, Serialize};
    use std::collections::HashMap;
    use std::path::Path;
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::process::Command;
    use tokio::sync::{Mutex, RwLock};
    use tokio_tungstenite::connect_async;

    use crate::axi_tools::{
        self, ConversationHistory, CronStore, RateLimiter, SddStore, ToolContext,
    };
    use crate::llm_router::LlmRouter;
    use crate::memory_plane::MemoryPlaneManager;
    use crate::task_queue::TaskQueue;

    /// WebSocket endpoint for the SimpleX CLI headless API.
    const SIMPLEX_WS_URL: &str = "ws://127.0.0.1:5226";
    /// Reconnect delay after connection failure.
    const RECONNECT_DELAY_SECS: u64 = 15;
    /// Fixed "chat_id" for the SimpleX channel (conversation history key).
    const SIMPLEX_CHAT_ID: i64 = 0x534D_504C_5800_0001; // "SMPLX001"
    /// Path where the invite link is persisted for the dashboard.
    const INVITE_LINK_PATH: &str = "/var/lib/lifeos/simplex-invite-link";
    /// Directory for downloaded files from SimpleX contacts.
    const DOWNLOADS_DIR: &str = "/var/lib/lifeos/simplex-downloads";

    // -----------------------------------------------------------------------
    // SimpleX CLI WebSocket protocol types
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
            #[serde(rename = "connReqInvitation", default)]
            conn_req_invitation: Option<String>,
            #[serde(rename = "connLinkInvitation", default)]
            conn_link_invitation: Option<InvitationLink>,
        },
        /// Contact connected.
        #[serde(rename = "contactConnected")]
        ContactConnected { contact: Option<ContactInfo> },
        /// File download completed — the file is ready on disk.
        #[serde(rename = "rcvFileComplete")]
        RcvFileComplete {
            #[serde(rename = "chatItem")]
            chat_item: Option<RcvFileChatItem>,
        },
        /// Call invitation received — we can't answer in headless mode but
        /// we inform the user.
        #[serde(rename = "callInvitation")]
        CallInvitation { contact: Option<ContactInfo> },
        /// Catch-all for events we don't handle yet.
        #[serde(other)]
        Other,
    }

    /// Minimal chat item for file completion events.
    #[derive(Debug, Deserialize)]
    struct RcvFileChatItem {
        file: Option<FileTransferInfo>,
    }

    /// An `AChatItem` from the SimpleX CLI — wraps both the chat-level
    /// metadata (`chatInfo`) and the per-message payload (`chatItem`).
    #[derive(Debug, Deserialize)]
    struct ChatItem {
        #[serde(rename = "chatInfo")]
        chat_info: Option<ChatInfo>,
        #[serde(rename = "chatItem")]
        chat_item: Option<ChatItemInner>,
    }

    /// Chat-level metadata. For direct messages the `type` discriminator
    /// is `"direct"` and the contact lives here.
    #[derive(Debug, Deserialize)]
    #[serde(tag = "type")]
    enum ChatInfo {
        #[serde(rename = "direct")]
        Direct { contact: Option<ContactInfo> },
        #[serde(other)]
        Other,
    }

    #[derive(Debug, Deserialize)]
    struct ChatItemInner {
        content: Option<ChatContent>,
        /// Direction discriminator — `directRcv` for incoming messages,
        /// `directSnd` for messages we sent. We must ignore `directSnd`
        /// to avoid an infinite echo loop.
        #[serde(rename = "chatDir")]
        chat_dir: Option<ChatDir>,
        /// File transfer metadata — present for image, voice, video, and
        /// file messages.
        file: Option<FileTransferInfo>,
    }

    /// Message direction. Only `directRcv` should be processed.
    #[derive(Debug, Deserialize)]
    #[serde(tag = "type")]
    enum ChatDir {
        #[serde(rename = "directRcv")]
        DirectRcv,
        #[serde(rename = "directSnd")]
        DirectSnd,
        #[serde(other)]
        Other,
    }

    #[derive(Debug, Deserialize)]
    struct ChatContent {
        #[serde(rename = "msgContent")]
        msg_content: Option<MsgContent>,
    }

    /// Message content — discriminated by `type` field.
    ///
    /// SimpleX supports text, image, voice, video, file, and link content
    /// types. Each variant carries different fields.
    #[allow(dead_code)]
    #[derive(Debug, Deserialize)]
    #[serde(tag = "type")]
    enum MsgContent {
        #[serde(rename = "text")]
        Text { text: Option<String> },
        #[serde(rename = "image")]
        Image {
            text: Option<String>,
            /// Base64 data-URI of the thumbnail (e.g. "data:image/png;base64,...")
            image: Option<String>,
        },
        #[serde(rename = "voice")]
        Voice {
            text: Option<String>,
            duration: Option<u64>,
        },
        #[serde(rename = "video")]
        Video {
            text: Option<String>,
            /// Thumbnail as base64 data-URI
            image: Option<String>,
            duration: Option<u64>,
        },
        #[serde(rename = "file")]
        File { text: Option<String> },
        #[serde(rename = "link")]
        Link { text: Option<String> },
        #[serde(other)]
        Unknown,
    }

    #[allow(dead_code)]
    impl MsgContent {
        /// Extract the text/caption field from any content type.
        fn text(&self) -> Option<&str> {
            match self {
                MsgContent::Text { text }
                | MsgContent::Image { text, .. }
                | MsgContent::Voice { text, .. }
                | MsgContent::Video { text, .. }
                | MsgContent::File { text }
                | MsgContent::Link { text } => text.as_deref(),
                MsgContent::Unknown => None,
            }
        }
    }

    /// File transfer metadata attached to media messages.
    #[allow(dead_code)]
    #[derive(Debug, Clone, Deserialize)]
    struct FileTransferInfo {
        #[serde(rename = "fileId")]
        file_id: Option<u64>,
        #[serde(rename = "fileName")]
        file_name: Option<String>,
        #[serde(rename = "fileSize")]
        file_size: Option<u64>,
        /// Local path where the file was saved (present in rcvFileComplete).
        #[serde(rename = "filePath")]
        file_path: Option<String>,
    }

    #[derive(Debug, Deserialize)]
    struct ContactInfo {
        #[serde(rename = "contactId")]
        contact_id: Option<i64>,
        #[serde(rename = "localDisplayName")]
        local_display_name: Option<String>,
    }

    #[derive(Debug, Deserialize)]
    struct InvitationLink {
        #[serde(rename = "connFullLink", default)]
        conn_full_link: Option<String>,
        #[serde(rename = "connShortLink", default)]
        conn_short_link: Option<String>,
    }

    // -----------------------------------------------------------------------
    // Pending file downloads — track files we auto-accepted
    // -----------------------------------------------------------------------

    /// What to do when a file download completes.
    #[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
    #[serde(tag = "kind", rename_all = "snake_case")]
    enum PendingAction {
        /// Transcribe the audio file and dispatch as text chat.
        TranscribeVoice { display_name: String },
        /// Process the image through the multimodal LLM.
        ProcessImage {
            display_name: String,
            caption: String,
        },
    }

    /// Disk-backed store of in-flight file actions so voice/image jobs survive
    /// daemon restarts.
    fn pending_files_path() -> std::path::PathBuf {
        std::path::PathBuf::from("/var/lib/lifeos/simplex-pending-files.json")
    }

    fn load_pending_files() -> HashMap<u64, PendingAction> {
        std::fs::read_to_string(pending_files_path())
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    async fn persist_pending_files(map: &HashMap<u64, PendingAction>) {
        let path = pending_files_path();
        if let Some(parent) = path.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }
        if let Ok(json) = serde_json::to_string(map) {
            let _ = tokio::fs::write(&path, json).await;
        }
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    type WsSink = futures_util::stream::SplitSink<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
        tokio_tungstenite::tungstenite::Message,
    >;

    /// Send a command to the SimpleX CLI via WebSocket.
    async fn send_command(ws: &mut WsSink, cmd: &str) -> anyhow::Result<String> {
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
    async fn ensure_invite_link(ws: &mut WsSink) {
        if std::path::Path::new(INVITE_LINK_PATH).exists() {
            info!(
                "[simplex_bridge] Invite link already exists at {}",
                INVITE_LINK_PATH
            );
            return;
        }

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

    /// Ensure the downloads directory exists.
    fn ensure_downloads_dir() {
        let _ = std::fs::create_dir_all(DOWNLOADS_DIR);
    }

    /// Set the Axi profile (display name, description, avatar) on SimpleX.
    /// Runs on every connect to ensure the profile is always correct.
    async fn ensure_axi_profile(ws: &mut WsSink) {
        // Set display name + description
        if let Err(e) = send_command(ws, "/profile Axi LifeOS AI Assistant").await {
            warn!("[simplex_bridge] Failed to set profile name: {}", e);
        }

        // Set avatar from the LifeOS icon (if available)
        let avatar_paths = [
            "/usr/share/icons/LifeOS/512x512/apps/lifeos-axi.png",
            "/usr/share/icons/LifeOS/scalable/apps/lifeos-axi.svg",
        ];
        for path in &avatar_paths {
            if let Ok(data) = std::fs::read(path) {
                use base64::Engine;
                let b64 = base64::engine::general_purpose::STANDARD.encode(&data);
                let ext = if path.ends_with(".svg") {
                    "svg+xml"
                } else {
                    "png"
                };
                let uri = format!("data:image/{};base64,{}", ext, b64);
                let cmd = format!("/set profile image {}", uri);
                match send_command(ws, &cmd).await {
                    Ok(_) => {
                        info!("[simplex_bridge] Axi avatar set from {}", path);
                        return;
                    }
                    Err(e) => {
                        warn!("[simplex_bridge] Failed to set avatar from {}: {}", path, e);
                    }
                }
            }
        }
        info!("[simplex_bridge] No avatar file found, skipping profile image");
    }

    /// Send a text message to a SimpleX contact by display name.
    async fn send_message(ws: &mut WsSink, display_name: &str, text: &str) -> anyhow::Result<()> {
        let cmd = format!("@{} {}", display_name, text);
        send_command(ws, &cmd).await?;
        Ok(())
    }

    /// Send a file to a SimpleX contact by display name.
    async fn send_file(ws: &mut WsSink, display_name: &str, path: &str) -> anyhow::Result<()> {
        let cmd = format!("/f @{} {}", display_name, path);
        send_command(ws, &cmd).await?;
        info!("[simplex_bridge] Sent file to {}: {}", display_name, path);
        Ok(())
    }

    /// Accept an incoming file transfer by file ID.
    async fn accept_file(ws: &mut WsSink, file_id: u64) -> anyhow::Result<()> {
        let cmd = format!("/fr {} {}", file_id, DOWNLOADS_DIR);
        send_command(ws, &cmd).await?;
        info!(
            "[simplex_bridge] Accepted file {} → {}",
            file_id, DOWNLOADS_DIR
        );
        Ok(())
    }

    /// Decode a base64 data-URI and save to a temp file. Returns the file path.
    async fn save_data_uri_to_file(data_uri: &str) -> Option<String> {
        // Format: "data:image/jpeg;base64,/9j/4AAQ..."
        let b64_data = data_uri.split(',').nth(1)?;
        let bytes = base64_decode(b64_data)?;

        let ext = if data_uri.contains("image/png") {
            "png"
        } else if data_uri.contains("image/webp") {
            "webp"
        } else {
            "jpg"
        };

        let path = format!(
            "/var/lib/lifeos/simplex-downloads/inline-{}.{}",
            uuid::Uuid::new_v4(),
            ext
        );
        ensure_downloads_dir();
        tokio::fs::write(&path, &bytes).await.ok()?;
        Some(path)
    }

    /// Decode base64 bytes (standard or URL-safe).
    fn base64_decode(input: &str) -> Option<Vec<u8>> {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD
            .decode(input.trim())
            .ok()
            .or_else(|| {
                base64::engine::general_purpose::STANDARD_NO_PAD
                    .decode(input.trim())
                    .ok()
            })
    }

    /// Path where we persist the most recent contact display_name so that
    /// proactive messages (reminders) can find a delivery target after a
    /// daemon restart.
    fn last_contact_path() -> std::path::PathBuf {
        std::path::PathBuf::from("/var/lib/lifeos/simplex-last-contact")
    }

    /// Record the most recent SimpleX contact we've interacted with. Called
    /// from the message receive path. Persisted to disk for restart recovery.
    fn remember_contact(display_name: &str) {
        let path = last_contact_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(&path, display_name);
    }

    /// Return the most recently seen contact display_name, if any.
    fn last_known_contact() -> Option<String> {
        let path = last_contact_path();
        std::fs::read_to_string(&path)
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }

    /// Read a file and encode as base64 (for passing to multimodal LLM).
    async fn file_to_base64(path: &str) -> Option<String> {
        use base64::Engine;
        let bytes = tokio::fs::read(path).await.ok()?;
        Some(base64::engine::general_purpose::STANDARD.encode(&bytes))
    }

    /// Transcribe an audio file using Whisper CLI.
    async fn transcribe_audio(path: &str) -> Option<String> {
        // Try whisper-cli first, then whisper-cpp
        let whisper = if Path::new("/usr/local/bin/whisper-cli").exists() {
            "/usr/local/bin/whisper-cli"
        } else if Path::new("/usr/local/bin/whisper-cpp").exists() {
            "/usr/local/bin/whisper-cpp"
        } else {
            warn!("[simplex_bridge] No whisper binary found for transcription");
            return None;
        };

        let model = "/usr/share/lifeos/models/whisper/ggml-small.bin";
        if !Path::new(model).exists() {
            warn!("[simplex_bridge] Whisper model not found at {}", model);
            return None;
        }

        // Convert to WAV first (voice notes may be OGG/OPUS)
        let wav_path = format!("{}.wav", path);
        let ffmpeg = Command::new("ffmpeg")
            .args([
                "-y", "-i", path, "-ar", "16000", "-ac", "1", "-f", "wav", &wav_path,
            ])
            .output()
            .await;

        let input_path = if ffmpeg.map(|o| o.status.success()).unwrap_or(false) {
            &wav_path
        } else {
            path // try original file if conversion failed
        };

        let output = Command::new(whisper)
            .args(["-m", model, "-f", input_path, "-l", "es", "--no-timestamps"])
            .output()
            .await
            .ok()?;

        // Clean up temp WAV
        let _ = tokio::fs::remove_file(&wav_path).await;

        if !output.status.success() {
            warn!(
                "[simplex_bridge] Whisper transcription failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            return None;
        }

        let text = String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter(|l| !l.trim().is_empty())
            .collect::<Vec<_>>()
            .join(" ")
            .trim()
            .to_string();

        if text.is_empty() {
            None
        } else {
            Some(text)
        }
    }

    /// Capture a camera photo and return the path.
    async fn capture_camera_photo() -> Option<String> {
        let path = format!(
            "/var/lib/lifeos/camera/simplex-{}.jpg",
            uuid::Uuid::new_v4()
        );
        let output = Command::new("ffmpeg")
            .args([
                "-y",
                "-f",
                "v4l2",
                "-i",
                "/dev/video0",
                "-frames:v",
                "1",
                &path,
            ])
            .output()
            .await
            .ok()?;

        if output.status.success() && Path::new(&path).exists() {
            Some(path)
        } else {
            None
        }
    }

    /// Capture a screenshot and return the path.
    async fn capture_screenshot() -> Option<String> {
        // Use the existing screenshots directory
        let path = format!(
            "/var/lib/lifeos/screenshots/simplex_{}.jpg",
            chrono::Utc::now().format("%Y%m%d_%H%M%S")
        );

        // Try grim (Wayland) first, then gnome-screenshot
        let result = Command::new("grim").arg(&path).output().await;

        if result.map(|o| o.status.success()).unwrap_or(false) && Path::new(&path).exists() {
            return Some(path);
        }

        let result = Command::new("gnome-screenshot")
            .args(["-f", &path])
            .output()
            .await;

        if result.map(|o| o.status.success()).unwrap_or(false) && Path::new(&path).exists() {
            Some(path)
        } else {
            None
        }
    }

    /// Detect natural language requests for a camera photo.
    fn wants_camera(lower: &str) -> bool {
        let camera_patterns = [
            "toma una foto",
            "tomá una foto",
            "toma foto",
            "tomá foto",
            "sacá una foto",
            "saca una foto",
            "sacá foto",
            "saca foto",
            "foto de la cámara",
            "foto de la camara",
            "foto con la cámara",
            "foto con la camara",
            "mandame una foto",
            "mándame una foto",
            "envíame una foto",
            "enviame una foto",
            "mandame foto",
            "qué ves por la cámara",
            "que ves por la camara",
            "qué ve la cámara",
            "que ve la camara",
            "muéstrame la cámara",
            "muestrame la camara",
            "enseñame la cámara",
            "enséñame la cámara",
            "webcam",
            "foto webcam",
            "captura cámara",
            "captura camara",
            "take a photo",
            "take photo",
            "camera photo",
            "send me a photo",
            "show me the camera",
            "what does the camera see",
        ];
        camera_patterns.iter().any(|p| lower.contains(p))
    }

    /// Detect natural language requests for a screenshot.
    fn wants_screenshot(lower: &str) -> bool {
        let screen_patterns = [
            "captura de pantalla",
            "screenshot",
            "captura pantalla",
            "mandame la pantalla",
            "mándame la pantalla",
            "enviame la pantalla",
            "envíame la pantalla",
            "qué hay en mi pantalla",
            "que hay en mi pantalla",
            "qué hay en la pantalla",
            "que hay en la pantalla",
            "muéstrame la pantalla",
            "muestrame la pantalla",
            "enseñame la pantalla",
            "enséñame la pantalla",
            "qué se ve en la pantalla",
            "que se ve en la pantalla",
            "mandame un screenshot",
            "mándame un screenshot",
            "foto de la pantalla",
            "foto de pantalla",
            "show me the screen",
            "send me a screenshot",
            "what's on my screen",
            "show me my screen",
        ];
        screen_patterns.iter().any(|p| lower.contains(p))
    }

    /// Extract display name from a ChatItem.
    fn extract_display_name(item: &ChatItem) -> Option<String> {
        match &item.chat_info {
            Some(ChatInfo::Direct { contact: Some(c) }) => c
                .local_display_name
                .as_ref()
                .filter(|n| !n.is_empty())
                .cloned(),
            _ => None,
        }
    }

    // -----------------------------------------------------------------------
    // Main loop
    // -----------------------------------------------------------------------

    #[allow(clippy::too_many_arguments)]
    #[allow(clippy::too_many_arguments)]
    pub async fn run_simplex_bridge(
        task_queue: Arc<TaskQueue>,
        router: Arc<RwLock<LlmRouter>>,
        memory: Option<Arc<RwLock<MemoryPlaneManager>>>,
        session_store: Option<Arc<crate::session_store::SessionStore>>,
        user_model: Option<Arc<RwLock<crate::user_model::UserModel>>>,
        meeting_archive: Option<Arc<crate::meeting_archive::MeetingArchive>>,
        meeting_assistant: Option<Arc<RwLock<crate::meeting_assistant::MeetingAssistant>>>,
        calendar: Option<Arc<crate::calendar::CalendarManager>>,
        history: Arc<ConversationHistory>,
        cron_store: Arc<CronStore>,
        event_bus: Option<tokio::sync::broadcast::Sender<crate::events::DaemonEvent>>,
    ) {
        info!(
            "[simplex_bridge] Starting SimpleX bridge (ws={})",
            SIMPLEX_WS_URL
        );

        ensure_downloads_dir();

        let tool_ctx = ToolContext {
            router,
            task_queue,
            memory,
            history,
            cron_store,
            sdd_store: Arc::new(SddStore::new()),
            session_store,
            user_model,
            meeting_archive,
            meeting_assistant,
            calendar,
            rate_limiter: RateLimiter::new(),
        };

        // Track pending file downloads: file_id → action to take on completion.
        // Loaded from disk so voice/image jobs that were mid-flight when the
        // daemon restarted still complete when the RcvFileComplete event
        // arrives after reconnect.
        let pending_files: Arc<Mutex<HashMap<u64, PendingAction>>> =
            Arc::new(Mutex::new(load_pending_files()));

        // Outbound queue for proactive messages (reminders, etc.) that need to
        // be delivered to SimpleX contacts. Each item is (display_name, text).
        let (outbound_tx, mut outbound_rx) =
            tokio::sync::mpsc::unbounded_channel::<(String, String)>();

        // Subscribe to reminder events and fan them out to all known contacts.
        // We don't yet have per-contact chat_id mapping (SimpleX uses a single
        // magic id for history), so we deliver every reminder to every
        // connected contact we know about. A better per-contact routing would
        // track display_name → chat_id mapping; for now any SimpleX reminder
        // reaches the user.
        if let Some(ref bus) = event_bus {
            let mut rx = bus.subscribe();
            let outbound = outbound_tx.clone();
            tokio::spawn(async move {
                while let Ok(evt) = rx.recv().await {
                    if let crate::events::DaemonEvent::ReminderDue {
                        chat_id,
                        title,
                        start_time,
                        ..
                    } = evt
                    {
                        // Accept only our SimpleX magic chat_id (and also
                        // accept any unknown-high-magic id just in case).
                        if chat_id == SIMPLEX_CHAT_ID {
                            let msg = format!("🔔 Recordatorio ({}): {}", start_time, title);
                            // Target all contacts — simplex does not expose
                            // a deterministic display_name per chat_id yet,
                            // so we use the stored default contact.
                            let contact = last_known_contact();
                            if let Some(name) = contact {
                                let _ = outbound.send((name, msg));
                            } else {
                                log::warn!(
                                    "[simplex_bridge] Reminder fired but no contact known to deliver to: {}",
                                    title
                                );
                            }
                        }
                    }
                }
            });
        }

        loop {
            match connect_async(SIMPLEX_WS_URL).await {
                Ok((ws_stream, _)) => {
                    info!("[simplex_bridge] Connected to SimpleX CLI WebSocket");
                    let (mut sink, mut stream) = ws_stream.split();

                    ensure_invite_link(&mut sink).await;
                    ensure_axi_profile(&mut sink).await;

                    let mut ping_interval = tokio::time::interval(Duration::from_secs(30));
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
                            outbound = outbound_rx.recv() => {
                                if let Some((name, text)) = outbound {
                                    match send_message(&mut sink, &name, &text).await {
                                        Ok(()) => info!(
                                            "[simplex_bridge] Proactive delivery to {} ({} chars)",
                                            name, text.len()
                                        ),
                                        Err(e) => warn!(
                                            "[simplex_bridge] Proactive delivery failed to {}: {}",
                                            name, e
                                        ),
                                    }
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

                        let event: SimplexEvent = match serde_json::from_str(&text) {
                            Ok(e) => e,
                            Err(e) => {
                                log::debug!(
                                    "[simplex_bridge] Unparseable event: {} — {}",
                                    e,
                                    crate::str_utils::truncate_bytes_safe(&text, 200)
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
                                conn_req_invitation,
                                conn_link_invitation,
                            } => {
                                let link = conn_link_invitation
                                    .as_ref()
                                    .and_then(|l| {
                                        l.conn_short_link
                                            .clone()
                                            .or_else(|| l.conn_full_link.clone())
                                    })
                                    .or(conn_req_invitation);

                                let link = match link {
                                    Some(l) => l,
                                    None => {
                                        warn!("[simplex_bridge] Invitation response had no link");
                                        continue;
                                    }
                                };

                                info!(
                                    "[simplex_bridge] Invitation link: {}",
                                    &link.chars().take(60).collect::<String>()
                                );
                                let valid_scheme = link.starts_with("simplex://")
                                    || link.starts_with("simplex:/")
                                    || (link.starts_with("https://") && link.contains(".simplex."));
                                if link.is_empty() || link.len() > 2000 {
                                    warn!("[simplex_bridge] Invalid invite link length");
                                } else if !valid_scheme {
                                    warn!("[simplex_bridge] Invite link has unexpected format");
                                } else {
                                    persist_invite_link(&link);
                                }
                            }

                            SimplexResponse::ContactConnected { contact: Some(c) } => {
                                let name = c.local_display_name.as_deref().unwrap_or("unknown");
                                info!(
                                    "[simplex_bridge] Contact connected: {} (id={:?})",
                                    name, c.contact_id
                                );
                                // Send welcome message with capabilities
                                if let Some(n) = &c.local_display_name {
                                    let _ = send_message(
                                        &mut sink,
                                        n,
                                        "¡Hola! Soy Axi, tu asistente de LifeOS 🤖\n\n\
                                         Escribí /help para ver todo lo que puedo hacer.\n\n\
                                         Podés enviarme texto, fotos, notas de voz y archivos.",
                                    )
                                    .await;
                                }
                            }
                            SimplexResponse::ContactConnected { contact: None } => {}

                            // ----- File download completed -----
                            SimplexResponse::RcvFileComplete { chat_item } => {
                                let file_path = chat_item
                                    .as_ref()
                                    .and_then(|ci| ci.file.as_ref())
                                    .and_then(|f| f.file_path.clone());
                                let file_id = chat_item
                                    .as_ref()
                                    .and_then(|ci| ci.file.as_ref())
                                    .and_then(|f| f.file_id);

                                let action = if let Some(id) = file_id {
                                    let mut guard = pending_files.lock().await;
                                    let a = guard.remove(&id);
                                    if a.is_some() {
                                        persist_pending_files(&guard).await;
                                    }
                                    a
                                } else {
                                    None
                                };

                                if let (Some(path), Some(action)) = (file_path, action) {
                                    info!(
                                        "[simplex_bridge] File download complete: {} → {:?}",
                                        path, action
                                    );
                                    match action {
                                        PendingAction::TranscribeVoice { display_name } => {
                                            match transcribe_audio(&path).await {
                                                Some(transcript) => {
                                                    info!(
                                                        "[simplex_bridge] Voice transcribed from {}: {}",
                                                        display_name,
                                                        &transcript.chars().take(80).collect::<String>()
                                                    );
                                                    let (reply, _) = axi_tools::agentic_chat(
                                                        &tool_ctx,
                                                        SIMPLEX_CHAT_ID,
                                                        &format!("[Mensaje de voz] {}", transcript),
                                                        None,
                                                    )
                                                    .await;
                                                    let _ = send_message(
                                                        &mut sink,
                                                        &display_name,
                                                        &reply,
                                                    )
                                                    .await;
                                                }
                                                None => {
                                                    let _ = send_message(
                                                        &mut sink,
                                                        &display_name,
                                                        "No pude transcribir ese audio. ¿Podrías repetirlo o escribirlo?",
                                                    )
                                                    .await;
                                                }
                                            }
                                        }
                                        PendingAction::ProcessImage {
                                            display_name,
                                            caption,
                                        } => {
                                            // Use the full-res downloaded file
                                            if let Some(b64) = file_to_base64(&path).await {
                                                let prompt = if caption.is_empty() {
                                                    "El usuario envió esta imagen. Descríbela y responde a lo que muestra.".to_string()
                                                } else {
                                                    caption
                                                };
                                                let (reply, _) = axi_tools::agentic_chat(
                                                    &tool_ctx,
                                                    SIMPLEX_CHAT_ID,
                                                    &prompt,
                                                    Some(&b64),
                                                )
                                                .await;
                                                let _ =
                                                    send_message(&mut sink, &display_name, &reply)
                                                        .await;
                                            }
                                        }
                                    }
                                }
                            }

                            // ----- Incoming call — can't answer in headless mode -----
                            SimplexResponse::CallInvitation { contact } => {
                                let name = contact
                                    .as_ref()
                                    .and_then(|c| c.local_display_name.as_deref())
                                    .unwrap_or("unknown");
                                info!("[simplex_bridge] Call invitation from {}", name);
                                if let Some(c) = contact {
                                    if let Some(n) = c.local_display_name {
                                        let _ = send_message(
                                            &mut sink,
                                            &n,
                                            "Las llamadas de voz y video no están disponibles todavía en Axi. \
                                             Pero podés enviarme mensajes de voz 🎤 y te respondo por texto o audio. \
                                             También podés enviar fotos 📷 y las analizo.",
                                        )
                                        .await;
                                    }
                                }
                            }

                            // ----- New messages -----
                            SimplexResponse::NewChatItems { chat_items } => {
                                for item in &chat_items {
                                    let inner = match &item.chat_item {
                                        Some(i) => i,
                                        None => continue,
                                    };

                                    // Ignore our own outgoing messages
                                    match &inner.chat_dir {
                                        Some(ChatDir::DirectRcv) => {}
                                        _ => continue,
                                    }

                                    let display_name = match extract_display_name(item) {
                                        Some(n) => n,
                                        None => {
                                            log::warn!("[simplex_bridge] Message with no contact info, skipping");
                                            continue;
                                        }
                                    };

                                    // Remember this contact so proactive
                                    // messages (reminders) can find a target.
                                    remember_contact(&display_name);

                                    let msg_content =
                                        inner.content.as_ref().and_then(|c| c.msg_content.as_ref());

                                    let msg_content = match msg_content {
                                        Some(mc) => mc,
                                        None => continue,
                                    };

                                    match msg_content {
                                        // ── Text message ──
                                        MsgContent::Text { text } | MsgContent::Link { text } => {
                                            let msg_text = text.as_deref().unwrap_or("");
                                            if msg_text.is_empty() {
                                                continue;
                                            }

                                            info!(
                                                "[simplex_bridge] Text from {}: {}",
                                                display_name,
                                                &msg_text.chars().take(80).collect::<String>()
                                            );

                                            // Check for special commands and natural language intents
                                            let lower = msg_text.trim().to_lowercase();

                                            // ── Help / Menu ──
                                            if lower == "/help"
                                                || lower == "/menu"
                                                || lower == "/ayuda"
                                                || lower == "/start"
                                                || lower == "?"
                                            {
                                                let help = "\
📱 *Axi — SimpleX*

Podés hablar conmigo en lenguaje natural o usar estos atajos:

📷 *Cámara*
  `/foto` — Te envío una foto de la webcam
  O decime: \"tomá una foto\", \"qué ves por la cámara\"

🖥️ *Pantalla*
  `/pantalla` — Te envío una captura de pantalla
  O decime: \"qué hay en mi pantalla\", \"mandame un screenshot\"

🎤 *Audio*
  Mandame una nota de voz y la transcribo

🖼️ *Imágenes*
  Mandame una foto o imagen y la analizo

📎 *Archivos*
  Mandame cualquier archivo y lo guardo

💬 *Chat*
  Cualquier otra cosa — hablamos normal

📞 *Llamadas*
  No disponibles todavía (limitación del CLI)";
                                                let _ =
                                                    send_message(&mut sink, &display_name, help)
                                                        .await;
                                                continue;
                                            }

                                            // ── Camera: commands + natural language ──
                                            if lower == "/foto"
                                                || lower == "/camera"
                                                || lower == "/cam"
                                                || wants_camera(&lower)
                                            {
                                                match capture_camera_photo().await {
                                                    Some(path) => {
                                                        let _ = send_file(
                                                            &mut sink,
                                                            &display_name,
                                                            &path,
                                                        )
                                                        .await;
                                                    }
                                                    None => {
                                                        let _ = send_message(&mut sink, &display_name, "No pude capturar la foto de la cámara.").await;
                                                    }
                                                }
                                                continue;
                                            }

                                            // ── Screenshot: commands + natural language ──
                                            if lower == "/pantalla"
                                                || lower == "/screenshot"
                                                || lower == "/screen"
                                                || wants_screenshot(&lower)
                                            {
                                                match capture_screenshot().await {
                                                    Some(path) => {
                                                        let _ = send_file(
                                                            &mut sink,
                                                            &display_name,
                                                            &path,
                                                        )
                                                        .await;
                                                    }
                                                    None => {
                                                        let _ = send_message(
                                                            &mut sink,
                                                            &display_name,
                                                            "No pude capturar la pantalla.",
                                                        )
                                                        .await;
                                                    }
                                                }
                                                continue;
                                            }

                                            let (reply, _audio) = axi_tools::agentic_chat(
                                                &tool_ctx,
                                                SIMPLEX_CHAT_ID,
                                                msg_text,
                                                None,
                                            )
                                            .await;

                                            match send_message(&mut sink, &display_name, &reply)
                                                .await
                                            {
                                                Ok(()) => {
                                                    info!(
                                                        "[simplex_bridge] Reply sent to {} ({} chars)",
                                                        display_name, reply.len()
                                                    );
                                                }
                                                Err(e) => {
                                                    error!(
                                                        "[simplex_bridge] Failed to send reply to {}: {}",
                                                        display_name, e
                                                    );
                                                }
                                            }
                                        }

                                        // ── Image message ──
                                        MsgContent::Image { text, image } => {
                                            let caption = text.as_deref().unwrap_or("").to_string();
                                            info!(
                                                "[simplex_bridge] Image from {} (caption: '{}')",
                                                display_name,
                                                &caption.chars().take(40).collect::<String>()
                                            );

                                            // Try inline base64 thumbnail first for quick response
                                            let mut responded = false;
                                            if let Some(data_uri) = image {
                                                if let Some(path) =
                                                    save_data_uri_to_file(data_uri).await
                                                {
                                                    if let Some(b64) = file_to_base64(&path).await {
                                                        let prompt = if caption.is_empty() {
                                                            "El usuario envió esta imagen. Descríbela y responde.".to_string()
                                                        } else {
                                                            caption.clone()
                                                        };
                                                        let (reply, _) = axi_tools::agentic_chat(
                                                            &tool_ctx,
                                                            SIMPLEX_CHAT_ID,
                                                            &prompt,
                                                            Some(&b64),
                                                        )
                                                        .await;
                                                        let _ = send_message(
                                                            &mut sink,
                                                            &display_name,
                                                            &reply,
                                                        )
                                                        .await;
                                                        responded = true;
                                                    }
                                                }
                                            }

                                            // Also accept the full-res file if available
                                            if let Some(file_id) =
                                                inner.file.as_ref().and_then(|f| f.file_id)
                                            {
                                                if responded {
                                                    // Already responded with thumbnail — just download for archive
                                                    let _ = accept_file(&mut sink, file_id).await;
                                                } else {
                                                    // No thumbnail — wait for full file
                                                    {
                                                        let mut guard = pending_files.lock().await;
                                                        guard.insert(
                                                            file_id,
                                                            PendingAction::ProcessImage {
                                                                display_name: display_name.clone(),
                                                                caption,
                                                            },
                                                        );
                                                        persist_pending_files(&guard).await;
                                                    }
                                                    let _ = accept_file(&mut sink, file_id).await;
                                                }
                                            } else if !responded {
                                                let _ = send_message(
                                                    &mut sink,
                                                    &display_name,
                                                    "Recibí tu imagen pero no pude procesarla.",
                                                )
                                                .await;
                                            }
                                        }

                                        // ── Voice note ──
                                        MsgContent::Voice { text: _, duration } => {
                                            info!(
                                                "[simplex_bridge] Voice note from {} ({}s)",
                                                display_name,
                                                duration.unwrap_or(0)
                                            );

                                            if let Some(file_id) =
                                                inner.file.as_ref().and_then(|f| f.file_id)
                                            {
                                                {
                                                    let mut guard = pending_files.lock().await;
                                                    guard.insert(
                                                        file_id,
                                                        PendingAction::TranscribeVoice {
                                                            display_name: display_name.clone(),
                                                        },
                                                    );
                                                    persist_pending_files(&guard).await;
                                                }
                                                match accept_file(&mut sink, file_id).await {
                                                    Ok(()) => {
                                                        let _ = send_message(
                                                            &mut sink,
                                                            &display_name,
                                                            "🎤 Recibido, transcribiendo...",
                                                        )
                                                        .await;
                                                    }
                                                    Err(e) => {
                                                        error!(
                                                            "[simplex_bridge] Failed to accept voice file: {}",
                                                            e
                                                        );
                                                    }
                                                }
                                            } else {
                                                let _ = send_message(
                                                    &mut sink,
                                                    &display_name,
                                                    "No pude recibir el audio. ¿Podrías reenviarlo?",
                                                )
                                                .await;
                                            }
                                        }

                                        // ── Video message ──
                                        MsgContent::Video {
                                            text,
                                            image,
                                            duration,
                                        } => {
                                            info!(
                                                "[simplex_bridge] Video from {} ({}s)",
                                                display_name,
                                                duration.unwrap_or(0)
                                            );

                                            // Process the thumbnail if available
                                            let caption = text.as_deref().unwrap_or("").to_string();
                                            if let Some(data_uri) = image {
                                                if let Some(path) =
                                                    save_data_uri_to_file(data_uri).await
                                                {
                                                    if let Some(b64) = file_to_base64(&path).await {
                                                        let prompt = if caption.is_empty() {
                                                            format!(
                                                                "El usuario envió un video de {}s. Esta es una captura del video. Descríbela.",
                                                                duration.unwrap_or(0)
                                                            )
                                                        } else {
                                                            caption
                                                        };
                                                        let (reply, _) = axi_tools::agentic_chat(
                                                            &tool_ctx,
                                                            SIMPLEX_CHAT_ID,
                                                            &prompt,
                                                            Some(&b64),
                                                        )
                                                        .await;
                                                        let _ = send_message(
                                                            &mut sink,
                                                            &display_name,
                                                            &reply,
                                                        )
                                                        .await;
                                                        continue;
                                                    }
                                                }
                                            }

                                            let _ = send_message(
                                                &mut sink,
                                                &display_name,
                                                "Recibí tu video. Por ahora solo puedo analizar imágenes, pero estoy trabajando en soporte de video completo.",
                                            )
                                            .await;
                                        }

                                        // ── File message ──
                                        MsgContent::File { text } => {
                                            let filename = text.as_deref().unwrap_or("archivo");
                                            info!(
                                                "[simplex_bridge] File from {}: {}",
                                                display_name, filename
                                            );

                                            // Auto-accept the file
                                            if let Some(file_id) =
                                                inner.file.as_ref().and_then(|f| f.file_id)
                                            {
                                                let _ = accept_file(&mut sink, file_id).await;
                                            }

                                            let _ = send_message(
                                                &mut sink,
                                                &display_name,
                                                &format!("📎 Recibí el archivo '{}'. Lo guardé en el sistema.", filename),
                                            )
                                            .await;
                                        }

                                        // ── Unknown content type ──
                                        MsgContent::Unknown => {
                                            log::debug!(
                                                "[simplex_bridge] Unknown content type from {}",
                                                display_name
                                            );
                                        }
                                    }
                                }
                            }
                            SimplexResponse::Other => {}
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

            // NOTE: we used to clear pending_files on disconnect, but that
            // dropped voice transcription jobs mid-flight when the daemon
            // reconnected quickly. Keeping the map across reconnects lets
            // RcvFileComplete events delivered after reconnect still fire
            // the correct action. The map is still bounded because every
            // entry is removed once its RcvFileComplete arrives, and stale
            // entries are naturally cleared on full process restart.
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

#[cfg(feature = "messaging")]
pub use inner::*;

// Stub when telegram feature is disabled
#[cfg(not(feature = "messaging"))]
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

#[cfg(not(feature = "messaging"))]
pub(crate) use stubs::*;
