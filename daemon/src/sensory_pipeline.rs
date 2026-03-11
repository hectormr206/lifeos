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
const DEFAULT_WAKE_WORD: &str = "hey axi";
const MAX_RELEVANT_LINES: usize = 8;
const MAX_MEMORY_BYTES: usize = 6 * 1024;
const MIN_AUDIO_SIGNAL_BYTES: usize = 4096;
const PCM_RMS_THRESHOLD: f64 = 450.0;

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
            last_error: None,
            last_updated_at: None,
        }
    }
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

    pub async fn is_screen_awareness_due(&self, interval_seconds: u64) -> bool {
        let state = self.state.read().await;
        let interval_seconds = interval_seconds.clamp(5, 30);
        state
            .vision
            .last_updated_at
            .map(|last| (Utc::now() - last).num_seconds().max(0) as u64 >= interval_seconds)
            .unwrap_or(true)
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

        let audio_path =
            match capture_audio_snippet(&self.data_dir, ALWAYS_ON_CAPTURE_SECONDS).await {
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
                            "You are Axi, the local LifeOS assistant. Answer briefly and helpfully.".to_string(),
                        ),
                        ("user".to_string(), transcript.clone()),
                    ],
                )
                .await?
        };
        let llm_duration_ms = llm_started.elapsed().as_millis() as u64;
        let tokens_per_second = tokens_per_second(chat.tokens_used, llm_duration_ms);
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
            match synthesize_tts(
                &self.data_dir,
                &chat.response,
                request.language.as_deref(),
                request.voice_model.as_deref(),
            )
            .await
            {
                Ok((path, engine)) => {
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

        let latency_ms = session_started.elapsed().as_millis() as u64;
        {
            let mut state = self.state.write().await;
            state.axi_state = if playback_started {
                AxiState::Speaking
            } else {
                AxiState::Idle
            };
            state.heavy_slot = if screen_context.is_some() {
                "vision".to_string()
            } else {
                "llm".to_string()
            };
            state.voice.active = playback_started;
            state.voice.session_id = Some(session_id.clone());
            state.voice.last_transcript = Some(transcript.clone());
            state.voice.last_response = Some(chat.response.clone());
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
                state.vision.last_summary = Some(chat.response.clone());
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

        if !playback_started {
            overlay.set_axi_state(AxiState::Idle, Some("ready")).await?;
        }
        overlay.clear_processing_feedback().await?;

        Ok(VoiceLoopResult {
            session_id,
            transcript,
            response: chat.response,
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
                Some("Describe the user's screen and stay concise."),
            )
            .await?
        } else {
            ai_manager
                .chat(
                    None,
                    vec![
                        (
                            "system".to_string(),
                            "You are Axi. Use OCR context to describe the current screen and answer directly."
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

        let mut degraded = degraded_modes(&state.capabilities, &state.gpu);
        let mut audio_path = None;
        if request.speak {
            match synthesize_tts(
                &self.data_dir,
                &response.response,
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
            state.vision.last_summary = Some(response.response.clone());
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
            response: response.response,
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

        let context = self
            .prepare_screen_context(
                ai_manager,
                screen_capture,
                memory_plane,
                None,
                "Resume brevemente la pantalla actual para memoria operativa.",
            )
            .await?;

        let previous_ocr = state.vision.last_ocr_text.unwrap_or_default();
        if normalize_whitespace(&previous_ocr) == normalize_whitespace(&context.ocr_text) {
            let mut state = self.state.write().await;
            state.vision.last_capture_path = Some(context.screen_path);
            state.vision.last_updated_at = Some(Utc::now());
            let snapshot = state.vision.clone();
            drop(state);
            self.save_state().await?;
            return Ok(Some(snapshot));
        }

        overlay
            .set_axi_state(AxiState::Watching, Some("awareness"))
            .await?;
        let summary = ai_manager
            .chat(
                None,
                vec![
                    (
                        "system".to_string(),
                        "Summarize the current screen for short-term assistant memory in one compact sentence."
                            .to_string(),
                    ),
                    (
                        "user".to_string(),
                        format!(
                            "OCR:\n{}\n\nRelevant lines:\n{}",
                            context.ocr_text,
                            context.relevant_text.join("\n")
                        ),
                    ),
                ],
            )
            .await
            .map(|result| result.response)
            .unwrap_or_else(|_| context.relevant_text.join(" | "));

        let tags = vec![
            "vision".to_string(),
            "screen".to_string(),
            "awareness".to_string(),
        ];
        let memory_content = truncate_for_memory(&format!(
            "summary: {}\nrelevant_lines:\n{}",
            summary,
            context.relevant_text.join("\n")
        ));
        memory_plane
            .add_entry(
                "vision-context",
                "short-term",
                &tags,
                Some("sensor://screen-awareness"),
                55,
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
        Ok(Some(snapshot))
    }

    pub async fn update_presence(
        &self,
        overlay: &OverlayManager,
        follow_along: &FollowAlongManager,
    ) -> Result<PresenceRuntime> {
        let mut snapshot = self.state.read().await.clone();
        let was_present = snapshot.presence.present;
        let camera_available = snapshot.capabilities.camera_device.is_some();
        let camera_consented = snapshot.presence.camera_consented;
        let now = Utc::now();

        let (present, face_near_screen, source) = if camera_available && camera_consented {
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
                ),
                Err(_) => presence_from_activity(follow_along).await,
            }
        } else {
            presence_from_activity(follow_along).await
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

        let ocr_text = extract_ocr(&screen_path, Some("eng"))
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
        tokio::fs::write(&path, raw)
            .await
            .context("Failed to persist sensory pipeline state")?;
        Ok(())
    }
}

async fn detect_capabilities(ai_manager: &AiManager) -> SensoryCapabilities {
    SensoryCapabilities {
        stt_binary: resolve_binary("LIFEOS_STT_BIN", &["whisper-cli", "whisper", "whisper-cpp"])
            .await,
        audio_capture_binary: resolve_binary(
            "LIFEOS_AUDIO_CAPTURE_BIN",
            &["ffmpeg", "arecord", "pw-record", "parecord"],
        )
        .await,
        tts_binary: resolve_binary("LIFEOS_TTS_BIN", &["piper", "espeak-ng"]).await,
        tts_model: resolve_tts_model(None).await,
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
    let gpu_enabled = active_gpu_layers != 0;
    let (
        profile_tier,
        llm_offload_gpu,
        vision_offload_gpu,
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
    let (llm_offload, vision_offload) = if gpu_enabled {
        (llm_offload_gpu, vision_offload_gpu)
    } else {
        ("cpu only", "cpu only")
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
    let binary = resolve_binary("LIFEOS_TTS_BIN", &["piper", "espeak-ng"])
        .await
        .ok_or_else(|| anyhow::anyhow!("no local TTS backend found"))?;

    if binary_basename(&binary) == "espeak-ng" {
        let audio_path = synthesize_with_espeak(data_dir, &binary, text, language).await?;
        return Ok((audio_path, binary));
    }

    let model = resolve_tts_model(voice_model)
        .await
        .ok_or_else(|| anyhow::anyhow!("no Piper voice model configured"))?;

    let tts_dir = data_dir.join("tts");
    tokio::fs::create_dir_all(&tts_dir)
        .await
        .context("Failed to create TTS output dir")?;
    let audio_path = tts_dir.join(format!("axi-{}.wav", uuid::Uuid::new_v4()));

    let mut child = Command::new(&binary)
        .args([
            "--model",
            &model,
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

    Ok((audio_path.to_string_lossy().to_string(), binary))
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

    Ok(audio_path.to_string_lossy().to_string())
}

async fn capture_audio_snippet(data_dir: &Path, duration_seconds: u64) -> Result<String> {
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
            cmd.args([
                "-y",
                "-f",
                "pulse",
                "-i",
                "default",
                "-t",
                &duration_seconds.to_string(),
                "-ac",
                "1",
                "-ar",
                "16000",
                &output_path,
            ]);
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
            cmd
        }
        "pw-record" | "parecord" => {
            let timeout = resolve_binary("LIFEOS_TIMEOUT_BIN", &["timeout"])
                .await
                .ok_or_else(|| anyhow::anyhow!("timeout utility is required for {}", program))?;
            let mut cmd = Command::new(timeout);
            cmd.arg(format!("{}s", duration_seconds)).arg(&binary);
            if program == "pw-record" {
                cmd.args(["--rate", "16000", "--channels", "1", &output_path]);
            } else {
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

    Ok(output_path)
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
    Ok(rms >= PCM_RMS_THRESHOLD)
}

async fn resolve_tts_model(override_model: Option<&str>) -> Option<String> {
    let override_model = override_model
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_string());
    if let Some(model) = override_model {
        if Path::new(&model).exists() {
            return Some(model);
        }
    }

    if let Ok(model) = std::env::var("LIFEOS_TTS_MODEL") {
        let model = model.trim().to_string();
        if !model.is_empty() && Path::new(&model).exists() {
            return Some(model);
        }
    }

    [
        "/var/lib/lifeos/models/piper/es_MX-claude-high.onnx",
        "/var/lib/lifeos/models/piper/es_ES-sharvard-medium.onnx",
        "/var/lib/lifeos/models/piper/en_US-lessac-medium.onnx",
        "/usr/share/lifeos/models/piper/es_MX-claude-high.onnx",
        "/usr/share/lifeos/models/piper/en_US-lessac-medium.onnx",
    ]
    .iter()
    .find(|candidate| Path::new(candidate).exists())
    .map(|candidate| candidate.to_string())
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

    [
        "/var/lib/lifeos/models/whisper/ggml-base.bin",
        "/usr/share/lifeos/models/whisper/ggml-base.bin",
        "/var/lib/lifeos/models/whisper/ggml-base.en.bin",
        "/usr/share/lifeos/models/whisper/ggml-base.en.bin",
        "/var/lib/lifeos/models/whisper/ggml-small.bin",
        "/usr/share/lifeos/models/whisper/ggml-small.bin",
    ]
    .iter()
    .find(|candidate| Path::new(candidate).exists())
    .map(|candidate| candidate.to_string())
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
    binary.map(binary_basename) == Some("piper")
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

fn normalized_wake_word(wake_word: &str) -> String {
    let wake_word = normalize_whitespace(wake_word).to_lowercase();
    if wake_word.is_empty() {
        DEFAULT_WAKE_WORD.to_string()
    } else {
        wake_word
    }
}

fn contains_wake_word(transcript: &str, wake_word: &str) -> bool {
    let transcript = transcript.to_lowercase();
    let wake_word = normalized_wake_word(wake_word);
    transcript.contains(&wake_word)
}

fn strip_wake_word(transcript: &str, wake_word: &str) -> Option<String> {
    let wake_word = normalized_wake_word(wake_word);
    let transcript_lower = transcript.to_lowercase();
    let wake_index = transcript_lower.find(&wake_word)?;
    let suffix = transcript[wake_index + wake_word.len()..]
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

fn tokenize(input: &str) -> Vec<String> {
    input
        .split(|c: char| !c.is_alphanumeric())
        .map(|token| token.trim().to_lowercase())
        .filter(|token| token.len() >= 3)
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

    analyze_camera_frame(&frame_path)
}

#[derive(Debug, Clone, Copy)]
struct CameraPresenceMetrics {
    present: bool,
    face_near_screen: bool,
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
    })
}

fn is_skin_like(r: u8, g: u8, b: u8) -> bool {
    let r = r as i32;
    let g = g as i32;
    let b = b as i32;
    r > 95 && g > 40 && b > 20 && (r - g).abs() > 15 && r > g && r > b
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
    fn wake_word_detection_and_prompt_stripping_work() {
        let transcript = "Hey Axi, que ves en mi pantalla ahora mismo?";
        assert!(contains_wake_word(transcript, "hey axi"));
        assert_eq!(
            strip_wake_word(transcript, "hey axi").as_deref(),
            Some("que ves en mi pantalla ahora mismo")
        );
        assert!(should_include_screen_for_prompt(
            "que ves en mi pantalla ahora mismo"
        ));
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
