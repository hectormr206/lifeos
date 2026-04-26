//! Finanzas Domain HTTP API (PRD Section 3 MVP).
//!
//! REST surface for cuentas / categorias / movimientos / presupuestos /
//! metas de ahorro plus aggregate analytics (overview, balance,
//! gastos-por-categoria, cuanto-puedo-gastar). Mounted under
//! `/api/v1/finanzas/*`.
//!
//! Auth follows the same convention as the rest of `/api/v1/*`: the
//! `x-bootstrap-token` middleware in `mod.rs` covers everything nested
//! under this router.

use super::{ApiError, ApiState};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};

pub fn finanzas_routes() -> Router<ApiState> {
    Router::new()
        // -- Cuentas ------------------------------------------------------
        .route("/cuentas", get(list_cuentas).post(create_cuenta))
        .route("/cuentas/:id", get(get_cuenta).patch(patch_cuenta))
        .route("/cuentas/:id/cerrar", post(post_cerrar_cuenta))
        .route("/cuentas/:id/saldo", post(post_saldo_cuenta))
        .route("/cuentas-balance", get(get_cuentas_balance))
        // -- Categorias ---------------------------------------------------
        .route("/categorias", get(list_categorias).post(create_categoria))
        .route(
            "/categorias/:id",
            get(get_categoria)
                .patch(patch_categoria)
                .delete(delete_categoria),
        )
        // -- Movimientos --------------------------------------------------
        .route(
            "/movimientos",
            get(list_movimientos).post(create_movimiento),
        )
        .route(
            "/movimientos/:id",
            get(get_movimiento)
                .patch(patch_movimiento)
                .delete(delete_movimiento),
        )
        // -- Presupuestos -------------------------------------------------
        .route(
            "/presupuestos",
            get(list_presupuestos).post(create_presupuesto),
        )
        .route("/presupuestos/status", get(get_presupuesto_status_one))
        // -- Metas --------------------------------------------------------
        .route("/metas", get(list_metas).post(create_meta))
        .route("/metas/:id/aporte", post(post_aporte_meta))
        // -- Analytics ----------------------------------------------------
        .route("/overview", get(get_overview))
        .route("/gastos-por-categoria", get(get_gastos_por_categoria))
        .route("/ingresos-vs-gastos", get(get_ingresos_vs_gastos))
        .route("/gastos-recurrentes", get(get_gastos_recurrentes))
        .route("/cuanto-puedo-gastar", get(get_cuanto_puedo_gastar))
}

// ----------------------------------------------------------------------
// Error mapping (same shape as vida_plena::err_to_http)
// ----------------------------------------------------------------------

fn err_to_http(e: anyhow::Error) -> (StatusCode, Json<ApiError>) {
    let msg = e.to_string();
    let status = if msg.contains("locked") || msg.contains("wrong passphrase") {
        StatusCode::FORBIDDEN
    } else if msg.contains("required")
        || msg.contains("must be")
        || msg.contains("invalid")
        || msg.contains("rejected")
    {
        StatusCode::BAD_REQUEST
    } else if msg.contains("UNIQUE constraint") || msg.contains("already configured") {
        StatusCode::CONFLICT
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

fn not_found(msg: impl Into<String>) -> (StatusCode, Json<ApiError>) {
    (
        StatusCode::NOT_FOUND,
        Json(ApiError {
            error: "Not Found".into(),
            message: msg.into(),
            code: 404,
        }),
    )
}

// ----------------------------------------------------------------------
// Cuentas
// ----------------------------------------------------------------------

#[derive(Debug, Deserialize, Default)]
pub struct CuentaListQuery {
    pub include_cerradas: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct CreateCuentaBody {
    pub nombre: String,
    pub tipo: String,
    pub banco: Option<String>,
    pub ultimos_4: Option<String>,
    pub moneda: Option<String>,
    pub saldo_actual: Option<f64>,
    pub limite_credito: Option<f64>,
    pub fecha_corte: Option<i64>,
    pub fecha_pago: Option<i64>,
    pub titular: Option<String>,
    #[serde(default)]
    pub notas: String,
}

#[derive(Debug, Deserialize, Default)]
pub struct PatchCuentaBody {
    pub nombre: Option<String>,
    pub banco: Option<String>,
    pub ultimos_4: Option<String>,
    pub limite_credito: Option<f64>,
    pub fecha_corte: Option<i64>,
    pub fecha_pago: Option<i64>,
    pub notas: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SaldoBody {
    pub saldo_actual: f64,
}

async fn list_cuentas(
    State(state): State<ApiState>,
    Query(q): Query<CuentaListQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr
        .finanzas_cuenta_list(q.include_cerradas.unwrap_or(false))
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "cuentas": list })))
}

