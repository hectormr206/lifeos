//! Async Worker Pool — runs LLM tasks without blocking the Telegram handler.
//!
//! When Axi receives a task (not an instant response), it spawns a worker
//! via tokio::spawn. The worker runs the agentic loop independently and
//! sends the result back to Telegram when done. Axi stays free to handle
//! more messages immediately.

#![allow(dead_code)]

use chrono::{DateTime, Utc};
use log::info;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

const MAX_WORKERS_PER_USER: usize = 3;

#[derive(Debug, Clone)]
pub struct WorkerInfo {
    pub task_id: String,
    pub chat_id: i64,
    pub description: String,
    pub started_at: DateTime<Utc>,
    pub status: WorkerStatus,
}

#[derive(Debug, Clone, PartialEq)]
pub enum WorkerStatus {
    Running,
    Completed,
    Failed(String),
}

#[derive(Clone)]
pub struct WorkerPool {
    workers: Arc<RwLock<HashMap<String, WorkerInfo>>>,
}

impl WorkerPool {
    pub fn new() -> Self {
        Self {
            workers: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Check if we can spawn another worker for this user.
    pub async fn can_spawn(&self, chat_id: i64) -> bool {
        let workers = self.workers.read().await;
        let active = workers
            .values()
            .filter(|w| w.chat_id == chat_id && w.status == WorkerStatus::Running)
            .count();
        active < MAX_WORKERS_PER_USER
    }

    /// Register a new worker.
    pub async fn register(&self, task_id: String, chat_id: i64, description: String) {
        let info = WorkerInfo {
            task_id: task_id.clone(),
            chat_id,
            description,
            started_at: Utc::now(),
            status: WorkerStatus::Running,
        };
        self.workers.write().await.insert(task_id, info);
    }

    /// Mark a worker as completed.
    pub async fn complete(&self, task_id: &str) {
        if let Some(w) = self.workers.write().await.get_mut(task_id) {
            w.status = WorkerStatus::Completed;
        }
    }

    /// Mark a worker as failed.
    pub async fn fail(&self, task_id: &str, error: String) {
        if let Some(w) = self.workers.write().await.get_mut(task_id) {
            w.status = WorkerStatus::Failed(error);
        }
    }

    /// List active workers for a user.
    pub async fn active_workers(&self, chat_id: i64) -> Vec<WorkerInfo> {
        self.workers
            .read()
            .await
            .values()
            .filter(|w| w.chat_id == chat_id && w.status == WorkerStatus::Running)
            .cloned()
            .collect()
    }

    /// List all workers (for dashboard / status).
    pub async fn all_workers(&self) -> Vec<WorkerInfo> {
        self.workers.read().await.values().cloned().collect()
    }

    /// Clean up old completed/failed workers (older than 1 hour).
    pub async fn cleanup(&self) {
        let cutoff = Utc::now() - chrono::Duration::hours(1);
        self.workers
            .write()
            .await
            .retain(|_, w| w.status == WorkerStatus::Running || w.started_at > cutoff);
    }
}

/// Background loop that periodically cleans up stale workers.
pub async fn cleanup_loop(pool: WorkerPool) {
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(600)).await;
        let all = pool.all_workers().await;
        let running = all
            .iter()
            .filter(|w| w.status == WorkerStatus::Running)
            .count();
        pool.cleanup().await;
        info!(
            "[async_workers] Cleanup: {} total, {} running",
            all.len(),
            running
        );
    }
}
