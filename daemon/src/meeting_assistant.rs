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
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::process::Command;
use tokio::sync::{broadcast, RwLock};

/// When true, raw audio files (WAV + OPUS) are deleted after successful transcription
/// and summarization. Override by setting `LIFEOS_KEEP_MEETING_AUDIO=1`.
const AUTO_DELETE_RAW_AUDIO: bool = true;

/// Interval between periodic meeting screenshots (in seconds).
const SCREENSHOT_INTERVAL_SECS: u64 = 30;

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

/// A single real-time caption entry produced during a meeting (BB.8).
#[derive(Debug, Clone, Serialize)]
pub struct CaptionEntry {
    pub timestamp: String,
    pub text: String,
    pub speaker: Option<String>,
    pub is_final: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MeetingState {
    pub detected: bool,
    pub app_name: Option<String>,
    pub recording: bool,
    pub recording_path: Option<String>,
    pub started_at: Option<String>,
    pub duration_secs: u64,
    /// Paths to periodic screenshots captured during the meeting.
    pub screenshot_paths: Vec<String>,
    /// Whether this meeting was started manually (in-person / manual trigger).
    pub manual_meeting: bool,
    /// Path to mic-only recording when dual-channel capture is active.
    pub mic_recording_path: Option<String>,
    /// Path to system-audio-only recording when dual-channel capture is active.
    pub system_recording_path: Option<String>,
}

/// Data bundle for meeting file export (BB.12), avoids too-many-arguments.
struct MeetingExportData<'a> {
    title: &'a str,
    started_at: &'a str,
    ended_at: &'a str,
    duration_secs: u64,
    app_name: &'a str,
    participants: &'a [String],
    summary: Option<&'a str>,
    diarized_transcript: &'a str,
    action_items: &'a [crate::meeting_archive::ActionItem],
    screenshot_paths: &'a [String],
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
    /// Mic recording process for dual-channel capture (BB.3).
    mic_process: Option<tokio::process::Child>,
    /// System audio recording process for dual-channel capture (BB.3).
    system_process: Option<tokio::process::Child>,
    language: String,
    event_bus: Option<broadcast::Sender<crate::events::DaemonEvent>>,
    llm_router: Option<Arc<RwLock<crate::llm_router::LlmRouter>>>,
    memory_plane: Option<Arc<RwLock<crate::memory_plane::MemoryPlaneManager>>>,
    /// Tracks when the last periodic screenshot was taken.
    last_screenshot: Option<std::time::Instant>,
    /// Speaker identification manager for resolving diarized speaker labels to names (BB.1).
    pub speaker_id: Option<Arc<RwLock<crate::speaker_id::SpeakerIdManager>>>,
    /// Meeting archive for structured SQLite storage of meeting records.
    pub archive: Option<Arc<crate::meeting_archive::MeetingArchive>>,
    /// Whether real-time captions are enabled (BB.8). Opt-in via `LIFEOS_MEETING_CAPTIONS=1`.
    captions_enabled: bool,
    /// Buffer of real-time caption entries produced during a meeting (BB.8).
    caption_buffer: Arc<RwLock<Vec<CaptionEntry>>>,
    /// Sender to signal the caption background task to stop (BB.8).
    caption_stop_tx: Option<tokio::sync::watch::Sender<bool>>,
}

impl MeetingAssistant {
    pub fn new(
        data_dir: PathBuf,
        event_bus: Option<broadcast::Sender<crate::events::DaemonEvent>>,
        llm_router: Option<Arc<RwLock<crate::llm_router::LlmRouter>>>,
        memory_plane: Option<Arc<RwLock<crate::memory_plane::MemoryPlaneManager>>>,
    ) -> Self {
        Self {
            data_dir,
            enabled: std::env::var("LIFEOS_MEETING_ASSISTANT")
                .map(|v| v != "0" && !v.eq_ignore_ascii_case("false"))
                .unwrap_or(true),
            state: MeetingState::default(),
            recording_process: None,
            mic_process: None,
            system_process: None,
            language: "auto".to_string(),
            event_bus,
            llm_router,
            memory_plane,
            last_screenshot: None,
            speaker_id: None,
            archive: None,
            captions_enabled: std::env::var("LIFEOS_MEETING_CAPTIONS")
                .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                .unwrap_or(false),
            caption_buffer: Arc::new(RwLock::new(Vec::new())),
            caption_stop_tx: None,
        }
    }

    /// Set the speaker identification manager for resolving speaker labels to names (BB.1).
    pub fn set_speaker_id(&mut self, sid: Arc<RwLock<crate::speaker_id::SpeakerIdManager>>) {
        self.speaker_id = Some(sid);
        info!("[meeting] Speaker identification enabled");
    }

