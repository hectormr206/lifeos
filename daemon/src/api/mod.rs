//! LifeOS REST API Server
//!
//! Provides HTTP API endpoints for:
//! - Mobile companion app integration
//! - Remote system monitoring
//! - Push notifications
//! - System management

mod lab;

use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::{Request, StatusCode},
    middleware::{self, Next},
    response::{
        sse::{Event, KeepAlive, Sse},
        Json, Response,
    },
    routing::{delete, get, post, put},
    Router,
};
use log::error;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::process::Command;
use tokio::sync::RwLock;
use tower_http::services::ServeDir;
use utoipa::{
    openapi::security::{ApiKey, ApiKeyValue, SecurityScheme},
    Modify, OpenApi, ToSchema,
};
use utoipa_swagger_ui::SwaggerUi;

use crate::accessibility::AccessibilityManager;
use crate::agent_runtime::AgentRuntimeManager;
use crate::ai::AiManager;
use crate::computer_use::{ComputerUseAction, ComputerUseManager};
use crate::context_policies::ContextPoliciesManager;
use crate::experience_modes::ExperienceManager;
use crate::follow_along::FollowAlongManager;
use crate::health::HealthMonitor;
use crate::lab::LabManager;
use crate::memory_plane::{MemoryPlaneManager, MemorySearchMode};
use crate::notifications::NotificationManager;
use crate::overlay::{OverlayManager, OverlayTheme};
use crate::screen_capture::ScreenCapture;
use crate::sensory_pipeline::{
    SensoryBenchmarkReport, SensoryBenchmarkRequest, SensoryPipelineManager, SensoryRuntimeSync,
    TtsRequest, VisionDescribeRequest, VoiceLoopRequest,
};
use crate::skill_generator::SkillRegistry;
use crate::system::SystemMonitor;
use crate::update_scheduler::UpdateScheduler;
use crate::visual_comfort::{ComfortProfile, VisualComfortManager};
use std::path::PathBuf;

const MODEL_DIR: &str = "/var/lib/lifeos/models";
const LLAMA_ENV_FILE: &str = "/etc/lifeos/llama-server.env";
const REMOVED_MODELS_FILE: &str = "/var/lib/lifeos/models/.removed-models";
const PINNED_MODELS_FILE: &str = "/var/lib/lifeos/models/.pinned-models";
const MODEL_LIFECYCLE_STATE_FILE: &str = "/var/lib/lifeos/models/.model-lifecycle-state.json";
const DEFAULT_DOWNLOAD_MBIT_PER_SEC: u64 = 100;
const EMBEDDED_MODEL_CATALOG_JSON: &str = include_str!("../../../contracts/models/v1/catalog.json");
const EMBEDDED_MODEL_CATALOG_SIG: &str =
    include_str!("../../../contracts/models/v1/catalog.json.sig");

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct OverlayModelLifecycleEntry {
    #[serde(default)]
    installed: bool,
    #[serde(default)]
    selected: bool,
    #[serde(default)]
    pinned: bool,
    #[serde(default)]
    removed_by_user: bool,
    #[serde(default)]
    updated_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct OverlayModelLifecycleState {
    #[serde(default)]
    version: u32,
    #[serde(default)]
    models: BTreeMap<String, OverlayModelLifecycleEntry>,
}

#[derive(Debug, Clone, Deserialize)]
struct OverlayCatalog {
    catalog_version: String,
    models: Vec<OverlayCatalogModel>,
}

#[derive(Debug, Clone, Deserialize)]
struct OverlayCatalogModel {
    id: String,
    download_url: String,
    size_bytes: u64,
    #[serde(default)]
    checksum_sha256: Option<String>,
    #[serde(default)]
    recommended_ram_gb: Option<u32>,
    #[serde(default)]
    recommended_vram_gb: Option<u32>,
    #[serde(default)]
    offload_policy: Option<String>,
    #[serde(default)]
    companion_mmproj: Option<OverlayCatalogCompanionArtifact>,
    #[serde(default)]
    runtime_profiles: Vec<String>,
    #[serde(default)]
    roles: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct OverlayCatalogCompanionArtifact {
    filename: String,
    download_url: String,
    #[serde(default)]
    size_bytes: Option<u64>,
    #[serde(default)]
    checksum_sha256: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct OverlayHardwareSnapshot {
    total_ram_gb: u32,
    total_vram_gb: Option<u32>,
    gpu_name: Option<String>,
    gpu_temp_celsius: Option<f32>,
    gpu_utilization_percent: Option<u32>,
    thermal_pressure: bool,
    on_battery: Option<bool>,
}

#[derive(Debug, Clone)]
struct OverlayModelFitAssessment {
    fit_tier: String,
    expected_gpu_layers: i32,
    expected_ram_gb: Option<u32>,
    expected_vram_gb: Option<u32>,
    expected_battery_impact: String,
}

/// Shared API state
#[derive(Clone)]
#[allow(dead_code)]
pub struct ApiState {
    pub system_monitor: Arc<RwLock<SystemMonitor>>,
    pub health_monitor: Arc<HealthMonitor>,
    pub ai_manager: Arc<RwLock<AiManager>>,
    pub notification_manager: Arc<NotificationManager>,
    pub overlay_manager: Arc<RwLock<OverlayManager>>,
    pub screen_capture: Arc<RwLock<ScreenCapture>>,
    pub sensory_pipeline_manager: Arc<RwLock<SensoryPipelineManager>>,
    pub experience_manager: Arc<RwLock<ExperienceManager>>,
    pub update_scheduler: Arc<RwLock<UpdateScheduler>>,
    pub follow_along_manager: Arc<RwLock<FollowAlongManager>>,
    pub context_policies_manager: Arc<RwLock<ContextPoliciesManager>>,
    pub telemetry_manager: Arc<RwLock<crate::telemetry::TelemetryManager>>,
    pub agent_runtime_manager: Arc<RwLock<AgentRuntimeManager>>,
    pub memory_plane_manager: Arc<RwLock<MemoryPlaneManager>>,
    pub visual_comfort_manager: Arc<RwLock<VisualComfortManager>>,
    pub accessibility_manager: Arc<RwLock<AccessibilityManager>>,
    pub lab_manager: Arc<RwLock<LabManager>>,
    pub llm_router: Arc<RwLock<crate::llm_router::LlmRouter>>,
    pub task_queue: Arc<crate::task_queue::TaskQueue>,
    pub supervisor: Arc<crate::supervisor::Supervisor>,
    pub scheduled_tasks: Arc<crate::scheduled_tasks::ScheduledTaskManager>,
    pub health_tracker: Arc<tokio::sync::Mutex<crate::health_tracking::HealthTracker>>,
    pub calendar: Arc<crate::calendar::CalendarManager>,
    pub event_bus: tokio::sync::broadcast::Sender<crate::events::DaemonEvent>,
    pub config: ApiConfig,
    pub game_guard: Option<Arc<RwLock<crate::game_guard::GameGuard>>>,
    pub wake_word_detector: Option<Arc<crate::wake_word::WakeWordDetector>>,
    pub skill_registry: SkillRegistry,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct ApiConfig {
    pub bind_address: SocketAddr,
    pub api_key: Option<String>,
    pub enable_cors: bool,
    pub max_request_size: usize,
}

impl Default for ApiConfig {
    fn default() -> Self {
        Self {
            bind_address: "127.0.0.1:8081".parse().unwrap(),
            api_key: None,
            enable_cors: true,
            max_request_size: 10 * 1024 * 1024, // 10MB
        }
    }
}

// ==================== API DOCUMENTATION ====================

#[derive(OpenApi)]
#[openapi(
    paths(
        get_system_status,
        get_system_resources,
        get_health_status,
        get_ai_status,
        get_ai_models,
        post_ai_chat,
        show_overlay,
        hide_overlay,
        toggle_overlay,
        overlay_chat,
        overlay_screenshot,
        clear_overlay,
        overlay_status,
        overlay_config,
        overlay_export,
        overlay_import,
        overlay_models,
        overlay_models_select,
        overlay_models_remove,
        overlay_models_pull,
        overlay_models_pin,
        overlay_models_unpin,
        overlay_models_cleanup,
        overlay_models_export_inventory,
        overlay_models_import_inventory,
        list_shortcuts,
        register_shortcuts,
        unregister_shortcuts,
        trigger_shortcut,
        get_current_mode,
        set_mode,
        list_modes,
        compare_modes,
        get_mode_features,
        test_feature,
        get_mode_info,
        get_update_channel,
        set_update_channel,
        get_update_schedule,
        set_update_schedule,
        get_available_updates,
        schedule_update,
        check_for_updates,
        get_update_history,
        install_update,
        rollback_update,
        get_update_status,
        clear_schedule,
        get_followalong_config,
        set_followalong_config,
        set_followalong_consent,
        get_followalong_context,
        get_followalong_stats,
        generate_followalong_summary,
        translate_followalong_summary,
        explain_followalong_activity,
        clear_followalong_events,
        get_notifications,
        post_notification,
        get_system_info,
        post_system_command,
        run_accessibility_audit,
        get_accessibility_settings,
    ),
    components(
        schemas(
            SystemStatus,
            ResourceUsage,
            HealthReport,
            AiStatus,
            ModelInfo,
            ChatRequest,
            ChatResponse,
            OverlayModelSelectorResponse,
            OverlayModelCard,
            OverlayModelSelectRequest,
            OverlayModelRemoveRequest,
            OverlayModelPullRequest,
            OverlayModelPinRequest,
            OverlayModelActionResponse,
            Notification,
            SystemInfo,
            CommandRequest,
            ApiError,
            UpdateChannelResponse,
            SetUpdateChannelRequest,
            UpdateScheduleResponse,
            SetUpdateScheduleRequest,
            AvailableUpdatesResponse,
            AvailableVersionInfo,
            ScheduleUpdateRequest,
            UpdateHistoryResponse,
            UpdateRecordInfo,
            InstallUpdateRequest,
            UpdateStatusResponse,
            FollowAlongConfigResponse,
            SetFollowAlongConfigRequest,
            SetConsentRequest,
            RecordEventRequest,
            SummaryResponse,
            TranslateSummaryRequest,
            ExplainActivityRequest,
            ExplanationResponse,
            ContextStateResponse,
            EventStatsResponse,
            EventCountInfo,
            ExportEventsRequest,
            ContextTypeResponse,
            SetContextTypeRequest,
            ListContextProfilesResponse,
            ProfileInfo,
            ProfileDetailsResponse,
            SwitchContextRequest,
            CreateContextProfileRequest,
            AddContextRuleRequest,
            DetectContextResponse,
            GetContextRulesResponse,
            ContextRuleInfo,
            ContextStatsResponse,
            ApplyRulesRequest,
            ApplyRulesResponse,
            AppliedRuleInfo,
        )
    ),
    tags(
        (name = "system", description = "System management endpoints"),
        (name = "health", description = "Health monitoring endpoints"),
        (name = "ai", description = "AI service endpoints"),
        (name = "overlay", description = "AI overlay UI endpoints"),
        (name = "notifications", description = "Notification endpoints"),
        (name = "updates", description = "Update management endpoints"),
        (name = "followalong", description = "FollowAlong monitoring endpoints"),
        (name = "context", description = "Context policies endpoints"),
        (name = "accessibility", description = "Accessibility and WCAG audit endpoints"),
    ),
    modifiers(&SecurityAddon)
)]
pub struct ApiDoc;

struct SecurityAddon;

impl Modify for SecurityAddon {
    fn modify(&self, openapi: &mut utoipa::openapi::OpenApi) {
        if let Some(components) = openapi.components.as_mut() {
            components.add_security_scheme(
                "api_key",
                SecurityScheme::ApiKey(ApiKey::Header(ApiKeyValue::new("X-API-Key"))),
            );
        }
    }
}

// ==================== DATA MODELS ====================

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayStatusResponse {
    pub visible: bool,
    pub focused: bool,
    pub stats: OverlayStats,
    pub chat_history: Vec<ChatMessageInfo>,
    pub axi_state: String,
    pub mic_active: bool,
    pub camera_active: bool,
    pub screen_active: bool,
    pub kill_switch_active: bool,
    pub feedback_stage: Option<String>,
    pub tokens_per_second: Option<f32>,
    pub eta_ms: Option<u64>,
    pub last_error: Option<String>,
    pub notifications: Vec<crate::overlay::ProactiveNotification>,
    pub widget_visible: bool,
    pub widget_badge: Option<String>,
    pub window_position: Option<(i32, i32)>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct DashboardBootstrapResponse {
    pub token: Option<String>,
    pub auth_required: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayStats {
    pub total_messages: usize,
    pub visible: bool,
    pub focused: bool,
    pub theme: String,
    pub shortcut: String,
    pub enabled: bool,
    pub axi_state: String,
    pub widget_visible: bool,
    pub widget_badge: Option<String>,
    pub widget_aura: String,
    pub active_notifications: usize,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayChatRequest {
    pub message: String,
    #[serde(default)]
    pub include_screen: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayChatResponse {
    pub response: String,
    pub model: String,
    pub tokens_used: Option<u32>,
    pub duration_ms: u64,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayScreenshotResponse {
    pub path: String,
    pub filename: String,
    pub width: u32,
    pub height: u32,
    pub size_bytes: u64,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct SetModeRequest {
    pub mode: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct CompareModesRequest {
    pub mode1: String,
    pub mode2: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct TestFeatureRequest {
    pub feature: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct CurrentModeResponse {
    pub mode: String,
    pub display_name: String,
    pub description: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ListModesResponse {
    pub modes: Vec<ModeInfo>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ModeInfo {
    pub name: String,
    pub display_name: String,
    pub description: String,
    pub ui_complexity: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct CompareModesResponse {
    pub mode1: String,
    pub mode1_display: String,
    pub mode2: String,
    pub mode2_display: String,
    pub differences: Vec<String>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ModeFeaturesResponse {
    pub mode: String,
    pub features: Vec<FeatureInfo>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct FeatureInfo {
    pub name: String,
    pub display_name: String,
    pub description: String,
    pub enabled: bool,
    pub category: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct TestFeatureResponse {
    pub available: bool,
    pub mode: String,
    pub feature: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ModeInfoResponse {
    pub mode: String,
    pub display_name: String,
    pub description: String,
    pub features: Vec<FeatureInfo>,
    pub settings: ModeSettingsInfo,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ModeSettingsInfo {
    pub ui_complexity: String,
    pub update_channel: String,
    pub ai_enabled: bool,
    pub ai_context_size: u32,
    pub telemetry_enabled: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayConfigRequest {
    #[serde(default)]
    pub theme: Option<String>,
    #[serde(default)]
    pub shortcut: Option<String>,
    #[serde(default)]
    pub opacity: Option<f32>,
    #[serde(default)]
    pub enabled: Option<bool>,
    #[serde(default)]
    pub widget_visible: Option<bool>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayExportRequest {
    pub path: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayShortcutTriggerRequest {
    pub shortcut_name: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ShortcutInfo {
    pub name: String,
    pub keys: String,
    pub action: String,
    pub description: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ShortcutsListResponse {
    pub shortcuts: Vec<ShortcutInfo>,
    pub active: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayImportRequest {
    pub path: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayModelSelectorResponse {
    pub active_model: Option<String>,
    pub configured_model: Option<String>,
    pub configured_mmproj: Option<String>,
    pub catalog_version: String,
    pub catalog_signature_valid: bool,
    pub featured_roster: Vec<String>,
    pub hardware: OverlayModelHardwareSummary,
    pub storage: OverlayModelStorageSummary,
    pub models: Vec<OverlayModelCard>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayModelCard {
    pub id: String,
    pub size_bytes: Option<u64>,
    pub size: String,
    pub installed: bool,
    pub selected: bool,
    pub pinned: bool,
    pub removed_by_user: bool,
    pub featured: bool,
    pub integrity_available: bool,
    pub checksum_sha256: Option<String>,
    pub recommended_ram_gb: Option<u32>,
    pub recommended_vram_gb: Option<u32>,
    pub offload_policy: Option<String>,
    pub required_disk_bytes: Option<u64>,
    pub estimated_download_seconds: Option<u64>,
    pub download_resumable: bool,
    pub fit_tier: String,
    pub expected_gpu_layers: i32,
    pub expected_ram_gb: Option<u32>,
    pub expected_vram_gb: Option<u32>,
    pub expected_battery_impact: String,
    pub runtime_profiles: Vec<String>,
    pub roles: Vec<String>,
    pub companion_mmproj: Option<String>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayModelHardwareSummary {
    pub total_ram_gb: u32,
    pub total_vram_gb: Option<u32>,
    pub gpu_name: Option<String>,
    pub gpu_temp_celsius: Option<f32>,
    pub gpu_utilization_percent: Option<u32>,
    pub thermal_pressure: bool,
    pub on_battery: Option<bool>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayModelStorageSummary {
    pub model_dir: String,
    pub filesystem_total_bytes: u64,
    pub filesystem_used_bytes: u64,
    pub filesystem_free_bytes: u64,
    pub filesystem_used_percent: f32,
    pub installed_model_bytes: u64,
    pub reclaimable_model_bytes: u64,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayModelSelectRequest {
    pub model: String,
    #[serde(default)]
    pub restart: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayModelRemoveRequest {
    pub model: String,
    #[serde(default = "default_true")]
    pub remove_companion: bool,
    #[serde(default = "default_true")]
    pub select_fallback: bool,
    #[serde(default)]
    pub restart: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayModelPullRequest {
    pub model: String,
    #[serde(default)]
    pub force: bool,
    #[serde(default)]
    pub restart: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayModelPinRequest {
    pub model: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayModelInventoryExportRequest {
    pub path: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayModelInventoryImportRequest {
    pub path: String,
    #[serde(default)]
    pub adopt_pinning: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayModelCleanupRequest {
    #[serde(default)]
    pub dry_run: bool,
    #[serde(default = "default_true")]
    pub remove_companion: bool,
    #[serde(default)]
    pub restart: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct OverlayModelInventorySnapshot {
    schema_version: String,
    exported_at: String,
    #[serde(default)]
    device_id: Option<String>,
    models: BTreeMap<String, OverlayModelLifecycleEntry>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayModelActionResponse {
    pub ok: bool,
    pub message: String,
    pub selected_model: Option<String>,
    pub companion_mmproj: Option<String>,
    pub selected_mmproj: Option<String>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayModelCleanupResponse {
    pub ok: bool,
    pub dry_run: bool,
    pub removed_models: Vec<String>,
    pub removed_companions: Vec<String>,
    pub reclaimed_bytes: u64,
    pub selected_model: Option<String>,
    pub selected_mmproj: Option<String>,
    pub message: String,
}

// ==================== UPDATE API STRUCTS ====================

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct UpdateChannelResponse {
    pub channel: String,
    pub display_name: String,
    pub description: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct SetUpdateChannelRequest {
    pub channel: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct UpdateScheduleResponse {
    pub schedule_type: String,
    pub update_time: String,
    pub update_day: u8,
    pub check_frequency_hours: u32,
    pub auto_install: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct SetUpdateScheduleRequest {
    #[serde(default)]
    pub schedule_type: Option<String>,
    #[serde(default)]
    pub update_time: Option<String>,
    #[serde(default)]
    pub update_day: Option<u8>,
    #[serde(default)]
    pub check_frequency_hours: Option<u32>,
    #[serde(default)]
    pub auto_install: Option<bool>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct AvailableUpdatesResponse {
    pub updates: Vec<AvailableVersionInfo>,
    pub count: usize,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct AvailableVersionInfo {
    pub version: String,
    pub channel: String,
    pub release_date: String,
    pub notes: String,
    pub size_bytes: u64,
    pub download_url: String,
    pub required_disk_space_mb: u32,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ScheduleUpdateRequest {
    pub version: String,
    #[serde(default)]
    pub channel: Option<String>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct UpdateHistoryResponse {
    pub history: Vec<UpdateRecordInfo>,
    pub count: usize,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct UpdateRecordInfo {
    pub timestamp: String,
    pub version: String,
    pub channel: String,
    pub status: String,
    pub checksum: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct InstallUpdateRequest {
    pub version: String,
    #[serde(default)]
    pub channel: Option<String>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct UpdateStatusResponse {
    pub current_channel: String,
    pub available_versions: usize,
    pub scheduled_updates: usize,
    pub last_update: Option<String>,
    pub schedule_type: String,
    pub check_frequency_hours: u32,
}

// ==================== FOLLOWALONG API STRUCTS ====================

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct FollowAlongConfigResponse {
    pub enabled: bool,
    pub consent_status: String,
    pub auto_summarize: bool,
    pub auto_translate: bool,
    pub auto_explain: bool,
    pub summary_interval_seconds: u64,
    pub max_events_buffer: usize,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct SetFollowAlongConfigRequest {
    #[serde(default)]
    pub enabled: Option<bool>,
    #[serde(default)]
    pub auto_summarize: Option<bool>,
    #[serde(default)]
    pub auto_translate: Option<bool>,
    #[serde(default)]
    pub auto_explain: Option<bool>,
    #[serde(default)]
    pub summary_interval_seconds: Option<u64>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct SetConsentRequest {
    pub granted: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct RecordEventRequest {
    pub event_type: String,
    #[serde(default)]
    pub application: Option<String>,
    #[serde(default)]
    pub window_title: Option<String>,
    pub details: serde_json::Value,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct SummaryResponse {
    pub summary: String,
    pub timestamp: String,
    pub event_count: usize,
    pub session_duration_minutes: i64,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct TranslateSummaryRequest {
    pub target_language: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ExplainActivityRequest {
    pub question: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ExplanationResponse {
    pub explanation: String,
    pub question: String,
    pub timestamp: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ContextStateResponse {
    pub current_application: Option<String>,
    pub current_window: Option<String>,
    pub active_pattern: Option<String>,
    pub session_duration_minutes: i64,
    pub last_event: Option<String>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct EventStatsResponse {
    pub total_events: usize,
    pub event_counts: Vec<EventCountInfo>,
    pub current_application: Option<String>,
    pub current_window: Option<String>,
    pub session_duration_minutes: i64,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct EventCountInfo {
    pub event_type: String,
    pub count: usize,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ExportEventsRequest {
    pub path: String,
}

// ==================== CONTEXT POLICIES API STRUCTS ====================

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ContextTypeResponse {
    pub context: String,
    pub display_name: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct SetContextTypeRequest {
    pub context: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ListContextProfilesResponse {
    pub profiles: Vec<ProfileInfo>,
    pub count: usize,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ProfileInfo {
    pub name: String,
    pub display_name: String,
    pub description: String,
    pub context: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ProfileDetailsResponse {
    pub name: String,
    pub display_name: String,
    pub description: String,
    pub context: String,
    pub features: Vec<FeatureInfo>,
    pub detection_method: String,
    pub trigger_applications: Vec<String>,
    pub trigger_network: Option<String>,
    pub priority: u32,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct SwitchContextRequest {
    pub context: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct CreateContextProfileRequest {
    pub name: String,
    pub display_name: String,
    pub description: String,
    pub context: String,
    pub detection_method: String,
    pub trigger_applications: Vec<String>,
    pub trigger_network: Option<String>,
    pub priority: u32,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct AddContextRuleRequest {
    pub name: String,
    pub description: String,
    pub rule_type: String,
    pub enabled: bool,
    pub priority: u32,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct DetectContextResponse {
    pub detected: bool,
    pub context: String,
    pub confidence: f32,
    pub detection_method: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct GetContextRulesResponse {
    pub context: String,
    pub rules: Vec<ContextRuleInfo>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ContextRuleInfo {
    pub id: String,
    pub name: String,
    pub description: String,
    pub rule_type: String,
    pub enabled: bool,
    pub priority: u32,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ContextStatsResponse {
    pub current_context: String,
    pub active_profile: String,
    pub last_switch: String,
    pub total_profiles: usize,
    pub detection_method: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ApplyRulesRequest {
    pub context: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ApplyRulesResponse {
    pub context: String,
    pub applied_rules: Vec<AppliedRuleInfo>,
    pub status: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct AppliedRuleInfo {
    pub rule_id: String,
    pub rule_name: String,
    pub action: String,
    pub status: String,
}

// ==================== VISUAL COMFORT API STRUCTS ====================

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct VisualComfortStatusResponse {
    pub current_temperature: u32,
    pub target_temperature: u32,
    pub current_font_scale: f32,
    pub target_font_scale: f32,
    pub animations_enabled: bool,
    pub active_profile: String,
    pub session_duration_minutes: u32,
    pub is_night_time: bool,
    pub transitioning: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct VisualComfortConfigResponse {
    pub color_temperature_day: u32,
    pub color_temperature_night: u32,
    pub night_start_hour: u8,
    pub night_end_hour: u8,
    pub font_scale_base: f32,
    pub font_scale_max: f32,
    pub animation_reduction_threshold_minutes: u32,
    pub enabled: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct SetProfileRequest {
    pub profile: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct SetTemperatureRequest {
    pub temperature: u32,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct SetFontScaleRequest {
    pub scale: f32,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct SetAnimationsRequest {
    pub enabled: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ProfileInfoResponse {
    pub name: String,
    pub display_name: String,
    pub temperature: u32,
    pub font_scale: f32,
    pub contrast_level: f32,
    pub animations_enabled: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ChatMessageInfo {
    pub id: String,
    pub role: String,
    pub content: String,
    pub timestamp: String,
    pub has_screen_context: bool,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct SystemStatus {
    pub online: bool,
    pub uptime_seconds: u64,
    pub version: String,
    pub hostname: String,
    pub boot_time: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ResourceUsage {
    pub cpu_percent: f32,
    pub memory_used_gb: f32,
    pub memory_total_gb: f32,
    pub memory_percent: f32,
    pub disk_used_gb: f32,
    pub disk_total_gb: f32,
    pub disk_percent: f32,
    pub network_rx_mbps: f32,
    pub network_tx_mbps: f32,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct HealthReport {
    pub healthy: bool,
    pub score: u8,
    pub checks: Vec<HealthCheck>,
    pub timestamp: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct HealthCheck {
    pub name: String,
    pub status: String,
    pub message: Option<String>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct AiStatus {
    pub running: bool,
    pub version: String,
    pub active_model: Option<String>,
    pub models_loaded: Vec<String>,
    pub gpu_available: bool,
    pub gpu_name: Option<String>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
    pub size: String,
    pub parameter_count: String,
    pub modified_at: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ChatRequest {
    pub message: String,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub stream: bool,
    #[serde(default)]
    pub context: Option<Vec<ChatMessage>>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ChatResponse {
    pub response: String,
    pub model: String,
    pub tokens_used: Option<u32>,
    pub duration_ms: u64,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct Notification {
    pub id: String,
    pub title: String,
    pub message: String,
    #[serde(rename = "type")]
    pub notification_type: String,
    pub priority: String,
    pub timestamp: String,
    pub read: bool,
    pub action_url: Option<String>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct SystemInfo {
    pub hostname: String,
    pub os_name: String,
    pub os_version: String,
    pub kernel_version: String,
    pub architecture: String,
    pub cpu_model: String,
    pub cpu_cores: u32,
    pub total_memory_gb: f32,
    pub gpu_model: Option<String>,
    pub gpu_vram_used_mb: Option<f32>,
    pub gpu_vram_total_mb: Option<f32>,
    pub lifeos_version: String,
    pub lifeos_build: String,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct CommandRequest {
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct ApiError {
    pub error: String,
    pub message: String,
    pub code: u16,
}

// ==================== API ROUTES ====================

pub fn create_router(state: ApiState) -> Router {
    let api_v1 = Router::new()
        // System endpoints
        .route("/system/status", get(get_system_status))
        .route("/system/resources", get(get_system_resources))
        .route("/system/info", get(get_system_info))
        .route("/system/command", post(post_system_command))
        // Health endpoints
        .route("/health", get(get_health_status))
        // Safe mode endpoints
        .route("/safe-mode", get(get_safe_mode_status))
        .route("/safe-mode/exit", post(post_exit_safe_mode))
        // AI endpoints
        .route("/ai/status", get(get_ai_status))
        .route("/ai/models", get(get_ai_models))
        .route("/ai/chat", post(post_ai_chat))
        .route("/vision/ocr", post(post_vision_ocr))
        .route("/audio/stt/status", get(get_stt_status))
        .route("/audio/stt/start", post(start_stt_service))
        .route("/audio/stt/stop", post(stop_stt_service))
        .route("/audio/stt/transcribe", post(transcribe_audio_file))
        .route("/sensory/status", get(get_sensory_status))
        .route("/sensory/voice/session", post(run_voice_session))
        .route("/sensory/voice/interrupt", post(interrupt_voice_session))
        .route("/sensory/tts/speak", post(run_tts_preview))
        .route(
            "/sensory/vision/describe",
            post(describe_screen_with_sensory),
        )
        .route(
            "/sensory/presence",
            get(get_presence_status).post(refresh_presence_status),
        )
        .route("/sensory/benchmark", post(run_sensory_benchmark))
        .route("/sensory/kill-switch", post(trigger_sensory_kill_switch))
        // Wake word training
        .route("/sensory/wake-word/record", post(record_wake_word_sample))
        .route("/sensory/wake-word/train", post(train_wake_word_model))
        .route(
            "/sensory/wake-word/samples",
            get(list_wake_word_samples).delete(delete_wake_word_samples),
        )
        // Overlay endpoints
        .route("/overlay/show", post(show_overlay))
        .route("/overlay/hide", post(hide_overlay))
        .route("/overlay/toggle", post(toggle_overlay))
        .route("/overlay/chat", post(overlay_chat))
        .route("/overlay/screenshot", post(overlay_screenshot))
        .route("/overlay/clear", post(clear_overlay))
        .route("/overlay/status", get(overlay_status))
        .route("/overlay/config", post(overlay_config))
        .route("/overlay/export", post(overlay_export))
        .route("/overlay/import", post(overlay_import))
        .route("/overlay/models", get(overlay_models))
        .route("/overlay/models/select", post(overlay_models_select))
        .route("/overlay/models/remove", post(overlay_models_remove))
        .route("/overlay/models/pull", post(overlay_models_pull))
        .route("/overlay/models/pin", post(overlay_models_pin))
        .route("/overlay/models/unpin", post(overlay_models_unpin))
        .route("/overlay/models/cleanup", post(overlay_models_cleanup))
        .route(
            "/overlay/models/export",
            post(overlay_models_export_inventory),
        )
        .route(
            "/overlay/models/import",
            post(overlay_models_import_inventory),
        )
        // Notification endpoints
        .route("/notifications", get(get_notifications))
        .route("/notifications", post(post_notification))
        .route("/notifications/:id/read", put(mark_notification_read))
        // Shortcut endpoints
        .route("/shortcuts/list", get(list_shortcuts))
        .route("/shortcuts/register", post(register_shortcuts))
        .route("/shortcuts/unregister", post(unregister_shortcuts))
        .route("/shortcuts/trigger", post(trigger_shortcut))
        // Mode endpoints
        .route("/mode/current", get(get_current_mode))
        .route("/mode/set", post(set_mode))
        .route("/mode/list", get(list_modes))
        .route("/mode/compare", post(compare_modes))
        .route("/mode/features", get(get_mode_features))
        .route("/mode/test", post(test_feature))
        .route("/mode/info", get(get_mode_info))
        // Update endpoints
        .route("/updates/channel", get(get_update_channel))
        .route("/updates/set-channel", post(set_update_channel))
        .route("/updates/schedule", get(get_update_schedule))
        .route("/updates/set-schedule", post(set_update_schedule))
        .route("/updates/available", get(get_available_updates))
        .route("/updates/schedule-update", post(schedule_update))
        .route("/updates/check", post(check_for_updates))
        .route("/updates/history", get(get_update_history))
        .route("/updates/install", post(install_update))
        .route("/updates/rollback", post(rollback_update))
        .route("/updates/status", get(get_update_status))
        .route("/updates/schedule-clear", post(clear_schedule))
        .route("/followalong/config", get(get_followalong_config))
        .route("/followalong/config", post(set_followalong_config))
        .route("/followalong/consent", post(set_followalong_consent))
        .route("/followalong/context", get(get_followalong_context))
        .route("/followalong/stats", get(get_followalong_stats))
        .route("/followalong/summary", post(generate_followalong_summary))
        .route(
            "/followalong/translate",
            post(translate_followalong_summary),
        )
        .route("/followalong/explain", post(explain_followalong_activity))
        .route("/followalong/clear", post(clear_followalong_events))
        // Context policies
        .route("/context/status", get(get_context_status))
        .route("/context/set", post(set_context))
        .route("/context/profiles", get(list_context_profiles))
        .route("/context/profile/:context", get(get_context_profile))
        .route("/context/profile", post(create_context_profile))
        .route("/context/profile/:context", delete(delete_context_profile))
        .route("/context/profile/:context/rule", post(add_context_rule))
        .route("/context/detect", post(detect_context))
        .route("/context/rules/:context", get(get_context_rules))
        .route("/context/stats", get(get_context_stats))
        // Telemetry
        .route("/telemetry/stats", get(get_telemetry_stats))
        .route("/telemetry/consent", get(get_telemetry_consent))
        .route("/telemetry/consent", post(set_telemetry_consent))
        .route("/telemetry/events", get(get_telemetry_events))
        .route("/telemetry/snapshot", post(take_hardware_snapshot))
        .route("/telemetry/export", get(export_telemetry))
        .route("/telemetry/clear", post(clear_telemetry))
        // Phase 2 foundations: intents + identity + ledger
        .route("/intents/plan", post(plan_intent))
        .route("/intents/apply", post(apply_intent))
        .route("/intents/status/:intent_id", get(get_intent_status))
        .route("/intents/validate", post(validate_intent))
        .route("/intents/log", get(get_intent_log))
        .route("/intents/ledger/export", post(export_intent_ledger))
        .route("/id/issue", post(issue_identity_token))
        .route("/id/list", get(list_identity_tokens))
        .route("/id/revoke", post(revoke_identity_token))
        .route("/workspace/run", post(run_workspace))
        .route("/workspace/runs", get(list_workspace_runs))
        .route("/orchestrator/team-run", post(orchestrate_team_run))
        .route("/orchestrator/team-runs", get(list_team_runs))
        .route(
            "/runtime/mode",
            get(get_runtime_mode).post(set_runtime_mode),
        )
        .route(
            "/runtime/trust-mode",
            get(get_trust_mode).post(set_trust_mode),
        )
        .route(
            "/runtime/resources",
            get(get_resource_runtime).post(set_resource_runtime),
        )
        .route(
            "/runtime/autonomy",
            get(get_autonomy_session).post(start_autonomy_session),
        )
        .route(
            "/runtime/always-on",
            get(get_always_on_runtime).post(set_always_on_runtime),
        )
        .route(
            "/runtime/always-on/classify",
            post(classify_always_on_runtime),
        )
        .route("/runtime/model-routing", post(route_runtime_model))
        .route("/runtime/self-defense", get(get_self_defense_status))
        .route(
            "/runtime/self-defense/repair",
            post(run_self_defense_repair),
        )
        .route(
            "/runtime/sensory",
            get(get_sensory_runtime).post(set_sensory_runtime),
        )
        .route("/runtime/sensory/snapshot", post(capture_sensory_snapshot))
        .route(
            "/runtime/heartbeat",
            get(get_heartbeat_runtime).post(set_heartbeat_runtime),
        )
        .route("/runtime/heartbeat/tick", post(run_heartbeat_tick))
        .route("/runtime/workspace-awareness", get(get_workspace_awareness))
        .route("/runtime/prompt-shield/scan", post(scan_prompt_shield))
        .route("/runtime/autonomy/stop", post(stop_autonomy_session))
        .route(
            "/runtime/autonomy/kill-switch",
            post(trigger_autonomy_kill_switch),
        )
        .route(
            "/memory/entries",
            get(list_memory_entries).post(add_memory_entry),
        )
        .route("/memory/entries/:entry_id", delete(delete_memory_entry))
        .route("/memory/search", get(search_memory_entries))
        .route("/memory/stats", get(get_memory_stats))
        .route("/memory/graph", get(get_memory_graph))
        .route("/memory/mcp/context", post(get_memory_mcp_context))
        .route("/mcp/memory/context", post(get_memory_mcp_context))
        .route("/mcp/skills/tools", get(get_mcp_skills_tools))
        .route("/computer-use/status", get(get_computer_use_status))
        .route("/computer-use/action", post(execute_computer_use_action))
        // Visual Comfort endpoints
        .route("/visual-comfort/status", get(get_visual_comfort_status))
        .route("/visual-comfort/config", get(get_visual_comfort_config))
        .route("/visual-comfort/profile", post(set_visual_comfort_profile))
        .route(
            "/visual-comfort/profiles",
            get(list_visual_comfort_profiles),
        )
        .route(
            "/visual-comfort/temperature",
            post(set_visual_comfort_temperature),
        )
        .route(
            "/visual-comfort/font-scale",
            post(set_visual_comfort_font_scale),
        )
        .route(
            "/visual-comfort/animations",
            post(set_visual_comfort_animations),
        )
        .route("/visual-comfort/reset", post(reset_visual_comfort_session))
        // Accessibility endpoints
        .route("/accessibility/audit", get(run_accessibility_audit))
        .route("/accessibility/settings", get(get_accessibility_settings))
        // LLM Router endpoints
        .route("/llm/chat", post(post_llm_chat))
        .route("/llm/providers", get(get_llm_providers))
        .route("/llm/reload", post(post_llm_reload))
        // Task Queue endpoints
        .route("/tasks", get(get_tasks))
        .route("/tasks", post(post_task))
        .route("/tasks/summary", get(get_tasks_summary))
        .route("/tasks/:id", get(get_task_by_id))
        .route("/tasks/:id/cancel", post(cancel_task))
        // Scheduled tasks endpoints
        .route("/tasks/scheduled", get(get_scheduled_tasks))
        .route("/tasks/scheduled", post(post_scheduled_task))
        .route("/tasks/scheduled/:id", delete(delete_scheduled_task))
        .route("/tasks/scheduled/:id/enable", post(toggle_scheduled_task))
        // Health tracking endpoints
        .route("/health/tracking", get(get_health_tracking))
        .route("/health/tracking/break", post(post_health_break))
        .route("/health/tracking/reminders", get(get_health_reminders))
        // Proactive alerts endpoint
        .route("/proactive/alerts", get(get_proactive_alerts))
        // Email endpoints
        .route("/email/inbox", get(get_email_inbox))
        .route("/email/send", post(post_email_send))
        .route("/email/status", get(get_email_status))
        // Calendar endpoints
        .route("/calendar/today", get(get_calendar_today))
        .route("/calendar/upcoming", get(get_calendar_upcoming))
        .route("/calendar/events", post(post_calendar_event))
        .route("/calendar/events/:id", delete(delete_calendar_event))
        .route("/calendar/reminders", get(get_calendar_reminders))
        // File management endpoints
        .route("/files/search", get(get_file_search))
        .route("/files/content-search", get(get_file_content_search))
        // Clipboard endpoint
        .route("/clipboard/copy", post(post_clipboard_copy))
        // Settings: API keys management
        .route("/settings/keys", get(get_api_keys_status))
        .route("/settings/keys", post(post_api_keys))
        // Settings: Timezone (AM.3)
        .route("/settings/timezone", get(get_timezone))
        .route("/settings/timezone", post(post_timezone))
        // Messaging channels status
        .route("/messaging/channels", get(get_messaging_channels))
        // Game Guard endpoints
        .route("/game-guard/status", get(get_game_guard_status))
        .route("/game-guard/toggle", post(post_game_guard_toggle))
        .route(
            "/game-guard/assistant-toggle",
            post(post_game_assistant_toggle),
        )
        // Battery management endpoints
        .route("/battery/status", get(get_battery_status))
        .route("/battery/threshold", post(post_battery_threshold))
        .route("/battery/history", get(get_battery_history))
        // Translation endpoint
        .route("/translate", post(post_translate))
        // Skill registry endpoints
        .route("/skills", get(get_skills_list))
        .route("/skills/:name", get(get_skill_by_name))
        .route("/skills/:name/run", post(post_skill_run))
        .route("/skills/reload", post(post_skills_reload))
        .route("/skills/diagnostics", get(get_skills_diagnostics))
        // Supervisor endpoints
        .route("/supervisor/status", get(get_supervisor_status))
        .route("/supervisor/metrics", get(get_supervisor_metrics))
        // Knowledge graph endpoints
        .route("/knowledge-graph/export", get(get_knowledge_graph_export))
        .route("/knowledge-graph/import", post(post_knowledge_graph_import))
        // Audit events query endpoint
        .route("/audit/events", get(get_audit_events))
        // Lab endpoints
        .nest("/lab", lab::lab_routes())
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            require_bootstrap_token,
        ));

    // SSE endpoint lives outside the auth middleware — it checks ?token= query param
    // since EventSource cannot set custom headers.
    let sse_route = Router::new()
        .route("/api/v1/events/stream", get(event_stream))
        .with_state(state.clone());

    // WebSocket control plane — handles its own auth on first message.
    let ws_route = Router::new()
        .route("/ws", get(crate::ws_gateway::ws_handler))
        .with_state(state.clone());

    // Dashboard static files (no auth required — local-only server).
    let dashboard_dir = std::env::var("LIFEOS_DASHBOARD_DIR")
        .unwrap_or_else(|_| "daemon/static/dashboard".to_string());
    let dashboard_service = ServeDir::new(&dashboard_dir).append_index_html_on_directories(true);
    let dashboard_bootstrap_route = Router::new()
        .route("/dashboard/bootstrap", get(dashboard_bootstrap))
        .with_state(state.clone());

    // Prometheus metrics endpoint — no auth required (standard practice)
    let metrics_route = Router::new()
        .route("/metrics", get(handle_metrics))
        .with_state(state.clone());

    Router::new()
        .nest("/api/v1", api_v1)
        .merge(sse_route)
        .merge(ws_route)
        .merge(metrics_route)
        .merge(dashboard_bootstrap_route)
        .nest_service("/dashboard", dashboard_service)
        .merge(SwaggerUi::new("/swagger-ui").url("/api-docs/openapi.json", ApiDoc::openapi()))
        .with_state(state)
}

async fn dashboard_bootstrap(
    State(state): State<ApiState>,
    request: Request<Body>,
) -> Result<Json<DashboardBootstrapResponse>, (StatusCode, Json<ApiError>)> {
    // Only serve bootstrap token when the server is bound to loopback.
    // This prevents token leakage if the daemon is ever exposed externally.
    if !state.config.bind_address.ip().is_loopback() {
        return Err((
            StatusCode::FORBIDDEN,
            Json(ApiError {
                error: "Forbidden".to_string(),
                message: "Bootstrap endpoint is only available on localhost".to_string(),
                code: 403,
            }),
        ));
    }
    let peer = request
        .extensions()
        .get::<axum::extract::ConnectInfo<std::net::SocketAddr>>()
        .map(|ci| ci.0);
    log::info!(
        "Dashboard bootstrap token served to {:?} — local-only endpoint",
        peer
    );
    Ok(Json(DashboardBootstrapResponse {
        token: state.config.api_key.clone(),
        auth_required: state.config.api_key.is_some(),
    }))
}

async fn require_bootstrap_token(
    State(state): State<ApiState>,
    request: Request<Body>,
    next: Next,
) -> Result<Response, (StatusCode, Json<ApiError>)> {
    let expected = match state.config.api_key.as_deref() {
        Some(key) => key,
        None => {
            // No token configured — allow localhost access unconditionally.
            // The server only binds to 127.0.0.1 so this is safe.
            return Ok(next.run(request).await);
        }
    };

    let provided = request
        .headers()
        .get("x-bootstrap-token")
        .or_else(|| request.headers().get("x-api-key"))
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();

    if provided == expected {
        return Ok(next.run(request).await);
    }

    Err((
        StatusCode::UNAUTHORIZED,
        Json(ApiError {
            error: "Unauthorized".to_string(),
            message: "Missing or invalid bootstrap token".to_string(),
            code: 401,
        }),
    ))
}

// ==================== SSE EVENT STREAM ====================

/// Server-Sent Events endpoint for real-time dashboard updates.
/// Accepts auth via `?token=` query param because EventSource cannot set headers.
async fn event_stream(
    State(state): State<ApiState>,
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Result<
    Sse<impl futures_lite::Stream<Item = Result<Event, std::convert::Infallible>>>,
    (StatusCode, Json<ApiError>),
> {
    // Allow unauthenticated SSE on localhost (same policy as the REST middleware).
    if !state.config.bind_address.ip().is_loopback() {
        let expected = state.config.api_key.as_deref().unwrap_or_default();
        let provided = params.get("token").map(|s| s.as_str()).unwrap_or_default();
        if provided != expected {
            return Err((
                StatusCode::UNAUTHORIZED,
                Json(ApiError {
                    error: "Unauthorized".to_string(),
                    message: "Missing or invalid token query parameter".to_string(),
                    code: 401,
                }),
            ));
        }
    }

    let rx = state.event_bus.subscribe();
    let stream = async_stream::stream! {
        let mut rx = rx;
        loop {
            match rx.recv().await {
                Ok(event) => {
                    let json = serde_json::to_string(&event).unwrap_or_default();
                    yield Ok(Event::default().data(json));
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    yield Ok(Event::default().event("lagged").data(format!("{n}")));
                }
                Err(_) => break,
            }
        }
    };
    Ok(Sse::new(stream).keep_alive(
        KeepAlive::new()
            .interval(std::time::Duration::from_secs(15))
            .text("ping"),
    ))
}

// ==================== HANDLERS ====================

/// Get system status
#[utoipa::path(
    get,
    path = "/api/v1/system/status",
    responses(
        (status = 200, description = "System status retrieved successfully", body = SystemStatus),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "system"
)]
async fn get_system_status(
    State(state): State<ApiState>,
) -> Result<Json<SystemStatus>, (StatusCode, Json<ApiError>)> {
    let _system_monitor = state.system_monitor.read().await;

    let uptime = std::time::Duration::from_secs(
        std::fs::read_to_string("/proc/uptime")
            .ok()
            .and_then(|s| s.split_whitespace().next()?.parse::<f64>().ok())
            .unwrap_or(0.0) as u64,
    );

    let status = SystemStatus {
        online: true,
        uptime_seconds: uptime.as_secs(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        hostname: get_hostname(),
        boot_time: chrono::Local::now()
            .checked_sub_signed(chrono::Duration::seconds(uptime.as_secs() as i64))
            .map(|t| t.to_rfc3339())
            .unwrap_or_default(),
    };

    Ok(Json(status))
}

/// Get system resource usage
#[utoipa::path(
    get,
    path = "/api/v1/system/resources",
    responses(
        (status = 200, description = "Resource usage retrieved successfully", body = ResourceUsage),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "system"
)]
async fn get_system_resources(
    State(state): State<ApiState>,
) -> Result<Json<ResourceUsage>, (StatusCode, Json<ApiError>)> {
    let mut system_monitor = state.system_monitor.write().await;
    let metrics = system_monitor.collect_metrics().map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to collect system metrics: {e}"),
                code: 500,
            }),
        )
    })?;

    let usage = ResourceUsage {
        cpu_percent: metrics.cpu_usage,
        memory_used_gb: metrics.memory_used_mb as f32 / 1024.0,
        memory_total_gb: metrics.memory_total_mb as f32 / 1024.0,
        memory_percent: metrics.memory_usage,
        disk_used_gb: metrics.disk_used_gb as f32,
        disk_total_gb: metrics.disk_total_gb as f32,
        disk_percent: metrics.disk_usage,
        network_rx_mbps: metrics.network_rx_mbps,
        network_tx_mbps: metrics.network_tx_mbps,
    };

    Ok(Json(usage))
}

/// Get system information
#[utoipa::path(
    get,
    path = "/api/v1/system/info",
    responses(
        (status = 200, description = "System info retrieved successfully", body = SystemInfo),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "system"
)]
async fn get_system_info(
    State(_state): State<ApiState>,
) -> Result<Json<SystemInfo>, (StatusCode, Json<ApiError>)> {
    let info = SystemInfo {
        hostname: get_hostname(),
        os_name: "LifeOS".to_string(),
        os_version: "0.1.0".to_string(),
        kernel_version: get_kernel_version(),
        architecture: std::env::consts::ARCH.to_string(),
        cpu_model: get_cpu_model(),
        cpu_cores: num_cpus::get() as u32,
        total_memory_gb: get_total_memory_gb(),
        gpu_model: get_gpu_model(),
        gpu_vram_used_mb: get_gpu_vram().map(|(u, _)| u),
        gpu_vram_total_mb: get_gpu_vram().map(|(_, t)| t),
        lifeos_version: env!("CARGO_PKG_VERSION").to_string(),
        lifeos_build: "2024.02.24".to_string(),
    };

    Ok(Json(info))
}

/// Execute system command
#[utoipa::path(
    post,
    path = "/api/v1/system/command",
    request_body = CommandRequest,
    responses(
        (status = 200, description = "Command executed successfully"),
        (status = 400, description = "Invalid command", body = ApiError),
        (status = 403, description = "Command not allowed", body = ApiError),
    ),
    tag = "system"
)]
async fn post_system_command(
    State(_state): State<ApiState>,
    Json(request): Json<CommandRequest>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    // Validate command (only allow safe commands)
    let allowed_commands = ["status", "info", "ping"];

    if !allowed_commands.contains(&request.command.as_str()) {
        return Err((
            StatusCode::FORBIDDEN,
            Json(ApiError {
                error: "Forbidden".to_string(),
                message: "Command not allowed".to_string(),
                code: 403,
            }),
        ));
    }

    // Execute command
    Ok(StatusCode::OK)
}

/// Get health status
#[utoipa::path(
    get,
    path = "/api/v1/health",
    responses(
        (status = 200, description = "Health status retrieved successfully", body = HealthReport),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "health"
)]
async fn get_health_status(
    State(state): State<ApiState>,
) -> Result<Json<HealthReport>, (StatusCode, Json<ApiError>)> {
    let report = state.health_monitor.check_all().await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to collect health status: {e}"),
                code: 500,
            }),
        )
    })?;

    let total_checks = report.checks.len() as u32;
    let passed_checks = report.checks.iter().filter(|check| check.passed).count() as u32;
    let score = if total_checks == 0 {
        100
    } else {
        ((passed_checks * 100) / total_checks) as u8
    };

    let checks: Vec<HealthCheck> = report
        .checks
        .iter()
        .map(|check| HealthCheck {
            name: check.name.clone(),
            status: if check.passed {
                "ok".to_string()
            } else {
                "warning".to_string()
            },
            message: Some(check.message.clone()),
        })
        .collect();

    let response = HealthReport {
        healthy: report.healthy,
        score,
        checks,
        timestamp: report.timestamp.to_rfc3339(),
    };

    Ok(Json(response))
}

/// Get safe mode status
async fn get_safe_mode_status() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "active": crate::safe_mode::is_safe_mode(),
    }))
}

/// Exit safe mode manually and reset boot counter
async fn post_exit_safe_mode() -> Json<serde_json::Value> {
    let was_active = crate::safe_mode::is_safe_mode();
    crate::safe_mode::exit_safe_mode();
    // Reset boot counter so next restart doesn't re-enter safe mode
    let data_dir = std::env::var("LIFEOS_DATA_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from("/var/lib/lifeos"));
    if let Err(e) = crate::safe_mode::reset_counter(&data_dir).await {
        log::warn!("Failed to reset boot counter: {}", e);
    }
    Json(serde_json::json!({
        "was_active": was_active,
        "active": crate::safe_mode::is_safe_mode(),
    }))
}

/// Get AI service status
#[utoipa::path(
    get,
    path = "/api/v1/ai/status",
    responses(
        (status = 200, description = "AI status retrieved successfully", body = AiStatus),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "ai"
)]
async fn get_ai_status(
    State(state): State<ApiState>,
) -> Result<Json<AiStatus>, (StatusCode, Json<ApiError>)> {
    let ai_manager = state.ai_manager.read().await;

    let status = AiStatus {
        running: ai_manager.is_running().await,
        version: "0.1.0".to_string(),
        active_model: ai_manager.active_model().await,
        models_loaded: ai_manager.loaded_models().await,
        gpu_available: ai_manager.gpu_available().await,
        gpu_name: ai_manager.gpu_name().await,
    };

    Ok(Json(status))
}

/// Get available AI models
#[utoipa::path(
    get,
    path = "/api/v1/ai/models",
    responses(
        (status = 200, description = "Models retrieved successfully", body = Vec<ModelInfo>),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "ai"
)]
async fn get_ai_models(
    State(state): State<ApiState>,
) -> Result<Json<Vec<ModelInfo>>, (StatusCode, Json<ApiError>)> {
    let ai_manager = state.ai_manager.read().await;

    let models = ai_manager.list_models().await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to list AI models: {e}"),
                code: 500,
            }),
        )
    })?;

    let models: Vec<ModelInfo> = models
        .into_iter()
        .map(|m| ModelInfo {
            id: m.name.clone(),
            name: m.name,
            size: format!("{} MB", m.size_mb),
            parameter_count: "unknown".to_string(),
            modified_at: m.modified,
        })
        .collect();

    Ok(Json(models))
}

/// Chat with AI
#[utoipa::path(
    post,
    path = "/api/v1/ai/chat",
    request_body = ChatRequest,
    responses(
        (status = 200, description = "Chat response received", body = ChatResponse),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 503, description = "AI service unavailable", body = ApiError),
    ),
    tag = "ai"
)]
async fn post_ai_chat(
    State(state): State<ApiState>,
    Json(request): Json<ChatRequest>,
) -> Result<Json<ChatResponse>, (StatusCode, Json<ApiError>)> {
    let ai_manager = state.ai_manager.read().await;

    if !ai_manager.is_running().await {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ApiError {
                error: "Service Unavailable".to_string(),
                message: "AI service is not running".to_string(),
                code: 503,
            }),
        ));
    }

    let start = std::time::Instant::now();

    let mut messages: Vec<(String, String)> = request
        .context
        .unwrap_or_default()
        .into_iter()
        .filter(|m| !m.content.trim().is_empty())
        .map(|m| (m.role, m.content))
        .collect();
    messages.push(("user".to_string(), request.message));

    let chat = ai_manager
        .chat(request.model.as_deref(), messages)
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_GATEWAY,
                Json(ApiError {
                    error: "Bad Gateway".to_string(),
                    message: format!("llama-server request failed: {e}"),
                    code: 502,
                }),
            )
        })?;

    let response = ChatResponse {
        response: chat.response,
        model: chat.model,
        tokens_used: chat.tokens_used,
        duration_ms: start.elapsed().as_millis() as u64,
    };

    Ok(Json(response))
}

const DEFAULT_STT_SERVICE: &str = "whisper-stt.service";
const DEFAULT_STT_BINARY: &str = "whisper-cli";

async fn resolve_stt_binary_path() -> Option<String> {
    for candidate in ["whisper-cli", "whisper", "whisper-cpp"] {
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

fn resolve_existing_stt_model_path(candidate: &str) -> Option<String> {
    let candidate = candidate.trim();
    if candidate.is_empty() {
        return None;
    }
    if std::path::Path::new(candidate).exists() {
        return Some(candidate.to_string());
    }

    let file_name = std::path::Path::new(candidate)
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
    .find(|path| std::path::Path::new(path).exists())
}

fn resolve_stt_model_path(model: Option<&str>) -> Option<String> {
    if let Some(path) = model.and_then(resolve_existing_stt_model_path) {
        return Some(path);
    }

    if let Ok(model) = std::env::var("LIFEOS_STT_MODEL") {
        if let Some(path) = resolve_existing_stt_model_path(&model) {
            return Some(path);
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
    .find(|candidate| std::path::Path::new(candidate).exists())
    .map(|candidate| candidate.to_string())
}

fn output_stderr(output: &std::process::Output) -> String {
    String::from_utf8_lossy(&output.stderr).trim().to_string()
}

async fn get_stt_status() -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let service = DEFAULT_STT_SERVICE;
    let running = Command::new("systemctl")
        .args(["is-active", "--quiet", service])
        .status()
        .await
        .map(|status| status.success())
        .unwrap_or(false);

    let enabled = Command::new("systemctl")
        .args(["is-enabled", "--quiet", service])
        .status()
        .await
        .map(|status| status.success())
        .unwrap_or(false);

    let binary = resolve_stt_binary_path()
        .await
        .unwrap_or_else(|| DEFAULT_STT_BINARY.to_string());

    Ok(Json(serde_json::json!({
        "running": running,
        "enabled": enabled,
        "service": service,
        "binary": binary,
    })))
}

async fn start_stt_service(
    Json(payload): Json<SttStartPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let service = DEFAULT_STT_SERVICE;
    let enable_on_boot = payload.enable.unwrap_or(false);

    let start_output = Command::new("systemctl")
        .args(["start", service])
        .output()
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: format!("Failed to execute systemctl start: {}", e),
                    code: 500,
                }),
            )
        })?;

    if !start_output.status.success() {
        return Err((
            StatusCode::BAD_GATEWAY,
            Json(ApiError {
                error: "Bad Gateway".to_string(),
                message: format!(
                    "Unable to start STT service '{}': {}",
                    service,
                    output_stderr(&start_output)
                ),
                code: 502,
            }),
        ));
    }

    if enable_on_boot {
        let enable_output = Command::new("systemctl")
            .args(["enable", service])
            .output()
            .await
            .map_err(|e| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ApiError {
                        error: "Internal Server Error".to_string(),
                        message: format!("Failed to execute systemctl enable: {}", e),
                        code: 500,
                    }),
                )
            })?;

        if !enable_output.status.success() {
            return Err((
                StatusCode::BAD_GATEWAY,
                Json(ApiError {
                    error: "Bad Gateway".to_string(),
                    message: format!(
                        "STT service started but failed to enable on boot: {}",
                        output_stderr(&enable_output)
                    ),
                    code: 502,
                }),
            ));
        }
    }

    Ok(Json(serde_json::json!({
        "status": "ok",
        "service": service,
        "running": true,
        "enable_on_boot": enable_on_boot,
    })))
}

async fn stop_stt_service() -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let service = DEFAULT_STT_SERVICE;
    let stop_output = Command::new("systemctl")
        .args(["stop", service])
        .output()
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: format!("Failed to execute systemctl stop: {}", e),
                    code: 500,
                }),
            )
        })?;

    if !stop_output.status.success() {
        return Err((
            StatusCode::BAD_GATEWAY,
            Json(ApiError {
                error: "Bad Gateway".to_string(),
                message: format!(
                    "Unable to stop STT service '{}': {}",
                    service,
                    output_stderr(&stop_output)
                ),
                code: 502,
            }),
        ));
    }

    Ok(Json(serde_json::json!({
        "status": "ok",
        "service": service,
        "running": false,
    })))
}

async fn transcribe_audio_file(
    Json(payload): Json<SttTranscribePayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let file = payload.file.trim();
    if file.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "file is required".to_string(),
                code: 400,
            }),
        ));
    }

    if !std::path::Path::new(file).exists() {
        return Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "Not Found".to_string(),
                message: format!("Audio file not found: {}", file),
                code: 404,
            }),
        ));
    }

    let (text, binary) = transcribe_with_whisper(file, payload.model.as_deref()).await?;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "text": text,
        "binary": binary,
        "model": payload.model,
    })))
}

async fn transcribe_with_whisper(
    file: &str,
    model: Option<&str>,
) -> Result<(String, String), (StatusCode, Json<ApiError>)> {
    let binary = resolve_stt_binary_path().await.ok_or_else(|| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ApiError {
                error: "Service Unavailable".to_string(),
                message: "No whisper.cpp binary found (expected whisper-cli/whisper)".to_string(),
                code: 503,
            }),
        )
    })?;

    let mut cmd = Command::new(&binary);
    if let Some(model) = resolve_stt_model_path(model) {
        cmd.arg("-m").arg(model);
    }
    cmd.args(["-f", file]);

    let output = cmd.output().await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to execute STT binary: {}", e),
                code: 500,
            }),
        )
    })?;

    if !output.status.success() {
        return Err((
            StatusCode::BAD_GATEWAY,
            Json(ApiError {
                error: "Bad Gateway".to_string(),
                message: format!(
                    "STT transcription failed with {}: {}",
                    binary,
                    output_stderr(&output)
                ),
                code: 502,
            }),
        ));
    }

    let mut text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if text.is_empty() {
        text = String::from_utf8_lossy(&output.stderr).trim().to_string();
    }
    Ok((text, binary))
}

async fn post_vision_ocr(
    State(state): State<ApiState>,
    Json(payload): Json<VisionOcrPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let capture_screen = payload.capture_screen.unwrap_or(payload.source.is_none());

    let source_path = if capture_screen {
        ensure_followalong_consent(&state).await?;
        let capture = ScreenCapture::new(PathBuf::from("/var/lib/lifeos/screenshots"));
        let screenshot = capture.capture().await.map_err(|e| {
            (
                StatusCode::BAD_GATEWAY,
                Json(ApiError {
                    error: "Bad Gateway".to_string(),
                    message: format!("Failed to capture screen for OCR: {}", e),
                    code: 502,
                }),
            )
        })?;
        screenshot.path.to_string_lossy().to_string()
    } else {
        payload
            .source
            .as_deref()
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .ok_or_else(|| {
                (
                    StatusCode::BAD_REQUEST,
                    Json(ApiError {
                        error: "Bad Request".to_string(),
                        message: "source is required when capture_screen=false".to_string(),
                        code: 400,
                    }),
                )
            })?
    };

    if !std::path::Path::new(&source_path).exists() {
        return Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "Not Found".to_string(),
                message: format!("Image source not found: {}", source_path),
                code: 404,
            }),
        ));
    }

    let language = payload
        .language
        .as_deref()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "eng".to_string());

    let tesseract_path = Command::new("which")
        .arg("tesseract")
        .output()
        .await
        .ok()
        .filter(|out| out.status.success())
        .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_string())
        .filter(|v| !v.is_empty())
        .ok_or_else(|| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(ApiError {
                    error: "Service Unavailable".to_string(),
                    message: "tesseract binary not found for OCR".to_string(),
                    code: 503,
                }),
            )
        })?;

    let output = Command::new(&tesseract_path)
        .arg(&source_path)
        .arg("stdout")
        .args(["-l", &language])
        .output()
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: format!("Failed to execute tesseract: {}", e),
                    code: 500,
                }),
            )
        })?;

    if !output.status.success() {
        return Err((
            StatusCode::BAD_GATEWAY,
            Json(ApiError {
                error: "Bad Gateway".to_string(),
                message: format!("OCR failed: {}", output_stderr(&output)),
                code: 502,
            }),
        ));
    }

    let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Ok(Json(serde_json::json!({
        "status": "ok",
        "engine": "tesseract",
        "language": language,
        "source": source_path,
        "text": text,
    })))
}

async fn get_sensory_status(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let ai_manager = *state.ai_manager.read().await;
    let sensory_mgr = state.sensory_pipeline_manager.read().await.clone();
    let status = sensory_mgr
        .refresh_capabilities(&ai_manager)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;
    Ok(Json(serde_json::json!(status)))
}

async fn run_voice_session(
    State(state): State<ApiState>,
    Json(payload): Json<SensoryVoiceSessionPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let ai_manager = *state.ai_manager.read().await;
    let overlay_mgr = state.overlay_manager.read().await.clone();
    let screen_capture = state.screen_capture.read().await.clone();
    let sensory_mgr = state.sensory_pipeline_manager.read().await.clone();
    let memory_plane = state.memory_plane_manager.read().await.clone();
    let telemetry = state.telemetry_manager.read().await.clone();

    let result = sensory_mgr
        .run_voice_loop(
            &ai_manager,
            &overlay_mgr,
            &screen_capture,
            &memory_plane,
            &telemetry,
            VoiceLoopRequest {
                audio_file: payload.audio_file,
                prompt: payload.prompt,
                include_screen: payload.include_screen.unwrap_or(false),
                screen_source: payload.screen_source,
                language: payload.language,
                voice_model: payload.voice_model,
                playback: payload.playback.unwrap_or(true),
            },
        )
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_GATEWAY,
                Json(ApiError {
                    error: "Bad Gateway".to_string(),
                    message: e.to_string(),
                    code: 502,
                }),
            )
        })?;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "voice_loop": result,
    })))
}

async fn interrupt_voice_session(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let overlay_mgr = state.overlay_manager.read().await.clone();
    let sensory_mgr = state.sensory_pipeline_manager.read().await.clone();
    let interrupted = sensory_mgr
        .interrupt_voice_session(&overlay_mgr)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "interrupted": interrupted,
    })))
}

async fn run_tts_preview(
    State(state): State<ApiState>,
    Json(payload): Json<SensoryTtsPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let overlay_mgr = state.overlay_manager.read().await.clone();
    let sensory_mgr = state.sensory_pipeline_manager.read().await.clone();
    let result = sensory_mgr
        .speak_text(
            &overlay_mgr,
            TtsRequest {
                text: payload.text,
                language: payload.language,
                voice_model: payload.voice_model,
                playback: payload.playback.unwrap_or(true),
            },
        )
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_GATEWAY,
                Json(ApiError {
                    error: "Bad Gateway".to_string(),
                    message: e.to_string(),
                    code: 502,
                }),
            )
        })?;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "tts": result,
    })))
}

