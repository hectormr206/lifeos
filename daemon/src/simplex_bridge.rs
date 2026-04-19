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
//! - **Receive video**: full file accepted via XFTP; ffmpeg extracts N
//!   keyframes (default 4, time-based fallback), ffprobe reports duration,
//!   and — when enabled — Whisper transcribes the audio track. Frames +
//!   transcript dispatched through the multimodal LLM. Limits: 120s / 50 MB.
//!   Config: `LIFEOS_VIDEO_TRANSCRIBE_AUDIO` (default true).
//! - **Send files**: camera photos, screenshots, TTS audio via `/f @name path`
//!
//! Activation: The bridge starts only when the SimpleX CLI WebSocket is
//! reachable on `ws://127.0.0.1:5226`.

#[cfg(feature = "messaging")]
mod inner {
    use futures_util::{SinkExt, StreamExt};
    use log::{debug, error, info, warn};
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
    use crate::session_store::SessionKey;
    use crate::task_queue::TaskQueue;

    /// WebSocket endpoint for the SimpleX CLI headless API.
    const SIMPLEX_WS_URL: &str = "ws://127.0.0.1:5226";
    /// Reconnect delay after connection failure.
    const RECONNECT_DELAY_SECS: u64 = 15;
    /// Synthetic `chat_id` used ONLY for the in-memory
    /// `ConversationHistory` index (which is keyed by `i64`) and for the
    /// event-bus reminder filter. Durable per-contact session replay lives
    /// on `SessionKey::simplex(contact_id)`, NOT on this magic id.
    const SIMPLEX_CHAT_ID: i64 = 0x534D_504C_5800_0001; // "SMPLX001"
    /// Path where the invite link is persisted for the dashboard.
    const INVITE_LINK_PATH: &str = "/var/lib/lifeos/simplex-invite-link";
    /// Canonical TTS output directory prefix — must match `synthesize_with_kokoro_http` output path.
    pub(crate) const TTS_OUTPUT_PREFIX: &str = "/var/lib/lifeos/tts/";
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
        /// Process a video: extract keyframes, optionally transcribe audio,
        /// then dispatch to the multimodal LLM.
        ProcessVideo {
            display_name: String,
            caption: String,
            /// Duration reported by SimpleX (seconds). Used as a fast-path
            /// size check; `ffprobe` is authoritative once the file lands.
            duration: Option<u64>,
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

    /// Defense-in-depth: sanitize a path before handing it to ffmpeg/ffprobe.
    ///
    /// ffmpeg treats any argument starting with `-` as a flag. A malicious
    /// (or just unusual) filename like `-i.mp4` could be mis-parsed. We:
    /// 1. Reject relative paths.
    /// 2. Reject paths whose filename begins with `-`.
    /// Returns the validated `PathBuf` on success.
    fn sanitize_ffmpeg_path(p: &std::path::Path) -> anyhow::Result<std::path::PathBuf> {
        if !p.is_absolute() {
            anyhow::bail!("ffmpeg path must be absolute: {}", p.display());
        }
        if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
            if name.starts_with('-') {
                anyhow::bail!("ffmpeg path filename begins with '-': {}", p.display());
            }
        }
        Ok(p.to_path_buf())
    }

