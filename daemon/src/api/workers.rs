//! Workers API endpoints — list and cancel async LLM workers.
//!
//! Backed by [`crate::async_workers::WorkerPool`], which owns the registry of
//! in-flight worker tasks. The dashboard already tracks workers in real time
//! via WebSocket events; these REST endpoints exist so the UI can:
//!
//! - reconcile its local map after a page reload (`GET /workers`), and
//! - explicitly cancel a worker by id (`POST /workers/:id/cancel`).

use super::{ApiError, ApiState};
use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use serde::Serialize;

pub fn workers_routes() -> Router<ApiState> {
    Router::new()
        .route("/", get(list_workers))
        .route("/:id/cancel", post(cancel_worker))
}

#[derive(Debug, Serialize)]
pub struct WorkerSummary {
    pub id: String,
    pub chat_id: i64,
    pub task: String,
    pub status: String,
    pub started_at: String,
    pub depth: u32,
    pub parent_id: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ListWorkersResponse {
    pub workers: Vec<WorkerSummary>,
    pub count: usize,
}

#[derive(Debug, Serialize)]
pub struct CancelWorkerResponse {
    pub cancelled: bool,
    pub id: String,
}

async fn list_workers(
    State(state): State<ApiState>,
) -> Result<Json<ListWorkersResponse>, (StatusCode, Json<ApiError>)> {
    let all = state.worker_pool.all_workers().await;
    let workers: Vec<WorkerSummary> = all
        .into_iter()
        .map(|w| WorkerSummary {
            id: w.task_id,
            chat_id: w.chat_id,
            task: w.description,
            status: status_label(&w.status),
            started_at: w.started_at.to_rfc3339(),
            depth: w.depth,
            parent_id: w.parent_id,
        })
        .collect();
    let count = workers.len();
    Ok(Json(ListWorkersResponse { workers, count }))
}

async fn cancel_worker(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<CancelWorkerResponse>, (StatusCode, Json<ApiError>)> {
    let cancelled = state.worker_pool.cancel(&id).await;
    if !cancelled {
        return Err((
            StatusCode::NOT_FOUND,
            Json(ApiError {
                error: "worker_not_found_or_not_running".into(),
                message: format!("No running worker with id '{}'", id),
                code: 404,
            }),
        ));
    }
    Ok(Json(CancelWorkerResponse { cancelled, id }))
}

fn status_label(s: &crate::async_workers::WorkerStatus) -> String {
    use crate::async_workers::WorkerStatus;
    match s {
        WorkerStatus::Running => "running".into(),
        WorkerStatus::Completed => "completed".into(),
        WorkerStatus::Failed(_) => "failed".into(),
        WorkerStatus::Cancelled => "cancelled".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::async_workers::WorkerPool;

    #[tokio::test]
    async fn list_returns_empty_initially() {
        let pool = WorkerPool::new();
        let all = pool.all_workers().await;
        assert!(all.is_empty());
    }

    #[tokio::test]
    async fn cancel_unknown_returns_false() {
        let pool = WorkerPool::new();
        let ok = pool.cancel("does-not-exist").await;
        assert!(!ok);
    }

    #[tokio::test]
    async fn cancel_running_marks_cancelled() {
        let pool = WorkerPool::new();
        pool.register("w1".into(), 42, "test task".into()).await;
        let ok = pool.cancel("w1").await;
        assert!(ok);
        let ok2 = pool.cancel("w1").await;
        assert!(!ok2);
    }

    #[tokio::test]
    async fn list_includes_registered_worker() {
        let pool = WorkerPool::new();
        pool.register("w-list".into(), 7, "list me".into()).await;
        let all = pool.all_workers().await;
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].task_id, "w-list");
        assert_eq!(all[0].chat_id, 7);
    }

    #[test]
    fn status_label_maps_variants() {
        use crate::async_workers::WorkerStatus;
        assert_eq!(status_label(&WorkerStatus::Running), "running");
        assert_eq!(status_label(&WorkerStatus::Completed), "completed");
        assert_eq!(status_label(&WorkerStatus::Cancelled), "cancelled");
        assert_eq!(status_label(&WorkerStatus::Failed("x".into())), "failed");
    }
}