async fn describe_screen_with_sensory(
    State(state): State<ApiState>,
    Json(payload): Json<SensoryVisionPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    if payload.source.is_none() && !payload.capture_screen.unwrap_or(true) {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "source is required when capture_screen=false".to_string(),
                code: 400,
            }),
        ));
    }

    let ai_manager = *state.ai_manager.read().await;
    let overlay_mgr = state.overlay_manager.read().await.clone();
    let screen_capture = state.screen_capture.read().await.clone();
    let sensory_mgr = state.sensory_pipeline_manager.read().await.clone();
    let memory_plane = state.memory_plane_manager.read().await.clone();

    let result = sensory_mgr
        .describe_screen(
            &ai_manager,
            &overlay_mgr,
            &screen_capture,
            &memory_plane,
            VisionDescribeRequest {
                source: payload.source,
                capture_screen: payload.capture_screen.unwrap_or(true),
                speak: payload.speak.unwrap_or(true),
                question: payload.question,
                language: payload.language,
                voice_model: payload.voice_model,
            },
        )
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_GATEWAY,
                Json(ApiError {
                    error: "Bad Gateway".to_string(),
                    message: e.to_string(),
                    code: 502,
                }),
            )
        })?;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "vision": result,
    })))
}

async fn get_presence_status(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let sensory_mgr = state.sensory_pipeline_manager.read().await.clone();
    let status = sensory_mgr.status().await;
    Ok(Json(serde_json::json!(status.presence)))
}

async fn refresh_presence_status(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let ai_mgr = *state.ai_manager.read().await;
    let overlay_mgr = state.overlay_manager.read().await.clone();
    let follow_along = state.follow_along_manager.read().await.clone();
    let memory_plane = state.memory_plane_manager.read().await.clone();
    let sensory_mgr = state.sensory_pipeline_manager.read().await.clone();
    let presence = sensory_mgr
        .update_presence(&ai_mgr, &overlay_mgr, &follow_along, &memory_plane)
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_GATEWAY,
                Json(ApiError {
                    error: "Bad Gateway".to_string(),
                    message: e.to_string(),
                    code: 502,
                }),
            )
        })?;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "presence": presence,
    })))
}

