//! Meeting Assistant — Auto-detect video calls and record/transcribe them.
//!
//! Detection strategy (combined signals for high confidence):
//! 1. PipeWire: monitor `pactl list sink-inputs` for conferencing app audio streams
//! 2. Camera: check `fuser /dev/video0` for browser/Zoom holding the webcam
//! 3. Window title: patterns like "Zoom Meeting", "Google Meet", "Microsoft Teams"
//!
//! Recording: `pw-record --target=<sink>` captures the meeting audio stream.
//! Transcription: Whisper STT post-meeting, then LLM summarization.

use anyhow::{Context, Result};
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::process::Command;
use tokio::sync::broadcast;

/// Known conferencing applications and their process/window identifiers.
const CONFERENCING_APPS: &[(&str, &[&str])] = &[
    ("Zoom", &["zoom", "ZoomWebinarWin", "Zoom Meeting"]),
    ("Google Meet", &["Google Meet", "meet.google.com"]),
    (
        "Microsoft Teams",
        &["teams", "Microsoft Teams", "teams.microsoft.com"],
    ),
    ("Discord", &["discord", "Discord"]),
    ("Slack Huddle", &["slack", "Slack"]),
    ("Jitsi", &["jitsi", "Jitsi Meet"]),
    ("WebEx", &["webex", "Cisco Webex"]),
];

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MeetingState {
    pub detected: bool,
    pub app_name: Option<String>,
    pub recording: bool,
    pub recording_path: Option<String>,
    pub started_at: Option<String>,
    pub duration_secs: u64,
}

/// Window title patterns that indicate an active meeting.
/// Each entry is (app name, list of title substrings to match).
const MEETING_WINDOW_PATTERNS: &[(&str, &[&str])] = &[
    ("Zoom", &["Zoom Meeting", "Zoom Webinar"]),
    ("Google Meet", &["Google Meet", "meet.google.com"]),
    (
        "Microsoft Teams",
        &["Microsoft Teams", "teams.microsoft.com"],
    ),
    ("Discord", &["Discord"]),
    ("Slack Huddle", &["Huddle"]),
    ("Jitsi", &["Jitsi Meet"]),
    ("WebEx", &["WebEx Meeting", "Cisco Webex"]),
];

/// Additional keywords that must appear alongside certain apps to confirm a meeting.
/// Discord needs "Voice" or "Stage"; Slack needs "Huddle".
const MEETING_QUALIFIER_PATTERNS: &[(&str, &[&str])] = &[
    ("Discord", &["Voice", "Stage"]),
    ("Slack Huddle", &["Huddle"]),
];

pub struct MeetingAssistant {
    data_dir: PathBuf,
    enabled: bool,
    state: MeetingState,
    recording_process: Option<tokio::process::Child>,
    language: String,
    event_bus: Option<broadcast::Sender<crate::events::DaemonEvent>>,
    llm_router: Option<std::sync::Arc<tokio::sync::RwLock<crate::llm_router::LlmRouter>>>,
    memory_plane:
        Option<std::sync::Arc<tokio::sync::RwLock<crate::memory_plane::MemoryPlaneManager>>>,
}