async fn create_cuenta(
    State(state): State<ApiState>,
    Json(b): Json<CreateCuentaBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let c = mgr
        .finanzas_cuenta_add(
            &b.nombre,
            &b.tipo,
            b.banco.as_deref(),
            b.ultimos_4.as_deref(),
            b.moneda.as_deref(),
            b.saldo_actual,
            b.limite_credito,
            b.fecha_corte,
            b.fecha_pago,
            b.titular.as_deref(),
            &b.notas,
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "cuenta": c })))
}

async fn get_cuenta(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let c = mgr
        .finanzas_cuenta_get(&id)
        .await
        .map_err(err_to_http)?
        .ok_or_else(|| not_found(format!("no cuenta with id {id}")))?;
    Ok(Json(serde_json::json!({ "cuenta": c })))
}

async fn patch_cuenta(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(b): Json<PatchCuentaBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let updated = mgr
        .finanzas_cuenta_update(
            &id,
            b.nombre.as_deref(),
            b.banco.as_deref(),
            b.ultimos_4.as_deref(),
            b.limite_credito,
            b.fecha_corte,
            b.fecha_pago,
            b.notas.as_deref(),
        )
        .await
        .map_err(err_to_http)?;
    if !updated {
        return Err(not_found(format!("no cuenta with id {id}")));
    }
    Ok(Json(
        serde_json::json!({ "updated": true, "cuenta_id": id }),
    ))
}

async fn post_cerrar_cuenta(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr.finanzas_cuenta_cerrar(&id).await.map_err(err_to_http)?;
    if !ok {
        return Err(not_found(format!("no cuenta with id {id}")));
    }
    Ok(Json(
        serde_json::json!({ "cerrada": true, "cuenta_id": id }),
    ))
}

async fn post_saldo_cuenta(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(b): Json<SaldoBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr
        .finanzas_cuenta_saldo_update(&id, b.saldo_actual)
        .await
        .map_err(err_to_http)?;
    if !ok {
        return Err(not_found(format!("no cuenta with id {id}")));
    }
    Ok(Json(serde_json::json!({ "updated": true })))
}

async fn get_cuentas_balance(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let b = mgr.finanzas_cuentas_balance().await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "balance": b })))
}

// ----------------------------------------------------------------------
// Categorias
// ----------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct CreateCategoriaBody {
    pub nombre: String,
    pub tipo: String,
    pub parent_id: Option<String>,
    pub emoji: Option<String>,
    pub color: Option<String>,
    pub presupuesto_mensual: Option<f64>,
}

#[derive(Debug, Deserialize, Default)]
pub struct PatchCategoriaBody {
    pub nombre: Option<String>,
    pub emoji: Option<String>,
    pub color: Option<String>,
    pub presupuesto_mensual: Option<f64>,
}

async fn list_categorias(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr.finanzas_categoria_list().await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "categorias": list })))
}

async fn create_categoria(
    State(state): State<ApiState>,
    Json(b): Json<CreateCategoriaBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let c = mgr
        .finanzas_categoria_add(
            &b.nombre,
            &b.tipo,
            b.parent_id.as_deref(),
            b.emoji.as_deref(),
            b.color.as_deref(),
            b.presupuesto_mensual,
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "categoria": c })))
}

async fn get_categoria(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let c = mgr
        .finanzas_categoria_get(&id)
        .await
        .map_err(err_to_http)?
        .ok_or_else(|| not_found(format!("no categoria with id {id}")))?;
    Ok(Json(serde_json::json!({ "categoria": c })))
}

async fn patch_categoria(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(b): Json<PatchCategoriaBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr
        .finanzas_categoria_update(
            &id,
            b.nombre.as_deref(),
            b.emoji.as_deref(),
            b.color.as_deref(),
            b.presupuesto_mensual,
        )
        .await
        .map_err(err_to_http)?;
    if !ok {
        return Err(not_found(format!("no categoria with id {id}")));
    }
    Ok(Json(
        serde_json::json!({ "updated": true, "categoria_id": id }),
    ))
}

async fn delete_categoria(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr
        .finanzas_categoria_delete(&id)
        .await
        .map_err(err_to_http)?;
    if !ok {
        return Err(not_found(format!("no categoria with id {id}")));
    }
    Ok(Json(
        serde_json::json!({ "deleted": true, "categoria_id": id }),
    ))
}