async fn run_sensory_benchmark(
    State(state): State<ApiState>,
    Json(payload): Json<SensoryBenchmarkPayload>,
) -> Result<Json<SensoryBenchmarkReport>, (StatusCode, Json<ApiError>)> {
    let ai_manager = *state.ai_manager.read().await;
    let overlay_mgr = state.overlay_manager.read().await.clone();
    let screen_capture = state.screen_capture.read().await.clone();
    let sensory_mgr = state.sensory_pipeline_manager.read().await.clone();
    let memory_plane = state.memory_plane_manager.read().await.clone();
    let telemetry = state.telemetry_manager.read().await.clone();

    let report = sensory_mgr
        .benchmark(
            &ai_manager,
            &overlay_mgr,
            &screen_capture,
            &memory_plane,
            &telemetry,
            SensoryBenchmarkRequest {
                audio_file: payload.audio_file,
                prompt: payload.prompt,
                include_screen: payload.include_screen.unwrap_or(false),
                screen_source: payload.screen_source,
                repeats: payload.repeats.unwrap_or(3),
            },
        )
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_GATEWAY,
                Json(ApiError {
                    error: "Bad Gateway".to_string(),
                    message: e.to_string(),
                    code: 502,
                }),
            )
        })?;
    Ok(Json(report))
}

/// Get notifications
#[utoipa::path(
    get,
    path = "/api/v1/notifications",
    responses(
        (status = 200, description = "Notifications retrieved successfully", body = Vec<Notification>),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "notifications"
)]
async fn get_notifications(
    State(_state): State<ApiState>,
) -> Result<Json<Vec<Notification>>, (StatusCode, Json<ApiError>)> {
    let notifications = vec![Notification {
        id: "1".to_string(),
        title: "System Update Available".to_string(),
        message: "LifeOS 0.2.0 is ready to install".to_string(),
        notification_type: "update".to_string(),
        priority: "normal".to_string(),
        timestamp: chrono::Local::now().to_rfc3339(),
        read: false,
        action_url: Some("life://update".to_string()),
    }];

    Ok(Json(notifications))
}

/// Create notification
#[utoipa::path(
    post,
    path = "/api/v1/notifications",
    request_body = Notification,
    responses(
        (status = 201, description = "Notification created"),
        (status = 400, description = "Invalid request", body = ApiError),
    ),
    tag = "notifications",
)]
async fn post_notification(
    State(_state): State<ApiState>,
    Json(_notification): Json<Notification>,
) -> StatusCode {
    StatusCode::CREATED
}

// ==================== SHORTCUT HANDLERS ====================

/// List registered shortcuts
#[utoipa::path(
    get,
    path = "/api/v1/shortcuts/list",
    responses(
        (status = 200, description = "Shortcuts list retrieved successfully", body = ShortcutsListResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn list_shortcuts(
    State(_state): State<ApiState>,
) -> Result<Json<ShortcutsListResponse>, (StatusCode, Json<ApiError>)> {
    let shortcut_infos: Vec<ShortcutInfo> = vec![ShortcutInfo {
        name: "toggle_overlay".to_string(),
        keys: "Super+Space".to_string(),
        action: "toggle_overlay".to_string(),
        description: "Toggle LifeOS overlay".to_string(),
    }];

    Ok(Json(ShortcutsListResponse {
        shortcuts: shortcut_infos,
        active: true,
    }))
}

/// Register shortcuts with the system
#[utoipa::path(
    post,
    path = "/api/v1/shortcuts/register",
    responses(
        (status = 200, description = "Shortcuts registered successfully"),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn register_shortcuts(State(_state): State<ApiState>) -> StatusCode {
    StatusCode::OK
}

/// Unregister shortcuts from the system
#[utoipa::path(
    post,
    path = "/api/v1/shortcuts/unregister",
    responses(
        (status = 200, description = "Shortcuts unregistered successfully"),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn unregister_shortcuts(State(_state): State<ApiState>) -> StatusCode {
    StatusCode::OK
}

// ==================== MODE HANDLERS ====================

/// Get current experience mode
#[utoipa::path(
    get,
    path = "/api/v1/mode/current",
    responses(
        (status = 200, description = "Current mode retrieved", body = CurrentModeResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn get_current_mode(
    State(_state): State<ApiState>,
) -> Result<Json<CurrentModeResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = ExperienceManager::new(PathBuf::from("/var/lib/lifeos"));
    let current = mgr.get_current_mode().await;

    if let Some(mode_details) = mgr.get_current_mode_details().await {
        Ok(Json(CurrentModeResponse {
            mode: current.clone(),
            display_name: mode_details.display_name,
            description: mode_details.description,
        }))
    } else {
        Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Mode Error".to_string(),
                message: "Failed to get current mode details".to_string(),
                code: 500,
            }),
        ))
    }
}

/// Set experience mode
#[utoipa::path(
    post,
    path = "/api/v1/mode/set",
    request_body = SetModeRequest,
    responses(
        (status = 200, description = "Mode set successfully", body = crate::experience_modes::ModeApplicationResult),
        (status = 400, description = "Invalid mode", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn set_mode(
    State(_state): State<ApiState>,
    Json(request): Json<SetModeRequest>,
) -> Result<Json<crate::experience_modes::ModeApplicationResult>, (StatusCode, Json<ApiError>)> {
    let mgr = ExperienceManager::new(PathBuf::from("/var/lib/lifeos"));

    match mgr.apply_mode(&request.mode).await {
        Ok(result) => Ok(Json(result)),
        Err(e) => {
            error!("Failed to set mode '{}': {}", request.mode, e);
            Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Mode Error".to_string(),
                    message: format!("Failed to set mode: {}", e),
                    code: 500,
                }),
            ))
        }
    }
}

/// List all experience modes
#[utoipa::path(
    get,
    path = "/api/v1/mode/list",
    responses(
        (status = 200, description = "Modes listed successfully", body = ListModesResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn list_modes(
    State(_state): State<ApiState>,
) -> Result<Json<ListModesResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = ExperienceManager::new(PathBuf::from("/var/lib/lifeos"));
    let modes = mgr.list_modes();

    let mode_infos: Vec<ModeInfo> = modes
        .iter()
        .map(|m| ModeInfo {
            name: m.name.clone(),
            display_name: m.display_name.clone(),
            description: m.description.clone(),
            ui_complexity: format!("{:?}", m.settings.ui_complexity),
        })
        .collect();

    Ok(Json(ListModesResponse { modes: mode_infos }))
}

/// Compare two experience modes
#[utoipa::path(
    post,
    path = "/api/v1/mode/compare",
    request_body = CompareModesRequest,
    responses(
        (status = 200, description = "Modes compared", body = CompareModesResponse),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn compare_modes(
    State(_state): State<ApiState>,
    Json(request): Json<CompareModesRequest>,
) -> Result<Json<CompareModesResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = ExperienceManager::new(PathBuf::from("/var/lib/lifeos"));
    let comparison = mgr.compare_modes(&request.mode1, &request.mode2);

    Ok(Json(CompareModesResponse {
        mode1: comparison.mode1,
        mode1_display: comparison.mode1_display,
        mode2: comparison.mode2,
        mode2_display: comparison.mode2_display,
        differences: comparison.differences,
    }))
}

/// Get features for current mode
#[utoipa::path(
    get,
    path = "/api/v1/mode/features",
    responses(
        (status = 200, description = "Features retrieved", body = ModeFeaturesResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn get_mode_features(
    State(_state): State<ApiState>,
) -> Result<Json<ModeFeaturesResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = ExperienceManager::new(PathBuf::from("/var/lib/lifeos"));
    let features = mgr.get_current_features().await;

    let mode = mgr.get_current_mode().await;

    let feature_infos: Vec<FeatureInfo> = features
        .iter()
        .map(|f| FeatureInfo {
            name: f.name.clone(),
            display_name: f.display_name.clone(),
            description: f.description.clone(),
            enabled: f.enabled,
            category: format!("{:?}", f.category),
        })
        .collect();

    Ok(Json(ModeFeaturesResponse {
        mode,
        features: feature_infos,
    }))
}

/// Test if feature is available
#[utoipa::path(
    post,
    path = "/api/v1/mode/test",
    request_body = TestFeatureRequest,
    responses(
        (status = 200, description = "Feature tested", body = TestFeatureResponse),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn test_feature(
    State(_state): State<ApiState>,
    Json(request): Json<TestFeatureRequest>,
) -> Result<Json<TestFeatureResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = ExperienceManager::new(PathBuf::from("/var/lib/lifeos"));
    let available = mgr.is_feature_enabled(&request.feature).await;
    let mode = mgr.get_current_mode().await;

    Ok(Json(TestFeatureResponse {
        available,
        mode,
        feature: request.feature,
    }))
}

/// Get mode information
#[utoipa::path(
    get,
    path = "/api/v1/mode/info",
    responses(
        (status = 200, description = "Mode info retrieved", body = ModeInfoResponse),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn get_mode_info(
    State(_state): State<ApiState>,
) -> Result<Json<ModeInfoResponse>, (StatusCode, Json<ApiError>)> {
    let mode_param: Option<String> = None;
    let mode = mode_param.as_deref().unwrap_or("current");
    let mgr = ExperienceManager::new(PathBuf::from("/var/lib/lifeos"));

    let (mode_name, display_name, description) = if mode == "current" {
        let current = mgr.get_current_mode().await;
        if let Some(details) = mgr.get_current_mode_details().await {
            (current, details.display_name, details.description)
        } else {
            (current, "Unknown".to_string(), "".to_string())
        }
    } else if let Some(details) = mgr.get_mode(mode) {
        (
            details.name.clone(),
            details.display_name.clone(),
            details.description.clone(),
        )
    } else {
        (mode.to_string(), "Unknown".to_string(), "".to_string())
    };

    // Get features
    let features = if mode == "current" {
        mgr.get_current_features().await
    } else if let Some(mode_details) = mgr.get_mode(mode) {
        mode_details.settings.features.clone()
    } else {
        vec![]
    };

    let feature_infos: Vec<FeatureInfo> = features
        .iter()
        .map(|f| FeatureInfo {
            name: f.name.clone(),
            display_name: f.display_name.clone(),
            description: f.description.clone(),
            enabled: f.enabled,
            category: format!("{:?}", f.category),
        })
        .collect();

    let settings = if mode == "current" {
        mgr.get_current_mode_details()
            .await
            .map(|d| d.settings.clone())
    } else {
        mgr.get_mode(mode).map(|d| d.settings.clone())
    };

    let (ui_complexity, update_channel, ai_enabled, ai_context_size, telemetry_enabled) =
        match settings {
            Some(s) => (
                format!("{:?}", s.ui_complexity),
                match s.updates.channel {
                    crate::experience_modes::UpdateChannel::Stable => "stable".to_string(),
                    crate::experience_modes::UpdateChannel::Candidate => "candidate".to_string(),
                    crate::experience_modes::UpdateChannel::Edge => "edge".to_string(),
                },
                s.ai.enabled,
                s.ai.context_size,
                s.privacy.telemetry_enabled,
            ),
            None => ("Unknown".to_string(), "stable".to_string(), false, 0, false),
        };

    Ok(Json(ModeInfoResponse {
        mode: mode_name,
        display_name,
        description,
        features: feature_infos,
        settings: ModeSettingsInfo {
            ui_complexity,
            update_channel,
            ai_enabled,
            ai_context_size,
            telemetry_enabled,
        },
    }))
}

/// Trigger a shortcut action
#[utoipa::path(
    post,
    path = "/api/v1/shortcuts/trigger",
    request_body = OverlayShortcutTriggerRequest,
    responses(
        (status = 200, description = "Shortcut triggered successfully"),
        (status = 404, description = "Shortcut not found", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn trigger_shortcut(
    State(_state): State<ApiState>,
    Json(_request): Json<OverlayShortcutTriggerRequest>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    Ok(StatusCode::OK)
}

/// Mark notification as read
#[utoipa::path(
    put,
    path = "/api/v1/notifications/{id}/read",
    responses(
        (status = 200, description = "Notification marked as read"),
        (status = 404, description = "Notification not found", body = ApiError),
    ),
    tag = "notifications"
)]
async fn mark_notification_read(
    Path(_id): Path<String>,
    State(_state): State<ApiState>,
) -> StatusCode {
    StatusCode::OK
}

// ==================== OVERLAY MODEL SELECTOR HELPERS ====================

fn default_true() -> bool {
    true
}

fn format_size_bytes(size_bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut size = size_bytes as f64;
    let mut unit = 0usize;
    while size >= 1024.0 && unit < UNITS.len() - 1 {
        size /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{} {}", size as u64, UNITS[unit])
    } else {
        format!("{:.1} {}", size, UNITS[unit])
    }
}

fn parse_signature(sig: &str) -> String {
    sig.lines()
        .find_map(|line| {
            let t = line.trim();
            if t.is_empty() || t.starts_with('#') {
                return None;
            }
            Some(t.strip_prefix("sha256:").unwrap_or(t).trim().to_lowercase())
        })
        .unwrap_or_default()
}

fn digest_bytes(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(bytes);
    format!("{:x}", digest)
}

fn estimate_download_seconds(size_bytes: u64) -> u64 {
    let bits = size_bytes.saturating_mul(8);
    let bits_per_second = DEFAULT_DOWNLOAD_MBIT_PER_SEC.saturating_mul(1_000_000);
    if bits_per_second == 0 {
        return 0;
    }
    bits.div_ceil(bits_per_second)
}

fn bytes_to_gib_ceil(bytes: u64) -> u32 {
    const GIB: u64 = 1024 * 1024 * 1024;
    if bytes == 0 {
        return 0;
    }
    bytes.div_ceil(GIB) as u32
}

fn detect_total_ram_gb() -> u32 {
    if let Ok(content) = std::fs::read_to_string("/proc/meminfo") {
        for line in content.lines() {
            if line.starts_with("MemTotal:") {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if let Some(kb_str) = parts.get(1) {
                    if let Ok(kb) = kb_str.parse::<u64>() {
                        return (kb / 1024 / 1024).max(1) as u32;
                    }
                }
            }
        }
    }
    8
}

fn detect_on_battery() -> Option<bool> {
    let power_supply = std::path::Path::new("/sys/class/power_supply");
    if !power_supply.exists() {
        return None;
    }

    let mut has_battery = false;
    let mut ac_online: Option<bool> = None;
    let entries = std::fs::read_dir(power_supply).ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(kind) = std::fs::read_to_string(path.join("type")) else {
            continue;
        };
        let kind = kind.trim().to_ascii_lowercase();
        if kind == "battery" {
            has_battery = true;
            if let Ok(status) = std::fs::read_to_string(path.join("status")) {
                let status = status.trim().to_ascii_lowercase();
                if status == "discharging" {
                    return Some(true);
                }
                if status == "charging" || status == "full" {
                    return Some(false);
                }
            }
        }
        if kind == "mains" || kind == "ac" {
            if let Ok(online) = std::fs::read_to_string(path.join("online")) {
                ac_online = Some(online.trim() == "1");
            }
        }
    }

    if has_battery {
        ac_online.map(|online| !online)
    } else {
        None
    }
}

async fn detect_overlay_hardware() -> OverlayHardwareSnapshot {
    let mut snapshot = OverlayHardwareSnapshot {
        total_ram_gb: detect_total_ram_gb(),
        on_battery: detect_on_battery(),
        ..OverlayHardwareSnapshot::default()
    };

    if let Ok(output) = Command::new("nvidia-smi")
        .args([
            "--query-gpu=name,memory.total,temperature.gpu,utilization.gpu",
            "--format=csv,noheader,nounits",
        ])
        .output()
        .await
    {
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            if let Some(line) = stdout.lines().next() {
                let parts: Vec<&str> = line.split(',').map(|part| part.trim()).collect();
                if parts.len() >= 4 {
                    snapshot.gpu_name = Some(parts[0].to_string());
                    snapshot.total_vram_gb = parts[1].parse::<u32>().ok().map(|mb| mb / 1024);
                    snapshot.gpu_temp_celsius = parts[2].parse::<f32>().ok();
                    snapshot.gpu_utilization_percent = parts[3].parse::<u32>().ok();
                    snapshot.thermal_pressure = snapshot
                        .gpu_temp_celsius
                        .map(|temp| temp >= 82.0)
                        .unwrap_or(false)
                        || snapshot
                            .gpu_utilization_percent
                            .map(|util| util >= 92)
                            .unwrap_or(false);
                }
            }
        }
    }

    snapshot
}

fn derive_expected_ram_gb(size_bytes: u64, recommended_ram_gb: Option<u32>) -> u32 {
    recommended_ram_gb.unwrap_or_else(|| bytes_to_gib_ceil(size_bytes).saturating_mul(2).max(6))
}

fn derive_expected_vram_gb(size_bytes: u64, recommended_vram_gb: Option<u32>) -> u32 {
    recommended_vram_gb.unwrap_or_else(|| bytes_to_gib_ceil(size_bytes).saturating_add(1).max(2))
}

fn battery_impact_label(
    size_bytes: u64,
    fit_tier: &str,
    on_battery: Option<bool>,
    thermal_pressure: bool,
) -> String {
    let mut score = 0u8;
    if fit_tier == "full_gpu" {
        score = score.saturating_add(2);
    } else if fit_tier == "partial_gpu" {
        score = score.saturating_add(1);
    }
    if size_bytes >= 10 * 1024 * 1024 * 1024 {
        score = score.saturating_add(2);
    } else if size_bytes >= 4 * 1024 * 1024 * 1024 {
        score = score.saturating_add(1);
    }
    if on_battery == Some(true) {
        score = score.saturating_add(1);
    }
    if thermal_pressure {
        score = score.saturating_add(1);
    }
    match score {
        0..=1 => "low".to_string(),
        2..=3 => "medium".to_string(),
        _ => "high".to_string(),
    }
}

fn assess_overlay_model_fit(
    size_bytes: u64,
    recommended_ram_gb: Option<u32>,
    recommended_vram_gb: Option<u32>,
    hardware: &OverlayHardwareSnapshot,
) -> OverlayModelFitAssessment {
    let expected_ram_gb = derive_expected_ram_gb(size_bytes, recommended_ram_gb);
    let expected_vram_gb = derive_expected_vram_gb(size_bytes, recommended_vram_gb);
    let has_nvidia = hardware.total_vram_gb.is_some();
    let ram_ok = hardware.total_ram_gb >= expected_ram_gb;

    let (mut fit_tier, mut expected_gpu_layers) = if let Some(vram_gb) = hardware.total_vram_gb {
        let partial_vram = expected_vram_gb.saturating_div(2).max(4);
        if ram_ok && vram_gb >= expected_vram_gb {
            ("full_gpu".to_string(), -1)
        } else if vram_gb >= partial_vram && hardware.total_ram_gb >= expected_ram_gb.max(8) / 2 {
            ("partial_gpu".to_string(), 20)
        } else {
            ("cpu_only".to_string(), 0)
        }
    } else {
        ("cpu_only".to_string(), 0)
    };

    if hardware.thermal_pressure {
        if fit_tier == "full_gpu" {
            fit_tier = "partial_gpu".to_string();
            expected_gpu_layers = 20;
        } else if fit_tier == "partial_gpu" {
            fit_tier = "cpu_only".to_string();
            expected_gpu_layers = 0;
        }
    }

    OverlayModelFitAssessment {
        expected_battery_impact: battery_impact_label(
            size_bytes,
            &fit_tier,
            hardware.on_battery,
            hardware.thermal_pressure,
        ),
        fit_tier,
        expected_gpu_layers: if has_nvidia { expected_gpu_layers } else { 0 },
        expected_ram_gb: Some(expected_ram_gb),
        expected_vram_gb: if has_nvidia {
            Some(expected_vram_gb)
        } else {
            None
        },
    }
}

fn read_filesystem_usage(path: &str) -> anyhow::Result<(u64, u64, u64, f32)> {
    let output = std::process::Command::new("df")
        .args(["-Pk", path])
        .output()?;
    if !output.status.success() {
        anyhow::bail!("df command failed for {}", path);
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout
        .lines()
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("Unable to parse df output for {}", path))?;
    let cols: Vec<&str> = line.split_whitespace().collect();
    if cols.len() < 6 {
        anyhow::bail!("Unexpected df output for {}", path);
    }

    let total_kb: u64 = cols[1].parse()?;
    let used_kb: u64 = cols[2].parse()?;
    let free_kb: u64 = cols[3].parse()?;
    let used_percent = if total_kb == 0 {
        0.0
    } else {
        (used_kb as f32 / total_kb as f32) * 100.0
    };

    Ok((
        total_kb.saturating_mul(1024),
        used_kb.saturating_mul(1024),
        free_kb.saturating_mul(1024),
        used_percent,
    ))
}

fn build_storage_summary(
    installed: &BTreeMap<String, u64>,
    pinned: &BTreeSet<String>,
    selected_model: Option<&str>,
) -> OverlayModelStorageSummary {
    let df_target = if std::path::Path::new(MODEL_DIR).exists() {
        MODEL_DIR
    } else {
        "/var"
    };
    let (
        filesystem_total_bytes,
        filesystem_used_bytes,
        filesystem_free_bytes,
        filesystem_used_percent,
    ) = read_filesystem_usage(df_target).unwrap_or((0, 0, 0, 0.0));
    let installed_model_bytes = installed.values().copied().sum::<u64>();
    let reclaimable_model_bytes = installed
        .iter()
        .filter(|(model, _)| !pinned.contains(*model) && selected_model != Some(model.as_str()))
        .map(|(_, size)| *size)
        .sum::<u64>();

    OverlayModelStorageSummary {
        model_dir: MODEL_DIR.to_string(),
        filesystem_total_bytes,
        filesystem_used_bytes,
        filesystem_free_bytes,
        filesystem_used_percent,
        installed_model_bytes,
        reclaimable_model_bytes,
    }
}

fn featured_overlay_roster(catalog_models: &[OverlayCatalogModel]) -> Vec<String> {
    let mut roster = Vec::new();
    for family in [
        "Qwen3.5-4B-Q4_K_M.gguf",
        "Qwen3.5-9B-Q4_K_M.gguf",
        "Qwen3.5-27B-Q4_K_M.gguf",
    ] {
        if let Some(model) = catalog_models
            .iter()
            .find(|entry| entry.id.eq_ignore_ascii_case(family))
        {
            roster.push(model.id.clone());
        }
    }
    roster
}

fn select_model_size_and_requirements(
    model_name: &str,
    catalog_models: &[OverlayCatalogModel],
) -> (u64, Option<u32>, Option<u32>) {
    if let Some(model) = resolve_catalog_model(model_name, catalog_models) {
        return (
            model.size_bytes,
            model.recommended_ram_gb,
            model.recommended_vram_gb,
        );
    }
    let path = std::path::Path::new(MODEL_DIR).join(model_name);
    let size_bytes = std::fs::metadata(path).map(|meta| meta.len()).unwrap_or(0);
    (size_bytes, None, None)
}

async fn recalculate_gpu_layers_for_model(
    model_name: &str,
    catalog_models: &[OverlayCatalogModel],
    persist: bool,
) -> anyhow::Result<OverlayModelFitAssessment> {
    let hardware = detect_overlay_hardware().await;
    let (size_bytes, recommended_ram_gb, recommended_vram_gb) =
        select_model_size_and_requirements(model_name, catalog_models);
    let assessment = assess_overlay_model_fit(
        size_bytes,
        recommended_ram_gb,
        recommended_vram_gb,
        &hardware,
    );
    if persist {
        upsert_env_var(
            "LIFEOS_AI_GPU_LAYERS",
            &assessment.expected_gpu_layers.to_string(),
        )?;
    }
    Ok(assessment)
}

fn ensure_model_storage_capacity(required_disk_bytes: u64) -> anyhow::Result<()> {
    let df_target = if std::path::Path::new(MODEL_DIR).exists() {
        MODEL_DIR
    } else {
        "/var"
    };
    let (_total, _used, free, _used_percent) = read_filesystem_usage(df_target)?;
    let safety_margin = 256 * 1024 * 1024;
    let required_with_margin = required_disk_bytes.saturating_add(safety_margin);
    if free < required_with_margin {
        anyhow::bail!(
            "Insufficient disk space in {}: required {} (including safety margin), available {}",
            MODEL_DIR,
            format_size_bytes(required_with_margin),
            format_size_bytes(free),
        );
    }
    Ok(())
}

fn expected_companion_for_model(
    model_name: &str,
    catalog_models: &[OverlayCatalogModel],
) -> Option<String> {
    resolve_catalog_model(model_name, catalog_models)
        .and_then(|entry| entry.companion_mmproj.map(|artifact| artifact.filename))
        .or_else(|| qwen_companion_mmproj_filename(model_name))
}

fn embedded_catalog_signature_valid() -> bool {
    let expected = parse_signature(EMBEDDED_MODEL_CATALOG_SIG);
    if expected.is_empty() {
        return false;
    }
    digest_bytes(EMBEDDED_MODEL_CATALOG_JSON.as_bytes()) == expected
}

fn fallback_overlay_catalog_models() -> Vec<OverlayCatalogModel> {
    vec![
        OverlayCatalogModel {
            id: "Qwen3.5-4B-Q4_K_M.gguf".to_string(),
            download_url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf".to_string(),
            size_bytes: 2_740_937_888,
            checksum_sha256: Some(
                "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4".to_string(),
            ),
            recommended_ram_gb: Some(16),
            recommended_vram_gb: Some(8),
            offload_policy: Some("prefer_full_gpu".to_string()),
            companion_mmproj: Some(OverlayCatalogCompanionArtifact {
                filename: "Qwen3.5-4B-mmproj-F16.gguf".to_string(),
                download_url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/mmproj-F16.gguf".to_string(),
                size_bytes: Some(672_423_616),
                checksum_sha256: Some(
                    "cd88edcf8d031894960bb0c9c5b9b7e1fea6ebee02b9f7ce925a00d12891f864".to_string(),
                ),
            }),
            runtime_profiles: vec![
                "lite".to_string(),
                "edge".to_string(),
                "secure".to_string(),
                "pro".to_string(),
            ],
            roles: vec![
                "general".to_string(),
                "reasoning".to_string(),
                "vision".to_string(),
            ],
        },
        OverlayCatalogModel {
            id: "Qwen3.5-9B-Q4_K_M.gguf".to_string(),
            download_url: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf".to_string(),
            size_bytes: 5_680_522_464,
            checksum_sha256: Some(
                "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8".to_string(),
            ),
            recommended_ram_gb: Some(24),
            recommended_vram_gb: Some(12),
            offload_policy: Some("prefer_full_gpu".to_string()),
            companion_mmproj: Some(OverlayCatalogCompanionArtifact {
                filename: "Qwen3.5-9B-mmproj-F16.gguf".to_string(),
                download_url: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/mmproj-F16.gguf".to_string(),
                size_bytes: Some(918_166_080),
                checksum_sha256: Some(
                    "f70dc3509053962b0d0d3ee8a7eacebf5d60aa560cad78254ae8698516ae029f".to_string(),
                ),
            }),
            runtime_profiles: vec!["edge".to_string(), "pro".to_string()],
            roles: vec![
                "general".to_string(),
                "reasoning".to_string(),
                "vision".to_string(),
            ],
        },
        OverlayCatalogModel {
            id: "Qwen3.5-27B-Q4_K_M.gguf".to_string(),
            download_url: "https://huggingface.co/unsloth/Qwen3.5-27B-GGUF/resolve/main/Qwen3.5-27B-Q4_K_M.gguf".to_string(),
            size_bytes: 16_740_812_704,
            checksum_sha256: Some(
                "84b5f7f112156d63836a01a69dc3f11a6ba63b10a23b8ca7a7efaf52d5a2d806".to_string(),
            ),
            recommended_ram_gb: Some(48),
            recommended_vram_gb: Some(24),
            offload_policy: Some("partial_gpu_or_cpu_fallback".to_string()),
            companion_mmproj: Some(OverlayCatalogCompanionArtifact {
                filename: "Qwen3.5-27B-mmproj-F16.gguf".to_string(),
                download_url: "https://huggingface.co/unsloth/Qwen3.5-27B-GGUF/resolve/main/mmproj-F16.gguf".to_string(),
                size_bytes: Some(927_607_040),
                checksum_sha256: Some(
                    "458bc46d8f275866fde5d88c9c554d9d462a6e8e3a028090d9850e17ab6a1217".to_string(),
                ),
            }),
            runtime_profiles: vec!["pro".to_string(), "workstation".to_string()],
            roles: vec![
                "general".to_string(),
                "reasoning".to_string(),
                "vision".to_string(),
            ],
        },
    ]
}

fn load_overlay_catalog() -> (String, bool, Vec<OverlayCatalogModel>) {
    match serde_json::from_str::<OverlayCatalog>(EMBEDDED_MODEL_CATALOG_JSON) {
        Ok(catalog) => (
            catalog.catalog_version,
            embedded_catalog_signature_valid(),
            catalog.models,
        ),
        Err(_) => (
            "fallback-local".to_string(),
            false,
            fallback_overlay_catalog_models(),
        ),
    }
}

fn is_selectable_model_asset(model: &str) -> bool {
    let lower = model.to_ascii_lowercase();
    lower.ends_with(".gguf")
        && !lower.starts_with("mmproj-")
        && !lower.contains("-mmproj-")
        && !lower.starts_with("nomic-embed-")
        && !lower.starts_with("whisper")
        && !lower.contains("embedding")
}

fn qwen_companion_mmproj_filename(model: &str) -> Option<String> {
    let lower = model.to_ascii_lowercase();
    if lower.contains("qwen3.5-4b") {
        return Some("Qwen3.5-4B-mmproj-F16.gguf".to_string());
    }
    if lower.contains("qwen3.5-9b") {
        return Some("Qwen3.5-9B-mmproj-F16.gguf".to_string());
    }
    if lower.contains("qwen3.5-27b") {
        return Some("Qwen3.5-27B-mmproj-F16.gguf".to_string());
    }
    if lower.contains("qwen3.5-0.8b") || lower.contains("qwen3.5-2b") {
        return Some("mmproj-F16.gguf".to_string());
    }
    None
}

fn qwen_repo_for_model(model: &str) -> Option<&'static str> {
    let lower = model.to_ascii_lowercase();
    if lower.contains("qwen3.5-4b") {
        Some("Qwen3.5-4B-GGUF")
    } else if lower.contains("qwen3.5-9b") {
        Some("Qwen3.5-9B-GGUF")
    } else if lower.contains("qwen3.5-27b") {
        Some("Qwen3.5-27B-GGUF")
    } else if lower.contains("qwen3.5-0.8b") {
        Some("Qwen3.5-0.8B-GGUF")
    } else if lower.contains("qwen3.5-2b") {
        Some("Qwen3.5-2B-GGUF")
    } else {
        None
    }
}

fn parse_env_var(content: &str, key: &str) -> Option<String> {
    let prefix = format!("{key}=");
    content.lines().find_map(|line| {
        line.strip_prefix(&prefix)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
    })
}

fn configured_model() -> Option<String> {
    let content = std::fs::read_to_string(LLAMA_ENV_FILE).ok()?;
    parse_env_var(&content, "LIFEOS_AI_MODEL")
}

fn configured_mmproj() -> Option<String> {
    let content = std::fs::read_to_string(LLAMA_ENV_FILE).ok()?;
    parse_env_var(&content, "LIFEOS_AI_MMPROJ")
}

fn read_env_lines() -> Vec<String> {
    std::fs::read_to_string(LLAMA_ENV_FILE)
        .ok()
        .map(|content| content.lines().map(ToOwned::to_owned).collect())
        .unwrap_or_default()
}

fn upsert_env_var(key: &str, value: &str) -> anyhow::Result<()> {
    let mut lines = read_env_lines();
    let mut found = false;
    for line in &mut lines {
        if line.starts_with(&format!("{key}=")) {
            *line = format!("{key}={value}");
            found = true;
        }
    }
    if !found {
        lines.push(format!("{key}={value}"));
    }
    if let Some(parent) = std::path::Path::new(LLAMA_ENV_FILE).parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(LLAMA_ENV_FILE, format!("{}\n", lines.join("\n")))?;
    Ok(())
}

fn clear_env_var(key: &str) -> anyhow::Result<()> {
    let mut lines = read_env_lines();
    lines.retain(|line| !line.starts_with(&format!("{key}=")));
    if let Some(parent) = std::path::Path::new(LLAMA_ENV_FILE).parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(LLAMA_ENV_FILE, format!("{}\n", lines.join("\n")))?;
    Ok(())
}

fn clear_overlay_model_selection() -> anyhow::Result<()> {
    clear_env_var("LIFEOS_AI_MODEL")?;
    clear_env_var("LIFEOS_AI_MMPROJ")?;
    set_selected_model_in_lifecycle(None)?;
    Ok(())
}

