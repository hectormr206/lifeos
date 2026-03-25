//! Unified sensory pipeline for LifeOS Phase 4.
//!
//! Coordinates:
//! - voice loop (STT -> LLM -> TTS -> playback)
//! - screen awareness and conversational vision
//! - camera presence and ergonomic heuristics
//! - GPU-aware routing and graceful degradation

use crate::ai::{AiChatResponse, AiManager};
use crate::follow_along::FollowAlongManager;
use crate::memory_plane::MemoryPlaneManager;
use crate::overlay::{AxiState, OverlayManager};
use crate::screen_capture::ScreenCapture;
use crate::telemetry::{MetricCategory, TelemetryManager};
use anyhow::{Context, Result};
use chrono::{DateTime, Timelike, Utc};
use image::{GenericImageView, Pixel};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use tokio::sync::{Mutex, RwLock};

const STATE_FILE: &str = "sensory_pipeline_state.json";
const BENCHMARK_FILE: &str = "sensory_benchmark.json";
const DEFAULT_SCREEN_INTERVAL_SECONDS: u64 = 10;
const ALWAYS_ON_CAPTURE_SECONDS: u64 = 4;
const DEFAULT_WAKE_WORD: &str = "axi";
const MAX_RELEVANT_LINES: usize = 8;
const MAX_MEMORY_BYTES: usize = 6 * 1024;
const MIN_AUDIO_SIGNAL_BYTES: usize = 4096;
/// Default RMS threshold for speech detection. Can be overridden via
/// `LIFEOS_VAD_RMS_THRESHOLD` env var. Lowered from 450 to 250 to detect
/// quiet/soft speech (whispers are ~100-300 RMS in 16-bit PCM).
const PCM_RMS_THRESHOLD_DEFAULT: f64 = 250.0;
/// Multiplier applied to the measured noise floor to compute the adaptive
/// speech threshold: `threshold = max(noise_floor * ADAPTIVE_MULTIPLIER, absolute_min)`.
const ADAPTIVE_NOISE_MULTIPLIER: f64 = 3.0;
/// Absolute minimum RMS threshold even with very low noise floor,
/// to avoid triggering on electrical noise.
const ADAPTIVE_RMS_FLOOR: f64 = 80.0;
/// Number of initial 250ms windows used to measure ambient noise floor.
const NOISE_FLOOR_WINDOWS: usize = 4; // 1 second of ambient measurement
/// How long to wait for the user to start speaking after wake word (seconds).
/// Increased from 4.0 to 6.0 to give quiet speakers more time.
const UTTERANCE_PRE_SPEECH_TIMEOUT_SECS: f64 = 6.0;
/// How long of silence after speech to consider the utterance complete (seconds).
/// Set to 2.5 s to tolerate natural thinking pauses (~1-2 s) without cutting off.
const UTTERANCE_SILENCE_AFTER_SPEECH_SECS: f64 = 2.5;
/// Absolute maximum recording time to prevent infinite capture (seconds).
const UTTERANCE_MAX_DURATION_SECS: f64 = 30.0;
/// Size of each analysis window for streaming VAD (seconds).
const UTTERANCE_WINDOW_SECS: f64 = 0.25;
/// Sample rate for all audio capture.
const AUDIO_SAMPLE_RATE: u32 = 16000;