    /// Startup defense-in-depth: remove stale `video-*` scratch dirs older
    /// than 24h under the downloads root. `TempDir` Drop handles the normal
    /// case; this sweep covers crash-before-drop scenarios.
    async fn sweep_stale_video_scratch() {
        let root = std::path::Path::new(DOWNLOADS_DIR);
        let mut rd = match tokio::fs::read_dir(root).await {
            Ok(r) => r,
            Err(_) => return,
        };
        let cutoff = std::time::SystemTime::now()
            .checked_sub(std::time::Duration::from_secs(24 * 3600));
        while let Ok(Some(entry)) = rd.next_entry().await {
            let path = entry.path();
            let name = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) => n.to_string(),
                None => continue,
            };
            if !name.starts_with("video-") {
                continue;
            }
            let is_old = match (entry.metadata().await, cutoff) {
                (Ok(md), Some(c)) => md.modified().map(|m| m < c).unwrap_or(false),
                _ => false,
            };
            if is_old {
                let _ = tokio::fs::remove_dir_all(&path).await;
                info!(
                    "[simplex_bridge] Sweep: borré scratch dir viejo {}",
                    path.display()
                );
            }
        }
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

    /// Whether to fan out reminder events (which are not yet per-contact
    /// addressable on SimpleX) to `last_known_contact()`. OFF by default —
    /// flipping it on has privacy implications: reminders originally tied
    /// to one context may reach whichever contact happened to be the most
    /// recent. Controlled by:
    /// - env `LIFEOS_SIMPLEX_FANOUT_REMINDERS` (1/true/yes/on), OR
    /// - `config.toml`: `[messaging.simplex] fanout_reminders_to_last_contact = true`
    async fn simplex_fanout_reminders_enabled() -> bool {
        use std::sync::OnceLock;
        use tokio::sync::RwLock;
        use tokio::time::{Duration, Instant};

        // (cached_at, resolved_bool). Hits and misses share the same TTL
        // since the value itself is always defined (default false).
        static CACHE: OnceLock<RwLock<Option<(Instant, bool)>>> = OnceLock::new();
        let cache = CACHE.get_or_init(|| RwLock::new(None));

        // Short hit TTL so dashboard toggles surface quickly; short miss TTL
        // so users enabling the flag after daemon start don't wait long.
        const HIT_TTL: Duration = Duration::from_secs(60);
        const MISS_TTL: Duration = Duration::from_secs(10);

        {
            let guard = cache.read().await;
            if let Some((stamped, val)) = guard.as_ref() {
                let ttl = if *val { HIT_TTL } else { MISS_TTL };
                if stamped.elapsed() < ttl {
                    return *val;
                }
            }
        }

        let resolved: bool = if let Ok(v) = std::env::var("LIFEOS_SIMPLEX_FANOUT_REMINDERS") {
            let v = v.trim().to_ascii_lowercase();
            matches!(v.as_str(), "1" | "true" | "yes" | "on")
        } else {
            let path = "/var/lib/lifeos/config-checkpoints/working/config.toml";
            match tokio::fs::read_to_string(path).await {
                Ok(raw) => match toml::from_str::<toml::Value>(&raw) {
                    Ok(parsed) => parsed
                        .get("messaging")
                        .and_then(|v| v.get("simplex"))
                        .and_then(|v| v.get("fanout_reminders_to_last_contact"))
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false),
                    Err(_) => false,
                },
                Err(_) => false,
            }
        };

        let mut w = cache.write().await;
        *w = Some((Instant::now(), resolved));
        resolved
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
        let safe_voice_input = sanitize_ffmpeg_path(std::path::Path::new(path));
        let ffmpeg = match safe_voice_input {
            Ok(safe) => {
                Command::new("ffmpeg")
                    .args([
                        "-y",
                        "-i",
                        safe.to_string_lossy().as_ref(),
                        "-ar",
                        "16000",
                        "-ac",
                        "1",
                        "-f",
                        "wav",
                        &wav_path,
                    ])
                    .output()
                    .await
            }
            Err(e) => {
                warn!("[simplex_bridge] voice ffmpeg rejected path: {}", e);
                return None;
            }
        };

        let input_path = if ffmpeg.map(|o| o.status.success()).unwrap_or(false) {
            &wav_path
        } else {
            path // try original file if conversion failed
        };

        // Round-2 audit C-NEW-4 — SimpleX voice notes are capped at
        // ~60s by the sender client and run through a small whisper
        // model, so ~120s timeout is plenty. `kill_on_drop(true)` so
        // a crashed / cancelled bridge doesn't leave orphans.
        let mut cmd = Command::new(whisper);
        cmd.args(["-m", model, "-f", input_path, "-l", "es", "--no-timestamps"])
            .kill_on_drop(true);
        let output =
            match tokio::time::timeout(std::time::Duration::from_secs(120), cmd.output()).await {
                Ok(Ok(o)) => o,
                Ok(Err(e)) => {
                    warn!("[simplex_bridge] whisper spawn failed: {}", e);
                    let _ = tokio::fs::remove_file(&wav_path).await;
                    return None;
                }
                Err(_) => {
                    warn!("[simplex_bridge] whisper transcription timed out");
                    let _ = tokio::fs::remove_file(&wav_path).await;
                    return None;
                }
            };

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

    // -----------------------------------------------------------------------
    // Video processing — full-frame support for SimpleX video messages
    // -----------------------------------------------------------------------

    /// Max accepted video duration (seconds). Longer clips are rejected with a
    /// friendly Rioplatense reply.
    const VIDEO_MAX_DURATION_SECS: u64 = 120;
    /// Max accepted video file size (bytes). 50 MB.
    const VIDEO_MAX_BYTES: u64 = 50 * 1024 * 1024;
    /// Default number of keyframes to extract from a video.
    const VIDEO_KEYFRAMES: u32 = 4;
    /// ffmpeg / ffprobe hard timeout per invocation.
    const VIDEO_FFMPEG_TIMEOUT_SECS: u64 = 60;

    /// Whether to extract the audio track of a video and transcribe it with
    /// Whisper. Controlled by `LIFEOS_VIDEO_TRANSCRIBE_AUDIO` (default true).
    fn video_transcribe_audio_enabled() -> bool {
        match std::env::var("LIFEOS_VIDEO_TRANSCRIBE_AUDIO") {
            Ok(v) => {
                let v = v.trim().to_ascii_lowercase();
                !(v == "0" || v == "false" || v == "no" || v == "off")
            }
            Err(_) => true,
        }
    }

    /// Run `ffprobe` to obtain the duration of a media file in seconds.
    async fn probe_video_duration(path: &str) -> Option<f64> {
        let safe_path = match sanitize_ffmpeg_path(std::path::Path::new(path)) {
            Ok(p) => p,
            Err(e) => {
                warn!("[simplex_bridge] ffprobe rejected path: {}", e);
                return None;
            }
        };
        let mut cmd = Command::new("ffprobe");
        cmd.args([
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "csv=p=0",
            safe_path.to_string_lossy().as_ref(),
        ])
        .kill_on_drop(true);
        let output = match tokio::time::timeout(
            Duration::from_secs(VIDEO_FFMPEG_TIMEOUT_SECS),
            cmd.output(),
        )
        .await
        {
            Ok(Ok(o)) => o,
            Ok(Err(e)) => {
                warn!("[simplex_bridge] ffprobe spawn failed: {}", e);
                return None;
            }
            Err(_) => {
                warn!("[simplex_bridge] ffprobe timed out");
                return None;
            }
        };
        if !output.status.success() {
            return None;
        }
        let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
        s.parse::<f64>().ok()
    }

    /// Extract up to `n` frames from a video.
    ///
    /// Strategy: first try keyframe selection (I-frames); if that returns fewer
    /// frames than requested, fall back to evenly spaced time-based extraction.
    /// Returns a list of paths to extracted JPEG frames in temporal order.
    async fn extract_video_keyframes(
        video_path: &str,
        out_dir: &std::path::Path,
        n: u32,
        duration_secs: Option<f64>,
    ) -> Vec<std::path::PathBuf> {
        let _ = tokio::fs::create_dir_all(out_dir).await;

        let safe_input = match sanitize_ffmpeg_path(std::path::Path::new(video_path)) {
            Ok(p) => p,
            Err(e) => {
                warn!("[simplex_bridge] extract_video_keyframes rejected path: {}", e);
                return Vec::new();
            }
        };
        let safe_input_str = safe_input.to_string_lossy().into_owned();

        // Attempt 1 — keyframe selection. ffmpeg's `thumbnail` filter picks the
        // most representative frame per scene; `eq(pict_type,I)` restricts to
        // I-frames. `-vsync vfr` avoids duplicate padding.
        let kf_pattern = out_dir.join("kf_%02d.jpg");
        let mut cmd = Command::new("ffmpeg");
        cmd.args([
            "-y",
            "-i",
            safe_input_str.as_str(),
            "-vf",
            "select='eq(pict_type,I)',thumbnail,scale=-1:480",
            "-frames:v",
            &n.to_string(),
            "-vsync",
            "vfr",
            kf_pattern.to_string_lossy().as_ref(),
        ])
        .kill_on_drop(true);
        let _ = tokio::time::timeout(
            Duration::from_secs(VIDEO_FFMPEG_TIMEOUT_SECS),
            cmd.output(),
        )
        .await;

        let mut frames = collect_frames(out_dir, "kf_").await;
        if frames.len() as u32 >= n {
            frames.truncate(n as usize);
            return frames;
        }

        // Attempt 2 — time-based fallback. Pick N evenly spaced timestamps
        // (25%, 50%, 75%, ...) and extract one frame per timestamp.
        if let Some(total) = duration_secs.filter(|d| *d > 0.0) {
            // Clear previous partial frames to avoid mixing modes.
            for f in &frames {
                let _ = tokio::fs::remove_file(f).await;
            }
            frames.clear();
            for i in 0..n {
                // Spread across middle of clip: (i+1)/(n+1) * total.
                let t = (i as f64 + 1.0) / (n as f64 + 1.0) * total;
                let out_path = out_dir.join(format!("tb_{:02}.jpg", i));
                let mut c = Command::new("ffmpeg");
                c.args([
                    "-y",
                    "-ss",
                    &format!("{:.3}", t),
                    "-i",
                    safe_input_str.as_str(),
                    "-frames:v",
                    "1",
                    "-vf",
                    "scale=-1:480",
                    out_path.to_string_lossy().as_ref(),
                ])
                .kill_on_drop(true);
                let _ = tokio::time::timeout(
                    Duration::from_secs(VIDEO_FFMPEG_TIMEOUT_SECS),
                    c.output(),
                )
                .await;
                if out_path.exists() {
                    frames.push(out_path);
                }
            }
        }

        frames
    }

    /// List extracted frame files with the given prefix, sorted by name.
    async fn collect_frames(
        out_dir: &std::path::Path,
        prefix: &str,
    ) -> Vec<std::path::PathBuf> {
        let mut out = Vec::new();
        if let Ok(mut rd) = tokio::fs::read_dir(out_dir).await {
            while let Ok(Some(entry)) = rd.next_entry().await {
                let p = entry.path();
                if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                    if name.starts_with(prefix) && name.ends_with(".jpg") {
                        out.push(p);
                    }
                }
            }
        }
        out.sort();
        out
    }

    /// Extract the audio track of a video to a WAV file suitable for
    /// `transcribe_audio`. Returns the WAV path on success.
    async fn extract_video_audio(video_path: &str, out_dir: &std::path::Path) -> Option<String> {
        let safe_input = match sanitize_ffmpeg_path(std::path::Path::new(video_path)) {
            Ok(p) => p,
            Err(e) => {
                warn!("[simplex_bridge] extract_video_audio rejected path: {}", e);
                return None;
            }
        };
        let wav = out_dir.join("audio.wav");
        let mut cmd = Command::new("ffmpeg");
        cmd.args([
            "-y",
            "-i",
            safe_input.to_string_lossy().as_ref(),
            "-vn",
            "-ar",
            "16000",
            "-ac",
            "1",
            "-f",
            "wav",
            wav.to_string_lossy().as_ref(),
        ])
        .kill_on_drop(true);
        let out = tokio::time::timeout(
            Duration::from_secs(VIDEO_FFMPEG_TIMEOUT_SECS),
            cmd.output(),
        )
        .await;
        match out {
            Ok(Ok(o)) if o.status.success() && wav.exists() => {
                Some(wav.to_string_lossy().into_owned())
            }
            _ => None,
        }
    }

    /// Build a human-readable prompt describing a video for the LLM.
    fn build_video_prompt(
        caption: &str,
        duration_secs: Option<f64>,
        frame_count: usize,
        transcript: Option<&str>,
    ) -> String {
        let dur = duration_secs
            .map(|d| format!("{:.1}s", d))
            .unwrap_or_else(|| "duración desconocida".to_string());
        let mut out = if caption.is_empty() {
            format!(
                "El usuario envió un video de {} con {} frames clave adjuntos. \
                 Describí lo que se ve y respondé.",
                dur, frame_count
            )
        } else {
            format!(
                "{}\n\n[Contexto: video de {} con {} frames clave]",
                caption, dur, frame_count
            )
        };
        if let Some(t) = transcript.filter(|t| !t.trim().is_empty()) {
            out.push_str("\n\n[Transcripción del audio] ");
            out.push_str(t);
        }
        out
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
        sensory_pipeline_for_tools: Option<
            Arc<RwLock<crate::sensory_pipeline::SensoryPipelineManager>>,
        >,
        history: Arc<ConversationHistory>,
        cron_store: Arc<CronStore>,
        event_bus: Option<tokio::sync::broadcast::Sender<crate::events::DaemonEvent>>,
    ) {
        info!(
            "[simplex_bridge] Starting SimpleX bridge (ws={})",
            SIMPLEX_WS_URL
        );

        ensure_downloads_dir();
        sweep_stale_video_scratch().await;

        // One-shot legacy session archive: a previous build stored ALL
        // SimpleX turns under the synthetic telegram_dm(SIMPLEX_CHAT_ID)
        // directory — mixing messages from every contact into a single
        // transcript. We CANNOT safely rebind that to one contact, so we
        // archive it under `.legacy_archive/` and start fresh per-contact.
        if let Some(ref store) = session_store {
            match store.archive_simplex_legacy_session(SIMPLEX_CHAT_ID).await {
                Ok(true) => info!(
                    "[simplex_bridge] Archivé la sesión legacy de SimpleX \
                     (historia mixta pre-upgrade, no se puede atribuir a un \
                     solo contacto). Arrancamos de cero por contacto, dale."
                ),
                Ok(false) => {}
                Err(e) => warn!(
                    "[simplex_bridge] Falló el archivado de la sesión legacy: {}",
                    e
                ),
            }
        }

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
            sensory_pipeline: sensory_pipeline_for_tools.clone(),
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
                            // Privacy gate: the SimpleX CLI does not expose
                            // per-chat_id contact mapping, so "fan out to
                            // last_known_contact" would silently leak a
                            // reminder to whichever contact happened to be
                            // most recent. OFF by default; users who
                            // explicitly opt in via config or env accept
                            // the tradeoff.
                            if !simplex_fanout_reminders_enabled().await {
                                warn!(
                                    "[simplex_bridge] Reminder '{}' no se entrega: \
                                     messaging.simplex.fanout_reminders_to_last_contact=false \
                                     (default). Activalo explícito si querés fan-out.",
                                    title
                                );
                                continue;
                            }
                            let msg = format!("🔔 Recordatorio ({}): {}", start_time, title);
                            let contact = last_known_contact();
                            if let Some(name) = contact {
                                let _ = outbound.send((name, msg));
                            } else {
                                warn!(
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
                                debug!(
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
                                                    // C-7 fix: no transcript content in
                                                    // journald — length-only log. Previously
                                                    // the first 80 chars landed in the
                                                    // system journal alongside the
                                                    // contact's display name.
                                                    info!(
                                                        "[simplex_bridge] Voice transcribed from {} ({} chars)",
                                                        display_name,
                                                        transcript.chars().count()
                                                    );
                                                    // C-6 fix: force sensitivity to Critical
                                                    // so the LLM router pins to LOCAL tier
                                                    // only. Voice notes are sensory artifacts
                                                    // that must never leave the device
                                                    // even when BYOK cloud providers are
                                                    // configured.
                                                    //
                                                    // W-NEW-5: mark the chat as voice-originated
                                                    // so EVERY follow-up turn on this chat
                                                    // inherits the clamp, even when the next
                                                    // message is plain text ("sí dale" / "ok").
                                                    tool_ctx
                                                        .history
                                                        .mark_voice_origin(SIMPLEX_CHAT_ID)
                                                        .await;
                                                    let (reply, _) =
                                                        axi_tools::agentic_chat_with_session(
                                                            &tool_ctx,
                                                            SIMPLEX_CHAT_ID,
                                                            &format!(
                                                                "[Mensaje de voz] {}",
                                                                transcript
                                                            ),
                                                            None,
                                                            Some(
                                                                crate::privacy_filter::SensitivityLevel::Critical,
                                                            ),
                                                            Some(SessionKey::simplex(&display_name)),
                                                        )
                                                        .await;
                                                    let _ = send_message(
                                                        &mut sink,
                                                        &display_name,
                                                        &reply,
                                                    )
                                                    .await;
                                                    // ── Voice-note reply hook (E2) ──
                                                    // For voice-originated inputs, synthesize reply as OGG
                                                    // and send as voice note (max 600 chars, max 1 MB).
                                                    //
                                                    // Habla audit C-2: gate on Sense::Tts BEFORE
                                                    // synthesising. Without this, the voice-note
                                                    // reply path kept synthesising + sending
                                                    // audio over SimpleX even with tts_enabled=false
                                                    // or kill switch engaged. Gate checks
                                                    // kill_switch + tts_enabled + suspend.
                                                    let tts_gate_ok = if let Some(ref sens) =
                                                        tool_ctx.sensory_pipeline
                                                    {
                                                        sens.read()
                                                            .await
                                                            .ensure_sense_allowed(
                                                                crate::sensory_pipeline::Sense::Tts,
                                                                "simplex_bridge.voice_note_reply",
                                                            )
                                                            .await
                                                            .is_ok()
                                                    } else {
                                                        // Fail-closed when manager isn't wired —
                                                        // consistent with the mic gate.
                                                        false
                                                    };
                                                    if reply.len() <= 600 && tts_gate_ok {
                                                        let server_url =
                                                            std::env::var("LIFEOS_TTS_SERVER_URL")
                                                                .unwrap_or_else(|_| {
                                                                    "http://127.0.0.1:8084"
                                                                        .to_string()
                                                                });
                                                        let env_default = std::env::var(
                                                            "LIFEOS_TTS_DEFAULT_VOICE",
                                                        )
                                                        .unwrap_or_else(|_| "if_sara".to_string());
                                                        // Usa el singleton kokoro_probe_client (connect 500ms, timeout 2s)
                                                        // para no bloquear el path de respuesta de Simplex.
                                                        // En caso de fallo degrada a &[] sin validación de voz.
                                                        let available_voices: Vec<crate::sensory_pipeline::KokoroVoice> =
                                                            crate::sensory_pipeline::fetch_kokoro_voices(
                                                                crate::sensory_pipeline::kokoro_probe_client(),
                                                                &server_url,
                                                            )
                                                            .await;
                                                        let voice = if let Some(ref um_arc) =
                                                            tool_ctx.user_model
                                                        {
                                                            let um = um_arc.read().await;
                                                            crate::sensory_pipeline::resolve_tts_voice(
                                                                &um,
                                                                &env_default,
                                                                None,
                                                                &available_voices,
                                                            )
                                                        } else {
                                                            env_default.clone()
                                                        };
                                                        match crate::sensory_pipeline::synthesize_with_kokoro_http(
                                                            &std::path::PathBuf::from("/var/lib/lifeos"),
                                                            &server_url,
                                                            &reply,
                                                            &voice,
                                                            "ogg",
                                                        ).await {
                                                            Ok(ref audio_path) => {
                                                                // Sanity check: path must be within the canonical
                                                                // TTS output directory created by synthesize_with_kokoro_http.
                                                                let canonical = std::path::Path::new(audio_path);
                                                                if !canonical.starts_with(TTS_OUTPUT_PREFIX) {
                                                                    warn!("[simplex_bridge] TTS output path outside expected dir: {}", audio_path);
                                                                } else {
                                                                    // File size guard: skip if > 1 MB
                                                                    let size_ok = tokio::fs::metadata(audio_path).await
                                                                        .map(|m| m.len() <= 1_048_576)
                                                                        .unwrap_or(false);
                                                                    if size_ok {
                                                                        let _ = send_file(&mut sink, &display_name, audio_path).await;
                                                                    } else {
                                                                        warn!("[simplex_bridge] TTS OGG too large (>1 MB), skipping voice note");
                                                                    }
                                                                    // Schedule cleanup after 60s
                                                                    let cleanup_path = audio_path.clone();
                                                                    tokio::spawn(async move {
                                                                        tokio::time::sleep(std::time::Duration::from_secs(60)).await;
                                                                        tokio::fs::remove_file(&cleanup_path).await.ok();
                                                                    });
                                                                }
                                                            }
                                                            Err(e) => {
                                                                warn!("[simplex_bridge] TTS synthesis for voice reply failed: {}", e);
                                                            }
                                                        }
                                                    }
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
                                                let (reply, _) = axi_tools::agentic_chat_with_session(
                                                    &tool_ctx,
                                                    SIMPLEX_CHAT_ID,
                                                    &prompt,
                                                    Some(&b64),
                                                    None,
                                                    Some(SessionKey::simplex(&display_name)),
                                                )
                                                .await;
                                                let _ =
                                                    send_message(&mut sink, &display_name, &reply)
                                                        .await;
                                            }
                                        }
                                        PendingAction::ProcessVideo {
                                            display_name,
                                            caption,
                                            duration,
                                        } => {
                                            // Authoritative size check on the landed file — the
                                            // message hint can lie; the file on disk can't.
                                            let size = tokio::fs::metadata(&path)
                                                .await
                                                .map(|m| m.len())
                                                .unwrap_or(0);
                                            if size > VIDEO_MAX_BYTES {
                                                let _ = send_message(
                                                    &mut sink,
                                                    &display_name,
                                                    "Ese video supera los 50 MB que puedo procesar, loco. \
                                                     Mandame un clip más cortito (hasta 120s / 50 MB) y lo vemos.",
                                                )
                                                .await;
                                                let _ = tokio::fs::remove_file(&path).await;
                                                continue;
                                            }

                                            // Authoritative duration via ffprobe.
                                            let ffprobe_dur = probe_video_duration(&path).await;
                                            let effective_dur =
                                                ffprobe_dur.or_else(|| duration.map(|d| d as f64));
                                            if let Some(d) = effective_dur {
                                                if d > VIDEO_MAX_DURATION_SECS as f64 {
                                                    let _ = send_message(
                                                        &mut sink,
                                                        &display_name,
                                                        &format!(
                                                            "El video dura {:.0}s y solo puedo \
                                                             analizar hasta {}s. Dale, recortalo \
                                                             y lo vemos.",
                                                            d, VIDEO_MAX_DURATION_SECS
                                                        ),
                                                    )
                                                    .await;
                                                    let _ = tokio::fs::remove_file(&path).await;
                                                    continue;
                                                }
                                            }

                                            // Scratch dir for frames + extracted audio. `TempDir`
                                            // cleans up on ALL paths (success, error, panic) via Drop.
                                            let work_tmp = match tempfile::Builder::new()
                                                .prefix("video-")
                                                .tempdir_in(DOWNLOADS_DIR)
                                            {
                                                Ok(t) => t,
                                                Err(e) => {
                                                    warn!(
                                                        "[simplex_bridge] No pude crear scratch dir: {}",
                                                        e
                                                    );
                                                    let _ = tokio::fs::remove_file(&path).await;
                                                    continue;
                                                }
                                            };
                                            let work_dir = work_tmp.path().to_path_buf();

                                            let frames = extract_video_keyframes(
                                                &path,
                                                &work_dir,
                                                VIDEO_KEYFRAMES,
                                                effective_dur,
                                            )
                                            .await;

                                            if frames.is_empty() {
                                                warn!(
                                                    "[simplex_bridge] Could not extract any frames from {}",
                                                    path
                                                );
                                                let _ = send_message(
                                                    &mut sink,
                                                    &display_name,
                                                    "Recibí el video pero no pude sacar frames para analizarlo. \
                                                     Fijate si podés reenviarlo.",
                                                )
                                                .await;
                                                // work_tmp drops here, cleans up.
                                                let _ = tokio::fs::remove_file(&path).await;
                                                continue;
                                            }

                                            // Optional — extract and transcribe the audio track.
                                            let transcript = if video_transcribe_audio_enabled() {
                                                match extract_video_audio(&path, &work_dir).await {
                                                    Some(wav) => {
                                                        let t = transcribe_audio(&wav).await;
                                                        let _ = tokio::fs::remove_file(&wav).await;
                                                        t
                                                    }
                                                    None => None,
                                                }
                                            } else {
                                                None
                                            };

                                            // Primary frame (frame 0) is passed to the multimodal
                                            // LLM as the image part. Remaining frames are
                                            // announced in the prompt so the model knows they
                                            // exist; when a multi-image pathway lands, this is
                                            // the hook to extend.
                                            let primary_b64 = file_to_base64(
                                                frames[0].to_string_lossy().as_ref(),
                                            )
                                            .await;

                                            let prompt = build_video_prompt(
                                                &caption,
                                                effective_dur,
                                                frames.len(),
                                                transcript.as_deref(),
                                            );

                                            let (reply, _) = axi_tools::agentic_chat_with_session(
                                                &tool_ctx,
                                                SIMPLEX_CHAT_ID,
                                                &prompt,
                                                primary_b64.as_deref(),
                                                None,
                                                Some(SessionKey::simplex(&display_name)),
                                            )
                                            .await;
                                            let _ = send_message(
                                                &mut sink,
                                                &display_name,
                                                &reply,
                                            )
                                            .await;

                                            // Cleanup — `work_tmp` drops here and recursively
                                            // removes the scratch dir. We still explicitly unlink
                                            // the downloaded video since it lives in DOWNLOADS_DIR,
                                            // not inside the scratch tempdir.
                                            drop(work_tmp);
                                            let _ = tokio::fs::remove_file(&path).await;
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
                                            warn!("[simplex_bridge] Message with no contact info, skipping");
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
                                                // Shared screen-capture gate — refuses when
                                                // screen_enabled=false / kill switch / suspend /
                                                // session locked / sensitive window. Round-2
                                                // audit C-NEW-4: this command previously shipped
                                                // a live screenshot over the network with zero
                                                // policy check.
                                                let gate = if let Some(ref sens) =
                                                    tool_ctx.sensory_pipeline
                                                {
                                                    sens.read()
                                                        .await
                                                        .ensure_screen_capture_allowed()
                                                        .await
                                                        .map_err(|r| r.to_string())
                                                } else {
                                                    Ok(())
                                                };
                                                if let Err(reason) = gate {
                                                    let _ = send_message(
                                                        &mut sink,
                                                        &display_name,
                                                        &format!("Captura rechazada: {}", reason),
                                                    )
                                                    .await;
                                                    continue;
                                                }
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

                                            let (reply, _audio) = axi_tools::agentic_chat_with_session(
                                                &tool_ctx,
                                                SIMPLEX_CHAT_ID,
                                                msg_text,
                                                None,
                                                None,
                                                Some(SessionKey::simplex(&display_name)),
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
                                                        let (reply, _) = axi_tools::agentic_chat_with_session(
                                                            &tool_ctx,
                                                            SIMPLEX_CHAT_ID,
                                                            &prompt,
                                                            Some(&b64),
                                                            None,
                                                            Some(SessionKey::simplex(&display_name)),
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
                                        //
                                        // Full-frame flow:
                                        // 1. Reject up-front if the reported duration already
                                        //    exceeds 120s or the file_size (if advertised)
                                        //    exceeds 50 MB — no point downloading.
                                        // 2. Queue a ProcessVideo pending action and
                                        //    auto-accept the XFTP transfer. The real work
                                        //    (keyframe extraction, optional audio transcription,
                                        //    LLM dispatch) happens on rcvFileComplete.
                                        // 3. If an inline thumbnail is present, fire a quick
                                        //    "I'm thinking" reply using it as frame 0 — purely
                                        //    a progressive UX hint. The authoritative analysis
                                        //    still runs on the downloaded file.
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

                                            let caption =
                                                text.as_deref().unwrap_or("").to_string();

                                            // Early duration limit check.
                                            if let Some(d) = duration {
                                                if *d > VIDEO_MAX_DURATION_SECS {
                                                    let _ = send_message(
                                                        &mut sink,
                                                        &display_name,
                                                        &format!(
                                                            "El video dura {}s y solo puedo \
                                                             analizar hasta {}s. Dale, mandame \
                                                             un clip más corto.",
                                                            *d, VIDEO_MAX_DURATION_SECS
                                                        ),
                                                    )
                                                    .await;
                                                    continue;
                                                }
                                            }

                                            // Early size check from the advertised transfer.
                                            let advertised_size = inner
                                                .file
                                                .as_ref()
                                                .and_then(|f| f.file_size)
                                                .unwrap_or(0);
                                            if advertised_size > VIDEO_MAX_BYTES {
                                                let _ = send_message(
                                                    &mut sink,
                                                    &display_name,
                                                    "Ese video supera los 50 MB que puedo procesar, loco. \
                                                     Mandame un clip más cortito (hasta 120s / 50 MB) y lo vemos.",
                                                )
                                                .await;
                                                continue;
                                            }

                                            // Progressive UX: if a thumbnail came inline, send
                                            // a quick "on it" message with the thumb analyzed
                                            // as frame 0 while the full file downloads.
                                            if let Some(data_uri) = image {
                                                if let Some(thumb_path) =
                                                    save_data_uri_to_file(data_uri).await
                                                {
                                                    if let Some(b64) =
                                                        file_to_base64(&thumb_path).await
                                                    {
                                                        let prompt = format!(
                                                            "El usuario envió un video de {}s. \
                                                             Esta es una captura previa mientras \
                                                             descargo el archivo completo. \
                                                             Decí algo cortito (una línea) sobre \
                                                             lo que ves en la captura; ya voy a \
                                                             responder más detalladamente cuando \
                                                             procese los frames.",
                                                            duration.unwrap_or(0)
                                                        );
                                                        let (reply, _) =
                                                            axi_tools::agentic_chat_with_session(
                                                                &tool_ctx,
                                                                SIMPLEX_CHAT_ID,
                                                                &prompt,
                                                                Some(&b64),
                                                                None,
                                                                Some(SessionKey::simplex(
                                                                    &display_name,
                                                                )),
                                                            )
                                                            .await;
                                                        let _ = send_message(
                                                            &mut sink,
                                                            &display_name,
                                                            &reply,
                                                        )
                                                        .await;
                                                    }
                                                    // Cleanup the inline thumbnail — we'll
                                                    // re-extract real frames from the full file.
                                                    let _ = tokio::fs::remove_file(&thumb_path).await;
                                                }
                                            }

                                            // Queue full-file processing. XFTP download is
                                            // kicked off by accept_file; the rcvFileComplete
                                            // branch picks up the ProcessVideo action.
                                            if let Some(file_id) =
                                                inner.file.as_ref().and_then(|f| f.file_id)
                                            {
                                                {
                                                    let mut guard = pending_files.lock().await;
                                                    guard.insert(
                                                        file_id,
                                                        PendingAction::ProcessVideo {
                                                            display_name: display_name.clone(),
                                                            caption: caption.clone(),
                                                            duration: *duration,
                                                        },
                                                    );
                                                    persist_pending_files(&guard).await;
                                                }
                                                match accept_file(&mut sink, file_id).await {
                                                    Ok(()) => {
                                                        let _ = send_message(
                                                            &mut sink,
                                                            &display_name,
                                                            "🎬 Recibiendo el video, dame un cachito \
                                                             que lo proceso...",
                                                        )
                                                        .await;
                                                    }
                                                    Err(e) => {
                                                        error!(
                                                            "[simplex_bridge] Failed to accept video file: {}",
                                                            e
                                                        );
                                                        let _ = send_message(
                                                            &mut sink,
                                                            &display_name,
                                                            "No pude aceptar el archivo del video. \
                                                             ¿Me lo reenviás?",
                                                        )
                                                        .await;
                                                    }
                                                }
                                            } else {
                                                // No XFTP transfer attached — we only have the
                                                // thumbnail response already sent (if any).
                                                let _ = send_message(
                                                    &mut sink,
                                                    &display_name,
                                                    "Recibí el video pero no vino el archivo completo. \
                                                     Probá reenviarlo.",
                                                )
                                                .await;
                                            }
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
                                            debug!(
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

// ── Tests ─────────────────────────────────────────────────────────────────────
#[cfg(test)]
#[cfg(feature = "messaging")]
mod tests {
    use super::inner::TTS_OUTPUT_PREFIX;

    /// Test 1: TTS_OUTPUT_PREFIX matches the canonical output directory of
    /// `synthesize_with_kokoro_http`, which writes to `{data_dir}/tts/axi-<uuid>.<ext>`.
    /// The guard in the voice-note handler must use this prefix exactly.
    #[test]
    fn test_tts_output_prefix_matches_kokoro_output_path() {
        // synthesize_with_kokoro_http writes to data_dir.join("tts").join("axi-<uuid>.<ext>")
        // With data_dir = /var/lib/lifeos this becomes /var/lib/lifeos/tts/axi-*.ogg
        let data_dir = std::path::Path::new("/var/lib/lifeos");
        let example_path = data_dir.join("tts").join("axi-test.ogg");

        assert!(
            example_path.starts_with(TTS_OUTPUT_PREFIX),
            "Expected kokoro output path {:?} to start_with TTS_OUTPUT_PREFIX {:?}",
            example_path,
            TTS_OUTPUT_PREFIX
        );

        // The old/wrong prefix must NOT match
        let wrong_prefix = "/var/lib/lifeos/tts-output/";
        assert!(
            !example_path.starts_with(wrong_prefix),
            "Old broken prefix {:?} must NOT match kokoro output path {:?}",
            wrong_prefix,
            example_path
        );
    }

    /// Test 2: fetch_kokoro_voices is pub — verifiable at compile time.
    /// If the function is private, this test will not compile with E0603.
    #[test]
    fn test_fetch_kokoro_voices_is_pub() {
        // Compile-only proof: reference the function by path — E0603 if private.
        let _ = crate::sensory_pipeline::fetch_kokoro_voices as fn(_, _) -> _;
    }
}