fn read_legacy_model_set(path: &str) -> BTreeSet<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|content| {
            content
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .map(ToOwned::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

fn write_legacy_model_set(path: &str, models: &BTreeSet<String>) -> anyhow::Result<()> {
    if let Some(parent) = std::path::Path::new(path).parent() {
        std::fs::create_dir_all(parent)?;
    }
    let serialized = if models.is_empty() {
        String::new()
    } else {
        format!(
            "{}\n",
            models.iter().cloned().collect::<Vec<_>>().join("\n")
        )
    };
    std::fs::write(path, serialized)?;
    Ok(())
}

fn model_lifecycle_marker() -> String {
    chrono::Utc::now().to_rfc3339()
}

fn local_device_id() -> String {
    std::fs::read_to_string("/etc/machine-id")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .or_else(|| std::env::var("HOSTNAME").ok())
        .unwrap_or_else(|| "unknown-device".to_string())
}

fn entry_has_state(entry: &OverlayModelLifecycleEntry) -> bool {
    entry.installed || entry.selected || entry.pinned || entry.removed_by_user
}

fn cleanup_model_lifecycle_state(state: &mut OverlayModelLifecycleState) {
    state.models.retain(|_, entry| entry_has_state(entry));
}

fn load_model_lifecycle_state() -> OverlayModelLifecycleState {
    let mut state = std::fs::read_to_string(MODEL_LIFECYCLE_STATE_FILE)
        .ok()
        .and_then(|raw| serde_json::from_str::<OverlayModelLifecycleState>(&raw).ok())
        .unwrap_or_default();
    if state.version == 0 {
        state.version = 1;
    }

    // Migrate/merge legacy text tombstones for compatibility with older builds.
    let removed_legacy = read_legacy_model_set(REMOVED_MODELS_FILE);
    for model in removed_legacy {
        let entry = state.models.entry(model).or_default();
        if !entry.removed_by_user {
            entry.removed_by_user = true;
            entry.updated_at = Some(model_lifecycle_marker());
        }
    }

    let pinned_legacy = read_legacy_model_set(PINNED_MODELS_FILE);
    for model in pinned_legacy {
        let entry = state.models.entry(model).or_default();
        if !entry.pinned {
            entry.pinned = true;
            entry.updated_at = Some(model_lifecycle_marker());
        }
    }

    cleanup_model_lifecycle_state(&mut state);
    state
}

fn write_model_lifecycle_state(state: &OverlayModelLifecycleState) -> anyhow::Result<()> {
    if let Some(parent) = std::path::Path::new(MODEL_LIFECYCLE_STATE_FILE).parent() {
        std::fs::create_dir_all(parent)?;
    }

    let mut normalized = state.clone();
    normalized.version = 1;
    cleanup_model_lifecycle_state(&mut normalized);

    let serialized = serde_json::to_string_pretty(&normalized)?;
    std::fs::write(MODEL_LIFECYCLE_STATE_FILE, serialized)?;

    // Keep legacy marker files in sync for compatibility with setup/runtime scripts.
    let removed: BTreeSet<String> = normalized
        .models
        .iter()
        .filter_map(|(model, entry)| entry.removed_by_user.then_some(model.clone()))
        .collect();
    let pinned: BTreeSet<String> = normalized
        .models
        .iter()
        .filter_map(|(model, entry)| entry.pinned.then_some(model.clone()))
        .collect();
    write_legacy_model_set(REMOVED_MODELS_FILE, &removed)?;
    write_legacy_model_set(PINNED_MODELS_FILE, &pinned)?;

    Ok(())
}

fn sync_model_lifecycle_state_with_runtime(
    installed_models: &BTreeMap<String, u64>,
    selected_model: Option<&str>,
) -> anyhow::Result<OverlayModelLifecycleState> {
    let mut state = load_model_lifecycle_state();
    let mut changed = false;

    for entry in state.models.values_mut() {
        if entry.installed {
            entry.installed = false;
            entry.updated_at = Some(model_lifecycle_marker());
            changed = true;
        }
        if entry.selected {
            entry.selected = false;
            entry.updated_at = Some(model_lifecycle_marker());
            changed = true;
        }
    }

    for model in installed_models.keys() {
        let entry = state.models.entry(model.clone()).or_default();
        if !entry.installed {
            entry.installed = true;
            entry.updated_at = Some(model_lifecycle_marker());
            changed = true;
        }
    }

    if let Some(selected) = selected_model {
        let entry = state.models.entry(selected.to_string()).or_default();
        if !entry.selected {
            entry.selected = true;
            entry.updated_at = Some(model_lifecycle_marker());
            changed = true;
        }
        if entry.removed_by_user {
            entry.removed_by_user = false;
            entry.updated_at = Some(model_lifecycle_marker());
            changed = true;
        }
    }

    if changed {
        write_model_lifecycle_state(&state)?;
    }
    Ok(state)
}

fn mark_model_removed(model_name: &str) -> anyhow::Result<()> {
    let mut state = load_model_lifecycle_state();
    let entry = state.models.entry(model_name.to_string()).or_default();
    entry.removed_by_user = true;
    entry.selected = false;
    entry.pinned = false;
    entry.installed = false;
    entry.updated_at = Some(model_lifecycle_marker());
    write_model_lifecycle_state(&state)
}

fn clear_removed_model(model_name: &str) -> anyhow::Result<()> {
    let mut state = load_model_lifecycle_state();
    if let Some(entry) = state.models.get_mut(model_name) {
        entry.removed_by_user = false;
        entry.updated_at = Some(model_lifecycle_marker());
    }
    write_model_lifecycle_state(&state)
}

fn mark_model_pinned(model_name: &str) -> anyhow::Result<()> {
    let mut state = load_model_lifecycle_state();
    let entry = state.models.entry(model_name.to_string()).or_default();
    entry.pinned = true;
    entry.updated_at = Some(model_lifecycle_marker());
    write_model_lifecycle_state(&state)
}

fn clear_model_pinned(model_name: &str) -> anyhow::Result<()> {
    let mut state = load_model_lifecycle_state();
    if let Some(entry) = state.models.get_mut(model_name) {
        entry.pinned = false;
        entry.updated_at = Some(model_lifecycle_marker());
    }
    write_model_lifecycle_state(&state)
}

fn set_selected_model_in_lifecycle(model_name: Option<&str>) -> anyhow::Result<()> {
    let mut state = load_model_lifecycle_state();
    for entry in state.models.values_mut() {
        entry.selected = false;
    }

    if let Some(model) = model_name {
        let entry = state.models.entry(model.to_string()).or_default();
        entry.selected = true;
        entry.removed_by_user = false;
        entry.updated_at = Some(model_lifecycle_marker());
    }

    write_model_lifecycle_state(&state)
}

fn set_model_installed_in_lifecycle(model_name: &str, installed: bool) -> anyhow::Result<()> {
    let mut state = load_model_lifecycle_state();
    let entry = state.models.entry(model_name.to_string()).or_default();
    entry.installed = installed;
    if installed {
        entry.removed_by_user = false;
    }
    entry.updated_at = Some(model_lifecycle_marker());
    write_model_lifecycle_state(&state)
}

fn installed_models_map() -> anyhow::Result<BTreeMap<String, u64>> {
    let mut models = BTreeMap::new();
    let model_dir = std::path::Path::new(MODEL_DIR);
    if !model_dir.exists() {
        return Ok(models);
    }
    for entry in std::fs::read_dir(model_dir)? {
        let entry = entry?;
        let path = entry.path();
        let file_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default()
            .to_string();
        if !path.is_file() || path.extension().and_then(|ext| ext.to_str()) != Some("gguf") {
            continue;
        }
        if !is_selectable_model_asset(&file_name) {
            continue;
        }
        let size_bytes = entry.metadata()?.len();
        models.insert(file_name, size_bytes);
    }
    Ok(models)
}

fn resolve_catalog_model_alias(model: &str) -> Option<&'static str> {
    match model.trim().to_ascii_lowercase().as_str() {
        "qwen3.5" | "qwen3.5:4b" | "qwen3.5-4b" => Some("Qwen3.5-4B-Q4_K_M.gguf"),
        "qwen3.5:9b" | "qwen3.5-9b" => Some("Qwen3.5-9B-Q4_K_M.gguf"),
        "qwen3.5:27b" | "qwen3.5-27b" => Some("Qwen3.5-27B-Q4_K_M.gguf"),
        _ => None,
    }
}

fn resolve_catalog_model(
    requested: &str,
    models: &[OverlayCatalogModel],
) -> Option<OverlayCatalogModel> {
    let canonical = resolve_catalog_model_alias(requested).unwrap_or(requested);
    models
        .iter()
        .find(|model| model.id.eq_ignore_ascii_case(canonical))
        .cloned()
}

async fn restart_llama_server() -> anyhow::Result<()> {
    let status = Command::new("systemctl")
        .args(["restart", "llama-server"])
        .status()
        .await?;
    if !status.success() {
        anyhow::bail!("systemctl restart llama-server failed");
    }
    Ok(())
}

fn sha256_file(path: &std::path::Path) -> anyhow::Result<String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;

    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 1024 * 1024];
    loop {
        let bytes_read = file.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        hasher.update(&buffer[..bytes_read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn verify_artifact(
    path: &std::path::Path,
    expected_size: Option<u64>,
    expected_sha256: Option<&str>,
) -> anyhow::Result<()> {
    if let Some(size) = expected_size {
        let actual = std::fs::metadata(path)?.len();
        if actual != size {
            anyhow::bail!(
                "Size mismatch for {} (expected {}, got {})",
                path.display(),
                size,
                actual
            );
        }
    }

    if let Some(expected) = expected_sha256 {
        let actual = sha256_file(path)?;
        if !actual.eq_ignore_ascii_case(expected) {
            anyhow::bail!(
                "Checksum mismatch for {} (expected {}, got {})",
                path.display(),
                expected,
                actual
            );
        }
    }

    Ok(())
}

fn apply_overlay_model_selection(
    model_name: &str,
    catalog_models: &[OverlayCatalogModel],
) -> anyhow::Result<Option<String>> {
    let model_path = std::path::Path::new(MODEL_DIR).join(model_name);
    if !model_path.exists() {
        anyhow::bail!("Model {} not found in {}", model_name, MODEL_DIR);
    }

    upsert_env_var("LIFEOS_AI_MODEL", model_name)?;
    let companion_mmproj = resolve_catalog_model(model_name, catalog_models)
        .and_then(|entry| entry.companion_mmproj.map(|artifact| artifact.filename))
        .or_else(|| qwen_companion_mmproj_filename(model_name));
    if let Some(mmproj) = &companion_mmproj {
        let companion_path = std::path::Path::new(MODEL_DIR).join(mmproj);
        if companion_path.exists() {
            upsert_env_var("LIFEOS_AI_MMPROJ", mmproj)?;
        } else {
            anyhow::bail!(
                "Companion mmproj {} is required for {} but was not found",
                mmproj,
                model_name
            );
        }
    } else {
        clear_env_var("LIFEOS_AI_MMPROJ")?;
    }
    clear_removed_model(model_name)?;
    set_model_installed_in_lifecycle(model_name, true)?;
    set_selected_model_in_lifecycle(Some(model_name))?;
    Ok(companion_mmproj)
}

fn pick_fallback_model(exclude: &str) -> anyhow::Result<Option<String>> {
    let fallback = installed_models_map()?
        .into_keys()
        .find(|candidate| !candidate.eq_ignore_ascii_case(exclude));
    Ok(fallback)
}

fn is_featured_overlay_model(model_name: &str) -> bool {
    matches!(
        model_name.to_ascii_lowercase().as_str(),
        "qwen3.5-4b-q4_k_m.gguf" | "qwen3.5-9b-q4_k_m.gguf" | "qwen3.5-27b-q4_k_m.gguf"
    )
}

async fn download_model_with_curl(
    url: &str,
    dest_path: &std::path::Path,
    expected_size: Option<u64>,
    expected_sha256: Option<&str>,
    force: bool,
) -> anyhow::Result<()> {
    let tmp_path = dest_path.with_extension("part");
    if force {
        let _ = tokio::fs::remove_file(dest_path).await;
        let _ = tokio::fs::remove_file(&tmp_path).await;
    }

    if !force && dest_path.exists() {
        if verify_artifact(dest_path, expected_size, expected_sha256).is_ok() {
            return Ok(());
        }
        let _ = tokio::fs::remove_file(dest_path).await;
    }
    if let Some(parent) = dest_path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }

    let status = Command::new("curl")
        .args([
            "-fL",
            "--retry",
            "4",
            "--retry-delay",
            "2",
            "--retry-connrefused",
            "--continue-at",
            "-",
            "--progress-bar",
            "-o",
        ])
        .arg(&tmp_path)
        .arg(url)
        .status()
        .await?;
    if !status.success() {
        anyhow::bail!("Failed to download {}", url);
    }

    verify_artifact(&tmp_path, expected_size, expected_sha256)?;
    tokio::fs::rename(&tmp_path, dest_path).await?;
    Ok(())
}

// ==================== OVERLAY HANDLERS ====================

/// Show overlay window
#[utoipa::path(
    post,
    path = "/api/v1/overlay/show",
    responses(
        (status = 200, description = "Overlay shown successfully"),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn show_overlay(State(state): State<ApiState>) -> StatusCode {
    let overlay_mgr = state.overlay_manager.read().await.clone();
    match overlay_mgr.show().await {
        Ok(_) => StatusCode::OK,
        Err(e) => {
            error!("Failed to show overlay: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

/// Hide overlay window
#[utoipa::path(
    post,
    path = "/api/v1/overlay/hide",
    responses(
        (status = 200, description = "Overlay hidden successfully"),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn hide_overlay(State(state): State<ApiState>) -> StatusCode {
    let overlay_mgr = state.overlay_manager.read().await.clone();
    match overlay_mgr.hide().await {
        Ok(_) => StatusCode::OK,
        Err(e) => {
            error!("Failed to hide overlay: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

/// Toggle overlay visibility
#[utoipa::path(
    post,
    path = "/api/v1/overlay/toggle",
    responses(
        (status = 200, description = "Overlay toggled successfully"),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn toggle_overlay(State(state): State<ApiState>) -> StatusCode {
    let overlay_mgr = state.overlay_manager.read().await.clone();
    match overlay_mgr.toggle().await {
        Ok(_) => StatusCode::OK,
        Err(e) => {
            error!("Failed to toggle overlay: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

/// Send message to overlay chat
#[utoipa::path(
    post,
    path = "/api/v1/overlay/chat",
    request_body = OverlayChatRequest,
    responses(
        (status = 200, description = "Message sent successfully", body = OverlayChatResponse),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_chat(
    State(state): State<ApiState>,
    Json(request): Json<OverlayChatRequest>,
) -> Result<Json<OverlayChatResponse>, (StatusCode, Json<ApiError>)> {
    let overlay_mgr = state.overlay_manager.read().await.clone();
    let start = std::time::Instant::now();

    let response = match overlay_mgr
        .send_message(request.message, request.include_screen)
        .await
    {
        Ok(response) => response,
        Err(e) => {
            error!("Failed to send chat message: {}", e);
            return Err((
                StatusCode::BAD_GATEWAY,
                Json(ApiError {
                    error: "AI Service Error".to_string(),
                    message: format!("llama-server request failed: {}", e),
                    code: 502,
                }),
            ));
        }
    };

    Ok(Json(OverlayChatResponse {
        response: response.response,
        model: response.model,
        tokens_used: response.tokens_used,
        duration_ms: start.elapsed().as_millis() as u64,
    }))
}

/// Capture screen for overlay
#[utoipa::path(
    post,
    path = "/api/v1/overlay/screenshot",
    responses(
        (status = 200, description = "Screenshot captured successfully", body = OverlayScreenshotResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_screenshot(
    State(state): State<ApiState>,
) -> Result<Json<OverlayScreenshotResponse>, (StatusCode, Json<ApiError>)> {
    let overlay_mgr = state.overlay_manager.read().await.clone();
    let screenshot_path = match overlay_mgr.include_screen_context().await {
        Ok(path) => path,
        Err(e) => {
            error!("Failed to capture screenshot: {}", e);
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Screenshot Error".to_string(),
                    message: format!("Failed to capture screen: {}", e),
                    code: 500,
                }),
            ));
        }
    };

    let filename = screenshot_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("screenshot.png")
        .to_string();

    // Get file metadata
    let metadata = tokio::fs::metadata(&screenshot_path).await.map_err(|e| {
        error!("Failed to get screenshot metadata: {}", e);
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Metadata Error".to_string(),
                message: format!("Failed to get metadata: {}", e),
                code: 500,
            }),
        )
    })?;

    Ok(Json(OverlayScreenshotResponse {
        path: screenshot_path.to_string_lossy().to_string(),
        filename,
        width: 1920,
        height: 1080,
        size_bytes: metadata.len(),
    }))
}

/// Clear overlay chat history
#[utoipa::path(
    post,
    path = "/api/v1/overlay/clear",
    responses(
        (status = 200, description = "Chat cleared successfully"),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn clear_overlay(State(state): State<ApiState>) -> StatusCode {
    let overlay_mgr = state.overlay_manager.read().await.clone();
    match overlay_mgr.clear_chat().await {
        Ok(_) => StatusCode::OK,
        Err(e) => {
            error!("Failed to clear chat: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

/// Get overlay status
#[utoipa::path(
    get,
    path = "/api/v1/overlay/status",
    responses(
        (status = 200, description = "Overlay status retrieved successfully", body = OverlayStatusResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_status(
    State(state): State<ApiState>,
) -> Result<Json<OverlayStatusResponse>, (StatusCode, Json<ApiError>)> {
    let overlay_mgr = state.overlay_manager.read().await.clone();
    let stats = overlay_mgr.get_stats().await;
    let state = overlay_mgr.get_state().await;

    // Convert chat messages to ChatMessageInfo
    let total_messages = state.chat_history.len();
    let chat_history: Vec<ChatMessageInfo> = state
        .chat_history
        .iter()
        .map(|msg| ChatMessageInfo {
            id: msg.id.clone(),
            role: match &msg.role {
                crate::overlay::ChatRole::User => "user".to_string(),
                crate::overlay::ChatRole::Assistant => "assistant".to_string(),
                crate::overlay::ChatRole::System => "system".to_string(),
            },
            content: msg.content.clone(),
            timestamp: msg.timestamp.clone(),
            has_screen_context: msg.has_screen_context,
        })
        .collect();

    Ok(Json(OverlayStatusResponse {
        visible: state.visible,
        focused: state.focused,
        stats: OverlayStats {
            total_messages,
            visible: stats.visible,
            focused: stats.focused,
            theme: format!("{:?}", stats.theme),
            shortcut: stats.shortcut,
            enabled: stats.enabled,
            axi_state: format!("{:?}", stats.axi_state),
            widget_visible: stats.widget_visible,
            widget_badge: stats.widget_badge.clone(),
            widget_aura: stats.widget_aura,
            active_notifications: stats.active_notifications,
        },
        chat_history,
        axi_state: format!("{:?}", state.axi_state),
        mic_active: state.sensor_indicators.mic_active,
        camera_active: state.sensor_indicators.camera_active,
        screen_active: state.sensor_indicators.screen_active,
        kill_switch_active: state.sensor_indicators.kill_switch_active,
        feedback_stage: state.feedback.stage,
        tokens_per_second: state.feedback.tokens_per_second,
        eta_ms: state.feedback.eta_ms,
        last_error: state.last_error,
        notifications: state.proactive_notifications,
        widget_visible: state.mini_widget.visible,
        widget_badge: state.mini_widget.badge,
        window_position: state.window_position,
    }))
}

/// Configure overlay settings
#[utoipa::path(
    post,
    path = "/api/v1/overlay/config",
    request_body = OverlayConfigRequest,
    responses(
        (status = 200, description = "Overlay configured successfully"),
        (status = 400, description = "Invalid request", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_config(
    State(state): State<ApiState>,
    Json(request): Json<OverlayConfigRequest>,
) -> StatusCode {
    let overlay_mgr = state.overlay_manager.read().await.clone();
    let mut config = overlay_mgr.get_config().await;

    if let Some(theme) = request.theme {
        config.theme = match theme.as_str() {
            "dark" => OverlayTheme::Dark,
            "light" => OverlayTheme::Light,
            "auto" => OverlayTheme::Auto,
            _ => config.theme,
        };
    }

    if let Some(shortcut) = request.shortcut {
        config.shortcut = shortcut;
    }

    if let Some(opacity) = request.opacity {
        config.opacity = opacity;
    }

    if let Some(enabled) = request.enabled {
        config.enabled = enabled;
    }

    if let Some(widget_visible) = request.widget_visible {
        config.mini_widget_visible = widget_visible;
    }

    match overlay_mgr.update_config(config).await {
        Ok(_) => StatusCode::OK,
        Err(e) => {
            error!("Failed to update overlay config: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

/// Export overlay chat history
#[utoipa::path(
    post,
    path = "/api/v1/overlay/export",
    request_body = OverlayExportRequest,
    responses(
        (status = 200, description = "Chat exported successfully"),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_export(
    State(state): State<ApiState>,
    Json(request): Json<OverlayExportRequest>,
) -> StatusCode {
    let overlay_mgr = state.overlay_manager.read().await.clone();
    let path = PathBuf::from(&request.path);

    match overlay_mgr.export_chat(path).await {
        Ok(_) => StatusCode::OK,
        Err(e) => {
            error!("Failed to export chat: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

/// Import overlay chat history
#[utoipa::path(
    post,
    path = "/api/v1/overlay/import",
    request_body = OverlayImportRequest,
    responses(
        (status = 200, description = "Chat imported successfully"),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_import(
    State(state): State<ApiState>,
    Json(request): Json<OverlayImportRequest>,
) -> StatusCode {
    let overlay_mgr = state.overlay_manager.read().await.clone();
    let path = PathBuf::from(&request.path);

    match overlay_mgr.import_chat(path).await {
        Ok(_) => StatusCode::OK,
        Err(e) => {
            error!("Failed to import chat: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

/// Get model selector data for overlay settings panel
#[utoipa::path(
    get,
    path = "/api/v1/overlay/models",
    responses(
        (status = 200, description = "Overlay model selector data", body = OverlayModelSelectorResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_models(
    State(state): State<ApiState>,
) -> Result<Json<OverlayModelSelectorResponse>, (StatusCode, Json<ApiError>)> {
    let hardware = detect_overlay_hardware().await;
    let configured = configured_model();
    let configured_mmproj = configured_mmproj();
    let active = {
        let ai_manager = state.ai_manager.read().await;
        ai_manager.active_model().await
    };
    let installed = installed_models_map().map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Model Inventory Error".to_string(),
                message: format!("Failed to read installed models: {}", e),
                code: 500,
            }),
        )
    })?;
    let lifecycle_state =
        sync_model_lifecycle_state_with_runtime(&installed, configured.as_deref())
            .unwrap_or_else(|_| load_model_lifecycle_state());
    let removed: BTreeSet<String> = lifecycle_state
        .models
        .iter()
        .filter_map(|(model, entry)| entry.removed_by_user.then_some(model.clone()))
        .collect();
    let pinned: BTreeSet<String> = lifecycle_state
        .models
        .iter()
        .filter_map(|(model, entry)| entry.pinned.then_some(model.clone()))
        .collect();
    let (catalog_version, signature_valid, catalog_models) = load_overlay_catalog();
    let featured_roster = featured_overlay_roster(&catalog_models);
    let storage = build_storage_summary(&installed, &pinned, configured.as_deref());

    let mut cards: Vec<OverlayModelCard> = catalog_models
        .iter()
        .map(|entry| {
            let fit = assess_overlay_model_fit(
                entry.size_bytes,
                entry.recommended_ram_gb,
                entry.recommended_vram_gb,
                &hardware,
            );
            let companion_name = entry
                .companion_mmproj
                .as_ref()
                .map(|artifact| artifact.filename.clone())
                .or_else(|| qwen_companion_mmproj_filename(&entry.id));
            let companion_size = entry
                .companion_mmproj
                .as_ref()
                .and_then(|artifact| artifact.size_bytes);
            let required_disk_bytes =
                Some(entry.size_bytes.saturating_add(companion_size.unwrap_or(0)));
            let integrity_available = entry.checksum_sha256.is_some()
                && entry
                    .companion_mmproj
                    .as_ref()
                    .map(|artifact| artifact.checksum_sha256.is_some())
                    .unwrap_or(true);
            let installed_size = installed.get(&entry.id).copied();
            OverlayModelCard {
                id: entry.id.clone(),
                size_bytes: Some(entry.size_bytes),
                size: format_size_bytes(installed_size.unwrap_or(entry.size_bytes)),
                installed: installed.contains_key(&entry.id),
                selected: configured.as_deref() == Some(entry.id.as_str()),
                pinned: pinned.contains(&entry.id),
                removed_by_user: removed.contains(&entry.id),
                featured: is_featured_overlay_model(&entry.id),
                integrity_available,
                checksum_sha256: entry.checksum_sha256.clone(),
                recommended_ram_gb: entry.recommended_ram_gb,
                recommended_vram_gb: entry.recommended_vram_gb,
                offload_policy: entry.offload_policy.clone(),
                required_disk_bytes,
                estimated_download_seconds: required_disk_bytes.map(estimate_download_seconds),
                download_resumable: true,
                fit_tier: fit.fit_tier,
                expected_gpu_layers: fit.expected_gpu_layers,
                expected_ram_gb: fit.expected_ram_gb,
                expected_vram_gb: fit.expected_vram_gb,
                expected_battery_impact: fit.expected_battery_impact,
                runtime_profiles: entry.runtime_profiles.clone(),
                roles: entry.roles.clone(),
                companion_mmproj: companion_name,
            }
        })
        .collect();

    for (name, size_bytes) in &installed {
        if cards.iter().any(|card| card.id == *name) {
            continue;
        }
        let fit = assess_overlay_model_fit(*size_bytes, None, None, &hardware);
        cards.push(OverlayModelCard {
            id: name.clone(),
            size_bytes: Some(*size_bytes),
            size: format_size_bytes(*size_bytes),
            installed: true,
            selected: configured.as_deref() == Some(name.as_str()),
            pinned: pinned.contains(name),
            removed_by_user: removed.contains(name),
            featured: is_featured_overlay_model(name),
            integrity_available: false,
            checksum_sha256: None,
            recommended_ram_gb: None,
            recommended_vram_gb: None,
            offload_policy: None,
            required_disk_bytes: Some(*size_bytes),
            estimated_download_seconds: Some(0),
            download_resumable: true,
            fit_tier: fit.fit_tier,
            expected_gpu_layers: fit.expected_gpu_layers,
            expected_ram_gb: fit.expected_ram_gb,
            expected_vram_gb: fit.expected_vram_gb,
            expected_battery_impact: fit.expected_battery_impact,
            runtime_profiles: Vec::new(),
            roles: vec!["local".to_string()],
            companion_mmproj: qwen_companion_mmproj_filename(name),
        });
    }

    cards.sort_by(|a, b| {
        b.featured
            .cmp(&a.featured)
            .then_with(|| b.selected.cmp(&a.selected))
            .then_with(|| b.pinned.cmp(&a.pinned))
            .then_with(|| a.id.cmp(&b.id))
    });

    Ok(Json(OverlayModelSelectorResponse {
        active_model: active,
        configured_model: configured,
        configured_mmproj,
        catalog_version,
        catalog_signature_valid: signature_valid,
        featured_roster,
        hardware: OverlayModelHardwareSummary {
            total_ram_gb: hardware.total_ram_gb,
            total_vram_gb: hardware.total_vram_gb,
            gpu_name: hardware.gpu_name,
            gpu_temp_celsius: hardware.gpu_temp_celsius,
            gpu_utilization_percent: hardware.gpu_utilization_percent,
            thermal_pressure: hardware.thermal_pressure,
            on_battery: hardware.on_battery,
        },
        storage,
        models: cards,
    }))
}

/// Set default heavy model for overlay selector
#[utoipa::path(
    post,
    path = "/api/v1/overlay/models/select",
    request_body = OverlayModelSelectRequest,
    responses(
        (status = 200, description = "Overlay model selected", body = OverlayModelActionResponse),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_models_select(
    Json(request): Json<OverlayModelSelectRequest>,
) -> Result<Json<OverlayModelActionResponse>, (StatusCode, Json<ApiError>)> {
    let (_catalog_version, _signature_valid, catalog_models) = load_overlay_catalog();
    let companion_mmproj =
        apply_overlay_model_selection(&request.model, &catalog_models).map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Model Selection Error".to_string(),
                    message: e.to_string(),
                    code: 400,
                }),
            )
        })?;
    let layer_profile = recalculate_gpu_layers_for_model(&request.model, &catalog_models, true)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Model Selection Error".to_string(),
                    message: format!("Failed to recalculate GPU layers: {}", e),
                    code: 500,
                }),
            )
        })?;

    if request.restart {
        restart_llama_server().await.map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Service Restart Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;
    }

    Ok(Json(OverlayModelActionResponse {
        ok: true,
        message: if request.restart {
            format!(
                "Selected {} (fit: {}, gpu_layers={}) and restarted llama-server",
                request.model, layer_profile.fit_tier, layer_profile.expected_gpu_layers
            )
        } else {
            format!(
                "Selected {} (fit: {}, gpu_layers={})",
                request.model, layer_profile.fit_tier, layer_profile.expected_gpu_layers
            )
        },
        selected_model: Some(request.model),
        companion_mmproj,
        selected_mmproj: configured_mmproj(),
    }))
}

/// Remove model through overlay selector lifecycle controls
#[utoipa::path(
    post,
    path = "/api/v1/overlay/models/remove",
    request_body = OverlayModelRemoveRequest,
    responses(
        (status = 200, description = "Overlay model removed", body = OverlayModelActionResponse),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_models_remove(
    Json(request): Json<OverlayModelRemoveRequest>,
) -> Result<Json<OverlayModelActionResponse>, (StatusCode, Json<ApiError>)> {
    let (_catalog_version, _signature_valid, catalog_models) = load_overlay_catalog();
    let model_path = std::path::Path::new(MODEL_DIR).join(&request.model);
    if !model_path.exists() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Model Remove Error".to_string(),
                message: format!("Model {} not found in {}", request.model, MODEL_DIR),
                code: 400,
            }),
        ));
    }

    tokio::fs::remove_file(&model_path).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Model Remove Error".to_string(),
                message: format!("Failed to remove model {}: {}", request.model, e),
                code: 500,
            }),
        )
    })?;

    let companion_mmproj = expected_companion_for_model(&request.model, &catalog_models);
    if request.remove_companion {
        if let Some(companion) = &companion_mmproj {
            let companion_path = std::path::Path::new(MODEL_DIR).join(companion);
            if companion_path.exists() {
                let _ = tokio::fs::remove_file(companion_path).await;
            }
        }
    }

    mark_model_removed(&request.model).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Model Remove Error".to_string(),
                message: format!("Failed to persist removed model state: {}", e),
                code: 500,
            }),
        )
    })?;
    clear_model_pinned(&request.model).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Model Remove Error".to_string(),
                message: format!("Failed to clear pinned model state: {}", e),
                code: 500,
            }),
        )
    })?;

    let mut selected_model = configured_model();
    let mut selected_mmproj = configured_mmproj();
    if selected_model.as_deref() == Some(request.model.as_str()) {
        if request.select_fallback {
            if let Some(fallback) = pick_fallback_model(&request.model).map_err(|e| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ApiError {
                        error: "Model Remove Error".to_string(),
                        message: e.to_string(),
                        code: 500,
                    }),
                )
            })? {
                apply_overlay_model_selection(&fallback, &catalog_models).map_err(|e| {
                    (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(ApiError {
                            error: "Fallback Selection Error".to_string(),
                            message: e.to_string(),
                            code: 500,
                        }),
                    )
                })?;
                selected_model = Some(fallback);
                selected_mmproj = configured_mmproj();
            } else {
                clear_overlay_model_selection().map_err(|e| {
                    (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(ApiError {
                            error: "Model Remove Error".to_string(),
                            message: format!("Failed to clear selected model/mmproj: {}", e),
                            code: 500,
                        }),
                    )
                })?;
                selected_model = None;
                selected_mmproj = None;
            }
        } else {
            clear_overlay_model_selection().map_err(|e| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ApiError {
                        error: "Model Remove Error".to_string(),
                        message: format!("Failed to clear selected model/mmproj: {}", e),
                        code: 500,
                    }),
                )
            })?;
            selected_model = None;
            selected_mmproj = None;
        }
    }

    if request.restart {
        restart_llama_server().await.map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Service Restart Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;
    }

    Ok(Json(OverlayModelActionResponse {
        ok: true,
        message: format!("Removed {}", request.model),
        selected_model,
        companion_mmproj,
        selected_mmproj,
    }))
}

