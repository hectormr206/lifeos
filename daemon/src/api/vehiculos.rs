//! Vehículos Domain MVP — HTTP API endpoints.
//!
//! Mounts under `/api/v1/vehiculos/`. Surfaces the inventory, mantenimientos,
//! seguros, combustible y analytics del dominio Vehiculos.
//!
//! Convencion:
//! - Notas, descripciones, taller y agente se cifran en disco.
//! - Los montos viajan en REAL plaintext para analytics.
//! - UUIDs tipados con prefijos: `veh-`, `man-`, `seg-`, `fuel-`.
//!
//! Auth: hereda `x-bootstrap-token` del middleware en `mod.rs`.

use super::{ApiError, ApiState};
use crate::memory_plane::VehiculoUpdate;
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{get, patch, post},
    Router,
};
use serde::Deserialize;

pub fn vehiculos_routes() -> Router<ApiState> {
    Router::new()
        // Vehiculos
        .route("/", post(post_vehiculo_add).get(get_vehiculo_list))
        .route("/overview", get(get_vehiculos_overview))
        .route("/proximos-mantenimientos", get(get_mantenimientos_proximos))
        .route("/seguros-por-vencer", get(get_seguros_por_vencer))
        .route("/:id", get(get_vehiculo).patch(patch_vehiculo))
        .route("/:id/kilometraje", patch(patch_vehiculo_kilometraje))
        .route("/:id/vender", post(post_vehiculo_vender))
        .route("/:id/costo-total", get(get_vehiculo_costo_total))
        .route("/:id/rendimiento", get(get_rendimiento_combustible))
        // Mantenimientos
        .route(
            "/:id/mantenimientos",
            get(get_mantenimientos_for_vehiculo).post(post_mantenimiento_log),
        )
        .route(
            "/:id/mantenimientos/programar",
            post(post_mantenimiento_programar),
        )
        .route(
            "/mantenimientos/:mid/completar",
            post(post_mantenimiento_completar),
        )
        // Seguros
        .route(
            "/:id/seguros",
            get(get_seguros_for_vehiculo).post(post_seguro_add),
        )
        .route("/seguros/:sid/renovar", post(post_seguro_renovar))
        // Combustible
        .route("/:id/combustible", post(post_combustible_log))
        .route("/:id/combustible/stats", get(get_combustible_stats))
}

