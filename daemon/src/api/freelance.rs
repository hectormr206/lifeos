//! Freelance domain HTTP API endpoints.
//!
//! All endpoints under `/api/v1/freelance/`. Auth handled by the
//! `x-bootstrap-token` middleware on the parent router.
//!
//! See `docs/strategy/prd-freelance-domain.md` section 6.

use super::{ApiError, ApiState};
use crate::memory_plane::{FreelanceClienteUpdate, FreelanceSesionUpdate};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{get, patch},
    Router,
};
use serde::Deserialize;

pub fn freelance_routes() -> Router<ApiState> {
    Router::new()
        .route("/clientes", get(get_clientes).post(post_cliente))
        .route(
            "/clientes/:id",
            get(get_cliente).patch(patch_cliente).delete(delete_cliente),
        )
        .route("/sesiones", get(get_sesiones).post(post_sesion))
        .route("/sesiones/:id", patch(patch_sesion).delete(delete_sesion))
        .route("/facturas", get(get_facturas).post(post_factura))
        .route("/facturas/:id", patch(patch_factura))
        .route("/facturas/pendientes", get(get_facturas_pendientes))
        .route("/facturas/vencidas", get(get_facturas_vencidas))
        .route("/overview", get(get_overview))
        .route("/horas-libres", get(get_horas_libres))
        .route("/clientes/:id/estado", get(get_cliente_estado_endpoint))
        .route("/ingresos", get(get_ingresos))
        .route("/top-clientes", get(get_top_clientes))
}

fn err_to_http(e: anyhow::Error) -> (StatusCode, Json<ApiError>) {
    let msg = e.to_string();
    let status = if msg.contains("not found") || msg.contains("no encontre") {
        StatusCode::NOT_FOUND
    } else if msg.contains("required") || msg.contains("must be") || msg.contains("invalid") {
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
}

// ---------------------------------------------------------------- Clientes

#[derive(Debug, Deserialize, Default)]
pub struct ClienteListQuery {
    pub estado: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ClienteCreate {
    pub nombre: String,
    #[serde(default)]
    pub tarifa_hora: Option<f64>,
    #[serde(default)]
    pub modalidad: Option<String>,
    #[serde(default)]
    pub retainer_mensual: Option<f64>,
    #[serde(default)]
    pub horas_comprometidas_mes: Option<i64>,
    #[serde(default)]
    pub fecha_inicio: Option<String>,
    #[serde(default)]
    pub contacto_principal: Option<String>,
    #[serde(default)]
    pub contacto_email: Option<String>,
    #[serde(default)]
    pub contacto_telefono: Option<String>,
    #[serde(default)]
    pub rfc: Option<String>,
    #[serde(default)]
    pub notas: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct ClientePatch {
    pub nombre: Option<String>,
    pub contacto_principal: Option<String>,
    pub contacto_email: Option<String>,
    pub contacto_telefono: Option<String>,
    pub rfc: Option<String>,
    pub tarifa_hora: Option<f64>,
    pub modalidad: Option<String>,
    pub retainer_mensual: Option<f64>,
    pub horas_comprometidas_mes: Option<i64>,
    pub fecha_inicio: Option<String>,
    pub fecha_fin: Option<String>,
    pub estado: Option<String>,
    pub notas: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct ClienteDeleteQuery {
    pub hard: Option<bool>,
}

async fn get_clientes(
    State(state): State<ApiState>,
    Query(q): Query<ClienteListQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let clientes = mgr
        .cliente_list(q.estado.as_deref())
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "clientes": clientes })))
}

async fn post_cliente(
    State(state): State<ApiState>,
    Json(body): Json<ClienteCreate>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let id = mgr
        .cliente_add(
            &body.nombre,
            body.tarifa_hora,
            body.modalidad.as_deref(),
            body.retainer_mensual,
            body.horas_comprometidas_mes,
            body.fecha_inicio.as_deref(),
            body.contacto_principal.as_deref(),
            body.contacto_email.as_deref(),
            body.contacto_telefono.as_deref(),
            body.rfc.as_deref(),
            body.notas.as_deref(),
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "cliente_id": id })))
}

async fn get_cliente(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    match mgr.cliente_get(&id).await.map_err(err_to_http)? {
        Some(c) => Ok(Json(serde_json::json!({ "cliente": c }))),
        None => Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "Not Found".to_string(),
                message: format!("cliente {} not found", id),
                code: 404,
            }),
        )),
    }
}

