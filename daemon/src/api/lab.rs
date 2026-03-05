//! Lab API endpoints

use super::{ApiError, ApiState};
use crate::lab::ExperimentType;
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

pub fn lab_routes() -> Router<ApiState> {
    Router::new()
        .route("/status", get(get_lab_status))
        .route("/experiment", post(start_experiment))
        .route("/experiment/:id", get(get_experiment))
        .route("/experiment/:id/canary", post(start_canary))
        .route("/experiment/:id/promote", post(promote_experiment))
        .route("/experiment/:id/rollback", post(rollback_experiment))
        .route("/experiment/:id/report", get(get_experiment_report))
        .route("/history", get(get_lab_history))
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct LabStatusResponse {
    pub current_experiment: Option<ExperimentInfo>,
    pub completed_experiments: usize,
    pub canary_active: bool,
    pub last_run: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct ExperimentInfo {
    pub id: String,
    pub experiment_type: String,
    pub hypothesis: String,
    pub status: String,
    pub started_at: String,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct StartExperimentRequest {
    pub experiment_type: String,
    pub hypothesis: String,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct StartExperimentResponse {
    pub experiment_id: String,
    pub status: String,
    pub message: String,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct ExperimentReportResponse {
    pub experiment: ExperimentInfo,
    pub result: Option<ExperimentResultInfo>,
    pub recommendation: String,
    pub next_steps: Vec<String>,
    pub risk_level: String,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct ExperimentResultInfo {
    pub completed_at: String,
    pub success: bool,
    pub improvement_score: f32,
    pub rollback_performed: bool,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct HistoryResponse {
    pub experiments: Vec<ExperimentHistoryItem>,
    pub count: usize,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct ExperimentHistoryItem {
    pub id: String,
    pub experiment_type: String,
    pub hypothesis: String,
    pub success: bool,
    pub completed_at: String,
    pub improvement_score: f32,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct RollbackRequest {
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct HistoryQuery {
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize {
    10
}

#[utoipa::path(
    get,
    path = "/api/v1/lab/status",
    responses(
        (status = 200, description = "Lab status retrieved", body = LabStatusResponse),
        (status = 500, description = "Internal error", body = ApiError),
    ),
    tag = "lab"
)]
pub async fn get_lab_status(
    State(state): State<ApiState>,
) -> Result<Json<LabStatusResponse>, (StatusCode, Json<ApiError>)> {
    let lab = state.lab_manager.read().await;
    let lab_state = lab.status().await;

    let response = LabStatusResponse {
        current_experiment: lab_state.current_experiment.map(|exp| ExperimentInfo {
            id: exp.id,
            experiment_type: exp.experiment_type.to_string(),
            hypothesis: exp.hypothesis,
            status: exp.status.to_string(),
            started_at: exp.started_at.to_rfc3339(),
        }),
        completed_experiments: lab_state.completed_experiments.len(),
        canary_active: lab_state.canary_active,
        last_run: lab_state.last_run.map(|t| t.to_rfc3339()),
    };

    Ok(Json(response))
}

#[utoipa::path(
    post,
    path = "/api/v1/lab/experiment",
    request_body = StartExperimentRequest,
    responses(
        (status = 200, description = "Experiment started", body = StartExperimentResponse),
        (status = 400, description = "Invalid request", body = ApiError),
        (status = 500, description = "Internal error", body = ApiError),
    ),
    tag = "lab"
)]
pub async fn start_experiment(
    State(state): State<ApiState>,
    Json(request): Json<StartExperimentRequest>,
) -> Result<Json<StartExperimentResponse>, (StatusCode, Json<ApiError>)> {
    let experiment_type = match request.experiment_type.as_str() {
        "config_optimization" => ExperimentType::ConfigOptimization,
        "service_tuning" => ExperimentType::ServiceTuning,
        "power_management" => ExperimentType::PowerManagement,
        "ai_model_selection" => ExperimentType::AIModelSelection,
        "security_hardening" => ExperimentType::SecurityHardening,
        _ => {
            return Err((
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Invalid experiment type".to_string(),
                    message: "Valid types: config_optimization, service_tuning, power_management, ai_model_selection, security_hardening".to_string(),
                    code: 400,
                }),
            ))
        }
    };

    let lab = state.lab_manager.read().await;
    let experiment_id = lab
        .start_experiment(experiment_type, &request.hypothesis)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Failed to start experiment".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?;

    Ok(Json(StartExperimentResponse {
        experiment_id,
        status: "running".to_string(),
        message: "Experiment started successfully".to_string(),
    }))
}

#[utoipa::path(
    get,
    path = "/api/v1/lab/experiment/{id}",
    responses(
        (status = 200, description = "Experiment details", body = ExperimentInfo),
        (status = 404, description = "Experiment not found", body = ApiError),
    ),
    tag = "lab"
)]
pub async fn get_experiment(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<ExperimentInfo>, (StatusCode, Json<ApiError>)> {
    let lab = state.lab_manager.read().await;
    let experiment = lab
        .get_experiment(&id)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError {
                    error: "Failed to get experiment".to_string(),
                    message: e.to_string(),
                    code: 500,
                }),
            )
        })?
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                Json(ApiError {
                    error: "Not found".to_string(),
                    message: format!("Experiment {} not found", id),
                    code: 404,
                }),
            )
        })?;

    Ok(Json(ExperimentInfo {
        id: experiment.id,
        experiment_type: experiment.experiment_type.to_string(),
        hypothesis: experiment.hypothesis,
        status: experiment.status.to_string(),
        started_at: experiment.started_at.to_rfc3339(),
    }))
}

