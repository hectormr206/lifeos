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
    response::{Json, Response},
    routing::{delete, get, post, put},
    Router,
};
use log::error;
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::process::Command;
use tokio::sync::RwLock;
use utoipa::{
    openapi::security::{ApiKey, ApiKeyValue, SecurityScheme},
    Modify, OpenApi, ToSchema,
};
use utoipa_swagger_ui::SwaggerUi;

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
use crate::system::SystemMonitor;
use crate::update_scheduler::UpdateScheduler;
use crate::visual_comfort::{ComfortProfile, VisualComfortManager};
use std::path::PathBuf;

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
    pub experience_manager: Arc<RwLock<ExperienceManager>>,
    pub update_scheduler: Arc<RwLock<UpdateScheduler>>,
    pub follow_along_manager: Arc<RwLock<FollowAlongManager>>,
    pub context_policies_manager: Arc<RwLock<ContextPoliciesManager>>,
    pub telemetry_manager: Arc<RwLock<crate::telemetry::TelemetryManager>>,
    pub agent_runtime_manager: Arc<RwLock<AgentRuntimeManager>>,
    pub memory_plane_manager: Arc<RwLock<MemoryPlaneManager>>,
    pub visual_comfort_manager: Arc<RwLock<VisualComfortManager>>,
    pub lab_manager: Arc<RwLock<LabManager>>,
    pub config: ApiConfig,
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
}

#[derive(Serialize, Deserialize, ToSchema, Clone)]
pub struct OverlayStats {
    pub total_messages: usize,
    pub visible: bool,
    pub focused: bool,
    pub theme: String,
    pub shortcut: String,
    pub enabled: bool,
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
        // AI endpoints
        .route("/ai/status", get(get_ai_status))
        .route("/ai/models", get(get_ai_models))
        .route("/ai/chat", post(post_ai_chat))
        .route("/vision/ocr", post(post_vision_ocr))
        .route("/audio/stt/status", get(get_stt_status))
        .route("/audio/stt/start", post(start_stt_service))
        .route("/audio/stt/stop", post(stop_stt_service))
        .route("/audio/stt/transcribe", post(transcribe_audio_file))
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
            "/runtime/jarvis",
            get(get_jarvis_session).post(start_jarvis_session),
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
        .route("/runtime/jarvis/stop", post(stop_jarvis_session))
        .route(
            "/runtime/jarvis/kill-switch",
            post(trigger_jarvis_kill_switch),
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
        .route("/visual-comfort/profiles", get(list_visual_comfort_profiles))
        .route("/visual-comfort/temperature", post(set_visual_comfort_temperature))
        .route("/visual-comfort/font-scale", post(set_visual_comfort_font_scale))
        .route("/visual-comfort/animations", post(set_visual_comfort_animations))
        .route("/visual-comfort/reset", post(reset_visual_comfort_session))
        // Lab endpoints
        .route("/lab/status", get(lab::get_lab_status))
        .route("/lab/experiment", post(lab::start_experiment))
        .route("/lab/experiment/:id", get(lab::get_experiment))
        .route("/lab/experiment/:id/canary", post(lab::start_canary))
        .route("/lab/experiment/:id/promote", post(lab::promote_experiment))
        .route("/lab/experiment/:id/rollback", post(lab::rollback_experiment))
        .route("/lab/experiment/:id/report", get(lab::get_experiment_report))
        .route("/lab/history", get(lab::get_lab_history))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            require_bootstrap_token,
        ));

    Router::new()
        .nest("/api/v1", api_v1)
        .merge(SwaggerUi::new("/swagger-ui").url("/api-docs/openapi.json", ApiDoc::openapi()))
        .with_state(state)
}