/// Read the VAD RMS threshold from environment or return the default.
fn vad_rms_threshold() -> f64 {
    std::env::var("LIFEOS_VAD_RMS_THRESHOLD")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(PCM_RMS_THRESHOLD_DEFAULT)
}
const SCREENSHOT_RETENTION_COUNT: usize = 50;
const SCREENSHOT_RETENTION_DAYS: u64 = 2;
const IDLE_SCREEN_INTERVAL_SECONDS: u64 = 45;
const VISION_MEMORY_ROUTINE_HOURS: u64 = 4;
const VISION_MEMORY_KEY_DAYS: u64 = 7;
const AUDIO_RETENTION_COUNT: usize = 120;
const TTS_RETENTION_COUNT: usize = 120;
const OCR_SIMILARITY_SKIP_THRESHOLD: f32 = 0.92;
const RELEVANT_SIMILARITY_SKIP_THRESHOLD: f32 = 0.60;
const OCR_LENGTH_DELTA_TRIGGER: usize = 320;
const TTS_CHUNK_MAX_CHARS: usize = 260;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct SensorLeds {
    pub mic_active: bool,
    pub camera_active: bool,
    pub screen_active: bool,
    pub kill_switch_active: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct SensoryCapabilities {
    pub stt_binary: Option<String>,
    pub audio_capture_binary: Option<String>,
    pub tts_binary: Option<String>,
    pub tts_model: Option<String>,
    pub playback_binary: Option<String>,
    pub screen_capture_available: bool,
    pub tesseract_available: bool,
    pub multimodal_chat_available: bool,
    pub camera_device: Option<String>,
    pub camera_capture_binary: Option<String>,
    pub llama_server_running: bool,
    pub always_on_source: Option<String>,
    pub rustpotter_model_available: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct GpuOffloadStatus {
    pub backend: String,
    pub gpu_name: Option<String>,
    pub total_vram_gb: Option<u32>,
    pub free_vram_gb: Option<u32>,
    pub profile_tier: String,
    pub llm_offload: String,
    pub vision_offload: String,
    pub tts_offload: String,
    pub stt_offload: String,
    pub recommended_gpu_layers: i32,
    pub active_gpu_layers: i32,
    pub rebalance_reason: Option<String>,
    pub tokens_per_second: Option<f32>,
    pub gpu_temp_celsius: Option<f32>,
    pub throttling: bool,
    pub updated_at: Option<DateTime<Utc>>,
}

impl Default for GpuOffloadStatus {
    fn default() -> Self {
        Self {
            backend: "cpu".to_string(),
            gpu_name: None,
            total_vram_gb: None,
            free_vram_gb: None,
            profile_tier: "cpu_only".to_string(),
            llm_offload: "cpu only".to_string(),
            vision_offload: "cpu only".to_string(),
            tts_offload: "cpu".to_string(),
            stt_offload: "cpu".to_string(),
            recommended_gpu_layers: 0,
            active_gpu_layers: 0,
            rebalance_reason: Some("no_dedicated_gpu".to_string()),
            tokens_per_second: None,
            gpu_temp_celsius: None,
            throttling: false,
            updated_at: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct VoiceSessionRuntime {
    pub active: bool,
    pub always_on_active: bool,
    pub session_id: Option<String>,
    pub last_transcript: Option<String>,
    pub last_response: Option<String>,
    pub last_audio_path: Option<String>,
    pub last_latency_ms: Option<u64>,
    pub last_tts_engine: Option<String>,
    pub last_playback_backend: Option<String>,
    pub last_tokens_per_second: Option<f32>,
    pub wake_word: String,
    pub last_listen_at: Option<DateTime<Utc>>,
    pub last_hotword_at: Option<DateTime<Utc>>,
    pub last_completed_at: Option<DateTime<Utc>>,
    pub last_interrupt_at: Option<DateTime<Utc>>,
    pub barge_in_count: u32,
    pub slo_target_ms: u64,
}

impl Default for VoiceSessionRuntime {
    fn default() -> Self {
        Self {
            active: false,
            always_on_active: false,
            session_id: None,
            last_transcript: None,
            last_response: None,
            last_audio_path: None,
            last_latency_ms: None,
            last_tts_engine: None,
            last_playback_backend: None,
            last_tokens_per_second: None,
            wake_word: DEFAULT_WAKE_WORD.to_string(),
            last_listen_at: None,
            last_hotword_at: None,
            last_completed_at: None,
            last_interrupt_at: None,
            barge_in_count: 0,
            slo_target_ms: 5000,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct VisionRuntime {
    pub enabled: bool,
    pub capture_interval_seconds: u64,
    pub last_capture_path: Option<String>,
    pub last_ocr_text: Option<String>,
    pub last_relevant_text: Vec<String>,
    pub last_summary: Option<String>,
    pub last_query_latency_ms: Option<u64>,
    pub last_multimodal_success: bool,
    pub last_updated_at: Option<DateTime<Utc>>,
    pub current_app: Option<String>,
    pub current_window: Option<String>,
    pub last_window_change_at: Option<DateTime<Utc>>,
}

impl Default for VisionRuntime {
    fn default() -> Self {
        Self {
            enabled: false,
            capture_interval_seconds: DEFAULT_SCREEN_INTERVAL_SECONDS,
            last_capture_path: None,
            last_ocr_text: None,
            last_relevant_text: Vec::new(),
            last_summary: None,
            last_query_latency_ms: None,
            last_multimodal_success: false,
            last_updated_at: None,
            current_app: None,
            current_window: None,
            last_window_change_at: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct PresenceRuntime {
    pub camera_available: bool,
    pub camera_consented: bool,
    pub camera_active: bool,
    pub present: bool,
    pub source: String,
    pub face_near_screen: bool,
    pub fatigue_alert: bool,
    pub posture_alert: bool,
    pub away_seconds: u64,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub last_checked_at: Option<DateTime<Utc>>,
    /// AI-generated description of what the camera sees (when multimodal available).
    pub scene_description: Option<String>,
    /// Detected user state: focused, distracted, away, talking, etc.
    pub user_state: Option<String>,
    /// Number of people detected in frame (0 = nobody, 1 = user alone, 2+ = meeting).
    pub people_count: Option<u8>,
    /// Last frame path for multimodal analysis.
    pub last_frame_path: Option<String>,
}

impl Default for PresenceRuntime {
    fn default() -> Self {
        Self {
            camera_available: false,
            camera_consented: false,
            camera_active: false,
            present: false,
            source: "activity-fallback".to_string(),
            face_near_screen: false,
            fatigue_alert: false,
            posture_alert: false,
            away_seconds: 0,
            last_seen_at: None,
            last_checked_at: None,
            scene_description: None,
            user_state: None,
            people_count: None,
            last_frame_path: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct SensoryPipelineState {
    pub axi_state: AxiState,
    pub leds: SensorLeds,
    pub kill_switch_active: bool,
    pub heavy_slot: String,
    pub degraded_modes: Vec<String>,
    pub capabilities: SensoryCapabilities,
    pub gpu: GpuOffloadStatus,
    pub voice: VoiceSessionRuntime,
    pub vision: VisionRuntime,
    pub presence: PresenceRuntime,
    pub meeting: MeetingState,
    pub last_error: Option<String>,
    pub last_updated_at: Option<DateTime<Utc>>,
}

impl Default for SensoryPipelineState {
    fn default() -> Self {
        Self {
            axi_state: AxiState::Idle,
            leds: SensorLeds::default(),
            kill_switch_active: false,
            heavy_slot: "llm".to_string(),
            degraded_modes: vec![],
            capabilities: SensoryCapabilities::default(),
            gpu: GpuOffloadStatus::default(),
            voice: VoiceSessionRuntime::default(),
            vision: VisionRuntime::default(),
            presence: PresenceRuntime::default(),
            meeting: MeetingState::default(),
            last_error: None,
            last_updated_at: None,
        }
    }
}

/// Tracks whether the user is in a video/voice call.
///
/// When active, Axi pauses wake word detection, skips camera capture,
/// and disables audio ducking to avoid interfering with the call.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct MeetingState {
    /// Whether a meeting/call is currently detected.
    pub active: bool,
    /// The app producing audio (e.g. "chrome", "firefox", "zoom", "discord").
    pub conferencing_app: Option<String>,
    /// Whether the camera device is busy (another process has it open).
    pub camera_busy: bool,
    /// Last time meeting state was checked.
    pub last_checked_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VoiceLoopRequest {
    pub audio_file: Option<String>,
    pub prompt: Option<String>,
    pub include_screen: bool,
    pub screen_source: Option<String>,
    pub language: Option<String>,
    pub voice_model: Option<String>,
    pub playback: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VoiceLoopResult {
    pub session_id: String,
    pub transcript: String,
    pub response: String,
    pub screen_path: Option<String>,
    pub relevant_text: Vec<String>,
    pub audio_path: Option<String>,
    pub latency_ms: u64,
    pub tts_engine: Option<String>,
    pub playback_backend: Option<String>,
    pub playback_started: bool,
    pub multimodal_used: bool,
    pub degraded_modes: Vec<String>,
    pub gpu: GpuOffloadStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VisionDescribeRequest {
    pub source: Option<String>,
    pub capture_screen: bool,
    pub speak: bool,
    pub question: Option<String>,
    pub language: Option<String>,
    pub voice_model: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VisionDescribeResult {
    pub response: String,
    pub screen_path: Option<String>,
    pub ocr_text: Option<String>,
    pub relevant_text: Vec<String>,
    pub audio_path: Option<String>,
    pub latency_ms: u64,
    pub multimodal_used: bool,
    pub degraded_modes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TtsRequest {
    pub text: String,
    pub language: Option<String>,
    pub voice_model: Option<String>,
    pub playback: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TtsResult {
    pub text: String,
    pub audio_path: Option<String>,
    pub tts_engine: Option<String>,
    pub playback_backend: Option<String>,
    pub playback_started: bool,
    pub degraded_modes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SensoryBenchmarkRequest {
    pub audio_file: Option<String>,
    pub prompt: Option<String>,
    pub include_screen: bool,
    pub screen_source: Option<String>,
    pub repeats: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SensoryBenchmarkEntry {
    pub iteration: u32,
    pub voice_loop_latency_ms: Option<u64>,
    pub vision_query_latency_ms: Option<u64>,
    pub gpu_tokens_per_second: Option<f32>,
    pub degraded_modes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SensoryBenchmarkReport {
    pub generated_at: DateTime<Utc>,
    pub repeats: u32,
    pub entries: Vec<SensoryBenchmarkEntry>,
    pub avg_voice_loop_latency_ms: Option<u64>,
    pub avg_vision_query_latency_ms: Option<u64>,
    pub avg_gpu_tokens_per_second: Option<f32>,
}

#[derive(Debug, Clone)]
struct ActivePlayback {
    session_id: String,
    pid: u32,
    backend: String,
    audio_path: String,
}

#[derive(Debug, Clone)]
struct ScreenContextResult {
    screen_path: String,
    ocr_text: String,
    relevant_text: Vec<String>,
    multimodal_used: bool,
}

pub struct SensoryRuntimeSync<'a> {
    pub audio_enabled: bool,
    pub screen_enabled: bool,
    pub camera_enabled: bool,
    pub kill_switch_active: bool,
    pub capture_interval_seconds: u64,
    pub always_on_active: bool,
    pub wake_word: Option<&'a str>,
}

pub struct AlwaysOnCycle<'a> {
    pub ai_manager: &'a AiManager,
    pub overlay: &'a OverlayManager,
    pub screen_capture: &'a ScreenCapture,
    pub memory_plane: &'a MemoryPlaneManager,
    pub telemetry: &'a TelemetryManager,
    pub wake_word: &'a str,
    pub screen_enabled: bool,
}

#[derive(Clone)]
pub struct SensoryPipelineManager {
    data_dir: PathBuf,
    state: Arc<RwLock<SensoryPipelineState>>,
    playback: Arc<Mutex<Option<ActivePlayback>>>,
}

impl SensoryPipelineManager {
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&data_dir).context("Failed to create sensory pipeline data dir")?;
        Ok(Self {
            data_dir,
            state: Arc::new(RwLock::new(SensoryPipelineState::default())),
            playback: Arc::new(Mutex::new(None)),
        })
    }

    pub async fn initialize(&self) -> Result<()> {
        self.load_state().await
    }

    pub async fn status(&self) -> SensoryPipelineState {
        self.state.read().await.clone()
    }

    pub async fn refresh_capabilities(
        &self,
        ai_manager: &AiManager,
    ) -> Result<SensoryPipelineState> {
        let mut state = self.state.write().await;
        state.capabilities = detect_capabilities(ai_manager).await;
        state.gpu = detect_gpu_status(state.gpu.tokens_per_second).await;
        let llama_server_running = state.capabilities.llama_server_running;
        if let Err(error) = maybe_apply_gpu_rebalance(&mut state.gpu, llama_server_running).await {
            state.gpu.rebalance_reason = Some(format!("rebalance_unapplied: {}", error));
        }
        state.presence.camera_available = state.capabilities.camera_device.is_some();
        state.degraded_modes = degraded_modes(&state.capabilities, &state.gpu);
        state.voice.slo_target_ms = if state.gpu.backend == "nvidia" {
            2000
        } else {
            5000
        };
        state.last_updated_at = Some(Utc::now());
        let snapshot = state.clone();
        drop(state);
        self.save_state().await?;
        Ok(snapshot)
    }

    pub async fn sync_runtime(
        &self,
        runtime: SensoryRuntimeSync<'_>,
        overlay: &OverlayManager,
    ) -> Result<SensoryPipelineState> {
        let mut state = self.state.write().await;
        state.kill_switch_active = runtime.kill_switch_active;
        state.leds = SensorLeds {
            mic_active: runtime.audio_enabled && !runtime.kill_switch_active,
            camera_active: runtime.camera_enabled && !runtime.kill_switch_active,
            screen_active: runtime.screen_enabled && !runtime.kill_switch_active,
            kill_switch_active: runtime.kill_switch_active,
        };
        state.vision.enabled = runtime.screen_enabled && !runtime.kill_switch_active;
        state.vision.capture_interval_seconds = runtime.capture_interval_seconds.clamp(5, 30);
        state.presence.camera_consented = runtime.camera_enabled;
        state.presence.camera_active = runtime.camera_enabled && !runtime.kill_switch_active;
        state.voice.always_on_active =
            runtime.always_on_active && runtime.audio_enabled && !runtime.kill_switch_active;
        state.voice.wake_word = runtime
            .wake_word
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or(DEFAULT_WAKE_WORD)
            .to_string();

        if runtime.kill_switch_active {
            state.axi_state = AxiState::Offline;
            state.voice.active = false;
        } else if !state.voice.active {
            state.axi_state = AxiState::Idle;
        }

        let snapshot = state.clone();
        drop(state);
        overlay
            .set_sensor_indicators(
                snapshot.leds.mic_active,
                snapshot.leds.camera_active,
                snapshot.leds.screen_active,
                snapshot.leds.kill_switch_active,
            )
            .await?;
        overlay
            .set_axi_state(
                snapshot.axi_state.clone(),
                Some(snapshot.heavy_slot.as_str()),
            )
            .await?;
        self.save_state().await?;
        Ok(snapshot)
    }

    pub async fn is_screen_awareness_due(&self, base_interval_seconds: u64) -> bool {
        let state = self.state.read().await;
        let now = Utc::now();

        // Window changed since last capture — capture immediately.
        if let Some(change_at) = state.vision.last_window_change_at {
            let last_capture = state.vision.last_updated_at.unwrap_or(change_at);
            if change_at > last_capture {
                return true;
            }
        }

        // Adaptive interval: if last OCR was identical to previous, stretch to idle.
        let interval = if state.vision.last_window_change_at.is_none()
            && state.vision.last_ocr_text.is_some()
        {
            IDLE_SCREEN_INTERVAL_SECONDS
        } else {
            base_interval_seconds.clamp(5, 30)
        };

        state
            .vision
            .last_updated_at
            .map(|last| (now - last).num_seconds().max(0) as u64 >= interval)
            .unwrap_or(true)
    }

    /// Poll the compositor for the active window and update vision state.
    ///
    /// Returns `Some((app_id, title))` if the window changed since last poll.
    pub async fn update_active_window(&self) -> Option<(String, String)> {
        let (app, title) = match poll_active_window().await {
            Ok(result) => result,
            Err(_) => return None,
        };

        let mut state = self.state.write().await;
        let changed = state.vision.current_app.as_deref() != Some(&app)
            || state.vision.current_window.as_deref() != Some(&title);

        state.vision.current_app = Some(app.clone());
        state.vision.current_window = Some(title.clone());

        if changed {
            state.vision.last_window_change_at = Some(Utc::now());
            Some((app, title))
        } else {
            None
        }
    }

    /// Refresh meeting/call detection state.
    ///
    /// Returns the updated `MeetingState`. When `active == true`, the caller
    /// should pause wake word detection and skip camera capture + audio ducking.
    pub async fn refresh_meeting_state(&self) -> MeetingState {
        let camera_device = {
            let state = self.state.read().await;
            state.capabilities.camera_device.clone()
        };
        let meeting = refresh_meeting_state(camera_device.as_deref()).await;
        {
            let mut state = self.state.write().await;
            state.meeting = meeting.clone();
        }
        meeting
    }

    /// Whether a meeting/call is currently active.
    pub async fn is_meeting_active(&self) -> bool {
        self.state.read().await.meeting.active
    }

    pub async fn is_presence_refresh_due(&self, interval_seconds: u64) -> bool {
        let state = self.state.read().await;
        let interval_seconds = interval_seconds.clamp(5, 30);
        state
            .presence
            .last_checked_at
            .map(|last| (Utc::now() - last).num_seconds().max(0) as u64 >= interval_seconds)
            .unwrap_or(true)
    }

    pub async fn trigger_kill_switch(
        &self,
        overlay: &OverlayManager,
    ) -> Result<SensoryPipelineState> {
        let _ = self.interrupt_voice_session(overlay).await?;
        let mut state = self.state.write().await;
        state.kill_switch_active = true;
        state.leds = SensorLeds {
            kill_switch_active: true,
            ..SensorLeds::default()
        };
        state.voice.active = false;
        state.voice.always_on_active = false;
        state.presence.camera_active = false;
        state.vision.enabled = false;
        state.axi_state = AxiState::Offline;
        state.last_updated_at = Some(Utc::now());
        let snapshot = state.clone();
        drop(state);
        overlay
            .set_sensor_indicators(false, false, false, true)
            .await?;
        overlay
            .set_axi_state(AxiState::Offline, Some("kill-switch"))
            .await?;
        overlay.clear_processing_feedback().await?;
        self.save_state().await?;
        Ok(snapshot)
    }

    pub async fn interrupt_voice_session(&self, overlay: &OverlayManager) -> Result<bool> {
        let active = self.playback.lock().await.clone();
        let Some(active) = active else {
            return Ok(false);
        };

        kill_pid(active.pid).await.ok();
        let mut playback = self.playback.lock().await;
        playback.take();
        drop(playback);

        let mut state = self.state.write().await;
        state.voice.active = false;
        state.voice.last_interrupt_at = Some(Utc::now());
        state.voice.last_playback_backend = Some(active.backend);
        state.voice.last_audio_path = Some(active.audio_path);
        state.axi_state = if state.kill_switch_active {
            AxiState::Offline
        } else {
            AxiState::Idle
        };
        let snapshot = state.clone();
        drop(state);

        overlay
            .set_axi_state(snapshot.axi_state.clone(), Some("interrupted"))
            .await?;
        overlay.clear_processing_feedback().await?;
        self.save_state().await?;
        Ok(true)
    }

    pub async fn speak_text(
        &self,
        overlay: &OverlayManager,
        request: TtsRequest,
    ) -> Result<TtsResult> {
        let state = self.state.read().await.clone();
        if state.kill_switch_active {
            anyhow::bail!("sensory kill switch is active");
        }

        overlay
            .set_axi_state(AxiState::Speaking, Some("tts"))
            .await?;

        let mut degraded = degraded_modes(&state.capabilities, &state.gpu);
        let (audio_path, tts_engine) = match synthesize_tts(
            &self.data_dir,
            &request.text,
            request.language.as_deref(),
            request.voice_model.as_deref(),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => {
                degraded.push("tts_unavailable".to_string());
                overlay
                    .set_axi_state(AxiState::Error, Some("tts-unavailable"))
                    .await?;
                overlay
                    .set_error(Some("Local TTS engine is not available"))
                    .await?;
                return Ok(TtsResult {
                    text: request.text,
                    audio_path: None,
                    tts_engine: None,
                    playback_backend: None,
                    playback_started: false,
                    degraded_modes: dedupe_strings(degraded),
                });
            }
        };

        let (playback_backend, playback_started) = if request.playback {
            self.spawn_playback(
                overlay.clone(),
                format!("tts-{}", uuid::Uuid::new_v4()),
                &audio_path,
            )
            .await?
        } else {
            (None, false)
        };

        if !playback_started {
            overlay
                .set_axi_state(AxiState::Idle, Some("tts-ready"))
                .await?;
        }

        Ok(TtsResult {
            text: request.text,
            audio_path: Some(audio_path),
            tts_engine: Some(tts_engine),
            playback_backend,
            playback_started,
            degraded_modes: dedupe_strings(degraded),
        })
    }

    pub async fn run_always_on_cycle(
        &self,
        cycle: AlwaysOnCycle<'_>,
    ) -> Result<Option<VoiceLoopResult>> {
        let state = self.status().await;
        if state.kill_switch_active
            || !state.leds.mic_active
            || !state.voice.always_on_active
            || state.voice.active
        {
            return Ok(None);
        }

        if let Some(last_listen_at) = state.voice.last_listen_at {
            if ((Utc::now() - last_listen_at).num_seconds().max(0) as u64)
                < ALWAYS_ON_CAPTURE_SECONDS
            {
                return Ok(None);
            }
        }

        let always_on_source = {
            let st = self.state.read().await;
            st.capabilities.always_on_source.clone()
        };
        let audio_path = match capture_audio_snippet(
            &self.data_dir,
            ALWAYS_ON_CAPTURE_SECONDS,
            always_on_source.as_deref(),
        )
        .await
        {
            Ok(path) => path,
            Err(_) => return Ok(None),
        };
        {
            let mut state = self.state.write().await;
            state.voice.last_listen_at = Some(Utc::now());
            state.voice.last_audio_path = Some(audio_path.clone());
            state.last_updated_at = Some(Utc::now());
        }
        self.save_state().await?;

        if !audio_has_voice_activity(Path::new(&audio_path)).await? {
            cycle
                .telemetry
                .record_event(
                    MetricCategory::AiRuntime,
                    "always_on_voice_idle",
                    serde_json::json!({
                        "audio_path": audio_path,
                        "wake_word": cycle.wake_word,
                    }),
                    None,
                )
                .await
                .ok();
            return Ok(None);
        }

        let (transcript, _binary) = match transcribe_audio(&audio_path, None).await {
            Ok(result) => result,
            Err(_) => return Ok(None),
        };
        let transcript = normalize_whitespace(&transcript);
        if transcript.is_empty() {
            return Ok(None);
        }

        {
            let mut state = self.state.write().await;
            state.voice.last_transcript = Some(transcript.clone());
            state.last_updated_at = Some(Utc::now());
        }
        self.save_state().await?;

        let hotword = normalized_wake_word(cycle.wake_word);
        if !contains_wake_word(&transcript, &hotword) {
            cycle
                .telemetry
                .record_event(
                    MetricCategory::AiRuntime,
                    "always_on_voice_ignored",
                    serde_json::json!({
                        "wake_word": hotword,
                        "transcript_chars": transcript.len(),
                    }),
                    None,
                )
                .await
                .ok();
            return Ok(None);
        }

        {
            let mut state = self.state.write().await;
            state.voice.last_hotword_at = Some(Utc::now());
            state.voice.wake_word = hotword.clone();
            state.last_updated_at = Some(Utc::now());
        }
        self.save_state().await?;

        let prompt = strip_wake_word(&transcript, &hotword)
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| "Estoy escuchando. Dime como puedo ayudarte.".to_string());
        let include_screen = cycle.screen_enabled && should_include_screen_for_prompt(&prompt);
        let result = self
            .run_voice_loop(
                cycle.ai_manager,
                cycle.overlay,
                cycle.screen_capture,
                cycle.memory_plane,
                cycle.telemetry,
                VoiceLoopRequest {
                    audio_file: None,
                    prompt: Some(prompt),
                    include_screen,
                    screen_source: None,
                    language: Some("es".to_string()),
                    voice_model: None,
                    playback: true,
                },
            )
            .await?;

        Ok(Some(result))
    }

    /// Handle the post-detection flow when rustpotter already confirmed the
    /// wake word. Captures command audio, transcribes via Whisper, and runs
    /// the voice loop — without re-checking for the wake word.
    pub async fn run_post_wakeword_cycle(
        &self,
        cycle: AlwaysOnCycle<'_>,
    ) -> Result<Option<VoiceLoopResult>> {
        let state = self.status().await;
        if state.kill_switch_active || !state.leds.mic_active || state.voice.active {
            return Ok(None);
        }

        {
            let mut st = self.state.write().await;
            st.voice.last_hotword_at = Some(Utc::now());
            st.voice.wake_word = normalized_wake_word(cycle.wake_word);
            st.last_updated_at = Some(Utc::now());
        }
        self.save_state().await?;

        cycle
            .telemetry
            .record_event(
                MetricCategory::AiRuntime,
                "wake_word_rustpotter_detected",
                serde_json::json!({ "wake_word": cycle.wake_word }),
                None,
            )
            .await
            .ok();

        // Capture command audio — listen until the user stops speaking.
        let always_on_source = {
            let st = self.state.read().await;
            st.capabilities.always_on_source.clone()
        };
        let audio_path =
            match capture_until_silence(&self.data_dir, always_on_source.as_deref()).await {
                Ok(path) => path,
                Err(_) => return Ok(None),
            };

        {
            let mut st = self.state.write().await;
            st.voice.last_listen_at = Some(Utc::now());
            st.voice.last_audio_path = Some(audio_path.clone());
            st.last_updated_at = Some(Utc::now());
        }
        self.save_state().await?;

        // Check if the captured audio actually contains voice
        if !audio_has_voice_activity(Path::new(&audio_path)).await? {
            // User said "Axi" but didn't follow up — respond with a prompt
            let result = self
                .run_voice_loop(
                    cycle.ai_manager,
                    cycle.overlay,
                    cycle.screen_capture,
                    cycle.memory_plane,
                    cycle.telemetry,
                    VoiceLoopRequest {
                        audio_file: None,
                        prompt: Some("Estoy escuchando. Dime como puedo ayudarte.".to_string()),
                        include_screen: false,
                        screen_source: None,
                        language: Some("es".to_string()),
                        voice_model: None,
                        playback: true,
                    },
                )
                .await?;
            return Ok(Some(result));
        }

        // Transcribe the command
        let (transcript, _binary) = match transcribe_audio(&audio_path, None).await {
            Ok(result) => result,
            Err(_) => return Ok(None),
        };
        let transcript = normalize_whitespace(&transcript);
        if transcript.is_empty() {
            return Ok(None);
        }

        {
            let mut st = self.state.write().await;
            st.voice.last_transcript = Some(transcript.clone());
            st.last_updated_at = Some(Utc::now());
        }
        self.save_state().await?;

        // Strip any residual wake word from the transcript
        let hotword = normalized_wake_word(cycle.wake_word);
        let prompt = strip_wake_word(&transcript, &hotword)
            .filter(|value| !value.is_empty())
            .unwrap_or(transcript);

        let include_screen = cycle.screen_enabled && should_include_screen_for_prompt(&prompt);
        let result = self
            .run_voice_loop(
                cycle.ai_manager,
                cycle.overlay,
                cycle.screen_capture,
                cycle.memory_plane,
                cycle.telemetry,
                VoiceLoopRequest {
                    audio_file: None,
                    prompt: Some(prompt),
                    include_screen,
                    screen_source: None,
                    language: Some("es".to_string()),
                    voice_model: None,
                    playback: true,
                },
            )
            .await?;

        Ok(Some(result))
    }

    pub async fn run_voice_loop(
        &self,
        ai_manager: &AiManager,
        overlay: &OverlayManager,
        screen_capture: &ScreenCapture,
        memory_plane: &MemoryPlaneManager,
        telemetry: &TelemetryManager,
        request: VoiceLoopRequest,
    ) -> Result<VoiceLoopResult> {
        let state = self.refresh_capabilities(ai_manager).await?;
        if state.kill_switch_active {
            anyhow::bail!("sensory kill switch is active");
        }

        let mut degraded = state.degraded_modes.clone();
        let barge_in = self.interrupt_voice_session(overlay).await?;
        if barge_in {
            degraded.push("barge_in".to_string());
        }

        let session_id = format!("voice-{}", uuid::Uuid::new_v4());
        let session_started = Instant::now();
        let transcript =
            if let Some(prompt) = request.prompt.as_deref().filter(|v| !v.trim().is_empty()) {
                prompt.trim().to_string()
            } else if let Some(audio_file) = request
                .audio_file
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                overlay
                    .set_axi_state(AxiState::Listening, Some("stt"))
                    .await?;
                overlay
                    .set_processing_feedback(Some("listening"), None, None, Some(0.8))
                    .await?;
                let (text, _binary) = transcribe_audio(audio_file, None).await?;
                text
            } else {
                anyhow::bail!("either prompt or audio_file is required for voice session");
            };

        if transcript.trim().is_empty() {
            anyhow::bail!("empty transcript produced by voice session");
        }

        let screen_context = if request.include_screen || request.screen_source.is_some() {
            overlay
                .set_axi_state(AxiState::Watching, Some("vision"))
                .await?;
            Some(
                self.prepare_screen_context(
                    ai_manager,
                    screen_capture,
                    memory_plane,
                    request.screen_source.as_deref(),
                    transcript.as_str(),
                )
                .await?,
            )
        } else {
            None
        };

        overlay
            .set_axi_state(AxiState::Thinking, Some("llm"))
            .await?;

        let system_context = screen_context.as_ref().map(|ctx| {
            format!(
                "Screen OCR context:\n{}\n\nRelevant lines:\n{}",
                ctx.ocr_text,
                ctx.relevant_text.join("\n")
            )
        });
        let llm_started = Instant::now();
        let chat = if let Some(ctx) = screen_context.as_ref() {
            multimodal_chat_with_fallback(
                ai_manager,
                &transcript,
                &ctx.screen_path,
                system_context.as_deref(),
            )
            .await?
        } else {
            ai_manager
                .chat(
                    None,
                    vec![
                        (
                            "system".to_string(),
                            "You are Axi, the local LifeOS assistant. Answer in ONE or TWO short sentences in natural spoken Spanish. Be direct and concise — this will be read aloud via TTS. No markdown, no code, no lists, no internal reasoning.".to_string(),
                        ),
                        ("user".to_string(), transcript.clone()),
                    ],
                )
                .await?
        };
        let llm_duration_ms = llm_started.elapsed().as_millis() as u64;
        let tokens_per_second = tokens_per_second(chat.tokens_used, llm_duration_ms);
        let response_text = sanitize_assistant_response(&chat.response);
        overlay
            .set_processing_feedback(
                Some("thinking"),
                tokens_per_second,
                Some(llm_duration_ms),
                None,
            )
            .await?;

        let mut audio_path = None;
        let mut tts_engine = None;
        let mut playback_backend = None;
        let mut playback_started = false;
        if request.playback {
            overlay
                .set_axi_state(AxiState::Speaking, Some("tts"))
                .await?;
            // Progressive TTS: synthesize + play sentence by sentence, with audio ducking.
            match self
                .synthesize_and_play_progressive(
                    overlay,
                    &session_id,
                    &response_text,
                    request.language.as_deref(),
                    request.voice_model.as_deref(),
                )
                .await
            {
                Ok((path, engine, backend, played)) => {
                    audio_path = path;
                    tts_engine = engine;
                    playback_backend = backend;
                    playback_started = played;
                }
                Err(e) => {
                    log::warn!("Progressive TTS failed, trying single-shot: {}", e);
                    // Fallback to single-shot TTS if progressive fails.
                    match synthesize_tts(
                        &self.data_dir,
                        &response_text,
                        request.language.as_deref(),
                        request.voice_model.as_deref(),
                    )
                    .await
                    {
                        Ok((path, engine)) => {
                            duck_system_audio(true).await;
                            tts_engine = Some(engine);
                            audio_path = Some(path.clone());
                            let playback = self
                                .spawn_playback(overlay.clone(), session_id.clone(), &path)
                                .await?;
                            playback_backend = playback.0;
                            playback_started = playback.1;
                        }
                        Err(_) => degraded.push("tts_unavailable".to_string()),
                    }
                }
            }
        }

        let latency_ms = session_started.elapsed().as_millis() as u64;
        {
            let mut state = self.state.write().await;
            // Progressive TTS completes synchronously, so we are always Idle here.
            state.axi_state = AxiState::Idle;
            state.heavy_slot = if screen_context.is_some() {
                "vision".to_string()
            } else {
                "llm".to_string()
            };
            state.voice.active = false;
            state.voice.session_id = Some(session_id.clone());
            state.voice.last_transcript = Some(transcript.clone());
            state.voice.last_response = Some(response_text.clone());
            state.voice.last_audio_path = audio_path.clone();
            state.voice.last_latency_ms = Some(latency_ms);
            state.voice.last_tts_engine = tts_engine.clone();
            state.voice.last_playback_backend = playback_backend.clone();
            state.voice.last_tokens_per_second = tokens_per_second;
            state.voice.last_completed_at = Some(Utc::now());
            if barge_in {
                state.voice.barge_in_count += 1;
            }
            state.gpu.tokens_per_second = tokens_per_second;
            state.last_error = None;
            state.last_updated_at = Some(Utc::now());
            if let Some(ctx) = screen_context.as_ref() {
                state.vision.last_capture_path = Some(ctx.screen_path.clone());
                state.vision.last_ocr_text = Some(ctx.ocr_text.clone());
                state.vision.last_relevant_text = ctx.relevant_text.clone();
                state.vision.last_summary = Some(response_text.clone());
                state.vision.last_query_latency_ms = Some(llm_duration_ms);
                state.vision.last_multimodal_success = ctx.multimodal_used;
                state.vision.last_updated_at = Some(Utc::now());
            }
            state.degraded_modes = dedupe_strings(degraded.clone());
        }
        self.save_state().await?;

        telemetry
            .record_event(
                MetricCategory::AiRuntime,
                "voice_loop",
                serde_json::json!({
                    "latency_ms": latency_ms,
                    "screen_context": screen_context.is_some(),
                    "playback_started": playback_started,
                    "multimodal_used": screen_context.as_ref().map(|ctx| ctx.multimodal_used).unwrap_or(false),
                    "degraded_modes": degraded,
                }),
                Some(latency_ms),
            )
            .await
            .ok();

        overlay.set_axi_state(AxiState::Idle, Some("ready")).await?;
        overlay.clear_processing_feedback().await?;

        Ok(VoiceLoopResult {
            session_id,
            transcript,
            response: response_text,
            screen_path: screen_context.as_ref().map(|ctx| ctx.screen_path.clone()),
            relevant_text: screen_context
                .as_ref()
                .map(|ctx| ctx.relevant_text.clone())
                .unwrap_or_default(),
            audio_path,
            latency_ms,
            tts_engine,
            playback_backend,
            playback_started,
            multimodal_used: screen_context
                .as_ref()
                .map(|ctx| ctx.multimodal_used)
                .unwrap_or(false),
            degraded_modes: dedupe_strings(degraded),
            gpu: self.state.read().await.gpu.clone(),
        })
    }

    pub async fn describe_screen(
        &self,
        ai_manager: &AiManager,
        overlay: &OverlayManager,
        screen_capture: &ScreenCapture,
        memory_plane: &MemoryPlaneManager,
        request: VisionDescribeRequest,
    ) -> Result<VisionDescribeResult> {
        let state = self.refresh_capabilities(ai_manager).await?;
        if state.kill_switch_active {
            anyhow::bail!("sensory kill switch is active");
        }

        let question = request.question.unwrap_or_else(|| {
            "Que ves en mi pantalla? Describe lo relevante y accionable.".to_string()
        });
        let started = Instant::now();
        overlay
            .set_axi_state(AxiState::Watching, Some("vision"))
            .await?;
        let screen_context = self
            .prepare_screen_context(
                ai_manager,
                screen_capture,
                memory_plane,
                request.source.as_deref(),
                question.as_str(),
            )
            .await?;

        let response = if screen_context.multimodal_used {
            multimodal_chat_with_fallback(
                ai_manager,
                &question,
                &screen_context.screen_path,
                Some("Describe the user's screen in concise spoken Spanish. Avoid markdown and never expose internal reasoning."),
            )
            .await?
        } else {
            ai_manager
                .chat(
                    None,
                    vec![
                        (
                            "system".to_string(),
                            "You are Axi. Use OCR context to describe the current screen in spoken Spanish, answer directly, avoid markdown, and do not reveal internal reasoning."
                                .to_string(),
                        ),
                        (
                            "user".to_string(),
                            format!(
                                "{}\n\nOCR:\n{}\n\nRelevant lines:\n{}",
                                question,
                                screen_context.ocr_text,
                                screen_context.relevant_text.join("\n")
                            ),
                        ),
                    ],
                )
                .await?
        };
        let response_text = sanitize_assistant_response(&response.response);

        let mut degraded = degraded_modes(&state.capabilities, &state.gpu);
        let mut audio_path = None;
        if request.speak {
            match synthesize_tts(
                &self.data_dir,
                &response_text,
                request.language.as_deref(),
                request.voice_model.as_deref(),
            )
            .await
            {
                Ok((path, _)) => {
                    audio_path = Some(path.clone());
                    let _ = self
                        .spawn_playback(
                            overlay.clone(),
                            format!("vision-{}", uuid::Uuid::new_v4()),
                            &path,
                        )
                        .await?;
                }
                Err(_) => degraded.push("tts_unavailable".to_string()),
            }
        }

        let latency_ms = started.elapsed().as_millis() as u64;
        {
            let mut state = self.state.write().await;
            state.vision.last_capture_path = Some(screen_context.screen_path.clone());
            state.vision.last_ocr_text = Some(screen_context.ocr_text.clone());
            state.vision.last_relevant_text = screen_context.relevant_text.clone();
            state.vision.last_summary = Some(response_text.clone());
            state.vision.last_query_latency_ms = Some(latency_ms);
            state.vision.last_multimodal_success = screen_context.multimodal_used;
            state.vision.last_updated_at = Some(Utc::now());
            state.axi_state = if request.speak {
                AxiState::Speaking
            } else {
                AxiState::Idle
            };
            state.last_updated_at = Some(Utc::now());
            state.last_error = None;
            state.degraded_modes = dedupe_strings(degraded.clone());
        }
        self.save_state().await?;
        overlay.clear_processing_feedback().await?;
        if !request.speak {
            overlay
                .set_axi_state(AxiState::Idle, Some("vision-ready"))
                .await?;
        }

        Ok(VisionDescribeResult {
            response: response_text,
            screen_path: Some(screen_context.screen_path),
            ocr_text: Some(screen_context.ocr_text),
            relevant_text: screen_context.relevant_text,
            audio_path,
            latency_ms,
            multimodal_used: screen_context.multimodal_used,
            degraded_modes: dedupe_strings(degraded),
        })
    }

    pub async fn run_screen_awareness_cycle(
        &self,
        ai_manager: &AiManager,
        overlay: &OverlayManager,
        screen_capture: &ScreenCapture,
        memory_plane: &MemoryPlaneManager,
        follow_along: Option<&FollowAlongManager>,
    ) -> Result<Option<VisionRuntime>> {
        let state = self.status().await;
        if state.kill_switch_active || !state.vision.enabled {
            return Ok(None);
        }

        // Determine if a window change triggered this capture.
        let window_changed = state
            .vision
            .last_window_change_at
            .map(|change_at| {
                state
                    .vision
                    .last_updated_at
                    .map(|last| change_at > last)
                    .unwrap_or(true)
            })
            .unwrap_or(false);

        // Phase 5: skip OCR if window unchanged and recent OCR exists (<30s).
        let skip_ocr = !window_changed
            && state.vision.last_ocr_text.is_some()
            && state
                .vision
                .last_updated_at
                .map(|t| (Utc::now() - t).num_seconds() < 30)
                .unwrap_or(false);

        let context = if skip_ocr {
            // Capture screenshot but reuse previous OCR.
            let shot = screen_capture.capture().await?;
            ScreenContextResult {
                screen_path: shot.path.to_string_lossy().to_string(),
                ocr_text: state.vision.last_ocr_text.clone().unwrap_or_default(),
                relevant_text: state.vision.last_relevant_text.clone(),
                multimodal_used: state.vision.last_multimodal_success,
            }
        } else {
            self.prepare_screen_context(
                ai_manager,
                screen_capture,
                memory_plane,
                None,
                "Resume brevemente la pantalla actual para memoria operativa.",
            )
            .await?
        };

        let previous_ocr = state.vision.last_ocr_text.unwrap_or_default();
        if !has_meaningful_screen_change(
            &previous_ocr,
            &context.ocr_text,
            &state.vision.last_relevant_text,
            &context.relevant_text,
        ) {
            let mut state = self.state.write().await;
            state.vision.last_capture_path = Some(context.screen_path);
            state.vision.last_ocr_text = Some(context.ocr_text);
            state.vision.last_relevant_text = context.relevant_text;
            state.vision.last_multimodal_success = context.multimodal_used;
            state.vision.last_updated_at = Some(Utc::now());
            state.vision.last_window_change_at = None;
            let snapshot = state.vision.clone();
            drop(state);
            self.save_state().await?;
            return Ok(Some(snapshot));
        }

        // Phase 3: compute importance and build richer context.
        let importance =
            compute_vision_importance(&context.ocr_text, &context.relevant_text, window_changed);

        overlay
            .set_axi_state(AxiState::Watching, Some("awareness"))
            .await?;

        // Only call LLM for high-importance snapshots (saves GPU).
        let summary = if importance >= 65 {
            ai_manager
                .chat(
                    None,
                    vec![
                        (
                            "system".to_string(),
                            "Resume la pantalla actual para la memoria del asistente en una o dos oraciones concisas."
                                .to_string(),
                        ),
                        (
                            "user".to_string(),
                            format!(
                                "App: {}\nVentana: {}\nOCR:\n{}\n\nLineas relevantes:\n{}",
                                state.vision.current_app.as_deref().unwrap_or("unknown"),
                                state.vision.current_window.as_deref().unwrap_or("unknown"),
                                context.ocr_text,
                                context.relevant_text.join("\n")
                            ),
                        ),
                    ],
                )
                .await
                .map(|result| result.response)
                .unwrap_or_else(|_| context.relevant_text.join(" | "))
        } else {
            context.relevant_text.join(" | ")
        };

        let mut tags = vec![
            "vision".to_string(),
            "screen".to_string(),
            "awareness".to_string(),
        ];
        if let Some(ref app) = state.vision.current_app {
            tags.push(format!("app:{}", app));
        }
        if window_changed {
            tags.push("window-change".to_string());
        }

        // Phase 3: structured memory content with app metadata.
        let ocr_excerpt: String = context.ocr_text.chars().take(2048).collect();
        let memory_content = truncate_for_memory(&format!(
            "app: {}\nwindow: {}\nsummary: {}\nrelevant_lines:\n{}\nocr_excerpt:\n{}",
            state.vision.current_app.as_deref().unwrap_or("unknown"),
            state.vision.current_window.as_deref().unwrap_or("unknown"),
            summary,
            context.relevant_text.join("\n"),
            &ocr_excerpt,
        ));
        memory_plane
            .add_entry(
                "vision-snapshot",
                "short-term",
                &tags,
                Some("sensor://screen-awareness"),
                importance,
                &memory_content,
            )
            .await
            .ok();

        let mut state = self.state.write().await;
        state.vision.last_capture_path = Some(context.screen_path);
        state.vision.last_ocr_text = Some(context.ocr_text);
        state.vision.last_relevant_text = context.relevant_text;
        state.vision.last_summary = Some(summary);
        state.vision.last_multimodal_success = context.multimodal_used;
        state.vision.last_updated_at = Some(Utc::now());
        state.vision.last_window_change_at = None;
        state.axi_state = AxiState::Idle;
        let snapshot = state.vision.clone();
        drop(state);
        if let Some(follow_along) = follow_along {
            self.emit_contextual_recommendations(
                overlay,
                follow_along,
                snapshot.last_ocr_text.as_deref().unwrap_or_default(),
                &snapshot.last_relevant_text,
            )
            .await
            .ok();
        }
        overlay
            .set_axi_state(AxiState::Idle, Some("awareness"))
            .await?;
        self.save_state().await?;

        if let Ok(removed) = screen_capture
            .cleanup_by_count(SCREENSHOT_RETENTION_COUNT)
            .await
        {
            if removed > 0 {
                log::info!(
                    "Screen capture retention removed {} files (max={})",
                    removed,
                    SCREENSHOT_RETENTION_COUNT
                );
            }
        }

        if let Ok(removed) = screen_capture.cleanup_old(SCREENSHOT_RETENTION_DAYS).await {
            if removed > 0 {
                log::info!(
                    "Screen capture retention removed {} files older than {} days",
                    removed,
                    SCREENSHOT_RETENTION_DAYS
                );
            }
        }

        // Phase 6: tiered memory retention cleanup.
        if let Err(e) = memory_plane
            .cleanup_vision_entries(VISION_MEMORY_ROUTINE_HOURS, VISION_MEMORY_KEY_DAYS)
            .await
        {
            log::warn!("Vision memory cleanup failed: {}", e);
        }

        Ok(Some(snapshot))
    }

    pub async fn update_presence(
        &self,
        ai_manager: &AiManager,
        overlay: &OverlayManager,
        follow_along: &FollowAlongManager,
        memory_plane: &MemoryPlaneManager,
    ) -> Result<PresenceRuntime> {
        let mut snapshot = self.state.read().await.clone();
        let was_present = snapshot.presence.present;
        let camera_available = snapshot.capabilities.camera_device.is_some();
        let camera_consented = snapshot.presence.camera_consented;
        let meeting_active = snapshot.meeting.active;
        let camera_busy = snapshot.meeting.camera_busy;
        let now = Utc::now();

        // Skip camera capture when in a meeting or camera is busy (another app has it).
        let can_use_camera =
            camera_available && camera_consented && !meeting_active && !camera_busy;

        let (present, face_near_screen, source, frame_path) = if can_use_camera {
            match capture_camera_presence(
                &self.data_dir,
                snapshot.capabilities.camera_capture_binary.as_deref(),
                snapshot.capabilities.camera_device.as_deref(),
            )
            .await
            {
                Ok(metrics) => (
                    metrics.present,
                    metrics.face_near_screen,
                    "camera-heuristic",
                    metrics.frame_path,
                ),
                Err(_) => {
                    let (p, f, s) = presence_from_activity(follow_along).await;
                    (p, f, s, None)
                }
            }
        } else if meeting_active || camera_busy {
            // During a meeting, assume user is present (they're on a call).
            (true, false, "meeting-inferred", None)
        } else {
            let (p, f, s) = presence_from_activity(follow_along).await;
            (p, f, s, None)
        };

        // AI-powered scene analysis when camera captured a frame and multimodal is available.
        let (scene_description, user_state, people_count) = if let Some(ref frame) = frame_path {
            match analyze_camera_scene(ai_manager, frame).await {
                Ok(analysis) => (
                    Some(analysis.scene_description),
                    Some(analysis.user_state),
                    Some(analysis.people_count),
                ),
                Err(_) => (None, None, None),
            }
        } else {
            (None, None, None)
        };

        let stats = follow_along.get_event_stats().await;
        let session_minutes = stats.session_duration.num_minutes().max(0) as u32;
        let fatigue_alert = session_minutes >= 180;
        let posture_alert = session_minutes >= 20 && (face_near_screen || present);

        if present {
            snapshot.presence.last_seen_at = Some(now);
            snapshot.presence.away_seconds = 0;
        } else if let Some(last_seen) = snapshot.presence.last_seen_at {
            snapshot.presence.away_seconds = (now - last_seen).num_seconds().max(0) as u64;
        }

        snapshot.presence.camera_available = camera_available;
        snapshot.presence.present = present;
        snapshot.presence.source = source.to_string();
        snapshot.presence.face_near_screen = face_near_screen;
        snapshot.presence.fatigue_alert = fatigue_alert;
        snapshot.presence.posture_alert = posture_alert;
        snapshot.presence.last_checked_at = Some(now);
        snapshot.presence.scene_description = scene_description.clone();
        snapshot.presence.user_state = user_state.clone();
        snapshot.presence.people_count = people_count;
        snapshot.presence.last_frame_path = frame_path;

        // Store camera context in memory for later recall.
        if let Some(ref desc) = scene_description {
            let importance = if people_count.unwrap_or(0) >= 2 {
                70 // meeting
            } else if user_state.as_deref() == Some("away") {
                40
            } else {
                50
            };
            let mut tags = vec!["camera".to_string(), "presence".to_string()];
            if let Some(ref state_str) = user_state {
                tags.push(format!("state:{}", state_str));
            }
            let memory_content = truncate_for_memory(&format!(
                "scene: {}\nuser_state: {}\npeople: {}",
                desc,
                user_state.as_deref().unwrap_or("unknown"),
                people_count.unwrap_or(0),
            ));
            memory_plane
                .add_entry(
                    "camera-presence",
                    "short-term",
                    &tags,
                    Some("sensor://camera-presence"),
                    importance,
                    &memory_content,
                )
                .await
                .ok();
        }

        if fatigue_alert {
            overlay
                .push_proactive_notification(
                    "low",
                    "Parece que llevas mucho tiempo activo. Considera tomar un descanso breve.",
                )
                .await
                .ok();
        }
        if posture_alert {
            overlay
                .push_proactive_notification(
                    "low",
                    "Detecte una postura exigente frente a la pantalla. Ajusta la distancia o endereza la espalda.",
                )
                .await
                .ok();
        }

        {
            let mut state = self.state.write().await;
            state.presence = snapshot.presence.clone();
            if !present && state.presence.away_seconds >= 300 {
                state.axi_state = if is_night_window(now) {
                    AxiState::Night
                } else {
                    AxiState::Offline
                };
            } else if matches!(state.axi_state, AxiState::Offline | AxiState::Night) && present {
                state.axi_state = AxiState::Idle;
            }
        }
        if !was_present && present {
            overlay
                .push_proactive_notification(
                    "low",
                    "Bienvenido de vuelta. Puedo resumirte lo relevante de lo que detecte en pantalla.",
                )
                .await
                .ok();
            overlay
                .set_axi_state(AxiState::Idle, Some("welcome-back"))
                .await
                .ok();
        } else if !present && snapshot.presence.away_seconds >= 300 {
            let target_state = if is_night_window(now) {
                AxiState::Night
            } else {
                AxiState::Offline
            };
            overlay
                .set_axi_state(target_state, Some("presence-away"))
                .await
                .ok();
        }
        self.save_state().await?;
        Ok(snapshot.presence)
    }

    pub async fn benchmark(
        &self,
        ai_manager: &AiManager,
        overlay: &OverlayManager,
        screen_capture: &ScreenCapture,
        memory_plane: &MemoryPlaneManager,
        telemetry: &TelemetryManager,
        request: SensoryBenchmarkRequest,
    ) -> Result<SensoryBenchmarkReport> {
        let repeats = request.repeats.clamp(1, 5);
        let mut entries = Vec::new();

        for iteration in 1..=repeats {
            let voice_result = self
                .run_voice_loop(
                    ai_manager,
                    overlay,
                    screen_capture,
                    memory_plane,
                    telemetry,
                    VoiceLoopRequest {
                        audio_file: request.audio_file.clone(),
                        prompt: request.prompt.clone().or_else(|| {
                            Some("Hey Axi, dame un resumen corto del sistema.".to_string())
                        }),
                        include_screen: false,
                        screen_source: None,
                        language: Some("es".to_string()),
                        voice_model: None,
                        playback: true,
                    },
                )
                .await
                .ok();

            let vision_result = if request.include_screen || request.screen_source.is_some() {
                self.describe_screen(
                    ai_manager,
                    overlay,
                    screen_capture,
                    memory_plane,
                    VisionDescribeRequest {
                        source: request.screen_source.clone(),
                        capture_screen: request.screen_source.is_none(),
                        speak: false,
                        question: Some("Que es lo mas importante en esta pantalla?".to_string()),
                        language: Some("es".to_string()),
                        voice_model: None,
                    },
                )
                .await
                .ok()
            } else {
                None
            };

            entries.push(SensoryBenchmarkEntry {
                iteration,
                voice_loop_latency_ms: voice_result.as_ref().map(|result| result.latency_ms),
                vision_query_latency_ms: vision_result.as_ref().map(|result| result.latency_ms),
                gpu_tokens_per_second: voice_result
                    .as_ref()
                    .and_then(|result| result.gpu.tokens_per_second),
                degraded_modes: dedupe_strings(
                    voice_result
                        .as_ref()
                        .map(|result| result.degraded_modes.clone())
                        .unwrap_or_default(),
                ),
            });
        }

        let report = SensoryBenchmarkReport {
            generated_at: Utc::now(),
            repeats,
            avg_voice_loop_latency_ms: average_u64(
                entries.iter().filter_map(|e| e.voice_loop_latency_ms),
            ),
            avg_vision_query_latency_ms: average_u64(
                entries.iter().filter_map(|e| e.vision_query_latency_ms),
            ),
            avg_gpu_tokens_per_second: average_f32(
                entries.iter().filter_map(|e| e.gpu_tokens_per_second),
            ),
            entries,
        };

        let benchmark_path = self.data_dir.join(BENCHMARK_FILE);
        tokio::fs::write(&benchmark_path, serde_json::to_string_pretty(&report)?)
            .await
            .context("Failed to persist sensory benchmark report")?;
        Ok(report)
    }

    async fn emit_contextual_recommendations(
        &self,
        overlay: &OverlayManager,
        follow_along: &FollowAlongManager,
        ocr_text: &str,
        relevant_text: &[String],
    ) -> Result<()> {
        let context = follow_along.get_context().await;
        let app_hint = format!(
            "{} {}",
            context.current_application.unwrap_or_default(),
            context.current_window.unwrap_or_default()
        )
        .to_lowercase();
        let joined = format!(
            "{}\n{}",
            ocr_text.to_lowercase(),
            relevant_text.join("\n").to_lowercase()
        );

        if contains_error_like_text(&joined) {
            overlay
                .push_proactive_notification(
                    "medium",
                    "Detecte un error o warning relevante en pantalla. Puedo resumirlo si abres Axi.",
                )
                .await?;
            return Ok(());
        }

        if looks_like_code_context(&app_hint, &joined) {
            overlay
                .push_proactive_notification(
                    "low",
                    "Veo codigo activo en pantalla. Puedo explicar el bloque actual o sugerir el siguiente cambio.",
                )
                .await?;
            return Ok(());
        }

        if looks_like_document_context(&app_hint, &joined) {
            overlay
                .push_proactive_notification(
                    "low",
                    "Hay un documento abierto. Puedo darte un resumen corto o extraer puntos clave.",
                )
                .await?;
        }

        Ok(())
    }

    async fn prepare_screen_context(
        &self,
        ai_manager: &AiManager,
        screen_capture: &ScreenCapture,
        memory_plane: &MemoryPlaneManager,
        explicit_source: Option<&str>,
        query: &str,
    ) -> Result<ScreenContextResult> {
        let screen_path = if let Some(source) = explicit_source
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            source.to_string()
        } else {
            let shot = screen_capture.capture().await?;
            shot.path.to_string_lossy().to_string()
        };

        let ocr_lang = detect_ocr_languages();
        let ocr_text = extract_ocr(&screen_path, Some(&ocr_lang))
            .await
            .unwrap_or_default();
        let relevant_text = relevant_ocr_lines(&ocr_text, query);
        let multimodal_used = if let Some(model) = ai_manager.active_model().await {
            model.to_lowercase().contains("qwen")
        } else {
            false
        };

        let tags = vec!["screen".to_string(), "ocr".to_string()];
        let memory_content = truncate_for_memory(&format!(
            "query: {}\nocr:\n{}\nrelevant:\n{}",
            query,
            ocr_text,
            relevant_text.join("\n")
        ));
        memory_plane
            .add_entry(
                "screen-ocr",
                "user",
                &tags,
                Some("sensor://screen-ocr"),
                45,
                &memory_content,
            )
            .await
            .ok();

        Ok(ScreenContextResult {
            screen_path,
            ocr_text,
            relevant_text,
            multimodal_used,
        })
    }

    async fn spawn_playback(
        &self,
        overlay: OverlayManager,
        session_id: String,
        audio_path: &str,
    ) -> Result<(Option<String>, bool)> {
        let player = resolve_binary("LIFEOS_PLAYBACK_BIN", &["pw-play", "aplay", "paplay"]).await;
        let Some(player) = player else {
            return Ok((None, false));
        };

        let mut child = Command::new(&player)
            .arg(audio_path)
            .spawn()
            .with_context(|| format!("Failed to start playback backend {}", player))?;

        let Some(pid) = child.id() else {
            return Ok((Some(player), false));
        };

        {
            let mut playback = self.playback.lock().await;
            *playback = Some(ActivePlayback {
                session_id: session_id.clone(),
                pid,
                backend: player.clone(),
                audio_path: audio_path.to_string(),
            });
        }

        let manager = self.clone();
        let audio_path_owned = audio_path.to_string();
        tokio::spawn(async move {
            let _ = child.wait().await;
            let mut playback = manager.playback.lock().await;
            if playback
                .as_ref()
                .map(|active| active.session_id == session_id)
                .unwrap_or(false)
            {
                playback.take();
                drop(playback);
                {
                    let mut state = manager.state.write().await;
                    state.voice.active = false;
                    state.voice.last_audio_path = Some(audio_path_owned);
                    if !state.kill_switch_active {
                        state.axi_state = AxiState::Idle;
                    }
                    state.last_updated_at = Some(Utc::now());
                }
                let _ = manager.save_state().await;
                let _ = overlay
                    .set_axi_state(AxiState::Idle, Some("playback"))
                    .await;
                let _ = overlay.clear_processing_feedback().await;
            }
        });

        Ok((Some(player), true))
    }

    /// Synthesize and play response text progressively, sentence by sentence.
    ///
    /// Flow:
    /// 1. Split response into spoken sentences.
    /// 2. Synthesize sentence 1 → start playback.
    /// 3. While sentence 1 plays, synthesize sentence 2 in parallel.
    /// 4. When sentence 1 finishes → play sentence 2 (already ready).
    /// 5. Repeat until all sentences are spoken.
    ///
    /// Falls back to the old single-shot path if progressive synthesis fails.
    async fn synthesize_and_play_progressive(
        &self,
        _overlay: &OverlayManager,
        session_id: &str,
        text: &str,
        language: Option<&str>,
        voice_model: Option<&str>,
    ) -> Result<(Option<String>, Option<String>, Option<String>, bool)> {
        let sentences = split_tts_chunks(text);
        if sentences.is_empty() {
            return Ok((None, None, None, false));
        }

        // Resolve TTS toolchain once.
        let piper_models = resolve_tts_models(voice_model).await;
        let fallback_binary = resolve_binary("LIFEOS_TTS_FALLBACK_BIN", &["espeak-ng"]).await;
        let binary = select_tts_binary(
            resolve_binary("LIFEOS_TTS_BIN", &["lifeos-piper", "piper", "espeak-ng"]).await,
            piper_models.first().map(|v| v.as_str()),
            fallback_binary.clone(),
        );
        let binary = sanitize_tts_binary(binary, fallback_binary.clone())
            .await
            .ok_or_else(|| anyhow::anyhow!("no local TTS backend found"))?;

        let player = resolve_binary("LIFEOS_PLAYBACK_BIN", &["pw-play", "aplay", "paplay"])
            .await
            .ok_or_else(|| anyhow::anyhow!("no playback backend found"))?;

        // Duck system audio before speaking.
        duck_system_audio(true).await;

        let mut first_audio_path: Option<String> = None;
        let tts_engine = binary.clone();
        let playback_backend = player.clone();
        let mut any_played = false;

        // Pre-synthesize the first sentence.
        let mut next_audio = synthesize_single_chunk(
            &self.data_dir,
            &binary,
            &sentences[0],
            language,
            piper_models.first().map(|v| v.as_str()),
        )
        .await
        .ok();

        for i in 0..sentences.len() {
            let current_audio = match next_audio.take() {
                Some(path) => path,
                None => continue,
            };

            if first_audio_path.is_none() {
                first_audio_path = Some(current_audio.clone());
            }

            // Start synthesizing the NEXT sentence in the background.
            let next_synth = if i + 1 < sentences.len() {
                let data_dir = self.data_dir.clone();
                let bin = binary.clone();
                let sent = sentences[i + 1].clone();
                let lang = language.map(str::to_string);
                let model = piper_models.first().cloned();
                Some(tokio::spawn(async move {
                    synthesize_single_chunk(
                        &data_dir,
                        &bin,
                        &sent,
                        lang.as_deref(),
                        model.as_deref(),
                    )
                    .await
                    .ok()
                }))
            } else {
                None
            };

            // Play the current sentence (blocking until done).
            let mut child = Command::new(&player)
                .arg(&current_audio)
                .spawn()
                .context("Failed to start playback")?;

            if let Some(pid) = child.id() {
                let mut playback = self.playback.lock().await;
                *playback = Some(ActivePlayback {
                    session_id: session_id.to_string(),
                    pid,
                    backend: player.clone(),
                    audio_path: current_audio.clone(),
                });
            }
            any_played = true;
            let _ = child.wait().await;

            // Check if we were interrupted (barge-in).
            let was_interrupted = {
                let pb = self.playback.lock().await;
                pb.as_ref()
                    .map(|active| active.session_id != session_id)
                    .unwrap_or(true)
            };
            if was_interrupted {
                // User interrupted — stop progressive playback.
                if let Some(handle) = next_synth {
                    handle.abort();
                }
                break;
            }

            // Collect the pre-synthesized next sentence.
            if let Some(handle) = next_synth {
                next_audio = handle.await.ok().flatten();
            }
        }

        // Clear playback slot.
        {
            let mut pb = self.playback.lock().await;
            if pb
                .as_ref()
                .map(|a| a.session_id == session_id)
                .unwrap_or(false)
            {
                pb.take();
            }
        }

        // Restore system audio.
        duck_system_audio(false).await;

        Ok((
            first_audio_path,
            Some(tts_engine),
            Some(playback_backend),
            any_played,
        ))
    }

    fn state_path(&self) -> PathBuf {
        self.data_dir.join(STATE_FILE)
    }

    async fn load_state(&self) -> Result<()> {
        let path = self.state_path();
        if !path.exists() {
            return Ok(());
        }

        let raw = tokio::fs::read_to_string(&path)
            .await
            .context("Failed to read sensory pipeline state")?;
        let state: SensoryPipelineState =
            serde_json::from_str(&raw).context("Failed to parse sensory pipeline state")?;
        *self.state.write().await = state;
        Ok(())
    }

    async fn save_state(&self) -> Result<()> {
        let path = self.state_path();
        let raw = serde_json::to_string_pretty(&*self.state.read().await)
            .context("Failed to serialize sensory pipeline state")?;
        write_atomic(&path, &raw)
            .await
            .context("Failed to persist sensory pipeline state")?;
        Ok(())
    }
}

async fn write_atomic(path: &PathBuf, contents: &str) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("Missing parent directory for {}", path.display()))?;
    let tmp_path = parent.join(format!(
        ".{}.tmp",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("sensory-pipeline-state")
    ));
    tokio::fs::write(&tmp_path, contents).await?;
    tokio::fs::rename(&tmp_path, path).await?;
    Ok(())
}

async fn detect_capabilities(ai_manager: &AiManager) -> SensoryCapabilities {
    let preferred_tts_binary =
        resolve_binary("LIFEOS_TTS_BIN", &["lifeos-piper", "piper", "espeak-ng"]).await;
    let tts_model = resolve_tts_model(None).await;
    let fallback_tts_binary = resolve_binary("LIFEOS_TTS_FALLBACK_BIN", &["espeak-ng"]).await;
    let tts_binary = select_tts_binary(
        preferred_tts_binary,
        tts_model.as_deref(),
        fallback_tts_binary.clone(),
    );
    let tts_binary = sanitize_tts_binary(tts_binary, fallback_tts_binary).await;

    SensoryCapabilities {
        stt_binary: resolve_binary("LIFEOS_STT_BIN", &["whisper-cli", "whisper", "whisper-cpp"])
            .await,
        audio_capture_binary: resolve_binary(
            "LIFEOS_AUDIO_CAPTURE_BIN",
            &["ffmpeg", "arecord", "pw-record", "parecord"],
        )
        .await,
        tts_binary,
        tts_model,
        playback_binary: resolve_binary("LIFEOS_PLAYBACK_BIN", &["pw-play", "aplay", "paplay"])
            .await,
        screen_capture_available: true,
        tesseract_available: resolve_binary("LIFEOS_TESSERACT_BIN", &["tesseract"])
            .await
            .is_some(),
        multimodal_chat_available: ai_manager.is_running().await,
        camera_device: resolve_camera_device(),
        camera_capture_binary: resolve_binary(
            "LIFEOS_CAMERA_CAPTURE_BIN",
            &["ffmpeg", "libcamera-still", "libcamera-jpeg", "fswebcam"],
        )
        .await,
        llama_server_running: ai_manager.is_running().await,
        always_on_source: resolve_always_on_source().await,
        rustpotter_model_available: Path::new(crate::wake_word::RUSTPOTTER_MODEL_PATH).exists(),
    }
}

async fn detect_gpu_status(previous_tokens_per_second: Option<f32>) -> GpuOffloadStatus {
    let active_gpu_layers = read_gpu_layers().unwrap_or(0);
    let runtime_backend = detect_llama_runtime_backend().await;
    let runtime_gpu_failure = detect_llama_runtime_gpu_failure().await;

    if let Ok(output) = Command::new("nvidia-smi")
        .args([
            "--query-gpu=name,memory.total,memory.free,temperature.gpu,utilization.gpu",
            "--format=csv,noheader,nounits",
        ])
        .output()
        .await
    {
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            if let Some(line) = stdout.lines().next() {
                let parts: Vec<&str> = line.split(',').map(|part| part.trim()).collect();
                if parts.len() >= 5 {
                    let name = Some(parts[0].to_string());
                    let total_vram_gb = parts[1].parse::<u32>().ok().map(|mb| mb / 1024);
                    let free_vram_gb = parts[2].parse::<u32>().ok().map(|mb| mb / 1024);
                    let gpu_temp_celsius = parts[3].parse::<f32>().ok();
                    let utilization = parts[4].parse::<u32>().ok().unwrap_or_default();
                    if !runtime_backend
                        .as_deref()
                        .map(gpu_backend_supports_offload)
                        .unwrap_or(false)
                    {
                        return GpuOffloadStatus {
                            gpu_name: name,
                            total_vram_gb,
                            free_vram_gb,
                            active_gpu_layers,
                            tokens_per_second: previous_tokens_per_second,
                            gpu_temp_celsius,
                            throttling: gpu_temp_celsius.map(|temp| temp >= 86.0).unwrap_or(false),
                            updated_at: Some(Utc::now()),
                            rebalance_reason: Some(
                                runtime_backend
                                    .map(|backend| {
                                        format!("llama_runtime_backend_unsupported:{backend}")
                                    })
                                    .unwrap_or_else(|| {
                                        "llama_runtime_gpu_backend_missing".to_string()
                                    }),
                            ),
                            ..GpuOffloadStatus::default()
                        };
                    }
                    if let Some(reason) = runtime_gpu_failure.clone() {
                        let mut profile = gpu_policy_for_vram(free_vram_gb, 0);
                        profile.backend =
                            runtime_backend.clone().unwrap_or_else(|| "cpu".to_string());
                        profile.gpu_name = name;
                        profile.total_vram_gb = total_vram_gb;
                        profile.free_vram_gb = free_vram_gb;
                        profile.gpu_temp_celsius = gpu_temp_celsius;
                        profile.throttling =
                            gpu_temp_celsius.map(|temp| temp >= 86.0).unwrap_or(false);
                        profile.updated_at = Some(Utc::now());
                        profile.tokens_per_second = previous_tokens_per_second;
                        profile.active_gpu_layers = active_gpu_layers;
                        profile.rebalance_reason = Some(reason);
                        return profile;
                    }
                    let mut profile = gpu_policy_for_vram(free_vram_gb, active_gpu_layers);
                    profile.backend = runtime_backend
                        .clone()
                        .unwrap_or_else(|| "nvidia".to_string());
                    profile.gpu_name = name;
                    profile.total_vram_gb = total_vram_gb;
                    profile.free_vram_gb = free_vram_gb;
                    profile.gpu_temp_celsius = gpu_temp_celsius;
                    profile.throttling = gpu_temp_celsius.map(|temp| temp >= 86.0).unwrap_or(false);
                    profile.updated_at = Some(Utc::now());
                    profile.tokens_per_second = previous_tokens_per_second;
                    if utilization >= 90 && free_vram_gb.unwrap_or(0) <= 2 {
                        profile.rebalance_reason = Some("gpu_pressure_detected".to_string());
                        profile.recommended_gpu_layers = profile.recommended_gpu_layers.min(20);
                    }
                    return profile;
                }
            }
        }
    }

    GpuOffloadStatus {
        active_gpu_layers,
        tokens_per_second: previous_tokens_per_second,
        updated_at: Some(Utc::now()),
        ..GpuOffloadStatus::default()
    }
}

async fn maybe_apply_gpu_rebalance(
    status: &mut GpuOffloadStatus,
    llama_server_running: bool,
) -> Result<()> {
    let target_layers = if gpu_backend_supports_offload(&status.backend) {
        status.recommended_gpu_layers
    } else {
        0
    };

    if status.active_gpu_layers == target_layers {
        return Ok(());
    }

    if persist_gpu_layers(target_layers)? {
        status.active_gpu_layers = target_layers;
        if status.rebalance_reason.is_none() {
            status.rebalance_reason = Some("runtime_profile_sync".to_string());
        }

        if llama_server_running {
            Command::new("systemctl")
                .args(["try-restart", "llama-server.service"])
                .status()
                .await
                .ok();
        }
    }

    Ok(())
}

fn gpu_policy_for_vram(free_vram_gb: Option<u32>, active_gpu_layers: i32) -> GpuOffloadStatus {
    let vram = free_vram_gb.unwrap_or_default();
    let (
        profile_tier,
        llm_offload,
        vision_offload,
        tts_offload,
        stt_offload,
        recommended_gpu_layers,
    ) = match vram {
        0..=3 => ("cpu_only", "cpu only", "cpu only", "cpu", "cpu", 0),
        4..=5 => (
            "4gb_partial",
            "partial (50% layers GPU)",
            "cpu only",
            "cpu",
            "cpu",
            20,
        ),
        6..=7 => ("6gb_full_llm", "full gpu", "cpu only", "cpu", "cpu", -1),
        8..=12 => (
            "8gb_full_multimodal",
            "full gpu",
            "full gpu",
            "cpu",
            "cpu/npu",
            -1,
        ),
        _ => (
            "12gb_plus",
            "full gpu",
            "full gpu",
            "gpu if supported",
            "cpu/npu",
            -1,
        ),
    };

    GpuOffloadStatus {
        backend: if vram >= 4 {
            "nvidia".to_string()
        } else {
            "cpu".to_string()
        },
        profile_tier: profile_tier.to_string(),
        llm_offload: llm_offload.to_string(),
        vision_offload: vision_offload.to_string(),
        tts_offload: tts_offload.to_string(),
        stt_offload: stt_offload.to_string(),
        recommended_gpu_layers,
        active_gpu_layers,
        rebalance_reason: None,
        ..GpuOffloadStatus::default()
    }
}

fn degraded_modes(capabilities: &SensoryCapabilities, gpu: &GpuOffloadStatus) -> Vec<String> {
    let mut degraded = Vec::new();
    if gpu.backend == "cpu" || gpu.active_gpu_layers == 0 || gpu.llm_offload == "cpu only" {
        degraded.push("cpu_only_llm".to_string());
    }
    if capabilities.stt_binary.is_none() {
        degraded.push("stt_unavailable".to_string());
    }
    if capabilities.audio_capture_binary.is_none() {
        degraded.push("mic_capture_unavailable".to_string());
    }
    if capabilities.tts_binary.is_none()
        || (tts_binary_requires_model(capabilities.tts_binary.as_deref())
            && capabilities.tts_model.is_none())
    {
        degraded.push("tts_unavailable".to_string());
    }
    if capabilities.camera_device.is_none() {
        degraded.push("camera_unavailable".to_string());
    }
    if !capabilities.tesseract_available {
        degraded.push("ocr_unavailable".to_string());
    }
    dedupe_strings(degraded)
}

async fn transcribe_audio(file: &str, model: Option<&str>) -> Result<(String, String)> {
    let binary = resolve_binary("LIFEOS_STT_BIN", &["whisper-cli", "whisper", "whisper-cpp"])
        .await
        .ok_or_else(|| anyhow::anyhow!("no whisper.cpp binary found"))?;
    let resolved_model = resolve_stt_model(model).await;

    let mut cmd = Command::new(&binary);
    if let Some(model) = resolved_model {
        cmd.arg("-m").arg(model);
    }
    // Auto-detect language from system locale for better wake word recognition.
    let lang = std::env::var("LIFEOS_STT_LANG").unwrap_or_else(|_| {
        std::env::var("LANG")
            .unwrap_or_default()
            .split('_')
            .next()
            .unwrap_or("es")
            .to_string()
    });
    if !lang.is_empty() && lang != "C" && lang != "POSIX" {
        cmd.args(["-l", &lang]);
    }
    cmd.args(["-f", file]);
    let output = cmd
        .output()
        .await
        .with_context(|| format!("Failed to execute {}", binary))?;
    if !output.status.success() {
        anyhow::bail!(
            "stt transcription failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }

    let mut text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if text.is_empty() {
        text = String::from_utf8_lossy(&output.stderr).trim().to_string();
    }
    Ok((text, binary))
}

async fn extract_ocr(source_path: &str, language: Option<&str>) -> Result<String> {
    let binary = resolve_binary("LIFEOS_TESSERACT_BIN", &["tesseract"])
        .await
        .ok_or_else(|| anyhow::anyhow!("tesseract not found"))?;
    let lang = language.unwrap_or("eng");
    let output = Command::new(&binary)
        .arg(source_path)
        .arg("stdout")
        .args(["-l", lang])
        .output()
        .await
        .with_context(|| format!("Failed to execute {}", binary))?;
    if !output.status.success() {
        anyhow::bail!(
            "ocr failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Detect OCR languages from system locale.
fn detect_ocr_languages() -> String {
    let lang = std::env::var("LANG").unwrap_or_default().to_lowercase();
    if lang.starts_with("es") {
        "eng+spa".to_string()
    } else if lang.starts_with("pt") {
        "eng+por".to_string()
    } else if lang.starts_with("fr") {
        "eng+fra".to_string()
    } else if lang.starts_with("de") {
        "eng+deu".to_string()
    } else {
        "eng".to_string()
    }
}

/// Poll the active window from the Wayland compositor.
///
/// Tries swaymsg (works on COSMIC/Sway) then hyprctl as fallback.
/// Returns `(app_id, window_title)`.
async fn poll_active_window() -> Result<(String, String)> {
    // Try swaymsg first (COSMIC/Sway).
    if let Ok(output) = Command::new("swaymsg")
        .args(["-t", "get_tree"])
        .output()
        .await
    {
        if output.status.success() {
            let json_str = String::from_utf8_lossy(&output.stdout);
            if let Ok(tree) = serde_json::from_str::<serde_json::Value>(&json_str) {
                if let Some((app, title)) = find_focused_node(&tree) {
                    return Ok((app, title));
                }
            }
        }
    }

    // Fallback: hyprctl.
    if let Ok(output) = Command::new("hyprctl")
        .args(["activewindow", "-j"])
        .output()
        .await
    {
        if output.status.success() {
            let json_str = String::from_utf8_lossy(&output.stdout);
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(&json_str) {
                let class = val["class"].as_str().unwrap_or("unknown").to_string();
                let title = val["title"].as_str().unwrap_or("").to_string();
                return Ok((class, title));
            }
        }
    }

    anyhow::bail!("no compositor window info available")
}

/// Recursively find the focused node in a swaymsg tree.
fn find_focused_node(node: &serde_json::Value) -> Option<(String, String)> {
    if node["focused"].as_bool() == Some(true) && node["type"].as_str() == Some("con") {
        let app = node["app_id"]
            .as_str()
            .or_else(|| node["window_properties"]["class"].as_str())
            .unwrap_or("unknown")
            .to_string();
        let title = node["name"].as_str().unwrap_or("").to_string();
        return Some((app, title));
    }
    if let Some(nodes) = node["nodes"].as_array() {
        for child in nodes {
            if let Some(result) = find_focused_node(child) {
                return Some(result);
            }
        }
    }
    if let Some(nodes) = node["floating_nodes"].as_array() {
        for child in nodes {
            if let Some(result) = find_focused_node(child) {
                return Some(result);
            }
        }
    }
    None
}

/// Compute importance score for a vision snapshot.
fn compute_vision_importance(
    ocr_text: &str,
    relevant_lines: &[String],
    window_changed: bool,
) -> u8 {
    let mut score: u8 = 35;
    let lower = ocr_text.to_lowercase();

    if window_changed {
        score = score.saturating_add(20);
    }
    if lower.contains("error") || lower.contains("failed") || lower.contains("panic") {
        score = score.saturating_add(25);
    }
    if lower.contains("warning") {
        score = score.saturating_add(10);
    }
    if relevant_lines.len() >= 4 {
        score = score.saturating_add(5);
    }
    score.min(100)
}

async fn multimodal_chat_with_fallback(
    ai_manager: &AiManager,
    prompt: &str,
    screen_path: &str,
    system_context: Option<&str>,
) -> Result<AiChatResponse> {
    match ai_manager
        .chat_multimodal(None, system_context, prompt, screen_path)
        .await
    {
        Ok(response) => Ok(response),
        Err(_) => {
            ai_manager
                .chat(
                    None,
                    vec![
                        (
                            "system".to_string(),
                            system_context
                                .unwrap_or(
                                    "You are Axi. Use OCR guidance when images are unavailable.",
                                )
                                .to_string(),
                        ),
                        (
                            "user".to_string(),
                            format!("{}\n\nImage path: {}", prompt, screen_path),
                        ),
                    ],
                )
                .await
        }
    }
}

async fn synthesize_tts(
    data_dir: &Path,
    text: &str,
    language: Option<&str>,
    voice_model: Option<&str>,
) -> Result<(String, String)> {
    let tts_text = prepare_tts_text(text);
    let piper_models = resolve_tts_models(voice_model).await;
    let fallback_binary = resolve_binary("LIFEOS_TTS_FALLBACK_BIN", &["espeak-ng"]).await;
    let binary = select_tts_binary(
        resolve_binary("LIFEOS_TTS_BIN", &["lifeos-piper", "piper", "espeak-ng"]).await,
        piper_models.first().map(|value| value.as_str()),
        fallback_binary.clone(),
    );
    let binary = sanitize_tts_binary(binary, fallback_binary.clone())
        .await
        .ok_or_else(|| anyhow::anyhow!("no local TTS backend found"))?;

    if binary_basename(&binary) == "espeak-ng" {
        let audio_path = synthesize_with_espeak(data_dir, &binary, &tts_text, language).await?;
        return Ok((audio_path, binary));
    }

    let mut piper_errors = Vec::new();
    for model in piper_models {
        match synthesize_with_piper(data_dir, &binary, &tts_text, &model).await {
            Ok(audio_path) => return Ok((audio_path, binary.clone())),
            Err(err) => {
                log::warn!("Piper synthesis failed with model {}: {}", model, err);
                piper_errors.push(format!("{model}: {err}"));
            }
        }
    }

    if let Some(fallback_binary) = fallback_binary {
        let audio_path =
            synthesize_with_espeak(data_dir, &fallback_binary, &tts_text, language).await?;
        return Ok((audio_path, fallback_binary));
    };

    if !piper_errors.is_empty() {
        anyhow::bail!(
            "piper synthesis failed for all configured models: {}",
            piper_errors.join(" | ")
        );
    }

    anyhow::bail!("no Piper voice model configured");
}

async fn synthesize_with_piper(
    data_dir: &Path,
    binary: &str,
    text: &str,
    model: &str,
) -> Result<String> {
    let tts_dir = data_dir.join("tts");
    tokio::fs::create_dir_all(&tts_dir)
        .await
        .context("Failed to create TTS output dir")?;
    let audio_path = tts_dir.join(format!("axi-{}.wav", uuid::Uuid::new_v4()));

    let mut child = Command::new(binary)
        .args([
            "--model",
            model,
            "--output_file",
            audio_path.to_string_lossy().as_ref(),
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .with_context(|| format!("Failed to start Piper via {}", binary))?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(text.trim().as_bytes())
            .await
            .context("Failed to send text to Piper stdin")?;
    }

    let output = child
        .wait_with_output()
        .await
        .context("Failed to wait for Piper output")?;
    if !output.status.success() {
        anyhow::bail!(
            "piper synthesis failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }

    cleanup_dir_by_count(&tts_dir, TTS_RETENTION_COUNT, "tts")
        .await
        .ok();
    Ok(audio_path.to_string_lossy().to_string())
}

async fn synthesize_with_espeak(
    data_dir: &Path,
    binary: &str,
    text: &str,
    language: Option<&str>,
) -> Result<String> {
    let tts_dir = data_dir.join("tts");
    tokio::fs::create_dir_all(&tts_dir)
        .await
        .context("Failed to create TTS output dir")?;
    let audio_path = tts_dir.join(format!("axi-{}.wav", uuid::Uuid::new_v4()));
    let voice = espeak_voice_for_language(language);

    let output = Command::new(binary)
        .args([
            "-w",
            audio_path.to_string_lossy().as_ref(),
            "-v",
            voice,
            text.trim(),
        ])
        .output()
        .await
        .with_context(|| format!("Failed to start espeak-ng via {}", binary))?;
    if !output.status.success() {
        anyhow::bail!(
            "espeak-ng synthesis failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }

    cleanup_dir_by_count(&tts_dir, TTS_RETENTION_COUNT, "tts")
        .await
        .ok();
    Ok(audio_path.to_string_lossy().to_string())
}

/// Synthesize a single text chunk to a WAV file. Used by progressive playback.
async fn synthesize_single_chunk(
    data_dir: &Path,
    binary: &str,
    text: &str,
    language: Option<&str>,
    piper_model: Option<&str>,
) -> Result<String> {
    if binary_basename(binary) == "espeak-ng" {
        return synthesize_with_espeak(data_dir, binary, text, language).await;
    }
    if let Some(model) = piper_model {
        return synthesize_with_piper(data_dir, binary, text, model).await;
    }
    anyhow::bail!("no TTS model available for progressive synthesis")
}

/// Split response text into sentence-level chunks suitable for progressive TTS.
fn split_tts_chunks(raw: &str) -> Vec<String> {
    let cleaned = sanitize_assistant_response(raw);
    let base = if cleaned.is_empty() {
        normalize_whitespace(raw)
    } else {
        cleaned
    };
    let sentences = split_spoken_sentences(&base);

    // Group very short sentences together (avoid choppy playback for fragments).
    let mut chunks = Vec::new();
    let mut current = String::new();
    for sentence in sentences {
        if sentence.is_empty() {
            continue;
        }
        if !current.is_empty() && current.len() + sentence.len() + 1 > TTS_CHUNK_MAX_CHARS {
            chunks.push(current.trim().to_string());
            current.clear();
        }
        if !current.is_empty() {
            current.push(' ');
        }
        current.push_str(&sentence);
    }
    if !current.trim().is_empty() {
        chunks.push(current.trim().to_string());
    }
    chunks
}

/// Lower or restore system audio volume via PulseAudio/PipeWire.
///
/// When `duck` is true, saves the current sink name + volume and sets it to 30%.
/// When `duck` is false, restores the saved volume ONLY if the same sink is still active.
/// This prevents volume corruption when the user switches audio devices (e.g. BT headphones).
async fn duck_system_audio(duck: bool) {
    /// File used to persist the original sink name and volume between duck and restore calls.
    /// Format: "sink_name\nvolume_percent"
    const DUCK_VOLUME_FILE: &str = "/tmp/lifeos-duck-volume";

    // Never duck during an active call — it would lower the call's audio.
    if duck && detect_active_meeting().await.is_some() {
        log::info!("Skipping audio ducking — meeting/call detected");
        return;
    }

    // Helper: get the current default sink name
    async fn get_default_sink() -> Option<String> {
        let output = Command::new("pactl")
            .args(["get-default-sink"])
            .output()
            .await
            .ok()?;
        if output.status.success() {
            let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !name.is_empty() {
                return Some(name);
            }
        }
        None
    }

    // Helper: get current volume percentage of the default sink
    async fn get_sink_volume() -> Option<u32> {
        let output = Command::new("pactl")
            .args(["get-sink-volume", "@DEFAULT_SINK@"])
            .output()
            .await
            .ok()?;
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            return stdout
                .split('/')
                .find(|part| part.trim().ends_with('%'))
                .and_then(|part| part.trim().strip_suffix('%'))
                .and_then(|val| val.trim().parse::<u32>().ok());
        }
        None
    }

    if duck {
        let sink_name = get_default_sink().await.unwrap_or_default();
        if let Some(pct) = get_sink_volume().await {
            // Only duck if the volume is above the duck level.
            if pct > 30 {
                let save_data = format!("{}\n{}", sink_name, pct);
                let _ = tokio::fs::write(DUCK_VOLUME_FILE, save_data).await;
                let _ = Command::new("pactl")
                    .args(["set-sink-volume", "@DEFAULT_SINK@", "30%"])
                    .output()
                    .await;
            }
        }
    } else {
        // Restore to the saved volume — but only if the same sink is still the default.
        // If the user switched to a different device (e.g. BT headphones), do NOT touch volume.
        if let Ok(saved) = tokio::fs::read_to_string(DUCK_VOLUME_FILE).await {
            let mut lines = saved.trim().lines();
            let saved_sink = lines.next().unwrap_or("").trim();
            let saved_pct = lines.next().unwrap_or("").trim();

            if !saved_sink.is_empty() && !saved_pct.is_empty() {
                let current_sink = get_default_sink().await.unwrap_or_default();

                if current_sink == saved_sink {
                    // Same sink — safe to restore volume
                    let _ = Command::new("pactl")
                        .args([
                            "set-sink-volume",
                            "@DEFAULT_SINK@",
                            &format!("{}%", saved_pct),
                        ])
                        .output()
                        .await;
                } else {
                    log::info!(
                        "Audio sink changed ({} -> {}), skipping volume restore to avoid overwriting user's volume",
                        saved_sink, current_sink
                    );
                }
            }
            // else: corrupted/empty file — do nothing, don't fallback to 100%
        }
        // else: no duck file — nothing to restore, do NOT set 100%
        let _ = tokio::fs::remove_file(DUCK_VOLUME_FILE).await;
    }
}

async fn capture_audio_snippet(
    data_dir: &Path,
    duration_seconds: u64,
    source: Option<&str>,
) -> Result<String> {
    let binary = resolve_binary(
        "LIFEOS_AUDIO_CAPTURE_BIN",
        &["ffmpeg", "arecord", "pw-record", "parecord"],
    )
    .await
    .ok_or_else(|| anyhow::anyhow!("no local audio capture backend found"))?;

    let audio_dir = data_dir.join("audio");
    tokio::fs::create_dir_all(&audio_dir)
        .await
        .context("Failed to create audio capture dir")?;
    let audio_path = audio_dir.join(format!("always-on-{}.wav", uuid::Uuid::new_v4()));
    let output_path = audio_path.to_string_lossy().to_string();

    let program = Path::new(&binary)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(binary.as_str());

    let mut cmd = match program {
        "ffmpeg" => {
            let mut cmd = Command::new(&binary);
            let input_source = source.unwrap_or("default");
            let gain_db = std::env::var("LIFEOS_MIC_GAIN_DB")
                .ok()
                .and_then(|v| v.parse::<f32>().ok())
                .unwrap_or(8.0);
            let af_filter = format!("volume={}dB", gain_db);
            cmd.args([
                "-y",
                "-f",
                "pulse",
                "-i",
                input_source,
                "-t",
                &duration_seconds.to_string(),
                "-af",
                &af_filter,
                "-ac",
                "1",
                "-ar",
                "16000",
                &output_path,
            ]);
            if let Some(src) = source {
                cmd.env("PULSE_SOURCE", src);
            }
            cmd
        }
        "arecord" => {
            let mut cmd = Command::new(&binary);
            cmd.args([
                "-q",
                "-d",
                &duration_seconds.to_string(),
                "-f",
                "S16_LE",
                "-c",
                "1",
                "-r",
                "16000",
                &output_path,
            ]);
            if let Some(src) = source {
                cmd.env("PULSE_SOURCE", src);
            }
            cmd
        }
        "pw-record" | "parecord" => {
            let timeout = resolve_binary("LIFEOS_TIMEOUT_BIN", &["timeout"])
                .await
                .ok_or_else(|| anyhow::anyhow!("timeout utility is required for {}", program))?;
            let mut cmd = Command::new(timeout);
            cmd.arg(format!("{}s", duration_seconds)).arg(&binary);
            if program == "pw-record" {
                if let Some(src) = source {
                    cmd.args(["--target", src]);
                }
                cmd.args(["--rate", "16000", "--channels", "1", &output_path]);
            } else {
                if let Some(src) = source {
                    cmd.args(["-d", src]);
                }
                cmd.args([
                    "--rate=16000",
                    "--channels=1",
                    "--format=s16le",
                    "--file-format=wav",
                    &output_path,
                ]);
            }
            cmd
        }
        _ => anyhow::bail!("unsupported audio capture backend: {}", binary),
    };

    let output = cmd
        .output()
        .await
        .with_context(|| format!("Failed to capture audio via {}", binary))?;
    let status_ok =
        output.status.success() || (output.status.code() == Some(124) && audio_path.exists());
    if !status_ok {
        anyhow::bail!(
            "audio capture failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }

    cleanup_dir_by_count(&audio_dir, AUDIO_RETENTION_COUNT, "audio")
        .await
        .ok();
    Ok(output_path)
}

async fn cleanup_dir_by_count(dir: &Path, max_files: usize, label: &str) -> Result<u64> {
    if max_files == 0 || !dir.exists() {
        return Ok(0);
    }

    let mut files: Vec<(u64, PathBuf)> = Vec::new();
    let mut entries = tokio::fs::read_dir(dir)
        .await
        .with_context(|| format!("Failed to read {} directory {}", label, dir.display()))?;

    while let Some(entry) = entries
        .next_entry()
        .await
        .with_context(|| format!("Failed to read {} directory entry", label))?
    {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        let modified_epoch = match tokio::fs::metadata(&path).await {
            Ok(metadata) => metadata
                .modified()
                .ok()
                .and_then(|ts| ts.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or_default(),
            Err(_) => continue,
        };
        files.push((modified_epoch, path));
    }

    if files.len() <= max_files {
        return Ok(0);
    }

    files.sort_by(|a, b| b.0.cmp(&a.0));
    let mut removed = 0u64;
    for (_, path) in files.into_iter().skip(max_files) {
        tokio::fs::remove_file(&path)
            .await
            .with_context(|| format!("Failed to remove stale {} file {}", label, path.display()))?;
        removed += 1;
    }

    if removed > 0 {
        log::info!(
            "{} retention removed {} files (max={})",
            label,
            removed,
            max_files
        );
    }

    Ok(removed)
}

async fn audio_has_voice_activity(path: &Path) -> Result<bool> {
    let bytes = tokio::fs::read(path)
        .await
        .with_context(|| format!("Failed to read captured audio {}", path.display()))?;
    if bytes.len() < MIN_AUDIO_SIGNAL_BYTES {
        return Ok(false);
    }

    let pcm = if bytes.starts_with(b"RIFF") && bytes.len() > 44 {
        &bytes[44..]
    } else {
        &bytes[..]
    };

    let mut samples = 0usize;
    let mut squared = 0f64;
    for chunk in pcm.chunks_exact(2) {
        let sample = i16::from_le_bytes([chunk[0], chunk[1]]) as f64;
        squared += sample * sample;
        samples += 1;
    }

    if samples == 0 {
        return Ok(false);
    }

    let rms = (squared / samples as f64).sqrt();
    let threshold = vad_rms_threshold();
    Ok(rms >= threshold)
}

/// Capture audio from the microphone until the user stops speaking.
///
/// Behaviour:
/// 1. Starts `pw-record` (or fallback) streaming to stdout.
/// 2. Reads audio in 250 ms windows, computing RMS for each.
/// 3. Waits up to [`UTTERANCE_PRE_SPEECH_TIMEOUT_SECS`] for speech to start.
/// 4. Once speech is detected, keeps recording until
///    [`UTTERANCE_SILENCE_AFTER_SPEECH_SECS`] of silence is observed.
/// 5. Hard-caps at [`UTTERANCE_MAX_DURATION_SECS`] to prevent runaway capture.
/// 6. Writes the complete WAV file and returns its path.
async fn capture_until_silence(data_dir: &Path, source: Option<&str>) -> Result<String> {
    use tokio::io::AsyncReadExt;

    let binary = resolve_binary(
        "LIFEOS_AUDIO_CAPTURE_BIN",
        &["pw-record", "parecord", "ffmpeg", "arecord"],
    )
    .await
    .ok_or_else(|| anyhow::anyhow!("no audio capture backend for streaming"))?;

    let audio_dir = data_dir.join("audio");
    tokio::fs::create_dir_all(&audio_dir).await?;
    let audio_path = audio_dir.join(format!("utterance-{}.wav", uuid::Uuid::new_v4()));

    let program = Path::new(&binary)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(binary.as_str());

    // Build a long-running pw-record / parecord that writes to stdout.
    // We use a generous timeout and kill it ourselves when done.
    let max_secs = UTTERANCE_MAX_DURATION_SECS as u64 + 2;
    let mut cmd = match program {
        "pw-record" => {
            let mut c = Command::new(&binary);
            if let Some(src) = source {
                c.args(["--target", src]);
            }
            c.args(["--rate", "16000", "--channels", "1", "--format", "s16", "-"]);
            c
        }
        "parecord" => {
            let mut c = Command::new(&binary);
            if let Some(src) = source {
                c.args(["-d", src]);
            }
            c.args(["--rate=16000", "--channels=1", "--format=s16le", "--raw"]);
            c.arg("-"); // stdout
            c
        }
        _ => {
            // ffmpeg / arecord don't stream well to stdout — fall back to fixed capture.
            return capture_audio_snippet(data_dir, UTTERANCE_MAX_DURATION_SECS as u64, source)
                .await;
        }
    };

    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::null());

    let mut child = cmd
        .spawn()
        .context("failed to spawn audio capture for utterance")?;
    let mut stdout = child
        .stdout
        .take()
        .context("failed to take audio capture stdout")?;

    // 250 ms window at 16 kHz mono 16-bit = 8000 bytes.
    let window_bytes = (AUDIO_SAMPLE_RATE as f64 * 2.0 * UTTERANCE_WINDOW_SECS) as usize;
    let mut buf = vec![0u8; window_bytes];
    let mut all_pcm: Vec<u8> = Vec::with_capacity(AUDIO_SAMPLE_RATE as usize * 2 * 10);

    let start = Instant::now();
    let mut speech_detected = false;
    let mut last_speech_at = Instant::now();

    // --- Adaptive VAD: measure ambient noise floor from the first N windows ---
    let base_threshold = vad_rms_threshold();
    let mut noise_floor_sum = 0f64;
    let mut noise_floor_count = 0usize;
    let mut adaptive_threshold = base_threshold;
    let mut noise_floor_measured = false;

    loop {
        let elapsed = start.elapsed().as_secs_f64();

        // Hard cap — stop no matter what.
        if elapsed >= UTTERANCE_MAX_DURATION_SECS {
            break;
        }

        // Read one window with a timeout to avoid blocking forever.
        let read_result = tokio::time::timeout(
            std::time::Duration::from_secs(max_secs),
            stdout.read_exact(&mut buf),
        )
        .await;

        match read_result {
            Ok(Ok(_)) => {}
            Ok(Err(_)) | Err(_) => break, // EOF or timeout
        }

        // Apply software gain before storing/analyzing. Default 12 dB for quiet speech.
        let gain_db: f64 = std::env::var("LIFEOS_MIC_GAIN_DB")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(12.0);
        let gain_linear = 10f64.powf(gain_db / 20.0);

        // Amplify samples in-place and store the boosted PCM.
        let mut amplified = Vec::with_capacity(buf.len());
        let mut sum_sq = 0f64;
        let mut count = 0usize;
        for chunk in buf.chunks_exact(2) {
            let raw = i16::from_le_bytes([chunk[0], chunk[1]]) as f64;
            let boosted = (raw * gain_linear).clamp(-32768.0, 32767.0);
            let sample_i16 = boosted as i16;
            amplified.extend_from_slice(&sample_i16.to_le_bytes());
            sum_sq += boosted * boosted;
            count += 1;
        }
        all_pcm.extend_from_slice(&amplified);

        // Compute RMS for this window (on the amplified signal).
        let rms = if count > 0 {
            (sum_sq / count as f64).sqrt()
        } else {
            0.0
        };

        // Adaptive noise floor: use the first N windows to measure ambient noise,
        // then set the threshold to noise_floor * multiplier (min ADAPTIVE_RMS_FLOOR).
        if !noise_floor_measured {
            noise_floor_sum += rms;
            noise_floor_count += 1;
            if noise_floor_count >= NOISE_FLOOR_WINDOWS {
                let avg_noise = noise_floor_sum / noise_floor_count as f64;
                adaptive_threshold = (avg_noise * ADAPTIVE_NOISE_MULTIPLIER)
                    .max(ADAPTIVE_RMS_FLOOR)
                    .min(base_threshold); // never worse than the configured max
                noise_floor_measured = true;
                log::debug!(
                    "[vad] noise floor: {avg_noise:.0}, adaptive threshold: {adaptive_threshold:.0} (base: {base_threshold:.0})"
                );
            }
            continue; // don't count noise floor windows as pre-speech timeout
        }

        let is_speech = rms >= adaptive_threshold;

        if is_speech {
            speech_detected = true;
            last_speech_at = Instant::now();
        }

        if !speech_detected {
            // Waiting for user to start speaking.
            if elapsed >= UTTERANCE_PRE_SPEECH_TIMEOUT_SECS {
                break; // User didn't say anything.
            }
        } else {
            // User has spoken — check for end-of-utterance silence.
            let silence_duration = last_speech_at.elapsed().as_secs_f64();
            if silence_duration >= UTTERANCE_SILENCE_AFTER_SPEECH_SECS {
                break; // Done — user stopped talking.
            }
        }
    }

    // Kill the capture process.
    let _ = child.kill().await;

    if all_pcm.is_empty() {
        anyhow::bail!("no audio captured");
    }

    // Write WAV file (16 kHz, mono, 16-bit PCM).
    let data_len = all_pcm.len() as u32;
    let file_len = data_len + 36;
    let mut wav = Vec::with_capacity(44 + all_pcm.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&file_len.to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes()); // chunk size
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&1u16.to_le_bytes()); // mono
    wav.extend_from_slice(&AUDIO_SAMPLE_RATE.to_le_bytes()); // sample rate
    wav.extend_from_slice(&(AUDIO_SAMPLE_RATE * 2).to_le_bytes()); // byte rate
    wav.extend_from_slice(&2u16.to_le_bytes()); // block align
    wav.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.extend_from_slice(&all_pcm);

    tokio::fs::write(&audio_path, &wav).await?;

    cleanup_dir_by_count(&audio_dir, AUDIO_RETENTION_COUNT, "audio")
        .await
        .ok();

    Ok(audio_path.to_string_lossy().to_string())
}

async fn resolve_tts_model(override_model: Option<&str>) -> Option<String> {
    resolve_tts_models(override_model).await.into_iter().next()
}

async fn resolve_tts_models(override_model: Option<&str>) -> Vec<String> {
    let mut models = Vec::new();

    if let Some(model) = override_model.and_then(resolve_existing_tts_model) {
        models.push(model);
    }

    if let Ok(model) = std::env::var("LIFEOS_TTS_MODEL") {
        if let Some(model) = resolve_existing_tts_model(&model) {
            if !models.iter().any(|existing| existing == &model) {
                models.push(model);
            }
        }
    }

    for candidate in [
        "/var/lib/lifeos/models/piper/es_MX-claude-high.onnx",
        "/var/lib/lifeos/models/piper/es_ES-sharvard-medium.onnx",
        "/var/lib/lifeos/models/piper/en_US-lessac-medium.onnx",
        "/usr/share/lifeos/models/piper/es_MX-claude-high.onnx",
        "/usr/share/lifeos/models/piper/en_US-lessac-medium.onnx",
    ] {
        if !models.iter().any(|existing| existing == candidate) && tts_model_is_ready(candidate) {
            models.push(candidate.to_string());
        }
    }

    models
}

fn resolve_existing_tts_model(candidate: &str) -> Option<String> {
    let candidate = candidate.trim();
    if candidate.is_empty() {
        return None;
    }
    if tts_model_is_ready(candidate) {
        return Some(candidate.to_string());
    }

    let file_name = Path::new(candidate)
        .file_name()
        .and_then(|name| name.to_str())?;
    [
        "/var/lib/lifeos/models/piper",
        "/usr/share/lifeos/models/piper",
        "/var/lib/lifeos/models",
        "/usr/share/lifeos/models",
    ]
    .iter()
    .map(|dir| format!("{dir}/{file_name}"))
    .find(|path| tts_model_is_ready(path))
}

fn tts_model_is_ready(candidate: &str) -> bool {
    let candidate = candidate.trim();
    if candidate.is_empty() {
        return false;
    }
    let path = Path::new(candidate);
    if !path.exists() {
        return false;
    }

    let is_onnx = path
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| ext.eq_ignore_ascii_case("onnx"))
        .unwrap_or(false);
    if !is_onnx {
        return true;
    }

    let metadata = format!("{candidate}.json");
    Path::new(&metadata).exists()
}

async fn resolve_stt_model(override_model: Option<&str>) -> Option<String> {
    if let Some(model) = override_model.and_then(resolve_existing_stt_model) {
        return Some(model);
    }

    if let Ok(model) = std::env::var("LIFEOS_STT_MODEL") {
        if let Some(model) = resolve_existing_stt_model(&model) {
            return Some(model);
        }
    }

    // Auto-select whisper model based on available RAM
    let available_ram_gb = read_available_ram_gb();

    // Tier the candidate list: prefer larger models when RAM allows
    let candidates: &[&str] = if available_ram_gb > 8.0 {
        // >8 GB available — prefer medium for better accuracy on quiet speech
        &[
            "/var/lib/lifeos/models/whisper/ggml-medium.bin",
            "/usr/share/lifeos/models/whisper/ggml-medium.bin",
            "/var/lib/lifeos/models/whisper/ggml-base.bin",
            "/usr/share/lifeos/models/whisper/ggml-base.bin",
            "/var/lib/lifeos/models/whisper/ggml-base.en.bin",
            "/usr/share/lifeos/models/whisper/ggml-base.en.bin",
            "/var/lib/lifeos/models/whisper/ggml-small.bin",
            "/usr/share/lifeos/models/whisper/ggml-small.bin",
            "/var/lib/lifeos/models/whisper/ggml-tiny.bin",
            "/usr/share/lifeos/models/whisper/ggml-tiny.bin",
        ]
    } else if available_ram_gb > 4.0 {
        // >4 GB — prefer base
        &[
            "/var/lib/lifeos/models/whisper/ggml-base.bin",
            "/usr/share/lifeos/models/whisper/ggml-base.bin",
            "/var/lib/lifeos/models/whisper/ggml-base.en.bin",
            "/usr/share/lifeos/models/whisper/ggml-base.en.bin",
            "/var/lib/lifeos/models/whisper/ggml-small.bin",
            "/usr/share/lifeos/models/whisper/ggml-small.bin",
            "/var/lib/lifeos/models/whisper/ggml-tiny.bin",
            "/usr/share/lifeos/models/whisper/ggml-tiny.bin",
        ]
    } else {
        // <4 GB — prefer tiny/small to conserve memory
        &[
            "/var/lib/lifeos/models/whisper/ggml-tiny.bin",
            "/usr/share/lifeos/models/whisper/ggml-tiny.bin",
            "/var/lib/lifeos/models/whisper/ggml-small.bin",
            "/usr/share/lifeos/models/whisper/ggml-small.bin",
            "/var/lib/lifeos/models/whisper/ggml-base.bin",
            "/usr/share/lifeos/models/whisper/ggml-base.bin",
        ]
    };

    candidates
        .iter()
        .find(|candidate| Path::new(candidate).exists())
        .map(|candidate| candidate.to_string())
}

/// Read available RAM in gigabytes from /proc/meminfo.
/// Returns 0.0 on any error (will fall through to the smallest-model tier).
fn read_available_ram_gb() -> f64 {
    let Ok(contents) = std::fs::read_to_string("/proc/meminfo") else {
        return 0.0;
    };
    for line in contents.lines() {
        if let Some(rest) = line.strip_prefix("MemAvailable:") {
            // Value is in kB, e.g. "MemAvailable:   16384000 kB"
            let trimmed = rest.trim().trim_end_matches("kB").trim();
            if let Ok(kb) = trimmed.parse::<u64>() {
                return kb as f64 / 1_048_576.0;
            }
        }
    }
    0.0
}

fn resolve_existing_stt_model(candidate: &str) -> Option<String> {
    let candidate = candidate.trim();
    if candidate.is_empty() {
        return None;
    }
    if Path::new(candidate).exists() {
        return Some(candidate.to_string());
    }

    let file_name = Path::new(candidate)
        .file_name()
        .and_then(|name| name.to_str())?;
    [
        "/var/lib/lifeos/models/whisper",
        "/usr/share/lifeos/models/whisper",
        "/var/lib/lifeos/models",
        "/usr/share/lifeos/models",
    ]
    .iter()
    .map(|dir| format!("{dir}/{file_name}"))
    .find(|path| Path::new(path).exists())
}

fn binary_basename(path: &str) -> &str {
    Path::new(path)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(path)
}

fn tts_binary_requires_model(binary: Option<&str>) -> bool {
    matches!(binary.map(binary_basename), Some("piper" | "lifeos-piper"))
}

fn select_tts_binary(
    preferred: Option<String>,
    tts_model: Option<&str>,
    espeak_fallback: Option<String>,
) -> Option<String> {
    if tts_binary_requires_model(preferred.as_deref()) && tts_model.is_none() {
        return espeak_fallback.or(preferred);
    }
    preferred
}

async fn sanitize_tts_binary(
    selected: Option<String>,
    espeak_fallback: Option<String>,
) -> Option<String> {
    let binary = selected?;

    if tts_binary_requires_model(Some(binary.as_str())) && !supports_piper_cli(&binary).await {
        log::warn!(
            "Configured Piper binary '{}' does not support Piper CLI flags; falling back",
            binary
        );
        return espeak_fallback;
    }

    Some(binary)
}

async fn supports_piper_cli(binary: &str) -> bool {
    let output = match Command::new(binary).arg("--help").output().await {
        Ok(output) => output,
        Err(_) => return false,
    };

    let combined = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
    .to_lowercase();

    combined.contains("--model")
}

fn espeak_voice_for_language(language: Option<&str>) -> &'static str {
    match language.unwrap_or("es").to_lowercase().as_str() {
        value if value.starts_with("en") => "en-us",
        value if value.starts_with("es-mx") => "es-mx",
        value if value.starts_with("es") => "es",
        value if value.starts_with("pt") => "pt",
        _ => "es",
    }
}

async fn detect_llama_runtime_backend() -> Option<String> {
    let binary = resolve_binary("LIFEOS_LLAMA_BIN", &["llama-server"]).await?;

    if let Ok(output) = Command::new(&binary).arg("--version").output().await {
        let combined = format!(
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        if let Some(backend) = parse_llama_runtime_backend(&combined) {
            return Some(backend);
        }
    }

    if let Ok(output) = Command::new("ldd").arg(&binary).output().await {
        let libs = format!(
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        if let Some(backend) = parse_llama_runtime_backend(&libs) {
            return Some(backend);
        }
    }

    None
}

async fn detect_llama_runtime_gpu_failure() -> Option<String> {
    let output = Command::new("journalctl")
        .args(["-u", "llama-server.service", "-b", "-n", "80", "--no-pager"])
        .output()
        .await
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let journal = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
    .to_lowercase();

    if journal.contains("no usable gpu found")
        || journal.contains("ggml_vulkan: no devices found")
        || journal.contains("clip using cpu backend")
    {
        return Some("llama_runtime_reported_no_gpu".to_string());
    }

    None
}

fn parse_llama_runtime_backend(output: &str) -> Option<String> {
    let lower = output.to_lowercase();
    [
        ("cuda", "cuda"),
        ("cublas", "cuda"),
        ("vulkan", "vulkan"),
        ("opencl", "opencl"),
        ("hip", "rocm"),
        ("metal", "metal"),
        ("sycl", "sycl"),
    ]
    .iter()
    .find_map(|(needle, backend)| lower.contains(needle).then(|| (*backend).to_string()))
}

fn gpu_backend_supports_offload(backend: &str) -> bool {
    matches!(
        backend,
        "cuda" | "vulkan" | "opencl" | "rocm" | "metal" | "sycl"
    )
}

fn relevant_ocr_lines(ocr_text: &str, query: &str) -> Vec<String> {
    let query_tokens = tokenize(query);
    let mut scored = Vec::new();

    for line in ocr_text.lines() {
        let line = normalize_whitespace(line);
        if line.is_empty() {
            continue;
        }
        let lower = line.to_lowercase();
        let mut score = 0i32;
        if query_tokens.iter().any(|token| lower.contains(token)) {
            score += 5;
        }
        if lower.contains("error") || lower.contains("warning") || lower.contains("failed") {
            score += 4;
        }
        if lower.contains("todo") || lower.contains("fixme") || lower.contains("panic") {
            score += 3;
        }
        if line.len() > 24 {
            score += 1;
        }
        scored.push((score, line));
    }

    scored.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.len().cmp(&a.1.len())));
    let mut lines = scored
        .into_iter()
        .filter(|(score, _)| *score > 0)
        .map(|(_, line)| line)
        .take(MAX_RELEVANT_LINES)
        .collect::<Vec<_>>();

    if lines.is_empty() {
        lines = ocr_text
            .lines()
            .map(normalize_whitespace)
            .filter(|line| !line.is_empty())
            .take(MAX_RELEVANT_LINES)
            .collect();
    }

    dedupe_strings(lines)
}

fn has_meaningful_screen_change(
    previous_ocr: &str,
    current_ocr: &str,
    previous_relevant: &[String],
    current_relevant: &[String],
) -> bool {
    let previous = normalize_whitespace(previous_ocr);
    let current = normalize_whitespace(current_ocr);

    if previous.is_empty() && current.is_empty() {
        return false;
    }
    if previous.is_empty() || current.is_empty() {
        return true;
    }
    if previous == current {
        return false;
    }

    if previous.len().abs_diff(current.len()) >= OCR_LENGTH_DELTA_TRIGGER {
        return true;
    }

    let ocr_similarity = text_jaccard_similarity(&previous, &current);
    if ocr_similarity < OCR_SIMILARITY_SKIP_THRESHOLD {
        return true;
    }

    let relevant_similarity = lines_jaccard_similarity(previous_relevant, current_relevant);
    if !previous_relevant.is_empty() || !current_relevant.is_empty() {
        return relevant_similarity < RELEVANT_SIMILARITY_SKIP_THRESHOLD;
    }

    false
}

fn text_jaccard_similarity(left: &str, right: &str) -> f32 {
    let left_tokens = tokenize_for_similarity(left);
    let right_tokens = tokenize_for_similarity(right);
    if left_tokens.is_empty() && right_tokens.is_empty() {
        return 1.0;
    }

    let left_set: std::collections::HashSet<_> = left_tokens.into_iter().collect();
    let right_set: std::collections::HashSet<_> = right_tokens.into_iter().collect();
    sets_jaccard_similarity(&left_set, &right_set)
}

fn lines_jaccard_similarity(left: &[String], right: &[String]) -> f32 {
    let left_text = left.join(" ");
    let right_text = right.join(" ");
    text_jaccard_similarity(&left_text, &right_text)
}

fn sets_jaccard_similarity(
    left: &std::collections::HashSet<String>,
    right: &std::collections::HashSet<String>,
) -> f32 {
    if left.is_empty() && right.is_empty() {
        return 1.0;
    }
    let intersection = left.intersection(right).count() as f32;
    let union = left.union(right).count() as f32;
    if union == 0.0 {
        1.0
    } else {
        intersection / union
    }
}

fn normalized_wake_word(wake_word: &str) -> String {
    let wake_word = normalize_whitespace(wake_word).to_lowercase();
    if wake_word.is_empty() {
        DEFAULT_WAKE_WORD.to_string()
    } else {
        wake_word
    }
}

fn contains_wake_word(transcript: &str, wake_word: &str) -> bool {
    let transcript = clean_transcript(transcript).to_lowercase();
    let wake_word = normalized_wake_word(wake_word);
    if transcript.contains(&wake_word) {
        return true;
    }
    // Check phonetic variants that Whisper commonly produces for "axi".
    if wake_word == "axi" {
        let variants = [
            "axi", "aksi", "axie", "oxy", "aksie", "acsi", "ahxi", "asi", "ahi", "ahsi",
            // Spanish Whisper mishearings
            "exi", "oxi", "acci", "aquí",
        ];
        return variants.iter().any(|v| transcript.contains(v));
    }
    false
}

/// Remove whisper-cli timestamp markers and noise tags from transcript text.
fn clean_transcript(text: &str) -> String {
    let mut cleaned = String::new();
    let mut rest = text;
    while let Some(start) = rest.find('[') {
        cleaned.push_str(&rest[..start]);
        if let Some(end) = rest[start..].find(']') {
            let bracket_content = &rest[start + 1..start + end];
            // Keep content that isn't a timestamp or noise marker.
            let is_timestamp = bracket_content.contains("-->");
            let is_noise = bracket_content.starts_with("Música")
                || bracket_content.starts_with("música")
                || bracket_content.starts_with("Music")
                || bracket_content.starts_with("BLANK");
            if !is_timestamp && !is_noise {
                cleaned.push_str(bracket_content);
            }
            rest = &rest[start + end + 1..];
        } else {
            cleaned.push_str(&rest[start..]);
            rest = "";
            break;
        }
    }
    cleaned.push_str(rest);
    normalize_whitespace(&cleaned)
}

fn strip_wake_word(transcript: &str, wake_word: &str) -> Option<String> {
    let wake_word = normalized_wake_word(wake_word);
    let cleaned = clean_transcript(transcript);
    let cleaned_lower = cleaned.to_lowercase();

    // Try exact wake word first.
    let wake_index = cleaned_lower.find(&wake_word).or_else(|| {
        // Fall back to phonetic variants for "axi".
        if wake_word == "axi" {
            let variants = [
                "axi", "aksi", "axie", "oxy", "aksie", "acsi", "ahxi", "asi", "ahi", "ahsi", "exi",
                "oxi", "acci", "aquí",
            ];
            variants
                .iter()
                .filter_map(|v| cleaned_lower.find(v).map(|pos| (pos, v.len())))
                .min_by_key(|(pos, _)| *pos)
                .map(|(pos, _)| pos)
        } else {
            None
        }
    })?;

    // Find the actual variant length at that position.
    let variant_len = if cleaned_lower[wake_index..].starts_with(&wake_word) {
        wake_word.len()
    } else if wake_word == "axi" {
        let variants = [
            "axi", "aksi", "axie", "oxy", "aksie", "acsi", "ahxi", "asi", "ahi", "ahsi", "exi",
            "oxi", "acci", "aquí",
        ];
        variants
            .iter()
            .find(|v| cleaned_lower[wake_index..].starts_with(*v))
            .map(|v| v.len())
            .unwrap_or(wake_word.len())
    } else {
        wake_word.len()
    };

    let suffix = cleaned[wake_index + variant_len..]
        .trim_matches(|ch: char| matches!(ch, ',' | '.' | ':' | ';' | '!' | '?'))
        .trim();
    Some(normalize_whitespace(suffix))
}

fn should_include_screen_for_prompt(prompt: &str) -> bool {
    let prompt = prompt.to_lowercase();
    [
        "pantalla",
        "screen",
        "ves",
        "window",
        "terminal",
        "error",
        "codigo",
        "code",
        "documento",
        "pdf",
    ]
    .iter()
    .any(|token| prompt.contains(token))
}

fn contains_error_like_text(text: &str) -> bool {
    ["error", "warning", "panic", "failed", "traceback"]
        .iter()
        .any(|token| text.contains(token))
}

fn looks_like_code_context(app_hint: &str, text: &str) -> bool {
    [
        "code", "codium", "vscodium", "nvim", "vim", "idea", "terminal", ".rs", ".py", ".ts",
    ]
    .iter()
    .any(|token| app_hint.contains(token) || text.contains(token))
}

fn looks_like_document_context(app_hint: &str, text: &str) -> bool {
    [
        "pdf",
        "document",
        "libreoffice",
        "writer",
        "okular",
        "evince",
        "docx",
        "markdown",
    ]
    .iter()
    .any(|token| app_hint.contains(token) || text.contains(token))
}

fn is_night_window(now: DateTime<Utc>) -> bool {
    let hour = now.hour();
    hour >= 22 || hour <= 5
}

fn normalize_whitespace(input: &str) -> String {
    input.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn sanitize_assistant_response(raw: &str) -> String {
    let mut text = strip_think_sections(raw);
    text = text
        .replace("<think>", " ")
        .replace("</think>", " ")
        .replace("<|im_start|>", " ")
        .replace("<|im_end|>", " ");

    let mut cleaned_lines = Vec::new();
    let mut in_code_fence = false;
    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.starts_with("```") {
            in_code_fence = !in_code_fence;
            continue;
        }
        if in_code_fence || line.is_empty() {
            continue;
        }
        if looks_like_internal_reasoning_line(line) {
            continue;
        }
        let line = strip_leading_list_marker(line)
            .trim_start_matches('#')
            .trim()
            .trim_matches('`')
            .trim();
        if !line.is_empty() {
            cleaned_lines.push(line.to_string());
        }
    }

    let cleaned = normalize_whitespace(&cleaned_lines.join(" "));
    if !cleaned.is_empty() {
        cleaned
    } else {
        let quoted = extract_quoted_spoken_text(raw);
        if !quoted.is_empty() {
            quoted
        } else {
            "Lo siento, no pude generar una respuesta clara.".to_string()
        }
    }
}

fn strip_think_sections(input: &str) -> String {
    let mut output = String::new();
    let mut rest = input;
    loop {
        if let Some(start) = rest.find("<think>") {
            output.push_str(&rest[..start]);
            let after_start = &rest[start + "<think>".len()..];
            if let Some(end_rel) = after_start.find("</think>") {
                rest = &after_start[end_rel + "</think>".len()..];
            } else {
                break;
            }
        } else {
            output.push_str(rest);
            break;
        }
    }
    output
}

fn looks_like_internal_reasoning_line(line: &str) -> bool {
    let normalized = normalize_whitespace(line)
        .trim_start_matches(['*', '-', '#', '`', '>', ' '])
        .to_lowercase();
    [
        "thinking process",
        "the user wants",
        "i need to",
        "let me ",
        "analyze the request",
        "determine the output",
        "drafting the",
        "selection:",
        "check constraints",
        "final polish",
        "constraints:",
        "goal:",
        "reasoning:",
        "analysis:",
        "internal reasoning",
    ]
    .iter()
    .any(|prefix| normalized.starts_with(prefix))
}

fn extract_quoted_spoken_text(raw: &str) -> String {
    let mut best = String::new();
    let mut current = String::new();
    let mut in_quote = false;

    for ch in raw.chars() {
        if matches!(ch, '"' | '“' | '”') {
            if in_quote {
                let candidate = normalize_whitespace(current.trim());
                if candidate.len() > best.len() {
                    best = candidate;
                }
                current.clear();
                in_quote = false;
            } else {
                in_quote = true;
                current.clear();
            }
            continue;
        }

        if in_quote {
            current.push(ch);
        }
    }

    best
}

fn strip_leading_list_marker(line: &str) -> &str {
    let trimmed = line.trim_start();
    let trimmed = trimmed
        .strip_prefix("- ")
        .or_else(|| trimmed.strip_prefix("* "))
        .or_else(|| trimmed.strip_prefix("• "))
        .unwrap_or(trimmed);

    let bytes = trimmed.as_bytes();
    let mut idx = 0usize;
    while idx < bytes.len() && bytes[idx].is_ascii_digit() {
        idx += 1;
    }
    if idx > 0 && idx + 1 < bytes.len() && (bytes[idx] == b'.' || bytes[idx] == b')') {
        let mut next = idx + 1;
        while next < bytes.len() && bytes[next].is_ascii_whitespace() {
            next += 1;
        }
        return trimmed[next..].trim_start();
    }

    trimmed
}

fn prepare_tts_text(raw: &str) -> String {
    let cleaned = sanitize_assistant_response(raw);
    let base = if cleaned.is_empty() {
        normalize_whitespace(raw)
    } else {
        cleaned
    };

    let mut chunks = Vec::new();
    let mut current = String::new();
    for sentence in split_spoken_sentences(&base) {
        if sentence.is_empty() {
            continue;
        }
        if !current.is_empty() && current.len() + sentence.len() + 1 > TTS_CHUNK_MAX_CHARS {
            chunks.push(current.trim().to_string());
            current.clear();
        }
        if !current.is_empty() {
            current.push(' ');
        }
        current.push_str(&sentence);
    }
    if !current.trim().is_empty() {
        chunks.push(current.trim().to_string());
    }

    if chunks.is_empty() {
        base
    } else {
        chunks.join("\n")
    }
}

fn split_spoken_sentences(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();

    for ch in text.chars() {
        if ch == '\n' || ch == '\r' {
            let normalized = normalize_whitespace(current.trim());
            if !normalized.is_empty() {
                out.push(normalized);
            }
            current.clear();
            continue;
        }

        current.push(ch);
        if matches!(ch, '.' | '!' | '?' | ';' | ':') {
            let normalized = normalize_whitespace(current.trim());
            if !normalized.is_empty() {
                out.push(normalized);
            }
            current.clear();
        }
    }

    let trailing = normalize_whitespace(current.trim());
    if !trailing.is_empty() {
        out.push(trailing);
    }
    out
}

fn tokenize(input: &str) -> Vec<String> {
    input
        .split(|c: char| !c.is_alphanumeric())
        .map(|token| token.trim().to_lowercase())
        .filter(|token| token.len() >= 3)
        .collect()
}

fn tokenize_for_similarity(input: &str) -> Vec<String> {
    input
        .split(|c: char| !c.is_alphanumeric())
        .map(|token| token.trim().to_lowercase())
        .filter(|token| token.len() >= 3)
        .map(|token| {
            token
                .chars()
                .map(|ch| if ch.is_ascii_digit() { '0' } else { ch })
                .collect::<String>()
        })
        .collect()
}

fn dedupe_strings(values: Vec<String>) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for value in values {
        if seen.insert(value.clone()) {
            out.push(value);
        }
    }
    out
}

fn truncate_for_memory(content: &str) -> String {
    let mut out = content.trim().to_string();
    if out.len() > MAX_MEMORY_BYTES {
        out.truncate(MAX_MEMORY_BYTES);
    }
    out
}

fn tokens_per_second(tokens_used: Option<u32>, duration_ms: u64) -> Option<f32> {
    let tokens = tokens_used?;
    if duration_ms == 0 {
        return None;
    }
    Some(tokens as f32 / (duration_ms as f32 / 1000.0))
}

async fn resolve_binary(env_var: &str, candidates: &[&str]) -> Option<String> {
    if let Ok(path) = std::env::var(env_var) {
        let path = path.trim().to_string();
        if !path.is_empty() && Path::new(&path).exists() {
            return Some(path);
        }
    }

    for candidate in candidates {
        let output = Command::new("which").arg(candidate).output().await.ok()?;
        if output.status.success() {
            let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path.is_empty() {
                return Some(path);
            }
        }
    }
    None
}

fn resolve_camera_device() -> Option<String> {
    if let Ok(path) = std::env::var("LIFEOS_CAMERA_DEVICE") {
        let path = path.trim().to_string();
        if !path.is_empty() {
            return Some(path);
        }
    }

    for candidate in ["/dev/video0", "/dev/video1", "/dev/video2"] {
        if Path::new(candidate).exists() {
            return Some(candidate.to_string());
        }
    }
    None
}

/// Resolve the audio source for always-on wake word capture.
/// When the default PulseAudio source is a Bluetooth device, this returns a
/// non-Bluetooth alternative (internal mic) to avoid A2DP→HSP/HFP profile
/// switching that degrades audio quality system-wide.
/// Auto-detect the best audio input source for voice capture.
///
/// Priority: env override → PipeWire default source → best available mic.
/// Unlike the previous version, this always returns a source if any mic exists,
/// not just when Bluetooth is the default.
async fn resolve_always_on_source() -> Option<String> {
    // 1. Explicit override from environment
    if let Ok(val) = std::env::var("LIFEOS_ALWAYS_ON_SOURCE") {
        let val = val.trim().to_string();
        if !val.is_empty() && val != "auto" {
            log::info!("[audio] using explicit source from env: {val}");
            return Some(val);
        }
    }

    // 2. Get the system default source (usually the built-in mic)
    let info_output = Command::new("pactl").arg("info").output().await.ok()?;
    if !info_output.status.success() {
        return None;
    }
    let info = String::from_utf8_lossy(&info_output.stdout);
    let default_source = info
        .lines()
        .find(|l| l.starts_with("Default Source:") || l.starts_with("Fuente por defecto:"))
        .and_then(|l| l.split_once(':').map(|(_, v)| v.trim().to_string()));

    // 3. List all non-monitor sources
    let list_output = Command::new("pactl")
        .args(["list", "short", "sources"])
        .output()
        .await
        .ok()?;
    if !list_output.status.success() {
        return None;
    }
    let list = String::from_utf8_lossy(&list_output.stdout);
    let sources: Vec<String> = list
        .lines()
        .filter_map(|line| {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() >= 2 {
                Some(cols[1].to_string())
            } else {
                None
            }
        })
        .filter(|name| !name.contains(".monitor"))
        .collect();

    // 4. If the default source is a real input (not a monitor), use it directly
    if let Some(ref ds) = default_source {
        if !ds.contains(".monitor") && sources.iter().any(|s| s == ds) {
            log::info!("[audio] using system default source: {ds}");
            return Some(ds.clone());
        }
    }

    // 5. Fallback priority: analog stereo > USB > Bluetooth > any ALSA input
    if let Some(s) = sources
        .iter()
        .find(|s| s.starts_with("alsa_input.") && s.contains("analog-stereo"))
    {
        log::info!("[audio] using analog stereo source: {s}");
        return Some(s.clone());
    }
    if let Some(s) = sources.iter().find(|s| s.starts_with("alsa_input.usb-")) {
        log::info!("[audio] using USB source: {s}");
        return Some(s.clone());
    }
    if let Some(s) = sources.iter().find(|s| s.starts_with("bluez_input.")) {
        log::info!("[audio] using Bluetooth source: {s}");
        return Some(s.clone());
    }
    if let Some(s) = sources.iter().find(|s| s.starts_with("alsa_input.")) {
        log::info!("[audio] using ALSA source: {s}");
        return Some(s.clone());
    }
    log::warn!("[audio] no input source found");
    None
}

fn read_gpu_layers() -> Option<i32> {
    let env_file = llama_env_path();
    let content = std::fs::read_to_string(env_file).ok()?;
    content.lines().find_map(|line| {
        line.strip_prefix("LIFEOS_AI_GPU_LAYERS=")
            .and_then(|value| value.trim().parse::<i32>().ok())
    })
}

fn persist_gpu_layers(target_layers: i32) -> Result<bool> {
    let env_file = llama_env_path();
    let parent = env_file
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    std::fs::create_dir_all(&parent)
        .with_context(|| format!("Failed to create {}", parent.display()))?;

    let existing = std::fs::read_to_string(&env_file).unwrap_or_default();
    let mut found = false;
    let mut lines = existing
        .lines()
        .map(|line| {
            if line.starts_with("LIFEOS_AI_GPU_LAYERS=") {
                found = true;
                format!("LIFEOS_AI_GPU_LAYERS={}", target_layers)
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>();

    if !found {
        lines.push(format!("LIFEOS_AI_GPU_LAYERS={}", target_layers));
    }

    let serialized = format!("{}\n", lines.join("\n"));
    if existing == serialized {
        return Ok(false);
    }

    std::fs::write(&env_file, serialized)
        .with_context(|| format!("Failed to update {}", env_file.display()))?;
    Ok(true)
}

fn llama_env_path() -> PathBuf {
    std::env::var("LIFEOS_LLAMA_ENV")
        .ok()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/etc/lifeos/llama-server.env"))
}

async fn kill_pid(pid: u32) -> Result<()> {
    Command::new("kill")
        .args(["-TERM", &pid.to_string()])
        .status()
        .await
        .context("Failed to invoke kill")?;
    Ok(())
}

async fn capture_camera_presence(
    data_dir: &Path,
    capture_binary: Option<&str>,
    camera_device: Option<&str>,
) -> Result<CameraPresenceMetrics> {
    let Some(binary) = capture_binary else {
        anyhow::bail!("camera capture binary unavailable");
    };
    let Some(device) = camera_device else {
        anyhow::bail!("camera device unavailable");
    };

    let camera_dir = data_dir.join("camera");
    tokio::fs::create_dir_all(&camera_dir)
        .await
        .context("Failed to create camera dir")?;
    let frame_path = camera_dir.join(format!("presence-{}.jpg", uuid::Uuid::new_v4()));

    let mut cmd = Command::new(binary);
    let program = Path::new(binary)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(binary);

    match program {
        "ffmpeg" => {
            cmd.args([
                "-y",
                "-f",
                "v4l2",
                "-i",
                device,
                "-frames:v",
                "1",
                frame_path.to_string_lossy().as_ref(),
            ]);
        }
        "libcamera-still" | "libcamera-jpeg" => {
            cmd.args([
                "-n",
                "-o",
                frame_path.to_string_lossy().as_ref(),
                "--immediate",
            ]);
        }
        "fswebcam" => {
            cmd.args(["-d", device, frame_path.to_string_lossy().as_ref()]);
        }
        _ => anyhow::bail!("unsupported camera capture backend: {}", binary),
    }

    let output = cmd
        .output()
        .await
        .with_context(|| format!("Failed to capture camera frame via {}", binary))?;
    if !output.status.success() {
        anyhow::bail!(
            "camera capture failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }

    let mut metrics = analyze_camera_frame(&frame_path)?;
    metrics.frame_path = Some(frame_path.to_string_lossy().to_string());
    Ok(metrics)
}

#[derive(Debug, Clone)]
struct CameraPresenceMetrics {
    present: bool,
    face_near_screen: bool,
    frame_path: Option<String>,
}

fn analyze_camera_frame(path: &Path) -> Result<CameraPresenceMetrics> {
    let image = image::open(path).context("Failed to open captured camera frame")?;
    let (width, height) = image.dimensions();
    let center_left = width / 4;
    let center_right = (width * 3) / 4;
    let center_top = height / 4;
    let center_bottom = (height * 3) / 4;

    let mut total_pixels = 0u64;
    let mut skin_like_pixels = 0u64;
    let mut brightness_sum = 0f64;
    let mut edge_sum = 0f64;

    for y in center_top..center_bottom {
        for x in center_left..center_right {
            let pixel = image.get_pixel(x, y).to_rgb();
            let channels = pixel.channels();
            let r = channels[0] as f64;
            let g = channels[1] as f64;
            let b = channels[2] as f64;
            brightness_sum += (r + g + b) / 3.0;
            if is_skin_like(channels[0], channels[1], channels[2]) {
                skin_like_pixels += 1;
            }
            if x > center_left {
                let prev = image.get_pixel(x - 1, y).to_rgb();
                let prev = prev.channels();
                edge_sum += ((r - prev[0] as f64).abs()
                    + (g - prev[1] as f64).abs()
                    + (b - prev[2] as f64).abs())
                    / 3.0;
            }
            total_pixels += 1;
        }
    }

    if total_pixels == 0 {
        anyhow::bail!("camera frame is empty");
    }

    let skin_ratio = skin_like_pixels as f64 / total_pixels as f64;
    let avg_brightness = brightness_sum / total_pixels as f64;
    let avg_edge = edge_sum / total_pixels as f64;
    let present = skin_ratio > 0.03 || (avg_brightness > 35.0 && avg_edge > 12.0);
    let face_near_screen = skin_ratio > 0.18;

    Ok(CameraPresenceMetrics {
        present,
        face_near_screen,
        frame_path: None,
    })
}

/// AI-powered camera scene analysis result.
struct CameraSceneAnalysis {
    scene_description: String,
    user_state: String,
    people_count: u8,
}

/// Use the multimodal LLM to analyze a camera frame for richer presence context.
async fn analyze_camera_scene(
    ai_manager: &AiManager,
    frame_path: &str,
) -> Result<CameraSceneAnalysis> {
    let response = ai_manager
        .chat_multimodal(
            None,
            Some(
                "You are a presence sensor. Output ONLY these three lines, nothing else:\n\
                 SCENE: <10 words max describing the scene>\n\
                 STATE: <focused|distracted|away|talking|resting>\n\
                 PEOPLE: <number>\n\n\
                 Do NOT explain your reasoning. Do NOT add any other text.",
            ),
            "Describe what you see in this webcam frame.",
            frame_path,
        )
        .await?;

    parse_camera_scene_response(&response.response)
}

fn parse_camera_scene_response(text: &str) -> Result<CameraSceneAnalysis> {
    // Strip <think>…</think> blocks that some models emit before the answer.
    let cleaned = strip_think_blocks(text);

    let mut scene = String::new();
    let mut state = String::from("unknown");
    let mut people: u8 = 0;

    for line in cleaned.lines() {
        let line = line.trim();
        // Standard format: SCENE: / STATE: / PEOPLE:
        if let Some(rest) = line.strip_prefix("SCENE:") {
            scene = rest.trim().to_string();
        } else if let Some(rest) = line.strip_prefix("STATE:") {
            state = rest.trim().to_lowercase();
        } else if let Some(rest) = line.strip_prefix("PEOPLE:") {
            people = rest.trim().parse().unwrap_or(0);
        }
    }

    // Extract inline STATE:/PEOPLE: from anywhere in the text (some models
    // put everything on one line or embed them in the scene description).
    let full_text = cleaned.replace('\n', " ");
    if state == "unknown" {
        if let Some(idx) = full_text.find("STATE:") {
            let after = full_text[idx + 6..].trim();
            let word = after.split_whitespace().next().unwrap_or("");
            let lower_word = word.to_lowercase();
            for candidate in ["focused", "distracted", "away", "talking", "resting"] {
                if lower_word == candidate {
                    state = candidate.to_string();
                    break;
                }
            }
        }
        // Still unknown? Try loose matching.
        if state == "unknown" {
            let lower = full_text.to_lowercase();
            for candidate in ["focused", "distracted", "away", "talking", "resting"] {
                if lower.contains(candidate) {
                    state = candidate.to_string();
                    break;
                }
            }
        }
    }
    if people == 0 {
        if let Some(idx) = full_text.find("PEOPLE:") {
            let after = full_text[idx + 7..].trim();
            let num_str = after.split_whitespace().next().unwrap_or("0");
            people = num_str.parse().unwrap_or(0);
        }
    }

    // Strip trailing "STATE: ... PEOPLE: ..." from the scene description.
    scene = strip_inline_tags(&scene);

    if scene.is_empty() {
        // Fallback: build scene from non-junk lines.
        let useful_lines: Vec<&str> = cleaned
            .lines()
            .map(|l| l.trim())
            .map(|l| l.trim_start_matches(['*', '#', '-', '>']).trim())
            .filter(|l| !l.is_empty() && !is_scene_junk_line(l))
            .collect();

        // Take the first substantive line, stripping markdown labels.
        if let Some(first) = useful_lines.first() {
            scene = strip_inline_tags(&strip_markdown_label(first));
        }
        if scene.is_empty() {
            scene = "unknown scene".to_string();
        }
    }

    // Truncate overly long scene descriptions.
    scene = truncate_scene(&scene, 120);

    Ok(CameraSceneAnalysis {
        scene_description: scene,
        user_state: state,
        people_count: people,
    })
}

/// Returns true for lines that look like LLM reasoning / structural headers.
fn is_scene_junk_line(line: &str) -> bool {
    let lower = line.to_lowercase();
    let lower = lower.trim_start_matches(['*', '#', '-', '>']).trim();
    // Structural / reasoning prefixes
    lower.starts_with("analyze")
        || lower.starts_with("let me")
        || lower.starts_with("i need")
        || lower.starts_with("the image")
        || lower.starts_with("looking at")
        || lower.starts_with("observation")
        || lower.starts_with("note:")
        || lower.starts_with("action")
        || lower.starts_with("context")
        || lower.starts_with("assessment")
        || lower.starts_with("summary")
        || lower.starts_with("conclusion")
        || lower.starts_with("step ")
        || lower.starts_with("first,")
        || lower.starts_with("next,")
        || lower.starts_with("finally,")
        || lower.starts_with("overall")
        || line.starts_with('<')
        // Section headers with no content (e.g. "**Subject:**")
        || (line.contains("**") && !line.contains(' '))
}

/// Remove inline "STATE: …" and "PEOPLE: …" tags from a scene description.
fn strip_inline_tags(scene: &str) -> String {
    let mut result = scene.to_string();
    // Remove "STATE: <word>" (case-insensitive).
    for prefix in ["STATE:", "State:", "state:"] {
        if let Some(idx) = result.find(prefix) {
            let before = &result[..idx];
            let after = &result[idx + prefix.len()..];
            // Skip the next word (the state value).
            let remaining = after
                .split_whitespace()
                .skip(1)
                .collect::<Vec<_>>()
                .join(" ");
            result = format!(
                "{}{}",
                before.trim_end(),
                if remaining.is_empty() {
                    String::new()
                } else {
                    format!(" {remaining}")
                }
            );
        }
    }
    // Remove "PEOPLE: <number>".
    for prefix in ["PEOPLE:", "People:", "people:"] {
        if let Some(idx) = result.find(prefix) {
            let before = &result[..idx];
            let after = &result[idx + prefix.len()..];
            let remaining = after
                .split_whitespace()
                .skip(1)
                .collect::<Vec<_>>()
                .join(" ");
            result = format!(
                "{}{}",
                before.trim_end(),
                if remaining.is_empty() {
                    String::new()
                } else {
                    format!(" {remaining}")
                }
            );
        }
    }
    // Clean up trailing punctuation/whitespace.
    result
        .trim_end_matches(['.', ',', ';', ' '])
        .trim()
        .to_string()
}

/// Strip markdown bold labels like "**Subject:** actual text" → "actual text"
fn strip_markdown_label(line: &str) -> String {
    // Pattern: **Label:** rest
    if let Some(idx) = line.find(":**") {
        let after = &line[idx + 3..];
        let trimmed = after.trim().trim_start_matches(['*', ' ']).trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    // Pattern: **Label** rest (no colon)
    let stripped = line
        .trim_start_matches('*')
        .trim()
        .trim_end_matches('*')
        .trim();
    stripped.to_string()
}

/// Truncate a scene string to `max_chars` on a char boundary.
fn truncate_scene(scene: &str, max_chars: usize) -> String {
    if scene.chars().count() <= max_chars {
        return scene.to_string();
    }
    let mut truncated: String = scene.chars().take(max_chars).collect();
    if let Some(last_space) = truncated.rfind(' ') {
        truncated.truncate(last_space);
    }
    truncated.push('…');
    truncated
}

/// Strip `<think>…</think>` sections from LLM output.
fn strip_think_blocks(input: &str) -> String {
    let mut output = String::new();
    let mut rest = input;
    loop {
        if let Some(start) = rest.find("<think>") {
            output.push_str(&rest[..start]);
            let after = &rest[start + "<think>".len()..];
            if let Some(end) = after.find("</think>") {
                rest = &after[end + "</think>".len()..];
            } else {
                // Unclosed think tag — discard the rest as reasoning.
                break;
            }
        } else {
            output.push_str(rest);
            break;
        }
    }
    output
}

fn is_skin_like(r: u8, g: u8, b: u8) -> bool {
    let r = r as i32;
    let g = g as i32;
    let b = b as i32;
    r > 95 && g > 40 && b > 20 && (r - g).abs() > 15 && r > g && r > b
}

// ── Meeting / call detection ────────────────────────────────────────────

/// Known conferencing app binary names (lowercase).
const CONFERENCING_APPS: &[&str] = &[
    "chrome",
    "chromium",
    "firefox",
    "google-chrome",
    "brave",
    "vivaldi",
    "microsoft-edge",
    "zoom",
    "zoom.real",
    "teams",
    "teams-for-linux",
    "slack",
    "discord",
    "skype",
    "webex",
    "obs",
    "telegram-desktop",
    "signal-desktop",
];

/// Detect whether the user is in a voice/video call by checking PulseAudio
/// sink-inputs for audio streams from known conferencing applications.
///
/// Logic: if a conferencing app (Chrome, Zoom, Teams, Discord, etc.) has an
/// active sink-input AND a source-output (mic capture), the user is almost
/// certainly in a call.
async fn detect_active_meeting() -> Option<String> {
    // Check sink-inputs (apps playing audio).
    let sink_output = Command::new("pactl")
        .args(["list", "sink-inputs"])
        .output()
        .await
        .ok()?;
    if !sink_output.status.success() {
        return None;
    }
    let sink_text = String::from_utf8_lossy(&sink_output.stdout).to_lowercase();

    // Check source-outputs (apps capturing mic).
    let source_output = Command::new("pactl")
        .args(["list", "source-outputs"])
        .output()
        .await
        .ok()?;
    let source_text = if source_output.status.success() {
        String::from_utf8_lossy(&source_output.stdout).to_lowercase()
    } else {
        String::new()
    };

    // A conferencing app playing audio AND capturing mic = very likely a call.
    for app in CONFERENCING_APPS {
        let app_playing_audio = sink_text.contains(app);
        let app_capturing_mic = source_text.contains(app);
        if app_playing_audio && app_capturing_mic {
            return Some(app.to_string());
        }
    }

    // Fallback: WebRTC in browsers often shows up as "AudioCallbackDriver".
    // If a browser is playing audio and ANY source-output exists, likely a call.
    let browser_names = [
        "chrome",
        "chromium",
        "firefox",
        "brave",
        "vivaldi",
        "microsoft-edge",
    ];
    let any_mic_active = !source_text.is_empty()
        && source_output.status.success()
        && source_text.contains("application.name");
    if any_mic_active {
        for browser in &browser_names {
            if sink_text.contains(browser) {
                return Some(browser.to_string());
            }
        }
    }

    None
}

/// Check if the camera device is currently in use by another process.
///
/// On Linux, V4L2 devices are exclusive — only one process can open them.
/// We try to open the device file; if it fails with EBUSY, it's in use.
fn is_camera_busy(device: &str) -> bool {
    use std::fs::OpenOptions;
    match OpenOptions::new().read(true).open(device) {
        Ok(_) => false, // We could open it → not busy.
        Err(e) => {
            // EBUSY (errno 16) = device in use by another process.
            e.raw_os_error() == Some(16)
        }
    }
}

/// Update meeting state by checking PulseAudio streams and camera availability.
async fn refresh_meeting_state(camera_device: Option<&str>) -> MeetingState {
    let conferencing_app = detect_active_meeting().await;
    let camera_busy = camera_device.map(is_camera_busy).unwrap_or(false);

    MeetingState {
        active: conferencing_app.is_some() || camera_busy,
        conferencing_app,
        camera_busy,
        last_checked_at: Some(Utc::now()),
    }
}

async fn presence_from_activity(follow_along: &FollowAlongManager) -> (bool, bool, &'static str) {
    let stats = follow_along.get_event_stats().await;
    let last_event = follow_along.get_context().await.last_event;
    let present = last_event
        .map(|event| (Utc::now() - event).num_seconds() < 300)
        .unwrap_or(stats.total_events > 0);
    (present, false, "activity-fallback")
}

fn average_u64(values: impl Iterator<Item = u64>) -> Option<u64> {
    let values = values.collect::<Vec<_>>();
    if values.is_empty() {
        return None;
    }
    Some(values.iter().sum::<u64>() / values.len() as u64)
}

fn average_f32(values: impl Iterator<Item = f32>) -> Option<f32> {
    let values = values.collect::<Vec<_>>();
    if values.is_empty() {
        return None;
    }
    Some(values.iter().sum::<f32>() / values.len() as f32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, Rgb};

    #[test]
    fn gpu_policy_matches_phase4_table() {
        let low = gpu_policy_for_vram(Some(3), 0);
        assert_eq!(low.llm_offload, "cpu only");
        let partial = gpu_policy_for_vram(Some(5), 0);
        assert_eq!(partial.llm_offload, "partial (50% layers GPU)");
        let full = gpu_policy_for_vram(Some(10), -1);
        assert_eq!(full.vision_offload, "full gpu");
    }

    #[test]
    fn relevant_ocr_lines_prioritize_errors_and_query() {
        let lines = relevant_ocr_lines(
            "Build complete\nwarning: foo\npanic: crash in main\nregular text",
            "why did main crash",
        );
        assert_eq!(
            lines.first().map(String::as_str),
            Some("panic: crash in main")
        );
    }

    #[test]
    fn screen_change_filter_ignores_minor_ocr_noise() {
        let previous_ocr = "lifeos terminal build complete warning memory 78c";
        let current_ocr = "lifeos terminal build complete warning memory 79c";
        let previous_relevant = vec![
            "warning memory 78c".to_string(),
            "build complete".to_string(),
        ];
        let current_relevant = vec![
            "warning memory 79c".to_string(),
            "build complete".to_string(),
        ];

        let changed = has_meaningful_screen_change(
            previous_ocr,
            current_ocr,
            &previous_relevant,
            &current_relevant,
        );
        assert!(!changed);
    }

    #[test]
    fn screen_change_filter_detects_context_shift() {
        let previous_ocr = "cargo test running on project alpha no errors";
        let current_ocr = "github actions failed release-channel missing artifact";
        let previous_relevant = vec!["cargo test running".to_string()];
        let current_relevant = vec!["release-channel missing artifact".to_string()];

        let changed = has_meaningful_screen_change(
            previous_ocr,
            current_ocr,
            &previous_relevant,
            &current_relevant,
        );
        assert!(changed);
    }

    #[test]
    fn wake_word_detection_and_prompt_stripping_work() {
        let transcript = "Axi, que ves en mi pantalla ahora mismo?";
        assert!(contains_wake_word(transcript, "axi"));
        assert_eq!(
            strip_wake_word(transcript, "axi").as_deref(),
            Some("que ves en mi pantalla ahora mismo")
        );
        assert!(should_include_screen_for_prompt(
            "que ves en mi pantalla ahora mismo"
        ));
    }

    #[test]
    fn wake_word_with_timestamps_and_noise() {
        // Whisper-cli output with timestamps
        let transcript = "[00:00:00.000 --> 00:00:04.000]  [Música] Oxi, dime la hora por favor.";
        assert!(contains_wake_word(transcript, "axi"));
        assert_eq!(
            strip_wake_word(transcript, "axi").as_deref(),
            Some("dime la hora por favor")
        );

        // Pure noise — no wake word
        let noise = "[00:00:00.000 --> 00:00:04.000]  [Música]";
        assert!(!contains_wake_word(noise, "axi"));

        // Phonetic variant "aquí" (common Spanish mishearing)
        let transcript2 = "[00:00:00.000 --> 00:00:02.000]  Aquí, ayúdame.";
        assert!(contains_wake_word(transcript2, "axi"));
        assert_eq!(
            strip_wake_word(transcript2, "axi").as_deref(),
            Some("ayúdame")
        );
    }

    #[test]
    fn persist_gpu_layers_updates_env_file() {
        let dir = std::env::temp_dir().join(format!("lifeos-gpu-env-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let env_file = dir.join("llama-server.env");
        std::env::set_var("LIFEOS_LLAMA_ENV", &env_file);

        assert!(persist_gpu_layers(20).unwrap());
        assert_eq!(read_gpu_layers(), Some(20));
        assert!(!persist_gpu_layers(20).unwrap());
        assert!(persist_gpu_layers(0).unwrap());
        assert_eq!(read_gpu_layers(), Some(0));

        std::env::remove_var("LIFEOS_LLAMA_ENV");
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn camera_frame_analysis_detects_center_presence() {
        let dir = std::env::temp_dir().join(format!("lifeos-camera-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("presence.jpg");

        let mut image: ImageBuffer<Rgb<u8>, Vec<u8>> =
            ImageBuffer::from_pixel(120, 120, Rgb([10, 10, 10]));
        for y in 30..90 {
            for x in 35..85 {
                image.put_pixel(x, y, Rgb([210, 150, 120]));
            }
        }
        image.save(&path).unwrap();

        let metrics = analyze_camera_frame(&path).unwrap();
        assert!(metrics.present);
        assert!(metrics.face_near_screen);

        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn tts_binary_selection_falls_back_to_espeak_when_piper_model_missing() {
        let selected = select_tts_binary(
            Some("/usr/bin/piper".to_string()),
            None,
            Some("/usr/bin/espeak-ng".to_string()),
        );
        assert_eq!(selected.as_deref(), Some("/usr/bin/espeak-ng"));
    }

    #[test]
    fn tts_binary_selection_keeps_piper_when_model_exists() {
        let selected = select_tts_binary(
            Some("/usr/bin/piper".to_string()),
            Some("/var/lib/lifeos/models/piper/es_MX-claude-high.onnx"),
            Some("/usr/bin/espeak-ng".to_string()),
        );
        assert_eq!(selected.as_deref(), Some("/usr/bin/piper"));
    }

    #[test]
    fn tts_binary_selection_treats_lifeos_piper_as_model_backend() {
        let selected = select_tts_binary(
            Some("/usr/local/bin/lifeos-piper".to_string()),
            None,
            Some("/usr/bin/espeak-ng".to_string()),
        );
        assert_eq!(selected.as_deref(), Some("/usr/bin/espeak-ng"));
    }

    #[test]
    fn tts_model_readiness_requires_companion_json_for_onnx() {
        let dir = std::env::temp_dir().join(format!("lifeos-tts-model-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let model = dir.join("es_MX-test.onnx");
        std::fs::write(&model, b"fake").unwrap();

        assert!(!tts_model_is_ready(model.to_string_lossy().as_ref()));

        let metadata = dir.join("es_MX-test.onnx.json");
        std::fs::write(&metadata, br#"{"audio":{"sample_rate":22050}}"#).unwrap();
        assert!(tts_model_is_ready(model.to_string_lossy().as_ref()));

        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn resolve_existing_tts_model_rejects_incomplete_onnx_asset() {
        let dir = std::env::temp_dir().join(format!("lifeos-tts-resolve-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let model = dir.join("es_MX-broken.onnx");
        std::fs::write(&model, b"fake").unwrap();

        assert!(resolve_existing_tts_model(model.to_string_lossy().as_ref()).is_none());

        std::fs::write(
            dir.join("es_MX-broken.onnx.json"),
            br#"{"audio":{"sample_rate":22050}}"#,
        )
        .unwrap();
        assert_eq!(
            resolve_existing_tts_model(model.to_string_lossy().as_ref()).as_deref(),
            Some(model.to_string_lossy().as_ref())
        );

        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn sanitize_assistant_response_removes_reasoning_scaffolding() {
        let raw = r#"
The user wants me to describe the screen.
I need to break down the content first.
1. Pantalla con terminal abierta.
2. Navegador con dashboard.
Drafting the description:
"#;

        let cleaned = sanitize_assistant_response(raw);
        let lowered = cleaned.to_lowercase();
        assert!(!lowered.contains("the user wants"));
        assert!(!lowered.contains("i need to"));
        assert!(cleaned.contains("Pantalla con terminal abierta."));
    }

    #[test]
    fn sanitize_assistant_response_extracts_quoted_final_text() {
        let raw = r#"Thinking Process: Analyze the request. **Final Polish:** "Hola, listo para ayudarte.""#;
        let cleaned = sanitize_assistant_response(raw);
        assert_eq!(cleaned, "Hola, listo para ayudarte.");
    }

    #[test]
    fn sanitize_assistant_response_uses_safe_fallback_when_only_reasoning_exists() {
        let raw = "Thinking Process: Analyze constraints and draft output.";
        let cleaned = sanitize_assistant_response(raw);
        assert_eq!(cleaned, "Lo siento, no pude generar una respuesta clara.");
    }

    #[test]
    fn prepare_tts_text_chunks_long_content() {
        let raw = "Primera frase con contexto largo para validar segmentacion y una salida hablada mas natural. ".repeat(8);
        let prepared = prepare_tts_text(&raw);
        assert!(prepared.contains('\n'));
    }

    #[tokio::test]
    async fn kill_switch_forces_offline_state() {
        let dir = std::env::temp_dir().join(format!("lifeos-sensory-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let manager = SensoryPipelineManager::new(dir.clone()).unwrap();
        let overlay = OverlayManager::new(dir.join("shots"));
        manager.initialize().await.unwrap();
        let status = manager.trigger_kill_switch(&overlay).await.unwrap();
        assert!(status.kill_switch_active);
        assert_eq!(status.axi_state, AxiState::Offline);
        std::fs::remove_dir_all(dir).ok();
    }
}