impl MeetingAssistant {
    pub fn new(
        data_dir: PathBuf,
        event_bus: Option<broadcast::Sender<crate::events::DaemonEvent>>,
        llm_router: Option<std::sync::Arc<tokio::sync::RwLock<crate::llm_router::LlmRouter>>>,
        memory_plane: Option<
            std::sync::Arc<tokio::sync::RwLock<crate::memory_plane::MemoryPlaneManager>>,
        >,
    ) -> Self {
        Self {
            data_dir,
            enabled: std::env::var("LIFEOS_MEETING_ASSISTANT")
                .map(|v| v != "0" && !v.eq_ignore_ascii_case("false"))
                .unwrap_or(true),
            state: MeetingState::default(),
            recording_process: None,
            language: "auto".to_string(),
            event_bus,
            llm_router,
            memory_plane,
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        if !enabled {
            self.stop_recording();
        }
    }

    pub fn state(&self) -> &MeetingState {
        &self.state
    }

    /// Check if a meeting is currently happening by looking for conferencing app audio streams,
    /// window titles, and camera usage.
    pub async fn detect_meeting(&mut self) -> Result<bool> {
        if !self.enabled {
            return Ok(false);
        }

        // Strategy 1: Check PipeWire/PulseAudio for conferencing app audio streams
        let audio_meeting = detect_meeting_audio().await;

        // Strategy 2: Check sway/COSMIC compositor window titles for meeting patterns
        let window_meeting = if audio_meeting.is_none() {
            detect_meeting_by_window_title().await
        } else {
            None
        };

        // Strategy 3: Check if camera is in use by a conferencing app
        let camera_in_use = detect_camera_in_use().await;

        let detected = audio_meeting.is_some() || window_meeting.is_some() || camera_in_use;
        let app_name = audio_meeting.or(window_meeting);

        if detected && !self.state.detected {
            // Meeting just started
            let app = app_name.clone().unwrap_or_else(|| "Unknown".into());
            info!("[meeting] Meeting detected: {} — starting recording", app);
            self.state.detected = true;
            self.state.app_name = app_name;
            self.state.started_at = Some(chrono::Utc::now().to_rfc3339());
            self.start_recording().await?;
        } else if !detected && self.state.detected {
            // Meeting ended
            let duration = self.state.duration_secs;
            info!(
                "[meeting] Meeting ended ({} min) — stopping recording",
                duration / 60
            );
            self.stop_recording();
            self.state.detected = false;
            self.state.recording = false;

            // Trigger transcription + summarization pipeline
            if let Some(ref recording_path) = self.state.recording_path {
                let path = recording_path.clone();
                info!("[meeting] Processing completed meeting: {}", path);

                // 1. Transcribe with Whisper
                match self.transcribe_meeting(&path).await {
                    Ok(transcript) => {
                        info!(
                            "[meeting] Transcription complete ({} chars)",
                            transcript.len()
                        );

                        // 2. Diarize (best-effort, falls back to raw transcript)
                        let diarized = self
                            .diarize_transcript(&path, &transcript)
                            .await
                            .unwrap_or_else(|e| {
                                warn!("[meeting] Diarization error: {e}");
                                transcript.clone()
                            });

                        // 3. Summarize with LLM (if router available)
                        let summary = if let Some(ref router) = self.llm_router {
                            match self.summarize_meeting(&diarized, router).await {
                                Ok(s) => {
                                    info!("[meeting] Summary generated ({} chars)", s.len());
                                    Some(s)
                                }
                                Err(e) => {
                                    warn!("[meeting] Summarization failed: {e}");
                                    None
                                }
                            }
                        } else {
                            warn!("[meeting] No LLM router available, skipping summarization");
                            None
                        };

                        // 4. Save to memory plane
                        if let Some(ref memory) = self.memory_plane {
                            let content = if let Some(ref s) = summary {
                                format!(
                                    "## Transcripcion\n\n{}\n\n## Resumen\n\n{}",
                                    &diarized[..diarized.len().min(4000)],
                                    s
                                )
                            } else {
                                diarized.clone()
                            };
                            let app = self
                                .state
                                .app_name
                                .clone()
                                .unwrap_or_else(|| "unknown".into());
                            let tags = vec![
                                "meeting".to_string(),
                                "transcript".to_string(),
                                app.to_lowercase(),
                            ];
                            match memory
                                .read()
                                .await
                                .add_entry(
                                    "meeting",
                                    "work",
                                    &tags,
                                    Some("lifeosd://meeting-assistant"),
                                    70,
                                    &content,
                                )
                                .await
                            {
                                Ok(entry) => {
                                    info!("[meeting] Saved to memory plane: {}", entry.entry_id);
                                }
                                Err(e) => {
                                    warn!("[meeting] Failed to save to memory: {e}");
                                }
                            }
                        }

                        // 5. Compress WAV to OPUS for storage efficiency
                        let _ = Self::compress_to_opus(&path).await;

                        // 6. Notify via event bus
                        if let Some(ref tx) = self.event_bus {
                            let msg = if let Some(ref s) = summary {
                                let preview = &s[..s.len().min(200)];
                                format!(
                                    "Reunion terminada ({} min). Resumen:\n{}",
                                    duration / 60,
                                    preview
                                )
                            } else {
                                format!(
                                    "Reunion terminada ({} min). Transcripcion disponible.",
                                    duration / 60
                                )
                            };
                            let _ = tx.send(crate::events::DaemonEvent::Notification {
                                priority: "info".into(),
                                message: msg,
                            });
                        }
                    }
                    Err(e) => {
                        warn!("[meeting] Transcription failed: {e}");
                        if let Some(ref tx) = self.event_bus {
                            let _ = tx.send(crate::events::DaemonEvent::Notification {
                                priority: "warning".into(),
                                message: format!(
                                    "Reunion terminada ({} min) pero la transcripcion fallo: {e}",
                                    duration / 60
                                ),
                            });
                        }
                    }
                }
            }
        }

        if self.state.detected {
            if let Some(ref started) = self.state.started_at {
                if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(started) {
                    self.state.duration_secs =
                        chrono::Utc::now().signed_duration_since(dt).num_seconds() as u64;
                }
            }
        }

        Ok(self.state.detected)
    }

    async fn start_recording(&mut self) -> Result<()> {
        let meetings_dir = self.data_dir.join("meetings");
        tokio::fs::create_dir_all(&meetings_dir).await?;

        let filename = format!("meeting-{}.wav", chrono::Utc::now().format("%Y%m%d-%H%M%S"));
        let output_path = meetings_dir.join(&filename);

        // Record the default audio output (what you hear) — this captures both sides
        let child = Command::new("pw-record")
            .args([
                "--rate",
                "16000",
                "--channels",
                "1",
                "--format",
                "s16",
                output_path.to_str().unwrap_or("meeting.wav"),
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .context("Failed to start pw-record for meeting")?;

        self.recording_process = Some(child);
        self.state.recording = true;
        self.state.recording_path = Some(output_path.to_string_lossy().to_string());

        // Emit recording started event via the event bus
        if let Some(ref tx) = self.event_bus {
            let _ = tx.send(crate::events::DaemonEvent::MeetingRecordingStarted {
                app_name: self
                    .state
                    .app_name
                    .clone()
                    .unwrap_or_else(|| "Unknown".into()),
                recording_path: output_path.to_string_lossy().to_string(),
            });
        }

        Ok(())
    }

    fn stop_recording(&mut self) {
        if let Some(ref mut child) = self.recording_process {
            let _ = child.start_kill();
        }
        self.recording_process = None;

        // Emit recording stopped event via the event bus
        if let Some(ref tx) = self.event_bus {
            let _ = tx.send(crate::events::DaemonEvent::MeetingRecordingStopped {
                recording_path: self.state.recording_path.clone(),
                duration_secs: self.state.duration_secs,
            });
        }

        self.state.recording = false;
    }

    /// Transcribe a completed meeting recording using Whisper.
    pub async fn transcribe_meeting(&self, audio_path: &str) -> Result<String> {
        let whisper = resolve_whisper_binary().await?;
        let model = resolve_whisper_model().await?;

        let output = Command::new(&whisper)
            .args([
                "-m",
                &model,
                "-f",
                audio_path,
                "--language",
                &self.language,
                "--output-txt",
            ])
            .output()
            .await
            .context("Failed to run whisper for meeting transcription")?;

        if !output.status.success() {
            anyhow::bail!(
                "Whisper failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }

        // Whisper writes a .txt file next to the input
        let txt_path = format!("{}.txt", audio_path);
        let transcript = tokio::fs::read_to_string(&txt_path)
            .await
            .unwrap_or_else(|_| String::from_utf8_lossy(&output.stdout).to_string());

        Ok(transcript)
    }

    /// Apply speaker diarization to a transcript.
    ///
    /// Uses `lifeos-diarize.py` which analyzes audio energy patterns to detect
    /// speaker turns and labels each line with `[Speaker 1]`, `[Speaker 2]`, etc.
    pub async fn diarize_transcript(&self, audio_path: &str, transcript: &str) -> Result<String> {
        // Write transcript to temp file for the Python script
        let transcript_path = format!("{}.transcript.txt", audio_path);
        let diarized_path = format!("{}.diarized.txt", audio_path);

        tokio::fs::write(&transcript_path, transcript)
            .await
            .context("Failed to write transcript for diarization")?;

        let output = Command::new("python3")
            .args([
                "/usr/local/bin/lifeos-diarize.py",
                audio_path,
                &transcript_path,
                "--output",
                &diarized_path,
            ])
            .output()
            .await;

        // Clean up temp transcript
        let _ = tokio::fs::remove_file(&transcript_path).await;

        match output {
            Ok(o) if o.status.success() => {
                if let Ok(diarized) = tokio::fs::read_to_string(&diarized_path).await {
                    let _ = tokio::fs::remove_file(&diarized_path).await;
                    if !diarized.trim().is_empty() {
                        info!("[meeting] Diarization completed successfully");
                        return Ok(diarized);
                    }
                }
                // Fallback: return original transcript
                warn!("[meeting] Diarization produced empty output, using raw transcript");
                Ok(transcript.to_string())
            }
            Ok(o) => {
                warn!(
                    "[meeting] Diarization failed: {}",
                    String::from_utf8_lossy(&o.stderr)
                );
                Ok(transcript.to_string())
            }
            Err(e) => {
                warn!("[meeting] Diarization script not available: {e}");
                Ok(transcript.to_string())
            }
        }
    }

    /// Generate a meeting summary from a transcript using the LLM router.
    pub async fn summarize_meeting(
        &self,
        transcript: &str,
        router: &std::sync::Arc<tokio::sync::RwLock<crate::llm_router::LlmRouter>>,
    ) -> Result<String> {
        let prompt = format!(
            "Eres un asistente que resume reuniones. Genera un resumen estructurado de esta transcripcion:\n\n\
            {}\n\n\
            Formato del resumen:\n\
            ## Resumen Ejecutivo\n\
            (3-5 bullet points)\n\n\
            ## Temas Discutidos\n\
            (lista)\n\n\
            ## Decisiones Tomadas\n\
            (lista)\n\n\
            ## Action Items\n\
            (quien, que, cuando)\n\n\
            ## Preguntas Sin Resolver\n\
            (lista, si las hay)",
            &transcript[..transcript.len().min(6000)]
        );

        let request = crate::llm_router::RouterRequest {
            messages: vec![crate::llm_router::ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(prompt),
            }],
            complexity: Some(crate::llm_router::TaskComplexity::Complex),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(2048),
        };

        let router_guard = router.read().await;
        let response = router_guard
            .chat(&request)
            .await
            .context("LLM summary generation failed")?;

        Ok(response.text)
    }

    /// Set the whisper language for transcription (e.g., "es", "en", "auto").
    pub fn set_language(&mut self, lang: &str) {
        self.language = lang.to_string();
        info!("[meeting] Whisper language set to: {}", self.language);
    }

    /// Delete meeting files (wav, opus, txt) older than `days` from the meetings directory.
    pub async fn cleanup_old_meetings(&self, days: u64) -> Result<u64> {
        let meetings_dir = self.data_dir.join("meetings");
        if !meetings_dir.exists() {
            return Ok(0);
        }

        let cutoff = std::time::SystemTime::now() - std::time::Duration::from_secs(days * 86400);

        let mut removed = 0u64;
        let mut entries = tokio::fs::read_dir(&meetings_dir).await?;
        while let Some(entry) = entries.next_entry().await? {
            let metadata = entry.metadata().await?;
            if metadata.is_file() {
                if let Ok(modified) = metadata.modified() {
                    if modified < cutoff {
                        if let Err(e) = tokio::fs::remove_file(entry.path()).await {
                            info!(
                                "[meeting] Failed to remove {}: {}",
                                entry.path().display(),
                                e
                            );
                        } else {
                            removed += 1;
                        }
                    }
                }
            }
        }

        info!(
            "[meeting] Cleaned up {} old meeting files (>{} days)",
            removed, days
        );
        Ok(removed)
    }

    /// Compress a WAV recording to OPUS for storage efficiency.
    pub async fn compress_to_opus(wav_path: &str) -> Result<String> {
        let opus_path = wav_path.replace(".wav", ".opus");
        let output = Command::new("ffmpeg")
            .args(["-i", wav_path, "-c:a", "libopus", "-b:a", "48k", &opus_path])
            .output()
            .await
            .context("ffmpeg opus compression failed")?;

        if output.status.success() {
            // Remove original WAV to save space
            let _ = tokio::fs::remove_file(wav_path).await;
            Ok(opus_path)
        } else {
            // Keep WAV if compression fails
            Ok(wav_path.to_string())
        }
    }
}

/// Detect if a conferencing app has an active audio stream via PipeWire/PulseAudio.
async fn detect_meeting_audio() -> Option<String> {
    let output = Command::new("pactl")
        .args(["list", "sink-inputs"])
        .output()
        .await
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let text = String::from_utf8_lossy(&output.stdout).to_lowercase();

    for (app_name, patterns) in CONFERENCING_APPS {
        for pattern in *patterns {
            if text.contains(&pattern.to_lowercase()) {
                return Some(app_name.to_string());
            }
        }
    }

    // Also check for generic browser audio that might be a web-based meeting
    if (text.contains("firefox") || text.contains("chromium") || text.contains("chrome"))
        && detect_camera_in_use().await
    {
        // Browser + camera = likely a web meeting
        return Some("Web Meeting".into());
    }

    None
}

/// Detect an active meeting by scanning compositor window titles via swaymsg.
///
/// Runs `swaymsg -t get_tree` (works on sway / COSMIC compositor) and walks the
/// JSON tree looking for window titles that match known conferencing patterns.
/// Returns the app name if a meeting window is found.
pub async fn detect_meeting_by_window_title() -> Option<String> {
    let output = Command::new("swaymsg")
        .args(["-t", "get_tree"])
        .output()
        .await
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let tree: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;

    // Collect all window titles from the tree
    let mut titles: Vec<String> = Vec::new();
    collect_window_titles(&tree, &mut titles);

    // Match titles against meeting patterns
    for title in &titles {
        let title_lower = title.to_lowercase();

        for (app_name, patterns) in MEETING_WINDOW_PATTERNS {
            let has_pattern = patterns
                .iter()
                .any(|p| title_lower.contains(&p.to_lowercase()));

            if !has_pattern {
                continue;
            }

            // Some apps need a qualifier keyword (e.g. Discord needs "Voice" or "Stage")
            if let Some((_, qualifiers)) = MEETING_QUALIFIER_PATTERNS
                .iter()
                .find(|(name, _)| *name == *app_name)
            {
                if qualifiers
                    .iter()
                    .any(|q| title_lower.contains(&q.to_lowercase()))
                {
                    return Some(app_name.to_string());
                }
                // Pattern matched but qualifier did not — skip this app
                continue;
            }

            return Some(app_name.to_string());
        }
    }

    None
}

/// Recursively collect window titles from a swaymsg JSON tree.
fn collect_window_titles(node: &serde_json::Value, titles: &mut Vec<String>) {
    // Leaf nodes with a "name" field are windows
    if let Some(name) = node.get("name").and_then(|v| v.as_str()) {
        // Only collect from actual windows (nodes with a pid or app_id)
        let is_window = node.get("pid").is_some()
            || node.get("app_id").is_some()
            || node
                .get("window_properties")
                .and_then(|wp| wp.get("class"))
                .is_some();
        if is_window {
            titles.push(name.to_string());
        }
    }

    // Recurse into child containers
    if let Some(nodes) = node.get("nodes").and_then(|v| v.as_array()) {
        for child in nodes {
            collect_window_titles(child, titles);
        }
    }
    if let Some(nodes) = node.get("floating_nodes").and_then(|v| v.as_array()) {
        for child in nodes {
            collect_window_titles(child, titles);
        }
    }
}

/// Check if /dev/video0 is in use by any process.
async fn detect_camera_in_use() -> bool {
    let output = Command::new("fuser").arg("/dev/video0").output().await.ok();

    match output {
        Some(o) => o.status.success() && !o.stdout.is_empty(),
        None => false,
    }
}

async fn resolve_whisper_binary() -> Result<String> {
    for bin in &["whisper-cli", "whisper-cpp", "whisper"] {
        if let Ok(output) = Command::new("which").arg(bin).output().await {
            if output.status.success() {
                return Ok(String::from_utf8_lossy(&output.stdout).trim().to_string());
            }
        }
    }
    anyhow::bail!("No whisper binary found")
}

async fn resolve_whisper_model() -> Result<String> {
    let candidates = [
        "/var/lib/lifeos/models/whisper/ggml-base.bin",
        "/var/lib/lifeos/models/whisper/ggml-small.bin",
        "/usr/share/lifeos/models/whisper/ggml-base.bin",
    ];
    for path in &candidates {
        if tokio::fs::metadata(path).await.is_ok() {
            return Ok(path.to_string());
        }
    }
    anyhow::bail!("No whisper model found")
}
