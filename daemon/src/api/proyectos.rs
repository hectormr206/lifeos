//! Proyectos Domain HTTP API endpoints.
//!
//! Lightweight personal project tracker: proyectos + milestones +
//! dependencias. Auth follows the same convention as the rest of
//! `/api/v1/*` — the `x-bootstrap-token` middleware in `mod.rs` covers
//! everything nested under this router.

use super::{ApiError, ApiState};
use crate::memory_plane::ProyectoListFilter;
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};

pub fn proyectos_routes() -> Router<ApiState> {
    Router::new()
        // -- Proyectos CRUD ---------------------------------------------
        .route("/", get(get_proyectos_list).post(post_proyecto_add))
        .route(
            "/:proyecto_id",
            get(get_proyecto).post(post_proyecto_update),
        )
        .route("/:proyecto_id/pausar", post(post_proyecto_pausar))
        .route("/:proyecto_id/completar", post(post_proyecto_completar))
        .route("/:proyecto_id/cancelar", post(post_proyecto_cancelar))
        .route("/:proyecto_id/bloquear", post(post_proyecto_bloquear))
        // -- Milestones -------------------------------------------------
        .route(
            "/:proyecto_id/milestones",
            get(get_milestones_list).post(post_milestone_add),
        )
        .route("/milestones/:milestone_id", post(post_milestone_update))
        .route(
            "/milestones/:milestone_id/completar",
            post(post_milestone_completar),
        )
        // -- Dependencias -----------------------------------------------
        .route(
            "/:proyecto_id/dependencias",
            get(get_dependencias).post(post_dependencia_add),
        )
        // -- Analytics --------------------------------------------------
        .route("/overview", get(get_overview))
        .route("/priorizados", get(get_priorizados))
        .route("/atrasados", get(get_atrasados))
        .route("/:proyecto_id/progress", get(get_progress))
        .route("/milestones/proximos", get(get_milestones_proximos))
}

fn err_to_http(e: anyhow::Error) -> (StatusCode, Json<ApiError>) {
    let msg = e.to_string();
    let status = if msg.contains("requerido") || msg.contains("invalido") || msg.contains("debe ") {
        StatusCode::BAD_REQUEST
    } else if msg.contains("no existe") {
        StatusCode::NOT_FOUND
    } else if msg.contains("ciclo") || msg.contains("rechaz") {
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

// ----------------------------------------------------------------------
// Payloads
// ----------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct ProyectoAddPayload {
    pub nombre: String,
    #[serde(default)]
    pub descripcion: String,
    pub tipo: String,
    #[serde(default = "default_prioridad")]
    pub prioridad: i32,
    #[serde(default)]
    pub fecha_inicio: Option<String>,
    #[serde(default)]
    pub fecha_objetivo: Option<String>,
    #[serde(default)]
    pub presupuesto_estimado: Option<f64>,
    #[serde(default)]
    pub ruta_disco: Option<String>,
    #[serde(default)]
    pub url_externo: Option<String>,
    #[serde(default)]
    pub notas: String,
}

fn default_prioridad() -> i32 {
    5
}

#[derive(Debug, Deserialize)]
pub struct ProyectoUpdatePayload {
    #[serde(default)]
    pub nombre: Option<String>,
    #[serde(default)]
    pub descripcion: Option<String>,
    #[serde(default)]
    pub tipo: Option<String>,
    #[serde(default)]
    pub prioridad: Option<i32>,
    #[serde(default)]
    pub fecha_inicio: Option<String>,
    #[serde(default)]
    pub fecha_objetivo: Option<String>,
    #[serde(default)]
    pub presupuesto_estimado: Option<f64>,
    #[serde(default)]
    pub presupuesto_gastado: Option<f64>,
    #[serde(default)]
    pub ruta_disco: Option<String>,
    #[serde(default)]
    pub url_externo: Option<String>,
    #[serde(default)]
    pub notas: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ProyectoListQuery {
    #[serde(default)]
    pub estado: Option<String>,
    #[serde(default)]
    pub tipo: Option<String>,
    #[serde(default)]
    pub prioridad_min: Option<i32>,
    #[serde(default)]
    pub prioridad_max: Option<i32>,
}

#[derive(Debug, Deserialize)]
pub struct BloquearPayload {
    pub bloqueado_por: String,
}

#[derive(Debug, Deserialize)]
pub struct MilestoneAddPayload {
    pub nombre: String,
    #[serde(default)]
    pub descripcion: String,
    #[serde(default)]
    pub fecha_objetivo: Option<String>,
    #[serde(default)]
    pub orden: i32,
    #[serde(default)]
    pub notas: String,
}

#[derive(Debug, Deserialize)]
pub struct MilestoneUpdatePayload {
    #[serde(default)]
    pub nombre: Option<String>,
    #[serde(default)]
    pub descripcion: Option<String>,
    #[serde(default)]
    pub fecha_objetivo: Option<String>,
    #[serde(default)]
    pub orden: Option<i32>,
    #[serde(default)]
    pub notas: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct DependenciaAddPayload {
    pub depende_de_id: String,
    #[serde(default)]
    pub tipo: Option<String>,
    #[serde(default)]
    pub notas: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct PriorizadosQuery {
    #[serde(default)]
    pub top_n: Option<i32>,
}

#[derive(Debug, Deserialize, Default)]
pub struct ProximosQuery {
    #[serde(default)]
    pub dias: Option<i32>,
}

#[derive(Debug, Serialize)]
pub struct UpdateResponse {
    pub updated: bool,
}

// ----------------------------------------------------------------------
// Handlers — Proyectos CRUD
// ----------------------------------------------------------------------

async fn post_proyecto_add(
    State(state): State<ApiState>,
    Json(p): Json<ProyectoAddPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let proyecto = mgr
        .proyecto_add(
            &p.nombre,
            &p.descripcion,
            &p.tipo,
            p.prioridad,
            p.fecha_inicio.as_deref(),
            p.fecha_objetivo.as_deref(),
            p.presupuesto_estimado,
            p.ruta_disco.as_deref(),
            p.url_externo.as_deref(),
            &p.notas,
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "proyecto": proyecto })))
}

async fn get_proyectos_list(
    State(state): State<ApiState>,
    Query(q): Query<ProyectoListQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let filter = ProyectoListFilter {
        estado: q.estado,
        tipo: q.tipo,
        prioridad_min: q.prioridad_min,
        prioridad_max: q.prioridad_max,
    };
    let list = mgr.proyecto_list(filter).await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({
        "proyectos": list,
        "count": list.len(),
    })))
}

