//! Vida Plena (Wellness Pillar) HTTP API endpoints.
//!
//! Surfaces the BI.* sub-fases of the Vida Plena pillar to the
//! dashboard and any future client. The intent of this module is
//! READ-MOSTLY: the heavy writes (logging entries, journaling)
//! continue to flow through Telegram tools where the LLM mediates
//! the conversation. The dashboard mostly needs to *display* state
//! and react to it (unlock vault, see summary, surface forgetting
//! check), so this module exposes:
//!
//!   * Per-pillar summaries (health, growth, exercise, nutrition,
//!     social, sleep, spiritual, financial, relationships,
//!     mental health, menstrual, sexual health).
//!   * The unified `LifeSummary` (BI.8 — coaching unificado).
//!   * `forgetting_check` and `cross_domain_patterns` helpers.
//!   * Vault control: status, set passphrase, unlock, lock, reset.
//!
//! Auth follows the same convention as the rest of `/api/v1/*` —
//! the `x-bootstrap-token` middleware in `mod.rs` covers everything
//! nested under this router.

use super::{ApiError, ApiState};
use crate::memory_plane::LifeSummaryWindow;
use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};

pub fn vida_plena_routes() -> Router<ApiState> {
    Router::new()
        // -- per-pillar summaries (read) ----------------------------
        .route("/health/summary", get(get_health_summary))
        .route("/growth/summary", get(get_growth_summary))
        .route("/exercise/summary", get(get_exercise_summary))
        .route("/nutrition/summary", get(get_nutrition_summary))
        .route("/social/summary", get(get_social_summary))
        .route("/sleep/summary", get(get_sleep_summary))
        .route("/spiritual/summary", get(get_spiritual_summary))
        .route("/financial/summary", get(get_financial_summary))
        .route("/relationships/summary", get(get_relationships_summary))
        .route("/mental-health/summary", get(get_mental_health_summary))
        .route("/menstrual/summary", get(get_menstrual_summary))
        .route("/menstrual/predict", get(get_menstrual_prediction))
        .route("/sexual-health/summary", get(get_sexual_health_summary))
        // -- BI.8 unified coaching ----------------------------------
        .route("/life-summary", get(get_life_summary))
        .route("/cross-domain-patterns", get(get_cross_domain_patterns))
        .route("/forgetting-check", get(get_forgetting_check))
        // -- Vault control (BI cifrado reforzado) -------------------
        .route("/vault/status", get(get_vault_status))
        .route("/vault/set-passphrase", post(post_vault_set_passphrase))
        .route("/vault/unlock", post(post_vault_unlock))
        .route("/vault/lock", post(post_vault_lock))
        .route("/vault/reset", post(post_vault_reset))
}

// ----------------------------------------------------------------------
// Common helpers
// ----------------------------------------------------------------------

/// Map an `anyhow::Error` from the memory plane into an HTTP error.
/// Most errors are 500; explicit "vault is locked" / "wrong
/// passphrase" / "required" / "must be" map to clearer codes.
fn err_to_http(e: anyhow::Error) -> (StatusCode, Json<ApiError>) {
    let msg = e.to_string();
    let status = if msg.contains("locked") || msg.contains("wrong passphrase") {
        StatusCode::FORBIDDEN
    } else if msg.contains("required")
        || msg.contains("must be")
        || msg.contains("invalid")
        || msg.contains("rejected")
        || msg.contains("not configured")
    {
        StatusCode::BAD_REQUEST
    } else if msg.contains("already configured") {
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
}

#[derive(Debug, Deserialize, Default)]
pub struct LimitQuery {
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize, Default)]
pub struct LifeSummaryQuery {
    pub window: Option<String>,
    pub today_local: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct TodayQuery {
    pub today_local: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct RelationshipsSummaryQuery {
    pub today_local: Option<String>,
    pub lookahead_days: Option<u32>,
}

fn today_or_local(today: Option<&str>) -> String {
    today
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| chrono::Local::now().format("%Y-%m-%d").to_string())
}

// ----------------------------------------------------------------------
// Per-pillar summary handlers
// ----------------------------------------------------------------------

async fn get_health_summary(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr.get_health_summary(10, 5).await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "summary": s })))
}

async fn get_growth_summary(
    State(state): State<ApiState>,
    Query(q): Query<TodayQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let today = today_or_local(q.today_local.as_deref());
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr
        .get_growth_summary(5, &today, 30)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "summary": s })))
}

async fn get_exercise_summary(
    State(state): State<ApiState>,
    Query(q): Query<LimitQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let limit = q.limit.unwrap_or(10);
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr.get_exercise_summary(limit).await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "summary": s })))
}

async fn get_nutrition_summary(
    State(state): State<ApiState>,
    Query(q): Query<LimitQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let limit = q.limit.unwrap_or(15);
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr
        .get_nutrition_summary(limit)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "summary": s })))
}