/// Pull model artifacts through overlay selector using signed catalog
#[utoipa::path(
    post,
    path = "/api/v1/overlay/models/pull",
    request_body = OverlayModelPullRequest,
    responses(
        (status = 200, description = "Overlay model pulled", body = OverlayModelActionResponse),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_models_pull(
    Json(request): Json<OverlayModelPullRequest>,
) -> Result<Json<OverlayModelActionResponse>, (StatusCode, Json<ApiError>)> {
    let (_catalog_version, _signature_valid, catalog_models) = load_overlay_catalog();
    let model_entry = resolve_catalog_model(&request.model, &catalog_models).ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Model Pull Error".to_string(),
                message: format!(
                    "Model {} is not available in the signed catalog",
                    request.model
                ),
                code: 400,
            }),
        )
    })?;
    let expected_companion_size = model_entry
        .companion_mmproj
        .as_ref()
        .and_then(|artifact| artifact.size_bytes)
        .unwrap_or(0);
    let required_disk_bytes = model_entry
        .size_bytes
        .saturating_add(expected_companion_size);
    ensure_model_storage_capacity(required_disk_bytes).map_err(|e| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Model Pull Error".to_string(),
                message: e.to_string(),
                code: 400,
            }),
        )
    })?;

    let model_path = std::path::Path::new(MODEL_DIR).join(&model_entry.id);
    download_model_with_curl(
        &model_entry.download_url,
        &model_path,
        Some(model_entry.size_bytes),
        model_entry.checksum_sha256.as_deref(),
        request.force,
    )
    .await
    .map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Model Pull Error".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )
    })?;

    let companion = model_entry.companion_mmproj.clone().or_else(|| {
        qwen_repo_for_model(&model_entry.id).and_then(|repo| {
            qwen_companion_mmproj_filename(&model_entry.id).map(|filename| {
                OverlayCatalogCompanionArtifact {
                    filename,
                    download_url: format!(
                        "https://huggingface.co/unsloth/{repo}/resolve/main/mmproj-F16.gguf"
                    ),
                    size_bytes: None,
                    checksum_sha256: None,
                }
            })
        })
    });

    let companion_mmproj = companion.as_ref().map(|artifact| artifact.filename.clone());
    if let Some(companion_artifact) = companion {
        let mmproj_path = std::path::Path::new(MODEL_DIR).join(&companion_artifact.filename);
        download_model_with_curl(
            &companion_artifact.download_url,
            &mmproj_path,
            companion_artifact.size_bytes,
            companion_artifact.checksum_sha256.as_deref(),
            request.force,
        )
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Model Pull Error".to_string(),
                    message: format!("Failed to pull companion mmproj: {}", e),
                    code: 500,
                }),
            )
        })?;
    }

    clear_removed_model(&model_entry.id).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Model Pull Error".to_string(),
                message: format!("Failed to clear removed model marker: {}", e),
                code: 500,
            }),
        )
    })?;
    set_model_installed_in_lifecycle(&model_entry.id, true).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Model Pull Error".to_string(),
                message: format!("Failed to persist model lifecycle state: {}", e),
                code: 500,
            }),
        )
    })?;

    let layers_target = configured_model().unwrap_or_else(|| model_entry.id.clone());
    let layer_profile = recalculate_gpu_layers_for_model(&layers_target, &catalog_models, true)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Model Pull Error".to_string(),
                    message: format!("Failed to recalculate GPU layers: {}", e),
                    code: 500,
                }),
            )
        })?;

    if request.restart && configured_model().as_deref() == Some(model_entry.id.as_str()) {
        restart_llama_server().await.map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Service Restart Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;
    }

    Ok(Json(OverlayModelActionResponse {
        ok: true,
        message: format!(
            "Pulled {} (fit: {}, gpu_layers={})",
            model_entry.id, layer_profile.fit_tier, layer_profile.expected_gpu_layers
        ),
        selected_model: configured_model(),
        companion_mmproj,
        selected_mmproj: configured_mmproj(),
    }))
}

/// Pin model to protect it from accidental cleanup flows
#[utoipa::path(
    post,
    path = "/api/v1/overlay/models/pin",
    request_body = OverlayModelPinRequest,
    responses(
        (status = 200, description = "Overlay model pinned", body = OverlayModelActionResponse),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_models_pin(
    Json(request): Json<OverlayModelPinRequest>,
) -> Result<Json<OverlayModelActionResponse>, (StatusCode, Json<ApiError>)> {
    let model_path = std::path::Path::new(MODEL_DIR).join(&request.model);
    if !model_path.exists() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Model Pin Error".to_string(),
                message: format!("Model {} not found in {}", request.model, MODEL_DIR),
                code: 400,
            }),
        ));
    }

    mark_model_pinned(&request.model).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Model Pin Error".to_string(),
                message: format!("Failed to persist pinned model state: {}", e),
                code: 500,
            }),
        )
    })?;

    Ok(Json(OverlayModelActionResponse {
        ok: true,
        message: format!("Pinned {}", request.model),
        selected_model: configured_model(),
        companion_mmproj: qwen_companion_mmproj_filename(&request.model),
        selected_mmproj: configured_mmproj(),
    }))
}

/// Unpin model so cleanup policies can prune it when needed
#[utoipa::path(
    post,
    path = "/api/v1/overlay/models/unpin",
    request_body = OverlayModelPinRequest,
    responses(
        (status = 200, description = "Overlay model unpinned", body = OverlayModelActionResponse),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_models_unpin(
    Json(request): Json<OverlayModelPinRequest>,
) -> Result<Json<OverlayModelActionResponse>, (StatusCode, Json<ApiError>)> {
    clear_model_pinned(&request.model).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Model Unpin Error".to_string(),
                message: format!("Failed to update pinned model state: {}", e),
                code: 500,
            }),
        )
    })?;

    Ok(Json(OverlayModelActionResponse {
        ok: true,
        message: format!("Unpinned {}", request.model),
        selected_model: configured_model(),
        companion_mmproj: qwen_companion_mmproj_filename(&request.model),
        selected_mmproj: configured_mmproj(),
    }))
}

/// Cleanup non-selected and non-pinned models to reclaim disk space
#[utoipa::path(
    post,
    path = "/api/v1/overlay/models/cleanup",
    request_body = OverlayModelCleanupRequest,
    responses(
        (status = 200, description = "Overlay model cleanup completed", body = OverlayModelCleanupResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_models_cleanup(
    Json(request): Json<OverlayModelCleanupRequest>,
) -> Result<Json<OverlayModelCleanupResponse>, (StatusCode, Json<ApiError>)> {
    let (_catalog_version, _signature_valid, catalog_models) = load_overlay_catalog();
    let installed = installed_models_map().map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Model Cleanup Error".to_string(),
                message: format!("Failed to read installed models: {}", e),
                code: 500,
            }),
        )
    })?;

    let selected_model = configured_model();
    let lifecycle_state =
        sync_model_lifecycle_state_with_runtime(&installed, selected_model.as_deref())
            .unwrap_or_else(|_| load_model_lifecycle_state());
    let pinned: BTreeSet<String> = lifecycle_state
        .models
        .iter()
        .filter_map(|(model, entry)| entry.pinned.then_some(model.clone()))
        .collect();

    let removable_models: Vec<String> = installed
        .keys()
        .filter(|model| {
            !pinned.contains(*model) && selected_model.as_deref() != Some(model.as_str())
        })
        .cloned()
        .collect();

    let mut removed_companions = BTreeSet::new();
    if request.remove_companion && !removable_models.is_empty() {
        let keep_models: BTreeSet<String> = installed
            .keys()
            .filter(|model| !removable_models.iter().any(|candidate| candidate == *model))
            .cloned()
            .collect();
        let required_companions: BTreeSet<String> = keep_models
            .iter()
            .filter_map(|model| expected_companion_for_model(model, &catalog_models))
            .collect();
        for model in &removable_models {
            if let Some(companion) = expected_companion_for_model(model, &catalog_models) {
                if !required_companions.contains(&companion) {
                    removed_companions.insert(companion);
                }
            }
        }
    }

    let mut reclaimed_bytes = 0u64;
    for model in &removable_models {
        let path = std::path::Path::new(MODEL_DIR).join(model);
        if let Ok(meta) = std::fs::metadata(&path) {
            reclaimed_bytes = reclaimed_bytes.saturating_add(meta.len());
        }
    }
    for companion in &removed_companions {
        let path = std::path::Path::new(MODEL_DIR).join(companion);
        if let Ok(meta) = std::fs::metadata(&path) {
            reclaimed_bytes = reclaimed_bytes.saturating_add(meta.len());
        }
    }

    if !request.dry_run {
        for model in &removable_models {
            let path = std::path::Path::new(MODEL_DIR).join(model);
            if path.exists() {
                tokio::fs::remove_file(&path).await.map_err(|e| {
                    (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(ApiError {
                            error: "Model Cleanup Error".to_string(),
                            message: format!("Failed to remove {}: {}", model, e),
                            code: 500,
                        }),
                    )
                })?;
            }
            mark_model_removed(model).map_err(|e| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ApiError {
                        error: "Model Cleanup Error".to_string(),
                        message: format!("Failed to persist tombstone for {}: {}", model, e),
                        code: 500,
                    }),
                )
            })?;
            clear_model_pinned(model).map_err(|e| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ApiError {
                        error: "Model Cleanup Error".to_string(),
                        message: format!("Failed to clear pinned state for {}: {}", model, e),
                        code: 500,
                    }),
                )
            })?;
        }

        for companion in &removed_companions {
            let path = std::path::Path::new(MODEL_DIR).join(companion);
            if path.exists() {
                tokio::fs::remove_file(path).await.map_err(|e| {
                    (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(ApiError {
                            error: "Model Cleanup Error".to_string(),
                            message: format!("Failed to remove companion {}: {}", companion, e),
                            code: 500,
                        }),
                    )
                })?;
            }
        }

        if request.restart {
            restart_llama_server().await.map_err(|e| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ApiError {
                        error: "Service Restart Error".to_string(),
                        message: e.to_string(),
                        code: 500,
                    }),
                )
            })?;
        }
    }

    let removed_companions_vec = removed_companions.into_iter().collect::<Vec<_>>();
    let selected_mmproj = configured_mmproj();
    let action = if request.dry_run {
        "Dry-run cleanup"
    } else {
        "Cleanup"
    };
    Ok(Json(OverlayModelCleanupResponse {
        ok: true,
        dry_run: request.dry_run,
        removed_models: removable_models.clone(),
        removed_companions: removed_companions_vec,
        reclaimed_bytes,
        selected_model,
        selected_mmproj,
        message: format!(
            "{}: {} model(s) reclaimable, estimated {} freed",
            action,
            removable_models.len(),
            format_size_bytes(reclaimed_bytes),
        ),
    }))
}

/// Export overlay model lifecycle inventory to disk
#[utoipa::path(
    post,
    path = "/api/v1/overlay/models/export",
    request_body = OverlayModelInventoryExportRequest,
    responses(
        (status = 200, description = "Overlay model inventory exported", body = OverlayModelActionResponse),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_models_export_inventory(
    Json(request): Json<OverlayModelInventoryExportRequest>,
) -> Result<Json<OverlayModelActionResponse>, (StatusCode, Json<ApiError>)> {
    let path = PathBuf::from(&request.path);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Model Inventory Export Error".to_string(),
                    message: format!("Failed to create export directory: {}", e),
                    code: 500,
                }),
            )
        })?;
    }

    let state = load_model_lifecycle_state();
    let snapshot = OverlayModelInventorySnapshot {
        schema_version: "lifeos-model-inventory-v1".to_string(),
        exported_at: chrono::Utc::now().to_rfc3339(),
        device_id: Some(local_device_id()),
        models: state.models,
    };
    let serialized = serde_json::to_string_pretty(&snapshot).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Model Inventory Export Error".to_string(),
                message: format!("Failed to serialize inventory export: {}", e),
                code: 500,
            }),
        )
    })?;
    std::fs::write(&path, serialized).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Model Inventory Export Error".to_string(),
                message: format!("Failed to write export file: {}", e),
                code: 500,
            }),
        )
    })?;

    let selected_mmproj = configured_mmproj();
    Ok(Json(OverlayModelActionResponse {
        ok: true,
        message: format!("Exported model inventory to {}", path.display()),
        selected_model: configured_model(),
        companion_mmproj: selected_mmproj.clone(),
        selected_mmproj,
    }))
}

/// Import overlay model lifecycle inventory from disk
#[utoipa::path(
    post,
    path = "/api/v1/overlay/models/import",
    request_body = OverlayModelInventoryImportRequest,
    responses(
        (status = 200, description = "Overlay model inventory imported", body = OverlayModelActionResponse),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "overlay"
)]
async fn overlay_models_import_inventory(
    Json(request): Json<OverlayModelInventoryImportRequest>,
) -> Result<Json<OverlayModelActionResponse>, (StatusCode, Json<ApiError>)> {
    let path = PathBuf::from(&request.path);
    let raw = std::fs::read_to_string(&path).map_err(|e| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Model Inventory Import Error".to_string(),
                message: format!("Failed to read import file: {}", e),
                code: 400,
            }),
        )
    })?;

    let snapshot = match serde_json::from_str::<OverlayModelInventorySnapshot>(&raw) {
        Ok(snapshot) => snapshot,
        Err(_) => {
            let legacy = serde_json::from_str::<OverlayModelLifecycleState>(&raw).map_err(|e| {
                (
                    StatusCode::BAD_REQUEST,
                    Json(ApiError {
                        error: "Model Inventory Import Error".to_string(),
                        message: format!("Invalid inventory format: {}", e),
                        code: 400,
                    }),
                )
            })?;
            OverlayModelInventorySnapshot {
                schema_version: "lifeos-model-inventory-v1".to_string(),
                exported_at: chrono::Utc::now().to_rfc3339(),
                device_id: None,
                models: legacy.models,
            }
        }
    };

    let local_device = local_device_id();
    let same_device = snapshot.device_id.as_deref() == Some(local_device.as_str());
    let apply_pinning = request.adopt_pinning || same_device || snapshot.device_id.is_none();

    let mut state = load_model_lifecycle_state();
    let mut imported_entries = 0usize;
    for (model, imported) in snapshot.models {
        let entry = state.models.entry(model).or_default();
        let mut changed = false;

        if imported.removed_by_user && !entry.removed_by_user {
            entry.removed_by_user = true;
            entry.selected = false;
            entry.installed = false;
            changed = true;
        }

        if apply_pinning && imported.pinned && !entry.pinned {
            entry.pinned = true;
            changed = true;
        }

        if changed {
            entry.updated_at = Some(model_lifecycle_marker());
            imported_entries += 1;
        }
    }

    write_model_lifecycle_state(&state).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Model Inventory Import Error".to_string(),
                message: format!("Failed to persist imported inventory: {}", e),
                code: 500,
            }),
        )
    })?;

    let selected_mmproj = configured_mmproj();
    let pinning_note = if apply_pinning {
        "pinning imported"
    } else {
        "pinning skipped (different device id)"
    };
    Ok(Json(OverlayModelActionResponse {
        ok: true,
        message: format!(
            "Imported model inventory from {} ({} entries updated, {})",
            path.display(),
            imported_entries,
            pinning_note
        ),
        selected_model: configured_model(),
        companion_mmproj: selected_mmproj.clone(),
        selected_mmproj,
    }))
}

// ==================== UPDATE API HANDLERS ====================

/// Get current update channel
#[utoipa::path(
    get,
    path = "/api/v1/updates/channel",
    responses(
        (status = 200, description = "Update channel retrieved", body = UpdateChannelResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "updates"
)]
async fn get_update_channel(
    State(_state): State<ApiState>,
) -> Result<Json<UpdateChannelResponse>, (StatusCode, Json<ApiError>)> {
    let scheduler = UpdateScheduler::new(PathBuf::from("/var/lib/lifeos"));
    let channel = scheduler.get_channel().await;

    let (display_name, description) = match channel {
        crate::update_scheduler::UpdateChannel::Stable => ("Stable", "Stable releases only"),
        crate::update_scheduler::UpdateChannel::Candidate => {
            ("Candidate", "Release candidates for testing")
        }
        crate::update_scheduler::UpdateChannel::Edge => ("Edge", "Bleeding edge features"),
    };

    Ok(Json(UpdateChannelResponse {
        channel: format!("{:?}", channel),
        display_name: display_name.to_string(),
        description: description.to_string(),
    }))
}

/// Set update channel
#[utoipa::path(
    post,
    path = "/api/v1/updates/set-channel",
    request_body = SetUpdateChannelRequest,
    responses(
        (status = 200, description = "Update channel set"),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "updates"
)]
async fn set_update_channel(
    State(_state): State<ApiState>,
    Json(request): Json<SetUpdateChannelRequest>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let scheduler = UpdateScheduler::new(PathBuf::from("/var/lib/lifeos"));

    let channel = match request.channel.to_lowercase().as_str() {
        "stable" => crate::update_scheduler::UpdateChannel::Stable,
        "candidate" => crate::update_scheduler::UpdateChannel::Candidate,
        "edge" => crate::update_scheduler::UpdateChannel::Edge,
        _ => {
            return Err((
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Invalid channel".to_string(),
                    message: "Channel must be one of: stable, candidate, edge".to_string(),
                    code: 400,
                }),
            ))
        }
    };

    match scheduler.set_channel(channel).await {
        Ok(_) => Ok(StatusCode::OK),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to set channel".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )),
    }
}

/// Get update schedule
#[utoipa::path(
    get,
    path = "/api/v1/updates/schedule",
    responses(
        (status = 200, description = "Update schedule retrieved", body = UpdateScheduleResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "updates"
)]
async fn get_update_schedule(
    State(_state): State<ApiState>,
) -> Result<Json<UpdateScheduleResponse>, (StatusCode, Json<ApiError>)> {
    let scheduler = UpdateScheduler::new(PathBuf::from("/var/lib/lifeos"));
    let status = scheduler.get_status().await;

    Ok(Json(UpdateScheduleResponse {
        schedule_type: format!("{:?}", status.schedule_type),
        update_time: "02:00".to_string(),
        update_day: 1,
        check_frequency_hours: status.check_frequency_hours,
        auto_install: false,
    }))
}

/// Set update schedule
#[utoipa::path(
    post,
    path = "/api/v1/updates/set-schedule",
    request_body = SetUpdateScheduleRequest,
    responses(
        (status = 200, description = "Update schedule set"),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "updates"
)]
async fn set_update_schedule(
    State(_state): State<ApiState>,
    Json(_request): Json<SetUpdateScheduleRequest>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    // In a real implementation, this would update the schedule configuration
    Ok(StatusCode::OK)
}

/// Get available updates
#[utoipa::path(
    get,
    path = "/api/v1/updates/available",
    responses(
        (status = 200, description = "Available updates retrieved", body = AvailableUpdatesResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "updates"
)]
async fn get_available_updates(
    State(_state): State<ApiState>,
) -> Result<Json<AvailableUpdatesResponse>, (StatusCode, Json<ApiError>)> {
    let scheduler = UpdateScheduler::new(PathBuf::from("/var/lib/lifeos"));
    match scheduler.get_available_versions(None).await {
        Ok(versions) => {
            let version_infos: Vec<AvailableVersionInfo> = versions
                .iter()
                .map(|v| AvailableVersionInfo {
                    version: v.version.clone(),
                    channel: format!("{:?}", v.channel),
                    release_date: v.release_date.to_rfc3339(),
                    notes: v.notes.clone(),
                    size_bytes: v.size_bytes,
                    download_url: v.download_url.clone(),
                    required_disk_space_mb: v.required_disk_space_mb,
                })
                .collect();

            Ok(Json(AvailableUpdatesResponse {
                updates: version_infos,
                count: versions.len(),
            }))
        }
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to get available updates".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )),
    }
}

/// Schedule an update
#[utoipa::path(
    post,
    path = "/api/v1/updates/schedule-update",
    request_body = ScheduleUpdateRequest,
    responses(
        (status = 200, description = "Update scheduled"),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "updates"
)]
async fn schedule_update(
    State(_state): State<ApiState>,
    Json(request): Json<ScheduleUpdateRequest>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let scheduler = UpdateScheduler::new(PathBuf::from("/var/lib/lifeos"));
    let channel = request.channel.unwrap_or_else(|| "stable".to_string());

    let update_channel = match channel.to_lowercase().as_str() {
        "stable" => crate::update_scheduler::UpdateChannel::Stable,
        "candidate" => crate::update_scheduler::UpdateChannel::Candidate,
        "edge" => crate::update_scheduler::UpdateChannel::Edge,
        _ => {
            return Err((
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Invalid channel".to_string(),
                    message: "Channel must be one of: stable, candidate, edge".to_string(),
                    code: 400,
                }),
            ))
        }
    };

    match scheduler
        .schedule_update(request.version, update_channel)
        .await
    {
        Ok(_) => Ok(StatusCode::OK),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to schedule update".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )),
    }
}

/// Check for updates
#[utoipa::path(
    post,
    path = "/api/v1/updates/check",
    responses(
        (status = 200, description = "Update check completed"),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "updates"
)]
async fn check_for_updates(
    State(_state): State<ApiState>,
) -> Result<Json<AvailableUpdatesResponse>, (StatusCode, Json<ApiError>)> {
    let scheduler = UpdateScheduler::new(PathBuf::from("/var/lib/lifeos"));
    match scheduler.fetch_available_versions().await {
        Ok(_) => {
            if let Ok(Some(update)) = scheduler.check_for_updates().await {
                Ok(Json(AvailableUpdatesResponse {
                    updates: vec![AvailableVersionInfo {
                        version: update.version,
                        channel: format!("{:?}", update.channel),
                        release_date: update.release_date.to_rfc3339(),
                        notes: update.notes,
                        size_bytes: update.size_bytes,
                        download_url: update.download_url,
                        required_disk_space_mb: update.required_disk_space_mb,
                    }],
                    count: 1,
                }))
            } else {
                Ok(Json(AvailableUpdatesResponse {
                    updates: vec![],
                    count: 0,
                }))
            }
        }
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to check for updates".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )),
    }
}

/// Get update history
#[utoipa::path(
    get,
    path = "/api/v1/updates/history",
    responses(
        (status = 200, description = "Update history retrieved", body = UpdateHistoryResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "updates"
)]
async fn get_update_history(
    State(_state): State<ApiState>,
) -> Result<Json<UpdateHistoryResponse>, (StatusCode, Json<ApiError>)> {
    let scheduler = UpdateScheduler::new(PathBuf::from("/var/lib/lifeos"));
    let history = scheduler.get_history().await;

    let record_infos: Vec<UpdateRecordInfo> = history
        .iter()
        .map(|r| UpdateRecordInfo {
            timestamp: r.timestamp.to_rfc3339(),
            version: r.version.clone(),
            channel: format!("{:?}", r.channel),
            status: format!("{:?}", r.status),
            checksum: r.checksum.clone(),
        })
        .collect();

    let count = record_infos.len();
    Ok(Json(UpdateHistoryResponse {
        history: record_infos,
        count,
    }))
}

/// Install update
#[utoipa::path(
    post,
    path = "/api/v1/updates/install",
    request_body = InstallUpdateRequest,
    responses(
        (status = 200, description = "Update installed"),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "updates"
)]
async fn install_update(
    State(_state): State<ApiState>,
    Json(request): Json<InstallUpdateRequest>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let scheduler = UpdateScheduler::new(PathBuf::from("/var/lib/lifeos"));

    // Get available versions
    let available = match scheduler.get_available_versions(None).await {
        Ok(v) => v,
        Err(e) => {
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Failed to get available versions".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            ))
        }
    };

    // Find the requested version
    let version = available
        .iter()
        .find(|v| v.version == request.version)
        .ok_or_else(|| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Version not found".to_string(),
                    message: format!("Version {} not available", request.version),
                    code: 400,
                }),
            )
        })?;

    // Download update
    match scheduler.download_update(version).await {
        Ok(_) => {
            // Install update
            match scheduler.install_update(version).await {
                Ok(_) => Ok(StatusCode::OK),
                Err(e) => Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ApiError {
                        error: "Failed to install update".to_string(),
                        message: e.to_string(),
                        code: 500,
                    }),
                )),
            }
        }
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to download update".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )),
    }
}

/// Rollback update
#[utoipa::path(
    post,
    path = "/api/v1/updates/rollback",
    responses(
        (status = 200, description = "Update rolled back"),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "updates"
)]
async fn rollback_update(
    State(_state): State<ApiState>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let scheduler = UpdateScheduler::new(PathBuf::from("/var/lib/lifeos"));

    match scheduler.rollback().await {
        Ok(_) => Ok(StatusCode::OK),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to rollback".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )),
    }
}

/// Get update status
#[utoipa::path(
    get,
    path = "/api/v1/updates/status",
    responses(
        (status = 200, description = "Update status retrieved", body = UpdateStatusResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "updates"
)]
async fn get_update_status(
    State(_state): State<ApiState>,
) -> Result<Json<UpdateStatusResponse>, (StatusCode, Json<ApiError>)> {
    let scheduler = UpdateScheduler::new(PathBuf::from("/var/lib/lifeos"));
    let status = scheduler.get_status().await;

    Ok(Json(UpdateStatusResponse {
        current_channel: format!("{:?}", status.current_channel),
        available_versions: status.available_versions,
        scheduled_updates: status.scheduled_updates,
        last_update: status.last_update,
        schedule_type: format!("{:?}", status.schedule_type),
        check_frequency_hours: status.check_frequency_hours,
    }))
}

/// Clear update schedule
#[utoipa::path(
    post,
    path = "/api/v1/updates/schedule-clear",
    responses(
        (status = 200, description = "Update schedule cleared"),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "updates"
)]
async fn clear_schedule(
    State(_state): State<ApiState>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let scheduler = UpdateScheduler::new(PathBuf::from("/var/lib/lifeos"));

    match scheduler.clear_history().await {
        Ok(_) => Ok(StatusCode::OK),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to clear schedule".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )),
    }
}

// ==================== FOLLOWALONG API HANDLERS ====================

/// Get FollowAlong configuration
#[utoipa::path(
    get,
    path = "/api/v1/followalong/config",
    responses(
        (status = 200, description = "FollowAlong configuration retrieved", body = FollowAlongConfigResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "followalong"
)]
async fn get_followalong_config(
    State(state): State<ApiState>,
) -> Result<Json<FollowAlongConfigResponse>, (StatusCode, Json<ApiError>)> {
    let manager = state.follow_along_manager.read().await.clone();
    let config = manager.get_config().await;

    Ok(Json(FollowAlongConfigResponse {
        enabled: config.enabled,
        consent_status: format!("{:?}", config.consent_status),
        auto_summarize: config.auto_summarize,
        auto_translate: config.auto_translate,
        auto_explain: config.auto_explain,
        summary_interval_seconds: config.summary_interval_seconds,
        max_events_buffer: config.max_events_buffer,
    }))
}

/// Set FollowAlong configuration
#[utoipa::path(
    post,
    path = "/api/v1/followalong/config",
    request_body = SetFollowAlongConfigRequest,
    responses(
        (status = 200, description = "FollowAlong configuration updated"),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "followalong"
)]
async fn set_followalong_config(
    State(state): State<ApiState>,
    Json(request): Json<SetFollowAlongConfigRequest>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let manager = state.follow_along_manager.read().await.clone();
    let mut config = manager.get_config().await;

    if let Some(enabled) = request.enabled {
        config.enabled = enabled;
    }
    if let Some(auto_summarize) = request.auto_summarize {
        config.auto_summarize = auto_summarize;
    }
    if let Some(auto_translate) = request.auto_translate {
        config.auto_translate = auto_translate;
    }
    if let Some(auto_explain) = request.auto_explain {
        config.auto_explain = auto_explain;
    }
    if let Some(interval) = request.summary_interval_seconds {
        config.summary_interval_seconds = interval;
    }

    match manager.update_config(config).await {
        Ok(_) => Ok(StatusCode::OK),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to update config".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )),
    }
}

/// Set FollowAlong consent
#[utoipa::path(
    post,
    path = "/api/v1/followalong/consent",
    request_body = SetConsentRequest,
    responses(
        (status = 200, description = "Consent status updated"),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "followalong"
)]
async fn set_followalong_consent(
    State(state): State<ApiState>,
    Json(request): Json<SetConsentRequest>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let manager = state.follow_along_manager.read().await.clone();
    match manager.set_consent(request.granted).await {
        Ok(_) => Ok(StatusCode::OK),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to set consent".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )),
    }
}

/// Get current context state
#[utoipa::path(
    get,
    path = "/api/v1/followalong/context",
    responses(
        (status = 200, description = "Context state retrieved", body = ContextStateResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "followalong"
)]
async fn get_followalong_context(
    State(state): State<ApiState>,
) -> Result<Json<ContextStateResponse>, (StatusCode, Json<ApiError>)> {
    let manager = state.follow_along_manager.read().await.clone();
    let context = manager.get_context().await;

    Ok(Json(ContextStateResponse {
        current_application: context.current_application,
        current_window: context.current_window,
        active_pattern: context.active_pattern,
        session_duration_minutes: context.session_duration.num_minutes(),
        last_event: context.last_event.map(|t| t.to_rfc3339()),
    }))
}

/// Get event statistics
#[utoipa::path(
    get,
    path = "/api/v1/followalong/stats",
    responses(
        (status = 200, description = "Event statistics retrieved", body = EventStatsResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "followalong"
)]
async fn get_followalong_stats(
    State(state): State<ApiState>,
) -> Result<Json<EventStatsResponse>, (StatusCode, Json<ApiError>)> {
    let manager = state.follow_along_manager.read().await.clone();
    let stats = manager.get_event_stats().await;

    let event_counts: Vec<EventCountInfo> = stats
        .event_counts
        .iter()
        .map(|(event_type, count)| EventCountInfo {
            event_type: event_type.clone(),
            count: *count,
        })
        .collect();

    Ok(Json(EventStatsResponse {
        total_events: stats.total_events,
        event_counts,
        current_application: stats.current_application,
        current_window: stats.current_window,
        session_duration_minutes: stats.session_duration.num_minutes(),
    }))
}

/// Generate activity summary
#[utoipa::path(
    post,
    path = "/api/v1/followalong/summary",
    responses(
        (status = 200, description = "Activity summary generated", body = SummaryResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "followalong"
)]
async fn generate_followalong_summary(
    State(state): State<ApiState>,
) -> Result<Json<SummaryResponse>, (StatusCode, Json<ApiError>)> {
    let manager = state.follow_along_manager.read().await.clone();
    match manager.generate_summary().await {
        Ok(summary) => Ok(Json(SummaryResponse {
            summary,
            timestamp: chrono::Utc::now().to_rfc3339(),
            event_count: manager.get_event_stats().await.total_events,
            session_duration_minutes: manager.get_context().await.session_duration.num_minutes(),
        })),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to generate summary".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )),
    }
}

/// Translate activity summary
#[utoipa::path(
    post,
    path = "/api/v1/followalong/translate",
    request_body = TranslateSummaryRequest,
    responses(
        (status = 200, description = "Summary translated"),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "followalong"
)]
async fn translate_followalong_summary(
    State(state): State<ApiState>,
    Json(request): Json<TranslateSummaryRequest>,
) -> Result<Json<SummaryResponse>, (StatusCode, Json<ApiError>)> {
    let manager = state.follow_along_manager.read().await.clone();
    match manager.translate_summary(&request.target_language).await {
        Ok(summary) => Ok(Json(SummaryResponse {
            summary,
            timestamp: chrono::Utc::now().to_rfc3339(),
            event_count: manager.get_event_stats().await.total_events,
            session_duration_minutes: manager.get_context().await.session_duration.num_minutes(),
        })),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to translate summary".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )),
    }
}

/// Explain activity
#[utoipa::path(
    post,
    path = "/api/v1/followalong/explain",
    request_body = ExplainActivityRequest,
    responses(
        (status = 200, description = "Activity explanation generated", body = ExplanationResponse),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "followalong"
)]
async fn explain_followalong_activity(
    State(state): State<ApiState>,
    Json(request): Json<ExplainActivityRequest>,
) -> Result<Json<ExplanationResponse>, (StatusCode, Json<ApiError>)> {
    let manager = state.follow_along_manager.read().await.clone();
    match manager.explain_activity(&request.question).await {
        Ok(explanation) => Ok(Json(ExplanationResponse {
            explanation,
            question: request.question,
            timestamp: chrono::Utc::now().to_rfc3339(),
        })),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to explain activity".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )),
    }
}

/// Clear events buffer
#[utoipa::path(
    post,
    path = "/api/v1/followalong/clear",
    responses(
        (status = 200, description = "Events cleared"),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "followalong"
)]
async fn clear_followalong_events(
    State(state): State<ApiState>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let manager = state.follow_along_manager.read().await.clone();
    match manager.clear_events().await {
        Ok(_) => Ok(StatusCode::OK),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to clear events".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )),
    }
}

// ==================== HELPER FUNCTIONS ====================

fn get_hostname() -> String {
    std::fs::read_to_string("/etc/hostname")
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "unknown".to_string())
}

fn get_kernel_version() -> String {
    std::fs::read_to_string("/proc/version")
        .map(|s| s.split_whitespace().nth(2).unwrap_or("unknown").to_string())
        .unwrap_or_else(|_| "unknown".to_string())
}

fn get_cpu_model() -> String {
    std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("model name"))
                .map(|l| l.split(':').nth(1).unwrap_or("unknown").trim().to_string())
        })
        .unwrap_or_else(|| "unknown".to_string())
}

fn get_total_memory_gb() -> f32 {
    std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("MemTotal:"))
                .and_then(|l| {
                    l.split_whitespace()
                        .nth(1)
                        .and_then(|n| n.parse::<f64>().ok())
                        .map(|kb| (kb / 1024.0 / 1024.0) as f32)
                })
        })
        .unwrap_or(0.0)
}

fn get_gpu_model() -> Option<String> {
    // Try lspci for NVIDIA/AMD/Intel GPU
    if let Ok(output) = std::process::Command::new("lspci").output() {
        let text = String::from_utf8_lossy(&output.stdout);
        let mut fallback: Option<String> = None;
        for line in text.lines() {
            if !(line.contains("VGA compatible controller") || line.contains("3D controller")) {
                continue;
            }
            if let Some(idx) = line.find(": ") {
                let name = line[idx + 2..].trim().to_string();
                // Prefer dedicated GPU (NVIDIA/AMD) over integrated Intel
                if name.contains("NVIDIA") || name.contains("AMD") {
                    return Some(name);
                }
                if fallback.is_none() {
                    fallback = Some(name);
                }
            }
        }
        if fallback.is_some() {
            return fallback;
        }
    }
    // Try nvidia-smi as fallback
    if let Ok(output) = std::process::Command::new("nvidia-smi")
        .args(["--query-gpu=name", "--format=csv,noheader,nounits"])
        .output()
    {
        let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !name.is_empty() {
            return Some(name);
        }
    }
    None
}

fn get_gpu_vram() -> Option<(f32, f32)> {
    if let Ok(output) = std::process::Command::new("nvidia-smi")
        .args([
            "--query-gpu=memory.used,memory.total",
            "--format=csv,noheader,nounits",
        ])
        .output()
    {
        let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let parts: Vec<&str> = text.split(',').map(|s| s.trim()).collect();
        if parts.len() == 2 {
            if let (Ok(used), Ok(total)) = (parts[0].parse::<f32>(), parts[1].parse::<f32>()) {
                return Some((used, total));
            }
        }
    }
    None
}

// ==================== CONTEXT POLICIES HANDLERS ====================