async fn patch_cliente(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(body): Json<ClientePatch>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let update = FreelanceClienteUpdate {
        nombre: body.nombre,
        contacto_principal: body.contacto_principal,
        contacto_email: body.contacto_email,
        contacto_telefono: body.contacto_telefono,
        rfc: body.rfc,
        tarifa_hora: body.tarifa_hora,
        modalidad: body.modalidad,
        retainer_mensual: body.retainer_mensual,
        horas_comprometidas_mes: body.horas_comprometidas_mes,
        fecha_inicio: body.fecha_inicio,
        fecha_fin: body.fecha_fin,
        estado: body.estado,
        notas: body.notas,
    };
    let mgr = state.memory_plane_manager.read().await;
    let updated = mgr.cliente_update(&id, update).await.map_err(err_to_http)?;
    Ok(Json(
        serde_json::json!({ "updated": updated, "cliente_id": id }),
    ))
}

async fn delete_cliente(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Query(q): Query<ClienteDeleteQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let hard = q.hard.unwrap_or(false);
    let ok = if hard {
        mgr.cliente_delete(&id).await.map_err(err_to_http)?
    } else {
        mgr.cliente_terminar(&id, None, None)
            .await
            .map_err(err_to_http)?
    };
    Ok(Json(serde_json::json!({
        "deleted": ok,
        "hard": hard,
        "cliente_id": id,
    })))
}

// ---------------------------------------------------------------- Sesiones

#[derive(Debug, Deserialize, Default)]
pub struct SesionListQuery {
    pub cliente_id: Option<String>,
    pub desde: Option<String>,
    pub hasta: Option<String>,
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
pub struct SesionCreate {
    pub cliente_id: Option<String>,
    pub cliente_nombre: Option<String>,
    pub horas: f64,
    #[serde(default)]
    pub fecha: Option<String>,
    #[serde(default)]
    pub descripcion: Option<String>,
    #[serde(default)]
    pub hora_inicio: Option<String>,
    #[serde(default)]
    pub hora_fin: Option<String>,
    #[serde(default)]
    pub facturable: Option<bool>,
}

#[derive(Debug, Deserialize, Default)]
pub struct SesionPatch {
    pub fecha: Option<String>,
    pub hora_inicio: Option<String>,
    pub hora_fin: Option<String>,
    pub horas: Option<f64>,
    pub descripcion: Option<String>,
    pub facturable: Option<bool>,
}

async fn get_sesiones(
    State(state): State<ApiState>,
    Query(q): Query<SesionListQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let sesiones = mgr
        .sesion_list(
            q.cliente_id.as_deref(),
            q.desde.as_deref(),
            q.hasta.as_deref(),
            q.limit,
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "sesiones": sesiones })))
}

async fn post_sesion(
    State(state): State<ApiState>,
    Json(body): Json<SesionCreate>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let key = body
        .cliente_id
        .as_deref()
        .or(body.cliente_nombre.as_deref())
        .ok_or_else(|| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Bad Request".to_string(),
                    message: "cliente_id or cliente_nombre required".to_string(),
                    code: 400,
                }),
            )
        })?;
    let mgr = state.memory_plane_manager.read().await;
    let id = mgr
        .sesion_log(
            key,
            body.horas,
            body.fecha.as_deref(),
            body.descripcion.as_deref(),
            body.hora_inicio.as_deref(),
            body.hora_fin.as_deref(),
            body.facturable,
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "sesion_id": id })))
}

async fn patch_sesion(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(body): Json<SesionPatch>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let update = FreelanceSesionUpdate {
        fecha: body.fecha,
        hora_inicio: body.hora_inicio,
        hora_fin: body.hora_fin,
        horas: body.horas,
        descripcion: body.descripcion,
        facturable: body.facturable,
    };
    let mgr = state.memory_plane_manager.read().await;
    let updated = mgr.sesion_update(&id, update).await.map_err(err_to_http)?;
    Ok(Json(
        serde_json::json!({ "updated": updated, "sesion_id": id }),
    ))
}

async fn delete_sesion(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ok = mgr.sesion_delete(&id).await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "deleted": ok, "sesion_id": id })))
}

// ---------------------------------------------------------------- Facturas

