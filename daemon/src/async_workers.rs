//! Async Worker Pool — runs LLM tasks without blocking the Telegram handler.
//!
//! When Axi receives a task (not an instant response), it spawns a worker
//! via tokio::spawn. The worker runs the agentic loop independently and
//! sends the result back to Telegram when done. Axi stays free to handle
//! more messages immediately.
//!
//! Features:
//! - Sub-workers: a worker can spawn child workers (max depth 3)
//! - Cancellation: users can cancel active workers via AtomicBool flag
//! - Steering: feed additional context to a running worker via message buffer
//! - Progress: workers report intermediate status messages

#![allow(dead_code)] // Sub-worker and steering APIs are available for future agentic integration

use chrono::{DateTime, Utc};
use log::{info, warn};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::RwLock;

const MAX_WORKERS_PER_USER: usize = 3;
const MAX_SUB_WORKER_DEPTH: u32 = 3;

#[derive(Debug, Clone, PartialEq)]
pub enum WorkerStatus {
    Running,
    Completed,
    Failed(String),
    Cancelled,
}

#[derive(Debug, Clone)]
pub struct WorkerInfo {
    pub task_id: String,
    pub chat_id: i64,
    pub description: String,
    pub started_at: DateTime<Utc>,
    pub status: WorkerStatus,
    /// Parent worker ID (for sub-workers).
    pub parent_id: Option<String>,
    /// Nesting depth (0 = top-level).
    pub depth: u32,
    /// Cancellation flag — checked by the worker loop.
    pub cancelled: Arc<AtomicBool>,
    /// Steering messages — additional context fed by the user while the worker runs.
    pub steering_messages: Arc<RwLock<Vec<String>>>,
    /// Result text (populated when sub-worker completes).
    pub result: Arc<RwLock<Option<String>>>,
}

#[derive(Clone)]
pub struct WorkerPool {
    workers: Arc<RwLock<HashMap<String, WorkerInfo>>>,
    /// Optional event bus for broadcasting worker lifecycle events to the dashboard.
    event_bus: Option<tokio::sync::broadcast::Sender<crate::events::DaemonEvent>>,
}

impl WorkerPool {
    pub fn new() -> Self {
        Self {
            workers: Arc::new(RwLock::new(HashMap::new())),
            event_bus: None,
        }
    }

    /// Create a WorkerPool with an event bus for real-time dashboard updates.
    pub fn with_event_bus(
        event_bus: tokio::sync::broadcast::Sender<crate::events::DaemonEvent>,
    ) -> Self {
        Self {
            workers: Arc::new(RwLock::new(HashMap::new())),
            event_bus: Some(event_bus),
        }
    }

