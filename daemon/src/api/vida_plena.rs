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
use crate::memory_plane::{LifeSummaryWindow, ShoppingListItem};
use axum::{
    extract::{Path, Query, State},
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
        // -- BI.3.1 sprint 2: weekly shopping list generator --------
        .route(
            "/shopping/generate-weekly",
            post(post_generate_weekly_shopping_list),
        )
        // -- Vault control (BI cifrado reforzado) -------------------
        .route("/vault/status", get(get_vault_status))
        .route("/vault/set-passphrase", post(post_vault_set_passphrase))
        .route("/vault/unlock", post(post_vault_unlock))
        .route("/vault/lock", post(post_vault_lock))
        .route("/vault/reset", post(post_vault_reset))
        // -- Local PIN (segunda capa sobre el vault) ----------------
        .route("/pin/status", get(get_pin_status))
        .route("/pin/set", post(post_pin_set))
        .route("/pin/validate", post(post_pin_validate))
        .route("/pin/clear", post(post_pin_clear))
        // -- BI.3.1: food_db write endpoints (importers) ------------
        .route("/food", post(post_add_food))
        .route("/food/search", get(get_food_search))
        .route("/food/by-barcode", get(get_food_by_barcode))
        // -- BI.3.1: Open Food Facts barcode lookup -----------------
        .route("/food/lookup-off", get(get_food_lookup_off))
        // -- BI.3.1 sprint 3: live editable shopping lists ----------
        .route("/shopping/active", get(get_shopping_list_active))
        .route(
            "/shopping/lists/:list_id/items",
            post(post_add_shopping_list_item),
        )
        .route(
            "/shopping/lists/:list_id/items/:item_index",
            axum::routing::delete(delete_shopping_list_item),
        )
        .route(
            "/shopping/lists/:list_id/check-by-name",
            post(post_check_shopping_list_item_by_name),
        )
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

// ----------------------------------------------------------------------
// BI.3.1 sprint 2 — Weekly shopping list generator
// ----------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct GenerateWeeklyShoppingPayload {
    pub name: String,
    #[serde(default)]
    pub target_store_id: Option<String>,
    #[serde(default)]
    pub tag_filter: Option<String>,
    #[serde(default)]
    pub max_recipes: Option<usize>,
}

async fn post_generate_weekly_shopping_list(
    State(state): State<ApiState>,
    Json(payload): Json<GenerateWeeklyShoppingPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let max_recipes = payload.max_recipes.unwrap_or(7);
    let mgr = state.memory_plane_manager.read().await;
    let plan = mgr
        .generate_weekly_shopping_list(
            &payload.name,
            payload.target_store_id.as_deref(),
            payload.tag_filter.as_deref(),
            max_recipes,
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "plan": plan })))
}

// ----------------------------------------------------------------------
// Local PIN (segunda capa sobre el vault)
// ----------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct PinSetPayload {
    pub pin: String,
    #[serde(default)]
    pub max_failures: Option<u32>,
    #[serde(default)]
    pub auto_lock_vault_on_max_failures: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct PinValidatePayload {
    pub pin: String,
}

async fn get_pin_status(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr.local_pin_status().await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "pin": s })))
}

async fn post_pin_set(
    State(state): State<ApiState>,
    Json(payload): Json<PinSetPayload>,
) -> Result<Json<VaultActionResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    mgr.set_local_pin(
        &payload.pin,
        payload.max_failures,
        payload.auto_lock_vault_on_max_failures,
    )
    .await
    .map_err(err_to_http)?;
    Ok(Json(VaultActionResponse {
        status: "configured",
    }))
}

async fn post_pin_validate(
    State(state): State<ApiState>,
    Json(payload): Json<PinValidatePayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let result = mgr
        .validate_local_pin(&payload.pin)
        .await
        .map_err(err_to_http)?;
    let status = if result.ok {
        StatusCode::OK
    } else {
        StatusCode::FORBIDDEN
    };
    if status == StatusCode::FORBIDDEN {
        return Err((
            status,
            Json(ApiError {
                error: "Forbidden".to_string(),
                message: if result.vault_locked_as_kill_switch {
                    "PIN incorrect — vault auto-locked as kill-switch".to_string()
                } else {
                    format!(
                        "PIN incorrect — {} attempts remaining",
                        result.attempts_remaining
                    )
                },
                code: 403,
            }),
        ));
    }
    Ok(Json(serde_json::json!({ "validation": result })))
}

