//! LifeOS REST API Server
//!
//! Provides HTTP API endpoints for:
//! - Mobile companion app integration
//! - Remote system monitoring
//! - Push notifications
//! - System management

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::Json,
    routing::{get, post, put},
    Router,
};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::RwLock;
use utoipa::{
    openapi::security::{ApiKey, ApiKeyValue, SecurityScheme},
    Modify, OpenApi, ToSchema,
};
use utoipa_swagger_ui::SwaggerUi;

use crate::ai::AiManager;
use crate::system::SystemMonitor;
use crate::health::HealthMonitor;
use crate::notifications::NotificationManager;

/// Shared API state
#[derive(Clone)]
#[allow(dead_code)]
pub struct ApiState {
    pub system_monitor: Arc<RwLock<SystemMonitor>>,
    pub health_monitor: Arc<HealthMonitor>,
    pub ai_manager: Arc<RwLock<AiManager>>,
    pub notification_manager: Arc<NotificationManager>,
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
            bind_address: "0.0.0.0:8080".parse().unwrap(),
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
        )
    ),
    tags(
        (name = "system", description = "System management endpoints"),
        (name = "health", description = "Health monitoring endpoints"),
        (name = "ai", description = "AI service endpoints"),
        (name = "notifications", description = "Notification endpoints"),
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
    Router::new()
        // System endpoints
        .route("/api/v1/system/status", get(get_system_status))
        .route("/api/v1/system/resources", get(get_system_resources))
        .route("/api/v1/system/info", get(get_system_info))
        .route("/api/v1/system/command", post(post_system_command))
        
        // Health endpoints
        .route("/api/v1/health", get(get_health_status))
        
        // AI endpoints
        .route("/api/v1/ai/status", get(get_ai_status))
        .route("/api/v1/ai/models", get(get_ai_models))
        .route("/api/v1/ai/chat", post(post_ai_chat))
        
        // Notification endpoints
        .route("/api/v1/notifications", get(get_notifications))
        .route("/api/v1/notifications", post(post_notification))
        .route("/api/v1/notifications/:id/read", put(mark_notification_read))
        
        // Swagger UI
        .merge(SwaggerUi::new("/swagger-ui").url("/api-docs/openapi.json", ApiDoc::openapi()))
        
        .with_state(state)
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
async fn get_system_status(State(state): State<ApiState>) -> Result<Json<SystemStatus>, (StatusCode, Json<ApiError>)> {
    let _system_monitor = state.system_monitor.read().await;
    
    let uptime = std::time::Duration::from_secs(
        std::fs::read_to_string("/proc/uptime")
            .ok()
            .and_then(|s| s.split_whitespace().next()?.parse::<f64>().ok())
            .unwrap_or(0.0) as u64
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
async fn get_system_resources(State(state): State<ApiState>) -> Result<Json<ResourceUsage>, (StatusCode, Json<ApiError>)> {
    let _system_monitor = state.system_monitor.read().await;
    
    // This would call the actual system monitor methods
    let usage = ResourceUsage {
        cpu_percent: 25.5,
        memory_used_gb: 8.2,
        memory_total_gb: 16.0,
        memory_percent: 51.3,
        disk_used_gb: 256.0,
        disk_total_gb: 512.0,
        disk_percent: 50.0,
        network_rx_mbps: 1.5,
        network_tx_mbps: 0.8,
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
async fn get_system_info(State(_state): State<ApiState>) -> Result<Json<SystemInfo>, (StatusCode, Json<ApiError>)> {
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
async fn get_health_status(State(state): State<ApiState>) -> Result<Json<HealthReport>, (StatusCode, Json<ApiError>)> {
    let report = state
        .health_monitor
        .check_all()
        .await
        .map_err(|e| {
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
async fn get_ai_status(State(state): State<ApiState>) -> Result<Json<AiStatus>, (StatusCode, Json<ApiError>)> {
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
async fn get_ai_models(State(state): State<ApiState>) -> Result<Json<Vec<ModelInfo>>, (StatusCode, Json<ApiError>)> {
    let ai_manager = state.ai_manager.read().await;

    let models = ai_manager
        .list_models()
        .await
        .map_err(|e| {
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
    
    // This would call the actual AI chat method
    let response = ChatResponse {
        response: "This is a placeholder response.".to_string(),
        model: request.model.unwrap_or_else(|| "qwen3:8b".to_string()),
        tokens_used: Some(42),
        duration_ms: start.elapsed().as_millis() as u64,
    };
    
    Ok(Json(response))
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
async fn get_notifications(State(_state): State<ApiState>) -> Result<Json<Vec<Notification>>, (StatusCode, Json<ApiError>)> {
    let notifications = vec![
        Notification {
            id: "1".to_string(),
            title: "System Update Available".to_string(),
            message: "LifeOS 0.2.0 is ready to install".to_string(),
            notification_type: "update".to_string(),
            priority: "normal".to_string(),
            timestamp: chrono::Local::now().to_rfc3339(),
            read: false,
            action_url: Some("life://update".to_string()),
        },
    ];
    
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
    tag = "notifications"
)]
async fn post_notification(
    State(_state): State<ApiState>,
    Json(_notification): Json<Notification>,
) -> StatusCode {
    // Send notification via notification manager
    StatusCode::CREATED
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

// ==================== HELPER FUNCTIONS ====================

fn get_hostname() -> String {
    std::fs::read_to_string("/etc/hostname")
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "unknown".to_string())
}

fn get_kernel_version() -> String {
    std::fs::read_to_string("/proc/version")
        .map(|s| {
            s.split_whitespace()
                .nth(2)
                .unwrap_or("unknown")
                .to_string()
        })
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

// ==================== SERVER STARTUP ====================

pub async fn start_api_server(state: ApiState) -> anyhow::Result<()> {
    let router = create_router(state.clone());
    
    let addr = state.config.bind_address;
    
    log::info!("Starting API server on http://{}", addr);
    
    let listener = tokio::net::TcpListener::bind(addr).await?;
    
    axum::serve(listener, router).await?;
    
    Ok(())
}
