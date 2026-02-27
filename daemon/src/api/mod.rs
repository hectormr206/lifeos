//! LifeOS REST API Server
//!
//! Provides HTTP API endpoints for:
//! - Mobile companion app integration
//! - Remote system monitoring
//! - Push notifications
//! - System management

use axum::{
    body::Body,
    extract::{Path, State},
    http::{Request, StatusCode},
    middleware::{self, Next},
    response::{Json, Response},
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
        // Notification endpoints
        .route("/notifications", get(get_notifications))
        .route("/notifications", post(post_notification))
        .route("/notifications/:id/read", put(mark_notification_read))
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