#[utoipa::path(
    post,
    path = "/api/v1/lab/experiment/{id}/canary",
    responses(
        (status = 200, description = "Canary phase started"),
        (status = 400, description = "Invalid state", body = ApiError),
        (status = 404, description = "Experiment not found", body = ApiError),
    ),
    tag = "lab"
)]
pub async fn start_canary(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let lab = state.lab_manager.read().await;
    lab.start_canary(&id).await.map_err(|e| {
        let code = if e.to_string().contains("not found") {
            StatusCode::NOT_FOUND
        } else {
            StatusCode::BAD_REQUEST
        };
        (
            code,
            Json(ApiError {
                error: "Failed to start canary".to_string(),
                message: e.to_string(),
                code: code.as_u16(),
            }),
        )
    })?;

    Ok(StatusCode::OK)
}

#[utoipa::path(
    post,
    path = "/api/v1/lab/experiment/{id}/promote",
    responses(
        (status = 200, description = "Experiment promoted"),
        (status = 400, description = "Invalid state", body = ApiError),
        (status = 404, description = "Experiment not found", body = ApiError),
    ),
    tag = "lab"
)]
pub async fn promote_experiment(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let lab = state.lab_manager.read().await;
    lab.promote(&id).await.map_err(|e| {
        let code = if e.to_string().contains("not found") {
            StatusCode::NOT_FOUND
        } else {
            StatusCode::BAD_REQUEST
        };
        (
            code,
            Json(ApiError {
                error: "Failed to promote experiment".to_string(),
                message: e.to_string(),
                code: code.as_u16(),
            }),
        )
    })?;

    Ok(StatusCode::OK)
}

#[utoipa::path(
    post,
    path = "/api/v1/lab/experiment/{id}/rollback",
    request_body = Option<RollbackRequest>,
    responses(
        (status = 200, description = "Experiment rolled back"),
        (status = 400, description = "Invalid state", body = ApiError),
        (status = 404, description = "Experiment not found", body = ApiError),
    ),
    tag = "lab"
)]
pub async fn rollback_experiment(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(request): Json<Option<RollbackRequest>>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let reason = request
        .and_then(|r| r.reason)
        .unwrap_or_else(|| "Manual rollback".to_string());

    let lab = state.lab_manager.read().await;
    lab.rollback(&id, &reason).await.map_err(|e| {
        let code = if e.to_string().contains("not found") {
            StatusCode::NOT_FOUND
        } else {
            StatusCode::BAD_REQUEST
        };
        (
            code,
            Json(ApiError {
                error: "Failed to rollback experiment".to_string(),
                message: e.to_string(),
                code: code.as_u16(),
            }),
        )
    })?;

    Ok(StatusCode::OK)
}

#[utoipa::path(
    get,
    path = "/api/v1/lab/experiment/{id}/report",
    responses(
        (status = 200, description = "Experiment report", body = ExperimentReportResponse),
        (status = 404, description = "Experiment not found", body = ApiError),
    ),
    tag = "lab"
)]
pub async fn get_experiment_report(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<ExperimentReportResponse>, (StatusCode, Json<ApiError>)> {
    let lab = state.lab_manager.read().await;
    let report = lab.report(&id).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to generate report".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )
    })?;

    Ok(Json(ExperimentReportResponse {
        experiment: ExperimentInfo {
            id: report.experiment.id,
            experiment_type: report.experiment.experiment_type.to_string(),
            hypothesis: report.experiment.hypothesis,
            status: report.experiment.status.to_string(),
            started_at: report.experiment.started_at.to_rfc3339(),
        },
        result: report.result.map(|r| ExperimentResultInfo {
            completed_at: r.completed_at.to_rfc3339(),
            success: r.success,
            improvement_score: r.improvement_score,
            rollback_performed: r.rollback_performed,
        }),
        recommendation: report.recommendation,
        next_steps: report.next_steps,
        risk_level: format!("{:?}", report.risk_level).to_lowercase(),
    }))
}

#[utoipa::path(
    get,
    path = "/api/v1/lab/history",
    responses(
        (status = 200, description = "Experiment history", body = HistoryResponse),
    ),
    tag = "lab"
)]
pub async fn get_lab_history(
    State(state): State<ApiState>,
    Query(query): Query<HistoryQuery>,
) -> Result<Json<HistoryResponse>, (StatusCode, Json<ApiError>)> {
    let lab = state.lab_manager.read().await;
    let history = lab.history().await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError {
                error: "Failed to get history".to_string(),
                message: e.to_string(),
                code: 500,
            }),
        )
    })?;

    let experiments: Vec<ExperimentHistoryItem> = history
        .into_iter()
        .take(query.limit)
        .map(|r| ExperimentHistoryItem {
            id: r.experiment.id,
            experiment_type: r.experiment.experiment_type.to_string(),
            hypothesis: r.experiment.hypothesis,
            success: r.success,
            completed_at: r.completed_at.to_rfc3339(),
            improvement_score: r.improvement_score,
        })
        .collect();

    let count = experiments.len();

    Ok(Json(HistoryResponse { experiments, count }))
}