async fn post_pin_clear(
    State(state): State<ApiState>,
) -> Result<Json<VaultActionResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    mgr.clear_local_pin().await.map_err(err_to_http)?;
    Ok(Json(VaultActionResponse { status: "cleared" }))
}

// ----------------------------------------------------------------------
// BI.3.1 — food_db write endpoints (used by importers)
// ----------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct AddFoodPayload {
    pub name: String,
    #[serde(default)]
    pub brand: Option<String>,
    #[serde(default)]
    pub category: Option<String>,
    #[serde(default)]
    pub kcal_per_100g: Option<f64>,
    #[serde(default)]
    pub protein_g_per_100g: Option<f64>,
    #[serde(default)]
    pub carbs_g_per_100g: Option<f64>,
    #[serde(default)]
    pub fat_g_per_100g: Option<f64>,
    #[serde(default)]
    pub fiber_g_per_100g: Option<f64>,
    #[serde(default)]
    pub serving_size_g: Option<f64>,
    pub source: String,
    #[serde(default)]
    pub barcode: Option<String>,
    #[serde(default)]
    pub tags: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
pub struct FoodSearchQuery {
    pub q: String,
    #[serde(default)]
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
pub struct BarcodeQuery {
    pub barcode: String,
}

async fn post_add_food(
    State(state): State<ApiState>,
    Json(payload): Json<AddFoodPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let tags = payload.tags.unwrap_or_default();
    let food = mgr
        .add_food(
            &payload.name,
            payload.brand.as_deref(),
            payload.category.as_deref(),
            payload.kcal_per_100g,
            payload.protein_g_per_100g,
            payload.carbs_g_per_100g,
            payload.fat_g_per_100g,
            payload.fiber_g_per_100g,
            payload.serving_size_g,
            &payload.source,
            payload.barcode.as_deref(),
            &tags,
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "food": food })))
}

async fn get_food_search(
    State(state): State<ApiState>,
    Query(q): Query<FoodSearchQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let limit = q.limit.unwrap_or(20);
    let mgr = state.memory_plane_manager.read().await;
    let foods = mgr.search_foods(&q.q, limit).await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({
        "foods": foods,
        "count": foods.len(),
    })))
}

async fn get_food_by_barcode(
    State(state): State<ApiState>,
    Query(q): Query<BarcodeQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let food = mgr
        .get_food_by_barcode(&q.barcode)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "food": food })))
}

/// Look up a barcode against Open Food Facts. Does NOT persist —
/// the dashboard or LLM is expected to inspect the result and
/// optionally POST it to /food separately if the user confirms.
async fn get_food_lookup_off(
    Query(q): Query<BarcodeQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let result = crate::food_lookup::lookup_off(&q.barcode)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "lookup": result })))
}

// ----------------------------------------------------------------------
// BI.3.1 sprint 3 — Live editable shopping lists
// ----------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct AddShoppingItemPayload {
    pub item: ShoppingListItem,
}

#[derive(Debug, Deserialize)]
pub struct CheckByNamePayload {
    pub needle: String,
    #[serde(default = "default_true")]
    pub checked: bool,
}

fn default_true() -> bool {
    true
}

async fn get_shopping_list_active(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr.get_active_shopping_list().await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "list": list })))
}

async fn post_add_shopping_list_item(
    State(state): State<ApiState>,
    Path(list_id): Path<String>,
    Json(payload): Json<AddShoppingItemPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let updated = mgr
        .add_shopping_list_item(&list_id, payload.item)
        .await
        .map_err(err_to_http)?;
    match updated {
        Some(l) => Ok(Json(serde_json::json!({ "list": l }))),
        None => Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "Not Found".to_string(),
                message: format!("no shopping list with id {}", list_id),
                code: 404,
            }),
        )),
    }
}

async fn delete_shopping_list_item(
    State(state): State<ApiState>,
    Path((list_id, item_index)): Path<(String, usize)>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let removed = mgr
        .remove_shopping_list_item(&list_id, item_index)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "removed": removed })))
}

async fn post_check_shopping_list_item_by_name(
    State(state): State<ApiState>,
    Path(list_id): Path<String>,
    Json(payload): Json<CheckByNamePayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let m = mgr
        .check_shopping_list_item_by_name(&list_id, &payload.needle, payload.checked)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "match": m })))
}
