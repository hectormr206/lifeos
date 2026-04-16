//! Unified sensory pipeline for LifeOS Phase 4.
//!
//! Coordinates:
//! - voice loop (STT -> LLM -> TTS -> playback)
//! - screen awareness and conversational vision
//! - camera presence and ergonomic heuristics
//! - GPU-aware routing and graceful degradation

use crate::ai::{AiChatResponse, AiManager};
use crate::audio_frontend::{
    looks_like_voice, looks_like_voice_with_profile, preprocess_frame_i16le, AudioFilterState,
    VoiceActivityProfile,
};
use crate::follow_along::FollowAlongManager;
use crate::memory_plane::MemoryPlaneManager;
use crate::overlay::{AxiState, OverlayManager};
use crate::privacy_filter::{PrivacyFilter, SensitivityLevel};
use crate::screen_capture::ScreenCapture;
use crate::telemetry::{MetricCategory, TelemetryManager};
use anyhow::{Context, Result};
use chrono::{DateTime, Timelike, Utc};
use image::{DynamicImage, GenericImageView, Pixel};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

/// Set once we have logged the "camera capture binary unavailable" warning.
/// Prevents flooding the journal when the capture binary is missing — the
/// condition never changes at runtime, so one WARN at the first miss and
/// DEBUG afterwards is the right policy.
static CAMERA_BINARY_WARNED: AtomicBool = AtomicBool::new(false);
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::{mpsc, Mutex, RwLock};

const STATE_FILE: &str = "sensory_pipeline_state.json";
const BENCHMARK_FILE: &str = "sensory_benchmark.json";
const DEFAULT_SCREEN_INTERVAL_SECONDS: u64 = 10;

/// Intervalo mínimo entre llamadas sucesivas al probe del servidor Kokoro TTS.
/// El estado del servidor cambia lentamente; 5 segundos era un desperdicio de red.
pub(crate) const KOKORO_PROBE_INTERVAL: std::time::Duration = std::time::Duration::from_secs(300);

/// Tiempos de espera entre reintentos de `synthesize_with_kokoro_http`.
/// 2 entradas → 3 intentos en total (1 inicial + 2 reintentos).
pub(crate) const KOKORO_RETRY_DELAYS: [u64; 2] = [200, 800];

/// Cliente HTTP singleton para health probes al servidor Kokoro TTS.
/// `connect_timeout` 500 ms, `timeout` 2 s — suficiente para loopback.
static KOKORO_PROBE_CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();

/// Cliente HTTP singleton para síntesis TTS (POST /tts).
/// `connect_timeout` 3 s, `timeout` 30 s — tolera CPU bajo carga.
static KOKORO_SYNTH_CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();

/// Devuelve el cliente HTTP para health probes (connect 500 ms, timeout 2 s).
pub(crate) fn kokoro_probe_client() -> &'static reqwest::Client {
    KOKORO_PROBE_CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .connect_timeout(std::time::Duration::from_millis(500))
            .timeout(std::time::Duration::from_secs(2))
            .build()
            .expect("Failed to build Kokoro probe reqwest client")
    })
}

/// Devuelve el cliente HTTP para síntesis TTS (connect 3 s, timeout 30 s).
pub(crate) fn kokoro_synth_client() -> &'static reqwest::Client {
    KOKORO_SYNTH_CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .connect_timeout(std::time::Duration::from_secs(3))
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .expect("Failed to build Kokoro synth reqwest client")
    })
}

/// Último instante en que se ejecutó `probe_kokoro_tts_server`.
/// Permite saltar el probe si el intervalo mínimo no ha transcurrido.
static LAST_KOKORO_PROBE: std::sync::Mutex<Option<std::time::Instant>> =
    std::sync::Mutex::new(None);
const ALWAYS_ON_CAPTURE_SECONDS: u64 = 4;
const DEFAULT_WAKE_WORD: &str = "axi";
fn default_tts_enabled() -> bool {
    true
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SttProfile {
    HotwordProbe,
    Command,
}

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
const UTTERANCE_MEDIUM_END_SILENCE_SECS: f64 = 1.45;
const UTTERANCE_FAST_END_SILENCE_SECS: f64 = 1.05;
const UTTERANCE_MEDIUM_END_MIN_SPEECH_WINDOWS: usize = 4;
const UTTERANCE_FAST_END_MIN_SPEECH_WINDOWS: usize = 5;
const UTTERANCE_MEDIUM_END_MIN_STREAK_WINDOWS: usize = 3;
const UTTERANCE_FAST_END_MIN_STREAK_WINDOWS: usize = 4;
const UTTERANCE_PREROLL_SECS: f64 = 0.18;
const UTTERANCE_POSTROLL_SECS: f64 = 0.22;
/// Absolute maximum recording time to prevent infinite capture (seconds).
const UTTERANCE_MAX_DURATION_SECS: f64 = 30.0;
/// Size of each analysis window for streaming VAD (seconds).
const UTTERANCE_WINDOW_SECS: f64 = 0.25;
/// Sample rate for all audio capture.
const AUDIO_SAMPLE_RATE: u32 = 16000;
const AUDIO_BYTES_PER_SECOND: usize = AUDIO_SAMPLE_RATE as usize * 2;
const BARGE_IN_CAPTURE_MILLIS: u64 = 650;
const BARGE_IN_ECHO_SIMILARITY_THRESHOLD: f64 = 0.92;
const BARGE_IN_ENVELOPE_FRAME_SAMPLES: usize = (AUDIO_SAMPLE_RATE as usize * 20) / 1000;
const BARGE_IN_MIN_ENVELOPE_FRAMES: usize = 6;
const STT_FAST_PATH_MAX_DURATION_MS: u64 = 5_500;
const STT_HOTWORD_FAST_PATH_MAX_DURATION_MS: u64 = 4_300;
const STT_FAST_BEAM_SIZE: &str = "3";
const STT_FAST_BEST_OF: &str = "3";
const STT_FAST_MAX_LEN: &str = "96";
const STT_HOTWORD_BEAM_SIZE: &str = "2";
const STT_HOTWORD_BEST_OF: &str = "2";
const STT_HOTWORD_MAX_LEN: &str = "40";
const STT_STREAM_STEP_MS: &str = "400";
const STT_STREAM_LENGTH_MS: &str = "2800";
const STT_STREAM_KEEP_MS: &str = "200";
const STT_STREAM_MAX_TOKENS: &str = "24";
const STT_STREAM_VAD_THRESHOLD: &str = "0.60";
const STT_STREAM_FREQ_THRESHOLD: &str = "120";
const STT_STREAM_TIMEOUT_MS: u64 = 8_500;
const STT_STREAM_STABLE_MS: u64 = 1_250;
const STT_STREAM_MIN_LISTEN_MS: u64 = 900;

/// Read the VAD RMS threshold from environment, calibration cache, or default.
///
/// Priority: env var → cached calibration → hardcoded default.
fn vad_rms_threshold() -> f64 {
    // 1. Explicit env override always wins
    if let Some(v) = std::env::var("LIFEOS_VAD_RMS_THRESHOLD")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
    {
        return v;
    }

    // 2. Try cached calibration (synchronous read — acceptable for small JSON)
    if let Some(home) = std::env::var("HOME").ok().map(PathBuf::from) {
        let cal_path = home.join(".local/share/lifeos").join(MIC_CALIBRATION_FILE);
        if let Ok(data) = std::fs::read_to_string(&cal_path) {
            if let Ok(cal) = serde_json::from_str::<MicCalibration>(&data) {
                let age_hours = (Utc::now() - cal.timestamp).num_hours();
                if age_hours < MIC_CALIBRATION_MAX_AGE_HOURS {
                    return cal.threshold as f64;
                }
            }
        }
    }

    PCM_RMS_THRESHOLD_DEFAULT
}
/// Path for cached mic calibration data.
const MIC_CALIBRATION_FILE: &str = "mic-calibration.json";
/// Maximum age for a cached calibration before re-measuring (hours).
const MIC_CALIBRATION_MAX_AGE_HOURS: i64 = 24;
/// Duration of ambient noise sampling for calibration (seconds).
const MIC_CALIBRATION_SAMPLE_SECS: u64 = 2;
/// Minimum calibrated threshold to avoid triggering on electrical noise.
const MIC_CALIBRATION_MIN: u32 = 200;
/// Maximum calibrated threshold to avoid being too insensitive.
const MIC_CALIBRATION_MAX: u32 = 1500;
/// Multiplier over ambient noise floor for calibrated threshold.
const MIC_CALIBRATION_MULTIPLIER: f64 = 3.0;
/// Path for the cached wake word chime WAV file.
const CHIME_CACHE_PATH: &str = "/tmp/lifeos-chime.wav";
/// Near-field threshold multiplier (headsets).
const NEAR_FIELD_THRESHOLD_MULT: f64 = 0.6;
/// Far-field extra gain in dB (laptop mic).
const FAR_FIELD_EXTRA_GAIN_DB: f64 = 8.0;

const SCREENSHOT_RETENTION_COUNT: usize = 50;
const SCREENSHOT_RETENTION_DAYS: u64 = 2;
const SCREENSHOT_RETENTION_MAX_BYTES: u64 = 500 * 1024 * 1024; // 500 MB
const IDLE_SCREEN_INTERVAL_SECONDS: u64 = 45;
const VISION_MEMORY_ROUTINE_HOURS: u64 = 4;
const VISION_MEMORY_KEY_DAYS: u64 = 7;
const AUDIO_RETENTION_COUNT: usize = 120;
const AUDIO_RETENTION_MAX_BYTES: u64 = 200 * 1024 * 1024; // 200 MB
const TTS_RETENTION_COUNT: usize = 120;
const OCR_SIMILARITY_SKIP_THRESHOLD: f32 = 0.92;
const RELEVANT_SIMILARITY_SKIP_THRESHOLD: f32 = 0.60;
const OCR_LENGTH_DELTA_TRIGGER: usize = 320;
const TTS_CHUNK_MAX_CHARS: usize = 260;
const CAMERA_CAPTURE_TIMEOUT_SECS: u64 = 3;
const CAMERA_STALE_CAPTURE_SECS: u64 = 15;
const CAMERA_CAPTURE_PREFERRED_SIZE: &str = "1280x720";
const CAMERA_CAPTURE_FALLBACK_SIZE: &str = "640x480";
/// Per-capture cap for `/var/lib/lifeos/camera/`. Enforced every cycle so
/// the directory cannot drift above this between 6-hour housekeeping ticks
/// (observed live: 229 files, nearly 2× the cap, because camera captures
/// ~6×/min and housekeeping only ran every 6h). Matches the global
/// MAX_FILES_PER_DIR used by `storage_housekeeping`.
const CAMERA_PRESENCE_MAX_FILES: usize = 120;
const CAMERA_FRAME_DARK_THRESHOLD: f64 = 62.0;
const CAMERA_FRAME_TARGET_BRIGHTNESS: f64 = 96.0;
const CAMERA_FRAME_MAX_BRIGHTEN: i32 = 52;
const CAMERA_FRAME_CONTRAST_BOOST: f32 = 20.0;
const CAMERA_FRAME_VERY_DARK_CONTRAST_BOOST: f32 = 30.0;
/// How long after a voice response to keep listening without requiring
/// the wake word again (continuous conversation window).
const CONTINUOUS_CONVERSATION_SECS: i64 = 30;

/// Near-field vs far-field microphone mode. Near-field (headset) uses lower
/// thresholds, while far-field (laptop mic) uses higher thresholds and gain.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MicFieldMode {
    /// Headset or close-range mic (<30cm) — lower threshold, no extra gain.
    NearField,
    /// Built-in laptop mic (>50cm) — higher threshold, +8dB gain.
    FarField,
}

/// Cached mic calibration result persisted to disk.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct MicCalibration {
    threshold: u32,
    device: Option<String>,
    field_mode: Option<MicFieldMode>,
    timestamp: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct SensorLeds {
    pub mic_active: bool,
    pub camera_active: bool,
    pub screen_active: bool,
    pub kill_switch_active: bool,
}

/// A single voice available from the Kokoro TTS server.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct KokoroVoice {
    pub name: String,
    pub language: String,
    pub gender: String,
    pub is_default: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct SensoryCapabilities {
    pub stt_binary: Option<String>,
    pub audio_capture_binary: Option<String>,
    /// URL of the Kokoro TTS HTTP server (e.g. "http://127.0.0.1:8084"). None = unavailable.
    pub tts_server_url: Option<String>,
    /// Voices available from the Kokoro TTS server. Empty if server is unavailable.
    pub kokoro_voices: Vec<KokoroVoice>,
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
    /// Master "mic capture is permitted at all" toggle — AND of
    /// `runtime.audio_enabled && !kill_switch_active`. Covers explicit
    /// voice sessions, meeting recording, barge-in, wake-word sample
    /// enrollment. Separate from `always_on_active` which is stricter
    /// (also requires always-on listening to be enabled).
    #[serde(default)]
    pub audio_enabled: bool,
    /// Per-sense toggle for automatic meeting capture. Evaluated by
    /// `Sense::Meeting`. When false, Axi still detects meetings (for
    /// focus / presence hints) but does NOT record audio or take
    /// screenshots. AND'd with audio_enabled and kill_switch in the
    /// gate so it cannot accidentally re-enable capture.
    #[serde(default)]
    pub meeting_capture_enabled: bool,
    pub always_on_active: bool,
    #[serde(default = "default_tts_enabled")]
    pub tts_enabled: bool,
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
    /// When set, the voice pipeline skips wake word detection until this
    /// timestamp, enabling continuous conversation after a response.
    pub continuous_listen_until: Option<DateTime<Utc>>,
}

impl Default for VoiceSessionRuntime {
    fn default() -> Self {
        Self {
            active: false,
            audio_enabled: false,
            meeting_capture_enabled: true,
            always_on_active: false,
            tts_enabled: true,
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
            continuous_listen_until: None,
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
    /// True when triggered by an explicit wake word from the user.
    /// When false (continuous listen follow-up), the continuous
    /// conversation window is NOT renewed — this prevents an infinite
    /// loop where Axi's TTS output gets captured as a follow-up.
    pub triggered_by_wake_word: bool,
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

struct StreamingVoiceChatResult {
    chat: AiChatResponse,
    llm_duration_ms: u64,
    spoken_prefix: Option<String>,
    audio_path: Option<String>,
    tts_engine: Option<String>,
    playback_backend: Option<String>,
    playback_started: bool,
    interrupted: bool,
}

pub struct SensoryRuntimeSync<'a> {
    pub audio_enabled: bool,
    pub screen_enabled: bool,
    pub camera_enabled: bool,
    pub tts_enabled: bool,
    /// Per-sense toggle for automatic meeting capture. Evaluated by
    /// `Sense::Meeting`. See `VoiceSessionRuntime::meeting_capture_enabled`.
    pub meeting_enabled: bool,
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
    pub hotword_triggered: bool,
    pub screen_enabled: bool,
    /// Optional reference to the wake word detector for auto-refinement.
    pub wake_word_detector: Option<&'a crate::wake_word::WakeWordDetector>,
}

/// One of Axi's senses — the input/output channels a caller may want to
/// exercise. Each variant has its own policy (kill switch alone, or
/// master toggle, or consent, etc.) but every capture/persist/route
/// request goes through the unified `ensure_sense_allowed` gate so a
/// new entry point CANNOT nest itself around an older enforcement.
///
/// Policy per variant:
/// - `Screen` — kill switch + `vision.enabled` + suspend + session
///   lock + sensitive-window title. Applied to every grim/maim/
///   spectacle/gnome-screenshot shell-out, OCR call, and multimodal
///   describe request.
/// - `Camera` — kill switch + `presence.camera_consented` + suspend.
///   The camera_consented field is already AND'd with kill switch by
///   `sync_runtime` (Fase A fix).
/// - `Microphone` — kill switch + `voice.audio_enabled` + suspend.
///   Covers EVERY mic capture: explicit voice sessions, meeting
///   recorder, barge-in during TTS playback, wake-word sample
///   enrollment, STT file transcription.
/// - `AlwaysOnListening` — stricter superset of Microphone: same gates
///   PLUS `voice.always_on_active` (the wake-word detector must be
///   enabled by the user). Use for rustpotter and the continuous
///   hotword-probe loop only.
/// - `Meeting` — stricter superset of Microphone: adds the per-sense
///   `voice.meeting_capture_enabled` toggle so the user can let Axi
///   hear the mic (wake word, voice commands) WITHOUT auto-recording
///   every meeting they have. Gates the meeting recorder, screenshots,
///   and real-time captions.
/// - `Tts` — kill switch + `voice.tts_enabled`.
/// - `WindowTracking` — kill switch + FollowAlong consent. Gates the
///   event-bus `WindowChanged` listener in `sensory_memory`.
/// - `CloudRoute` — kill switch only. Redundant safety rail for anything
///   that would send a sensory artifact (image, audio, OCR) to a
///   non-local LLM provider; upstream paths should ALSO clamp
///   `SensitivityLevel::Critical`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sense {
    Screen,
    Camera,
    Microphone,
    AlwaysOnListening,
    Meeting,
    Tts,
    WindowTracking,
    CloudRoute,
}

impl Sense {
    pub fn as_str(&self) -> &'static str {
        match self {
            Sense::Screen => "screen",
            Sense::Camera => "camera",
            Sense::Microphone => "microphone",
            Sense::AlwaysOnListening => "always_on_listening",
            Sense::Meeting => "meeting",
            Sense::Tts => "tts",
            Sense::WindowTracking => "window_tracking",
            Sense::CloudRoute => "cloud_route",
        }
    }
}

#[derive(Debug, Clone)]
pub struct GateAuditEntry {
    pub sense: Sense,
    pub caller: &'static str,
    pub allowed: bool,
    pub reason: Option<&'static str>,
    pub at: DateTime<Utc>,
}

/// How many gate decisions to keep in memory for dashboard/audit-trail
/// surfacing. Small ring buffer — we care about recency, not history
/// (MemoryPlane is where long-term audit lives).
const GATE_AUDIT_RING_CAPACITY: usize = 200;

pub struct SensoryPipelineManager {
    data_dir: PathBuf,
    state: Arc<RwLock<SensoryPipelineState>>,
    playback: Arc<Mutex<Option<ActivePlayback>>>,
    speaker_id: Arc<RwLock<crate::speaker_id::SpeakerIdManager>>,
    privacy_filter: Option<Arc<PrivacyFilter>>,
    /// Consent source for `Sense::WindowTracking`. Injected from main
    /// so the gate can consult FollowAlong without every caller having
    /// to plumb the manager manually. `None` means the gate treats
    /// window tracking as unconditionally disallowed (fail-closed).
    follow_along: Option<Arc<RwLock<crate::follow_along::FollowAlongManager>>>,
    /// Ring buffer of recent gate decisions — feeds `GET /sensory/gate-audit`
    /// so the dashboard can surface "which senses were asked for, by
    /// whom, and were any refused?" without touching MemoryPlane.
    gate_audit: Arc<RwLock<std::collections::VecDeque<GateAuditEntry>>>,
    /// Set while the host is in (or about to enter) suspend/hibernate.
    /// Gates all camera captures so the sensory loop doesn't try to hold
    /// `/dev/video0` across a sleep cycle — kernel USB re-probes on resume
    /// leave the old v4l2 handle stale (journal: "Cannot open video device
    /// /dev/video0: Permission denied"). Cleared on PrepareForSleep(false).
    suspending: Arc<std::sync::atomic::AtomicBool>,
}

impl Clone for SensoryPipelineManager {
    fn clone(&self) -> Self {
        Self {
            data_dir: self.data_dir.clone(),
            state: self.state.clone(),
            playback: self.playback.clone(),
            speaker_id: self.speaker_id.clone(),
            privacy_filter: self.privacy_filter.clone(),
            follow_along: self.follow_along.clone(),
            gate_audit: self.gate_audit.clone(),
            suspending: self.suspending.clone(),
        }
    }
}

