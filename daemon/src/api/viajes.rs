//! Viajes Domain HTTP API endpoints (BI.viajes).
//!
//! REST surface mounted under `/api/v1/viajes`. Auth handled by the
//! `x-bootstrap-token` middleware in `mod.rs`.
//!
//! Notas, descripciones y alojamiento se cifran at-rest dentro del
//! `MemoryPlaneManager`; este modulo solo orquesta entrada/salida JSON.

use super::{ApiError, ApiState};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{get, patch, post},
    Router,
};
use serde::Deserialize;

pub fn viajes_routes() -> Router<ApiState> {
    Router::new()
        // -- Viajes (header) ---------------------------------------------
        .route("/", post(post_viaje_add).get(get_viaje_list))
        .route("/overview", get(get_viajes_overview))
        .route("/by-destino", get(get_viajes_a))
        .route("/cuanto-gaste", get(get_cuanto_gaste_en))
        .route("/compare", get(get_comparar_viajes))
        .route("/:viaje_id", get(get_viaje).patch(patch_viaje))
        .route("/:viaje_id/iniciar", post(post_viaje_iniciar))
        .route("/:viaje_id/completar", post(post_viaje_completar))
        .route("/:viaje_id/cancelar", post(post_viaje_cancelar))
        .route("/:viaje_id/resumen", get(get_viaje_resumen))
        // -- Destinos -----------------------------------------------------
        .route(
            "/:viaje_id/destinos",
            post(post_destino_add).get(get_destino_list),
        )
        .route("/destinos/:destino_id", patch(patch_destino))
        // -- Actividades --------------------------------------------------
        .route(
            "/:viaje_id/actividades",
            post(post_actividad_log).get(get_actividades_list),
        )
        .route(
            "/actividades/:actividad_id/recomendar",
            post(post_actividad_recomendar),
        )
}

// ---------------------------------------------------------------------------
// Common helpers
// ---------------------------------------------------------------------------

fn err_to_http(e: anyhow::Error) -> (StatusCode, Json<ApiError>) {
    let msg = e.to_string();
    let status = if msg.contains("required") || msg.contains("must be") || msg.contains("invalid") {
        StatusCode::BAD_REQUEST
    } else if msg.contains("not found") {
        StatusCode::NOT_FOUND
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

fn not_found(what: &str, id: &str) -> (StatusCode, Json<ApiError>) {
    (
        StatusCode::NOT_FOUND,
        Json(ApiError {
            error: "Not Found".to_string(),
            message: format!("no {} with id {}", what, id),
            code: 404,
        }),
    )
}

// ---------------------------------------------------------------------------
// Request bodies & query strings
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct ViajeAddBody {
    pub nombre: String,
    pub destino: String,
    pub pais: Option<String>,
    pub motivo: Option<String>,
    pub fecha_inicio: String,
    pub fecha_fin: String,
    pub acompanantes: Option<String>,
    pub presupuesto_inicial: Option<f64>,
    #[serde(default)]
    pub notas: String,
    pub fotos_path: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct ViajeListQuery {
    pub estado: Option<String>,
    pub year: Option<i32>,
}

#[derive(Debug, Deserialize, Default)]
pub struct ViajeUpdateBody {
    pub nombre: Option<String>,
    pub destino: Option<String>,
    pub pais: Option<String>,
    pub motivo: Option<String>,
    pub fecha_inicio: Option<String>,
    pub fecha_fin: Option<String>,
    pub acompanantes: Option<String>,
    pub presupuesto_inicial: Option<f64>,
    pub notas: Option<String>,
    pub fotos_path: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct DestinoAddBody {
    pub ciudad: String,
    pub pais: Option<String>,
    pub fecha_llegada: String,
    pub fecha_salida: Option<String>,
    #[serde(default)]
    pub alojamiento: String,
    #[serde(default)]
    pub notas: String,
}

#[derive(Debug, Deserialize, Default)]
pub struct DestinoUpdateBody {
    pub ciudad: Option<String>,
    pub pais: Option<String>,
    pub fecha_llegada: Option<String>,
    pub fecha_salida: Option<String>,
    pub alojamiento: Option<String>,
    pub notas: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ActividadLogBody {
    pub fecha: String,
    pub titulo: String,
    #[serde(default)]
    pub descripcion: String,
    pub tipo: Option<String>,
    pub costo: Option<f64>,
    pub movimiento_id: Option<String>,
    pub rating: Option<i32>,
    pub recomendaria: Option<bool>,
    #[serde(default)]
    pub notas: String,
}

#[derive(Debug, Deserialize)]
pub struct ActividadRecomendarBody {
    pub rating: i32,
    pub recomendaria: bool,
}

#[derive(Debug, Deserialize, Default)]
pub struct OverviewQuery {
    pub year: Option<i32>,
}

#[derive(Debug, Deserialize)]
pub struct DestinoOPaisQuery {
    pub destino_o_pais: String,
}

#[derive(Debug, Deserialize)]
pub struct CompareQuery {
    pub viaje_a: String,
    pub viaje_b: String,
}

// ---------------------------------------------------------------------------
// Handlers — Viajes header
// ---------------------------------------------------------------------------

async fn post_viaje_add(
    State(state): State<ApiState>,
    Json(body): Json<ViajeAddBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let v = mgr
        .viaje_add(
            &body.nombre,
            &body.destino,
            body.pais.as_deref(),
            body.motivo.as_deref(),
            &body.fecha_inicio,
            &body.fecha_fin,
            body.acompanantes.as_deref(),
            body.presupuesto_inicial,
            &body.notas,
            body.fotos_path.as_deref(),
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "viaje": v })))
}

async fn get_viaje_list(
    State(state): State<ApiState>,
    Query(q): Query<ViajeListQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr
        .viaje_list(q.estado.as_deref(), q.year)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "viajes": list })))
}