// ----------------------------------------------------------------------
// Movimientos
// ----------------------------------------------------------------------

#[derive(Debug, Deserialize, Default)]
pub struct MovimientoListQuery {
    pub cuenta_id: Option<String>,
    pub categoria_id: Option<String>,
    pub desde: Option<String>,
    pub hasta: Option<String>,
    pub tipo: Option<String>,
    pub recurrente: Option<bool>,
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
pub struct CreateMovimientoBody {
    pub cuenta_id: Option<String>,
    pub cuenta_nombre: Option<String>,
    pub categoria_id: Option<String>,
    pub categoria_nombre: Option<String>,
    pub tipo: String,
    pub fecha: Option<String>,
    pub monto: f64,
    pub moneda: Option<String>,
    pub descripcion: Option<String>,
    pub comercio: Option<String>,
    pub metodo: Option<String>,
    pub cuenta_destino_id: Option<String>,
    #[serde(default)]
    pub recurrente: bool,
    #[serde(default)]
    pub notas: String,
    pub viaje_id: Option<String>,
    pub vehiculo_id: Option<String>,
    pub proyecto_id: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct PatchMovimientoBody {
    pub categoria_id: Option<String>,
    pub descripcion: Option<String>,
    pub comercio: Option<String>,
    pub notas: Option<String>,
    pub recurrente: Option<bool>,
}

async fn list_movimientos(
    State(state): State<ApiState>,
    Query(q): Query<MovimientoListQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr
        .finanzas_movimiento_list(
            q.cuenta_id.as_deref(),
            q.categoria_id.as_deref(),
            q.desde.as_deref(),
            q.hasta.as_deref(),
            q.tipo.as_deref(),
            q.recurrente,
            q.limit.unwrap_or(100),
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "movimientos": list })))
}

async fn create_movimiento(
    State(state): State<ApiState>,
    Json(b): Json<CreateMovimientoBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let m = mgr
        .finanzas_movimiento_log(
            b.cuenta_id.as_deref(),
            b.cuenta_nombre.as_deref(),
            b.categoria_id.as_deref(),
            b.categoria_nombre.as_deref(),
            &b.tipo,
            b.fecha.as_deref(),
            b.monto,
            b.moneda.as_deref(),
            b.descripcion.as_deref(),
            b.comercio.as_deref(),
            b.metodo.as_deref(),
            b.cuenta_destino_id.as_deref(),
            b.recurrente,
            &b.notas,
            b.viaje_id.as_deref(),
            b.vehiculo_id.as_deref(),
            b.proyecto_id.as_deref(),
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "movimiento": m })))
}

async fn get_movimiento(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let m = mgr
        .finanzas_movimiento_get(&id)
        .await
        .map_err(err_to_http)?
        .ok_or_else(|| not_found(format!("no movimiento with id {id}")))?;
    Ok(Json(serde_json::json!({ "movimiento": m })))
}

async fn patch_movimiento(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(b): Json<PatchMovimientoBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr
        .finanzas_movimiento_update(
            &id,
            b.categoria_id.as_deref(),
            b.descripcion.as_deref(),
            b.comercio.as_deref(),
            b.notas.as_deref(),
            b.recurrente,
        )
        .await
        .map_err(err_to_http)?;
    if !ok {
        return Err(not_found(format!("no movimiento with id {id}")));
    }
    Ok(Json(
        serde_json::json!({ "updated": true, "movimiento_id": id }),
    ))
}

async fn delete_movimiento(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr
        .finanzas_movimiento_delete(&id)
        .await
        .map_err(err_to_http)?;
    if !ok {
        return Err(not_found(format!("no movimiento with id {id}")));
    }
    Ok(Json(
        serde_json::json!({ "deleted": true, "movimiento_id": id }),
    ))
}

// ----------------------------------------------------------------------
// Presupuestos
// ----------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct CreatePresupuestoBody {
    pub categoria_id: String,
    pub mes: String,
    pub monto_objetivo: f64,
    pub alerta_pct: Option<f64>,
}