    /// Emit a worker lifecycle event to the WebSocket event bus.
    fn emit_worker_event(&self, event: crate::events::DaemonEvent) {
        if let Some(ref bus) = self.event_bus {
            let _ = bus.send(event);
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

    /// Register a new top-level worker.
    pub async fn register(&self, task_id: String, chat_id: i64, description: String) {
        let desc_clone = description.clone();
        let info = WorkerInfo {
            task_id: task_id.clone(),
            chat_id,
            description,
            started_at: Utc::now(),
            status: WorkerStatus::Running,
            parent_id: None,
            depth: 0,
            cancelled: Arc::new(AtomicBool::new(false)),
            steering_messages: Arc::new(RwLock::new(Vec::new())),
            result: Arc::new(RwLock::new(None)),
        };
        self.workers.write().await.insert(task_id.clone(), info);
        self.emit_worker_event(crate::events::DaemonEvent::WorkerStarted {
            id: task_id,
            task: desc_clone,
            started_at: Utc::now().to_rfc3339(),
        });
    }

    /// Mark a worker as completed.
    pub async fn complete(&self, task_id: &str) {
        let task_desc = {
            let mut workers = self.workers.write().await;
            if let Some(w) = workers.get_mut(task_id) {
                w.status = WorkerStatus::Completed;
                w.description.clone()
            } else {
                String::new()
            }
        };
        self.emit_worker_event(crate::events::DaemonEvent::WorkerCompleted {
            id: task_id.to_string(),
            task: task_desc,
            result: None,
        });
    }

    /// Mark a worker as completed with a result (used by sub-workers to report back).
    pub async fn complete_with_result(&self, task_id: &str, result_text: String) {
        let task_desc = {
            let mut workers = self.workers.write().await;
            if let Some(w) = workers.get_mut(task_id) {
                w.status = WorkerStatus::Completed;
                *w.result.write().await = Some(result_text.clone());
                w.description.clone()
            } else {
                String::new()
            }
        };
        self.emit_worker_event(crate::events::DaemonEvent::WorkerCompleted {
            id: task_id.to_string(),
            task: task_desc,
            result: Some(result_text),
        });
    }

    /// Mark a worker as failed.
    pub async fn fail(&self, task_id: &str, error: String) {
        let task_desc = {
            let mut workers = self.workers.write().await;
            if let Some(w) = workers.get_mut(task_id) {
                w.status = WorkerStatus::Failed(error.clone());
                w.description.clone()
            } else {
                String::new()
            }
        };
        self.emit_worker_event(crate::events::DaemonEvent::WorkerFailed {
            id: task_id.to_string(),
            task: task_desc,
            error,
        });
    }

    /// Cancel an active worker by setting its cancellation flag.
    pub async fn cancel(&self, task_id: &str) -> bool {
        let mut workers = self.workers.write().await;
        if let Some(w) = workers.get_mut(task_id) {
            if w.status == WorkerStatus::Running {
                w.cancelled.store(true, Ordering::SeqCst);
                w.status = WorkerStatus::Cancelled;
                let desc = w.description.clone();
                drop(workers);
                self.emit_worker_event(crate::events::DaemonEvent::WorkerFailed {
                    id: task_id.to_string(),
                    task: desc,
                    error: "cancelled by user".to_string(),
                });
                return true;
            }
        }
        false
    }

    /// Check if a worker has been cancelled.
    pub async fn is_cancelled(&self, task_id: &str) -> bool {
        let workers = self.workers.read().await;
        workers
            .get(task_id)
            .map(|w| w.cancelled.load(Ordering::SeqCst))
            .unwrap_or(false)
    }

    /// Get the cancellation flag for a worker (clone of the Arc<AtomicBool>).
    pub async fn get_cancel_flag(&self, task_id: &str) -> Option<Arc<AtomicBool>> {
        self.workers
            .read()
            .await
            .get(task_id)
            .map(|w| w.cancelled.clone())
    }

    // ----- Sub-worker support -----

    /// Get the depth of a worker.
    async fn get_depth(&self, task_id: &str) -> u32 {
        self.workers
            .read()
            .await
            .get(task_id)
            .map(|w| w.depth)
            .unwrap_or(0)
    }

    /// Store the parent relationship for a sub-worker.
    async fn set_parent(&self, sub_id: &str, parent_id: &str) {
        if let Some(w) = self.workers.write().await.get_mut(sub_id) {
            w.parent_id = Some(parent_id.to_string());
        }
    }

    /// Spawn a sub-worker under a parent. Returns the sub-worker ID if successful.
    /// Enforces max depth of 3 levels.
    pub async fn spawn_sub_worker(
        &self,
        parent_id: &str,
        chat_id: i64,
        description: String,
    ) -> Option<String> {
        let depth = self.get_depth(parent_id).await;
        if depth >= MAX_SUB_WORKER_DEPTH {
            warn!(
                "[workers] Max depth ({}) reached for parent {}",
                MAX_SUB_WORKER_DEPTH, parent_id
            );
            return None;
        }

        let sub_id = format!(
            "{}-sub-{}",
            parent_id,
            &uuid::Uuid::new_v4().to_string()[..8]
        );

        let desc_clone = description.clone();
        let info = WorkerInfo {
            task_id: sub_id.clone(),
            chat_id,
            description,
            started_at: Utc::now(),
            status: WorkerStatus::Running,
            parent_id: Some(parent_id.to_string()),
            depth: depth + 1,
            cancelled: Arc::new(AtomicBool::new(false)),
            steering_messages: Arc::new(RwLock::new(Vec::new())),
            result: Arc::new(RwLock::new(None)),
        };
        self.workers.write().await.insert(sub_id.clone(), info);
        self.emit_worker_event(crate::events::DaemonEvent::WorkerStarted {
            id: sub_id.clone(),
            task: format!("sub-worker of {}: {}", parent_id, desc_clone),
            started_at: Utc::now().to_rfc3339(),
        });

        Some(sub_id)
    }

    /// Get results from all completed sub-workers of a parent.
    /// Returns Vec<(sub_task_id, result_text)>.
    pub async fn get_sub_results(&self, parent_id: &str) -> Vec<(String, String)> {
        let workers = self.workers.read().await;
        // Collect sub-worker result Arcs first, then read them outside the main lock
        let sub_workers: Vec<(String, Arc<RwLock<Option<String>>>)> = workers
            .values()
            .filter(|w| {
                w.parent_id.as_deref() == Some(parent_id) && w.status == WorkerStatus::Completed
            })
            .map(|w| (w.task_id.clone(), w.result.clone()))
            .collect();
        drop(workers);

        let mut results = Vec::new();
        for (task_id, result_arc) in sub_workers {
            let guard = result_arc.read().await;
            if let Some(ref result_text) = *guard {
                results.push((task_id, result_text.clone()));
            }
        }
        results
    }

    // ----- Steering support -----

    /// Push a steering message to an active worker's buffer.
    pub async fn steer(&self, task_id: &str, message: String) -> bool {
        let workers = self.workers.read().await;
        if let Some(w) = workers.get(task_id) {
            if w.status == WorkerStatus::Running {
                w.steering_messages.write().await.push(message);
                return true;
            }
        }
        false
    }

    /// Drain all pending steering messages for a worker.
    pub async fn drain_steering(&self, task_id: &str) -> Vec<String> {
        let workers = self.workers.read().await;
        if let Some(w) = workers.get(task_id) {
            let mut msgs = w.steering_messages.write().await;
            msgs.drain(..).collect()
        } else {
            Vec::new()
        }
    }

    /// Check if there's an active worker for a given chat and return its task_id.
    /// Used to decide whether an incoming message should steer an existing worker.
    pub async fn active_worker_for_chat(&self, chat_id: i64) -> Option<String> {
        let workers = self.workers.read().await;
        // Return the most recently started running worker for this chat
        workers
            .values()
            .filter(|w| w.chat_id == chat_id && w.status == WorkerStatus::Running)
            .max_by_key(|w| w.started_at)
            .map(|w| w.task_id.clone())
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

    /// Clean up old completed/failed/cancelled workers (older than 1 hour).
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