async fn get_viaje(
    State(state): State<ApiState>,
    Path(viaje_id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    match mgr.viaje_get(&viaje_id).await.map_err(err_to_http)? {
        Some(v) => Ok(Json(serde_json::json!({ "viaje": v }))),
        None => Err(not_found("viaje", &viaje_id)),
    }
}

async fn patch_viaje(
    State(state): State<ApiState>,
    Path(viaje_id): Path<String>,
    Json(body): Json<ViajeUpdateBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let updated = mgr
        .viaje_update(
            &viaje_id,
            body.nombre.as_deref(),
            body.destino.as_deref(),
            body.pais.as_deref(),
            body.motivo.as_deref(),
            body.fecha_inicio.as_deref(),
            body.fecha_fin.as_deref(),
            body.acompanantes.as_deref(),
            body.presupuesto_inicial,
            body.notas.as_deref(),
            body.fotos_path.as_deref(),
        )
        .await
        .map_err(err_to_http)?;
    if !updated {
        return Err(not_found("viaje", &viaje_id));
    }
    Ok(Json(
        serde_json::json!({ "updated": true, "viaje_id": viaje_id }),
    ))
}

async fn post_viaje_iniciar(
    State(state): State<ApiState>,
    Path(viaje_id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr.viaje_iniciar(&viaje_id).await.map_err(err_to_http)?;
    if !ok {
        return Err(not_found("viaje", &viaje_id));
    }
    Ok(Json(serde_json::json!({ "estado": "en_curso" })))
}

async fn post_viaje_completar(
    State(state): State<ApiState>,
    Path(viaje_id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr.viaje_completar(&viaje_id).await.map_err(err_to_http)?;
    if !ok {
        return Err(not_found("viaje", &viaje_id));
    }
    Ok(Json(serde_json::json!({ "estado": "completado" })))
}

async fn post_viaje_cancelar(
    State(state): State<ApiState>,
    Path(viaje_id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr.viaje_cancelar(&viaje_id).await.map_err(err_to_http)?;
    if !ok {
        return Err(not_found("viaje", &viaje_id));
    }
    Ok(Json(serde_json::json!({ "estado": "cancelado" })))
}

// ---------------------------------------------------------------------------
// Handlers — Destinos
// ---------------------------------------------------------------------------

async fn post_destino_add(
    State(state): State<ApiState>,
    Path(viaje_id): Path<String>,
    Json(body): Json<DestinoAddBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let d = mgr
        .destino_add(
            &viaje_id,
            &body.ciudad,
            body.pais.as_deref(),
            &body.fecha_llegada,
            body.fecha_salida.as_deref(),
            &body.alojamiento,
            &body.notas,
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "destino": d })))
}

async fn get_destino_list(
    State(state): State<ApiState>,
    Path(viaje_id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr.destino_list(&viaje_id).await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "destinos": list })))
}