#[derive(Debug, Deserialize, Default)]
pub struct PresupuestoStatusQuery {
    pub mes: Option<String>,
    pub categoria_id: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct PresupuestosListQuery {
    pub mes: Option<String>,
}

#[derive(Serialize)]
struct EmptyOk {
    ok: bool,
}

async fn list_presupuestos(
    State(state): State<ApiState>,
    Query(q): Query<PresupuestosListQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mes = q
        .mes
        .unwrap_or_else(|| chrono::Local::now().format("%Y-%m").to_string());
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr
        .finanzas_presupuestos_list_mes(&mes)
        .await
        .map_err(err_to_http)?;
    Ok(Json(
        serde_json::json!({ "mes": mes, "presupuestos": list }),
    ))
}

async fn create_presupuesto(
    State(state): State<ApiState>,
    Json(b): Json<CreatePresupuestoBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let p = mgr
        .finanzas_presupuesto_set(&b.categoria_id, &b.mes, b.monto_objetivo, b.alerta_pct)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "presupuesto": p })))
}

async fn get_presupuesto_status_one(
    State(state): State<ApiState>,
    Query(q): Query<PresupuestoStatusQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mes = q
        .mes
        .unwrap_or_else(|| chrono::Local::now().format("%Y-%m").to_string());
    let mgr = state.memory_plane_manager.read().await;
    if let Some(cat) = q.categoria_id {
        let s = mgr
            .finanzas_presupuesto_status(&cat, &mes)
            .await
            .map_err(err_to_http)?;
        Ok(Json(serde_json::json!({ "mes": mes, "status": s })))
    } else {
        let list = mgr
            .finanzas_presupuestos_list_mes(&mes)
            .await
            .map_err(err_to_http)?;
        Ok(Json(serde_json::json!({ "mes": mes, "status": list })))
    }
}

// ----------------------------------------------------------------------
// Metas
// ----------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct CreateMetaBody {
    pub nombre: String,
    pub monto_objetivo: f64,
    pub fecha_objetivo: Option<String>,
    pub cuenta_id: Option<String>,
    pub prioridad: Option<i64>,
    #[serde(default)]
    pub notas: String,
}

#[derive(Debug, Deserialize)]
pub struct AporteBody {
    pub monto: f64,
}

#[derive(Debug, Deserialize, Default)]
pub struct MetasListQuery {
    pub all: Option<bool>,
}

async fn list_metas(
    State(state): State<ApiState>,
    Query(q): Query<MetasListQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let only_active = !q.all.unwrap_or(false);
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr
        .finanzas_meta_ahorro_list(only_active)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "metas": list })))
}

async fn create_meta(
    State(state): State<ApiState>,
    Json(b): Json<CreateMetaBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let m = mgr
        .finanzas_meta_ahorro_add(
            &b.nombre,
            b.monto_objetivo,
            b.fecha_objetivo.as_deref(),
            b.cuenta_id.as_deref(),
            b.prioridad,
            &b.notas,
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "meta": m })))
}

async fn post_aporte_meta(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(b): Json<AporteBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let m = mgr
        .finanzas_meta_ahorro_aporte(&id, b.monto)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "meta": m })))
}

// ----------------------------------------------------------------------
// Analytics
// ----------------------------------------------------------------------

#[derive(Debug, Deserialize, Default)]
pub struct OverviewQuery {
    pub mes: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct GastosCatQuery {
    pub desde: Option<String>,
    pub hasta: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct IngVsGastQuery {
    pub meses_atras: Option<i32>,
}

#[derive(Debug, Deserialize, Default)]
pub struct CuantoQuery {
    pub categoria_id: Option<String>,
}

async fn get_overview(
    State(state): State<ApiState>,
    Query(q): Query<OverviewQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ov = mgr
        .finanzas_overview(q.mes.as_deref())
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "overview": ov })))
}

async fn get_gastos_por_categoria(
    State(state): State<ApiState>,
    Query(q): Query<GastosCatQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr
        .finanzas_gastos_por_categoria(q.desde.as_deref(), q.hasta.as_deref())
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "gastos": list })))
}

async fn get_ingresos_vs_gastos(
    State(state): State<ApiState>,
    Query(q): Query<IngVsGastQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr
        .finanzas_ingresos_vs_gastos(q.meses_atras.unwrap_or(6))
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "tendencia": list })))
}

async fn get_gastos_recurrentes(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let list = mgr
        .finanzas_gastos_recurrentes_list()
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "movimientos": list })))
}

async fn get_cuanto_puedo_gastar(
    State(state): State<ApiState>,
    Query(q): Query<CuantoQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let restante = mgr
        .finanzas_cuanto_puedo_gastar(q.categoria_id.as_deref())
        .await
        .map_err(err_to_http)?;
    Ok(Json(
        serde_json::json!({ "restante": restante, "categoria_id": q.categoria_id }),
    ))
}

// Marker to silence unused-warning if the harness ever drops a route.
#[allow(dead_code)]
fn _route_unused_marker(_e: EmptyOk) {}