/// Get current context status
async fn get_context_status(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let ctx_mgr = state.context_policies_manager.read().await;
    let stats = ctx_mgr.get_statistics().await;

    Ok(Json(serde_json::json!({
        "current_context": stats.current_context.to_string(),
        "active_profile": stats.active_profile,
        "detection_method": format!("{:?}", stats.detection_method),
        "last_switch": stats.last_switch.to_rfc3339(),
    })))
}

/// Set current context
async fn set_context(
    State(state): State<ApiState>,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let context_str = payload["context"].as_str().ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "Missing 'context' field".to_string(),
                code: 400,
            }),
        )
    })?;

    let context_type: crate::context_policies::ContextType = context_str.parse().map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: format!("Invalid context: {}", context_str),
                code: 400,
            }),
        )
    })?;

    let ctx_mgr = state.context_policies_manager.read().await;
    ctx_mgr.set_context(context_type).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to set context: {}", e),
                code: 500,
            }),
        )
    })?;

    Ok(Json(serde_json::json!({ "status": "ok" })))
}

/// List all context profiles
async fn list_context_profiles(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let ctx_mgr = state.context_policies_manager.read().await;
    let profiles = ctx_mgr.list_profiles().await;

    let profiles_json: Vec<serde_json::Value> = profiles
        .iter()
        .map(|p| {
            serde_json::json!({
                "name": p.name,
                "context": p.context.to_string(),
                "description": p.description,
                "detection_method": format!("{:?}", p.detection_method),
                "rules": p.rules.iter().map(|r| serde_json::json!({
                    "id": r.id,
                    "name": r.name,
                    "description": r.description,
                    "enabled": r.enabled,
                })).collect::<Vec<_>>(),
                "priority": p.priority,
            })
        })
        .collect();

    Ok(Json(serde_json::json!({ "profiles": profiles_json })))
}

/// Get a specific context profile
async fn get_context_profile(
    State(state): State<ApiState>,
    Path(context): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let context_type: crate::context_policies::ContextType = context.parse().map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: format!("Invalid context: {}", context),
                code: 400,
            }),
        )
    })?;

    let ctx_mgr = state.context_policies_manager.read().await;
    match ctx_mgr.get_profile(&context_type).await {
        Some(profile) => Ok(Json(serde_json::json!({
            "name": profile.name,
            "context": profile.context.to_string(),
            "description": profile.description,
            "detection_method": format!("{:?}", profile.detection_method),
            "priority": profile.priority,
            "rules": profile.rules.iter().map(|r| serde_json::json!({
                "id": r.id,
                "name": r.name,
                "description": r.description,
                "enabled": r.enabled,
                "rule_type": format!("{:?}", r.rule_type),
            })).collect::<Vec<serde_json::Value>>(),
        }))),
        None => Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "Not Found".to_string(),
                message: format!("Profile '{}' not found", context),
                code: 404,
            }),
        )),
    }
}

/// Create a new context profile
async fn create_context_profile(
    State(state): State<ApiState>,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let name = payload["name"].as_str().ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "Missing 'name' field".to_string(),
                code: 400,
            }),
        )
    })?;

    let description = payload["description"].as_str().unwrap_or("Custom context");
    let priority = payload["priority"].as_u64().unwrap_or(5) as u32;

    let context_type: crate::context_policies::ContextType = name.parse().map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: format!("Invalid context name: {}", name),
                code: 400,
            }),
        )
    })?;

    let profile = crate::context_policies::ContextProfile {
        context: context_type,
        name: name.to_string(),
        description: description.to_string(),
        detection_method: crate::context_policies::DetectionMethod::Manual,
        rules: vec![],
        time_schedule: None,
        trigger_applications: vec![],
        trigger_network: None,
        priority,
    };

    let ctx_mgr = state.context_policies_manager.read().await;
    ctx_mgr.save_profile(profile).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to create profile: {}", e),
                code: 500,
            }),
        )
    })?;

    Ok(Json(serde_json::json!({ "status": "ok", "name": name })))
}

/// Delete a context profile
async fn delete_context_profile(
    State(state): State<ApiState>,
    Path(context): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let context_type: crate::context_policies::ContextType = context.parse().map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: format!("Invalid context: {}", context),
                code: 400,
            }),
        )
    })?;

    let ctx_mgr = state.context_policies_manager.read().await;
    ctx_mgr.delete_profile(&context_type).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to delete profile: {}", e),
                code: 500,
            }),
        )
    })?;

    Ok(Json(serde_json::json!({ "status": "ok" })))
}

/// Add a rule to a context profile
async fn add_context_rule(
    State(state): State<ApiState>,
    Path(context): Path<String>,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let context_type: crate::context_policies::ContextType = context.parse().map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: format!("Invalid context: {}", context),
                code: 400,
            }),
        )
    })?;

    let rule_type_str = payload["rule_type"].as_str().unwrap_or("");
    let value = payload["value"].as_str().unwrap_or("");

    let rule_type = match rule_type_str {
        "mode" => crate::context_policies::RuleType::SetExperienceMode(value.to_string()),
        "model" => crate::context_policies::RuleType::SetAiModel(value.to_string()),
        "notifications" => crate::context_policies::RuleType::DisableNotifications,
        "capture" => {
            crate::context_policies::RuleType::ScreenCapture(value == "true" || value == "on")
        }
        "channel" => crate::context_policies::RuleType::SetUpdateChannel(value.to_string()),
        "block-app" => crate::context_policies::RuleType::BlockApplication(value.to_string()),
        "privacy" => crate::context_policies::RuleType::SetPrivacyLevel(value.to_string()),
        _ => {
            return Err((
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Bad Request".to_string(),
                    message: format!("Unknown rule type: {}", rule_type_str),
                    code: 400,
                }),
            ));
        }
    };

    let rule = crate::context_policies::ContextRule {
        id: format!("{}-{}", context, rule_type_str),
        name: format!("{} rule", rule_type_str),
        description: format!("Set {} to {}", rule_type_str, value),
        rule_type,
        enabled: true,
        priority: 10,
    };

    let ctx_mgr = state.context_policies_manager.read().await;

    // Get profile, add rule, save
    if let Some(mut profile) = ctx_mgr.get_profile(&context_type).await {
        profile.rules.push(rule);
        ctx_mgr.save_profile(profile).await.map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: format!("Failed to add rule: {}", e),
                    code: 500,
                }),
            )
        })?;
        Ok(Json(serde_json::json!({ "status": "ok" })))
    } else {
        Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "Not Found".to_string(),
                message: format!("Profile '{}' not found", context),
                code: 404,
            }),
        ))
    }
}

/// Detect context automatically
async fn detect_context(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let ctx_mgr = state.context_policies_manager.read().await;
    match ctx_mgr.detect_context().await {
        Some(detected) => {
            // Auto-switch
            let switched = ctx_mgr.set_context(detected.clone()).await.is_ok();
            Ok(Json(serde_json::json!({
                "detected_context": detected.to_string(),
                "switched": switched,
            })))
        }
        None => Ok(Json(serde_json::json!({
            "detected_context": null,
            "switched": false,
        }))),
    }
}

/// Get rules for a context
async fn get_context_rules(
    State(state): State<ApiState>,
    Path(context): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let context_str = if context == "current" {
        let ctx_mgr = state.context_policies_manager.read().await;
        ctx_mgr.get_current_context().await.to_string()
    } else {
        context.clone()
    };

    let context_type: crate::context_policies::ContextType = context_str.parse().map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: format!("Invalid context: {}", context_str),
                code: 400,
            }),
        )
    })?;

    let ctx_mgr = state.context_policies_manager.read().await;
    let applied = ctx_mgr.apply_rules(&context_type).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to get rules: {}", e),
                code: 500,
            }),
        )
    })?;

    let rules_json: Vec<serde_json::Value> = applied
        .iter()
        .map(|r| {
            serde_json::json!({
                "rule_id": r.rule_id,
                "rule_name": r.rule_name,
                "action": r.action,
                "status": format!("{:?}", r.status),
            })
        })
        .collect();

    Ok(Json(serde_json::json!({ "applied_rules": rules_json })))
}

/// Get context statistics
async fn get_context_stats(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let ctx_mgr = state.context_policies_manager.read().await;
    let stats = ctx_mgr.get_statistics().await;

    Ok(Json(serde_json::json!({
        "current_context": stats.current_context.to_string(),
        "active_profile": stats.active_profile,
        "total_profiles": stats.total_profiles,
        "detection_method": format!("{:?}", stats.detection_method),
        "last_switch": stats.last_switch.to_rfc3339(),
    })))
}

// ==================== TELEMETRY HANDLERS ====================

/// Get telemetry statistics
async fn get_telemetry_stats(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let tel_mgr = state.telemetry_manager.read().await;
    let stats = tel_mgr.get_stats().await;
    Ok(Json(serde_json::to_value(&stats).unwrap_or_default()))
}

/// Get current telemetry consent level
async fn get_telemetry_consent(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let tel_mgr = state.telemetry_manager.read().await;
    let consent = tel_mgr.get_consent().await;
    Ok(Json(serde_json::json!({
        "consent_level": format!("{:?}", consent),
    })))
}

/// Set telemetry consent level
async fn set_telemetry_consent(
    State(state): State<ApiState>,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let level_str = payload["level"].as_str().ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "Missing 'level' field (disabled, minimal, full)".to_string(),
                code: 400,
            }),
        )
    })?;

    let level = match level_str.to_lowercase().as_str() {
        "disabled" | "off" | "none" => crate::telemetry::ConsentLevel::Disabled,
        "minimal" | "basic" => crate::telemetry::ConsentLevel::Minimal,
        "full" | "all" => crate::telemetry::ConsentLevel::Full,
        _ => {
            return Err((
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Bad Request".to_string(),
                    message: format!(
                        "Invalid consent level: {}. Use: disabled, minimal, full",
                        level_str
                    ),
                    code: 400,
                }),
            ));
        }
    };

    let tel_mgr = state.telemetry_manager.read().await;
    tel_mgr.set_consent(level).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to set consent: {}", e),
                code: 500,
            }),
        )
    })?;

    Ok(Json(serde_json::json!({ "status": "ok" })))
}

/// Get recent telemetry events
async fn get_telemetry_events(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let tel_mgr = state.telemetry_manager.read().await;
    let events = tel_mgr.get_recent_events(50).await;
    Ok(Json(serde_json::json!({
        "events": events,
        "count": events.len(),
    })))
}

/// Take a hardware snapshot
async fn take_hardware_snapshot(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let tel_mgr = state.telemetry_manager.read().await;
    match tel_mgr.record_hardware_snapshot().await {
        Ok(Some(snapshot)) => Ok(Json(serde_json::to_value(&snapshot).unwrap_or_default())),
        Ok(None) => Ok(Json(serde_json::json!({
            "message": "Hardware snapshots require 'full' consent level"
        }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to take snapshot: {}", e),
                code: 500,
            }),
        )),
    }
}

/// Export all telemetry data
async fn export_telemetry(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let tel_mgr = state.telemetry_manager.read().await;
    let data = tel_mgr.export_data().await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to export: {}", e),
                code: 500,
            }),
        )
    })?;
    Ok(Json(data))
}

/// Clear all telemetry data
async fn clear_telemetry(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let tel_mgr = state.telemetry_manager.read().await;
    tel_mgr.clear_all_data().await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to clear data: {}", e),
                code: 500,
            }),
        )
    })?;
    Ok(Json(
        serde_json::json!({ "status": "ok", "message": "All telemetry data cleared" }),
    ))
}

#[derive(Debug, Deserialize)]
struct IntentLogQuery {
    limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct IdentityListQuery {
    active: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct WorkspaceRunsQuery {
    limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct TeamRunPayload {
    objective: String,
    specialists: Vec<String>,
    approved: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct TeamRunsQuery {
    limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct RuntimeModePayload {
    mode: String,
    actor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ResourceRuntimePayload {
    profile: String,
    actor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TrustModePayload {
    enabled: bool,
    actor: Option<String>,
    consent_bundle: Option<String>,
    signature: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AutonomyStartPayload {
    actor: Option<String>,
    pin: String,
    ttl_minutes: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct AutonomyControlPayload {
    actor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct PromptShieldScanPayload {
    input: String,
}

#[derive(Debug, Deserialize)]
struct AlwaysOnRuntimePayload {
    enabled: bool,
    wake_word: Option<String>,
    actor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AlwaysOnClassifyPayload {
    input: String,
}

#[derive(Debug, Deserialize)]
struct ModelRoutingPayload {
    priority: String,
    preferred_model: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SelfDefenseRepairPayload {
    actor: Option<String>,
    auto_rollback: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct SensoryRuntimePayload {
    enabled: Option<bool>,
    audio_enabled: Option<bool>,
    screen_enabled: Option<bool>,
    camera_enabled: Option<bool>,
    capture_interval_seconds: Option<u64>,
    actor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SensorySnapshotPayload {
    include_screen: Option<bool>,
    audio_file: Option<String>,
    model: Option<String>,
}

#[derive(Debug, Deserialize)]
struct HeartbeatRuntimePayload {
    enabled: bool,
    interval_seconds: Option<u64>,
    actor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct HeartbeatTickPayload {
    actor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct VisionOcrPayload {
    source: Option<String>,
    capture_screen: Option<bool>,
    language: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SttStartPayload {
    enable: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct SttTranscribePayload {
    file: String,
    model: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SensoryVoiceSessionPayload {
    audio_file: Option<String>,
    prompt: Option<String>,
    include_screen: Option<bool>,
    screen_source: Option<String>,
    language: Option<String>,
    voice_model: Option<String>,
    playback: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct SensoryInterruptPayload {
    actor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SensoryTtsPayload {
    text: String,
    language: Option<String>,
    voice_model: Option<String>,
    playback: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct SensoryVisionPayload {
    source: Option<String>,
    capture_screen: Option<bool>,
    speak: Option<bool>,
    question: Option<String>,
    language: Option<String>,
    voice_model: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SensoryBenchmarkPayload {
    audio_file: Option<String>,
    prompt: Option<String>,
    include_screen: Option<bool>,
    screen_source: Option<String>,
    repeats: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct AddMemoryEntryPayload {
    kind: String,
    scope: Option<String>,
    tags: Option<Vec<String>>,
    source: Option<String>,
    importance: Option<u8>,
    content: String,
}

#[derive(Debug, Deserialize)]
struct ListMemoryEntriesQuery {
    limit: Option<usize>,
    scope: Option<String>,
    tag: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SearchMemoryEntriesQuery {
    q: Option<String>,
    limit: Option<usize>,
    scope: Option<String>,
    mode: Option<String>,
}

#[derive(Debug, Deserialize)]
struct MemoryGraphQuery {
    limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct MemoryMcpContextPayload {
    query: String,
    limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct ComputerUseActionPayload {
    action: String,
    x: Option<i32>,
    y: Option<i32>,
    button: Option<u8>,
    text: Option<String>,
    combo: Option<String>,
    dry_run: Option<bool>,
    actor: Option<String>,
}

// ==================== AGENT RUNTIME HANDLERS ====================

async fn plan_intent(
    State(state): State<ApiState>,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let description = payload["description"].as_str().ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "Missing 'description' field".to_string(),
                code: 400,
            }),
        )
    })?;

    let mgr = state.agent_runtime_manager.read().await;
    let intent = mgr.plan_intent(description).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to plan intent: {}", e),
                code: 500,
            }),
        )
    })?;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "intent": intent,
    })))
}

async fn apply_intent(
    State(state): State<ApiState>,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let intent_id = payload["intent_id"].as_str().ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "Missing 'intent_id' field".to_string(),
                code: 400,
            }),
        )
    })?;
    let approved = payload["approved"].as_bool().unwrap_or(false);

    let mgr = state.agent_runtime_manager.read().await;
    let intent = mgr.apply_intent(intent_id, approved).await.map_err(|e| {
        let status = if e.to_string().contains("Intent not found") {
            StatusCode::NOT_FOUND
        } else {
            StatusCode::INTERNAL_SERVER_ERROR
        };
        (
            status,
            Json(ApiError {
                error: status.canonical_reason().unwrap_or("Error").to_string(),
                message: e.to_string(),
                code: status.as_u16(),
            }),
        )
    })?;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "intent": intent,
    })))
}

async fn get_intent_status(
    State(state): State<ApiState>,
    Path(intent_id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    if let Some(intent) = mgr.get_intent(&intent_id).await {
        Ok(Json(serde_json::json!({
            "status": "ok",
            "intent": intent,
        })))
    } else {
        Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "Not Found".to_string(),
                message: format!("Intent '{}' not found", intent_id),
                code: 404,
            }),
        ))
    }
}

async fn validate_intent(
    State(state): State<ApiState>,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let to_validate = payload
        .get("intent")
        .cloned()
        .unwrap_or_else(|| payload.clone());
    let mgr = state.agent_runtime_manager.read().await;
    let report = mgr.validate_intent_payload(&to_validate);
    Ok(Json(serde_json::json!(report)))
}

async fn get_intent_log(
    State(state): State<ApiState>,
    Query(query): Query<IntentLogQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let limit = query.limit.unwrap_or(50).clamp(1, 500);
    let mgr = state.agent_runtime_manager.read().await;
    let entries = mgr.ledger_entries(limit).await;
    Ok(Json(serde_json::json!({
        "entries": entries,
        "count": entries.len(),
    })))
}

async fn export_intent_ledger(
    State(state): State<ApiState>,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let passphrase = payload["passphrase"].as_str().ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "Missing 'passphrase' field".to_string(),
                code: 400,
            }),
        )
    })?;
    let limit = payload["limit"].as_u64().unwrap_or(200).clamp(1, 5000) as usize;

    let mgr = state.agent_runtime_manager.read().await;
    let export = mgr
        .export_ledger_encrypted(passphrase, limit)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: format!("Failed to export ledger: {}", e),
                    code: 500,
                }),
            )
        })?;
    Ok(Json(export))
}

async fn issue_identity_token(
    State(state): State<ApiState>,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let agent = payload["agent"].as_str().ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "Missing 'agent' field".to_string(),
                code: 400,
            }),
        )
    })?;
    let cap = payload["cap"].as_str().ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "Missing 'cap' field".to_string(),
                code: 400,
            }),
        )
    })?;
    let ttl = payload["ttl"].as_u64().unwrap_or(60) as u32;
    let scope = payload["scope"].as_str();

    let mgr = state.agent_runtime_manager.read().await;
    let token = mgr.issue_token(agent, cap, ttl, scope).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to issue token: {}", e),
                code: 500,
            }),
        )
    })?;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "token": token,
    })))
}

async fn list_identity_tokens(
    State(state): State<ApiState>,
    Query(query): Query<IdentityListQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let active_only = query.active.unwrap_or(false);
    let mgr = state.agent_runtime_manager.read().await;
    let tokens = mgr.list_tokens(active_only).await;
    Ok(Json(serde_json::json!({
        "tokens": tokens,
        "count": tokens.len(),
    })))
}

async fn revoke_identity_token(
    State(state): State<ApiState>,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let token_id = payload["token_id"].as_str().ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "Missing 'token_id' field".to_string(),
                code: 400,
            }),
        )
    })?;

    let mgr = state.agent_runtime_manager.read().await;
    let token = mgr.revoke_token(token_id).await.map_err(|e| {
        let status = if e.to_string().contains("Token not found") {
            StatusCode::NOT_FOUND
        } else {
            StatusCode::INTERNAL_SERVER_ERROR
        };
        (
            status,
            Json(ApiError {
                error: status.canonical_reason().unwrap_or("Error").to_string(),
                message: e.to_string(),
                code: status.as_u16(),
            }),
        )
    })?;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "token": token,
    })))
}

async fn run_workspace(
    State(state): State<ApiState>,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let intent_id = payload["intent_id"].as_str().ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "Missing 'intent_id' field".to_string(),
                code: 400,
            }),
        )
    })?;

    let command = payload["command"].as_str();
    let isolation = payload["isolation"].as_str().unwrap_or("sandbox");
    let approved = payload["approved"].as_bool().unwrap_or(false);

    let mgr = state.agent_runtime_manager.read().await;
    let run = mgr
        .workspace_run(intent_id, command, isolation, approved)
        .await
        .map_err(|e| {
            let msg = e.to_string();
            let status = if msg.contains("not found") {
                StatusCode::NOT_FOUND
            } else if msg.contains("requires approval") {
                StatusCode::CONFLICT
            } else {
                StatusCode::INTERNAL_SERVER_ERROR
            };
            (
                status,
                Json(ApiError {
                    error: status.canonical_reason().unwrap_or("Error").to_string(),
                    message: msg,
                    code: status.as_u16(),
                }),
            )
        })?;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "run": run,
    })))
}

async fn list_workspace_runs(
    State(state): State<ApiState>,
    Query(query): Query<WorkspaceRunsQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let limit = query.limit.unwrap_or(20).clamp(1, 200);
    let mgr = state.agent_runtime_manager.read().await;
    let runs = mgr.list_workspace_runs(limit).await;
    Ok(Json(serde_json::json!({
        "runs": runs,
        "count": runs.len(),
    })))
}

async fn orchestrate_team_run(
    State(state): State<ApiState>,
    Json(payload): Json<TeamRunPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let run = mgr
        .orchestrate_team(
            &payload.objective,
            &payload.specialists,
            payload.approved.unwrap_or(false),
        )
        .await
        .map_err(|e| {
            let msg = e.to_string();
            let status = if msg.contains("required") {
                StatusCode::BAD_REQUEST
            } else {
                StatusCode::INTERNAL_SERVER_ERROR
            };
            (
                status,
                Json(ApiError {
                    error: status.canonical_reason().unwrap_or("Error").to_string(),
                    message: msg,
                    code: status.as_u16(),
                }),
            )
        })?;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "run": run,
    })))
}

async fn list_team_runs(
    State(state): State<ApiState>,
    Query(query): Query<TeamRunsQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let runs = mgr.list_team_runs(query.limit.unwrap_or(20)).await;
    Ok(Json(serde_json::json!({
        "runs": runs,
        "count": runs.len(),
    })))
}

async fn get_runtime_mode(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let mode = mgr.execution_mode().await;
    let mode_str = serde_json::to_value(&mode)
        .ok()
        .and_then(|v| v.as_str().map(|s| s.to_string()))
        .unwrap_or_else(|| "interactive".to_string());
    Ok(Json(serde_json::json!({
        "mode": mode_str
    })))
}

async fn set_runtime_mode(
    State(state): State<ApiState>,
    Json(payload): Json<RuntimeModePayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let mode = mgr
        .set_execution_mode(&payload.mode, payload.actor.as_deref())
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Bad Request".to_string(),
                    message: e.to_string(),
                    code: 400,
                }),
            )
        })?;
    let mode_str = serde_json::to_value(&mode)
        .ok()
        .and_then(|v| v.as_str().map(|s| s.to_string()))
        .unwrap_or_else(|| "interactive".to_string());
    Ok(Json(serde_json::json!({
        "status": "ok",
        "mode": mode_str
    })))
}

async fn get_resource_runtime(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let status = mgr.resource_runtime().await;
    Ok(Json(
        serde_json::to_value(status).unwrap_or_else(|_| serde_json::json!({})),
    ))
}

async fn set_resource_runtime(
    State(state): State<ApiState>,
    Json(payload): Json<ResourceRuntimePayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let status = mgr
        .set_resource_profile(&payload.profile, payload.actor.as_deref())
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Bad Request".to_string(),
                    message: e.to_string(),
                    code: 400,
                }),
            )
        })?;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "resources": status,
    })))
}

async fn get_always_on_runtime(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let status = mgr.always_on_runtime().await;
    Ok(Json(
        serde_json::to_value(status).unwrap_or_else(|_| serde_json::json!({})),
    ))
}

async fn set_always_on_runtime(
    State(state): State<ApiState>,
    Json(payload): Json<AlwaysOnRuntimePayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let status = mgr
        .set_always_on_runtime(
            payload.enabled,
            payload.wake_word.as_deref(),
            payload.actor.as_deref(),
        )
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Bad Request".to_string(),
                    message: e.to_string(),
                    code: 400,
                }),
            )
        })?;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "always_on": status,
    })))
}

async fn classify_always_on_runtime(
    State(state): State<ApiState>,
    Json(payload): Json<AlwaysOnClassifyPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    if payload.input.trim().is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "input is required".to_string(),
                code: 400,
            }),
        ));
    }

    let mgr = state.agent_runtime_manager.read().await;
    let report = mgr.classify_always_on_signal(&payload.input).await;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "classification": report
    })))
}

async fn route_runtime_model(
    State(state): State<ApiState>,
    Json(payload): Json<ModelRoutingPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let priority = payload.priority.trim();
    if priority.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "priority is required".to_string(),
                code: 400,
            }),
        ));
    }

    let mgr = state.agent_runtime_manager.read().await;
    let decision = mgr
        .route_model_for_priority(priority, payload.preferred_model.as_deref())
        .await;
    let _ = mgr
        .record_ledger_event(
            "runtime",
            "route_model",
            "model-router",
            serde_json::json!({
                "priority": decision.priority,
                "selected_tier": decision.selected_tier,
                "model_hint": decision.model_hint,
                "degraded": decision.degraded,
            }),
        )
        .await;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "decision": decision,
    })))
}

async fn get_self_defense_status(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let report = mgr.self_defense_status().await;
    Ok(Json(serde_json::json!(report)))
}

async fn run_self_defense_repair(
    State(state): State<ApiState>,
    Json(payload): Json<SelfDefenseRepairPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let report = mgr
        .run_self_defense_repair(
            payload.actor.as_deref(),
            payload.auto_rollback.unwrap_or(false),
        )
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "repair": report,
    })))
}

async fn get_sensory_runtime(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let status = mgr.sensory_capture_runtime().await;
    Ok(Json(
        serde_json::to_value(status).unwrap_or_else(|_| serde_json::json!({})),
    ))
}

async fn set_sensory_runtime(
    State(state): State<ApiState>,
    Json(payload): Json<SensoryRuntimePayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let enabled = payload.enabled.unwrap_or(true);
    let audio_enabled = payload.audio_enabled.unwrap_or(enabled);
    let screen_enabled = payload.screen_enabled.unwrap_or(enabled);
    let camera_enabled = payload.camera_enabled.unwrap_or(enabled);
    let capture_interval_seconds = payload
        .capture_interval_seconds
        .map(|value| value.clamp(5, 30));

    if enabled && (audio_enabled || screen_enabled || camera_enabled) {
        ensure_followalong_consent(&state).await?;
    }

    let mut stt_started = false;
    if enabled && audio_enabled {
        stt_started = Command::new("systemctl")
            .args(["start", DEFAULT_STT_SERVICE])
            .status()
            .await
            .map(|status| status.success())
            .unwrap_or(false);
    }

    let mgr = state.agent_runtime_manager.read().await;
    let status = mgr
        .set_sensory_capture_runtime(
            enabled,
            audio_enabled,
            screen_enabled,
            camera_enabled,
            capture_interval_seconds,
            payload.actor.as_deref(),
        )
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Bad Request".to_string(),
                    message: e.to_string(),
                    code: 400,
                }),
            )
        })?;
    let always_on = mgr.always_on_runtime().await;
    drop(mgr);

    let sensory_mgr = state.sensory_pipeline_manager.read().await;
    let overlay_mgr = state.overlay_manager.read().await.clone();
    sensory_mgr
        .sync_runtime(
            SensoryRuntimeSync {
                audio_enabled: status.audio_enabled,
                screen_enabled: status.screen_enabled,
                camera_enabled: status.camera_enabled,
                kill_switch_active: status.kill_switch_active,
                capture_interval_seconds: status.capture_interval_seconds,
                always_on_active: always_on.enabled,
                wake_word: Some(always_on.wake_word.as_str()),
            },
            &overlay_mgr,
        )
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "sensory": status,
        "stt_started": stt_started,
    })))
}

async fn capture_sensory_snapshot(
    State(state): State<ApiState>,
    Json(payload): Json<SensorySnapshotPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    ensure_followalong_consent(&state).await?;

    let mgr = state.agent_runtime_manager.read().await;
    let sensory = mgr.sensory_capture_runtime().await;
    if !sensory.enabled {
        return Err((
            StatusCode::CONFLICT,
            Json(ApiError {
                error: "Conflict".to_string(),
                message: "sensory capture runtime is not enabled".to_string(),
                code: 409,
            }),
        ));
    }

    let include_screen = payload.include_screen.unwrap_or(sensory.screen_enabled);
    let mut screen_path = None;
    if include_screen {
        let capture = ScreenCapture::new(PathBuf::from("/var/lib/lifeos/screenshots"));
        let screenshot = capture.capture().await.map_err(|e| {
            (
                StatusCode::BAD_GATEWAY,
                Json(ApiError {
                    error: "Bad Gateway".to_string(),
                    message: format!("Failed to capture screen: {}", e),
                    code: 502,
                }),
            )
        })?;
        screen_path = Some(screenshot.path.to_string_lossy().to_string());
    }

    let mut transcript = None;
    if let Some(audio_file) = payload
        .audio_file
        .as_deref()
        .map(|v| v.trim())
        .filter(|v| !v.is_empty())
    {
        if !std::path::Path::new(audio_file).exists() {
            return Err((
                StatusCode::NOT_FOUND,
                Json(ApiError {
                    error: "Not Found".to_string(),
                    message: format!("Audio file not found: {}", audio_file),
                    code: 404,
                }),
            ));
        }
        let (text, _binary) = transcribe_with_whisper(audio_file, payload.model.as_deref()).await?;
        transcript = Some(text);
    }

    let status = mgr
        .record_sensory_snapshot(screen_path.as_deref(), transcript.as_deref())
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "sensory": status,
        "snapshot": {
            "screen_path": screen_path,
            "transcript": transcript,
        }
    })))
}

async fn get_heartbeat_runtime(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let status = mgr.heartbeat_runtime().await;
    Ok(Json(
        serde_json::to_value(status).unwrap_or_else(|_| serde_json::json!({})),
    ))
}

async fn set_heartbeat_runtime(
    State(state): State<ApiState>,
    Json(payload): Json<HeartbeatRuntimePayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let status = mgr
        .set_heartbeat_runtime(
            payload.enabled,
            payload.interval_seconds,
            payload.actor.as_deref(),
        )
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Bad Request".to_string(),
                    message: e.to_string(),
                    code: 400,
                }),
            )
        })?;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "heartbeat": status,
    })))
}

async fn run_heartbeat_tick(
    State(state): State<ApiState>,
    Json(payload): Json<HeartbeatTickPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let report = mgr
        .run_proactive_heartbeat(payload.actor.as_deref())
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "tick": report,
    })))
}

async fn get_trust_mode(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let trust = mgr.trust_mode().await;
    Ok(Json(
        serde_json::to_value(trust).unwrap_or_else(|_| serde_json::json!({})),
    ))
}

async fn set_trust_mode(
    State(state): State<ApiState>,
    Json(payload): Json<TrustModePayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let trust = mgr
        .set_trust_mode(
            payload.enabled,
            payload.actor.as_deref(),
            payload.consent_bundle.as_deref(),
            payload.signature.as_deref(),
        )
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Bad Request".to_string(),
                    message: e.to_string(),
                    code: 400,
                }),
            )
        })?;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "trust_mode": trust,
    })))
}

async fn get_autonomy_session(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let autonomy_state = mgr.autonomy_session().await;
    Ok(Json(serde_json::json!(autonomy_state)))
}

async fn start_autonomy_session(
    State(state): State<ApiState>,
    Json(payload): Json<AutonomyStartPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let autonomy_state = mgr
        .start_autonomy_session(
            payload.actor.as_deref(),
            &payload.pin,
            payload.ttl_minutes.unwrap_or(30),
        )
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Bad Request".to_string(),
                    message: e.to_string(),
                    code: 400,
                }),
            )
        })?;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "autonomy": autonomy_state,
    })))
}

async fn stop_autonomy_session(
    State(state): State<ApiState>,
    Json(payload): Json<AutonomyControlPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let autonomy_state = mgr
        .stop_autonomy_session(payload.actor.as_deref())
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;
    Ok(Json(serde_json::json!({
        "status": "ok",
        "autonomy": autonomy_state,
    })))
}

async fn trigger_autonomy_kill_switch(
    State(state): State<ApiState>,
    Json(payload): Json<AutonomyControlPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let actor = payload.actor.as_deref();
    let runtime_mgr = state.agent_runtime_manager.read().await;
    let autonomy_state = runtime_mgr.trigger_kill_switch(actor).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )
    })?;

    let sensory_runtime = runtime_mgr
        .trigger_sensory_kill_switch(actor)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;
    drop(runtime_mgr);

    let sensory_mgr = state.sensory_pipeline_manager.read().await;
    let overlay_mgr = state.overlay_manager.read().await.clone();
    let sensory = sensory_mgr
        .trigger_kill_switch(&overlay_mgr)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "autonomy": autonomy_state,
        "sensory_runtime": sensory_runtime,
        "sensory": sensory,
        "execution_mode": "interactive",
        "trust_mode": "disabled",
    })))
}

async fn trigger_sensory_kill_switch(
    State(state): State<ApiState>,
    Json(payload): Json<SensoryInterruptPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let actor = payload.actor.as_deref();
    let runtime_mgr = state.agent_runtime_manager.read().await;
    let runtime = runtime_mgr
        .trigger_sensory_kill_switch(actor)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;
    drop(runtime_mgr);

    let sensory_mgr = state.sensory_pipeline_manager.read().await;
    let overlay_mgr = state.overlay_manager.read().await.clone();
    let sensory = sensory_mgr
        .trigger_kill_switch(&overlay_mgr)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "sensory_runtime": runtime,
        "sensory": sensory,
    })))
}

// ---------------------------------------------------------------------------
// Wake word training endpoints
// ---------------------------------------------------------------------------