async fn require_bootstrap_token(
    State(state): State<ApiState>,
    request: Request<Body>,
    next: Next,
) -> Result<Response, (StatusCode, Json<ApiError>)> {
    let expected = state.config.api_key.as_deref().ok_or_else(|| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ApiError {
                error: "Service Unavailable".to_string(),
                message: "Bootstrap token not configured".to_string(),
                code: 503,
            }),
        )
    })?;

    let provided = request
        .headers()
        .get("x-bootstrap-token")
        .or_else(|| request.headers().get("x-api-key"))
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();

    if provided != expected {
        return Err((
            StatusCode::UNAUTHORIZED,
            Json(ApiError {
                error: "Unauthorized".to_string(),
                message: "Missing or invalid bootstrap token".to_string(),
                code: 401,
            }),
        ));
    }

    Ok(next.run(request).await)
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
    let allowed_commands = vec!["status", "info", "ping"];

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
    if let Some(model) = model.map(str::trim).filter(|v| !v.is_empty()) {
        cmd.args(["-m", model]);
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
    let mode = mode_param.as_ref().map(|s| s.as_str()).unwrap_or("current");
    let mgr = ExperienceManager::new(PathBuf::from("/var/lib/lifeos"));

    let (mode_name, display_name, description) = if mode == "current" {
        let current = mgr.get_current_mode().await;
        if let Some(details) = mgr.get_current_mode_details().await {
            (current, details.display_name, details.description)
        } else {
            (current, "Unknown".to_string(), "".to_string())
        }
    } else {
        if let Some(details) = mgr.get_mode(&mode) {
            (
                details.name.clone(),
                details.display_name.clone(),
                details.description.clone(),
            )
        } else {
            (mode.to_string(), "Unknown".to_string(), "".to_string())
        }
    };

    // Get features
    let features = if mode == "current" {
        mgr.get_current_features().await
    } else if let Some(mode_details) = mgr.get_mode(&mode) {
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
        mgr.get_mode(&mode).map(|d| d.settings.clone())
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
async fn show_overlay(State(_state): State<ApiState>) -> StatusCode {
    let overlay_mgr = OverlayManager::new(PathBuf::from("/var/lib/lifeos/screenshots"));
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
async fn hide_overlay(State(_state): State<ApiState>) -> StatusCode {
    let overlay_mgr = OverlayManager::new(PathBuf::from("/var/lib/lifeos/screenshots"));
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
async fn toggle_overlay(State(_state): State<ApiState>) -> StatusCode {
    let overlay_mgr = OverlayManager::new(PathBuf::from("/var/lib/lifeos/screenshots"));
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
    State(_state): State<ApiState>,
    Json(request): Json<OverlayChatRequest>,
) -> Result<Json<OverlayChatResponse>, (StatusCode, Json<ApiError>)> {
    let overlay_mgr = OverlayManager::new(PathBuf::from("/var/lib/lifeos/screenshots"));

    let response_content = match overlay_mgr
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
        response: response_content,
        model: "Qwen3.5-4B-Q4_K_M.gguf".to_string(),
        tokens_used: None,
        duration_ms: 0,
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
    State(_state): State<ApiState>,
) -> Result<Json<OverlayScreenshotResponse>, (StatusCode, Json<ApiError>)> {
    let overlay_mgr = OverlayManager::new(PathBuf::from("/var/lib/lifeos/screenshots"));
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
async fn clear_overlay(State(_state): State<ApiState>) -> StatusCode {
    let overlay_mgr = OverlayManager::new(PathBuf::from("/var/lib/lifeos/screenshots"));
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
    State(_state): State<ApiState>,
) -> Result<Json<OverlayStatusResponse>, (StatusCode, Json<ApiError>)> {
    let overlay_mgr = OverlayManager::new(PathBuf::from("/var/lib/lifeos/screenshots"));
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
        },
        chat_history,
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
    State(_state): State<ApiState>,
    Json(request): Json<OverlayConfigRequest>,
) -> StatusCode {
    let overlay_mgr = OverlayManager::new(PathBuf::from("/var/lib/lifeos/screenshots"));
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
    State(_state): State<ApiState>,
    Json(request): Json<OverlayExportRequest>,
) -> StatusCode {
    let overlay_mgr = OverlayManager::new(PathBuf::from("/var/lib/lifeos/screenshots"));
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
    State(_state): State<ApiState>,
    Json(request): Json<OverlayImportRequest>,
) -> StatusCode {
    let overlay_mgr = OverlayManager::new(PathBuf::from("/var/lib/lifeos/screenshots"));
    let path = PathBuf::from(&request.path);

    match overlay_mgr.import_chat(path).await {
        Ok(_) => StatusCode::OK,
        Err(e) => {
            error!("Failed to import chat: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
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
    State(_state): State<ApiState>,
) -> Result<Json<FollowAlongConfigResponse>, (StatusCode, Json<ApiError>)> {
    let manager = crate::follow_along::FollowAlongManager::new(PathBuf::from("/var/lib/lifeos"))
        .unwrap_or_else(|_| {
            crate::follow_along::FollowAlongManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
        });

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
    State(_state): State<ApiState>,
    Json(request): Json<SetFollowAlongConfigRequest>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let manager = crate::follow_along::FollowAlongManager::new(PathBuf::from("/var/lib/lifeos"))
        .unwrap_or_else(|_| {
            crate::follow_along::FollowAlongManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
        });

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
    State(_state): State<ApiState>,
    Json(request): Json<SetConsentRequest>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let manager = crate::follow_along::FollowAlongManager::new(PathBuf::from("/var/lib/lifeos"))
        .unwrap_or_else(|_| {
            crate::follow_along::FollowAlongManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
        });

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
    State(_state): State<ApiState>,
) -> Result<Json<ContextStateResponse>, (StatusCode, Json<ApiError>)> {
    let manager = crate::follow_along::FollowAlongManager::new(PathBuf::from("/var/lib/lifeos"))
        .unwrap_or_else(|_| {
            crate::follow_along::FollowAlongManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
        });

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
    State(_state): State<ApiState>,
) -> Result<Json<EventStatsResponse>, (StatusCode, Json<ApiError>)> {
    let manager = crate::follow_along::FollowAlongManager::new(PathBuf::from("/var/lib/lifeos"))
        .unwrap_or_else(|_| {
            crate::follow_along::FollowAlongManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
        });

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
    State(_state): State<ApiState>,
) -> Result<Json<SummaryResponse>, (StatusCode, Json<ApiError>)> {
    let manager = crate::follow_along::FollowAlongManager::new(PathBuf::from("/var/lib/lifeos"))
        .unwrap_or_else(|_| {
            crate::follow_along::FollowAlongManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
        });

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
    State(_state): State<ApiState>,
    Json(request): Json<TranslateSummaryRequest>,
) -> Result<Json<SummaryResponse>, (StatusCode, Json<ApiError>)> {
    let manager = crate::follow_along::FollowAlongManager::new(PathBuf::from("/var/lib/lifeos"))
        .unwrap_or_else(|_| {
            crate::follow_along::FollowAlongManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
        });

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
    State(_state): State<ApiState>,
    Json(request): Json<ExplainActivityRequest>,
) -> Result<Json<ExplanationResponse>, (StatusCode, Json<ApiError>)> {
    let manager = crate::follow_along::FollowAlongManager::new(PathBuf::from("/var/lib/lifeos"))
        .unwrap_or_else(|_| {
            crate::follow_along::FollowAlongManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
        });

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
    State(_state): State<ApiState>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let manager = crate::follow_along::FollowAlongManager::new(PathBuf::from("/var/lib/lifeos"))
        .unwrap_or_else(|_| {
            crate::follow_along::FollowAlongManager::new(PathBuf::from("/tmp/lifeos")).unwrap()
        });

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
    // Try to get GPU info
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
struct JarvisStartPayload {
    actor: Option<String>,
    pin: String,
    ttl_minutes: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct JarvisControlPayload {
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
    let limit = query.limit.unwrap_or(50).max(1).min(500);
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
    let limit = query.limit.unwrap_or(20).max(1).min(200);
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

    if enabled && (audio_enabled || screen_enabled) {
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

async fn get_jarvis_session(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let jarvis = mgr.jarvis_session().await;
    Ok(Json(serde_json::json!(jarvis)))
}

async fn start_jarvis_session(
    State(state): State<ApiState>,
    Json(payload): Json<JarvisStartPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let jarvis = mgr
        .start_jarvis_session(
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
        "jarvis": jarvis,
    })))
}

async fn stop_jarvis_session(
    State(state): State<ApiState>,
    Json(payload): Json<JarvisControlPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let jarvis = mgr
        .stop_jarvis_session(payload.actor.as_deref())
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
        "jarvis": jarvis,
    })))
}

async fn trigger_jarvis_kill_switch(
    State(state): State<ApiState>,
    Json(payload): Json<JarvisControlPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.agent_runtime_manager.read().await;
    let jarvis = mgr
        .trigger_kill_switch(payload.actor.as_deref())
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
        "jarvis": jarvis,
        "execution_mode": "interactive",
        "trust_mode": "disabled",
    })))
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
async fn list_visual_comfort_profiles() -> Result<Json<Vec<ProfileInfoResponse>>, (StatusCode, Json<ApiError>)> {
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
    manager.set_temperature(request.temperature).await.map_err(|e| {
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

// ==================== SERVER STARTUP ====================

pub async fn start_api_server(state: ApiState) -> anyhow::Result<()> {
    let router = create_router(state.clone());

    let addr = state.config.bind_address;

    log::info!("Starting API server on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;

    axum::serve(listener, router).await?;

    Ok(())
}