async fn get_proyecto(
    State(state): State<ApiState>,
    Path(proyecto_id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let p = mgr.proyecto_get(&proyecto_id).await.map_err(err_to_http)?;
    match p {
        Some(p) => Ok(Json(serde_json::json!({ "proyecto": p }))),
        None => Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "Not Found".into(),
                message: format!("no proyecto with id {}", proyecto_id),
                code: 404,
            }),
        )),
    }
}

async fn post_proyecto_update(
    State(state): State<ApiState>,
    Path(proyecto_id): Path<String>,
    Json(p): Json<ProyectoUpdatePayload>,
) -> Result<Json<UpdateResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let updated = mgr
        .proyecto_update(
            &proyecto_id,
            p.nombre.as_deref(),
            p.descripcion.as_deref(),
            p.tipo.as_deref(),
            p.prioridad,
            p.fecha_inicio.as_deref(),
            p.fecha_objetivo.as_deref(),
            p.presupuesto_estimado,
            p.presupuesto_gastado,
            p.ruta_disco.as_deref(),
            p.url_externo.as_deref(),
            p.notas.as_deref(),
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(UpdateResponse { updated }))
}

async fn post_proyecto_pausar(
    State(state): State<ApiState>,
    Path(proyecto_id): Path<String>,
) -> Result<Json<UpdateResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let updated = mgr
        .proyecto_pausar(&proyecto_id)
        .await
        .map_err(err_to_http)?;
    Ok(Json(UpdateResponse { updated }))
}

async fn post_proyecto_completar(
    State(state): State<ApiState>,
    Path(proyecto_id): Path<String>,
) -> Result<Json<UpdateResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let updated = mgr
        .proyecto_completar(&proyecto_id)
        .await
        .map_err(err_to_http)?;
    Ok(Json(UpdateResponse { updated }))
}

async fn post_proyecto_cancelar(
    State(state): State<ApiState>,
    Path(proyecto_id): Path<String>,
) -> Result<Json<UpdateResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let updated = mgr
        .proyecto_cancelar(&proyecto_id)
        .await
        .map_err(err_to_http)?;
    Ok(Json(UpdateResponse { updated }))
}

async fn post_proyecto_bloquear(
    State(state): State<ApiState>,
    Path(proyecto_id): Path<String>,
    Json(p): Json<BloquearPayload>,
) -> Result<Json<UpdateResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let updated = mgr
        .proyecto_bloquear(&proyecto_id, &p.bloqueado_por)
        .await
        .map_err(err_to_http)?;
    Ok(Json(UpdateResponse { updated }))
}

