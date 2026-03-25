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
use log::info;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::process::Command;

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

pub struct MeetingAssistant {
    data_dir: PathBuf,
    enabled: bool,
    state: MeetingState,
    recording_process: Option<tokio::process::Child>,
    language: String,
}

impl MeetingAssistant {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            enabled: std::env::var("LIFEOS_MEETING_ASSISTANT")
                .map(|v| v != "0" && !v.eq_ignore_ascii_case("false"))
                .unwrap_or(true),
            state: MeetingState::default(),
            recording_process: None,
            language: "auto".to_string(),
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

    /// Check if a meeting is currently happening by looking for conferencing app audio streams.
    pub async fn detect_meeting(&mut self) -> Result<bool> {
        if !self.enabled {
            return Ok(false);
        }

        // Strategy 1: Check PipeWire/PulseAudio for conferencing app audio streams
        let audio_meeting = detect_meeting_audio().await;

        // Strategy 2: Check if camera is in use by a conferencing app
        let camera_in_use = detect_camera_in_use().await;

        let detected = audio_meeting.is_some() || camera_in_use;
        let app_name = audio_meeting;

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
            info!("[meeting] Meeting ended — stopping recording");
            self.stop_recording();
            self.state.detected = false;
            self.state.recording = false;
            // TODO: trigger transcription + summarization
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
        Ok(())
    }

    fn stop_recording(&mut self) {
        if let Some(ref mut child) = self.recording_process {
            let _ = child.start_kill();
        }
        self.recording_process = None;
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