const WAKE_WORD_SAMPLES_DIR: &str = "/var/lib/lifeos/models/rustpotter/samples";
const WAKE_WORD_MODEL_PATH: &str = "/var/lib/lifeos/models/rustpotter/axi.rpw";

/// Record a 2-second WAV sample of the user saying the wake word.
async fn record_wake_word_sample(
    State(_state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let samples_dir = std::path::Path::new(WAKE_WORD_SAMPLES_DIR);
    tokio::fs::create_dir_all(samples_dir).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "IO Error".into(),
                message: format!("Cannot create samples dir: {e}"),
                code: 500,
            }),
        )
    })?;

    let sample_id = uuid::Uuid::new_v4();
    let wav_path = samples_dir.join(format!("axi-{sample_id}.wav"));

    // Record 2.5 seconds of audio via pw-record
    let output = Command::new("pw-record")
        .args([
            "--rate",
            "16000",
            "--channels",
            "1",
            "--format",
            "s16",
            wav_path.to_string_lossy().as_ref(),
        ])
        .spawn();

    match output {
        Ok(mut child) => {
            // Let it record for 2.5 seconds, then kill
            tokio::time::sleep(std::time::Duration::from_millis(2500)).await;
            let _ = child.kill().await;
            let _ = child.wait().await;

            if wav_path.exists() {
                Ok(Json(serde_json::json!({
                    "status": "ok",
                    "sample_path": wav_path.to_string_lossy(),
                    "sample_id": sample_id.to_string(),
                })))
            } else {
                Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ApiError {
                        error: "Recording failed".into(),
                        message: "pw-record did not produce a WAV file".into(),
                        code: 500,
                    }),
                ))
            }
        }
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Recording failed".into(),
                message: format!("Cannot start pw-record: {e}"),
                code: 500,
            }),
        )),
    }
}

/// List existing wake word samples.
async fn list_wake_word_samples(
    State(_state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let samples_dir = std::path::Path::new(WAKE_WORD_SAMPLES_DIR);
    let mut samples = Vec::new();

    if samples_dir.exists() {
        let mut entries = tokio::fs::read_dir(samples_dir).await.map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "IO Error".into(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;

        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("wav") {
                let meta = tokio::fs::metadata(&path).await.ok();
                samples.push(serde_json::json!({
                    "name": path.file_name().and_then(|n| n.to_str()).unwrap_or(""),
                    "path": path.to_string_lossy(),
                    "size_bytes": meta.as_ref().map(|m| m.len()).unwrap_or(0),
                }));
            }
        }
    }

    let model_exists = std::path::Path::new(WAKE_WORD_MODEL_PATH).exists();

    Ok(Json(serde_json::json!({
        "samples": samples,
        "count": samples.len(),
        "model_exists": model_exists,
        "model_path": WAKE_WORD_MODEL_PATH,
    })))
}

/// Delete all wake word samples.
async fn delete_wake_word_samples(
    State(_state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let samples_dir = std::path::Path::new(WAKE_WORD_SAMPLES_DIR);
    if samples_dir.exists() {
        let _ = tokio::fs::remove_dir_all(samples_dir).await;
    }
    Ok(Json(
        serde_json::json!({ "status": "ok", "message": "Samples deleted" }),
    ))
}

/// Build a rustpotter .rpw wake word model from recorded samples.
#[cfg(feature = "wake-word")]
async fn train_wake_word_model(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    use rustpotter::{WakewordRef, WakewordRefBuildFromFiles, WakewordSave};

    let samples_dir = std::path::Path::new(WAKE_WORD_SAMPLES_DIR);
    if !samples_dir.exists() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "No samples".into(),
                message: "Record at least 3 samples first".into(),
                code: 400,
            }),
        ));
    }

    // Collect WAV files
    let mut wav_files: Vec<String> = Vec::new();
    let mut entries = tokio::fs::read_dir(samples_dir).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "IO Error".into(),
                message: e.to_string(),
                code: 500,
            }),
        )
    })?;
    while let Ok(Some(entry)) = entries.next_entry().await {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) == Some("wav") {
            wav_files.push(path.to_string_lossy().to_string());
        }
    }

    if wav_files.len() < 3 {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Not enough samples".into(),
                message: format!(
                    "Need at least 3 samples, got {}. Record more.",
                    wav_files.len()
                ),
                code: 400,
            }),
        ));
    }

    // Build the model in a blocking task (MFCC computation is CPU-heavy)
    let model_path = WAKE_WORD_MODEL_PATH.to_string();
    let result = tokio::task::spawn_blocking(move || {
        // Ensure parent dir exists
        if let Some(parent) = std::path::Path::new(&model_path).parent() {
            std::fs::create_dir_all(parent).ok();
        }

        let wakeword_ref = WakewordRef::new_from_sample_files(
            "axi".to_string(),
            None, // use default threshold
            None, // use default avg_threshold
            wav_files,
            16, // mfcc_size — standard value
        )
        .map_err(|e| format!("Failed to build wake word model: {e}"))?;

        wakeword_ref
            .save_to_file(&model_path)
            .map_err(|e| format!("Failed to save model: {e}"))?;

        Ok::<_, String>(model_path)
    })
    .await
    .map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Training failed".into(),
                message: format!("Task panicked: {e}"),
                code: 500,
            }),
        )
    })?;

    match result {
        Ok(path) => {
            // Hot-reload: signal the wake word detector to pick up the new model
            if let Some(ref detector) = state.wake_word_detector {
                detector.reload_model();
            }
            Ok(Json(serde_json::json!({
                "status": "ok",
                "model_path": path,
                "message": "Wake word model created and activated.",
            })))
        }
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Training failed".into(),
                message: e,
                code: 500,
            }),
        )),
    }
}

/// Stub when wake-word feature is not compiled.
#[cfg(not(feature = "wake-word"))]
async fn train_wake_word_model(
    State(_state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    Err((
        StatusCode::NOT_IMPLEMENTED,
        Json(ApiError {
            error: "Not available".into(),
            message: "wake-word feature not compiled".into(),
            code: 501,
        }),
    ))
}

async fn scan_prompt_shield(
    State(state): State<ApiState>,
    Json(payload): Json<PromptShieldScanPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let input = payload.input.trim();
    if input.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "input is required".to_string(),
                code: 400,
            }),
        ));
    }
    let mgr = state.agent_runtime_manager.read().await;
    let report = mgr.scan_prompt_shield(input);
    Ok(Json(serde_json::json!(report)))
}

async fn ensure_followalong_consent(state: &ApiState) -> Result<(), (StatusCode, Json<ApiError>)> {
    let manager = state.follow_along_manager.read().await;
    let config = manager.get_config().await;
    if config.consent_status == crate::follow_along::ConsentStatus::Granted {
        Ok(())
    } else {
        Err((
            StatusCode::FORBIDDEN,
            Json(ApiError {
                error: "Forbidden".to_string(),
                message: "FollowAlong consent is required for sensory capture".to_string(),
                code: 403,
            }),
        ))
    }
}

async fn get_workspace_awareness() -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)>
{
    let desktop = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_else(|_| "COSMIC".to_string());
    let workspace = std::env::var("COSMIC_WORKSPACE")
        .or_else(|_| std::env::var("LIFEOS_WORKSPACE_HINT"))
        .unwrap_or_else(|_| "default".to_string());
    let workspace_lc = workspace.to_lowercase();

    let habitat = if workspace_lc.contains("meeting") {
        "meeting"
    } else if workspace_lc.contains("focus") || workspace_lc.contains("flow") {
        "focus"
    } else if workspace_lc.contains("dev") || workspace_lc.contains("code") {
        "development"
    } else {
        "general"
    };

    let suggestions = match habitat {
        "meeting" => vec![
            "Enable meeting context preset (life meeting)".to_string(),
            "Prioritize concise summaries and action items".to_string(),
        ],
        "focus" => vec![
            "Enable focus preset (life focus)".to_string(),
            "Silence non-critical notifications".to_string(),
        ],
        "development" => vec![
            "Route assistant to implementation specialist".to_string(),
            "Prefer workspace-isolated execution for risky tasks".to_string(),
        ],
        _ => vec![
            "Use interactive execution mode".to_string(),
            "Offer cross-app memory context suggestions".to_string(),
        ],
    };

    Ok(Json(serde_json::json!({
        "desktop": desktop,
        "workspace": workspace,
        "habitat": habitat,
        "suggestions": suggestions
    })))
}

async fn add_memory_entry(
    State(state): State<ApiState>,
    Json(payload): Json<AddMemoryEntryPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let scope = payload
        .scope
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or("user");
    let tags = payload.tags.unwrap_or_default();
    let source = payload.source.as_deref();
    let importance = payload.importance.unwrap_or(50);

    let mgr = state.memory_plane_manager.read().await;
    let entry = mgr
        .add_entry(
            &payload.kind,
            scope,
            &tags,
            source,
            importance,
            &payload.content,
        )
        .await
        .map_err(|e| {
            let msg = e.to_string();
            let status =
                if msg.contains("required") || msg.contains("range") || msg.contains("too large") {
                    StatusCode::BAD_REQUEST
                } else {
                    StatusCode::INTERNAL_SERVER_ERROR
                };
            (
                status,
                Json(ApiError {
                    error: status.canonical_reason().unwrap_or("Error").to_string(),
                    message: msg,
                    code: status.as_u16(),
                }),
            )
        })?;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "entry": entry,
    })))
}

async fn list_memory_entries(
    State(state): State<ApiState>,
    Query(query): Query<ListMemoryEntriesQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let limit = query.limit.unwrap_or(20);
    let mgr = state.memory_plane_manager.read().await;
    let entries = mgr
        .list_entries(limit, query.scope.as_deref(), query.tag.as_deref())
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;

    Ok(Json(serde_json::json!({
        "entries": entries,
        "count": entries.len(),
    })))
}

async fn search_memory_entries(
    State(state): State<ApiState>,
    Query(query): Query<SearchMemoryEntriesQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let q = query.q.as_deref().unwrap_or("");
    let limit = query.limit.unwrap_or(10);
    let mode = MemorySearchMode::parse(query.mode.as_deref());
    let mgr = state.memory_plane_manager.read().await;
    let results = mgr
        .search_entries_with_mode(q, limit, query.scope.as_deref(), mode)
        .await
        .map_err(|e| {
            let msg = e.to_string();
            let status = if msg.contains("query is required") {
                StatusCode::BAD_REQUEST
            } else {
                StatusCode::INTERNAL_SERVER_ERROR
            };
            (
                status,
                Json(ApiError {
                    error: status.canonical_reason().unwrap_or("Error").to_string(),
                    message: msg,
                    code: status.as_u16(),
                }),
            )
        })?;

    Ok(Json(serde_json::json!({
        "results": results,
        "count": results.len(),
    })))
}

async fn delete_memory_entry(
    State(state): State<ApiState>,
    Path(entry_id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let deleted = mgr.delete_entry(&entry_id).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )
    })?;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "deleted": deleted,
        "entry_id": entry_id,
    })))
}

async fn get_memory_stats(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let stats = mgr.stats().await;
    Ok(Json(
        serde_json::to_value(stats).unwrap_or_else(|_| serde_json::json!({})),
    ))
}

async fn get_memory_graph(
    State(state): State<ApiState>,
    Query(query): Query<MemoryGraphQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let graph = mgr
        .correlation_graph(query.limit.unwrap_or(200))
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;
    Ok(Json(graph))
}

async fn get_memory_mcp_context(
    State(state): State<ApiState>,
    Json(payload): Json<MemoryMcpContextPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let context = mgr
        .mcp_context(&payload.query, payload.limit.unwrap_or(5))
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Bad Request".to_string(),
                    message: e.to_string(),
                    code: 400,
                }),
            )
        })?;
    Ok(Json(context))
}

async fn get_mcp_skills_tools() -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let registry_path = std::env::var("LIFEOS_SKILLS_REGISTRY")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/var/lib/lifeos/skills/registry.json"));

    let tools = if !registry_path.exists() {
        Vec::new()
    } else {
        let raw = tokio::fs::read_to_string(&registry_path)
            .await
            .map_err(|e| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ApiError {
                        error: "Internal Server Error".to_string(),
                        message: format!(
                            "Failed to read MCP skills registry '{}': {}",
                            registry_path.display(),
                            e
                        ),
                        code: 500,
                    }),
                )
            })?;

        let parsed: serde_json::Value = serde_json::from_str(&raw).map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: format!(
                        "Invalid MCP skills registry '{}': {}",
                        registry_path.display(),
                        e
                    ),
                    code: 500,
                }),
            )
        })?;

        parsed["skills"]
            .as_array()
            .map(|skills| {
                skills
                    .iter()
                    .map(|skill| {
                        let id = skill["id"].as_str().unwrap_or("unknown.skill");
                        let version = skill["version"].as_str().unwrap_or("0.0.0");
                        let trust = skill["trust_level"].as_str().unwrap_or("community");
                        serde_json::json!({
                            "name": format!("skills.{}", id.replace(['.', '-'], "_")),
                            "description": format!("Run skill {}@{}", id, version),
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "args": {
                                        "type": "array",
                                        "items": { "type": "string" }
                                    }
                                },
                                "additionalProperties": false
                            },
                            "metadata": {
                                "skill_id": id,
                                "version": version,
                                "trust_level": trust
                            }
                        })
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    };

    Ok(Json(serde_json::json!({
        "protocol": "mcp-tools/v1",
        "server": "lifeos-skills",
        "registry_path": registry_path.to_string_lossy(),
        "tools_count": tools.len(),
        "tools": tools,
    })))
}

async fn get_computer_use_status() -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)>
{
    let manager = ComputerUseManager::new();
    let status = manager.status().await;
    Ok(Json(
        serde_json::to_value(status).unwrap_or_else(|_| serde_json::json!({})),
    ))
}

async fn execute_computer_use_action(
    State(state): State<ApiState>,
    Json(payload): Json<ComputerUseActionPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let action = parse_computer_use_action(&payload)?;
    let manager = ComputerUseManager::new();
    let result = manager
        .execute(action.clone(), payload.dry_run.unwrap_or(false))
        .await
        .map_err(|e| {
            let msg = e.to_string();
            let status = if msg.contains("required")
                || msg.contains("Unsupported key")
                || msg.contains("exceeds")
                || msg.contains("No supported backend")
            {
                StatusCode::BAD_REQUEST
            } else {
                StatusCode::INTERNAL_SERVER_ERROR
            };
            (
                status,
                Json(ApiError {
                    error: status.canonical_reason().unwrap_or("Error").to_string(),
                    message: msg,
                    code: status.as_u16(),
                }),
            )
        })?;

    let actor = payload
        .actor
        .as_deref()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or("user://local/default");

    let runtime = state.agent_runtime_manager.read().await;
    let _ = runtime
        .record_ledger_event(
            "computer_use",
            "action",
            &payload.action,
            serde_json::json!({
                "actor": actor,
                "backend": result.backend,
                "dry_run": result.dry_run,
                "success": result.success,
                "command": result.command,
                "exit_code": result.exit_code,
            }),
        )
        .await;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "result": result,
    })))
}

fn parse_computer_use_action(
    payload: &ComputerUseActionPayload,
) -> Result<ComputerUseAction, (StatusCode, Json<ApiError>)> {
    let action_name = payload.action.trim().to_lowercase();
    match action_name.as_str() {
        "move" => {
            let x = payload.x.ok_or_else(|| {
                (
                    StatusCode::BAD_REQUEST,
                    Json(ApiError {
                        error: "Bad Request".to_string(),
                        message: "Missing 'x' for move action".to_string(),
                        code: 400,
                    }),
                )
            })?;
            let y = payload.y.ok_or_else(|| {
                (
                    StatusCode::BAD_REQUEST,
                    Json(ApiError {
                        error: "Bad Request".to_string(),
                        message: "Missing 'y' for move action".to_string(),
                        code: 400,
                    }),
                )
            })?;
            Ok(ComputerUseAction::Move { x, y })
        }
        "click" => Ok(ComputerUseAction::Click {
            button: payload.button.unwrap_or(1),
        }),
        "type" => {
            let text = payload
                .text
                .as_deref()
                .filter(|v| !v.trim().is_empty())
                .ok_or_else(|| {
                    (
                        StatusCode::BAD_REQUEST,
                        Json(ApiError {
                            error: "Bad Request".to_string(),
                            message: "Missing 'text' for type action".to_string(),
                            code: 400,
                        }),
                    )
                })?;
            Ok(ComputerUseAction::TypeText {
                text: text.to_string(),
            })
        }
        "key" => {
            let combo = payload
                .combo
                .as_deref()
                .filter(|v| !v.trim().is_empty())
                .ok_or_else(|| {
                    (
                        StatusCode::BAD_REQUEST,
                        Json(ApiError {
                            error: "Bad Request".to_string(),
                            message: "Missing 'combo' for key action".to_string(),
                            code: 400,
                        }),
                    )
                })?;
            Ok(ComputerUseAction::Key {
                combo: combo.to_string(),
            })
        }
        _ => Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "Unknown action. Use move|click|type|key".to_string(),
                code: 400,
            }),
        )),
    }
}

// ==================== VISUAL COMFORT HANDLERS ====================

/// Get visual comfort status
#[utoipa::path(
    get,
    path = "/api/v1/visual-comfort/status",
    responses(
        (status = 200, description = "Visual comfort status retrieved", body = VisualComfortStatusResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "visual-comfort"
)]
async fn get_visual_comfort_status(
    State(state): State<ApiState>,
) -> Result<Json<VisualComfortStatusResponse>, (StatusCode, Json<ApiError>)> {
    let manager = state.visual_comfort_manager.read().await;
    let state_data = manager.get_state().await;

    Ok(Json(VisualComfortStatusResponse {
        current_temperature: state_data.current_temperature,
        target_temperature: state_data.target_temperature,
        current_font_scale: state_data.current_font_scale,
        target_font_scale: state_data.target_font_scale,
        animations_enabled: state_data.animations_enabled,
        active_profile: state_data.active_profile.as_str().to_string(),
        session_duration_minutes: state_data.session_duration_minutes,
        is_night_time: state_data.is_night_time,
        transitioning: state_data.transitioning,
    }))
}

/// Get visual comfort configuration
#[utoipa::path(
    get,
    path = "/api/v1/visual-comfort/config",
    responses(
        (status = 200, description = "Visual comfort config retrieved", body = VisualComfortConfigResponse),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "visual-comfort"
)]
async fn get_visual_comfort_config(
    State(state): State<ApiState>,
) -> Result<Json<VisualComfortConfigResponse>, (StatusCode, Json<ApiError>)> {
    let manager = state.visual_comfort_manager.read().await;
    let config = manager.get_config().await;

    Ok(Json(VisualComfortConfigResponse {
        color_temperature_day: config.color_temperature_day,
        color_temperature_night: config.color_temperature_night,
        night_start_hour: config.night_start_hour,
        night_end_hour: config.night_end_hour,
        font_scale_base: config.font_scale_base,
        font_scale_max: config.font_scale_max,
        animation_reduction_threshold_minutes: config.animation_reduction_threshold_minutes,
        enabled: config.enabled,
    }))
}

/// Set comfort profile
#[utoipa::path(
    post,
    path = "/api/v1/visual-comfort/profile",
    request_body = SetProfileRequest,
    responses(
        (status = 200, description = "Profile set successfully"),
        (status = 400, description = "Invalid profile", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "visual-comfort"
)]
async fn set_visual_comfort_profile(
    State(state): State<ApiState>,
    Json(request): Json<SetProfileRequest>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let profile = ComfortProfile::from_str(&request.profile).ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: format!(
                    "Invalid profile '{}'. Must be: default, coding, reading, design, or meeting",
                    request.profile
                ),
                code: 400,
            }),
        )
    })?;

    let manager = state.visual_comfort_manager.read().await;
    manager.set_profile(profile).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to set profile: {}", e),
                code: 500,
            }),
        )
    })?;

    Ok(StatusCode::OK)
}

/// List available profiles
#[utoipa::path(
    get,
    path = "/api/v1/visual-comfort/profiles",
    responses(
        (status = 200, description = "Profiles listed", body = Vec<ProfileInfoResponse>),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "visual-comfort"
)]
async fn list_visual_comfort_profiles(
) -> Result<Json<Vec<ProfileInfoResponse>>, (StatusCode, Json<ApiError>)> {
    let profiles = vec![
        ProfileInfoResponse {
            name: "default".to_string(),
            display_name: "Default".to_string(),
            temperature: 6500,
            font_scale: 1.0,
            contrast_level: 1.0,
            animations_enabled: true,
        },
        ProfileInfoResponse {
            name: "coding".to_string(),
            display_name: "Coding".to_string(),
            temperature: 6000,
            font_scale: 0.95,
            contrast_level: 1.2,
            animations_enabled: false,
        },
        ProfileInfoResponse {
            name: "reading".to_string(),
            display_name: "Reading".to_string(),
            temperature: 4000,
            font_scale: 1.15,
            contrast_level: 1.0,
            animations_enabled: true,
        },
        ProfileInfoResponse {
            name: "design".to_string(),
            display_name: "Design".to_string(),
            temperature: 6500,
            font_scale: 1.0,
            contrast_level: 1.0,
            animations_enabled: true,
        },
        ProfileInfoResponse {
            name: "meeting".to_string(),
            display_name: "Meeting".to_string(),
            temperature: 4500,
            font_scale: 1.05,
            contrast_level: 0.9,
            animations_enabled: false,
        },
        ProfileInfoResponse {
            name: "balanced".to_string(),
            display_name: "Balanced".to_string(),
            temperature: 5500,
            font_scale: 1.0,
            contrast_level: 1.0,
            animations_enabled: true,
        },
        ProfileInfoResponse {
            name: "focus".to_string(),
            display_name: "Focus".to_string(),
            temperature: 6000,
            font_scale: 0.95,
            contrast_level: 1.2,
            animations_enabled: false,
        },
        ProfileInfoResponse {
            name: "vivid".to_string(),
            display_name: "Vivid".to_string(),
            temperature: 6500,
            font_scale: 1.0,
            contrast_level: 1.1,
            animations_enabled: true,
        },
    ];

    Ok(Json(profiles))
}

/// Set color temperature manually
#[utoipa::path(
    post,
    path = "/api/v1/visual-comfort/temperature",
    request_body = SetTemperatureRequest,
    responses(
        (status = 200, description = "Temperature set successfully"),
        (status = 400, description = "Invalid temperature", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "visual-comfort"
)]
async fn set_visual_comfort_temperature(
    State(state): State<ApiState>,
    Json(request): Json<SetTemperatureRequest>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    if request.temperature < 2500 || request.temperature > 6500 {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "Temperature must be between 2500K and 6500K".to_string(),
                code: 400,
            }),
        ));
    }

    let manager = state.visual_comfort_manager.read().await;
    manager
        .set_temperature(request.temperature)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Internal Server Error".to_string(),
                    message: format!("Failed to set temperature: {}", e),
                    code: 500,
                }),
            )
        })?;

    Ok(StatusCode::OK)
}

/// Set font scale
#[utoipa::path(
    post,
    path = "/api/v1/visual-comfort/font-scale",
    request_body = SetFontScaleRequest,
    responses(
        (status = 200, description = "Font scale set successfully"),
        (status = 400, description = "Invalid scale", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "visual-comfort"
)]
async fn set_visual_comfort_font_scale(
    State(state): State<ApiState>,
    Json(request): Json<SetFontScaleRequest>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    if request.scale < 0.8 || request.scale > 1.5 {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "Bad Request".to_string(),
                message: "Font scale must be between 0.8 and 1.5".to_string(),
                code: 400,
            }),
        ));
    }

    let manager = state.visual_comfort_manager.read().await;
    manager.set_font_scale(request.scale).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to set font scale: {}", e),
                code: 500,
            }),
        )
    })?;

    Ok(StatusCode::OK)
}

/// Enable/disable animations
#[utoipa::path(
    post,
    path = "/api/v1/visual-comfort/animations",
    request_body = SetAnimationsRequest,
    responses(
        (status = 200, description = "Animation state set successfully"),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "visual-comfort"
)]
async fn set_visual_comfort_animations(
    State(state): State<ApiState>,
    Json(request): Json<SetAnimationsRequest>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let manager = state.visual_comfort_manager.read().await;
    manager.set_animations(request.enabled).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to set animations: {}", e),
                code: 500,
            }),
        )
    })?;

    Ok(StatusCode::OK)
}

/// Reset visual comfort session
#[utoipa::path(
    post,
    path = "/api/v1/visual-comfort/reset",
    responses(
        (status = 200, description = "Session reset successfully"),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "visual-comfort"
)]
async fn reset_visual_comfort_session(
    State(state): State<ApiState>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let manager = state.visual_comfort_manager.read().await;
    manager.reset_session().await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Internal Server Error".to_string(),
                message: format!("Failed to reset session: {}", e),
                code: 500,
            }),
        )
    })?;

    Ok(StatusCode::OK)
}

// ==================== ACCESSIBILITY ENDPOINTS ====================

/// Run WCAG 2.2 AA accessibility audit
#[utoipa::path(
    get,
    path = "/api/v1/accessibility/audit",
    responses(
        (status = 200, description = "Accessibility audit completed", body = serde_json::Value),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "accessibility"
)]
async fn run_accessibility_audit(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let manager = state.accessibility_manager.read().await;
    let results = manager.audit_default_themes();

    let results_json: Vec<serde_json::Value> = results
        .iter()
        .map(|r| {
            serde_json::json!({
                "theme_name": r.theme_name,
                "total_pairs": r.total_pairs,
                "passing_pairs": r.passing_pairs,
                "failing_pairs": r.failing_pairs,
                "overall_pass": r.overall_pass,
                "issues": r.issues,
            })
        })
        .collect();

    Ok(Json(serde_json::json!({
        "results": results_json,
        "timestamp": chrono::Utc::now().to_rfc3339(),
    })))
}

/// Get current accessibility settings
#[utoipa::path(
    get,
    path = "/api/v1/accessibility/settings",
    responses(
        (status = 200, description = "Accessibility settings retrieved", body = serde_json::Value),
        (status = 500, description = "Internal server error", body = ApiError),
    ),
    tag = "accessibility"
)]
async fn get_accessibility_settings(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let manager = state.accessibility_manager.read().await;
    let settings = manager.get_settings();

    Ok(Json(serde_json::json!({
        "high_contrast": settings.high_contrast,
        "reduce_motion": settings.reduce_motion,
        "font_scale": settings.font_scale,
        "min_font_size": settings.min_font_size,
        "screen_reader_support": settings.screen_reader_support,
        "keyboard_navigation": settings.keyboard_navigation,
    })))
}

// ==================== TASK QUEUE ENDPOINTS ====================