// ----------------------------------------------------------------------
// Handlers — Milestones
// ----------------------------------------------------------------------

async fn post_milestone_add(
    State(state): State<ApiState>,
    Path(proyecto_id): Path<String>,
    Json(p): Json<MilestoneAddPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let m = mgr
        .milestone_add(
            &proyecto_id,
            &p.nombre,
            &p.descripcion,
            p.fecha_objetivo.as_deref(),
            p.orden,
            &p.notas,
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "milestone": m })))
}

async fn get_milestones_list(
    State(state): State<ApiState>,
    Path(proyecto_id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ms = mgr
        .milestone_list(&proyecto_id)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({
        "milestones": ms,
        "count": ms.len(),
    })))
}

async fn post_milestone_completar(
    State(state): State<ApiState>,
    Path(milestone_id): Path<String>,
) -> Result<Json<UpdateResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let updated = mgr
        .milestone_completar(&milestone_id)
        .await
        .map_err(err_to_http)?;
    Ok(Json(UpdateResponse { updated }))
}

async fn post_milestone_update(
    State(state): State<ApiState>,
    Path(milestone_id): Path<String>,
    Json(p): Json<MilestoneUpdatePayload>,
) -> Result<Json<UpdateResponse>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let updated = mgr
        .milestone_update(
            &milestone_id,
            p.nombre.as_deref(),
            p.descripcion.as_deref(),
            p.fecha_objetivo.as_deref(),
            p.orden,
            p.notas.as_deref(),
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(UpdateResponse { updated }))
}

// ----------------------------------------------------------------------
// Handlers — Dependencias
// ----------------------------------------------------------------------

async fn post_dependencia_add(
    State(state): State<ApiState>,
    Path(proyecto_id): Path<String>,
    Json(p): Json<DependenciaAddPayload>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let dep = mgr
        .proyecto_dependencia_add(
            &proyecto_id,
            &p.depende_de_id,
            p.tipo.as_deref(),
            p.notas.as_deref(),
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "dependencia": dep })))
}

async fn get_dependencias(
    State(state): State<ApiState>,
    Path(proyecto_id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let set = mgr
        .proyecto_dependencias_list(&proyecto_id)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "dependencias": set })))
}

// ----------------------------------------------------------------------
// Handlers — Analytics
// ----------------------------------------------------------------------

async fn get_overview(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ov = mgr.proyectos_overview().await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "overview": ov })))
}

async fn get_priorizados(
    State(state): State<ApiState>,
    Query(q): Query<PriorizadosQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let top_n = q.top_n.unwrap_or(5);
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr
        .proyectos_priorizados(top_n)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({
        "proyectos": list,
        "count": list.len(),
    })))
}

async fn get_atrasados(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr.proyectos_atrasados().await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({
        "proyectos": list,
        "count": list.len(),
    })))
}

async fn get_progress(
    State(state): State<ApiState>,
    Path(proyecto_id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let progress = mgr
        .proyecto_progress(&proyecto_id)
        .await
        .map_err(err_to_http)?;
    match progress {
        Some(p) => Ok(Json(serde_json::json!({ "progress": p }))),
        None => Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "Not Found".into(),
                message: format!("no proyecto with id {}", proyecto_id),
                code: 404,
            }),
        )),
    }
}

async fn get_milestones_proximos(
    State(state): State<ApiState>,
    Query(q): Query<ProximosQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let dias = q.dias.unwrap_or(7);
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr
        .milestones_proximos_dias(dias)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({
        "milestones": list,
        "count": list.len(),
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proyectos_routes_builds_without_panic() {
        let _r = proyectos_routes();
    }

    #[test]
    fn err_to_http_maps_no_existe_to_not_found() {
        let (status, _) = err_to_http(anyhow::anyhow!("proyecto_id 'foo' no existe"));
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    #[test]
    fn err_to_http_maps_ciclo_to_conflict() {
        let (status, _) = err_to_http(anyhow::anyhow!("dependencia rechazada: introduce un ciclo"));
        assert_eq!(status, StatusCode::CONFLICT);
    }

    #[test]
    fn err_to_http_maps_requerido_to_bad_request() {
        let (status, _) = err_to_http(anyhow::anyhow!("nombre requerido"));
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    #[test]
    fn default_prioridad_is_5() {
        assert_eq!(default_prioridad(), 5);
    }
}