    /// Set the meeting archive for structured SQLite storage of completed meetings.
    pub fn set_archive(&mut self, archive: Arc<crate::meeting_archive::MeetingArchive>) {
        self.archive = Some(archive);
        info!("[meeting] Meeting archive enabled");
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

        let detected = audio_meeting.is_some()
            || window_meeting.is_some()
            || camera_in_use
            || self.state.manual_meeting;
        let app_name = audio_meeting.or(window_meeting);

        if detected && !self.state.detected {
            // Meeting just started
            let app = app_name.clone().unwrap_or_else(|| "Unknown".into());
            info!("[meeting] Meeting detected: {} — starting recording", app);
            self.state.detected = true;
            self.state.app_name = app_name;
            self.state.started_at = Some(chrono::Utc::now().to_rfc3339());
            self.state.screenshot_paths.clear();
            self.last_screenshot = None;
            self.start_recording().await?;
            // Start real-time captions if enabled (BB.8)
            self.start_captions().await;
        } else if !detected && self.state.detected {
            // Meeting ended — stop captions (BB.8)
            self.stop_captions().await;
            let duration = self.state.duration_secs;
            let screenshot_count = self.state.screenshot_paths.len();
            info!(
                "[meeting] Meeting ended ({} min, {} screenshots) — stopping recording",
                duration / 60,
                screenshot_count
            );
            self.stop_recording();
            self.state.detected = false;
            self.state.recording = false;
            self.state.manual_meeting = false;

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

                        // 2b. Identify speakers in diarized transcript (BB.1)
                        let diarized = self.identify_speakers_in_transcript(&diarized, &path).await;

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

                        // 4b. Save to meeting archive (structured SQLite)
                        if let Some(ref archive) = self.archive {
                            let record = crate::meeting_archive::MeetingRecord {
                                id: uuid::Uuid::new_v4().to_string(),
                                started_at: self.state.started_at.clone().unwrap_or_default(),
                                ended_at: Some(chrono::Utc::now().to_rfc3339()),
                                duration_secs: duration,
                                app_name: self
                                    .state
                                    .app_name
                                    .clone()
                                    .unwrap_or_else(|| "unknown".into()),
                                meeting_type: "remote".to_string(),
                                participants: Vec::new(),
                                transcript: transcript.clone(),
                                diarized_transcript: diarized.clone(),
                                summary: summary.clone().unwrap_or_default(),
                                action_items: extract_action_items(
                                    summary.as_deref().unwrap_or(""),
                                ),
                                screenshot_count: self.state.screenshot_paths.len(),
                                screenshot_paths: self.state.screenshot_paths.clone(),
                                audio_path: Some(path.clone()),
                                audio_deleted: false,
                                tags: vec!["auto-detected".to_string()],
                                language: self.language.clone(),
                            };
                            match archive.save_meeting(&record).await {
                                Ok(()) => {
                                    info!("[meeting] Saved to meeting archive: {}", record.id)
                                }
                                Err(e) => warn!("[meeting] Failed to save to archive: {e}"),
                            }
                        }

                        // 4c. Export meeting files to structured folder (BB.12)
                        let action_items_vec =
                            extract_action_items(summary.as_deref().unwrap_or(""));
                        {
                            let meeting_title = self
                                .state
                                .app_name
                                .clone()
                                .unwrap_or_else(|| "reunion".into());
                            let started = self.state.started_at.clone().unwrap_or_default();
                            let ended = chrono::Utc::now().to_rfc3339();
                            let export_data = MeetingExportData {
                                title: &meeting_title,
                                started_at: &started,
                                ended_at: &ended,
                                duration_secs: duration,
                                app_name: &meeting_title,
                                participants: &[],
                                summary: summary.as_deref(),
                                diarized_transcript: &diarized,
                                action_items: &action_items_vec,
                                screenshot_paths: &self.state.screenshot_paths,
                            };
                            self.export_meeting_files(&export_data).await;
                        }

                        // 5. Compress WAV to OPUS for storage efficiency
                        let opus_result = Self::compress_to_opus(&path).await;

                        // 6. Auto-delete raw audio if summarization succeeded (BB.6)
                        let summarization_ok = summary.is_some();
                        if summarization_ok {
                            self.auto_delete_raw_audio(&path, &opus_result).await;
                        } else {
                            info!("[meeting] Keeping raw audio — summarization did not succeed");
                        }

                        // 7. Send structured post-meeting notification (BB.9)
                        self.send_post_meeting_notification(
                            duration,
                            screenshot_count,
                            summary.as_deref(),
                            &action_items_vec,
                            0, // participant count not yet resolved
                        );
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

            // Periodic screenshot capture (BB.2)
            let should_screenshot = match self.last_screenshot {
                Some(last) => last.elapsed().as_secs() >= SCREENSHOT_INTERVAL_SECS,
                None => true, // First screenshot immediately when meeting starts
            };
            if should_screenshot {
                if let Err(e) = self.capture_meeting_screenshot().await {
                    warn!("[meeting] Screenshot capture failed: {e}");
                }
            }
        }

        Ok(self.state.detected)
    }