async fn get_social_summary(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr.get_social_summary(10, 10).await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "summary": s })))
}

async fn get_sleep_summary(
    State(state): State<ApiState>,
    Query(q): Query<LimitQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let limit = q.limit.unwrap_or(10);
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr.get_sleep_summary(limit).await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "summary": s })))
}

async fn get_spiritual_summary(
    State(state): State<ApiState>,
    Query(q): Query<LimitQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let limit = q.limit.unwrap_or(10);
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr
        .get_spiritual_summary(limit)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "summary": s })))
}

async fn get_financial_summary(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr
        .get_financial_summary(15, 15)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "summary": s })))
}

async fn get_relationships_summary(
    State(state): State<ApiState>,
    Query(q): Query<RelationshipsSummaryQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let today = today_or_local(q.today_local.as_deref());
    let lookahead = q.lookahead_days.unwrap_or(30);
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr
        .get_relationships_summary(&today, lookahead, 10)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "summary": s })))
}

async fn get_mental_health_summary(
    State(state): State<ApiState>,
    Query(q): Query<LimitQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let limit = q.limit.unwrap_or(30);
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr
        .get_mental_health_summary(limit)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "summary": s })))
}

async fn get_menstrual_summary(
    State(state): State<ApiState>,
    Query(q): Query<LimitQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let limit = q.limit.unwrap_or(30);
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr
        .get_menstrual_cycle_summary(limit)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "summary": s })))
}

async fn get_menstrual_prediction(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let p = mgr.predict_next_period().await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "prediction": p })))
}

async fn get_sexual_health_summary(
    State(state): State<ApiState>,
    Query(q): Query<LimitQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let limit = q.limit.unwrap_or(30);
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr
        .get_sexual_health_summary(limit)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "summary": s })))
}

// ----------------------------------------------------------------------
// BI.8 — unified coaching endpoints
// ----------------------------------------------------------------------

async fn get_life_summary(
    State(state): State<ApiState>,
    Query(q): Query<LifeSummaryQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let today = today_or_local(q.today_local.as_deref());
    let window = LifeSummaryWindow::parse(q.window.as_deref().unwrap_or("week"))
        .unwrap_or(LifeSummaryWindow::Week);
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr
        .get_life_summary(window, &today)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "summary": s })))
}

async fn get_cross_domain_patterns(
    State(state): State<ApiState>,
    Query(q): Query<TodayQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let today = today_or_local(q.today_local.as_deref());
    let mgr = state.memory_plane_manager.read().await;
    let p = mgr
        .detect_cross_domain_patterns(&today)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({
        "patterns": p,
        "count": p.len(),
    })))
}

async fn get_forgetting_check(
    State(state): State<ApiState>,
    Query(q): Query<TodayQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let today = today_or_local(q.today_local.as_deref());
    let mgr = state.memory_plane_manager.read().await;
    let items = mgr.forgetting_check(&today).await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({
        "items": items,
        "count": items.len(),
    })))
}

// ----------------------------------------------------------------------
// Vault control endpoints
// ----------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct VaultSetPassphrasePayload {
    pub passphrase: String,
    #[serde(default)]
    pub idle_timeout_secs: Option<u64>,
}

#[derive(Debug, Deserialize)]
pub struct VaultUnlockPayload {
    pub passphrase: String,
}

#[derive(Debug, Serialize)]
pub struct VaultActionResponse {
    pub status: &'static str,
}

async fn get_vault_status(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr.reinforced_vault_status().await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "vault": s })))
}

async fn post_vault_set_passphrase(
    State(state): State<ApiState>,
    Json(payload): Json<VaultSetPassphrasePayload>,
) -> Result<Json<VaultActionResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    mgr.set_reinforced_passphrase(&payload.passphrase, payload.idle_timeout_secs)
        .await
        .map_err(err_to_http)?;
    Ok(Json(VaultActionResponse {
        status: "configured",
    }))
}

async fn post_vault_unlock(
    State(state): State<ApiState>,
    Json(payload): Json<VaultUnlockPayload>,
) -> Result<Json<VaultActionResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    mgr.unlock_reinforced_vault(&payload.passphrase)
        .await
        .map_err(err_to_http)?;
    Ok(Json(VaultActionResponse { status: "unlocked" }))
}

async fn post_vault_lock(
    State(state): State<ApiState>,
) -> Result<Json<VaultActionResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    mgr.lock_reinforced_vault();
    Ok(Json(VaultActionResponse { status: "locked" }))
}

async fn post_vault_reset(
    State(state): State<ApiState>,
) -> Result<Json<VaultActionResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    mgr.reset_reinforced_passphrase()
        .await
        .map_err(err_to_http)?;
    Ok(Json(VaultActionResponse { status: "reset" }))
}