#[derive(Debug, Deserialize, Default)]
pub struct FacturaListQuery {
    pub cliente_id: Option<String>,
    pub estado: Option<String>,
    pub desde: Option<String>,
    pub hasta: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct FacturaCreate {
    pub cliente_id: Option<String>,
    pub cliente_nombre: Option<String>,
    pub monto_subtotal: f64,
    #[serde(default)]
    pub monto_iva: Option<f64>,
    #[serde(default)]
    pub fecha_emision: Option<String>,
    #[serde(default)]
    pub fecha_vencimiento: Option<String>,
    #[serde(default)]
    pub concepto: Option<String>,
    #[serde(default)]
    pub numero_externo: Option<String>,
    #[serde(default)]
    pub sesion_ids: Option<Vec<String>>,
}

#[derive(Debug, Deserialize, Default)]
pub struct FacturaPatch {
    /// If set, marks the invoice paid as of this date.
    pub fecha_pago: Option<String>,
    /// If set, cancels the invoice with this reason.
    pub cancelar: Option<bool>,
    pub razon_cancelacion: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct ClientePendientesQuery {
    pub cliente_id: Option<String>,
}

async fn get_facturas(
    State(state): State<ApiState>,
    Query(q): Query<FacturaListQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let facturas = mgr
        .factura_list(
            q.cliente_id.as_deref(),
            q.estado.as_deref(),
            q.desde.as_deref(),
            q.hasta.as_deref(),
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "facturas": facturas })))
}

async fn post_factura(
    State(state): State<ApiState>,
    Json(body): Json<FacturaCreate>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let key = body
        .cliente_id
        .as_deref()
        .or(body.cliente_nombre.as_deref())
        .ok_or_else(|| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiError {
                    error: "Bad Request".to_string(),
                    message: "cliente_id or cliente_nombre required".to_string(),
                    code: 400,
                }),
            )
        })?;
    let mgr = state.memory_plane_manager.read().await;
    let id = mgr
        .factura_emit(
            key,
            body.monto_subtotal,
            body.monto_iva,
            body.fecha_emision.as_deref(),
            body.fecha_vencimiento.as_deref(),
            body.concepto.as_deref(),
            body.numero_externo.as_deref(),
            body.sesion_ids,
        )
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "factura_id": id })))
}

async fn patch_factura(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(body): Json<FacturaPatch>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    if body.cancelar.unwrap_or(false) {
        let ok = mgr
            .factura_cancelar(&id, body.razon_cancelacion.as_deref())
            .await
            .map_err(err_to_http)?;
        return Ok(Json(
            serde_json::json!({ "cancelled": ok, "factura_id": id }),
        ));
    }
    if body.fecha_pago.is_some() {
        let ok = mgr
            .factura_pagar(&id, body.fecha_pago.as_deref())
            .await
            .map_err(err_to_http)?;
        return Ok(Json(serde_json::json!({ "paid": ok, "factura_id": id })));
    }
    Err((
        StatusCode::BAD_REQUEST,
        Json(ApiError {
            error: "Bad Request".to_string(),
            message: "specify cancelar=true or fecha_pago".to_string(),
            code: 400,
        }),
    ))
}

async fn get_facturas_pendientes(
    State(state): State<ApiState>,
    Query(q): Query<ClientePendientesQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let facturas = mgr
        .facturas_pendientes(q.cliente_id.as_deref())
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "facturas": facturas })))
}

async fn get_facturas_vencidas(
    State(state): State<ApiState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let facturas = mgr.facturas_vencidas().await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "facturas": facturas })))
}

// ---------------------------------------------------------------- Analytics

#[derive(Debug, Deserialize, Default)]
pub struct OverviewQuery {
    pub mes: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct HorasLibresQuery {
    pub ventana: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct IngresosQuery {
    pub desde: String,
    pub hasta: String,
    #[serde(default)]
    pub agrupado_por: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct TopClientesQuery {
    pub desde: Option<String>,
    pub hasta: Option<String>,
}

async fn get_overview(
    State(state): State<ApiState>,
    Query(q): Query<OverviewQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let ov = mgr
        .freelance_overview(q.mes.as_deref())
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "overview": ov })))
}

async fn get_horas_libres(
    State(state): State<ApiState>,
    Query(q): Query<HorasLibresQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let ventana = q.ventana.as_deref().unwrap_or("semana");
    let mgr = state.memory_plane_manager.read().await;
    let h = mgr.horas_libres(ventana).await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "horas_libres": h })))
}

async fn get_cliente_estado_endpoint(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let s = mgr.cliente_estado(&id).await.map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "estado": s })))
}

async fn get_ingresos(
    State(state): State<ApiState>,
    Query(q): Query<IngresosQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let agrup = q.agrupado_por.as_deref().unwrap_or("mes");
    let mgr = state.memory_plane_manager.read().await;
    let buckets = mgr
        .ingresos_periodo(&q.desde, &q.hasta, agrup)
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "buckets": buckets })))
}

async fn get_top_clientes(
    State(state): State<ApiState>,
    Query(q): Query<TopClientesQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    let mgr = state.memory_plane_manager.read().await;
    let buckets = mgr
        .clientes_por_facturacion(q.desde.as_deref(), q.hasta.as_deref())
        .await
        .map_err(err_to_http)?;
    Ok(Json(serde_json::json!({ "clientes": buckets })))
}