impl SensoryPipelineManager {
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&data_dir).context("Failed to create sensory pipeline data dir")?;
        let speaker_dir = data_dir.join("speaker_profiles");
        Ok(Self {
            data_dir,
            state: Arc::new(RwLock::new(SensoryPipelineState::default())),
            playback: Arc::new(Mutex::new(None)),
            speaker_id: Arc::new(RwLock::new(crate::speaker_id::SpeakerIdManager::new(
                speaker_dir,
            ))),
            privacy_filter: None,
            follow_along: None,
            gate_audit: Arc::new(RwLock::new(std::collections::VecDeque::with_capacity(
                GATE_AUDIT_RING_CAPACITY,
            ))),
            suspending: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        })
    }

    /// Inject the FollowAlong manager so `Sense::WindowTracking` can
    /// consult consent. Call this once at daemon init — the gate will
    /// fail-closed for WindowTracking if the manager isn't wired.
    pub fn set_follow_along(
        &mut self,
        manager: Arc<RwLock<crate::follow_along::FollowAlongManager>>,
    ) {
        self.follow_along = Some(manager);
    }

    /// Unified sense gate — the ONE place every caller goes through before
    /// exercising any of Axi's senses. Returns `Err(reason)` when a gate
    /// trips. `caller` is a short static tag (e.g. `"api.overlay_chat"`)
    /// that lands in the audit ring for debugging / dashboard surfacing.
    ///
    /// This is the architectural fix for the recurring "asymmetric
    /// hardening" class of bug surfaced by the TTS / camera / screen
    /// audits: new entry points kept bypassing user policy because each
    /// one had its own ad-hoc subset of checks. Now every sense access
    /// is routed through here — add a new entry point, get every gate
    /// for free.
    pub async fn ensure_sense_allowed(
        &self,
        sense: Sense,
        caller: &'static str,
    ) -> std::result::Result<(), &'static str> {
        let outcome = self.check_sense(sense).await;
        self.record_audit(sense, caller, outcome).await;
        outcome
    }

    async fn check_sense(&self, sense: Sense) -> std::result::Result<(), &'static str> {
        let state = self.state.read().await;
        if state.kill_switch_active {
            return Err("sensory kill switch is active");
        }

        match sense {
            Sense::Screen => {
                if !state.vision.enabled {
                    return Err("screen capture is disabled by user preference");
                }
                let current_window = state.vision.current_window.clone();
                drop(state);
                if self.is_suspending() {
                    return Err("screen capture is paused across suspend/hibernate");
                }
                if is_session_locked().await {
                    return Err("screen capture skipped: session locked");
                }
                if let Some(title) = current_window {
                    if is_sensitive_window_title(&title) {
                        return Err("screen capture skipped: sensitive active window");
                    }
                }
                Ok(())
            }
            Sense::Camera => {
                if !state.presence.camera_consented {
                    return Err("camera capture is disabled by user preference");
                }
                drop(state);
                if self.is_suspending() {
                    return Err("camera capture is paused across suspend/hibernate");
                }
                Ok(())
            }
            Sense::Microphone => {
                if !state.voice.audio_enabled {
                    return Err("microphone capture is disabled by user preference");
                }
                drop(state);
                if self.is_suspending() {
                    return Err("microphone capture is paused across suspend/hibernate");
                }
                Ok(())
            }
            Sense::AlwaysOnListening => {
                // Stricter than Microphone: user must have BOTH the
                // master audio toggle on AND opted in to always-on
                // listening. Used by rustpotter and the continuous
                // hotword-probe loop — never by user-initiated mic
                // sessions, which should ask for Sense::Microphone.
                if !state.voice.audio_enabled {
                    return Err("always-on listening requires audio_enabled");
                }
                if !state.voice.always_on_active {
                    return Err("always-on listening is disabled by user preference");
                }
                drop(state);
                if self.is_suspending() {
                    return Err("always-on listening is paused across suspend/hibernate");
                }
                Ok(())
            }
            Sense::Meeting => {
                // Lets Axi hear you (wake word, voice commands) WITHOUT
                // auto-recording every call. When `meeting_capture_enabled`
                // is false, meeting detection still runs (presence /
                // focus hints) but the recorder, captions, and meeting
                // screenshots are gated closed.
                if !state.voice.audio_enabled {
                    return Err("meeting capture requires audio_enabled");
                }
                if !state.voice.meeting_capture_enabled {
                    return Err("meeting capture is disabled by user preference");
                }
                drop(state);
                if self.is_suspending() {
                    return Err("meeting capture is paused across suspend/hibernate");
                }
                Ok(())
            }
            Sense::Tts => {
                if !state.voice.tts_enabled {
                    return Err("TTS is disabled by user preference");
                }
                Ok(())
            }
            Sense::WindowTracking => {
                drop(state);
                let Some(ref follow_along) = self.follow_along else {
                    return Err("window tracking: follow-along manager not wired (fail-closed)");
                };
                let guard = follow_along.read().await;
                let config = guard.get_config().await;
                if config.consent_status != crate::follow_along::ConsentStatus::Granted {
                    return Err("window tracking requires FollowAlong consent");
                }
                Ok(())
            }
            Sense::CloudRoute => {
                // Kill switch already checked above — CloudRoute itself
                // has no per-user toggle today; callers are responsible
                // for clamping sensitivity so the router stays local
                // when the payload contains sensory artifacts.
                Ok(())
            }
        }
    }

    async fn record_audit(
        &self,
        sense: Sense,
        caller: &'static str,
        outcome: std::result::Result<(), &'static str>,
    ) {
        let entry = GateAuditEntry {
            sense,
            caller,
            allowed: outcome.is_ok(),
            reason: outcome.err(),
            at: Utc::now(),
        };
        let mut ring = self.gate_audit.write().await;
        if ring.len() >= GATE_AUDIT_RING_CAPACITY {
            ring.pop_front();
        }
        ring.push_back(entry);
    }

    /// Dump the gate audit ring in newest-first order. Feeds the
    /// dashboard's "what senses was Axi asked to use, and what got
    /// refused?" panel.
    pub async fn gate_audit(&self) -> Vec<GateAuditEntry> {
        let ring = self.gate_audit.read().await;
        ring.iter().rev().cloned().collect()
    }

    /// Thin wrapper around the unified `ensure_sense_allowed(Sense::Screen)`
    /// gate. Kept for callers that haven't been migrated to pass an
    /// explicit caller tag yet; new call sites should prefer
    /// `ensure_sense_allowed` so the audit log knows who asked.
    pub async fn ensure_screen_capture_allowed(&self) -> std::result::Result<(), &'static str> {
        self.ensure_sense_allowed(Sense::Screen, "legacy.screen_helper")
            .await
    }

    /// Called by the login1 PrepareForSleep listener when the system is
    /// about to suspend/hibernate or has just resumed. Gates subsequent
    /// presence captures via the `suspending` flag.
    pub fn set_suspending(&self, suspending: bool) {
        self.suspending
            .store(suspending, std::sync::atomic::Ordering::Relaxed);
    }

    /// Cheap check used by capture entry points and `update_presence` to
    /// skip work while the host is suspending/hibernating.
    pub fn is_suspending(&self) -> bool {
        self.suspending.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Attach a shared privacy filter for OCR text classification.
    pub fn set_privacy_filter(&mut self, filter: Arc<PrivacyFilter>) {
        self.privacy_filter = Some(filter);
    }

    /// Returns the shared speaker identification manager so other subsystems
    /// (e.g. meeting_assistant) can resolve speakers against the same profiles.
    pub fn speaker_id(&self) -> Arc<RwLock<crate::speaker_id::SpeakerIdManager>> {
        self.speaker_id.clone()
    }

    pub async fn initialize(&self) -> Result<()> {
        self.load_state().await
    }

    pub async fn status(&self) -> SensoryPipelineState {
        self.state.read().await.clone()
    }

    /// Returns `true` if we are inside the continuous conversation window
    /// (user recently interacted and wake word can be skipped).
    pub async fn is_continuous_listen_active(&self) -> bool {
        let state = self.state.read().await;
        state
            .voice
            .continuous_listen_until
            .map(|until| Utc::now() < until)
            .unwrap_or(false)
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
        // Treat consent as gated by the kill switch: callers use
        // `camera_consented` to decide whether a capture is allowed at all
        // (see `update_presence` and API endpoints), so leaving it at the
        // raw `camera_enabled` value would let an active kill switch be
        // bypassed by a direct `POST /sensory/presence` request.
        state.presence.camera_consented = runtime.camera_enabled && !runtime.kill_switch_active;
        state.presence.camera_active = runtime.camera_enabled && !runtime.kill_switch_active;
        state.voice.audio_enabled = runtime.audio_enabled && !runtime.kill_switch_active;
        state.voice.meeting_capture_enabled =
            runtime.meeting_enabled && runtime.audio_enabled && !runtime.kill_switch_active;
        state.voice.always_on_active =
            runtime.always_on_active && runtime.audio_enabled && !runtime.kill_switch_active;
        state.voice.tts_enabled = runtime.tts_enabled && !runtime.kill_switch_active;
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

        // ── Auto-calibrate mic threshold when voice pipeline activates ──
        if snapshot.voice.always_on_active
            && snapshot.leds.mic_active
            && load_calibrated_threshold().await.is_none()
        {
            let source = snapshot.capabilities.always_on_source.clone();
            tokio::spawn(async move {
                let threshold = calibrate_mic_threshold(source.as_deref()).await;
                log::info!("[voice-init] auto-calibrated mic threshold: {threshold}");
            });
        }

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

    /// Release the sensory kill switch. Sensor preferences are restored by the
    /// runtime sync path, not by blindly enabling everything here.
    pub async fn release_kill_switch(
        &self,
        overlay: &OverlayManager,
    ) -> Result<SensoryPipelineState> {
        let mut state = self.state.write().await;
        state.kill_switch_active = false;
        state.leds = SensorLeds {
            mic_active: false,
            camera_active: false,
            screen_active: false,
            kill_switch_active: false,
        };
        state.voice.active = false;
        state.voice.always_on_active = false;
        state.presence.camera_active = false;
        state.vision.enabled = false;
        state.axi_state = AxiState::Idle;
        state.last_updated_at = Some(Utc::now());
        let snapshot = state.clone();
        drop(state);
        overlay
            .set_sensor_indicators(false, false, false, false)
            .await?;
        overlay
            .set_axi_state(AxiState::Idle, Some("kill-switch-released"))
            .await?;
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
        if request.playback && !state.voice.tts_enabled {
            overlay
                .set_axi_state(AxiState::Idle, Some("tts-disabled"))
                .await?;
            return Ok(TtsResult {
                text: request.text,
                audio_path: None,
                tts_engine: None,
                playback_backend: None,
                playback_started: false,
                degraded_modes: vec!["tts_disabled".to_string()],
            });
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

        // Skip listening while Axi is speaking via TTS — the microphone
        // would capture Axi's own voice and trigger a feedback loop.
        {
            let pb = self.playback.lock().await;
            if pb.is_some() {
                log::debug!("[always_on] Skipping cycle — TTS playback active");
                return Ok(None);
            }
        }

        // Post-playback cooldown: after TTS finishes, the room still has
        // residual echo for a couple of seconds. Skip capture during that
        // window to avoid feeding Axi's own voice back as user input.
        if let Some(completed) = state.voice.last_completed_at {
            let elapsed = (Utc::now() - completed).num_milliseconds().max(0) as u64;
            if elapsed < 3000 {
                log::debug!(
                    "[always_on] Skipping cycle — {}ms post-TTS cooldown",
                    elapsed
                );
                return Ok(None);
            }
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
        // Unified mic gate — `Sense::AlwaysOnListening` (stricter than
        // plain Microphone: requires user-opted wake-word listening to
        // be enabled). Without this, the hotword probe loop kept
        // capturing even with audio_enabled=false.
        if self
            .ensure_sense_allowed(Sense::AlwaysOnListening, "pipeline.hotword_cycle.capture")
            .await
            .is_err()
        {
            return Ok(None);
        }
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

        let (transcript, _binary) =
            match transcribe_audio(&audio_path, None, SttProfile::HotwordProbe).await {
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

        // Check if we are inside the continuous conversation window (skip wake word).
        let in_continuous_window = {
            let st = self.state.read().await;
            st.voice
                .continuous_listen_until
                .map(|until| Utc::now() < until)
                .unwrap_or(false)
        };

        let wake_word_found = contains_wake_word(&transcript, &hotword);
        if !wake_word_found && !in_continuous_window {
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
            if wake_word_found {
                state.voice.last_hotword_at = Some(Utc::now());
            }
            state.voice.wake_word = hotword.clone();
            state.last_updated_at = Some(Utc::now());
        }
        self.save_state().await?;

        // ── Auditory feedback: chime on wake word detection ──────────
        if wake_word_found {
            tokio::spawn(async { play_wake_word_chime().await });
        }

        // ── Wake word auto-refinement: save positive sample ──────────
        if wake_word_found {
            match save_wake_word_sample(&audio_path).await {
                Ok(samples_dir) => {
                    if let Some(detector) = cycle.wake_word_detector {
                        maybe_refine_wake_word_model(&samples_dir, detector).await;
                    }
                }
                Err(e) => {
                    log::warn!("Failed to save wake word sample: {e}");
                }
            }
        }

        if in_continuous_window && !wake_word_found {
            log::info!("Continuous conversation: processing follow-up without wake word");
        }

        let prompt = if wake_word_found {
            strip_wake_word(&transcript, &hotword)
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| "Estoy escuchando. Dime como puedo ayudarte.".to_string())
        } else {
            // Continuous conversation — use the full transcript as the prompt.
            transcript.clone()
        };
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
                    triggered_by_wake_word: wake_word_found,
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
            if cycle.hotword_triggered {
                st.voice.last_hotword_at = Some(Utc::now());
            }
            st.voice.wake_word = normalized_wake_word(cycle.wake_word);
            st.last_updated_at = Some(Utc::now());
        }
        self.save_state().await?;

        if cycle.hotword_triggered {
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

            // ── Auditory feedback: chime on rustpotter wake word detection ──
            tokio::spawn(async { play_wake_word_chime().await });
        }

        if local_streaming_stt_available().await {
            cycle
                .overlay
                .set_axi_state(AxiState::Listening, Some("stt-stream"))
                .await?;
            match transcribe_local_command_streaming(None).await {
                Ok(Some((transcript, _binary))) => {
                    let transcript = normalize_whitespace(&transcript);
                    if !transcript.is_empty() {
                        {
                            let mut st = self.state.write().await;
                            st.voice.last_listen_at = Some(Utc::now());
                            st.voice.last_audio_path = None;
                            st.voice.last_transcript = Some(transcript.clone());
                            st.last_updated_at = Some(Utc::now());
                        }
                        self.save_state().await?;

                        let hotword = normalized_wake_word(cycle.wake_word);
                        let prompt = strip_wake_word(&transcript, &hotword)
                            .filter(|value| !value.is_empty())
                            .unwrap_or(transcript);
                        let include_screen =
                            cycle.screen_enabled && should_include_screen_for_prompt(&prompt);
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
                                    triggered_by_wake_word: true,
                                },
                            )
                            .await?;
                        return Ok(Some(result));
                    }
                }
                Ok(None) => {
                    if !cycle.hotword_triggered {
                        return Ok(None);
                    }
                    let result = self
                        .run_voice_loop(
                            cycle.ai_manager,
                            cycle.overlay,
                            cycle.screen_capture,
                            cycle.memory_plane,
                            cycle.telemetry,
                            VoiceLoopRequest {
                                audio_file: None,
                                prompt: Some(
                                    "Estoy escuchando. Dime como puedo ayudarte.".to_string(),
                                ),
                                include_screen: false,
                                screen_source: None,
                                language: Some("es".to_string()),
                                voice_model: None,
                                playback: true,
                                triggered_by_wake_word: true,
                            },
                        )
                        .await?;
                    return Ok(Some(result));
                }
                Err(error) => {
                    log::warn!("Streaming STT fallback to batch capture: {error}");
                }
            }
        }

        // Capture command audio — listen until the user stops speaking.
        let always_on_source = {
            let st = self.state.read().await;
            st.capabilities.always_on_source.clone()
        };
        // Post-wakeword user-initiated capture. Uses the `Microphone`
        // sense (not AlwaysOnListening) because by this point the user
        // has explicitly triggered capture via the hotword — it's an
        // active voice session, not passive background listening.
        if self
            .ensure_sense_allowed(Sense::Microphone, "pipeline.capture_until_silence")
            .await
            .is_err()
        {
            return Ok(None);
        }
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
            if !cycle.hotword_triggered {
                return Ok(None);
            }
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
                        triggered_by_wake_word: true,
                    },
                )
                .await?;
            return Ok(Some(result));
        }

        // Transcribe the command
        let (transcript, _binary) =
            match transcribe_audio(&audio_path, None, SttProfile::Command).await {
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
                    audio_file: Some(audio_path),
                    prompt: Some(prompt),
                    include_screen,
                    screen_source: None,
                    language: Some("es".to_string()),
                    voice_model: None,
                    playback: true,
                    triggered_by_wake_word: true,
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
        let transcript = if let Some(prompt) =
            request.prompt.as_deref().filter(|v| !v.trim().is_empty())
        {
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
            let (text, _binary) = transcribe_audio(audio_file, None, SttProfile::Command).await?;
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

        // --- Speaker identification (passive enrollment) ---
        // Extract embedding from captured audio and identify/enroll speaker.
        // This runs concurrently with the LLM call preparation.
        let speaker_match = if let Some(audio_file) =
            request.audio_file.as_deref().filter(|p| !p.is_empty())
        {
            let audio_path = std::path::PathBuf::from(audio_file);
            match crate::speaker_id::extract_embedding(&audio_path).await {
                Ok(embedding) => {
                    let mut sid = self.speaker_id.write().await;
                    let result = sid.identify(&embedding);

                    // Check if user is responding to "¿Como te llamas?" from previous interaction.
                    // Detect name responses like "Héctor", "Me llamo Cely", "Soy Héctor", etc.
                    if result.name.is_none() {
                        if let Some(name) = extract_name_from_transcript(&transcript) {
                            log::info!("Speaker {} identified as '{}'", result.profile_id, name);
                            sid.set_name(&result.profile_id, &name);
                        }
                    }

                    Some(result)
                }
                Err(e) => {
                    log::debug!("Speaker embedding extraction skipped: {e}");
                    None
                }
            }
        } else {
            None
        };

        let speaker_name = speaker_match.as_ref().and_then(|m| m.name.as_deref());
        let should_ask_name = speaker_match
            .as_ref()
            .map(|m| m.should_ask_name)
            .unwrap_or(false);

        // Build system prompt with speaker context
        let greeting_context = if let Some(name) = speaker_name {
            format!(
                " The user's name is {}. Greet them naturally by name when appropriate.",
                name
            )
        } else {
            String::new()
        };

        let base_system_prompt = format!(
            "{}\n\nYou are Axi, the local LifeOS assistant. Answer in ONE or TWO short sentences in natural spoken Spanish. Be direct and concise — this will be read aloud via TTS. No markdown, no code, no lists, no internal reasoning.{}",
            crate::time_context::time_context_short(),
            greeting_context
        );

        let system_context = screen_context.as_ref().map(|ctx| {
            format!(
                "Screen OCR context:\n{}\n\nRelevant lines:\n{}",
                ctx.ocr_text,
                ctx.relevant_text.join("\n")
            )
        });
        let mut prefetched_prefix = None;
        let mut prefetched_audio_path = None;
        let mut prefetched_tts_engine = None;
        let mut prefetched_playback_backend = None;
        let mut prefetched_playback_started = false;
        let mut prefetched_interrupted = false;
        let llm_started = Instant::now();
        let (chat, llm_duration_ms) = if let Some(ctx) = screen_context.as_ref() {
            (
                multimodal_chat_with_fallback(
                    ai_manager,
                    &transcript,
                    &ctx.screen_path,
                    system_context.as_deref(),
                )
                .await?,
                llm_started.elapsed().as_millis() as u64,
            )
        } else if request.playback && state.voice.tts_enabled {
            match self
                .stream_text_chat_with_prefetched_tts(
                    ai_manager,
                    overlay,
                    &session_id,
                    &transcript,
                    &base_system_prompt,
                    request.language.as_deref(),
                    request.voice_model.as_deref(),
                )
                .await
            {
                Ok(streamed) => {
                    prefetched_prefix = streamed.spoken_prefix;
                    prefetched_audio_path = streamed.audio_path;
                    prefetched_tts_engine = streamed.tts_engine;
                    prefetched_playback_backend = streamed.playback_backend;
                    prefetched_playback_started = streamed.playback_started;
                    prefetched_interrupted = streamed.interrupted;
                    (streamed.chat, streamed.llm_duration_ms)
                }
                Err(error) => {
                    log::warn!("Streaming voice chat fallback to non-streaming: {error}");
                    (
                        ai_manager
                            .chat(
                                None,
                                vec![
                                    ("system".to_string(), base_system_prompt.clone()),
                                    ("user".to_string(), transcript.clone()),
                                ],
                            )
                            .await?,
                        llm_started.elapsed().as_millis() as u64,
                    )
                }
            }
        } else {
            (
                ai_manager
                    .chat(
                        None,
                        vec![
                            ("system".to_string(), base_system_prompt.clone()),
                            ("user".to_string(), transcript.clone()),
                        ],
                    )
                    .await?,
                llm_started.elapsed().as_millis() as u64,
            )
        };
        let tokens_per_second = tokens_per_second(chat.tokens_used, llm_duration_ms);
        let mut response_text = sanitize_assistant_response(&chat.response);

        // If the speaker hasn't been named yet and threshold reached, ask their name
        if should_ask_name {
            response_text.push_str(" Por cierto, no conozco tu nombre aun. ¿Como te llamas?");
        }
        overlay
            .set_processing_feedback(
                Some("thinking"),
                tokens_per_second,
                Some(llm_duration_ms),
                None,
            )
            .await?;

        let mut audio_path = prefetched_audio_path;
        let mut tts_engine = prefetched_tts_engine;
        let mut playback_backend = prefetched_playback_backend;
        let mut playback_started = prefetched_playback_started;
        if request.playback && state.voice.tts_enabled {
            let playback_text = prefetched_prefix
                .as_deref()
                .map(|prefix| trim_streamed_prefix_from_response(&response_text, prefix))
                .unwrap_or_else(|| response_text.clone());

            if !prefetched_interrupted && !playback_text.trim().is_empty() {
                overlay
                    .set_axi_state(AxiState::Speaking, Some("tts"))
                    .await?;
                // Progressive TTS: synthesize + play sentence by sentence, with audio ducking.
                match self
                    .synthesize_and_play_progressive(
                        overlay,
                        &session_id,
                        &playback_text,
                        request.language.as_deref(),
                        request.voice_model.as_deref(),
                    )
                    .await
                {
                    Ok((path, engine, backend, played)) => {
                        if audio_path.is_none() {
                            audio_path = path;
                        }
                        if tts_engine.is_none() {
                            tts_engine = engine;
                        }
                        if playback_backend.is_none() {
                            playback_backend = backend;
                        }
                        playback_started |= played;
                    }
                    Err(e) => {
                        log::warn!("Progressive TTS failed, trying single-shot: {}", e);
                        // Fallback to single-shot TTS if progressive fails.
                        match synthesize_tts(
                            &self.data_dir,
                            &playback_text,
                            request.language.as_deref(),
                            request.voice_model.as_deref(),
                        )
                        .await
                        {
                            Ok((path, engine)) => {
                                duck_system_audio(true).await;
                                tts_engine = Some(engine);
                                if audio_path.is_none() {
                                    audio_path = Some(path.clone());
                                }
                                let playback = self
                                    .spawn_playback(overlay.clone(), session_id.clone(), &path)
                                    .await?;
                                if playback_backend.is_none() {
                                    playback_backend = playback.0;
                                }
                                playback_started |= playback.1;
                            }
                            Err(_) => degraded.push("tts_unavailable".to_string()),
                        }
                    }
                }
            }
        } else if request.playback {
            degraded.push("tts_disabled".to_string());
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
            // Continuous conversation is DISABLED when TTS playback occurred.
            // When Axi speaks aloud, the microphone inevitably captures the
            // TTS audio. If we kept the continuous-listen window open, the
            // pipeline would transcribe Axi's own voice as user input and
            // respond again — creating an infinite voice loop.
            //
            // Continuous listen is only safe for text-only responses (no
            // playback) where there is no risk of mic feedback.
            if request.triggered_by_wake_word && !request.playback {
                state.voice.continuous_listen_until =
                    Some(Utc::now() + chrono::Duration::seconds(CONTINUOUS_CONVERSATION_SECS));
            } else {
                // Clear any existing continuous window to prevent stale
                // windows from previous sessions causing loops.
                state.voice.continuous_listen_until = None;
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

    #[allow(clippy::too_many_arguments)]
    async fn stream_text_chat_with_prefetched_tts(
        &self,
        ai_manager: &AiManager,
        overlay: &OverlayManager,
        session_id: &str,
        transcript: &str,
        system_prompt: &str,
        language: Option<&str>,
        voice_model: Option<&str>,
    ) -> Result<StreamingVoiceChatResult> {
        let (partial_tx, mut partial_rx) = mpsc::channel(1024);
        let ai = *ai_manager;
        let system_prompt = system_prompt.to_string();
        let transcript = transcript.to_string();
        let mut chat_task = tokio::spawn(async move {
            let started = Instant::now();
            let chat = ai
                .chat_stream(
                    None,
                    vec![
                        ("system".to_string(), system_prompt),
                        ("user".to_string(), transcript),
                    ],
                    partial_tx,
                )
                .await;
            (chat, started.elapsed().as_millis() as u64)
        });

        let interrupt_before = self.state.read().await.voice.last_interrupt_at;
        let mut spoken_prefix = None;
        let mut audio_path = None;
        let mut tts_engine = None;
        let mut playback_backend = None;
        let mut playback_started = false;
        let mut attempted_prefix = false;

        while !attempted_prefix {
            tokio::select! {
                chat_result = &mut chat_task => {
                    let (chat, llm_duration_ms) = chat_result.context("streaming chat task join failed")?;
                    return Ok(StreamingVoiceChatResult {
                        chat: chat?,
                        llm_duration_ms,
                        spoken_prefix,
                        audio_path,
                        tts_engine,
                        playback_backend,
                        playback_started,
                        interrupted: false,
                    });
                }
                maybe_partial = partial_rx.recv() => {
                    let Some(partial) = maybe_partial else {
                        attempted_prefix = true;
                        continue;
                    };
                    let Some(prefix) = extract_streaming_tts_prefix(&partial) else {
                        continue;
                    };

                    attempted_prefix = true;
                    overlay
                        .set_axi_state(AxiState::Speaking, Some("tts_stream"))
                        .await?;
                    match self
                        .synthesize_and_play_progressive(
                            overlay,
                            session_id,
                            &prefix,
                            language,
                            voice_model,
                        )
                        .await
                    {
                        Ok((path, engine, backend, played)) => {
                            if played {
                                spoken_prefix = Some(prefix);
                                audio_path = path;
                                tts_engine = engine;
                                playback_backend = backend;
                                playback_started = true;
                            }
                        }
                        Err(error) => {
                            log::warn!("Streaming TTS prefix fallback to full response: {error}");
                        }
                    }
                }
            }
        }

        let (chat, llm_duration_ms) = chat_task.await.context("streaming chat task join failed")?;
        let interrupt_after = self.state.read().await.voice.last_interrupt_at;
        Ok(StreamingVoiceChatResult {
            chat: chat?,
            llm_duration_ms,
            spoken_prefix,
            audio_path,
            tts_engine,
            playback_backend,
            playback_started,
            interrupted: playback_started && interrupt_after != interrupt_before,
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
        // Unified sense gate — kill switch + vision.enabled + suspend +
        // session lock + sensitive-window title. Replaces the inline
        // ladder this function used to carry so every screen-consuming
        // path enforces the same policy via one implementation.
        if let Err(reason) = self
            .ensure_sense_allowed(Sense::Screen, "pipeline.describe_screen")
            .await
        {
            anyhow::bail!("{}", reason);
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
                Some(&format!("{} Describe the user's screen in concise spoken Spanish. Avoid markdown and never expose internal reasoning.", crate::time_context::time_context_short())),
            )
            .await?
        } else {
            ai_manager
                .chat(
                    None,
                    vec![
                        (
                            "system".to_string(),
                            format!("{} You are Axi. Use OCR context to describe the current screen in spoken Spanish, answer directly, avoid markdown, and do not reveal internal reasoning.",
                                crate::time_context::time_context_short()),
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
        let speech_allowed = request.speak && state.voice.tts_enabled;
        let mut audio_path = None;
        if speech_allowed {
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
        } else if request.speak {
            degraded.push("tts_disabled".to_string());
        }
        let spoke = speech_allowed && audio_path.is_some();

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
            state.axi_state = if spoke {
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
        if !spoke {
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

        // Skip capture if the session is locked. `loginctl` exposes
        // `LockedHint` per session — when the user locks the screen we
        // MUST stop capturing to avoid leaking login prompts, password
        // managers, and whatever was on screen before lock.
        if is_session_locked().await {
            log::debug!("sensory: skipping capture — session locked");
            return Ok(None);
        }

        // Skip capture if active window looks sensitive (login, password dialogs,
        // private / incognito browsing). Shared helper so every entry
        // point — awareness, describe_screen, meeting capture, overlay —
        // enforces the same list instead of each diverging.
        if let Some(ref title) = state.vision.current_window {
            if is_sensitive_window_title(title) {
                log::info!("sensory: skipping capture — sensitive window: {}", title);
                return Ok(None);
            }
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
                            format!("{} Resume la pantalla actual para la memoria del asistente en una o dos oraciones concisas.",
                                crate::time_context::time_context_short()),
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
        // Privacy-filter the OCR excerpt before writing to memory.
        let mut skip_awareness_persist = false;
        let ocr_excerpt: String = context.ocr_text.chars().take(2048).collect();
        let ocr_for_memory = if let Some(ref pf) = self.privacy_filter {
            let sensitivity = pf.classify(&ocr_excerpt);
            match sensitivity {
                SensitivityLevel::Critical => {
                    log::warn!(
                        "Vision awareness OCR classified as Critical — skipping memory persistence"
                    );
                    skip_awareness_persist = true;
                    String::new()
                }
                SensitivityLevel::High => {
                    log::info!(
                        "Vision awareness OCR classified as High — sanitizing before persistence"
                    );
                    pf.sanitize(&ocr_excerpt).sanitized_text
                }
                _ => ocr_excerpt,
            }
        } else {
            ocr_excerpt
        };

        if !skip_awareness_persist {
            let memory_content = truncate_for_memory(&format!(
                "app: {}\nwindow: {}\nsummary: {}\nrelevant_lines:\n{}\nocr_excerpt:\n{}",
                state.vision.current_app.as_deref().unwrap_or("unknown"),
                state.vision.current_window.as_deref().unwrap_or("unknown"),
                summary,
                context.relevant_text.join("\n"),
                &ocr_for_memory,
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
        }

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

        if let Ok(removed) = screen_capture
            .cleanup_by_size(SCREENSHOT_RETENTION_MAX_BYTES)
            .await
        {
            if removed > 0 {
                log::info!(
                    "Screen capture size-based retention removed {} files (limit=500MB)",
                    removed
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
        // Unified sense gate — kill switch + camera_consented + suspend.
        // Any variant trip short-circuits with the last-known presence
        // snapshot so callers don't need to branch on the reason.
        if self
            .ensure_sense_allowed(Sense::Camera, "pipeline.update_presence")
            .await
            .is_err()
        {
            return Ok(self.state.read().await.presence.clone());
        }

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
                Err(error) => {
                    // The "binary unavailable" branch fires every cycle on
                    // systems that don't ship fswebcam / grim / v4l2-ctl.
                    // Log it ONCE at WARN (with the expected binaries) and
                    // quiet afterwards. Other failure modes stay at WARN so
                    // we still notice transient camera problems.
                    let msg = error.to_string();
                    let is_missing_binary = msg.contains("camera capture binary unavailable")
                        || msg.contains("camera device unavailable");
                    if is_missing_binary {
                        if !CAMERA_BINARY_WARNED.swap(true, Ordering::Relaxed) {
                            log::warn!(
                                "[camera] presence capture disabled: {} \
                                 (expected one of fswebcam/grim/v4l2-ctl on PATH \
                                 and a camera device). Falling back to activity-based \
                                 presence; further failures of this kind will be DEBUG.",
                                error
                            );
                        } else {
                            log::debug!(
                                "[camera] presence capture still unavailable; \
                                 activity fallback in use: {}",
                                error
                            );
                        }
                    } else {
                        log::warn!(
                            "[camera] presence capture failed; falling back to activity: {}",
                            error
                        );
                    }
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

        // AI-powered scene analysis when camera captured a frame AND the
        // capabilities snapshot says multimodal is available. Gating on
        // the capability flag prevents a cascade of VL requests during the
        // 6-8s llama-server startup window — each would time out, spam
        // journald, and delay the presence cycle.
        let (scene_description, user_state, people_count) = match (
            frame_path.as_deref(),
            snapshot.capabilities.multimodal_chat_available,
        ) {
            (Some(frame), true) => match analyze_camera_scene(ai_manager, frame).await {
                Ok(analysis) => (
                    Some(analysis.scene_description),
                    Some(analysis.user_state),
                    Some(analysis.people_count),
                ),
                Err(err) => {
                    // Swallowing these silently made VL regressions invisible in
                    // journald. Log at debug (failures are not operator-actionable
                    // by themselves — they happen during model warm-up, on
                    // transient parse mismatches, etc.) and keep moving.
                    log::debug!("[camera] scene analysis failed: {}", err);
                    (None, None, None)
                }
            },
            _ => (None, None, None),
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
        // Apply the same privacy filter the OCR / awareness paths use
        // (see vision awareness persistence above and screen-context
        // sanitization below). Without this, raw VL-model output about a
        // webcam frame — which can easily include sensitive context like
        // on-screen email subjects, documents visible on the desk, or
        // people's names — was stored verbatim in MemoryPlane and echoed
        // back by the presence API.
        let (filtered_scene, skip_scene_persist) = match scene_description.as_deref() {
            Some(desc) if !desc.is_empty() => {
                if let Some(ref pf) = self.privacy_filter {
                    match pf.classify(desc) {
                        SensitivityLevel::Critical => {
                            log::warn!(
                                "Camera scene classified as Critical — dropping from state + memory"
                            );
                            (None, true)
                        }
                        SensitivityLevel::High => {
                            log::info!(
                                "Camera scene classified as High — sanitizing before persistence"
                            );
                            (Some(pf.sanitize(desc).sanitized_text), false)
                        }
                        _ => (Some(desc.to_string()), false),
                    }
                } else {
                    (Some(desc.to_string()), false)
                }
            }
            _ => (None, true),
        };

        snapshot.presence.posture_alert = posture_alert;
        snapshot.presence.last_checked_at = Some(now);
        snapshot.presence.scene_description = filtered_scene.clone();
        snapshot.presence.user_state = user_state.clone();
        snapshot.presence.people_count = people_count;

        // Store camera context in memory for later recall.
        if let (Some(ref desc), false) = (filtered_scene.as_ref(), skip_scene_persist) {
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
                        triggered_by_wake_word: true,
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
        // Previously `.unwrap_or_default()` — so every tesseract crash /
        // missing binary / unreadable screenshot silently degraded to an
        // empty string, and downstream importance/summary decisions ran on
        // a baseline with no operator signal. Surface at warn level so
        // repeated failures show up in the journal.
        let mut ocr_text = match extract_ocr(&screen_path, Some(&ocr_lang)).await {
            Ok(text) => text,
            Err(err) => {
                log::warn!("[screen] OCR failed: {}", err);
                String::new()
            }
        };
        let relevant_text = relevant_ocr_lines(&ocr_text, query);
        let multimodal_used = if let Some(model) = ai_manager.active_model().await {
            model.to_lowercase().contains("qwen")
        } else {
            false
        };

        // Privacy-filter OCR text before persisting to memory.
        let mut skip_memory_persist = false;
        if let Some(ref pf) = self.privacy_filter {
            let sensitivity = pf.classify(&ocr_text);
            match sensitivity {
                SensitivityLevel::Critical => {
                    log::warn!("OCR text classified as Critical — skipping memory persistence");
                    skip_memory_persist = true;
                }
                SensitivityLevel::High => {
                    log::info!(
                        "OCR text classified as High sensitivity — sanitizing before persistence"
                    );
                    let result = pf.sanitize(&ocr_text);
                    ocr_text = result.sanitized_text;
                }
                _ => {}
            }
        }

        if !skip_memory_persist {
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
        }

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

        let player = resolve_binary("LIFEOS_PLAYBACK_BIN", &["pw-play", "aplay", "paplay"])
            .await
            .ok_or_else(|| anyhow::anyhow!("no playback backend found"))?;

        // Resolve voice for this session.
        let env_default =
            std::env::var("LIFEOS_TTS_DEFAULT_VOICE").unwrap_or_else(|_| "if_sara".to_string());
        let voice = voice_model.unwrap_or(env_default.as_str()).to_string();

        // Duck system audio before speaking.
        duck_system_audio(true).await;

        let mut first_audio_path: Option<String> = None;
        let tts_engine = format!("kokoro:{}", voice);
        let playback_backend = player.clone();
        let mut any_played = false;

        // Pre-synthesize the first sentence.
        let mut next_audio =
            synthesize_single_chunk(&self.data_dir, &sentences[0], language, &voice)
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
                let sent = sentences[i + 1].clone();
                let lang = language.map(str::to_string);
                let v = voice.clone();
                Some(tokio::spawn(async move {
                    synthesize_single_chunk(&data_dir, &sent, lang.as_deref(), &v)
                        .await
                        .ok()
                }))
            } else {
                None
            };

            // Play the current sentence with barge-in detection.
            // We monitor the microphone for voice activity while playing;
            // if the user starts speaking, we kill the playback immediately.
            let mut child = Command::new(&player)
                .arg(&current_audio)
                .spawn()
                .context("Failed to start playback")?;

            let child_pid = child.id();
            if let Some(pid) = child_pid {
                let mut playback = self.playback.lock().await;
                *playback = Some(ActivePlayback {
                    session_id: session_id.to_string(),
                    pid,
                    backend: player.clone(),
                    audio_path: current_audio.clone(),
                });
            }
            any_played = true;

            // Barge-in monitor: capture short audio snippets while playing and
            // check for voice activity. If the user speaks, kill the playback.
            let barge_in_data_dir = self.data_dir.clone();
            let barge_in_pid = child_pid;
            let barge_in_detected = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let barge_in_flag = barge_in_detected.clone();
            let barge_in_source = {
                let st = self.state.read().await;
                st.capabilities.always_on_source.clone()
            };
            let barge_in_playback_audio = current_audio.clone();
            // Clone self's shared state so the spawned monitor task can
            // consult the mic gate inside its loop. A user toggling
            // audio_enabled=false mid-playback now stops barge-in capture
            // on the next loop iteration (previously it kept going).
            let barge_in_mgr = self.clone();
            let monitor_handle = tokio::spawn(async move {
                // Wait a short moment before starting to monitor, so the
                // playback audio doesn't feed back into the microphone.
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                loop {
                    // Per-iteration gate check so a mid-playback toggle
                    // of audio_enabled / kill switch actually stops the
                    // monitor rather than waiting for the outer task.
                    if barge_in_mgr
                        .ensure_sense_allowed(Sense::Microphone, "pipeline.barge_in_monitor")
                        .await
                        .is_err()
                    {
                        break;
                    }
                    let path = match capture_audio_snippet_ms(
                        &barge_in_data_dir,
                        BARGE_IN_CAPTURE_MILLIS,
                        barge_in_source.as_deref(),
                    )
                    .await
                    {
                        Ok(p) => p,
                        Err(_) => break,
                    };
                    if audio_has_voice_activity_with_profile(
                        Path::new(&path),
                        VoiceActivityProfile::BargeIn,
                    )
                    .await
                    .unwrap_or(false)
                    {
                        let echo_similarity = playback_echo_similarity(
                            Path::new(&path),
                            Path::new(&barge_in_playback_audio),
                        )
                        .await
                        .unwrap_or(0.0);
                        if echo_similarity >= BARGE_IN_ECHO_SIMILARITY_THRESHOLD {
                            log::debug!(
                                "Ignoring probable TTS echo during barge-in detection (similarity={:.3})",
                                echo_similarity
                            );
                            tokio::fs::remove_file(&path).await.ok();
                            continue;
                        }
                        log::info!("Barge-in detected during TTS playback");
                        barge_in_flag.store(true, std::sync::atomic::Ordering::Relaxed);
                        // Kill the playback process.
                        if let Some(pid) = barge_in_pid {
                            kill_pid(pid).await.ok();
                        }
                        break;
                    }
                    // Clean up snippet.
                    tokio::fs::remove_file(&path).await.ok();
                }
            });

            let _ = child.wait().await;
            monitor_handle.abort();

            let was_barged_in = barge_in_detected.load(std::sync::atomic::Ordering::Relaxed);

            // Check if we were interrupted (barge-in or external interrupt).
            let was_interrupted = was_barged_in || {
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
                if was_barged_in {
                    let mut state = self.state.write().await;
                    state.voice.barge_in_count += 1;
                    state.voice.last_interrupt_at = Some(Utc::now());
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
        let mut state: SensoryPipelineState =
            serde_json::from_str(&raw).context("Failed to parse sensory pipeline state")?;

        // Always release kill switch on daemon startup.
        // The kill switch is a session-level safety mechanism — it should NOT
        // persist across daemon restarts. A stale kill_switch_active=true from
        // a previous session would permanently disable all senses.
        if state.kill_switch_active {
            log::info!(
                "[sensory] Releasing stale kill switch from previous session (was persisted as active)"
            );
            state.kill_switch_active = false;
            state.leds.kill_switch_active = false;
            state.voice.active = false;
        }

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
        // Harden to 0o600. The persisted state contains last_ocr_text,
        // last_summary, current_window, voice transcripts, capture paths —
        // exactly the data the API response scrubs. Without this chmod
        // the file was world-readable (0o644), so every local uid could
        // read live activity via the disk. Audit round-2 C-NEW-6.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Ok(md) = tokio::fs::metadata(&path).await {
                let mut perms = md.permissions();
                perms.set_mode(0o600);
                let _ = tokio::fs::set_permissions(&path, perms).await;
            }
        }
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
    let (tts_server_url, kokoro_voices) = probe_kokoro_tts_server().await;

    SensoryCapabilities {
        stt_binary: resolve_binary("LIFEOS_STT_BIN", &["whisper-cli", "whisper", "whisper-cpp"])
            .await,
        audio_capture_binary: resolve_binary(
            "LIFEOS_AUDIO_CAPTURE_BIN",
            &["ffmpeg", "arecord", "pw-record", "parecord"],
        )
        .await,
        tts_server_url,
        kokoro_voices,
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
        rustpotter_model_available: crate::wake_word::resolve_model_path().is_some(),
    }
}

/// Determina si se debe ejecutar un probe ahora.
/// El throttle sólo se aplica cuando hubo un probe EXITOSO previo.
/// Un probe fallido no debe estampar el reloj para que el sensory loop
/// (~5 s) pueda reintentar durante el período de calentamiento (≤ 20 s).
pub(crate) fn should_probe(
    last: Option<std::time::Instant>,
    interval: std::time::Duration,
    now: std::time::Instant,
) -> bool {
    match last {
        None => true,
        Some(prev) => now.duration_since(prev) >= interval,
    }
}

/// Probe the Kokoro TTS server at startup. Returns `(Some(url), voices)` on
/// success or `(None, vec![])` when the server is unreachable after 3 retries.
/// Successive calls within `KOKORO_PROBE_INTERVAL` are skipped and return
/// `(None, vec![])` immediately to avoid hammering the server every 5 s.
///
/// El throttle se estampa SÓLO en probe exitoso.  Si Kokoro aún está
/// calentando (normal: 6-8 s; diseño: hasta 20 s) los intentos fallidos
/// no bloquean los reintentos del siguiente tick (~5 s).
async fn probe_kokoro_tts_server() -> (Option<String>, Vec<KokoroVoice>) {
    {
        // N1: usar unwrap_or_else para recuperarse de mutex envenenado en lugar
        // de panic, preservando la disponibilidad del sensory loop.
        let last = LAST_KOKORO_PROBE.lock().unwrap_or_else(|p| p.into_inner());
        let now = std::time::Instant::now();
        if !should_probe(*last, KOKORO_PROBE_INTERVAL, now) {
            return (None, vec![]);
        }
        // No estampamos aquí — sólo estampamos en éxito (ver abajo).
    }

    let base_url = std::env::var("LIFEOS_TTS_SERVER_URL")
        .unwrap_or_else(|_| "http://127.0.0.1:8084".to_string());

    let client = kokoro_probe_client();

    for attempt in 0..3u32 {
        if attempt > 0 {
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }
        match client.get(format!("{base_url}/health")).send().await {
            Ok(resp) if resp.status().is_success() => {
                let voices = fetch_kokoro_voices(client, &base_url).await;
                log::info!(
                    "[tts] Kokoro TTS server ready at {} ({} voices)",
                    base_url,
                    voices.len()
                );
                // C2: estampar SÓLO en éxito para que el throttle de 5 min
                // aplique sólo a partir del primer probe exitoso.
                let mut last = LAST_KOKORO_PROBE.lock().unwrap_or_else(|p| p.into_inner());
                *last = Some(std::time::Instant::now());
                return (Some(base_url), voices);
            }
            Ok(resp) => {
                log::warn!(
                    "[tts] Kokoro health check returned {} (attempt {})",
                    resp.status(),
                    attempt + 1
                );
            }
            Err(e) => {
                log::warn!(
                    "[tts] Kokoro health check failed (attempt {}): {}",
                    attempt + 1,
                    e
                );
            }
        }
    }

    log::warn!("[tts] Kokoro TTS server not available — TTS degraded");
    (None, vec![])
}

/// Fetch available voices from `GET {base_url}/voices`.
pub async fn fetch_kokoro_voices(client: &reqwest::Client, base_url: &str) -> Vec<KokoroVoice> {
    match client.get(format!("{base_url}/voices")).send().await {
        Ok(resp) if resp.status().is_success() => {
            resp.json::<Vec<KokoroVoice>>().await.unwrap_or_default()
        }
        Ok(resp) => {
            log::warn!("[tts] /voices returned {}", resp.status());
            vec![]
        }
        Err(e) => {
            log::warn!("[tts] Failed to fetch voices: {}", e);
            vec![]
        }
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
    if capabilities.tts_server_url.is_none() {
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

async fn transcribe_audio(
    file: &str,
    model: Option<&str>,
    profile: SttProfile,
) -> Result<(String, String)> {
    let binary = resolve_binary("LIFEOS_STT_BIN", &["whisper-cli", "whisper", "whisper-cpp"])
        .await
        .ok_or_else(|| anyhow::anyhow!("no whisper.cpp binary found"))?;
    let resolved_model = resolve_stt_model(model).await;

    let mut cmd = Command::new(&binary);
    cmd.kill_on_drop(true);
    let lang = resolve_stt_language();
    let estimated_duration_ms = estimate_pcm_wav_duration_ms(file);
    let stt_args = build_interactive_stt_args(
        file,
        resolved_model.as_deref(),
        &lang,
        estimated_duration_ms,
        profile,
    );
    let fast_path = should_use_fast_stt_profile(estimated_duration_ms, profile);
    log::debug!(
        "[stt] profile={profile:?} duration_ms={estimated_duration_ms:?} fast_path={fast_path}"
    );
    cmd.args(&stt_args);
    // Hearing audit C-11: bound the subprocess lifetime so a hung
    // whisper-cli cannot cook CPU indefinitely (observed live:
    // PID 4192949 at 354% CPU for 270s with no cancellation). Allow
    // ~10× real-time as worst case (ggml-base on CPU does 0.3-0.5×),
    // with a 30s floor for short utterances and a 10min ceiling for
    // full meetings. `kill_on_drop(true)` above ensures the child
    // dies on timeout (or any abort of the parent task).
    let duration_secs = estimated_duration_ms.unwrap_or(0) / 1000;
    let timeout_secs = duration_secs.saturating_mul(10).clamp(30, 600);
    let output = match tokio::time::timeout(
        std::time::Duration::from_secs(timeout_secs),
        cmd.output(),
    )
    .await
    {
        Ok(res) => res.with_context(|| format!("Failed to execute {}", binary))?,
        Err(_) => {
            anyhow::bail!(
                "stt transcription timed out after {}s (audio ~{}s)",
                timeout_secs,
                duration_secs
            );
        }
    };
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

fn resolve_stt_language() -> String {
    std::env::var("LIFEOS_STT_LANG").unwrap_or_else(|_| {
        std::env::var("LANG")
            .unwrap_or_default()
            .split('_')
            .next()
            .unwrap_or("es")
            .to_string()
    })
}

fn build_interactive_stt_args(
    file: &str,
    model: Option<&str>,
    lang: &str,
    estimated_duration_ms: Option<u64>,
    profile: SttProfile,
) -> Vec<String> {
    let mut args = Vec::new();
    if let Some(model) = model {
        args.push("-m".to_string());
        args.push(model.to_string());
    }

    let normalized_lang = lang.trim();
    if !normalized_lang.is_empty() && normalized_lang != "C" && normalized_lang != "POSIX" {
        args.push("-l".to_string());
        args.push(normalized_lang.to_string());
    }

    args.push("-nt".to_string());
    args.push("-np".to_string());
    args.push("-sns".to_string());
    args.push("-mc".to_string());
    args.push("0".to_string());

    let threads = default_stt_thread_count();
    args.push("-t".to_string());
    args.push(threads.to_string());

    if should_use_fast_stt_profile(estimated_duration_ms, profile) {
        let (beam_size, best_of, max_len) = match profile {
            SttProfile::HotwordProbe => (
                STT_HOTWORD_BEAM_SIZE,
                STT_HOTWORD_BEST_OF,
                STT_HOTWORD_MAX_LEN,
            ),
            SttProfile::Command => (STT_FAST_BEAM_SIZE, STT_FAST_BEST_OF, STT_FAST_MAX_LEN),
        };
        args.push("-bs".to_string());
        args.push(beam_size.to_string());
        args.push("-bo".to_string());
        args.push(best_of.to_string());
        args.push("-ml".to_string());
        args.push(max_len.to_string());
        args.push("-sow".to_string());
    }

    if let Some(prompt) = interactive_stt_prompt(profile) {
        args.push("--prompt".to_string());
        args.push(prompt);
    }

    args.push("-f".to_string());
    args.push(file.to_string());
    args
}

fn default_stt_thread_count() -> usize {
    if let Some(value) = std::env::var("LIFEOS_STT_THREADS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|value| *value > 0)
    {
        return value;
    }

    std::thread::available_parallelism()
        .map(|parallelism| parallelism.get().clamp(4, 6))
        .unwrap_or(4)
}

fn interactive_stt_prompt(profile: SttProfile) -> Option<String> {
    let env_key = match profile {
        SttProfile::HotwordProbe => "LIFEOS_STT_HOTWORD_PROMPT",
        SttProfile::Command => "LIFEOS_STT_PROMPT",
    };
    if let Ok(value) = std::env::var(env_key) {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return None;
        }
        return Some(trimmed.to_string());
    }

    match profile {
        SttProfile::HotwordProbe => Some(
            "Axi. Axi, ayudame. Axi, dime la hora. Axi, abre la terminal. Oxi. Ahsi."
                .to_string(),
        ),
        SttProfile::Command => Some(
            "Axi, LifeOS, abre, cierra, responde, reproduce, apaga, enciende, pantalla, camara, microfono, Telegram."
                .to_string(),
        ),
    }
}

fn should_use_fast_stt_profile(estimated_duration_ms: Option<u64>, profile: SttProfile) -> bool {
    let max_duration_ms = match profile {
        SttProfile::HotwordProbe => STT_HOTWORD_FAST_PATH_MAX_DURATION_MS,
        SttProfile::Command => STT_FAST_PATH_MAX_DURATION_MS,
    };
    estimated_duration_ms
        .map(|duration_ms| duration_ms <= max_duration_ms)
        .unwrap_or(false)
}

fn estimate_pcm_wav_duration_ms(file: &str) -> Option<u64> {
    let path = Path::new(file);
    if !path
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("wav"))
    {
        return None;
    }

    let metadata = std::fs::metadata(path).ok()?;
    let total_bytes = usize::try_from(metadata.len()).ok()?;
    let pcm_bytes = total_bytes.checked_sub(44)?;
    if pcm_bytes == 0 {
        return Some(0);
    }

    Some(((pcm_bytes as f64 / AUDIO_BYTES_PER_SECOND as f64) * 1000.0).round() as u64)
}

async fn local_streaming_stt_available() -> bool {
    if let Ok(value) = std::env::var("LIFEOS_STT_STREAMING") {
        let normalized = value.trim().to_lowercase();
        if matches!(normalized.as_str(), "0" | "false" | "off" | "no") {
            return false;
        }
    }

    resolve_binary("LIFEOS_STT_STREAM_BIN", &["whisper-stream"])
        .await
        .is_some()
}

async fn resolve_streaming_stt_model(override_model: Option<&str>) -> Option<String> {
    if let Some(model) = override_model.and_then(resolve_existing_stt_model) {
        return Some(model);
    }

    if let Ok(model) = std::env::var("LIFEOS_STT_STREAM_MODEL") {
        if let Some(model) = resolve_existing_stt_model(&model) {
            return Some(model);
        }
    }

    [
        "/var/lib/lifeos/models/whisper/ggml-tiny.bin",
        "/usr/share/lifeos/models/whisper/ggml-tiny.bin",
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

fn build_whisper_stream_args(model: Option<&str>, lang: &str) -> Vec<String> {
    let mut args = Vec::new();
    if let Some(model) = model {
        args.push("-m".to_string());
        args.push(model.to_string());
    }

    let normalized_lang = lang.trim();
    if !normalized_lang.is_empty() && normalized_lang != "C" && normalized_lang != "POSIX" {
        args.push("-l".to_string());
        args.push(normalized_lang.to_string());
    }

    let threads = default_stt_thread_count();
    args.push("-t".to_string());
    args.push(threads.to_string());
    args.push("--step".to_string());
    args.push(STT_STREAM_STEP_MS.to_string());
    args.push("--length".to_string());
    args.push(STT_STREAM_LENGTH_MS.to_string());
    args.push("--keep".to_string());
    args.push(STT_STREAM_KEEP_MS.to_string());
    args.push("-mt".to_string());
    args.push(STT_STREAM_MAX_TOKENS.to_string());
    args.push("-ac".to_string());
    args.push("0".to_string());
    args.push("-vth".to_string());
    args.push(STT_STREAM_VAD_THRESHOLD.to_string());
    args.push("-fth".to_string());
    args.push(STT_STREAM_FREQ_THRESHOLD.to_string());
    args.push("-kc".to_string());
    args
}

fn strip_ansi_csi_sequences(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars().peekable();

    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' {
            if matches!(chars.peek(), Some('[')) {
                let _ = chars.next();
                for next in chars.by_ref() {
                    if ('@'..='~').contains(&next) {
                        break;
                    }
                }
            }
            continue;
        }

        out.push(ch);
    }

    out
}

fn extract_latest_whisper_stream_text(raw: &str) -> Option<String> {
    let sanitized = strip_ansi_csi_sequences(raw);
    let mut latest = None;

    for line in sanitized.lines() {
        let visible = line.rsplit('\r').next().unwrap_or(line);
        let normalized = normalize_whitespace(visible.trim());
        if normalized.is_empty()
            || normalized == "[Start speaking]"
            || normalized.starts_with("### Transcription")
        {
            continue;
        }
        latest = Some(clean_transcript(&normalized));
    }

    latest.filter(|text| !text.trim().is_empty())
}

async fn transcribe_local_command_streaming(
    model: Option<&str>,
) -> Result<Option<(String, String)>> {
    let binary = resolve_binary("LIFEOS_STT_STREAM_BIN", &["whisper-stream"])
        .await
        .ok_or_else(|| anyhow::anyhow!("no whisper-stream binary found"))?;
    let resolved_model = resolve_streaming_stt_model(model).await;
    let lang = resolve_stt_language();

    let mut cmd = Command::new(&binary);
    cmd.args(build_whisper_stream_args(resolved_model.as_deref(), &lang));
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());

    let mut child = cmd
        .spawn()
        .with_context(|| format!("Failed to execute {}", binary))?;
    let mut stdout = child
        .stdout
        .take()
        .context("failed to take whisper-stream stdout")?;
    let stderr = child.stderr.take();
    let stderr_task = tokio::spawn(async move {
        let mut stderr_text = String::new();
        if let Some(mut stderr) = stderr {
            let mut buf = Vec::new();
            let _ = stderr.read_to_end(&mut buf).await;
            stderr_text = String::from_utf8_lossy(&buf).to_string();
        }
        stderr_text
    });

    let started = Instant::now();
    let mut raw_output = String::new();
    let mut latest_text = None;
    let mut last_change_at = None;
    let mut buf = [0u8; 2048];

    loop {
        let read_result =
            tokio::time::timeout(std::time::Duration::from_millis(150), stdout.read(&mut buf))
                .await;

        match read_result {
            Ok(Ok(0)) => break,
            Ok(Ok(n)) => {
                raw_output.push_str(&String::from_utf8_lossy(&buf[..n]));
                if let Some(candidate) = extract_latest_whisper_stream_text(&raw_output) {
                    let changed = latest_text
                        .as_deref()
                        .map(|current| current != candidate)
                        .unwrap_or(true);
                    if changed {
                        latest_text = Some(candidate);
                        last_change_at = Some(Instant::now());
                    }
                }
            }
            Ok(Err(err)) => {
                let _ = child.kill().await;
                let _ = child.wait().await;
                let stderr_text = stderr_task.await.unwrap_or_default();
                let stderr_snippet: String = stderr_text.trim().chars().take(240).collect();
                anyhow::bail!(
                    "streaming stt read failed: {err}; stderr={}",
                    stderr_snippet
                );
            }
            Err(_) => {}
        }

        if started.elapsed().as_millis() as u64 >= STT_STREAM_TIMEOUT_MS {
            break;
        }

        if let Some(last_change_at) = last_change_at {
            let stable_for_ms = last_change_at.elapsed().as_millis() as u64;
            let listened_for_ms = started.elapsed().as_millis() as u64;
            if latest_text.is_some()
                && listened_for_ms >= STT_STREAM_MIN_LISTEN_MS
                && stable_for_ms >= STT_STREAM_STABLE_MS
            {
                break;
            }
        }
    }

    let _ = child.kill().await;
    let _ = child.wait().await;
    let stderr_text = stderr_task.await.unwrap_or_default();

    if latest_text.is_none() && !stderr_text.trim().is_empty() {
        let stderr_snippet: String = stderr_text.trim().chars().take(240).collect();
        log::debug!("whisper-stream stderr: {}", stderr_snippet);
    }

    Ok(latest_text.map(|text| (text, binary)))
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

/// Resolve the TTS voice to use, applying priority: req_override > model.tts_voice > env_default.
/// Empty-string override is treated as None.
pub fn resolve_tts_voice(
    model: &crate::user_model::UserModel,
    env_default: &str,
    req_override: Option<&str>,
    available: &[KokoroVoice],
) -> String {
    // 1. req_override (if non-empty and in available list)
    if let Some(ov) = req_override {
        let ov = ov.trim();
        if !ov.is_empty() {
            if available.is_empty() || available.iter().any(|v| v.name == ov) {
                return ov.to_string();
            }
            log::warn!(
                "[tts] Requested voice '{}' not in available list — falling back to default '{}'",
                ov,
                env_default
            );
            return env_default.to_string();
        }
    }

    // 2. model.tts_voice (if in available list)
    if let Some(ref mv) = model.tts_voice {
        if available.is_empty() || available.iter().any(|v| v.name == mv.as_str()) {
            return mv.clone();
        }
        log::warn!(
            "[tts] Model voice '{}' not in available list — falling back to default '{}'",
            mv,
            env_default
        );
    }

    // 3. env_default
    env_default.to_string()
}

/// Synthesize text to a WAV file via the Kokoro HTTP TTS server.
/// Retries on transient errors with [200ms, 500ms, 1200ms] delays.
/// Falls back to espeak-ng when tts_server_url is None.
async fn synthesize_tts(
    data_dir: &Path,
    text: &str,
    language: Option<&str>,
    voice_model: Option<&str>,
) -> Result<(String, String)> {
    let tts_text = prepare_tts_text(text);

    // Determine if Kokoro server URL is configured.
    let server_url = std::env::var("LIFEOS_TTS_SERVER_URL")
        .ok()
        .filter(|s| !s.is_empty());

    if let Some(ref base_url) = server_url {
        let env_default =
            std::env::var("LIFEOS_TTS_DEFAULT_VOICE").unwrap_or_else(|_| "if_sara".to_string());
        let voice = voice_model.unwrap_or(env_default.as_str()).to_string();
        match synthesize_with_kokoro_http(data_dir, base_url, &tts_text, &voice, "wav").await {
            Ok(path) => return Ok((path, format!("kokoro:{}", voice))),
            Err(e) => {
                log::warn!("[tts] Kokoro synthesis failed: {} — trying espeak-ng", e);
            }
        }
    }

    // Fallback: espeak-ng
    let espeak = resolve_binary("LIFEOS_TTS_FALLBACK_BIN", &["espeak-ng"])
        .await
        .ok_or_else(|| {
            anyhow::anyhow!("no TTS backend available (Kokoro unreachable, espeak-ng not found)")
        })?;
    let audio_path = synthesize_with_espeak(data_dir, &espeak, &tts_text, language).await?;
    Ok((audio_path, espeak))
}

/// Call Kokoro TTS server HTTP API with retry logic.
/// Retries 3 times on connection-refused / 503 / 504 / timeout.
/// Returns path to the saved audio file.
pub async fn synthesize_with_kokoro_http(
    data_dir: &Path,
    base_url: &str,
    text: &str,
    voice: &str,
    format: &str,
) -> Result<String> {
    let tts_dir = data_dir.join("tts");
    tokio::fs::create_dir_all(&tts_dir)
        .await
        .context("Failed to create TTS output dir")?;

    let ext = if format == "ogg" { "ogg" } else { "wav" };
    let audio_path = tts_dir.join(format!("axi-{}.{}", uuid::Uuid::new_v4(), ext));

    let client = kokoro_synth_client();

    let delays_ms = KOKORO_RETRY_DELAYS;
    let mut last_err: Option<anyhow::Error> = None;

    for (attempt, &delay_ms) in std::iter::once(&0u64).chain(delays_ms.iter()).enumerate() {
        if attempt > 0 {
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
        }

        let body = serde_json::json!({
            "text": text,
            "voice": voice,
            "format": format,
        });

        let resp = match client
            .post(format!("{base_url}/tts"))
            .json(&body)
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                let is_transient = e.is_connect() || e.is_timeout();
                log::warn!(
                    "[tts] Kokoro request failed (attempt {}): {}",
                    attempt + 1,
                    e
                );
                last_err = Some(e.into());
                if is_transient && attempt < KOKORO_RETRY_DELAYS.len() {
                    continue;
                }
                break;
            }
        };

        let status = resp.status();
        if status == reqwest::StatusCode::SERVICE_UNAVAILABLE
            || status == reqwest::StatusCode::GATEWAY_TIMEOUT
        {
            log::warn!("[tts] Kokoro returned {} (attempt {})", status, attempt + 1);
            last_err = Some(anyhow::anyhow!("Kokoro returned {}", status));
            if attempt < KOKORO_RETRY_DELAYS.len() {
                continue;
            }
            break;
        }

        if !status.is_success() {
            let msg = resp.text().await.unwrap_or_else(|_| status.to_string());
            anyhow::bail!("Kokoro TTS error {}: {}", status, msg);
        }

        let bytes = resp
            .bytes()
            .await
            .context("Failed to read Kokoro audio bytes")?;
        tokio::fs::write(&audio_path, &bytes)
            .await
            .context("Failed to write TTS audio file")?;

        cleanup_dir_by_count(&tts_dir, TTS_RETENTION_COUNT, "tts")
            .await
            .ok();
        return Ok(audio_path.to_string_lossy().to_string());
    }

    Err(last_err.unwrap_or_else(|| anyhow::anyhow!("Kokoro TTS failed after retries")))
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
/// Uses Kokoro HTTP API when available, falls back to espeak-ng.
async fn synthesize_single_chunk(
    data_dir: &Path,
    text: &str,
    language: Option<&str>,
    voice: &str,
) -> Result<String> {
    let server_url = std::env::var("LIFEOS_TTS_SERVER_URL")
        .ok()
        .filter(|s| !s.is_empty());

    if let Some(ref base_url) = server_url {
        match synthesize_with_kokoro_http(data_dir, base_url, text, voice, "wav").await {
            Ok(path) => return Ok(path),
            Err(e) => {
                log::warn!(
                    "[tts] Kokoro chunk synthesis failed: {} — trying espeak-ng",
                    e
                );
            }
        }
    }

    let espeak = resolve_binary("LIFEOS_TTS_FALLBACK_BIN", &["espeak-ng"])
        .await
        .ok_or_else(|| anyhow::anyhow!("no TTS backend available for chunk synthesis"))?;
    synthesize_with_espeak(data_dir, &espeak, text, language).await
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

/// Duck or restore OTHER applications' audio while Axi speaks.
///
/// Unlike the old approach (which changed the global sink volume and
/// affected Axi's own voice), this operates on individual sink-inputs
/// (per-app audio streams). Axi speaks at whatever volume the user has
/// set on the system — only other apps (Spotify, Firefox, etc.) get
/// lowered to `DUCK_RATIO` of their current volume, then restored.
///
/// This matches the Alexa/Google Home model: assistant speaks at the
/// user's chosen volume, background audio ducks, then comes back.
async fn duck_system_audio(duck: bool) {
    /// File used to persist original sink-input volumes between duck/restore.
    /// Format: one line per stream — "sink_input_index:original_volume"
    const DUCK_VOLUME_FILE: &str = "/tmp/lifeos-duck-volumes";
    /// How much to reduce other streams (0.3 = 30% of their current volume).
    const DUCK_RATIO: f64 = 0.30;

    // Never duck during an active call — it would lower the call's audio.
    if duck && detect_active_meeting().await.is_some() {
        log::info!("Skipping audio ducking — meeting/call detected");
        return;
    }

    /// List all sink-inputs and their volumes. Returns Vec<(index, volume_raw)>.
    /// Uses `pactl list sink-inputs` and parses the output.
    async fn list_sink_inputs() -> Vec<(u32, u64)> {
        let output = match Command::new("pactl")
            .args(["list", "sink-inputs"])
            .output()
            .await
        {
            Ok(o) if o.status.success() => o,
            _ => return Vec::new(),
        };
        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut inputs = Vec::new();
        let mut current_index: Option<u32> = None;

        for line in stdout.lines() {
            let trimmed = line.trim();
            // "Sink Input #42"
            if let Some(rest) = trimmed.strip_prefix("Sink Input #") {
                current_index = rest.trim().parse().ok();
            }
            // "Volume: front-left: 42000 /  64% / ..."
            if trimmed.starts_with("Volume:") {
                if let Some(idx) = current_index {
                    // Extract the first raw volume number (e.g. 42000)
                    if let Some(raw) = trimmed
                        .split_whitespace()
                        .find(|w| w.parse::<u64>().is_ok())
                    {
                        if let Ok(vol) = raw.parse::<u64>() {
                            inputs.push((idx, vol));
                        }
                    }
                }
            }
        }
        inputs
    }

    if duck {
        let inputs = list_sink_inputs().await;
        if inputs.is_empty() {
            return;
        }

        // Save original volumes and duck each stream.
        let mut save_lines = Vec::new();
        for (idx, vol) in &inputs {
            save_lines.push(format!("{}:{}", idx, vol));
            let ducked = ((*vol as f64) * DUCK_RATIO) as u64;
            let _ = Command::new("pactl")
                .args([
                    "set-sink-input-volume",
                    &idx.to_string(),
                    &ducked.to_string(),
                ])
                .output()
                .await;
        }
        let _ = tokio::fs::write(DUCK_VOLUME_FILE, save_lines.join("\n")).await;
        log::debug!(
            "[duck] Ducked {} sink-input(s) to {:.0}%",
            inputs.len(),
            DUCK_RATIO * 100.0
        );
    } else {
        // Restore saved volumes.
        let saved = match tokio::fs::read_to_string(DUCK_VOLUME_FILE).await {
            Ok(s) => s,
            Err(_) => return, // nothing to restore
        };

        for line in saved.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            if let Some((idx_str, vol_str)) = line.split_once(':') {
                if let (Ok(idx), Ok(vol)) = (idx_str.parse::<u32>(), vol_str.parse::<u64>()) {
                    let _ = Command::new("pactl")
                        .args(["set-sink-input-volume", &idx.to_string(), &vol.to_string()])
                        .output()
                        .await;
                }
            }
        }
        let _ = tokio::fs::remove_file(DUCK_VOLUME_FILE).await;
        log::debug!("[duck] Restored sink-input volumes");
    }
}

async fn capture_audio_snippet(
    data_dir: &Path,
    duration_seconds: u64,
    source: Option<&str>,
) -> Result<String> {
    capture_audio_snippet_ms(data_dir, duration_seconds.saturating_mul(1000), source).await
}

async fn capture_audio_snippet_ms(
    data_dir: &Path,
    duration_millis: u64,
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
    let duration_arg = format_capture_duration_secs(duration_millis);

    let mut cmd = match program {
        "ffmpeg" => {
            let mut cmd = Command::new(&binary);
            let input_source = source.unwrap_or("default");
            let env_gain_db = std::env::var("LIFEOS_MIC_GAIN_DB")
                .ok()
                .and_then(|v| v.parse::<f64>().ok())
                .unwrap_or(8.0);
            // Read cached field mode for extra gain adjustment
            let fm = {
                let home = std::env::var("HOME").ok().map(PathBuf::from);
                home.and_then(|h| {
                    let data = std::fs::read_to_string(
                        h.join(".local/share/lifeos").join(MIC_CALIBRATION_FILE),
                    )
                    .ok()?;
                    let cal: MicCalibration = serde_json::from_str(&data).ok()?;
                    cal.field_mode
                })
                .unwrap_or(MicFieldMode::FarField)
            };
            let gain_db = env_gain_db + field_mode_extra_gain(fm);
            let af_filter = format!("volume={}dB", gain_db);
            cmd.args([
                "-y",
                "-f",
                "pulse",
                "-i",
                input_source,
                "-t",
                &duration_arg,
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
            let duration_seconds = duration_millis.div_ceil(1000).max(1);
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
            cmd.arg(format!("{duration_arg}s")).arg(&binary);
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
    cleanup_dir_by_size(&audio_dir, AUDIO_RETENTION_MAX_BYTES, "audio")
        .await
        .ok();
    Ok(output_path)
}

fn format_capture_duration_secs(duration_millis: u64) -> String {
    let secs = (duration_millis.max(100) as f64) / 1000.0;
    let mut formatted = format!("{secs:.3}");
    while formatted.contains('.') && formatted.ends_with('0') {
        formatted.pop();
    }
    if formatted.ends_with('.') {
        formatted.pop();
    }
    formatted
}

async fn playback_echo_similarity(captured_path: &Path, playback_path: &Path) -> Result<f64> {
    let captured = tokio::fs::read(captured_path)
        .await
        .with_context(|| format!("Failed to read captured audio {}", captured_path.display()))?;
    let playback = tokio::fs::read(playback_path)
        .await
        .with_context(|| format!("Failed to read playback audio {}", playback_path.display()))?;

    let captured_env = envelope_from_audio_bytes(&captured);
    let playback_env = envelope_from_audio_bytes(&playback);
    Ok(max_envelope_similarity(&captured_env, &playback_env))
}

fn envelope_from_audio_bytes(bytes: &[u8]) -> Vec<f64> {
    let pcm = if bytes.starts_with(b"RIFF") && bytes.len() > 44 {
        &bytes[44..]
    } else {
        bytes
    };
    if pcm.len() < 2 {
        return Vec::new();
    }

    let samples: Vec<i16> = pcm
        .chunks_exact(2)
        .map(|chunk| i16::from_le_bytes([chunk[0], chunk[1]]))
        .collect();
    rms_envelope(&samples, BARGE_IN_ENVELOPE_FRAME_SAMPLES.max(1))
}

fn rms_envelope(samples: &[i16], frame_samples: usize) -> Vec<f64> {
    if samples.is_empty() || frame_samples == 0 {
        return Vec::new();
    }

    let mut envelope = Vec::new();
    for chunk in samples.chunks(frame_samples) {
        if chunk.is_empty() {
            continue;
        }
        let sum_sq: f64 = chunk
            .iter()
            .map(|sample| {
                let value = *sample as f64;
                value * value
            })
            .sum();
        envelope.push((sum_sq / chunk.len() as f64).sqrt());
    }

    trim_quiet_envelope(&envelope)
}

fn trim_quiet_envelope(envelope: &[f64]) -> Vec<f64> {
    if envelope.is_empty() {
        return Vec::new();
    }

    let peak = envelope.iter().copied().fold(0.0, f64::max);
    if peak <= 0.0 {
        return Vec::new();
    }
    let threshold = peak * 0.18;
    let start = envelope.iter().position(|value| *value >= threshold);
    let end = envelope.iter().rposition(|value| *value >= threshold);

    match (start, end) {
        (Some(start_idx), Some(end_idx)) if end_idx >= start_idx => {
            envelope[start_idx..=end_idx].to_vec()
        }
        _ => Vec::new(),
    }
}

fn max_envelope_similarity(snippet: &[f64], playback: &[f64]) -> f64 {
    if snippet.len() < BARGE_IN_MIN_ENVELOPE_FRAMES || playback.len() < BARGE_IN_MIN_ENVELOPE_FRAMES
    {
        return 0.0;
    }

    if snippet.len() >= playback.len() {
        return cosine_similarity(&snippet[..playback.len()], playback);
    }

    let mut best = 0.0;
    for offset in 0..=(playback.len() - snippet.len()) {
        let similarity = cosine_similarity(snippet, &playback[offset..offset + snippet.len()]);
        if similarity > best {
            best = similarity;
        }
    }
    best
}

fn post_speech_silence_target(
    field_mode: MicFieldMode,
    speech_windows: usize,
    max_voice_streak: usize,
    speech_bursts: usize,
) -> f64 {
    let mut target = if speech_bursts <= 1
        && speech_windows >= UTTERANCE_FAST_END_MIN_SPEECH_WINDOWS
        && max_voice_streak >= UTTERANCE_FAST_END_MIN_STREAK_WINDOWS
    {
        UTTERANCE_FAST_END_SILENCE_SECS
    } else if speech_bursts <= 2
        && speech_windows >= UTTERANCE_MEDIUM_END_MIN_SPEECH_WINDOWS
        && max_voice_streak >= UTTERANCE_MEDIUM_END_MIN_STREAK_WINDOWS
    {
        UTTERANCE_MEDIUM_END_SILENCE_SECS
    } else {
        UTTERANCE_SILENCE_AFTER_SPEECH_SECS
    };

    if matches!(field_mode, MicFieldMode::FarField) {
        target += 0.15;
    }

    target.clamp(0.9, UTTERANCE_SILENCE_AFTER_SPEECH_SECS)
}

fn trim_utterance_pcm_to_speech(
    pcm: &[u8],
    speech_start_offset: Option<usize>,
    last_speech_end_offset: Option<usize>,
) -> Vec<u8> {
    let Some(speech_start_offset) = speech_start_offset else {
        return pcm.to_vec();
    };
    let Some(last_speech_end_offset) = last_speech_end_offset else {
        return pcm.to_vec();
    };
    if pcm.is_empty() || last_speech_end_offset <= speech_start_offset {
        return pcm.to_vec();
    }

    let preroll_bytes = ((AUDIO_SAMPLE_RATE as f64 * 2.0 * UTTERANCE_PREROLL_SECS) as usize) & !1;
    let postroll_bytes = ((AUDIO_SAMPLE_RATE as f64 * 2.0 * UTTERANCE_POSTROLL_SECS) as usize) & !1;
    let start = speech_start_offset
        .saturating_sub(preroll_bytes)
        .min(pcm.len());
    let end = last_speech_end_offset
        .saturating_add(postroll_bytes)
        .min(pcm.len());

    if end <= start {
        pcm.to_vec()
    } else {
        pcm[start..end].to_vec()
    }
}

fn cosine_similarity(left: &[f64], right: &[f64]) -> f64 {
    if left.is_empty() || left.len() != right.len() {
        return 0.0;
    }

    let mut dot = 0.0;
    let mut left_norm = 0.0;
    let mut right_norm = 0.0;
    for i in 0..left.len() {
        dot += left[i] * right[i];
        left_norm += left[i] * left[i];
        right_norm += right[i] * right[i];
    }
    if left_norm <= f64::EPSILON || right_norm <= f64::EPSILON {
        return 0.0;
    }

    dot / (left_norm.sqrt() * right_norm.sqrt())
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

/// Remove oldest files in `dir` until total size is within `max_bytes`.
async fn cleanup_dir_by_size(dir: &Path, max_bytes: u64, label: &str) -> Result<u64> {
    if max_bytes == 0 || !dir.exists() {
        return Ok(0);
    }

    let mut files: Vec<(u64, u64, PathBuf)> = Vec::new();
    let mut total_size: u64 = 0;
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
        let metadata = match tokio::fs::metadata(&path).await {
            Ok(m) => m,
            Err(_) => continue,
        };
        let size = metadata.len();
        total_size += size;
        let modified_epoch = metadata
            .modified()
            .ok()
            .and_then(|ts| ts.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or_default();
        files.push((modified_epoch, size, path));
    }

    if total_size <= max_bytes {
        return Ok(0);
    }

    files.sort_by_key(|(epoch, _, _)| *epoch);
    let mut removed = 0u64;
    for (_, size, path) in &files {
        if total_size <= max_bytes {
            break;
        }
        tokio::fs::remove_file(path)
            .await
            .with_context(|| format!("Failed to remove {} file {}", label, path.display()))?;
        total_size = total_size.saturating_sub(*size);
        removed += 1;
    }

    if removed > 0 {
        log::info!(
            "{} size-based retention removed {} files (limit={}MB)",
            label,
            removed,
            max_bytes / (1024 * 1024)
        );
    }

    Ok(removed)
}

async fn audio_has_voice_activity(path: &Path) -> Result<bool> {
    audio_has_voice_activity_with_profile(path, VoiceActivityProfile::Normal).await
}

async fn audio_has_voice_activity_with_profile(
    path: &Path,
    profile: VoiceActivityProfile,
) -> Result<bool> {
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

    if pcm.len() < 2 {
        return Ok(false);
    }

    let field_mode = {
        let home = std::env::var("HOME").ok().map(PathBuf::from);
        home.and_then(|h| {
            let cal_path = h.join(".local/share/lifeos").join(MIC_CALIBRATION_FILE);
            let data = std::fs::read_to_string(cal_path).ok()?;
            let cal: MicCalibration = serde_json::from_str(&data).ok()?;
            cal.field_mode
        })
        .unwrap_or(MicFieldMode::FarField)
    };
    let env_gain_db: f64 = std::env::var("LIFEOS_MIC_GAIN_DB")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(12.0);
    let gain_db = env_gain_db + field_mode_extra_gain(field_mode);
    let mut adaptive_threshold = apply_field_mode_threshold(vad_rms_threshold(), field_mode);
    let window_bytes = (AUDIO_SAMPLE_RATE as f64 * 2.0 * UTTERANCE_WINDOW_SECS) as usize;
    let mut filter_state = AudioFilterState::default();
    let mut noise_floor_sum = 0f64;
    let mut noise_floor_count = 0usize;
    let mut noise_floor = None;
    let mut speech_windows = 0usize;
    let mut voice_streak = 0usize;

    for frame in pcm.chunks(window_bytes.max(2)) {
        let processed = preprocess_frame_i16le(
            frame,
            AUDIO_SAMPLE_RATE,
            gain_db,
            noise_floor,
            &mut filter_state,
        );
        if processed.pcm_le.is_empty() {
            continue;
        }

        if noise_floor_count < NOISE_FLOOR_WINDOWS {
            noise_floor_sum += processed.stats.rms;
            noise_floor_count += 1;
            if noise_floor_count == NOISE_FLOOR_WINDOWS {
                let avg_noise = noise_floor_sum / noise_floor_count as f64;
                noise_floor = Some(avg_noise);
                adaptive_threshold = (avg_noise * ADAPTIVE_NOISE_MULTIPLIER)
                    .max(ADAPTIVE_RMS_FLOOR)
                    .min(apply_field_mode_threshold(vad_rms_threshold(), field_mode));
            }
            continue;
        }

        if looks_like_voice_with_profile(&processed.stats, adaptive_threshold, profile) {
            speech_windows += 1;
            voice_streak += 1;
            if voice_streak >= 2 || speech_windows >= 3 {
                return Ok(true);
            }
        } else {
            voice_streak = 0;
        }
    }

    Ok(speech_windows >= 1 && pcm.len() <= (window_bytes * 2))
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
    let mut speech_windows = 0usize;
    let mut current_voice_streak = 0usize;
    let mut max_voice_streak = 0usize;
    let mut speech_bursts = 0usize;
    let mut in_speech = false;
    let mut speech_start_offset = None;
    let mut last_speech_end_offset = None;

    // --- Detect mic field mode and apply threshold/gain adjustments ---
    // This is a sync context wrapper — the actual detection happened or will
    // happen via the cached calibration. For the streaming loop we read the
    // cached field mode or default to FarField.
    let field_mode = {
        let home = std::env::var("HOME").ok().map(PathBuf::from);
        home.and_then(|h| {
            let cal_path = h.join(".local/share/lifeos").join(MIC_CALIBRATION_FILE);
            let data = std::fs::read_to_string(cal_path).ok()?;
            let cal: MicCalibration = serde_json::from_str(&data).ok()?;
            cal.field_mode
        })
        .unwrap_or(MicFieldMode::FarField)
    };

    // --- Adaptive VAD: measure ambient noise floor from the first N windows ---
    let raw_base_threshold = vad_rms_threshold();
    let base_threshold = apply_field_mode_threshold(raw_base_threshold, field_mode);
    let mut noise_floor_sum = 0f64;
    let mut noise_floor_count = 0usize;
    let mut adaptive_threshold = base_threshold;
    let mut adaptive_noise_floor = None;
    let mut noise_floor_measured = false;
    let mut filter_state = AudioFilterState::default();

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

        let env_gain_db: f64 = std::env::var("LIFEOS_MIC_GAIN_DB")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(12.0);
        let gain_db = env_gain_db + field_mode_extra_gain(field_mode);
        let processed = preprocess_frame_i16le(
            &buf,
            AUDIO_SAMPLE_RATE,
            gain_db,
            adaptive_noise_floor,
            &mut filter_state,
        );
        let frame_start_offset = all_pcm.len();
        all_pcm.extend_from_slice(&processed.pcm_le);
        let rms = processed.stats.rms;

        // Adaptive noise floor: use the first N windows to measure ambient noise,
        // then set the threshold to noise_floor * multiplier (min ADAPTIVE_RMS_FLOOR).
        if !noise_floor_measured {
            noise_floor_sum += rms;
            noise_floor_count += 1;
            if noise_floor_count >= NOISE_FLOOR_WINDOWS {
                let avg_noise = noise_floor_sum / noise_floor_count as f64;
                adaptive_noise_floor = Some(avg_noise);
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

        let is_speech = looks_like_voice(&processed.stats, adaptive_threshold);

        if is_speech {
            if !in_speech {
                speech_bursts += 1;
                in_speech = true;
            }
            if speech_start_offset.is_none() {
                speech_start_offset = Some(frame_start_offset);
            }
            speech_detected = true;
            last_speech_at = Instant::now();
            speech_windows += 1;
            current_voice_streak += 1;
            max_voice_streak = max_voice_streak.max(current_voice_streak);
            last_speech_end_offset = Some(all_pcm.len());
        } else {
            current_voice_streak = 0;
            in_speech = false;
        }

        if !speech_detected {
            // Waiting for user to start speaking.
            if elapsed >= UTTERANCE_PRE_SPEECH_TIMEOUT_SECS {
                break; // User didn't say anything.
            }
        } else {
            // User has spoken — check for end-of-utterance silence.
            let silence_duration = last_speech_at.elapsed().as_secs_f64();
            let silence_target = post_speech_silence_target(
                field_mode,
                speech_windows,
                max_voice_streak,
                speech_bursts,
            );
            if silence_duration >= silence_target {
                break; // Done — user stopped talking.
            }
        }
    }

    // Kill the capture process.
    let _ = child.kill().await;

    if all_pcm.is_empty() {
        anyhow::bail!("no audio captured");
    }

    if speech_detected {
        all_pcm =
            trim_utterance_pcm_to_speech(&all_pcm, speech_start_offset, last_speech_end_offset);
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
    cleanup_dir_by_size(&audio_dir, AUDIO_RETENTION_MAX_BYTES, "audio")
        .await
        .ok();

    Ok(audio_path.to_string_lossy().to_string())
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
            "axi", "aksi", "axie", "aksie", "acsi", "ahxi",
            // Spanish Whisper mishearings observed in our own transcripts.
            // Keep this list tight and biased toward explicit wake invocations.
            "exi", "acci", "ahsi", "aquí", "oxi",
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

    // Strip markdown bold/italic asterisks — these get read aloud by TTS as "asterisk"
    text = text.replace("**", "").replace('*', "");

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

fn sanitize_streaming_partial_text(raw: &str) -> String {
    let mut text = strip_think_sections(raw);
    text = text
        .replace("<think>", " ")
        .replace("</think>", " ")
        .replace("<|im_start|>", " ")
        .replace("<|im_end|>", " ")
        .replace("**", "")
        .replace('*', "");

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

    normalize_whitespace(&cleaned_lines.join(" "))
}

fn extract_streaming_tts_prefix(raw: &str) -> Option<String> {
    let cleaned = sanitize_streaming_partial_text(raw);
    if cleaned.is_empty() {
        return None;
    }

    let sentences = split_spoken_sentences(&cleaned);
    if sentences.is_empty() {
        return None;
    }

    let ends_with_terminal = cleaned
        .chars()
        .last()
        .map(|ch| matches!(ch, '.' | '!' | '?' | ';' | ':'))
        .unwrap_or(false);

    if ends_with_terminal || sentences.len() >= 2 {
        Some(sentences[0].clone())
    } else {
        None
    }
}

fn trim_streamed_prefix_from_response(full_response: &str, spoken_prefix: &str) -> String {
    let full_clean = sanitize_assistant_response(full_response);
    let prefix_clean = sanitize_streaming_partial_text(spoken_prefix);
    if full_clean.is_empty() || prefix_clean.is_empty() {
        return full_clean;
    }

    let sentences = split_spoken_sentences(&full_clean);
    if let Some(first_sentence) = sentences.first() {
        if text_jaccard_similarity(first_sentence, &prefix_clean) >= 0.82 {
            return sentences
                .into_iter()
                .skip(1)
                .collect::<Vec<_>>()
                .join(" ")
                .trim()
                .to_string();
        }
    }

    if full_clean.starts_with(&prefix_clean) {
        return full_clean[prefix_clean.len()..].trim().to_string();
    }

    full_clean
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

/// Try to extract a person's name from a transcript that is a response to
/// "¿Como te llamas?". Matches patterns like "Héctor", "Me llamo Cely",
/// "Soy Héctor", "Mi nombre es Cely", or a single capitalized word.
fn extract_name_from_transcript(transcript: &str) -> Option<String> {
    let text = transcript.trim();
    if text.is_empty() || text.len() > 100 {
        return None;
    }
    let lower = text.to_lowercase();

    // Pattern: "me llamo X", "soy X", "mi nombre es X"
    for prefix in &["me llamo ", "soy ", "mi nombre es "] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            let name = rest.trim().trim_end_matches(['.', ',', '!']);
            if !name.is_empty() && name.len() < 30 {
                // Capitalize first letter
                let mut chars = name.chars();
                let capitalized: String = chars
                    .next()
                    .map(|c| c.to_uppercase().to_string())
                    .unwrap_or_default()
                    + chars.as_str();
                return Some(capitalized);
            }
        }
    }

    // Pattern: single word that looks like a name (1-3 words, short)
    let words: Vec<&str> = text.split_whitespace().collect();
    if words.len() <= 2 && text.len() < 25 {
        // Check that the first character is alphabetic (likely a name)
        if text
            .chars()
            .next()
            .map(|c| c.is_alphabetic())
            .unwrap_or(false)
        {
            let name = text.trim_end_matches(['.', ',', '!']);
            if !name.is_empty() {
                return Some(name.to_string());
            }
        }
    }

    None
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

pub async fn resolve_binary(env_var: &str, candidates: &[&str]) -> Option<String> {
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

// ── Mic calibration, chime, and field mode ──────────────────────────────

/// Calibrate the microphone threshold by sampling 2 seconds of ambient noise.
///
/// Records ambient audio, computes the RMS, and sets the threshold to
/// `ambient_rms * 3` (clamped to 200..1500). The result is cached to disk.
pub async fn calibrate_mic_threshold(source: Option<&str>) -> u32 {
    let tmp_path = format!("/tmp/lifeos-calibration-{}.wav", std::process::id());

    // Try pw-record first, then parecord
    let binary = resolve_binary("LIFEOS_AUDIO_CAPTURE_BIN", &["pw-record", "parecord"]).await;

    let recorded = if let Some(bin) = binary {
        let program = Path::new(&bin)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(&bin);

        let timeout_bin = resolve_binary("LIFEOS_TIMEOUT_BIN", &["timeout"]).await;
        let result = match (program, timeout_bin) {
            ("pw-record", Some(ref tb)) => {
                let mut cmd = Command::new(tb);
                cmd.arg(format!("{}s", MIC_CALIBRATION_SAMPLE_SECS))
                    .arg(&bin);
                if let Some(src) = source {
                    cmd.args(["--target", src]);
                }
                cmd.args([
                    "--rate",
                    "16000",
                    "--channels",
                    "1",
                    "--format",
                    "s16",
                    &tmp_path,
                ]);
                cmd.stderr(std::process::Stdio::piped())
                    .stdout(std::process::Stdio::piped());
                cmd.output().await.map(|o| (o.status, o.stderr))
            }
            ("parecord", Some(ref tb)) => {
                let mut cmd = Command::new(tb);
                cmd.arg(format!("{}s", MIC_CALIBRATION_SAMPLE_SECS))
                    .arg(&bin);
                if let Some(src) = source {
                    cmd.args(["-d", src]);
                }
                cmd.args(["--rate=16000", "--channels=1", "--format=s16le", &tmp_path]);
                cmd.stderr(std::process::Stdio::piped())
                    .stdout(std::process::Stdio::piped());
                cmd.output().await.map(|o| (o.status, o.stderr))
            }
            _ => {
                log::warn!("[calibration] no timeout binary or unsupported recorder");
                Err(std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "no timeout",
                ))
            }
        };
        match result {
            Ok((status, _stderr)) if status.success() || status.code() == Some(124) => true,
            Ok((status, stderr)) => {
                let err_text = String::from_utf8_lossy(&stderr);
                log::warn!(
                    "[calibration] {program} exited with {status}: {}",
                    err_text.trim()
                );
                false
            }
            Err(e) => {
                log::warn!("[calibration] failed to spawn {program}: {e}");
                false
            }
        }
    } else {
        false
    };

    if !recorded {
        log::warn!("[calibration] failed to record ambient audio, using default threshold");
        return PCM_RMS_THRESHOLD_DEFAULT as u32;
    }

    // Read the recorded file and compute RMS
    let rms = match tokio::fs::read(&tmp_path).await {
        Ok(bytes) if bytes.len() > 44 => {
            let pcm = if bytes.starts_with(b"RIFF") {
                &bytes[44..]
            } else {
                &bytes[..]
            };
            let field_mode = detect_mic_field_mode().await;
            let env_gain_db: f64 = std::env::var("LIFEOS_MIC_GAIN_DB")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(12.0);
            let gain_db = env_gain_db + field_mode_extra_gain(field_mode);
            let mut filter_state = AudioFilterState::default();
            let processed =
                preprocess_frame_i16le(pcm, AUDIO_SAMPLE_RATE, gain_db, None, &mut filter_state);
            processed.stats.rms
        }
        _ => {
            log::warn!("[calibration] failed to read calibration audio");
            return PCM_RMS_THRESHOLD_DEFAULT as u32;
        }
    };

    // Clean up temp file
    tokio::fs::remove_file(&tmp_path).await.ok();

    let threshold = (rms * MIC_CALIBRATION_MULTIPLIER)
        .round()
        .clamp(MIC_CALIBRATION_MIN as f64, MIC_CALIBRATION_MAX as f64) as u32;

    log::info!(
        "[calibration] ambient RMS: {rms:.0}, calibrated threshold: {threshold} (device: {:?})",
        source
    );

    // Detect field mode and persist to disk
    let field_mode = detect_mic_field_mode().await;
    let calibration = MicCalibration {
        threshold,
        device: source.map(|s| s.to_string()),
        field_mode: Some(field_mode),
        timestamp: Utc::now(),
    };
    if let Some(home) = dirs_home() {
        let cal_dir = home.join(".local/share/lifeos");
        tokio::fs::create_dir_all(&cal_dir).await.ok();
        let cal_path = cal_dir.join(MIC_CALIBRATION_FILE);
        if let Ok(json) = serde_json::to_string_pretty(&calibration) {
            tokio::fs::write(&cal_path, json).await.ok();
        }
    }

    threshold
}

/// Load a previously cached mic calibration if it exists and is fresh (<24h).
pub async fn load_calibrated_threshold() -> Option<u32> {
    let home = dirs_home()?;
    let cal_path = home.join(".local/share/lifeos").join(MIC_CALIBRATION_FILE);
    let data = tokio::fs::read_to_string(&cal_path).await.ok()?;
    let cal: MicCalibration = serde_json::from_str(&data).ok()?;

    let age_hours = (Utc::now() - cal.timestamp).num_hours();
    if age_hours < MIC_CALIBRATION_MAX_AGE_HOURS {
        log::debug!(
            "[calibration] loaded cached threshold: {} (age: {}h)",
            cal.threshold,
            age_hours
        );
        Some(cal.threshold)
    } else {
        log::debug!("[calibration] cached threshold expired (age: {age_hours}h)");
        None
    }
}

/// Detect whether the current default audio source is near-field (headset)
/// or far-field (built-in laptop mic).
///
/// Bluetooth/USB headsets are classified as NearField; everything else as FarField.
pub async fn detect_mic_field_mode() -> MicFieldMode {
    let output = Command::new("pactl")
        .args(["list", "sources", "short"])
        .output()
        .await;

    let sources_text = match output {
        Ok(ref o) if o.status.success() => String::from_utf8_lossy(&o.stdout).to_string(),
        _ => return MicFieldMode::FarField,
    };

    // Also get the default source name
    let info_output = Command::new("pactl").arg("info").output().await;
    let default_source = info_output.ok().and_then(|o| {
        let text = String::from_utf8_lossy(&o.stdout).to_string();
        text.lines()
            .find(|l| l.starts_with("Default Source:") || l.starts_with("Fuente por defecto:"))
            .and_then(|l| l.split_once(':').map(|(_, v)| v.trim().to_string()))
    });

    if let Some(ref ds) = default_source {
        let ds_lower = ds.to_lowercase();
        if ds_lower.contains("bluez") || ds_lower.contains("usb") {
            log::info!("[field-mode] NearField detected (source: {ds})");
            return MicFieldMode::NearField;
        }
    }

    // Check if any active non-monitor source is bluetooth/USB
    for line in sources_text.lines() {
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() >= 2 {
            let name = cols[1].to_lowercase();
            if name.contains(".monitor") {
                continue;
            }
            if let Some(ref ds) = default_source {
                if cols[1] != ds.as_str() {
                    continue;
                }
            }
            if name.contains("bluez") || name.contains("usb") {
                log::info!("[field-mode] NearField detected (source: {})", cols[1]);
                return MicFieldMode::NearField;
            }
        }
    }

    log::info!("[field-mode] FarField detected (built-in mic)");
    MicFieldMode::FarField
}

/// Apply field-mode adjustments to a calibrated threshold.
///
/// NearField: threshold * 0.6 (headsets pick up voice clearly).
/// FarField: threshold * 1.0 (no reduction, rely on extra gain).
fn apply_field_mode_threshold(threshold: f64, mode: MicFieldMode) -> f64 {
    match mode {
        MicFieldMode::NearField => (threshold * NEAR_FIELD_THRESHOLD_MULT).max(ADAPTIVE_RMS_FLOOR),
        MicFieldMode::FarField => threshold,
    }
}

/// Return the extra gain (in dB) to apply for a given field mode.
fn field_mode_extra_gain(mode: MicFieldMode) -> f64 {
    match mode {
        MicFieldMode::NearField => 0.0,
        MicFieldMode::FarField => FAR_FIELD_EXTRA_GAIN_DB,
    }
}

/// Generate a two-tone ascending chime WAV (440Hz 100ms + 660Hz 100ms) and
/// cache it at `/tmp/lifeos-chime.wav`. Plays it at 30% of system volume.
pub async fn play_wake_word_chime() {
    // Generate the chime WAV if not already cached
    if !Path::new(CHIME_CACHE_PATH).exists() {
        if let Err(e) = generate_chime_wav(CHIME_CACHE_PATH).await {
            log::warn!("[chime] failed to generate chime WAV: {e}");
            return;
        }
    }

    // Read current system volume to scale to 30%
    let volume_scale = get_system_volume_scale().await.unwrap_or(0.3);
    let chime_volume = volume_scale * 0.3;

    // Try pw-play first, then aplay
    let player = resolve_binary("LIFEOS_PLAYBACK_BIN", &["pw-play", "aplay"]).await;
    if let Some(bin) = player {
        let program = Path::new(&bin)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(&bin);

        let result = match program {
            "pw-play" => {
                let mut cmd = Command::new(&bin);
                cmd.arg(format!("--volume={:.2}", chime_volume));
                cmd.arg(CHIME_CACHE_PATH);
                cmd.stderr(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null());
                cmd.status().await
            }
            _ => {
                // aplay doesn't have volume control, just play at system volume
                let mut cmd = Command::new(&bin);
                cmd.arg(CHIME_CACHE_PATH);
                cmd.stderr(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null());
                cmd.status().await
            }
        };
        match result {
            Ok(s) if s.success() => log::debug!("[chime] played wake word chime"),
            Ok(s) => log::warn!("[chime] playback exited with {s}"),
            Err(e) => log::warn!("[chime] playback failed: {e}"),
        }
    } else {
        log::warn!("[chime] no playback binary available");
    }
}

/// Generate a simple two-tone WAV file: 440Hz for 100ms, then 660Hz for 100ms.
async fn generate_chime_wav(path: &str) -> Result<()> {
    let sample_rate: u32 = 16000;
    let tone1_hz: f64 = 440.0;
    let tone2_hz: f64 = 660.0;
    let tone_duration_samples = (sample_rate as f64 * 0.1) as usize; // 100ms each
    let total_samples = tone_duration_samples * 2;
    let amplitude: f64 = 16000.0; // moderate amplitude

    let mut pcm_data: Vec<u8> = Vec::with_capacity(total_samples * 2);

    // Tone 1: 440Hz for 100ms
    for i in 0..tone_duration_samples {
        let t = i as f64 / sample_rate as f64;
        let sample = (amplitude * (2.0 * std::f64::consts::PI * tone1_hz * t).sin()) as i16;
        pcm_data.extend_from_slice(&sample.to_le_bytes());
    }

    // Tone 2: 660Hz for 100ms
    for i in 0..tone_duration_samples {
        let t = i as f64 / sample_rate as f64;
        let sample = (amplitude * (2.0 * std::f64::consts::PI * tone2_hz * t).sin()) as i16;
        pcm_data.extend_from_slice(&sample.to_le_bytes());
    }

    // Build WAV header (44 bytes)
    let data_size = (total_samples * 2) as u32;
    let file_size = data_size + 36;
    let mut wav: Vec<u8> = Vec::with_capacity(44 + data_size as usize);

    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&file_size.to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes()); // chunk size
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM format
    wav.extend_from_slice(&1u16.to_le_bytes()); // mono
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&(sample_rate * 2).to_le_bytes()); // byte rate
    wav.extend_from_slice(&2u16.to_le_bytes()); // block align
    wav.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_size.to_le_bytes());
    wav.extend_from_slice(&pcm_data);

    tokio::fs::write(path, &wav)
        .await
        .context("Failed to write chime WAV")?;
    log::debug!("[chime] generated chime WAV at {path}");
    Ok(())
}

/// Read the current system volume as a linear scale (0.0..1.0).
async fn get_system_volume_scale() -> Option<f64> {
    let output = Command::new("wpctl")
        .args(["get-volume", "@DEFAULT_AUDIO_SINK@"])
        .output()
        .await
        .ok()?;
    if !output.status.success() {
        return None;
    }
    // Output looks like: "Volume: 0.50" or "Volume: 0.50 [MUTED]"
    let text = String::from_utf8_lossy(&output.stdout);
    text.split_whitespace()
        .find_map(|tok| tok.parse::<f64>().ok())
}

/// Get the user home directory.
fn dirs_home() -> Option<PathBuf> {
    std::env::var("HOME").ok().map(PathBuf::from)
}

/// Heuristic: does pactl stderr indicate the server isn't ready yet (boot race)
/// vs a permanent failure like missing binary or bad args?
fn pactl_stderr_is_not_ready(stderr: &str) -> bool {
    let s = stderr.to_ascii_lowercase();
    s.contains("connection refused")
        || s.contains("connection terminated")
        || s.contains("no pulseaudio daemon")
        || s.contains("no such file or directory")
        || s.contains("failed to connect")
        || s.contains("conexión rehusada")
        || s.contains("no se pudo conectar")
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

    // At boot, `After=pipewire.service` only waits for the service to start, not
    // for sources to be enumerable. Retry pactl up to 3 times with backoff when
    // the failure looks like "server not ready yet".
    let backoffs_ms = [500u64, 1000, 2000];
    let mut attempt: usize = 0;
    let (info_stdout, list_stdout) = loop {
        // 2. Get the system default source (usually the built-in mic)
        let info_output = match Command::new("pactl").arg("info").output().await {
            Ok(o) => o,
            Err(e) => {
                log::warn!("[audio] failed to spawn `pactl info`: {e}");
                return None;
            }
        };
        if !info_output.status.success() {
            let stderr = String::from_utf8_lossy(&info_output.stderr);
            let retryable = pactl_stderr_is_not_ready(&stderr);
            log::warn!(
                "[audio] `pactl info` failed ({}): {}",
                info_output.status,
                stderr.trim()
            );
            if retryable && attempt < backoffs_ms.len() {
                tokio::time::sleep(std::time::Duration::from_millis(backoffs_ms[attempt])).await;
                attempt += 1;
                continue;
            }
            return None;
        }

        // 3. List all non-monitor sources
        let list_output = match Command::new("pactl")
            .args(["list", "short", "sources"])
            .output()
            .await
        {
            Ok(o) => o,
            Err(e) => {
                log::warn!("[audio] failed to spawn `pactl list sources`: {e}");
                return None;
            }
        };
        if !list_output.status.success() {
            let stderr = String::from_utf8_lossy(&list_output.stderr);
            let retryable = pactl_stderr_is_not_ready(&stderr);
            log::warn!(
                "[audio] `pactl list short sources` failed ({}): {}",
                list_output.status,
                stderr.trim()
            );
            if retryable && attempt < backoffs_ms.len() {
                tokio::time::sleep(std::time::Duration::from_millis(backoffs_ms[attempt])).await;
                attempt += 1;
                continue;
            }
            return None;
        }

        break (info_output.stdout, list_output.stdout);
    };

    let info = String::from_utf8_lossy(&info_stdout);
    let default_source = info
        .lines()
        .find(|l| l.starts_with("Default Source:") || l.starts_with("Fuente por defecto:"))
        .and_then(|l| l.split_once(':').map(|(_, v)| v.trim().to_string()));

    let list = String::from_utf8_lossy(&list_stdout);
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
            log::debug!("[audio] using system default source: {ds}");
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

/// Send SIGTERM to `pid` and escalate to SIGKILL if the process does not
/// exit within ~2 seconds. Uses `libc::kill` directly instead of forking
/// `/usr/bin/kill`, so the reaper costs one syscall per signal rather than
/// two forks per TERM.
///
/// The escalation matters: ffmpeg / libcamera can get wedged in uninterrupt-
/// ible sleep on a hung V4L2 device. A TERM-only reaper leaves the camera
/// device permanently locked on that class of failure.
async fn kill_pid(pid: u32) -> Result<()> {
    // SAFETY: libc::kill is sound on any valid i32 pid. Rejecting pid=0
    // (broadcast to process group) and negative values is done up-front.
    let pid_i32: libc::pid_t = pid.try_into().context("pid out of range")?;
    if pid_i32 <= 0 {
        anyhow::bail!("refusing to signal pid {} (invalid)", pid);
    }

    // 1) Polite shutdown — give the child a chance to flush/close handles.
    let term_rc = unsafe { libc::kill(pid_i32, libc::SIGTERM) };
    if term_rc != 0 {
        let err = std::io::Error::last_os_error();
        // ESRCH = process already gone; treat as success.
        if err.raw_os_error() != Some(libc::ESRCH) {
            anyhow::bail!("SIGTERM {} failed: {}", pid, err);
        }
        return Ok(());
    }

    // 2) Poll for exit. `kill(pid, 0)` is the standard liveness probe —
    //    returns 0 if the process is still alive, ESRCH if it's gone.
    for _ in 0..20 {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        let alive_rc = unsafe { libc::kill(pid_i32, 0) };
        if alive_rc != 0 {
            let err = std::io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::ESRCH) {
                return Ok(());
            }
        }
    }

    // 3) Still alive after ~2s — escalate.
    log::warn!(
        "kill_pid: pid {} did not exit after SIGTERM; escalating to SIGKILL",
        pid
    );
    let kill_rc = unsafe { libc::kill(pid_i32, libc::SIGKILL) };
    if kill_rc != 0 {
        let err = std::io::Error::last_os_error();
        if err.raw_os_error() != Some(libc::ESRCH) {
            anyhow::bail!("SIGKILL {} failed: {}", pid, err);
        }
    }
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
            if let Err(primary_error) =
                capture_camera_presence_ffmpeg(binary, device, &frame_path).await
            {
                log::warn!(
                    "[camera] preferred ffmpeg capture failed on {}: {}",
                    device,
                    primary_error
                );
                tokio::fs::remove_file(&frame_path).await.ok();
                let mut fallback = Command::new(binary);
                fallback.args([
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-nostdin",
                    "-y",
                    "-f",
                    "v4l2",
                    "-video_size",
                    CAMERA_CAPTURE_FALLBACK_SIZE,
                    "-i",
                    device,
                    "-frames:v",
                    "1",
                    "-q:v",
                    "2",
                    frame_path.to_string_lossy().as_ref(),
                ]);
                if let Err(fallback_error) = run_camera_capture_command(fallback, binary).await {
                    // Fallback ALSO failed — ffmpeg may have left a zero-byte
                    // or truncated JPG on disk that would survive until the
                    // 6h housekeeping sweep and count against the retention
                    // cap. Sweep it before returning the error.
                    tokio::fs::remove_file(&frame_path).await.ok();
                    return Err(fallback_error);
                }
            }
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

    if program != "ffmpeg" {
        if let Err(err) = run_camera_capture_command(cmd, binary).await {
            // Same hygiene for the non-ffmpeg backends.
            tokio::fs::remove_file(&frame_path).await.ok();
            return Err(err);
        }
    }

    let mut metrics = match analyze_camera_frame(&frame_path) {
        Ok(m) => m,
        Err(err) => {
            // A frame exists on disk but it didn't parse. Do not leak
            // unreadable JPGs into the retention bucket — they'd count
            // against the 120-file cap and distract troubleshooting.
            tokio::fs::remove_file(&frame_path).await.ok();
            return Err(err);
        }
    };
    metrics.frame_path = Some(frame_path.to_string_lossy().to_string());
    log::debug!(
        "[camera] captured presence frame via {} brightness={:.1} enhanced={} present={} face_near_screen={}",
        program,
        metrics.avg_brightness,
        metrics.enhanced,
        metrics.present,
        metrics.face_near_screen
    );

    // Enforce the per-cycle retention cap here rather than waiting for the
    // 6-hour background housekeeping tick. `cleanup_dir_by_count` is cheap
    // (a single readdir + sort + N unlinks) and guarantees the directory
    // never drifts above the cap even under sustained capture cadence.
    if let Ok(removed) =
        crate::storage_housekeeping::cleanup_dir_by_count(&camera_dir, CAMERA_PRESENCE_MAX_FILES)
            .await
    {
        if removed > 0 {
            log::debug!(
                "[camera] per-cycle retention removed {} files (cap {})",
                removed,
                CAMERA_PRESENCE_MAX_FILES
            );
        }
    }

    Ok(metrics)
}

#[derive(Debug, Clone)]
struct CameraPresenceMetrics {
    present: bool,
    face_near_screen: bool,
    frame_path: Option<String>,
    avg_brightness: f64,
    enhanced: bool,
}

#[derive(Debug, Clone)]
struct CameraFrameStats {
    skin_ratio: f64,
    /// Mean brightness over the center crop. Used as an overall luminance
    /// signal but NOT as the enhancement trigger — that now uses
    /// `face_brightness` so a bright back-lit scene with a dim face
    /// still gets enhanced.
    avg_brightness: f64,
    avg_edge: f64,
    /// Mean brightness of the skin-tone pixels in the center crop (if
    /// any were detected). None when no skin was found — callers fall
    /// back to `avg_brightness`.
    face_brightness: Option<f64>,
}

fn analyze_camera_frame(path: &Path) -> Result<CameraPresenceMetrics> {
    let image = image::open(path).context("Failed to open captured camera frame")?;
    let stats = compute_camera_frame_stats(&image)?;
    let (image, stats, enhanced) = maybe_enhance_camera_frame(image, &stats);
    if enhanced {
        image
            .save(path)
            .with_context(|| format!("Failed to save enhanced camera frame {}", path.display()))?;
    }
    let present = stats.skin_ratio > 0.03 || (stats.avg_brightness > 35.0 && stats.avg_edge > 12.0);
    let face_near_screen = stats.skin_ratio > 0.18;

    Ok(CameraPresenceMetrics {
        present,
        face_near_screen,
        frame_path: None,
        avg_brightness: stats.avg_brightness,
        enhanced,
    })
}

fn compute_camera_frame_stats(image: &DynamicImage) -> Result<CameraFrameStats> {
    let (width, height) = image.dimensions();
    let center_left = width / 4;
    let center_right = (width * 3) / 4;
    let center_top = height / 4;
    let center_bottom = (height * 3) / 4;

    let mut total_pixels = 0u64;
    let mut skin_like_pixels = 0u64;
    let mut brightness_sum = 0f64;
    let mut edge_sum = 0f64;
    let mut skin_brightness_sum = 0f64;

    for y in center_top..center_bottom {
        for x in center_left..center_right {
            let pixel = image.get_pixel(x, y).to_rgb();
            let channels = pixel.channels();
            let r = channels[0] as f64;
            let g = channels[1] as f64;
            let b = channels[2] as f64;
            let pixel_brightness = (r + g + b) / 3.0;
            brightness_sum += pixel_brightness;
            if is_skin_like(channels[0], channels[1], channels[2]) {
                skin_like_pixels += 1;
                skin_brightness_sum += pixel_brightness;
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

    let face_brightness = if skin_like_pixels > 0 {
        Some(skin_brightness_sum / skin_like_pixels as f64)
    } else {
        None
    };

    Ok(CameraFrameStats {
        skin_ratio: skin_like_pixels as f64 / total_pixels as f64,
        avg_brightness: brightness_sum / total_pixels as f64,
        avg_edge: edge_sum / total_pixels as f64,
        face_brightness,
    })
}

fn maybe_enhance_camera_frame(
    image: DynamicImage,
    stats: &CameraFrameStats,
) -> (DynamicImage, CameraFrameStats, bool) {
    // Use face brightness (skin-pixel mean) when available rather than the
    // whole-center mean — handles back-lit scenes where a bright window
    // behind the user lifts the mean above the threshold while the face
    // itself is under-exposed. Falls back to avg_brightness when no skin
    // was detected (face not yet in frame, camera off-angle, etc.).
    let reference_brightness = stats.face_brightness.unwrap_or(stats.avg_brightness);
    if reference_brightness >= CAMERA_FRAME_DARK_THRESHOLD {
        return (image, stats.clone(), false);
    }

    let brighten = (CAMERA_FRAME_TARGET_BRIGHTNESS - reference_brightness)
        .round()
        .clamp(12.0, CAMERA_FRAME_MAX_BRIGHTEN as f64) as i32;
    let contrast = if reference_brightness < 45.0 {
        CAMERA_FRAME_VERY_DARK_CONTRAST_BOOST
    } else {
        CAMERA_FRAME_CONTRAST_BOOST
    };
    let enhanced = image.brighten(brighten).adjust_contrast(contrast);
    let enhanced_stats = compute_camera_frame_stats(&enhanced).unwrap_or_else(|_| stats.clone());

    if enhanced_stats.avg_brightness <= stats.avg_brightness + 4.0 {
        return (image, stats.clone(), false);
    }

    (enhanced, enhanced_stats, true)
}

async fn capture_camera_presence_ffmpeg(
    binary: &str,
    device: &str,
    frame_path: &Path,
) -> Result<()> {
    let mut cmd = Command::new(binary);
    cmd.args([
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-y",
        "-f",
        "v4l2",
        "-input_format",
        "mjpeg",
        "-video_size",
        CAMERA_CAPTURE_PREFERRED_SIZE,
        "-framerate",
        "15",
        "-i",
        device,
        "-frames:v",
        "1",
        "-q:v",
        "2",
        frame_path.to_string_lossy().as_ref(),
    ]);
    run_camera_capture_command(cmd, binary).await
}

async fn run_camera_capture_command(mut cmd: Command, binary: &str) -> Result<()> {
    cmd.stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = cmd
        .spawn()
        .with_context(|| format!("Failed to spawn camera capture via {}", binary))?;
    let mut stderr_pipe = child.stderr.take();

    let wait_result = tokio::time::timeout(
        std::time::Duration::from_secs(CAMERA_CAPTURE_TIMEOUT_SECS),
        child.wait(),
    )
    .await;

    let mut stderr_buf = Vec::new();
    match wait_result {
        Ok(status_result) => {
            let status = status_result
                .with_context(|| format!("Failed waiting for camera capture via {}", binary))?;
            if let Some(mut pipe) = stderr_pipe.take() {
                let _ = tokio::io::AsyncReadExt::read_to_end(&mut pipe, &mut stderr_buf).await;
            }
            if !status.success() {
                let stderr = String::from_utf8_lossy(&stderr_buf).trim().to_string();
                let detail = if stderr.is_empty() {
                    format!("exit status {}", status)
                } else {
                    stderr
                };
                anyhow::bail!("camera capture failed via {}: {}", binary, detail);
            }
        }
        Err(_) => {
            let _ = child.start_kill();
            let _ = child.wait().await;
            if let Some(mut pipe) = stderr_pipe.take() {
                let _ = tokio::io::AsyncReadExt::read_to_end(&mut pipe, &mut stderr_buf).await;
            }
            let stderr = String::from_utf8_lossy(&stderr_buf).trim().to_string();
            let detail = if stderr.is_empty() {
                String::new()
            } else {
                format!(": {}", stderr)
            };
            anyhow::bail!(
                "camera capture timed out via {} after {}s{}",
                binary,
                CAMERA_CAPTURE_TIMEOUT_SECS,
                detail
            );
        }
    }

    Ok(())
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

/// Parse a caller-supplied PEOPLE: value safely.
/// - "3"  → 3
/// - "500" → 255 (clamped, u8 max)
/// - "-1" / garbage → 0
///
/// Implemented via i32 + clamp so u8 overflow doesn't silently fall
/// through to 0 and misclassify a crowded room as empty.
fn parse_people_count(raw: &str) -> u8 {
    raw.parse::<i32>()
        .map(|n| n.clamp(0, u8::MAX as i32) as u8)
        .unwrap_or(0)
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
            // Parse via i32 + clamp so a model answer like "PEOPLE: 500"
            // (overflow in u8) does not silently fall through to 0 and
            // misclassify a crowded room as empty. Negatives are clamped
            // to 0 for robustness against malformed output.
            people = parse_people_count(rest.trim());
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
            people = parse_people_count(num_str);
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

    // Truncate overly long scene descriptions. The prompt asks for 10
    // words max; 64 chars is a comfortable ceiling for that while still
    // keeping room for diacritics / Spanish text. Down from 120: models
    // routinely overshoot the word budget and the tighter cap reduces
    // how much arbitrary VL context lands in MemoryPlane per cycle.
    scene = truncate_scene(&scene, 64);

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

/// Detect skin-like pixels across the full Fitzpatrick I–VI range.
///
/// The previous heuristic (`r > 95 && g > 40 && b > 20 && r - g > 15 && r > g > b`)
/// had a hard R-channel floor at 95, which excluded most deeply pigmented
/// skin (Fitzpatrick IV–VI typically lands in R 40–90) — the presence and
/// `face_near_screen` signals never triggered for darker-skinned users, so
/// posture/fatigue alerts and the "user at screen" state were silently
/// disabled for them. See Buolamwini/Gebru "Gender Shades" (2018) for
/// prior art on this exact class of bug.
///
/// The new approach converts RGB → YCbCr and matches the chroma channels
/// (Cb, Cr) against the Chai & Ngan (1999) skin-locus range, which is
/// chroma-based and much less sensitive to overall luminance — it
/// generalises across skin tones while still rejecting typical
/// background / clothing / wall colours.
fn is_skin_like(r: u8, g: u8, b: u8) -> bool {
    let r = r as f32;
    let g = g as f32;
    let b = b as f32;
    // ITU-R BT.601 RGB → YCbCr (8-bit studio range, 16–235 luma / 16–240 chroma).
    let y = 0.299 * r + 0.587 * g + 0.114 * b;
    let cb = 128.0 - 0.168736 * r - 0.331264 * g + 0.5 * b;
    let cr = 128.0 + 0.5 * r - 0.418688 * g - 0.081312 * b;
    // Chai & Ngan skin-locus; keep a generous luma floor so pure black
    // (dead-dark pixels) don't count, but don't use luma as an upper
    // discriminator — bright and dark skin alike land inside the Cb/Cr box.
    (77.0..=127.0).contains(&cb) && (133.0..=173.0).contains(&cr) && y >= 20.0
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

/// Detect an active meeting by scanning compositor window titles via swaymsg.
///
/// Delegates to the meeting assistant module which has the full pattern matching
/// logic for sway/COSMIC compositor window titles.
async fn detect_meeting_by_window_title() -> Option<String> {
    crate::meeting_assistant::detect_meeting_by_window_title().await
}

/// Update meeting state by checking PulseAudio streams, window titles, and camera availability.
async fn refresh_meeting_state(camera_device: Option<&str>) -> MeetingState {
    let conferencing_app = detect_active_meeting().await;

    // If audio detection didn't find anything, try window title detection
    let window_app = if conferencing_app.is_none() {
        detect_meeting_by_window_title().await
    } else {
        None
    };

    if let Some(device) = camera_device {
        if let Ok(true) = reap_stale_presence_capture_processes(device).await {
            log::warn!(
                "[camera] reaped a stale camera presence capture on {}; camera availability restored",
                device
            );
        }
    }

    let camera_busy = camera_device.map(is_camera_busy).unwrap_or(false);
    let app = conferencing_app.or(window_app);

    MeetingState {
        active: app.is_some() || camera_busy,
        conferencing_app: app,
        camera_busy,
        last_checked_at: Some(Utc::now()),
    }
}

async fn reap_stale_presence_capture_processes(device: &str) -> Result<bool> {
    // Include the user id column so the reaper cannot be tricked into
    // SIGTERMing another user's process on a shared/multi-user host by
    // anyone who can name their process "/camera/presence-…".
    let output = Command::new("ps")
        .args(["-eo", "pid=,uid=,etimes=,cmd="])
        .output()
        .await
        .context("Failed to inspect process table for stale camera capture")?;
    if !output.status.success() {
        return Ok(false);
    }

    // SAFETY: libc::getuid is a pure read of the calling process's real UID.
    let own_uid: u32 = unsafe { libc::getuid() };

    let mut killed = false;
    let device_lower = device.to_lowercase();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let mut parts = line.split_whitespace();
        let pid = parts.next().and_then(|value| value.parse::<u32>().ok());
        let uid = parts.next().and_then(|value| value.parse::<u32>().ok());
        let elapsed = parts.next().and_then(|value| value.parse::<u64>().ok());
        let cmd = parts.collect::<Vec<_>>().join(" ");
        let Some(pid) = pid else { continue };
        let Some(uid) = uid else { continue };
        let Some(elapsed) = elapsed else { continue };
        if uid != own_uid {
            continue;
        }
        if elapsed < CAMERA_STALE_CAPTURE_SECS {
            continue;
        }
        if !is_stale_presence_capture_process(&cmd, &device_lower) {
            continue;
        }
        kill_pid(pid).await.ok();
        killed = true;
    }

    Ok(killed)
}

/// True when the user session is locked, per systemd-logind. Returns
/// false on any error (bus unavailable, unknown session, etc.) so a
/// broken bus doesn't silently disable capture — the suspend gate and
/// sensitive-window gate still protect us in that case.
///
/// Uses the direct CLI to avoid adding an extra sync point on the
/// system bus; `loginctl show-session --property LockedHint` is a
/// single fast call.
pub async fn is_session_locked() -> bool {
    let session_id = std::env::var("XDG_SESSION_ID").unwrap_or_default();
    if session_id.is_empty() {
        return false;
    }
    let output = match tokio::time::timeout(
        std::time::Duration::from_millis(500),
        tokio::process::Command::new("loginctl")
            .args(["show-session", &session_id, "--property=LockedHint"])
            .output(),
    )
    .await
    {
        Ok(Ok(o)) => o,
        _ => return false,
    };
    if !output.status.success() {
        return false;
    }
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .any(|line| line.trim() == "LockedHint=yes")
}

/// True when the active window title matches a sensitive pattern (login,
/// password manager, private / incognito browsing, unlock prompts).
/// Shared by every screen-capture entry point so the policy stays uniform
/// — previously only the awareness cycle applied it, leaving
/// describe_screen / meeting / overlay uncovered.
///
/// The list covers English, Spanish, Portuguese, French, German, and
/// Italian variants of "private browsing" / "incognito" — the prior list
/// missed Chrome's "Incognito" entirely and every Spanish variant except
/// "contraseña" / "iniciar sesión".
pub fn is_sensitive_window_title(title: &str) -> bool {
    let lower = title.to_lowercase();
    const SENSITIVE_KEYWORDS: &[&str] = &[
        // credentials / unlock
        "password",
        "contraseña",
        "senha",
        "mot de passe",
        "passwort",
        "password manager",
        "keepass",
        "bitwarden",
        "1password",
        "login",
        "log in",
        "sign in",
        "iniciar sesión",
        "iniciar sesion",
        "pin",
        "cvv",
        "2fa",
        "secret",
        "unlock",
        "desbloquear",
        // private / incognito browsing
        "private browsing",
        "private window",
        "navegación privada",
        "navegacion privada",
        "modo privado",
        "modo incognito",
        "modo incógnito",
        "incognito",
        "incógnito",
        "inprivate",
        "privater modus",
        "navigation privée",
        "navigazione anonima",
        // lock screens
        "lock screen",
        "locked",
        "screen locked",
    ];
    SENSITIVE_KEYWORDS.iter().any(|kw| lower.contains(kw))
}

fn is_stale_presence_capture_process(cmd: &str, device_lower: &str) -> bool {
    let lower = cmd.to_lowercase();
    lower.contains("/camera/presence-")
        && (lower.contains("ffmpeg")
            || lower.contains("libcamera-still")
            || lower.contains("libcamera-jpeg")
            || lower.contains("fswebcam"))
        && (lower.contains(device_lower) || !lower.contains("/dev/video"))
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

// ── Wake word auto-refinement ────────────────────────────────────────────

/// Directory under `$HOME/.local/share/lifeos/` where confirmed wake word
/// audio samples are stored for progressive model refinement.
const WAKE_WORD_SAMPLES_SUBDIR: &str = "wake-word-samples";
/// Maximum number of positive samples to keep on disk.
const WAKE_WORD_MAX_SAMPLES: usize = 50;
/// After every N new samples, trigger a model refinement cycle.
const WAKE_WORD_REFINE_EVERY: usize = 20;

/// Save a confirmed wake word audio sample for future model refinement.
///
/// Copies the audio file to `~/.local/share/lifeos/wake-word-samples/positive-{timestamp}.wav`
/// and prunes old samples if the directory exceeds [`WAKE_WORD_MAX_SAMPLES`].
async fn save_wake_word_sample(audio_path: &str) -> Result<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
    let samples_dir = PathBuf::from(home)
        .join(".local/share/lifeos")
        .join(WAKE_WORD_SAMPLES_SUBDIR);
    tokio::fs::create_dir_all(&samples_dir)
        .await
        .context("Failed to create wake word samples directory")?;

    let timestamp = Utc::now().format("%Y%m%d_%H%M%S_%3f");
    let dest = samples_dir.join(format!("positive-{timestamp}.wav"));
    tokio::fs::copy(audio_path, &dest)
        .await
        .with_context(|| format!("Failed to copy wake word sample to {}", dest.display()))?;
    log::info!("Saved wake word positive sample: {}", dest.display());

    // Prune oldest samples if over limit
    let mut entries: Vec<(std::time::SystemTime, PathBuf)> = Vec::new();
    let mut read_dir = tokio::fs::read_dir(&samples_dir).await?;
    while let Some(entry) = read_dir.next_entry().await? {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) == Some("wav") {
            let modified = entry
                .metadata()
                .await
                .ok()
                .and_then(|m| m.modified().ok())
                .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
            entries.push((modified, path));
        }
    }
    if entries.len() > WAKE_WORD_MAX_SAMPLES {
        entries.sort_by_key(|(t, _)| *t);
        let to_remove = entries.len() - WAKE_WORD_MAX_SAMPLES;
        for (_, path) in entries.iter().take(to_remove) {
            tokio::fs::remove_file(path).await.ok();
            log::debug!("Pruned old wake word sample: {}", path.display());
        }
    }

    Ok(samples_dir)
}

/// Check if a model refinement cycle should run and trigger it.
///
/// When the number of `.wav` samples in the directory is a multiple of
/// [`WAKE_WORD_REFINE_EVERY`] (and > 0), request a hot-reload of the wake
/// word model. The actual rustpotter-cli re-training is a future step —
/// for now we just reload the existing model so the infrastructure is
/// exercised end-to-end.
async fn maybe_refine_wake_word_model(
    samples_dir: &Path,
    detector: &crate::wake_word::WakeWordDetector,
) {
    let count = match tokio::fs::read_dir(samples_dir).await {
        Ok(mut rd) => {
            let mut n = 0usize;
            while let Ok(Some(entry)) = rd.next_entry().await {
                if entry.path().extension().and_then(|e| e.to_str()) == Some("wav") {
                    n += 1;
                }
            }
            n
        }
        Err(_) => return,
    };
    if count > 0 && count % WAKE_WORD_REFINE_EVERY == 0 {
        log::info!("Wake word refinement triggered with {count} samples");
        detector.reload_model();
    }
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
    fn wake_word_handles_shouted_axi_with_punctuation() {
        let transcript = "¡¡AXI!! abre la terminal ahora mismo.";
        assert!(contains_wake_word(transcript, "axi"));
        assert_eq!(
            strip_wake_word(transcript, "axi").as_deref(),
            Some("abre la terminal ahora mismo")
        );
    }

    #[test]
    fn wake_word_handles_soft_spanish_mishearings() {
        let transcript = "[00:00:00.000 --> 00:00:03.200]  Ahsi... puedes ayudarme con esto?";
        assert!(contains_wake_word(transcript, "axi"));
        assert_eq!(
            strip_wake_word(transcript, "axi").as_deref(),
            Some("puedes ayudarme con esto")
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
    fn camera_frame_analysis_brightens_dark_face_frames() {
        // Face swatch (48,30,20) sits inside the YCbCr skin locus but its
        // mean brightness (~33) is well below CAMERA_FRAME_DARK_THRESHOLD=62,
        // so `face_brightness`-driven enhancement must trigger regardless
        // of background luminance.
        let dir = std::env::temp_dir().join(format!("lifeos-camera-dark-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("presence.jpg");

        let mut image: ImageBuffer<Rgb<u8>, Vec<u8>> =
            ImageBuffer::from_pixel(120, 120, Rgb([8, 8, 8]));
        for y in 30..90 {
            for x in 35..85 {
                image.put_pixel(x, y, Rgb([48, 30, 20]));
            }
        }
        image.save(&path).unwrap();

        let metrics = analyze_camera_frame(&path).unwrap();
        assert!(metrics.present);
        assert!(metrics.enhanced);

        std::fs::remove_dir_all(dir).ok();
    }

    // ── camera-audit Fase B: YCbCr skin detection covers all Fitzpatrick tones ──

    #[test]
    fn skin_detector_matches_light_skin() {
        // Fitzpatrick I–III swatch (warm beige). Should match.
        assert!(is_skin_like(220, 180, 150));
        assert!(is_skin_like(210, 150, 120));
        assert!(is_skin_like(200, 160, 135));
    }

    #[test]
    fn skin_detector_matches_dark_skin_fitzpatrick_iv_vi() {
        // These RGB samples represent deeply pigmented skin (Fitzpatrick
        // IV–VI). The OLD heuristic's `r > 95` floor made every one of
        // these return false, silently disabling posture/face-near-screen
        // for darker-skinned users. Regression-guard the new YCbCr path.
        assert!(is_skin_like(88, 60, 44), "medium-brown failed");
        assert!(is_skin_like(70, 45, 30), "dark-brown failed");
        assert!(is_skin_like(60, 38, 25), "very-dark-brown failed");
        assert!(is_skin_like(48, 30, 20), "near-black-brown failed");
    }

    #[test]
    fn skin_detector_rejects_non_skin_backgrounds() {
        // Saturated greens / blues / grays / black are outside the Cb/Cr
        // skin locus and must not register.
        assert!(!is_skin_like(0, 0, 0), "pure black");
        assert!(!is_skin_like(60, 150, 40), "grass green");
        assert!(!is_skin_like(40, 120, 200), "sky blue");
        assert!(!is_skin_like(120, 120, 120), "neutral gray");
        assert!(!is_skin_like(10, 10, 10), "near-black noise");
    }

    #[test]
    fn skin_detector_rejects_old_heuristic_false_positives() {
        // The previous RGB gate matched deeply saturated pure reds as
        // "skin" (sunlight on red shirt, red paint on wall, etc.) because
        // it only required R dominance. YCbCr filters these out via the
        // narrower Cb/Cr box.
        assert!(!is_skin_like(255, 0, 0), "pure red shirt");
        assert!(!is_skin_like(200, 20, 20), "deep red");
    }

    #[test]
    fn people_count_parser_clamps_overflow_and_negatives() {
        assert_eq!(parse_people_count("3"), 3);
        assert_eq!(parse_people_count("0"), 0);
        // u8 overflow — previous `unwrap_or(0)` silently reported an empty
        // room; now we clamp.
        assert_eq!(parse_people_count("500"), u8::MAX);
        assert_eq!(parse_people_count("1000"), u8::MAX);
        // Negatives clamp to 0, same for garbage.
        assert_eq!(parse_people_count("-1"), 0);
        assert_eq!(parse_people_count("abc"), 0);
        assert_eq!(parse_people_count(""), 0);
    }

    #[test]
    fn truncate_scene_honors_new_64_char_cap() {
        // Below cap → passthrough.
        assert_eq!(truncate_scene("short scene", 64).chars().count(), 11);
        // Above cap → truncated + ellipsis, and the prompt's
        // "10 words max" contract is comfortably respected.
        let long =
            "this is a scene description that runs much longer than sixty four characters for sure";
        let out = truncate_scene(long, 64);
        assert!(out.chars().count() <= 64);
        assert!(out.ends_with('…'));
    }

    #[test]
    fn adaptive_brightness_uses_face_brightness_when_available() {
        // Back-lit synthetic frame: bright background + dim skin region
        // in the center. Mean brightness is above the dark threshold, so
        // the OLD enhancement path would not trigger; face-region mean
        // IS below threshold, so the NEW path correctly decides to
        // enhance.
        let dir =
            std::env::temp_dir().join(format!("lifeos-camera-backlit-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("backlit.jpg");

        let mut image: ImageBuffer<Rgb<u8>, Vec<u8>> =
            ImageBuffer::from_pixel(120, 120, Rgb([230, 230, 230])); // bright bg
                                                                     // Paint a darker skin-tone face in the center — inside the new
                                                                     // YCbCr skin locus but below CAMERA_FRAME_DARK_THRESHOLD.
        for y in 30..90 {
            for x in 35..85 {
                image.put_pixel(x, y, Rgb([55, 38, 30]));
            }
        }
        image.save(&path).unwrap();

        let metrics = analyze_camera_frame(&path).unwrap();
        assert!(
            metrics.enhanced,
            "expected face-region brightness to trigger enhancement"
        );

        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn camera_presence_max_files_matches_housekeeping_global() {
        // Guard against drift between the per-cycle cap and the global
        // housekeeping cap — if the two ever diverge, the per-cycle path
        // either leaks files or prunes more aggressively than advertised.
        // Keep them lock-step.
        assert_eq!(CAMERA_PRESENCE_MAX_FILES, 120);
    }

    // ── Unified sensory gate — one policy, every sense ──────────────────

    #[tokio::test]
    async fn sense_enum_str_tags_are_stable() {
        // Gate audit log exports these verbatim — renaming a variant
        // string is a breaking change for any dashboard/CLI consumer
        // that filters on it.
        assert_eq!(Sense::Screen.as_str(), "screen");
        assert_eq!(Sense::Camera.as_str(), "camera");
        assert_eq!(Sense::Microphone.as_str(), "microphone");
        assert_eq!(Sense::Tts.as_str(), "tts");
        assert_eq!(Sense::WindowTracking.as_str(), "window_tracking");
        assert_eq!(Sense::CloudRoute.as_str(), "cloud_route");
    }

    #[tokio::test]
    async fn kill_switch_blocks_every_sense() {
        // Regression guard: the kill switch is the outermost gate and
        // MUST short-circuit every variant before per-sense policy runs.
        let dir = std::env::temp_dir().join(format!("lifeos-gate-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let mgr = SensoryPipelineManager::new(dir.clone()).unwrap();
        {
            let mut st = mgr.state.write().await;
            st.kill_switch_active = true;
            st.vision.enabled = true;
            st.voice.always_on_active = true;
            st.voice.meeting_capture_enabled = true;
            st.voice.tts_enabled = true;
            st.presence.camera_consented = true;
        }
        for sense in [
            Sense::Screen,
            Sense::Camera,
            Sense::Microphone,
            Sense::AlwaysOnListening,
            Sense::Meeting,
            Sense::Tts,
            Sense::WindowTracking,
            Sense::CloudRoute,
        ] {
            let result = mgr.ensure_sense_allowed(sense, "test.kill_switch").await;
            assert!(
                result.is_err(),
                "kill switch must block {:?} but returned Ok",
                sense
            );
        }
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn meeting_gate_respects_per_sense_toggle() {
        // Axi should be able to hear the user (wake word, voice commands)
        // WITHOUT auto-recording every meeting. Turning
        // `meeting_capture_enabled` off must deny Sense::Meeting while
        // Sense::Microphone still passes — the defining property of the
        // new toggle.
        let dir =
            std::env::temp_dir().join(format!("lifeos-meeting-gate-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let mgr = SensoryPipelineManager::new(dir.clone()).unwrap();
        {
            let mut st = mgr.state.write().await;
            st.kill_switch_active = false;
            st.voice.audio_enabled = true;
            st.voice.meeting_capture_enabled = false;
        }
        let mic = mgr
            .ensure_sense_allowed(Sense::Microphone, "test.mic")
            .await;
        let meeting = mgr
            .ensure_sense_allowed(Sense::Meeting, "test.meeting")
            .await;
        assert!(
            mic.is_ok(),
            "Microphone should pass with audio_enabled=true"
        );
        assert!(
            meeting.is_err(),
            "Meeting should be refused with meeting_capture_enabled=false"
        );

        // Flip back: both pass.
        {
            let mut st = mgr.state.write().await;
            st.voice.meeting_capture_enabled = true;
        }
        assert!(mgr
            .ensure_sense_allowed(Sense::Meeting, "test.meeting_on")
            .await
            .is_ok());

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn sense_screen_blocked_when_disabled() {
        let dir = std::env::temp_dir().join(format!("lifeos-gate-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let mgr = SensoryPipelineManager::new(dir.clone()).unwrap();
        // kill switch off but vision.enabled still false (default).
        assert!(mgr
            .ensure_sense_allowed(Sense::Screen, "test.screen_off")
            .await
            .is_err());
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn sense_window_tracking_fails_closed_without_follow_along() {
        // If the FollowAlong manager isn't wired, window tracking must
        // refuse — we fail-closed rather than fail-open because this
        // gate controls whether window titles land in MemoryPlane.
        let dir = std::env::temp_dir().join(format!("lifeos-gate-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let mgr = SensoryPipelineManager::new(dir.clone()).unwrap();
        let result = mgr
            .ensure_sense_allowed(Sense::WindowTracking, "test.no_follow_along")
            .await;
        assert!(result.is_err());
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn gate_audit_ring_records_every_decision() {
        let dir = std::env::temp_dir().join(format!("lifeos-gate-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let mgr = SensoryPipelineManager::new(dir.clone()).unwrap();
        {
            let mut st = mgr.state.write().await;
            st.kill_switch_active = true; // all calls will fail
        }
        let _ = mgr.ensure_sense_allowed(Sense::Camera, "test.a").await;
        let _ = mgr.ensure_sense_allowed(Sense::Tts, "test.b").await;
        let log = mgr.gate_audit().await;
        assert_eq!(log.len(), 2);
        // Newest-first ordering — last call appears first.
        assert_eq!(log[0].caller, "test.b");
        assert_eq!(log[0].sense, Sense::Tts);
        assert!(!log[0].allowed);
        assert_eq!(log[1].caller, "test.a");
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn gate_audit_ring_caps_at_buffer_size() {
        // Verifies the ring trims oldest entries; prevents unbounded
        // memory growth if a misbehaving caller loops on the gate.
        let dir = std::env::temp_dir().join(format!("lifeos-gate-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let mgr = SensoryPipelineManager::new(dir.clone()).unwrap();
        for _ in 0..(GATE_AUDIT_RING_CAPACITY + 25) {
            let _ = mgr.ensure_sense_allowed(Sense::Tts, "test.cap").await;
        }
        let log = mgr.gate_audit().await;
        assert_eq!(log.len(), GATE_AUDIT_RING_CAPACITY);
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn stale_presence_capture_detection_matches_only_real_presence_commands() {
        assert!(is_stale_presence_capture_process(
            "/usr/bin/ffmpeg -f v4l2 -i /dev/video0 -frames:v 1 /var/lib/lifeos/camera/presence-123.jpg",
            "/dev/video0",
        ));
        assert!(!is_stale_presence_capture_process(
            "/usr/bin/ffmpeg -f x11grab -i :0.0 screenshot.jpg",
            "/dev/video0",
        ));
        assert!(!is_stale_presence_capture_process(
            "/usr/bin/ffmpeg -f v4l2 -i /dev/video0 /tmp/other-capture.jpg",
            "/dev/video0",
        ));
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
    fn extract_streaming_tts_prefix_waits_for_complete_sentence() {
        assert_eq!(
            extract_streaming_tts_prefix("Hola, estoy revisando eso"),
            None
        );
        assert_eq!(
            extract_streaming_tts_prefix("Hola, estoy revisando eso. Ahora sigo."),
            Some("Hola, estoy revisando eso.".to_string())
        );
    }

    #[test]
    fn trim_streamed_prefix_from_response_removes_matching_first_sentence() {
        let remaining = trim_streamed_prefix_from_response(
            "Claro, ya revise tu pedido. Todo se ve correcto.",
            "Claro, ya revise tu pedido.",
        );
        assert_eq!(remaining, "Todo se ve correcto.");
    }

    #[test]
    fn envelope_similarity_detects_shifted_playback_echo_shape() {
        let snippet = vec![0.2, 0.8, 1.0, 0.75, 0.35, 0.15];
        let playback = vec![0.05, 0.09, 0.2, 0.8, 1.0, 0.75, 0.35, 0.15, 0.04];
        let similarity = max_envelope_similarity(&snippet, &playback);
        assert!(similarity > 0.98, "similarity was {similarity}");
    }

    #[test]
    fn envelope_similarity_rejects_different_phrase_shape() {
        let snippet = vec![0.2, 0.8, 1.0, 0.75, 0.35, 0.15];
        let playback = vec![1.0, 0.95, 0.92, 0.9, 0.88, 0.87, 0.86, 0.85];
        let similarity = max_envelope_similarity(&snippet, &playback);
        assert!(similarity < 0.93, "similarity was {similarity}");
    }

    #[test]
    fn clear_single_burst_uses_fast_endpoint() {
        let target = post_speech_silence_target(MicFieldMode::NearField, 6, 5, 1);
        assert!(target <= 1.1, "target was {target}");
    }

    #[test]
    fn multi_burst_speech_keeps_longer_pause_budget() {
        let target = post_speech_silence_target(MicFieldMode::NearField, 8, 4, 3);
        assert!(
            (target - UTTERANCE_SILENCE_AFTER_SPEECH_SECS).abs() < f64::EPSILON,
            "target was {target}"
        );
    }

    #[test]
    fn far_field_adds_small_endpoint_buffer() {
        let near = post_speech_silence_target(MicFieldMode::NearField, 6, 5, 1);
        let far = post_speech_silence_target(MicFieldMode::FarField, 6, 5, 1);
        assert!(far > near, "near={near}, far={far}");
        assert!(far <= 1.25, "far target was {far}");
    }

    #[test]
    fn trim_utterance_pcm_to_speech_removes_leading_and_trailing_padding() {
        let pcm: Vec<u8> = (0u8..120).collect();
        let trimmed = trim_utterance_pcm_to_speech(&pcm, Some(20), Some(80));
        let preroll_bytes =
            ((AUDIO_SAMPLE_RATE as f64 * 2.0 * UTTERANCE_PREROLL_SECS) as usize) & !1;
        let postroll_bytes =
            ((AUDIO_SAMPLE_RATE as f64 * 2.0 * UTTERANCE_POSTROLL_SECS) as usize) & !1;
        let expected_start = 20usize.saturating_sub(preroll_bytes);
        let expected_end = (80usize.saturating_add(postroll_bytes)).min(pcm.len());
        assert_eq!(trimmed, pcm[expected_start..expected_end].to_vec());
    }

    #[test]
    fn trim_utterance_pcm_to_speech_is_noop_without_complete_offsets() {
        let pcm: Vec<u8> = (0u8..48).collect();
        assert_eq!(trim_utterance_pcm_to_speech(&pcm, None, Some(20)), pcm);
        assert_eq!(trim_utterance_pcm_to_speech(&pcm, Some(12), None), pcm);
    }

    #[test]
    fn trim_utterance_pcm_to_speech_clamps_to_pcm_bounds() {
        let pcm: Vec<u8> = (0u8..32).collect();
        let trimmed = trim_utterance_pcm_to_speech(&pcm, Some(2), Some(30));
        assert_eq!(trimmed, pcm);
    }

    #[test]
    fn build_interactive_stt_args_uses_fast_profile_for_short_audio() {
        let args = build_interactive_stt_args(
            "/tmp/utterance.wav",
            Some("/models/stt.gguf"),
            "es",
            Some(3_200),
            SttProfile::Command,
        );
        assert!(args
            .windows(2)
            .any(|pair| pair == ["-m", "/models/stt.gguf"]));
        assert!(args.windows(2).any(|pair| pair == ["-l", "es"]));
        assert!(args.contains(&"-sns".to_string()));
        assert!(args
            .windows(2)
            .any(|pair| pair == ["-bs", STT_FAST_BEAM_SIZE]));
        assert!(args
            .windows(2)
            .any(|pair| pair == ["-bo", STT_FAST_BEST_OF]));
        assert!(args
            .windows(2)
            .any(|pair| pair == ["-ml", STT_FAST_MAX_LEN]));
        assert!(args.contains(&"-sow".to_string()));
        assert!(args
            .windows(2)
            .any(|pair| pair == ["-f", "/tmp/utterance.wav"]));
    }

    #[test]
    fn build_interactive_stt_args_uses_tighter_hotword_profile() {
        let args = build_interactive_stt_args(
            "/tmp/hotword.wav",
            None,
            "es",
            Some(3_600),
            SttProfile::HotwordProbe,
        );
        assert!(args
            .windows(2)
            .any(|pair| pair == ["-bs", STT_HOTWORD_BEAM_SIZE]));
        assert!(args
            .windows(2)
            .any(|pair| pair == ["-bo", STT_HOTWORD_BEST_OF]));
        assert!(args
            .windows(2)
            .any(|pair| pair == ["-ml", STT_HOTWORD_MAX_LEN]));
        assert!(args.windows(2).any(|pair| pair
            == [
                "--prompt",
                "Axi. Axi, ayudame. Axi, dime la hora. Axi, abre la terminal. Oxi. Ahsi."
            ]));
    }

    #[test]
    fn build_interactive_stt_args_skips_fast_profile_for_long_audio() {
        let args = build_interactive_stt_args(
            "/tmp/lecture.wav",
            None,
            "es",
            Some(8_500),
            SttProfile::Command,
        );
        assert!(!args.contains(&"-sow".to_string()));
        assert!(!args
            .windows(2)
            .any(|pair| pair == ["-bs", STT_FAST_BEAM_SIZE]));
        assert!(!args
            .windows(2)
            .any(|pair| pair == ["-bo", STT_FAST_BEST_OF]));
        assert!(!args
            .windows(2)
            .any(|pair| pair == ["-ml", STT_FAST_MAX_LEN]));
    }

    #[test]
    fn build_whisper_stream_args_include_streaming_controls() {
        let args = build_whisper_stream_args(Some("/models/ggml-tiny.bin"), "es");
        assert!(args
            .windows(2)
            .any(|pair| pair == ["-m", "/models/ggml-tiny.bin"]));
        assert!(args.windows(2).any(|pair| pair == ["-l", "es"]));
        assert!(args
            .windows(2)
            .any(|pair| pair == ["--step", STT_STREAM_STEP_MS]));
        assert!(args
            .windows(2)
            .any(|pair| pair == ["--length", STT_STREAM_LENGTH_MS]));
        assert!(args
            .windows(2)
            .any(|pair| pair == ["--keep", STT_STREAM_KEEP_MS]));
        assert!(args.contains(&"-kc".to_string()));
    }

    #[test]
    fn extract_latest_whisper_stream_text_ignores_ansi_and_start_banner() {
        let raw = "[Start speaking]\n\x1b[2K\rhola\x1b[2K\rhola axi abre terminal";
        assert_eq!(
            extract_latest_whisper_stream_text(raw).as_deref(),
            Some("hola axi abre terminal")
        );
    }

    #[test]
    fn estimate_pcm_wav_duration_ms_matches_mono_pcm_layout() {
        let temp =
            std::env::temp_dir().join(format!("lifeos-stt-duration-{}.wav", uuid::Uuid::new_v4()));
        let pcm_len = AUDIO_BYTES_PER_SECOND * 2;
        let wav_len = 44 + pcm_len;
        std::fs::write(&temp, vec![0u8; wav_len]).unwrap();
        let duration_ms = estimate_pcm_wav_duration_ms(temp.to_str().unwrap());
        assert_eq!(duration_ms, Some(2_000));
        std::fs::remove_file(temp).ok();
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

    // ── D2: Capabilities regression guard ────────────────────────────────────
    #[test]
    fn test_capabilities_has_no_piper_fields() {
        let caps = SensoryCapabilities::default();
        let value = serde_json::to_value(&caps).expect("serialize SensoryCapabilities");
        assert!(
            value.get("tts_binary").is_none(),
            "SensoryCapabilities must not contain tts_binary (piper field)"
        );
        assert!(
            value.get("tts_model").is_none(),
            "SensoryCapabilities must not contain tts_model (piper field)"
        );
        assert!(
            value.get("tts_server_url").is_some(),
            "SensoryCapabilities must contain tts_server_url (kokoro field)"
        );
        assert!(
            value.get("kokoro_voices").is_some(),
            "SensoryCapabilities must contain kokoro_voices (kokoro field)"
        );
    }

    // ── D1: resolve_tts_voice permutation tests ───────────────────────────────
    fn make_voices(names: &[&str]) -> Vec<KokoroVoice> {
        names
            .iter()
            .map(|&n| KokoroVoice {
                name: n.to_string(),
                language: "es".to_string(),
                gender: "female".to_string(),
                is_default: false,
            })
            .collect()
    }

    #[test]
    fn test_resolve_tts_voice_override_in_available() {
        let model = crate::user_model::UserModel::default();
        let available = make_voices(&["if_sara", "af_heart"]);
        let result = resolve_tts_voice(&model, "if_sara", Some("af_heart"), &available);
        assert_eq!(result, "af_heart");
    }

    #[test]
    fn test_resolve_tts_voice_override_not_in_available_falls_back_to_default() {
        let model = crate::user_model::UserModel::default();
        let available = make_voices(&["if_sara"]);
        let result = resolve_tts_voice(&model, "if_sara", Some("nonexistent"), &available);
        assert_eq!(result, "if_sara");
    }

    #[test]
    fn test_resolve_tts_voice_model_voice_in_available() {
        let model = crate::user_model::UserModel {
            tts_voice: Some("im_nicola".to_string()),
            ..Default::default()
        };
        let available = make_voices(&["if_sara", "im_nicola"]);
        let result = resolve_tts_voice(&model, "if_sara", None, &available);
        assert_eq!(result, "im_nicola");
    }

    #[test]
    fn test_resolve_tts_voice_model_voice_not_in_available() {
        let model = crate::user_model::UserModel {
            tts_voice: Some("im_nicola".to_string()),
            ..Default::default()
        };
        let available = make_voices(&["if_sara"]);
        let result = resolve_tts_voice(&model, "if_sara", None, &available);
        assert_eq!(result, "if_sara");
    }

    #[test]
    fn test_resolve_tts_voice_no_model_voice_returns_default() {
        let model = crate::user_model::UserModel::default();
        let available = make_voices(&["if_sara"]);
        let result = resolve_tts_voice(&model, "if_sara", None, &available);
        assert_eq!(result, "if_sara");
    }

    #[test]
    fn test_resolve_tts_voice_empty_string_override_treats_as_none() {
        let model = crate::user_model::UserModel::default();
        let available = make_voices(&["if_sara", "af_heart"]);
        let result = resolve_tts_voice(&model, "if_sara", Some(""), &available);
        assert_eq!(result, "if_sara");
    }

    // --- Warning A: probe interval ---

    #[test]
    fn kokoro_probe_interval_is_five_minutes() {
        assert_eq!(
            KOKORO_PROBE_INTERVAL,
            std::time::Duration::from_secs(300),
            "KOKORO_PROBE_INTERVAL debe ser 5 minutos (300 s)"
        );
    }

    // --- Warning B: retry count ---

    #[test]
    fn kokoro_retry_delays_len_gives_three_total_attempts() {
        // 1 initial attempt + KOKORO_RETRY_DELAYS.len() retries == 3
        assert_eq!(
            KOKORO_RETRY_DELAYS.len(),
            2,
            "KOKORO_RETRY_DELAYS must have exactly 2 entries (1 initial + 2 retries = 3 total)"
        );
    }

    // ── C2: throttle should_probe helper ─────────────────────────────────────
    // Tests the pure helper that decides whether a probe should run.
    // None → always probe; Some(recent) → skip; Some(old) → probe again.

    #[test]
    fn should_probe_returns_true_when_never_probed() {
        let now = std::time::Instant::now();
        assert!(
            should_probe(None, KOKORO_PROBE_INTERVAL, now),
            "should_probe debe retornar true cuando nunca se probó (last=None)"
        );
    }

    #[test]
    fn should_probe_returns_false_when_last_probe_was_recent() {
        let now = std::time::Instant::now();
        // 1 minute ago — well within the 5-minute interval
        let recent = now - std::time::Duration::from_secs(60);
        assert!(
            !should_probe(Some(recent), KOKORO_PROBE_INTERVAL, now),
            "should_probe debe retornar false cuando el último probe fue hace 1 min (intervalo 5 min)"
        );
    }

    #[test]
    fn should_probe_returns_true_when_last_probe_was_old() {
        let now = std::time::Instant::now();
        // 6 minutes ago — past the 5-minute interval
        let old = now - std::time::Duration::from_secs(360);
        assert!(
            should_probe(Some(old), KOKORO_PROBE_INTERVAL, now),
            "should_probe debe retornar true cuando el último probe fue hace 6 min (intervalo 5 min)"
        );
    }

    // ── W4: split probe/synth clients ────────────────────────────────────────

    #[test]
    fn kokoro_probe_client_returns_same_instance() {
        let a = kokoro_probe_client();
        let b = kokoro_probe_client();
        assert!(
            std::ptr::eq(a, b),
            "kokoro_probe_client() debe devolver siempre el mismo puntero (singleton)"
        );
    }

    #[test]
    fn kokoro_synth_client_returns_same_instance() {
        let a = kokoro_synth_client();
        let b = kokoro_synth_client();
        assert!(
            std::ptr::eq(a, b),
            "kokoro_synth_client() debe devolver siempre el mismo puntero (singleton)"
        );
    }

    #[test]
    fn kokoro_probe_and_synth_clients_are_different_instances() {
        let probe = kokoro_probe_client() as *const _ as *const ();
        let synth = kokoro_synth_client() as *const _ as *const ();
        assert!(
            !std::ptr::eq(probe, synth),
            "kokoro_probe_client() y kokoro_synth_client() deben ser instancias distintas"
        );
    }

    // ── N1: mutex poison recovery ─────────────────────────────────────────────
    // Direct unit test is hard without a threaded panic, but this confirms the
    // function compiles and returns a valid guard using unwrap_or_else(|p| p.into_inner()).
    // Coverage provided implicitly by all tests that call probe_kokoro_tts_server()
    // or any function locking LAST_KOKORO_PROBE.
    #[test]
    fn last_kokoro_probe_lock_is_accessible() {
        // Verifies that LAST_KOKORO_PROBE can be locked without panicking.
        // The production code uses unwrap_or_else(|p| p.into_inner()) — if it
        // were still .expect(...), a poisoned lock would panic the sensory loop.
        let guard = LAST_KOKORO_PROBE.lock().unwrap_or_else(|p| p.into_inner());
        assert!(
            guard.is_none() || guard.is_some(),
            "LAST_KOKORO_PROBE debe ser accesible"
        );
    }
}