async fn post_task(
    State(state): State<ApiState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let objective = body
        .get("objective")
        .and_then(|o| o.as_str())
        .unwrap_or("")
        .to_string();

    if objective.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "bad_request".into(),
                message: "objective is required".into(),
                code: 400,
            }),
        ));
    }

    let priority = body
        .get("priority")
        .and_then(|p| serde_json::from_value(p.clone()).ok())
        .unwrap_or(crate::task_queue::TaskPriority::Normal);

    let source = body
        .get("source")
        .and_then(|s| s.as_str())
        .unwrap_or("api")
        .to_string();

    let create = crate::task_queue::TaskCreate {
        objective,
        priority,
        source,
        max_attempts: body
            .get("max_attempts")
            .and_then(|m| m.as_u64())
            .unwrap_or(3) as u32,
    };

    match state.task_queue.enqueue(create) {
        Ok(task) => Ok(Json(serde_json::to_value(task).unwrap_or_default())),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "enqueue_failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

async fn get_tasks(
    State(state): State<ApiState>,
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let limit = params
        .get("limit")
        .and_then(|l| l.parse::<u32>().ok())
        .unwrap_or(50);

    let status_filter = params
        .get("status")
        .and_then(|s| serde_json::from_value(serde_json::Value::String(s.clone())).ok());

    match state.task_queue.list(status_filter, limit) {
        Ok(tasks) => Ok(Json(
            serde_json::json!({ "tasks": tasks, "count": tasks.len() }),
        )),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "list_failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

async fn get_tasks_summary(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    match state.task_queue.summary() {
        Ok(summary) => Ok(Json(summary)),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "summary_failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

async fn get_task_by_id(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    match state.task_queue.get(&id) {
        Ok(Some(task)) => Ok(Json(serde_json::to_value(task).unwrap_or_default())),
        Ok(None) => Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "not_found".into(),
                message: format!("Task {} not found", id),
                code: 404,
            }),
        )),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "get_failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

async fn cancel_task(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    match state.task_queue.cancel(&id) {
        Ok(()) => Ok(Json(serde_json::json!({"status": "cancelled", "id": id}))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "cancel_failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

async fn get_supervisor_status(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let running = state.supervisor.is_running();
    let summary = state.task_queue.summary().unwrap_or_default();
    Ok(Json(serde_json::json!({
        "running": running,
        "queue": summary,
    })))
}

async fn get_supervisor_metrics(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let metrics = state.supervisor.metrics();
    Ok(Json(serde_json::to_value(metrics).unwrap_or_default()))
}

// ==================== PROMETHEUS METRICS ENDPOINT ====================

async fn handle_metrics(
    State(state): State<ApiState>,
) -> (StatusCode, [(&'static str, &'static str); 1], String) {
    let mut output = String::new();

    // Task metrics from task_queue
    if let Ok(summary) = state.task_queue.summary() {
        output.push_str("# HELP lifeos_tasks_total Total tasks by status\n");
        output.push_str("# TYPE lifeos_tasks_total gauge\n");
        if let Some(obj) = summary.as_object() {
            for (status, count) in obj {
                let n = count.as_i64().unwrap_or(0);
                output.push_str(&format!(
                    "lifeos_tasks_total{{status=\"{}\"}} {}\n",
                    status, n
                ));
            }
        }
    }

    // System metrics from SystemMonitor
    if let Ok(metrics) = state.system_monitor.write().await.collect_metrics() {
        output.push_str("# HELP lifeos_cpu_usage_percent CPU usage\n");
        output.push_str("# TYPE lifeos_cpu_usage_percent gauge\n");
        output.push_str(&format!(
            "lifeos_cpu_usage_percent {:.1}\n",
            metrics.cpu_usage
        ));

        output.push_str("# HELP lifeos_memory_used_bytes Memory used in bytes\n");
        output.push_str("# TYPE lifeos_memory_used_bytes gauge\n");
        output.push_str(&format!(
            "lifeos_memory_used_bytes {}\n",
            metrics.memory_used_mb * 1024 * 1024
        ));

        output.push_str("# HELP lifeos_memory_usage_percent Memory usage percent\n");
        output.push_str("# TYPE lifeos_memory_usage_percent gauge\n");
        output.push_str(&format!(
            "lifeos_memory_usage_percent {:.1}\n",
            metrics.memory_usage
        ));

        output.push_str("# HELP lifeos_disk_used_percent Disk usage percent\n");
        output.push_str("# TYPE lifeos_disk_used_percent gauge\n");
        output.push_str(&format!(
            "lifeos_disk_used_percent {:.1}\n",
            metrics.disk_usage
        ));
    }

    // Supervisor reliability
    let reliability = state.supervisor.reliability_stats();
    output.push_str("# HELP lifeos_supervisor_tasks_total Total supervisor tasks\n");
    output.push_str("# TYPE lifeos_supervisor_tasks_total gauge\n");
    output.push_str(&format!(
        "lifeos_supervisor_tasks_total {}\n",
        reliability.total_tasks
    ));
    output.push_str("# HELP lifeos_supervisor_success_rate Success rate (0.0-1.0)\n");
    output.push_str("# TYPE lifeos_supervisor_success_rate gauge\n");
    output.push_str(&format!(
        "lifeos_supervisor_success_rate {:.3}\n",
        reliability.success_rate
    ));

    (
        StatusCode::OK,
        [("content-type", "text/plain; version=0.0.4; charset=utf-8")],
        output,
    )
}

// ==================== SCHEDULED TASKS ENDPOINTS ====================

async fn get_scheduled_tasks(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    match state.scheduled_tasks.list() {
        Ok(tasks) => Ok(Json(serde_json::json!({ "tasks": tasks }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "list_failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

async fn post_scheduled_task(
    State(state): State<ApiState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let objective = body
        .get("objective")
        .and_then(|o| o.as_str())
        .unwrap_or("")
        .to_string();

    if objective.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "bad_request".into(),
                message: "objective is required".into(),
                code: 400,
            }),
        ));
    }

    let schedule_type = body
        .get("schedule_type")
        .and_then(|s| s.as_str())
        .unwrap_or("interval");

    let schedule_param = body
        .get("schedule_param")
        .and_then(|s| s.as_str())
        .unwrap_or("30")
        .to_string();

    let schedule = match schedule_type {
        "daily" => crate::scheduled_tasks::Schedule::Daily {
            time: schedule_param,
        },
        "weekly" => {
            let days = body
                .get("days")
                .and_then(|d| serde_json::from_value::<Vec<u8>>(d.clone()).ok())
                .unwrap_or_else(|| vec![0, 1, 2, 3, 4]); // Mon-Fri default
            crate::scheduled_tasks::Schedule::Weekly {
                days,
                time: schedule_param,
            }
        }
        _ => {
            let minutes: u32 = schedule_param.parse().unwrap_or(30);
            crate::scheduled_tasks::Schedule::Interval { minutes }
        }
    };

    match state.scheduled_tasks.add(&objective, schedule) {
        Ok(task) => Ok(Json(serde_json::to_value(task).unwrap_or_default())),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "add_failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

async fn delete_scheduled_task(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    match state.scheduled_tasks.delete(&id) {
        Ok(()) => Ok(Json(serde_json::json!({ "deleted": true }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "delete_failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

async fn toggle_scheduled_task(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let enabled = body
        .get("enabled")
        .and_then(|e| e.as_bool())
        .unwrap_or(true);
    match state.scheduled_tasks.set_enabled(&id, enabled) {
        Ok(()) => Ok(Json(serde_json::json!({ "enabled": enabled }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "toggle_failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

// ==================== HEALTH TRACKING ENDPOINTS ====================

async fn get_health_tracking(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let tracker = state.health_tracker.lock().await;
    let health_state = tracker.state();
    let summary = tracker.daily_summary();
    Ok(Json(serde_json::json!({
        "state": health_state,
        "summary": summary,
    })))
}

async fn post_health_break(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mut tracker = state.health_tracker.lock().await;
    tracker.record_break();
    Ok(Json(
        serde_json::json!({ "break_recorded": true, "break_count": tracker.state().break_count }),
    ))
}

async fn get_health_reminders(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mut tracker = state.health_tracker.lock().await;
    let reminders = tracker.check_reminders();
    Ok(Json(serde_json::json!({ "reminders": reminders })))
}

// ==================== PROACTIVE ALERTS ENDPOINT ====================

async fn get_proactive_alerts(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let alerts = crate::proactive::check_all(Some(&state.task_queue)).await;
    Ok(Json(serde_json::json!({ "alerts": alerts })))
}

// ==================== EMAIL ENDPOINTS ====================

async fn get_email_status() -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    Ok(Json(serde_json::json!({
        "configured": crate::email_bridge::EmailConfig::is_configured(),
    })))
}

async fn get_email_inbox(
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let limit: usize = params
        .get("limit")
        .and_then(|l| l.parse().ok())
        .unwrap_or(10);

    match crate::email_bridge::list_recent_emails(limit).await {
        Ok(emails) => Ok(Json(serde_json::json!({ "emails": emails }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "email_fetch_failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

async fn post_email_send(
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let to = body.get("to").and_then(|t| t.as_str()).unwrap_or("");
    let subject = body.get("subject").and_then(|s| s.as_str()).unwrap_or("");
    let email_body = body.get("body").and_then(|b| b.as_str()).unwrap_or("");

    if to.is_empty() || subject.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "bad_request".into(),
                message: "to and subject are required".into(),
                code: 400,
            }),
        ));
    }

    match crate::email_bridge::send_email(to, subject, email_body).await {
        Ok(()) => Ok(Json(serde_json::json!({ "sent": true }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "email_send_failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

// ==================== CALENDAR ENDPOINTS ====================

async fn get_calendar_today(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    match state.calendar.today() {
        Ok(events) => Ok(Json(serde_json::json!({ "events": events }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "calendar_error".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

async fn get_calendar_upcoming(
    State(state): State<ApiState>,
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let days: u32 = params.get("days").and_then(|d| d.parse().ok()).unwrap_or(7);
    match state.calendar.upcoming(days) {
        Ok(events) => Ok(Json(serde_json::json!({ "events": events, "days": days }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "calendar_error".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

async fn post_calendar_event(
    State(state): State<ApiState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let title = body.get("title").and_then(|t| t.as_str()).unwrap_or("");
    let start_time = body
        .get("start_time")
        .and_then(|s| s.as_str())
        .unwrap_or("");

    if title.is_empty() || start_time.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "bad_request".into(),
                message: "title and start_time are required".into(),
                code: 400,
            }),
        ));
    }

    let end_time = body.get("end_time").and_then(|e| e.as_str());
    let description = body
        .get("description")
        .and_then(|d| d.as_str())
        .unwrap_or("");
    let reminder_minutes = body
        .get("reminder_minutes")
        .and_then(|r| r.as_i64())
        .map(|r| r as i32);

    match state
        .calendar
        .add_event(title, start_time, end_time, description, reminder_minutes)
    {
        Ok(event) => Ok(Json(serde_json::to_value(event).unwrap_or_default())),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "calendar_error".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

async fn delete_calendar_event(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    match state.calendar.delete(&id) {
        Ok(()) => Ok(Json(serde_json::json!({ "deleted": true }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "calendar_error".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

async fn get_calendar_reminders(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    match state.calendar.due_reminders() {
        Ok(events) => Ok(Json(serde_json::json!({ "reminders": events }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "calendar_error".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

// ==================== FILE MANAGEMENT ENDPOINTS ====================

async fn get_file_search(
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let pattern = params.get("pattern").cloned().unwrap_or_default();
    let path = params
        .get("path")
        .cloned()
        .unwrap_or_else(|| ".".to_string());

    if pattern.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "bad_request".into(),
                message: "pattern query param is required".into(),
                code: 400,
            }),
        ));
    }

    let output = tokio::process::Command::new("find")
        .args([
            &path,
            "-name",
            &pattern,
            "-not",
            "-path",
            "*/target/*",
            "-not",
            "-path",
            "*/.git/*",
            "-type",
            "f",
        ])
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let files: Vec<&str> = stdout.lines().take(100).collect();
            Ok(Json(
                serde_json::json!({ "files": files, "count": files.len() }),
            ))
        }
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "search_failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

async fn get_file_content_search(
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let query = params.get("query").cloned().unwrap_or_default();
    let path = params
        .get("path")
        .cloned()
        .unwrap_or_else(|| ".".to_string());

    if query.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "bad_request".into(),
                message: "query param is required".into(),
                code: 400,
            }),
        ));
    }

    let output = tokio::process::Command::new("grep")
        .args([
            "-rl",
            "--include=*.rs",
            "--include=*.toml",
            "--include=*.md",
            "--include=*.json",
            "--include=*.yaml",
            "--include=*.yml",
            "--include=*.txt",
            "--include=*.sh",
            &query,
            &path,
        ])
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let files: Vec<&str> = stdout.lines().take(50).collect();
            Ok(Json(
                serde_json::json!({ "files": files, "count": files.len(), "query": query }),
            ))
        }
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "search_failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

// ==================== TIMEZONE SETTINGS (AM.3) ====================

/// GET /api/v1/settings/timezone — returns current timezone
async fn get_timezone() -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let tz = crate::time_context::get_user_timezone();
    Ok(Json(serde_json::json!({
        "timezone": tz,
        "valid": crate::time_context::is_valid_iana_timezone(&tz),
    })))
}

/// POST /api/v1/settings/timezone — set timezone (body: {"timezone": "America/Mexico_City"})
async fn post_timezone(
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let tz = body.get("timezone").and_then(|t| t.as_str()).unwrap_or("");

    if tz.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "bad_request".into(),
                message: "timezone is required".into(),
                code: 400,
            }),
        ));
    }

    if !crate::time_context::is_valid_iana_timezone(tz) {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "invalid_timezone".into(),
                message: format!(
                    "'{}' is not a valid IANA timezone (e.g., America/Mexico_City)",
                    tz
                ),
                code: 400,
            }),
        ));
    }

    match crate::time_context::save_user_timezone(tz) {
        Ok(()) => Ok(Json(serde_json::json!({
            "timezone": tz,
            "saved": true,
        }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "save_failed".into(),
                message: format!("Failed to save timezone: {}", e),
                code: 500,
            }),
        )),
    }
}

// ==================== API KEYS MANAGEMENT ====================

/// Get the status of configured API keys (configured/not configured, never the actual values).
async fn get_api_keys_status() -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let keys = [
        "CEREBRAS_API_KEY",
        "GROQ_API_KEY",
        "OPENROUTER_API_KEY",
        "LIFEOS_TELEGRAM_BOT_TOKEN",
        "LIFEOS_TELEGRAM_CHAT_ID",
        "LIFEOS_EMAIL_IMAP_HOST",
        "LIFEOS_WHATSAPP_TOKEN",
        "LIFEOS_MATRIX_ACCESS_TOKEN",
        "LIFEOS_SIGNAL_PHONE",
        "LIFEOS_HA_URL",
    ];

    let status: serde_json::Map<String, serde_json::Value> = keys
        .iter()
        .map(|&k| {
            let configured = std::env::var(k).map(|v| !v.is_empty()).unwrap_or(false);
            (k.to_string(), serde_json::json!(configured))
        })
        .collect();

    Ok(Json(serde_json::json!({ "keys": status })))
}

/// Save API keys to the user env file and reload them into the process.
async fn post_api_keys(
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let allowed_keys = [
        "CEREBRAS_API_KEY",
        "GROQ_API_KEY",
        "OPENROUTER_API_KEY",
        "LIFEOS_TELEGRAM_BOT_TOKEN",
        "LIFEOS_TELEGRAM_CHAT_ID",
        "LIFEOS_EMAIL_IMAP_HOST",
        "LIFEOS_EMAIL_IMAP_USER",
        "LIFEOS_EMAIL_IMAP_PASS",
        "LIFEOS_EMAIL_SMTP_HOST",
        "LIFEOS_WHATSAPP_TOKEN",
        "LIFEOS_WHATSAPP_PHONE_ID",
        "LIFEOS_WHATSAPP_VERIFY_TOKEN",
        "LIFEOS_WHATSAPP_ALLOWED_NUMBERS",
        "LIFEOS_MATRIX_HOMESERVER",
        "LIFEOS_MATRIX_USER_ID",
        "LIFEOS_MATRIX_ACCESS_TOKEN",
        "LIFEOS_MATRIX_ROOM_IDS",
        "LIFEOS_SIGNAL_CLI_URL",
        "LIFEOS_SIGNAL_PHONE",
        "LIFEOS_SIGNAL_ALLOWED_NUMBERS",
        "LIFEOS_HA_URL",
        "LIFEOS_HA_TOKEN",
    ];

    // Determine writable env file path
    let env_path = if std::path::Path::new("/etc/lifeos/llm-providers.env").exists() {
        std::path::PathBuf::from("/etc/lifeos/llm-providers.env")
    } else {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
        std::path::PathBuf::from(format!("{}/.config/lifeos/llm-providers.env", home))
    };

    // Read existing file content
    let existing = tokio::fs::read_to_string(&env_path)
        .await
        .unwrap_or_default();

    let mut lines: Vec<String> = existing.lines().map(String::from).collect();
    let mut updated_count = 0u32;

    if let Some(keys_obj) = body.get("keys").and_then(|k| k.as_object()) {
        for (key, value) in keys_obj {
            // Only allow whitelisted keys to prevent arbitrary env injection
            if !allowed_keys.contains(&key.as_str()) {
                continue;
            }
            let val_str = value.as_str().unwrap_or("").trim().to_string();

            // Update or append the key in the file
            let key_prefix = format!("{}=", key);
            let mut found = false;
            for line in &mut lines {
                if line.starts_with(&key_prefix) {
                    *line = format!("{}={}", key, val_str);
                    found = true;
                    break;
                }
            }
            if !found {
                lines.push(format!("{}={}", key, val_str));
            }

            // Also set in current process env for immediate effect
            if !val_str.is_empty() {
                // SAFETY: single-threaded write path, keys are whitelisted
                unsafe { std::env::set_var(key, &val_str) };
            }
            updated_count += 1;
        }
    }

    // Write back
    if let Some(parent) = env_path.parent() {
        let _ = tokio::fs::create_dir_all(parent).await;
    }
    let content = lines.join("\n") + "\n";
    if let Err(e) = tokio::fs::write(&env_path, &content).await {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "write_failed".into(),
                message: format!("Failed to write {}: {}", env_path.display(), e),
                code: 500,
            }),
        ));
    }

    Ok(Json(serde_json::json!({
        "updated": updated_count,
        "path": env_path.display().to_string(),
        "note": "Keys guardadas y activas. Los proveedores LLM funcionan inmediatamente."
    })))
}

// ==================== GAME GUARD ENDPOINTS ====================

async fn get_game_guard_status(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    if let Some(ref gg) = state.game_guard {
        let guard = gg.read().await;
        let gs = guard.state().await;
        let gpu_layers = std::env::var("LIFEOS_AI_GPU_LAYERS").unwrap_or_else(|_| "-1".into());
        Ok(Json(serde_json::json!({
            "guard_enabled": gs.guard_enabled,
            "assistant_enabled": gs.assistant_enabled,
            "llm_mode": format!("{:?}", gs.llm_mode).to_lowercase(),
            "gpu_layers": gpu_layers,
            "game_detected": gs.game_detected,
            "game_name": gs.game_name,
            "game_pid": gs.game_pid,
            "game_window_title": gs.game_window_title,
            "last_check": gs.last_check.to_rfc3339(),
        })))
    } else {
        // Fallback: read from env vars
        let enabled = std::env::var("LIFEOS_AI_GAME_GUARD")
            .map(|v| v != "false" && v != "0")
            .unwrap_or(true);
        let assistant_enabled = std::env::var("LIFEOS_AI_GAME_ASSISTANT")
            .map(|v| v != "false" && v != "0")
            .unwrap_or(true);
        let gpu_layers = std::env::var("LIFEOS_AI_GPU_LAYERS").unwrap_or_else(|_| "-1".into());
        let llm_mode = if gpu_layers == "0" { "cpu" } else { "gpu" };

        Ok(Json(serde_json::json!({
            "guard_enabled": enabled,
            "assistant_enabled": assistant_enabled,
            "llm_mode": llm_mode,
            "gpu_layers": gpu_layers,
            "game_detected": false,
            "game_name": null,
        })))
    }
}

async fn post_game_guard_toggle(
    State(state): State<ApiState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let enabled = body["enabled"].as_bool().unwrap_or(true);
    if let Some(ref gg) = state.game_guard {
        let guard = gg.read().await;
        guard.set_enabled(enabled).await;
    }
    unsafe {
        std::env::set_var(
            "LIFEOS_AI_GAME_GUARD",
            if enabled { "true" } else { "false" },
        )
    };
    Ok(Json(serde_json::json!({ "guard_enabled": enabled })))
}

async fn post_game_assistant_toggle(
    State(state): State<ApiState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let enabled = body["enabled"].as_bool().unwrap_or(true);
    if let Some(ref gg) = state.game_guard {
        let guard = gg.read().await;
        guard.set_assistant_enabled(enabled).await;
    }
    unsafe {
        std::env::set_var(
            "LIFEOS_AI_GAME_ASSISTANT",
            if enabled { "true" } else { "false" },
        )
    };
    Ok(Json(serde_json::json!({ "assistant_enabled": enabled })))
}

// ==================== MESSAGING CHANNELS ====================

async fn get_messaging_channels() -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let channels = vec![
        serde_json::json!({
            "id": "telegram",
            "name": "Telegram",
            "enabled": cfg!(feature = "telegram"),
            "configured": std::env::var("LIFEOS_TELEGRAM_BOT_TOKEN").map(|v| !v.is_empty()).unwrap_or(false),
            "status": if std::env::var("LIFEOS_TELEGRAM_BOT_TOKEN").map(|v| !v.is_empty()).unwrap_or(false) { "active" } else { "not_configured" },
        }),
        serde_json::json!({
            "id": "whatsapp",
            "name": "WhatsApp",
            "enabled": cfg!(feature = "whatsapp"),
            "configured": std::env::var("LIFEOS_WHATSAPP_TOKEN").map(|v| !v.is_empty()).unwrap_or(false),
            "status": if std::env::var("LIFEOS_WHATSAPP_TOKEN").map(|v| !v.is_empty()).unwrap_or(false) { "active" } else { "not_configured" },
        }),
        serde_json::json!({
            "id": "matrix",
            "name": "Matrix/Element",
            "enabled": cfg!(feature = "matrix"),
            "configured": std::env::var("LIFEOS_MATRIX_ACCESS_TOKEN").map(|v| !v.is_empty()).unwrap_or(false),
            "status": if std::env::var("LIFEOS_MATRIX_ACCESS_TOKEN").map(|v| !v.is_empty()).unwrap_or(false) { "active" } else { "not_configured" },
        }),
        serde_json::json!({
            "id": "signal",
            "name": "Signal",
            "enabled": cfg!(feature = "signal"),
            "configured": std::env::var("LIFEOS_SIGNAL_PHONE").map(|v| !v.is_empty()).unwrap_or(false),
            "status": if std::env::var("LIFEOS_SIGNAL_PHONE").map(|v| !v.is_empty()).unwrap_or(false) { "active" } else { "not_configured" },
        }),
        serde_json::json!({
            "id": "homeassistant",
            "name": "Home Assistant",
            "enabled": cfg!(feature = "homeassistant"),
            "configured": std::env::var("LIFEOS_HA_URL").map(|v| !v.is_empty()).unwrap_or(false),
            "status": if std::env::var("LIFEOS_HA_URL").map(|v| !v.is_empty()).unwrap_or(false) { "active" } else { "not_configured" },
        }),
    ];

    Ok(Json(serde_json::json!({ "channels": channels })))
}

// ==================== CLIPBOARD ENDPOINT ====================

async fn post_clipboard_copy(
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let text = body
        .get("text")
        .and_then(|t| t.as_str())
        .unwrap_or("")
        .to_string();

    if text.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "bad_request".into(),
                message: "text is required".into(),
                code: 400,
            }),
        ));
    }

    // Try wl-copy (Wayland) first, then xclip (X11)
    let wl_result = tokio::process::Command::new("wl-copy")
        .stdin(std::process::Stdio::piped())
        .spawn();

    if let Ok(mut child) = wl_result {
        if let Some(mut stdin) = child.stdin.take() {
            use tokio::io::AsyncWriteExt;
            let _ = stdin.write_all(text.as_bytes()).await;
            drop(stdin);
        }
        if child.wait().await.map(|s| s.success()).unwrap_or(false) {
            return Ok(Json(serde_json::json!({
                "copied": true,
                "chars": text.len(),
                "method": "wl-copy"
            })));
        }
    }

    // Fallback to xclip
    let mut xclip = tokio::process::Command::new("xclip")
        .args(["-selection", "clipboard"])
        .stdin(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "clipboard_failed".into(),
                    message: format!("No clipboard tool: {}", e),
                    code: 500,
                }),
            )
        })?;

    if let Some(mut stdin) = xclip.stdin.take() {
        use tokio::io::AsyncWriteExt;
        let _ = stdin.write_all(text.as_bytes()).await;
        drop(stdin);
    }

    match xclip.wait().await {
        Ok(status) if status.success() => Ok(Json(serde_json::json!({
            "copied": true,
            "chars": text.len(),
            "method": "xclip"
        }))),
        _ => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "clipboard_failed".into(),
                message: "Both wl-copy and xclip failed".into(),
                code: 500,
            }),
        )),
    }
}

// ==================== LLM ROUTER ENDPOINTS ====================

async fn post_llm_chat(
    State(state): State<ApiState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    use crate::llm_router::{ChatMessage, RouterRequest, TaskComplexity};
    use crate::privacy_filter::SensitivityLevel;

    let messages: Vec<ChatMessage> = body
        .get("messages")
        .and_then(|m| serde_json::from_value(m.clone()).ok())
        .unwrap_or_default();

    if messages.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError {
                error: "bad_request".into(),
                message: "messages array is required".into(),
                code: 400,
            }),
        ));
    }

    let complexity = body
        .get("complexity")
        .and_then(|c| serde_json::from_value::<TaskComplexity>(c.clone()).ok());

    let sensitivity = body
        .get("sensitivity")
        .and_then(|s| serde_json::from_value::<SensitivityLevel>(s.clone()).ok());

    let preferred_provider = body
        .get("provider")
        .and_then(|p| p.as_str())
        .map(String::from);

    let max_tokens = body
        .get("max_tokens")
        .and_then(|t| t.as_u64())
        .and_then(|t| u32::try_from(t).ok());

    let request = RouterRequest {
        messages,
        complexity,
        sensitivity,
        preferred_provider,
        max_tokens,
    };

    let router = state.llm_router.read().await;
    match router.chat(&request).await {
        Ok(response) => Ok(Json(serde_json::json!({
            "text": response.text,
            "provider": response.provider,
            "model": response.model,
            "tokens_used": response.tokens_used,
            "latency_ms": response.latency_ms,
        }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "llm_routing_failed".into(),
                message: format!("LLM routing failed: {}", e),
                code: 500,
            }),
        )),
    }
}

async fn get_llm_providers(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let router = state.llm_router.read().await;
    let summary = router.cost_summary();

    let providers: Vec<serde_json::Value> = summary
        .into_iter()
        .map(|(name, requests, tokens, failures)| {
            serde_json::json!({
                "name": name,
                "total_requests": requests,
                "total_output_tokens": tokens,
                "total_failures": failures,
            })
        })
        .collect();

    Ok(Json(serde_json::json!({ "providers": providers })))
}

async fn post_llm_reload(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mut router = state.llm_router.write().await;
    match router.reload_providers() {
        Ok(count) => Ok(Json(serde_json::json!({
            "reloaded": true,
            "provider_count": count,
        }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "reload_failed".into(),
                message: format!("Failed to reload providers: {}", e),
                code: 500,
            }),
        )),
    }
}

// ==================== SERVER STARTUP ====================

pub async fn start_api_server(state: ApiState) -> anyhow::Result<()> {
    let router = create_router(state.clone());

    let addr = state.config.bind_address;

    log::info!("Starting API server on http://{}", addr);
    log::info!("Dashboard: http://{}/dashboard", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;

    axum::serve(listener, router).await?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Battery management handlers
// ---------------------------------------------------------------------------

async fn get_battery_status(
    State(_state): State<ApiState>,
) -> Result<axum::Json<serde_json::Value>, (StatusCode, String)> {
    match crate::battery_manager::read_battery_status().await {
        Ok(status) => Ok(axum::Json(serde_json::to_value(status).unwrap_or_default())),
        Err(e) => Ok(axum::Json(serde_json::json!({
            "error": format!("{}", e),
            "present": false
        }))),
    }
}

async fn post_battery_threshold(
    State(_state): State<ApiState>,
    axum::Json(body): axum::Json<serde_json::Value>,
) -> Result<axum::Json<serde_json::Value>, (StatusCode, String)> {
    let threshold = body
        .get("threshold")
        .and_then(|v| v.as_u64())
        .ok_or_else(|| {
            (
                StatusCode::BAD_REQUEST,
                "Missing 'threshold' (40-100)".into(),
            )
        })? as u32;

    match crate::battery_manager::set_charge_threshold(threshold).await {
        Ok(()) => Ok(axum::Json(serde_json::json!({
            "success": true,
            "threshold": threshold
        }))),
        Err(e) => Ok(axum::Json(serde_json::json!({
            "success": false,
            "error": format!("{}", e)
        }))),
    }
}

/// GET /api/v1/battery/history — battery level readings.
///
/// Returns the current battery snapshot. Full historical tracking with a
/// background sampler is a future improvement — for now we return a single
/// data-point so the endpoint contract is honest.
async fn get_battery_history(
    State(_state): State<ApiState>,
) -> Result<axum::Json<serde_json::Value>, (StatusCode, String)> {
    match crate::battery_manager::read_battery_status().await {
        Ok(status) => {
            let now = chrono::Utc::now().to_rfc3339();
            let entry = serde_json::json!({
                "timestamp": now,
                "capacity_pct": status.capacity_pct,
                "status": status.status,
                "health_pct": status.health_pct,
                "power_profile": status.power_profile,
            });
            Ok(axum::Json(serde_json::json!({
                "readings": [entry],
                "note": "Historical tracking with periodic sampling is planned. Currently returns the latest snapshot."
            })))
        }
        Err(e) => Ok(axum::Json(serde_json::json!({
            "readings": [],
            "error": format!("{}", e)
        }))),
    }
}

// ---------------------------------------------------------------------------
// Translation handler
// ---------------------------------------------------------------------------

/// POST /api/v1/translate — translate text between languages.
///
/// Request body: `{ "text": "...", "target_lang": "es", "source_lang": "en" }`
/// `source_lang` is optional (auto-detected when omitted).
async fn post_translate(
    State(state): State<ApiState>,
    axum::Json(body): axum::Json<serde_json::Value>,
) -> Result<axum::Json<serde_json::Value>, (StatusCode, String)> {
    let text = body
        .get("text")
        .and_then(|v| v.as_str())
        .ok_or_else(|| (StatusCode::BAD_REQUEST, "Missing 'text' field".into()))?;
    let target_lang = body
        .get("target_lang")
        .and_then(|v| v.as_str())
        .ok_or_else(|| {
            (
                StatusCode::BAD_REQUEST,
                "Missing 'target_lang' field".into(),
            )
        })?;
    let source_lang = body
        .get("source_lang")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    let engine = crate::translation::TranslationEngine::new(None);
    let req = crate::translation::TranslationRequest {
        text: text.to_string(),
        source_lang,
        target_lang: target_lang.to_string(),
    };

    let router = state.llm_router.read().await;
    match engine.translate(&req, Some(&router)).await {
        Ok(result) => Ok(axum::Json(serde_json::json!({
            "original": result.original,
            "translated": result.translated,
            "source_lang": result.source_lang,
            "target_lang": result.target_lang,
            "method": result.method,
        }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Translation failed: {}", e),
        )),
    }
}

// ==================== SKILL REGISTRY ENDPOINTS ====================

/// GET /api/v1/skills — list all loaded skills
async fn get_skills_list(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let skills = state.skill_registry.list().await;
    Ok(Json(serde_json::json!({
        "skills": skills,
        "count": skills.len(),
    })))
}

/// GET /api/v1/skills/:name — get a single skill by name
async fn get_skill_by_name(
    State(state): State<ApiState>,
    Path(name): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    match state.skill_registry.get(&name).await {
        Some((manifest, dir)) => Ok(Json(serde_json::json!({
            "skill": manifest,
            "directory": dir.display().to_string(),
        }))),
        None => Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "Not Found".into(),
                message: format!("Skill '{}' not found in registry", name),
                code: 404,
            }),
        )),
    }
}

#[derive(Debug, Deserialize)]
struct SkillRunRequest {
    #[serde(default)]
    input: String,
}

/// POST /api/v1/skills/:name/run — execute a skill by name
async fn post_skill_run(
    State(state): State<ApiState>,
    Path(name): Path<String>,
    body: Option<Json<SkillRunRequest>>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let input = body.map(|b| b.input.clone()).unwrap_or_default();
    match state.skill_registry.run(&name, &input).await {
        Ok(output) => Ok(Json(serde_json::json!({
            "success": true,
            "skill": name,
            "output": output,
        }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Skill Execution Failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

/// POST /api/v1/skills/reload — trigger a hot-reload of all skill directories
async fn post_skills_reload(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    match state.skill_registry.reload().await {
        Ok(summary) => Ok(Json(serde_json::json!({
            "success": true,
            "summary": summary,
        }))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Reload Failed".into(),
                message: format!("{}", e),
                code: 500,
            }),
        )),
    }
}

/// GET /api/v1/skills/diagnostics — registry diagnostics
async fn get_skills_diagnostics(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let diag = state.skill_registry.diagnostics().await;
    Ok(Json(serde_json::json!({
        "diagnostics": diag,
    })))
}

async fn get_knowledge_graph_export() -> impl axum::response::IntoResponse {
    Json(serde_json::json!({
        "note": "Knowledge graph export via API is planned. Use Telegram `graph_query` tool for queries.",
        "status": "not_yet_implemented"
    }))
}

async fn post_knowledge_graph_import(
    Json(body): Json<serde_json::Value>,
) -> impl axum::response::IntoResponse {
    let entities = body
        .get("entities")
        .and_then(|v| v.as_array())
        .map(|a| a.len())
        .unwrap_or(0);
    let relations = body
        .get("relations")
        .and_then(|v| v.as_array())
        .map(|a| a.len())
        .unwrap_or(0);
    Json(serde_json::json!({
        "accepted": true,
        "entities_received": entities,
        "relations_received": relations,
        "note": "Import is best-effort. Full merge planned for future release."
    }))
}

async fn get_audit_events(
    axum::extract::Query(params): axum::extract::Query<std::collections::HashMap<String, String>>,
) -> impl axum::response::IntoResponse {
    let since = params.get("since").cloned().unwrap_or_else(|| "24h".into());
    let event_type = params.get("type").cloned();
    Json(serde_json::json!({
        "period": since,
        "filter_type": event_type,
        "note": "Audit events available via `life audit` CLI. API query planned for future release."
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_signature_valid_hex() {
        let parsed = parse_signature("deadbeef");
        assert_eq!(parsed, "deadbeef");
        let prefixed = parse_signature("sha256:DEADBEEF");
        assert_eq!(prefixed, "deadbeef");
    }

    #[test]
    fn test_parse_signature_invalid_hex() {
        assert_eq!(parse_signature("not-hex"), "not-hex");
        assert!(parse_signature("").is_empty());
    }

    #[test]
    fn test_embedded_catalog_signature_matches() {
        assert!(embedded_catalog_signature_valid());
    }

    #[test]
    fn test_format_size_bytes_units() {
        assert_eq!(format_size_bytes(900), "900 B");
        assert_eq!(format_size_bytes(2048), "2.0 KB");
        assert_eq!(format_size_bytes(10 * 1024 * 1024), "10.0 MB");
    }

    #[test]
    fn test_is_selectable_model_asset_filters_non_models() {
        assert!(is_selectable_model_asset("Qwen3.5-4B-Q4_K_M.gguf"));
        assert!(!is_selectable_model_asset("mmproj-F16.gguf"));
        assert!(!is_selectable_model_asset(".removed-models"));
        assert!(!is_selectable_model_asset("readme.txt"));
    }

    #[test]
    fn test_qwen_companion_mmproj_mapping() {
        assert_eq!(
            qwen_companion_mmproj_filename("Qwen3.5-0.8B-Q4_K_M.gguf"),
            Some("mmproj-F16.gguf".to_string())
        );
        assert_eq!(
            qwen_companion_mmproj_filename("Qwen3.5-4B-Q4_K_M.gguf"),
            Some("Qwen3.5-4B-mmproj-F16.gguf".to_string())
        );
        assert_eq!(qwen_companion_mmproj_filename("llama-3.2-3b.gguf"), None);
    }

    #[test]
    fn test_estimate_download_seconds_uses_default_rate() {
        assert_eq!(estimate_download_seconds(0), 0);
        assert_eq!(estimate_download_seconds(100_000_000), 8);
    }

    #[test]
    fn test_verify_artifact_validates_size_and_checksum() {
        let path =
            std::env::temp_dir().join(format!("lifeos-artifact-test-{}.bin", uuid::Uuid::new_v4()));
        std::fs::write(&path, b"abc").expect("should write temp artifact");
        let expected_sha = digest_bytes(b"abc");

        verify_artifact(&path, Some(3), Some(&expected_sha)).expect("artifact should validate");
        assert!(verify_artifact(&path, Some(4), Some(&expected_sha)).is_err());
        assert!(verify_artifact(&path, Some(3), Some("deadbeef")).is_err());

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn test_parse_env_var_reads_non_empty_values() {
        let env = "LIFEOS_AI_MODEL=Qwen3.5-4B-Q4_K_M.gguf\nLIFEOS_AI_MMPROJ=Qwen3.5-4B-mmproj-F16.gguf\nEMPTY=\n";
        assert_eq!(
            parse_env_var(env, "LIFEOS_AI_MODEL"),
            Some("Qwen3.5-4B-Q4_K_M.gguf".to_string())
        );
        assert_eq!(
            parse_env_var(env, "LIFEOS_AI_MMPROJ"),
            Some("Qwen3.5-4B-mmproj-F16.gguf".to_string())
        );
        assert_eq!(parse_env_var(env, "EMPTY"), None);
        assert_eq!(parse_env_var(env, "MISSING"), None);
    }

    #[test]
    fn test_catalog_companion_resolution_prefers_signed_catalog() {
        let catalog_models = fallback_overlay_catalog_models();
        let entry = resolve_catalog_model("qwen3.5:4b", &catalog_models).expect("catalog entry");
        let companion = entry
            .companion_mmproj
            .as_ref()
            .expect("companion should be present");
        assert_eq!(companion.filename, "Qwen3.5-4B-mmproj-F16.gguf");
        assert!(companion.checksum_sha256.is_some());
    }

    #[test]
    fn test_featured_overlay_roster_contains_qwen_tiers() {
        let roster = featured_overlay_roster(&fallback_overlay_catalog_models());
        assert_eq!(
            roster,
            vec![
                "Qwen3.5-4B-Q4_K_M.gguf".to_string(),
                "Qwen3.5-9B-Q4_K_M.gguf".to_string(),
                "Qwen3.5-27B-Q4_K_M.gguf".to_string()
            ]
        );
    }

    #[test]
    fn test_assess_overlay_model_fit_downgrades_when_thermal_pressure() {
        let cool_hardware = OverlayHardwareSnapshot {
            total_ram_gb: 32,
            total_vram_gb: Some(12),
            thermal_pressure: false,
            ..OverlayHardwareSnapshot::default()
        };
        let cool_fit = assess_overlay_model_fit(2_740_937_888, Some(16), Some(8), &cool_hardware);
        assert_eq!(cool_fit.fit_tier, "full_gpu");
        assert_eq!(cool_fit.expected_gpu_layers, -1);

        let hot_hardware = OverlayHardwareSnapshot {
            thermal_pressure: true,
            ..cool_hardware
        };
        let hot_fit = assess_overlay_model_fit(2_740_937_888, Some(16), Some(8), &hot_hardware);
        assert_eq!(hot_fit.fit_tier, "partial_gpu");
        assert_eq!(hot_fit.expected_gpu_layers, 20);
    }

    #[test]
    fn test_storage_summary_reclaimable_respects_selected_and_pinned() {
        let installed = BTreeMap::from([
            ("a.gguf".to_string(), 100_u64),
            ("b.gguf".to_string(), 200_u64),
            ("c.gguf".to_string(), 300_u64),
        ]);
        let pinned = BTreeSet::from(["b.gguf".to_string()]);
        let summary = build_storage_summary(&installed, &pinned, Some("c.gguf"));
        assert_eq!(summary.installed_model_bytes, 600);
        assert_eq!(summary.reclaimable_model_bytes, 100);
    }
}