async fn patch_destino(
    State(state): State<ApiState>,
    Path(destino_id): Path<String>,
    Json(body): Json<DestinoUpdateBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let updated = mgr
        .destino_update(
            &destino_id,
            body.ciudad.as_deref(),
            body.pais.as_deref(),
            body.fecha_llegada.as_deref(),
            body.fecha_salida.as_deref(),
            body.alojamiento.as_deref(),
            body.notas.as_deref(),
        )
        .await
        .map_err(err_to_http)?;
    if !updated {
        return Err(not_found("destino", &destino_id));
    }
    Ok(Json(
        serde_json::json!({ "updated": true, "destino_id": destino_id }),
    ))
}

// ---------------------------------------------------------------------------
// Handlers — Actividades
// ---------------------------------------------------------------------------

async fn post_actividad_log(
    State(state): State<ApiState>,
    Path(viaje_id): Path<String>,
    Json(body): Json<ActividadLogBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let a = mgr
        .actividad_log(
            &viaje_id,
            &body.fecha,
            &body.titulo,
            &body.descripcion,
            body.tipo.as_deref(),
            body.costo,
            body.movimiento_id.as_deref(),
            body.rating,
            body.recomendaria,
            &body.notas,
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "actividad": a })))
}

async fn get_actividades_list(
    State(state): State<ApiState>,
    Path(viaje_id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr.actividades_list(&viaje_id).await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "actividades": list })))
}

async fn post_actividad_recomendar(
    State(state): State<ApiState>,
    Path(actividad_id): Path<String>,
    Json(body): Json<ActividadRecomendarBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr
        .actividad_recomendar(&actividad_id, body.rating, body.recomendaria)
        .await
        .map_err(err_to_http)?;
    if !ok {
        return Err(not_found("actividad", &actividad_id));
    }
    Ok(Json(serde_json::json!({
        "updated": true,
        "actividad_id": actividad_id,
    })))
}

// ---------------------------------------------------------------------------
// Handlers — Analytics
// ---------------------------------------------------------------------------

async fn get_viajes_overview(
    State(state): State<ApiState>,
    Query(q): Query<OverviewQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr.viajes_overview(q.year).await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "overview": s })))
}

async fn get_viaje_resumen(
    State(state): State<ApiState>,
    Path(viaje_id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    match mgr.viaje_resumen(&viaje_id).await.map_err(err_to_http)? {
        Some(r) => Ok(Json(serde_json::json!({ "resumen": r }))),
        None => Err(not_found("viaje", &viaje_id)),
    }
}

async fn get_comparar_viajes(
    State(state): State<ApiState>,
    Query(q): Query<CompareQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let cmp = mgr
        .comparar_viajes(&q.viaje_a, &q.viaje_b)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "comparison": cmp })))
}

async fn get_viajes_a(
    State(state): State<ApiState>,
    Query(q): Query<DestinoOPaisQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let agg = mgr.viajes_a(&q.destino_o_pais).await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "result": agg })))
}

async fn get_cuanto_gaste_en(
    State(state): State<ApiState>,
    Query(q): Query<DestinoOPaisQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let total = mgr
        .cuanto_gaste_en(&q.destino_o_pais)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({
        "destino_o_pais": q.destino_o_pais,
        "total_gastos": total,
    })))
}