fn err(e: anyhow::Error) -> (StatusCode, Json<ApiError>) {
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

#[derive(Debug, Deserialize, Default)]
pub struct VehiculoListQuery {
    pub include_inactive: Option<bool>,
}

#[derive(Debug, Deserialize, Default)]
pub struct DiasQuery {
    pub dias: Option<i64>,
}

#[derive(Debug, Deserialize, Default)]
pub struct VehiculoEstadoQuery {
    pub estado: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct CombustibleStatsQuery {
    pub ultimas_n: Option<usize>,
}

#[derive(Debug, Deserialize, Default)]
pub struct CostoTotalQuery {
    pub periodo: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct VehiculoAddBody {
    pub alias: String,
    pub marca: String,
    pub modelo: String,
    pub anio: Option<i64>,
    pub placas: Option<String>,
    pub vin: Option<String>,
    pub color: Option<String>,
    pub kilometraje_actual: Option<i64>,
    pub fecha_compra: Option<String>,
    pub precio_compra: Option<f64>,
    pub titular: Option<String>,
    pub notas: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct KmBody {
    pub kilometraje: i64,
}

#[derive(Debug, Deserialize)]
pub struct VenderBody {
    pub fecha_baja: String,
    pub precio_venta: f64,
}

#[derive(Debug, Deserialize)]
pub struct MantenimientoLogBody {
    pub tipo: String,
    pub descripcion: Option<String>,
    pub fecha_realizado: Option<String>,
    pub kilometraje_realizado: Option<i64>,
    pub km_proximo: Option<i64>,
    pub taller: Option<String>,
    pub costo: Option<f64>,
    pub movimiento_id: Option<String>,
    pub notas: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct MantenimientoProgramarBody {
    pub tipo: String,
    pub descripcion: Option<String>,
    pub fecha_programada: String,
    pub km_proximo: Option<i64>,
    pub taller: Option<String>,
    pub notas: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct MantenimientoCompletarBody {
    pub fecha_realizado: Option<String>,
    pub kilometraje_realizado: Option<i64>,
    pub costo: Option<f64>,
}

#[derive(Debug, Deserialize)]
pub struct SeguroAddBody {
    pub aseguradora: String,
    pub tipo: String,
    pub numero_poliza: Option<String>,
    pub fecha_inicio: String,
    pub fecha_vencimiento: String,
    pub prima_total: Option<f64>,
    pub cobertura_rc: Option<f64>,
    pub deducible_dh: Option<f64>,
    pub agente: Option<String>,
    pub movimiento_id: Option<String>,
    pub notas: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CombustibleLogBody {
    pub fecha: Option<String>,
    pub litros: Option<f64>,
    pub monto: f64,
    pub precio_litro: Option<f64>,
    pub kilometraje: Option<i64>,
    pub estacion: Option<String>,
    pub movimiento_id: Option<String>,
    pub notas: Option<String>,
}

// ----------------------------------------------------------------------
// Vehiculos handlers
// ----------------------------------------------------------------------

async fn post_vehiculo_add(
    State(state): State<ApiState>,
    Json(body): Json<VehiculoAddBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let v = mgr
        .vehiculo_add(
            &body.alias,
            &body.marca,
            &body.modelo,
            body.anio,
            body.placas.as_deref(),
            body.vin.as_deref(),
            body.color.as_deref(),
            body.kilometraje_actual,
            body.fecha_compra.as_deref(),
            body.precio_compra,
            body.titular.as_deref(),
            body.notas.as_deref().unwrap_or(""),
        )
        .await
        .map_err(err)?;
    Ok(Json(serde_json::json!({ "vehiculo": v })))
}

async fn get_vehiculo_list(
    State(state): State<ApiState>,
    Query(q): Query<VehiculoListQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let vs = mgr
        .vehiculo_list(q.include_inactive.unwrap_or(false))
        .await
        .map_err(err)?;
    Ok(Json(serde_json::json!({ "vehiculos": vs })))
}

async fn get_vehiculo(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    match mgr.vehiculo_get(&id).await.map_err(err)? {
        None => Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "Not Found".into(),
                message: format!("vehiculo {} not found", id),
                code: 404,
            }),
        )),
        Some(v) => Ok(Json(serde_json::json!({ "vehiculo": v }))),
    }
}

async fn patch_vehiculo(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(body): Json<VehiculoUpdate>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr.vehiculo_update(&id, body).await.map_err(err)?;
    Ok(Json(serde_json::json!({ "updated": ok })))
}

async fn patch_vehiculo_kilometraje(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(body): Json<KmBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr
        .vehiculo_kilometraje_actualizar(&id, body.kilometraje)
        .await
        .map_err(err)?;
    Ok(Json(
        serde_json::json!({ "updated": ok, "kilometraje": body.kilometraje }),
    ))
}

async fn post_vehiculo_vender(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(body): Json<VenderBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr
        .vehiculo_vender(&id, &body.fecha_baja, body.precio_venta)
        .await
        .map_err(err)?;
    Ok(Json(serde_json::json!({ "updated": ok })))
}

async fn get_vehiculos_overview(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let o = mgr.vehiculos_overview().await.map_err(err)?;
    Ok(Json(serde_json::json!({ "overview": o })))
}

async fn get_vehiculo_costo_total(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Query(q): Query<CostoTotalQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let periodo = q.periodo.as_deref().unwrap_or("mes");
    let c = mgr.vehiculo_costo_total(&id, periodo).await.map_err(err)?;
    Ok(Json(serde_json::json!({ "costo": c })))
}

async fn get_rendimiento_combustible(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let r = mgr.rendimiento_combustible(&id).await.map_err(err)?;
    Ok(Json(serde_json::json!({ "rendimiento": r })))
}

// ----------------------------------------------------------------------
// Mantenimientos handlers
// ----------------------------------------------------------------------

async fn post_mantenimiento_log(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(body): Json<MantenimientoLogBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let m = mgr
        .mantenimiento_log(
            &id,
            &body.tipo,
            body.descripcion.as_deref().unwrap_or(""),
            body.fecha_realizado.as_deref(),
            body.kilometraje_realizado,
            body.km_proximo,
            body.taller.as_deref().unwrap_or(""),
            body.costo,
            body.movimiento_id.as_deref(),
            body.notas.as_deref().unwrap_or(""),
        )
        .await
        .map_err(err)?;
    Ok(Json(serde_json::json!({ "mantenimiento": m })))
}

async fn post_mantenimiento_programar(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(body): Json<MantenimientoProgramarBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let m = mgr
        .mantenimiento_programar(
            &id,
            &body.tipo,
            body.descripcion.as_deref().unwrap_or(""),
            &body.fecha_programada,
            body.km_proximo,
            body.taller.as_deref().unwrap_or(""),
            body.notas.as_deref().unwrap_or(""),
        )
        .await
        .map_err(err)?;
    Ok(Json(serde_json::json!({ "mantenimiento": m })))
}

async fn post_mantenimiento_completar(
    State(state): State<ApiState>,
    Path(mid): Path<String>,
    Json(body): Json<MantenimientoCompletarBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr
        .mantenimiento_completar(
            &mid,
            body.fecha_realizado.as_deref(),
            body.kilometraje_realizado,
            body.costo,
        )
        .await
        .map_err(err)?;
    Ok(Json(serde_json::json!({ "updated": ok })))
}

async fn get_mantenimientos_for_vehiculo(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Query(q): Query<VehiculoEstadoQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ms = mgr
        .mantenimiento_list(Some(&id), q.estado.as_deref())
        .await
        .map_err(err)?;
    Ok(Json(serde_json::json!({ "mantenimientos": ms })))
}

async fn get_mantenimientos_proximos(
    State(state): State<ApiState>,
    Query(q): Query<DiasQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ms = mgr
        .mantenimientos_proximos(q.dias.unwrap_or(30))
        .await
        .map_err(err)?;
    Ok(Json(serde_json::json!({ "mantenimientos": ms })))
}

// ----------------------------------------------------------------------
// Seguros handlers
// ----------------------------------------------------------------------

async fn post_seguro_add(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(body): Json<SeguroAddBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr
        .seguro_add(
            &id,
            &body.aseguradora,
            &body.tipo,
            body.numero_poliza.as_deref(),
            &body.fecha_inicio,
            &body.fecha_vencimiento,
            body.prima_total,
            body.cobertura_rc,
            body.deducible_dh,
            body.agente.as_deref().unwrap_or(""),
            body.movimiento_id.as_deref(),
            body.notas.as_deref().unwrap_or(""),
        )
        .await
        .map_err(err)?;
    Ok(Json(serde_json::json!({ "seguro": s })))
}

async fn post_seguro_renovar(
    State(state): State<ApiState>,
    Path(sid): Path<String>,
    Json(body): Json<SeguroAddBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr
        .seguro_renovar(
            &sid,
            &body.aseguradora,
            &body.tipo,
            body.numero_poliza.as_deref(),
            &body.fecha_inicio,
            &body.fecha_vencimiento,
            body.prima_total,
            body.cobertura_rc,
            body.deducible_dh,
            body.agente.as_deref().unwrap_or(""),
            body.movimiento_id.as_deref(),
            body.notas.as_deref().unwrap_or(""),
        )
        .await
        .map_err(err)?;
    Ok(Json(serde_json::json!({ "seguro": s })))
}

async fn get_seguros_for_vehiculo(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ss = mgr.seguro_list(Some(&id)).await.map_err(err)?;
    Ok(Json(serde_json::json!({ "seguros": ss })))
}

async fn get_seguros_por_vencer(
    State(state): State<ApiState>,
    Query(q): Query<DiasQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ss = mgr
        .seguros_por_vencer(q.dias.unwrap_or(30))
        .await
        .map_err(err)?;
    Ok(Json(serde_json::json!({ "seguros": ss })))
}

// ----------------------------------------------------------------------
// Combustible handlers
// ----------------------------------------------------------------------

async fn post_combustible_log(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(body): Json<CombustibleLogBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let c = mgr
        .combustible_log(
            &id,
            body.fecha.as_deref(),
            body.litros,
            body.monto,
            body.precio_litro,
            body.kilometraje,
            body.estacion.as_deref(),
            body.movimiento_id.as_deref(),
            body.notas.as_deref().unwrap_or(""),
        )
        .await
        .map_err(err)?;
    Ok(Json(serde_json::json!({ "carga": c })))
}

async fn get_combustible_stats(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Query(q): Query<CombustibleStatsQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr
        .combustible_stats(&id, q.ultimas_n.unwrap_or(5))
        .await
        .map_err(err)?;
    Ok(Json(serde_json::json!({ "stats": s })))
}