    async fn start_recording(&mut self) -> Result<()> {
        let meetings_dir = self.data_dir.join("meetings");
        tokio::fs::create_dir_all(&meetings_dir).await?;

        let timestamp = chrono::Utc::now().format("%Y%m%d-%H%M%S").to_string();
        let filename = format!("meeting-{}.wav", timestamp);
        let output_path = meetings_dir.join(&filename);

        // Try dual-channel capture first (BB.3)
        let dual_ok = self
            .try_start_dual_recording(&meetings_dir, &timestamp)
            .await;

        if !dual_ok {
            // Fall back to single pw-record (original behavior)
            info!("[meeting] Using single-channel recording (fallback)");
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
        }

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

    /// Attempt to start dual-channel recording (mic + system audio separately).
    /// Returns true if both channels were started successfully.
    async fn try_start_dual_recording(&mut self, meetings_dir: &Path, timestamp: &str) -> bool {
        let monitor_source = find_monitor_source().await;
        let mic_source = find_mic_source().await;

        let (monitor, mic) = match (monitor_source, mic_source) {
            (Some(m), Some(k)) => (m, k),
            _ => {
                info!("[meeting] Could not find both monitor and mic sources for dual-channel");
                return false;
            }
        };

        info!(
            "[meeting] Starting dual-channel recording: mic={}, system={}",
            mic, monitor
        );

        let mic_path = meetings_dir.join(format!("meeting-{}-mic.wav", timestamp));
        let system_path = meetings_dir.join(format!("meeting-{}-system.wav", timestamp));

        // Start mic recording
        let mic_child = Command::new("pw-record")
            .args([
                "--rate",
                "16000",
                "--channels",
                "1",
                "--format",
                "s16",
                &format!("--target={}", mic),
                mic_path.to_str().unwrap_or("mic.wav"),
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();

        let mic_child = match mic_child {
            Ok(c) => c,
            Err(e) => {
                warn!("[meeting] Failed to start mic recording: {e}");
                return false;
            }
        };

        // Start system audio recording
        let system_child = Command::new("pw-record")
            .args([
                "--rate",
                "16000",
                "--channels",
                "1",
                "--format",
                "s16",
                &format!("--target={}", monitor),
                system_path.to_str().unwrap_or("system.wav"),
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();

        let system_child = match system_child {
            Ok(c) => c,
            Err(e) => {
                warn!("[meeting] Failed to start system recording: {e}");
                // Kill the mic process we already started
                let mut mc = mic_child;
                let _ = mc.start_kill();
                return false;
            }
        };

        self.mic_process = Some(mic_child);
        self.system_process = Some(system_child);
        self.state.mic_recording_path = Some(mic_path.to_string_lossy().to_string());
        self.state.system_recording_path = Some(system_path.to_string_lossy().to_string());

        info!("[meeting] Dual-channel recording started successfully");
        true
    }

    fn stop_recording(&mut self) {
        // Kill the single-channel process (if any)
        if let Some(ref mut child) = self.recording_process {
            let _ = child.start_kill();
        }
        self.recording_process = None;

        // Kill dual-channel processes (if any) and merge (BB.3)
        let has_dual = self.mic_process.is_some() && self.system_process.is_some();
        if let Some(ref mut child) = self.mic_process {
            let _ = child.start_kill();
        }
        self.mic_process = None;
        if let Some(ref mut child) = self.system_process {
            let _ = child.start_kill();
        }
        self.system_process = None;

        // If dual-channel was active, merge files in a background task
        if has_dual {
            let mic_path = self.state.mic_recording_path.clone();
            let system_path = self.state.system_recording_path.clone();
            let combined_path = self.state.recording_path.clone();

            tokio::spawn(async move {
                if let (Some(mic), Some(sys), Some(combined)) =
                    (mic_path, system_path, combined_path)
                {
                    if let Err(e) = merge_dual_channels(&mic, &sys, &combined).await {
                        warn!("[meeting] Dual-channel merge failed, trying mic-only fallback: {e}");
                        // Fallback: copy mic recording as the combined file
                        if let Err(e2) = tokio::fs::copy(&mic, &combined).await {
                            warn!("[meeting] Mic fallback copy also failed: {e2}");
                        }
                    } else {
                        info!("[meeting] Dual-channel audio merged successfully");
                    }
                }
            });
        }

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

    /// Identify speakers in a diarized transcript by matching voice embeddings (BB.1).
    ///
    /// Parses unique speaker labels like "[Speaker 1]", extracts a 5-second audio sample
    /// for each speaker, runs speaker identification, and replaces generic labels with
    /// recognized names. Returns the original transcript if speaker_id is None or
    /// identification fails.
    async fn identify_speakers_in_transcript(&self, diarized: &str, audio_path: &str) -> String {
        let speaker_id = match &self.speaker_id {
            Some(sid) => sid,
            None => return diarized.to_string(),
        };

        // Collect unique speaker labels and their first occurrence line index
        let mut speaker_lines: HashMap<String, usize> = HashMap::new();
        for (idx, line) in diarized.lines().enumerate() {
            if let Some(start) = line.find("[Speaker ") {
                if let Some(end) = line[start..].find(']') {
                    let label = &line[start + 1..start + end];
                    speaker_lines.entry(label.to_string()).or_insert(idx);
                }
            }
        }

        if speaker_lines.is_empty() {
            return diarized.to_string();
        }

        let total_lines = diarized.lines().count().max(1);
        let meetings_dir = self.data_dir.join("meetings");

        // Build mapping: "Speaker 1" -> identified name
        let mut name_map: HashMap<String, String> = HashMap::new();

        for (label, first_line_idx) in &speaker_lines {
            // Estimate time position based on line position in transcript.
            // This is approximate — we assume lines are roughly evenly distributed
            // across the audio duration.
            let duration_secs = self.state.duration_secs.max(60);
            let start_time = (*first_line_idx as f64 / total_lines as f64) * duration_secs as f64;
            let start_secs = start_time.max(0.0) as u64;

            let sample_path =
                meetings_dir.join(format!("speaker_sample_{}.wav", label.replace(' ', "_")));
            let sample_str = sample_path.to_string_lossy().to_string();

            // Extract 5-second sample using ffmpeg
            let extract_result = Command::new("ffmpeg")
                .args([
                    "-i",
                    audio_path,
                    "-ss",
                    &start_secs.to_string(),
                    "-t",
                    "5",
                    "-y",
                    &sample_str,
                ])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .output()
                .await;

            if let Err(e) = &extract_result {
                warn!(
                    "[meeting] Failed to extract speaker sample for {}: {e}",
                    label
                );
                continue;
            }
            let extract_output = extract_result.unwrap();
            if !extract_output.status.success() {
                warn!("[meeting] ffmpeg failed extracting sample for {}", label);
                let _ = tokio::fs::remove_file(&sample_path).await;
                continue;
            }

            // Extract embedding and identify speaker
            match crate::speaker_id::extract_embedding(&sample_path).await {
                Ok(embedding) => {
                    let mut sid_guard = speaker_id.write().await;
                    let speaker_match = sid_guard.identify(&embedding);
                    let resolved_name = speaker_match
                        .name
                        .unwrap_or_else(|| format!("Unknown {}", label));
                    info!(
                        "[meeting] {} identified as '{}' (confidence: {:.3})",
                        label, resolved_name, speaker_match.confidence
                    );
                    name_map.insert(label.clone(), resolved_name);
                }
                Err(e) => {
                    warn!("[meeting] Embedding extraction failed for {}: {e}", label);
                }
            }

            // Clean up sample file
            let _ = tokio::fs::remove_file(&sample_path).await;
        }

        if name_map.is_empty() {
            return diarized.to_string();
        }

        // Replace all speaker labels in the transcript
        let mut result = diarized.to_string();
        for (label, name) in &name_map {
            let old = format!("[{}]", label);
            let new = format!("[{}]", name);
            result = result.replace(&old, &new);
        }

        info!(
            "[meeting] Speaker identification complete: {} speakers resolved",
            name_map.len()
        );
        result
    }

    /// Generate a meeting summary from a transcript using the LLM router.
    pub async fn summarize_meeting(
        &self,
        transcript: &str,
        router: &Arc<RwLock<crate::llm_router::LlmRouter>>,
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

    // ------------------------------------------------------------------
    // BB.2 — Periodic screenshot capture during meetings
    // ------------------------------------------------------------------

    /// Capture a screenshot of the current screen using `grim` and save it to
    /// the meetings directory alongside the audio recording.
    async fn capture_meeting_screenshot(&mut self) -> Result<()> {
        let meetings_dir = self.data_dir.join("meetings");
        tokio::fs::create_dir_all(&meetings_dir).await?;

        let n = self.state.screenshot_paths.len() + 1;
        let filename = format!(
            "meeting-{}-screenshot-{}.png",
            chrono::Utc::now().format("%Y%m%d-%H%M%S"),
            n
        );
        let output_path = meetings_dir.join(&filename);
        let output_str = output_path.to_string_lossy().to_string();

        let output = Command::new("grim")
            .arg(&output_str)
            .output()
            .await
            .context("Failed to run grim for meeting screenshot")?;

        if !output.status.success() {
            anyhow::bail!("grim failed: {}", String::from_utf8_lossy(&output.stderr));
        }

        self.state.screenshot_paths.push(output_str.clone());
        self.last_screenshot = Some(std::time::Instant::now());
        info!("[meeting] Screenshot #{} captured: {}", n, filename);

        Ok(())
    }

    // ------------------------------------------------------------------
    // BB.6 — Privacy auto-delete raw audio after processing
    // ------------------------------------------------------------------

    /// Delete raw audio files (WAV + OPUS) after successful summarization.
    /// Keeps transcript .txt files and screenshots.
    async fn auto_delete_raw_audio(&self, wav_path: &str, opus_result: &Result<String>) {
        if !AUTO_DELETE_RAW_AUDIO {
            return;
        }

        // Allow override via environment variable
        if std::env::var("LIFEOS_KEEP_MEETING_AUDIO")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false)
        {
            info!("[meeting] LIFEOS_KEEP_MEETING_AUDIO set — keeping raw audio files");
            return;
        }

        // Delete the WAV file
        match tokio::fs::remove_file(wav_path).await {
            Ok(()) => info!("[meeting] Deleted raw WAV: {}", wav_path),
            Err(e) => {
                // WAV may already have been removed by compress_to_opus
                if e.kind() != std::io::ErrorKind::NotFound {
                    warn!("[meeting] Failed to delete WAV {}: {}", wav_path, e);
                }
            }
        }

        // Delete the OPUS file if compression succeeded
        if let Ok(ref opus_path) = opus_result {
            if opus_path != wav_path {
                match tokio::fs::remove_file(opus_path).await {
                    Ok(()) => info!("[meeting] Deleted compressed OPUS: {}", opus_path),
                    Err(e) => {
                        if e.kind() != std::io::ErrorKind::NotFound {
                            warn!("[meeting] Failed to delete OPUS {}: {}", opus_path, e);
                        }
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // BB.7 — Manual meeting start/stop (in-person meetings)
    // ------------------------------------------------------------------

    /// Start a manually-triggered meeting (e.g., in-person meeting without PipeWire signals).
    /// Sets `manual_meeting = true` and begins recording immediately.
    pub async fn start_manual_meeting(&mut self, description: &str) -> Result<()> {
        if self.state.detected {
            anyhow::bail!("A meeting is already in progress");
        }

        info!("[meeting] Manual meeting started: {}", description);

        self.state.detected = true;
        self.state.manual_meeting = true;
        self.state.app_name = Some(description.to_string());
        self.state.started_at = Some(chrono::Utc::now().to_rfc3339());
        self.state.screenshot_paths.clear();
        self.last_screenshot = None;

        self.start_recording().await?;
        // Start real-time captions if enabled (BB.8)
        self.start_captions().await;

        Ok(())
    }

    /// Stop a manually-triggered meeting and run the full post-meeting pipeline
    /// (transcription, diarization, summarization).
    pub async fn stop_manual_meeting(&mut self) -> Result<()> {
        if !self.state.manual_meeting {
            anyhow::bail!("No manual meeting is currently active");
        }

        let duration = self.state.duration_secs;
        let screenshot_count = self.state.screenshot_paths.len();
        info!(
            "[meeting] Manual meeting stopped ({} min, {} screenshots)",
            duration / 60,
            screenshot_count
        );

        // Stop captions (BB.8)
        self.stop_captions().await;
        self.stop_recording();
        self.state.detected = false;
        self.state.recording = false;
        self.state.manual_meeting = false;

        // Run the full post-meeting pipeline
        if let Some(ref recording_path) = self.state.recording_path.clone() {
            info!("[meeting] Processing manual meeting: {}", recording_path);

            match self.transcribe_meeting(recording_path).await {
                Ok(transcript) => {
                    info!(
                        "[meeting] Transcription complete ({} chars)",
                        transcript.len()
                    );

                    let diarized = self
                        .diarize_transcript(recording_path, &transcript)
                        .await
                        .unwrap_or_else(|e| {
                            warn!("[meeting] Diarization error: {e}");
                            transcript.clone()
                        });

                    // Identify speakers in diarized transcript (BB.1)
                    let diarized = self
                        .identify_speakers_in_transcript(&diarized, recording_path)
                        .await;

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

                    // Save to memory plane
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
                            .unwrap_or_else(|| "manual".into());
                        let tags = vec![
                            "meeting".to_string(),
                            "transcript".to_string(),
                            "manual".to_string(),
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

                    // Save to meeting archive (structured SQLite)
                    if let Some(ref archive) = self.archive {
                        let record = crate::meeting_archive::MeetingRecord {
                            id: uuid::Uuid::new_v4().to_string(),
                            started_at: self.state.started_at.clone().unwrap_or_default(),
                            ended_at: Some(chrono::Utc::now().to_rfc3339()),
                            duration_secs: duration,
                            app_name: self
                                .state
                                .app_name
                                .clone()
                                .unwrap_or_else(|| "manual".into()),
                            meeting_type: "manual".to_string(),
                            participants: Vec::new(),
                            transcript: transcript.clone(),
                            diarized_transcript: diarized.clone(),
                            summary: summary.clone().unwrap_or_default(),
                            action_items: extract_action_items(summary.as_deref().unwrap_or("")),
                            screenshot_count: self.state.screenshot_paths.len(),
                            screenshot_paths: self.state.screenshot_paths.clone(),
                            audio_path: Some(recording_path.clone()),
                            audio_deleted: false,
                            tags: vec!["manual".to_string()],
                            language: self.language.clone(),
                        };
                        match archive.save_meeting(&record).await {
                            Ok(()) => {
                                info!("[meeting] Saved to meeting archive: {}", record.id)
                            }
                            Err(e) => warn!("[meeting] Failed to save to archive: {e}"),
                        }
                    }

                    // Export meeting files to structured folder (BB.12)
                    let action_items_vec = extract_action_items(summary.as_deref().unwrap_or(""));
                    {
                        let meeting_title = self
                            .state
                            .app_name
                            .clone()
                            .unwrap_or_else(|| "reunion-manual".into());
                        let started = self.state.started_at.clone().unwrap_or_default();
                        let ended = chrono::Utc::now().to_rfc3339();
                        let export_data = MeetingExportData {
                            title: &meeting_title,
                            started_at: &started,
                            ended_at: &ended,
                            duration_secs: duration,
                            app_name: &meeting_title,
                            participants: &[],
                            summary: summary.as_deref(),
                            diarized_transcript: &diarized,
                            action_items: &action_items_vec,
                            screenshot_paths: &self.state.screenshot_paths,
                        };
                        self.export_meeting_files(&export_data).await;
                    }

                    let opus_result = Self::compress_to_opus(recording_path).await;

                    // Auto-delete if summarization succeeded
                    if summary.is_some() {
                        self.auto_delete_raw_audio(recording_path, &opus_result)
                            .await;
                    }

                    // Send structured post-meeting notification (BB.9)
                    self.send_post_meeting_notification(
                        duration,
                        screenshot_count,
                        summary.as_deref(),
                        &action_items_vec,
                        0,
                    );
                }
                Err(e) => {
                    warn!("[meeting] Transcription failed: {e}");
                    if let Some(ref tx) = self.event_bus {
                        let _ = tx.send(crate::events::DaemonEvent::Notification {
                            priority: "warning".into(),
                            message: format!(
                                "Reunion manual terminada ({} min) pero la transcripcion fallo: {e}",
                                duration / 60
                            ),
                        });
                    }
                }
            }
        }

        Ok(())
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

    // ------------------------------------------------------------------
    // BB.8 — Real-time captions framework
    // ------------------------------------------------------------------

    /// Start real-time captions by spawning a background task that captures
    /// audio in 3-second chunks and transcribes each chunk with whisper-cli
    /// using the tiny model for speed. Results are pushed to `caption_buffer`.
    pub async fn start_captions(&mut self) {
        if !self.captions_enabled {
            return;
        }

        // Stop any existing caption task first
        self.stop_captions().await;

        info!("[meeting] Starting real-time captions");

        let (tx, mut rx) = tokio::sync::watch::channel(false);
        self.caption_stop_tx = Some(tx);

        let buffer = Arc::clone(&self.caption_buffer);
        let data_dir = self.data_dir.clone();
        let language = self.language.clone();

        tokio::spawn(async move {
            let captions_dir = data_dir.join("meetings").join("captions_tmp");
            if let Err(e) = tokio::fs::create_dir_all(&captions_dir).await {
                warn!("[meeting] Failed to create captions dir: {e}");
                return;
            }

            // Resolve whisper binary and model (prefer tiny for speed)
            let whisper = match resolve_whisper_binary().await {
                Ok(bin) => bin,
                Err(e) => {
                    warn!("[meeting] Captions: whisper binary not found: {e}");
                    return;
                }
            };
            let model = match resolve_caption_model().await {
                Ok(m) => m,
                Err(e) => {
                    warn!("[meeting] Captions: no suitable whisper model found: {e}");
                    return;
                }
            };

            let mut chunk_idx: u64 = 0;
            loop {
                // Check stop signal
                if *rx.borrow() {
                    break;
                }

                let chunk_path = captions_dir.join(format!("chunk_{}.wav", chunk_idx));
                let chunk_str = chunk_path.to_string_lossy().to_string();

                // Record a 3-second audio chunk
                let record_result = Command::new("pw-record")
                    .args([
                        "--rate",
                        "16000",
                        "--channels",
                        "1",
                        "--format",
                        "s16",
                        &chunk_str,
                    ])
                    .spawn();

                let mut record_child = match record_result {
                    Ok(child) => child,
                    Err(e) => {
                        warn!("[meeting] Captions: failed to start pw-record: {e}");
                        break;
                    }
                };

                // Wait 3 seconds then kill the recording
                tokio::select! {
                    _ = tokio::time::sleep(std::time::Duration::from_secs(3)) => {
                        let _ = record_child.start_kill();
                        let _ = record_child.wait().await;
                    }
                    _ = rx.changed() => {
                        let _ = record_child.start_kill();
                        let _ = record_child.wait().await;
                        break;
                    }
                }

                // Transcribe the chunk
                let lang = if language == "auto" { "en" } else { &language };
                let output = Command::new(&whisper)
                    .args([
                        "-m",
                        &model,
                        "-f",
                        &chunk_str,
                        "--language",
                        lang,
                        "--no-timestamps",
                    ])
                    .output()
                    .await;

                // Read whisper's txt output before cleanup
                let txt_path = format!("{}.txt", &chunk_str);
                let txt_content = tokio::fs::read_to_string(&txt_path).await.ok();

                // Clean up chunk file and whisper's output txt
                let _ = tokio::fs::remove_file(&chunk_path).await;
                let _ = tokio::fs::remove_file(&txt_path).await;

                match output {
                    Ok(o) if o.status.success() => {
                        let text = txt_content
                            .unwrap_or_else(|| String::from_utf8_lossy(&o.stdout).to_string());
                        let text = text.trim().to_string();
                        if !text.is_empty() && text != "[BLANK_AUDIO]" {
                            let entry = CaptionEntry {
                                timestamp: chrono::Utc::now().to_rfc3339(),
                                text,
                                speaker: None,
                                is_final: true,
                            };
                            let mut buf = buffer.write().await;
                            buf.push(entry);
                        }
                    }
                    Ok(o) => {
                        warn!(
                            "[meeting] Captions: whisper failed for chunk {}: {}",
                            chunk_idx,
                            String::from_utf8_lossy(&o.stderr)
                        );
                    }
                    Err(e) => {
                        warn!("[meeting] Captions: failed to run whisper: {e}");
                    }
                }

                chunk_idx += 1;
            }

            // Clean up temp dir (ignore error if not empty)
            let _ = tokio::fs::remove_dir(&captions_dir).await;
            info!("[meeting] Captions task stopped after {} chunks", chunk_idx);
        });
    }

    /// Stop the real-time captions background task.
    pub async fn stop_captions(&mut self) {
        if let Some(tx) = self.caption_stop_tx.take() {
            let _ = tx.send(true);
            info!("[meeting] Stopping real-time captions");
        }
    }

    /// Return the last N caption entries from the buffer.
    pub fn get_recent_captions(&self, limit: usize) -> Vec<CaptionEntry> {
        // Use try_read to avoid blocking; return empty if lock is held
        match self.caption_buffer.try_read() {
            Ok(buf) => {
                let start = buf.len().saturating_sub(limit);
                buf[start..].to_vec()
            }
            Err(_) => Vec::new(),
        }
    }

    // ------------------------------------------------------------------
    // BB.9 — Structured post-meeting Telegram notification
    // ------------------------------------------------------------------

    /// Build and send a structured Telegram notification after meeting processing.
    fn send_post_meeting_notification(
        &self,
        duration_secs: u64,
        screenshot_count: usize,
        summary: Option<&str>,
        action_items: &[crate::meeting_archive::ActionItem],
        participant_count: usize,
    ) {
        let Some(ref tx) = self.event_bus else {
            return;
        };

        let app_name = self
            .state
            .app_name
            .clone()
            .unwrap_or_else(|| "Desconocida".into());

        let hours = duration_secs / 3600;
        let minutes = (duration_secs % 3600) / 60;

        let summary_block = match summary {
            Some(s) if !s.is_empty() => {
                let preview = if s.len() > 500 { &s[..500] } else { s };
                format!("\nResumen:\n{}\n", preview)
            }
            _ => "\nResumen: No disponible\n".to_string(),
        };

        let action_count = action_items.len();
        let action_list = if action_items.is_empty() {
            String::new()
        } else {
            let items: Vec<String> = action_items
                .iter()
                .take(5)
                .map(|item| {
                    let when_str = item
                        .when
                        .as_deref()
                        .map(|w| format!(" ({})", w))
                        .unwrap_or_default();
                    format!("- {}: {}{}", item.who, item.what, when_str)
                })
                .collect();
            format!("\n{}", items.join("\n"))
        };

        let msg = format!(
            "Reunion finalizada: {app_name}\n\n\
             Duracion: {hours}h {minutes}m\n\
             Participantes: {participant_count} detectados\n\
             Screenshots: {screenshot_count} capturados\n\
             {summary_block}\n\
             Action items: {action_count}{action_list}\n\n\
             La reunion completa esta disponible en el dashboard."
        );

        let _ = tx.send(crate::events::DaemonEvent::Notification {
            priority: "info".into(),
            message: msg,
        });
    }

    // ------------------------------------------------------------------
    // BB.12 — Exportable markdown file per meeting
    // ------------------------------------------------------------------

    /// Export meeting files to a structured folder for each meeting.
    ///
    /// Creates:
    ///   /var/lib/lifeos/meetings/YYYY-MM-DD-{title_slug}/
    ///     reunion.md          — Full markdown with summary + transcript
    ///     action-items.json   — Structured action items
    ///     metadata.json       — Duration, participants, app, timestamps
    async fn export_meeting_files(&self, export: &MeetingExportData<'_>) {
        let date_prefix = chrono::Local::now().format("%Y-%m-%d").to_string();
        let slug = slugify(export.title);
        let folder_name = format!("{}-{}", date_prefix, slug);
        let export_dir = PathBuf::from("/var/lib/lifeos/meetings").join(&folder_name);

        if let Err(e) = tokio::fs::create_dir_all(&export_dir).await {
            warn!(
                "[meeting] BB.12: Failed to create export dir {}: {e}",
                export_dir.display()
            );
            return;
        }

        // --- reunion.md ---
        let hours = export.duration_secs / 3600;
        let minutes = (export.duration_secs % 3600) / 60;
        let duration_str = format!("{}h {}m", hours, minutes);
        let participants_str = if export.participants.is_empty() {
            "No identificados".to_string()
        } else {
            export.participants.join(", ")
        };

        let summary_section = export.summary.unwrap_or("No disponible");
        let title = export.title;
        let app_name = export.app_name;
        let diarized_transcript = export.diarized_transcript;

        let action_items_md: String = if export.action_items.is_empty() {
            "Ninguno".to_string()
        } else {
            export
                .action_items
                .iter()
                .map(|item| {
                    let when_str = item
                        .when
                        .as_deref()
                        .map(|w| format!(" ({})", w))
                        .unwrap_or_default();
                    format!("- [ ] {}: {}{}", item.who, item.what, when_str)
                })
                .collect::<Vec<_>>()
                .join("\n")
        };

        let markdown = format!(
            "# Reunion: {title}\n\n\
             **Fecha:** {date_prefix}\n\
             **Duracion:** {duration_str}\n\
             **App:** {app_name}\n\
             **Participantes:** {participants_str}\n\n\
             ## Resumen\n\n\
             {summary_section}\n\n\
             ## Action Items\n\n\
             {action_items_md}\n\n\
             ## Transcript\n\n\
             {diarized_transcript}\n"
        );

        let md_path = export_dir.join("reunion.md");
        if let Err(e) = tokio::fs::write(&md_path, &markdown).await {
            warn!("[meeting] BB.12: Failed to write reunion.md: {e}");
        }

        // --- metadata.json ---
        let metadata = serde_json::json!({
            "title": export.title,
            "date": date_prefix,
            "started_at": export.started_at,
            "ended_at": export.ended_at,
            "duration_secs": export.duration_secs,
            "duration_human": duration_str,
            "app_name": export.app_name,
            "participants": export.participants,
            "screenshot_count": export.screenshot_paths.len(),
            "screenshot_paths": export.screenshot_paths,
            "action_item_count": export.action_items.len(),
            "export_folder": export_dir.to_string_lossy(),
        });

        let meta_path = export_dir.join("metadata.json");
        match serde_json::to_string_pretty(&metadata) {
            Ok(json_str) => {
                if let Err(e) = tokio::fs::write(&meta_path, &json_str).await {
                    warn!("[meeting] BB.12: Failed to write metadata.json: {e}");
                }
            }
            Err(e) => warn!("[meeting] BB.12: Failed to serialize metadata: {e}"),
        }

        // --- action-items.json ---
        let ai_path = export_dir.join("action-items.json");
        match serde_json::to_string_pretty(&export.action_items) {
            Ok(json_str) => {
                if let Err(e) = tokio::fs::write(&ai_path, &json_str).await {
                    warn!("[meeting] BB.12: Failed to write action-items.json: {e}");
                }
            }
            Err(e) => warn!("[meeting] BB.12: Failed to serialize action items: {e}"),
        }

        // --- Move existing screenshots into the meeting folder ---
        for src_path_str in export.screenshot_paths {
            let src = PathBuf::from(src_path_str);
            if let Some(filename) = src.file_name() {
                let dest = export_dir.join(filename);
                match tokio::fs::rename(&src, &dest).await {
                    Ok(()) => {
                        info!(
                            "[meeting] BB.12: Moved screenshot {} to {}",
                            src.display(),
                            dest.display()
                        );
                    }
                    Err(e) => {
                        // rename may fail across filesystems; try copy+delete
                        if let Ok(()) = tokio::fs::copy(&src, &dest).await.map(|_| ()) {
                            let _ = tokio::fs::remove_file(&src).await;
                            info!(
                                "[meeting] BB.12: Copied screenshot {} to {}",
                                src.display(),
                                dest.display()
                            );
                        } else {
                            warn!(
                                "[meeting] BB.12: Failed to move screenshot {}: {e}",
                                src.display()
                            );
                        }
                    }
                }
            }
        }

        info!(
            "[meeting] BB.12: Meeting files exported to {}",
            export_dir.display()
        );
    }
}

// ── BB.12 helper — slugify title for folder names ──────────────────────────

/// Convert a string to a URL/filesystem-friendly slug.
/// Lowercase, replace non-alphanumeric chars with hyphens, collapse and trim hyphens.
fn slugify(s: &str) -> String {
    let slug: String = s
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    // Collapse consecutive hyphens and trim leading/trailing hyphens
    let mut result = String::with_capacity(slug.len());
    let mut last_was_hyphen = true; // true to trim leading hyphens
    for c in slug.chars() {
        if c == '-' {
            if !last_was_hyphen {
                result.push('-');
            }
            last_was_hyphen = true;
        } else {
            result.push(c);
            last_was_hyphen = false;
        }
    }
    // Trim trailing hyphen
    while result.ends_with('-') {
        result.pop();
    }
    if result.is_empty() {
        "reunion".to_string()
    } else {
        result
    }
}

// ── Dual-channel audio helpers (BB.3) ───────────────────────────────────────

/// Find the PulseAudio/PipeWire monitor source (system audio output loopback).
async fn find_monitor_source() -> Option<String> {
    let output = Command::new("pactl")
        .args(["list", "sources", "short"])
        .output()
        .await
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let text = String::from_utf8_lossy(&output.stdout);
    for line in text.lines() {
        if line.contains(".monitor") {
            // Format: <index>\t<name>\t<driver>\t<format>\t<state>
            let name = line.split('\t').nth(1)?;
            return Some(name.to_string());
        }
    }

    None
}

/// Find the default microphone input source (non-monitor).
async fn find_mic_source() -> Option<String> {
    let output = Command::new("pactl")
        .args(["list", "sources", "short"])
        .output()
        .await
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let text = String::from_utf8_lossy(&output.stdout);

    // First pass: look for active non-monitor sources
    for line in text.lines() {
        if line.contains(".monitor") {
            continue;
        }
        if line.contains("RUNNING") || line.contains("IDLE") || line.contains("SUSPENDED") {
            if let Some(name) = line.split('\t').nth(1) {
                return Some(name.to_string());
            }
        }
    }

    // Fallback: return the first non-monitor source regardless of state
    for line in text.lines() {
        if !line.contains(".monitor") && !line.trim().is_empty() {
            if let Some(name) = line.split('\t').nth(1) {
                return Some(name.to_string());
            }
        }
    }

    None
}

/// Merge mic and system audio files into a combined WAV using ffmpeg.
async fn merge_dual_channels(mic_path: &str, system_path: &str, output_path: &str) -> Result<()> {
    let output = Command::new("ffmpeg")
        .args([
            "-i",
            mic_path,
            "-i",
            system_path,
            "-filter_complex",
            "amix=inputs=2",
            "-ar",
            "16000",
            "-ac",
            "1",
            "-y",
            output_path,
        ])
        .output()
        .await
        .context("ffmpeg dual-channel merge failed")?;

    if !output.status.success() {
        anyhow::bail!(
            "ffmpeg merge failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    Ok(())
}

// ── Meeting detection helpers ───────────────────────────────────────────────

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

/// Extract action items from a meeting summary using simple heuristic parsing.
///
/// Looks for lines starting with bullet points, "TODO", "ACTION", or numbered items
/// that indicate tasks assigned during the meeting.
fn extract_action_items(summary: &str) -> Vec<crate::meeting_archive::ActionItem> {
    let mut items = Vec::new();
    for line in summary.lines() {
        let trimmed = line.trim();
        // Match lines starting with "- [ ]", "* [ ]", "TODO:", "ACTION:", "- TODO"
        let is_action = trimmed.starts_with("- [ ]")
            || trimmed.starts_with("* [ ]")
            || trimmed.to_uppercase().starts_with("TODO:")
            || trimmed.to_uppercase().starts_with("ACTION:")
            || trimmed.to_uppercase().starts_with("- TODO")
            || trimmed.to_uppercase().starts_with("* TODO")
            || trimmed.to_uppercase().starts_with("PENDIENTE:");

        if is_action {
            // Try to extract "who" from patterns like "- [ ] @Alice: do X" or "TODO: Bob should..."
            let content = trimmed
                .trim_start_matches("- [ ]")
                .trim_start_matches("* [ ]")
                .trim_start_matches("TODO:")
                .trim_start_matches("Todo:")
                .trim_start_matches("todo:")
                .trim_start_matches("ACTION:")
                .trim_start_matches("Action:")
                .trim_start_matches("- TODO")
                .trim_start_matches("* TODO")
                .trim_start_matches("PENDIENTE:")
                .trim_start_matches("Pendiente:")
                .trim();

            let (who, what) = if let Some(rest) = content.strip_prefix('@') {
                // "@Alice: do X"
                if let Some(colon_pos) = rest.find(':') {
                    (
                        rest[..colon_pos].trim().to_string(),
                        rest[colon_pos + 1..].trim().to_string(),
                    )
                } else {
                    ("unknown".to_string(), content.to_string())
                }
            } else {
                ("unknown".to_string(), content.to_string())
            };

            if !what.is_empty() {
                items.push(crate::meeting_archive::ActionItem {
                    who,
                    what,
                    when: None,
                    completed: false,
                });
            }
        }
    }
    items
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

/// Resolve the whisper model for real-time captions (BB.8).
/// Prefers the tiny model for minimal latency, falls back to base.
async fn resolve_caption_model() -> Result<String> {
    let candidates = [
        "/var/lib/lifeos/models/whisper/ggml-tiny.bin",
        "/usr/share/lifeos/models/whisper/ggml-tiny.bin",
        "/var/lib/lifeos/models/whisper/ggml-base.bin",
        "/usr/share/lifeos/models/whisper/ggml-base.bin",
    ];
    for path in &candidates {
        if tokio::fs::metadata(path).await.is_ok() {
            return Ok(path.to_string());
        }
    }
    anyhow::bail!("No whisper caption model found (need ggml-tiny.bin or ggml-base.bin)")
}
