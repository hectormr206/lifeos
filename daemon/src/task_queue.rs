//! Persistent task queue backed by SQLite.
//!
//! Tasks survive daemon restarts. The supervisor pulls tasks from this queue,
//! executes them, and updates their state.

use anyhow::{Context, Result};
use chrono::Local;
use log::{info, warn};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Pending,
    Running,
    Completed,
    Failed,
    Retrying,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskPriority {
    Low,
    Normal,
    High,
    Urgent,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub id: String,
    pub objective: String,
    pub status: TaskStatus,
    pub priority: TaskPriority,
    pub source: String,
    pub plan: Option<String>,
    pub result: Option<String>,
    pub error: Option<String>,
    pub attempts: u32,
    pub max_attempts: u32,
    pub created_at: String,
    pub updated_at: String,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskCreate {
    pub objective: String,
    #[serde(default = "default_priority")]
    pub priority: TaskPriority,
    #[serde(default = "default_source")]
    pub source: String,
    #[serde(default = "default_max_attempts")]
    pub max_attempts: u32,
}

fn default_priority() -> TaskPriority {
    TaskPriority::Normal
}
fn default_source() -> String {
    "api".into()
}
fn default_max_attempts() -> u32 {
    3
}

// ---------------------------------------------------------------------------
// TaskQueue
// ---------------------------------------------------------------------------

pub struct TaskQueue {
    db: Mutex<Connection>,
    #[allow(dead_code)]
    db_path: PathBuf,
}

impl TaskQueue {
    pub fn new(data_dir: &Path) -> Result<Self> {
        let db_path = data_dir.join("task_queue.db");
        std::fs::create_dir_all(data_dir)?;

        let conn = Connection::open(&db_path)
            .with_context(|| format!("Failed to open task queue DB at {}", db_path.display()))?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS tasks (
                id          TEXT PRIMARY KEY,
                objective   TEXT NOT NULL,
                status      TEXT NOT NULL DEFAULT 'pending',
                priority    TEXT NOT NULL DEFAULT 'normal',
                source      TEXT NOT NULL DEFAULT 'api',
                plan        TEXT,
                result      TEXT,
                error       TEXT,
                attempts    INTEGER NOT NULL DEFAULT 0,
                max_attempts INTEGER NOT NULL DEFAULT 3,
                created_at  TEXT NOT NULL,
                updated_at  TEXT NOT NULL,
                started_at  TEXT,
                completed_at TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
            CREATE INDEX IF NOT EXISTS idx_tasks_priority ON tasks(priority);",
        )?;

        info!("Task queue initialized at {}", db_path.display());

        Ok(Self {
            db: Mutex::new(conn),
            db_path,
        })
    }

    /// Add a new task to the queue.
    pub fn enqueue(&self, create: TaskCreate) -> Result<Task> {
        let id = uuid::Uuid::new_v4().to_string();
        let now = Local::now().to_rfc3339();
        let status = "pending";
        let priority = serde_json::to_value(create.priority)?
            .as_str()
            .unwrap_or("normal")
            .to_string();

        let db = self.db.lock().map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute(
            "INSERT INTO tasks (id, objective, status, priority, source, attempts, max_attempts, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?7, ?8)",
            params![id, create.objective, status, priority, create.source, create.max_attempts, now, now],
        )?;

        info!("Task enqueued: {} — {}", id, create.objective);

        Ok(Task {
            id,
            objective: create.objective,
            status: TaskStatus::Pending,
            priority: create.priority,
            source: create.source,
            plan: None,
            result: None,
            error: None,
            attempts: 0,
            max_attempts: create.max_attempts,
            created_at: now.clone(),
            updated_at: now,
            started_at: None,
            completed_at: None,
        })
    }

    /// Get the next pending task (highest priority first, oldest first).
    pub fn dequeue(&self) -> Result<Option<Task>> {
        let db = self.db.lock().map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;

        let mut stmt = db.prepare(
            "SELECT id, objective, status, priority, source, plan, result, error,
                    attempts, max_attempts, created_at, updated_at, started_at, completed_at
             FROM tasks
             WHERE status IN ('pending', 'retrying')
             ORDER BY
                CASE priority
                    WHEN 'urgent' THEN 0
                    WHEN 'high' THEN 1
                    WHEN 'normal' THEN 2
                    WHEN 'low' THEN 3
                END,
                created_at ASC
             LIMIT 1",
        )?;

        let task = stmt
            .query_row([], |row| {
                Ok(Task {
                    id: row.get(0)?,
                    objective: row.get(1)?,
                    status: parse_status(row.get::<_, String>(2)?.as_str()),
                    priority: parse_priority(row.get::<_, String>(3)?.as_str()),
                    source: row.get(4)?,
                    plan: row.get(5)?,
                    result: row.get(6)?,
                    error: row.get(7)?,
                    attempts: row.get(8)?,
                    max_attempts: row.get(9)?,
                    created_at: row.get(10)?,
                    updated_at: row.get(11)?,
                    started_at: row.get(12)?,
                    completed_at: row.get(13)?,
                })
            })
            .optional()?;

        Ok(task)
    }

    /// Mark a task as running.
    pub fn mark_running(&self, task_id: &str) -> Result<()> {
        let now = Local::now().to_rfc3339();
        let db = self.db.lock().map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute(
            "UPDATE tasks SET status = 'running', started_at = ?1, updated_at = ?2, attempts = attempts + 1 WHERE id = ?3",
            params![now, now, task_id],
        )?;
        Ok(())
    }

    /// Mark a task as completed with a result.
    pub fn mark_completed(&self, task_id: &str, result: &str) -> Result<()> {
        let now = Local::now().to_rfc3339();
        let db = self.db.lock().map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute(
            "UPDATE tasks SET status = 'completed', result = ?1, completed_at = ?2, updated_at = ?3 WHERE id = ?4",
            params![result, now, now, task_id],
        )?;
        info!("Task completed: {}", task_id);
        Ok(())
    }

    /// Mark a task as failed. If under max_attempts, set to retrying instead.
    pub fn mark_failed(&self, task_id: &str, error: &str) -> Result<bool> {
        let now = Local::now().to_rfc3339();
        let db = self.db.lock().map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;

        let (attempts, max_attempts): (u32, u32) = db.query_row(
            "SELECT attempts, max_attempts FROM tasks WHERE id = ?1",
            params![task_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;

        let will_retry = attempts < max_attempts;
        let new_status = if will_retry { "retrying" } else { "failed" };

        db.execute(
            "UPDATE tasks SET status = ?1, error = ?2, updated_at = ?3 WHERE id = ?4",
            params![new_status, error, now, task_id],
        )?;

        if will_retry {
            warn!("Task {} failed (attempt {}/{}), will retry: {}", task_id, attempts, max_attempts, error);
        } else {
            warn!("Task {} failed permanently after {} attempts: {}", task_id, attempts, error);
        }

        Ok(will_retry)
    }

    /// Store the plan JSON for a task.
    pub fn set_plan(&self, task_id: &str, plan: &str) -> Result<()> {
        let now = Local::now().to_rfc3339();
        let db = self.db.lock().map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute(
            "UPDATE tasks SET plan = ?1, updated_at = ?2 WHERE id = ?3",
            params![plan, now, task_id],
        )?;
        Ok(())
    }

    /// Cancel a task.
    pub fn cancel(&self, task_id: &str) -> Result<()> {
        let now = Local::now().to_rfc3339();
        let db = self.db.lock().map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute(
            "UPDATE tasks SET status = 'cancelled', updated_at = ?1 WHERE id = ?2",
            params![now, task_id],
        )?;
        Ok(())
    }

    /// List tasks with optional status filter.
    pub fn list(&self, status_filter: Option<TaskStatus>, limit: u32) -> Result<Vec<Task>> {
        let db = self.db.lock().map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;

        let (query, filter_val) = if let Some(status) = status_filter {
            let s = status_to_str(status);
            (
                "SELECT id, objective, status, priority, source, plan, result, error,
                        attempts, max_attempts, created_at, updated_at, started_at, completed_at
                 FROM tasks WHERE status = ?1 ORDER BY updated_at DESC LIMIT ?2",
                Some(s),
            )
        } else {
            (
                "SELECT id, objective, status, priority, source, plan, result, error,
                        attempts, max_attempts, created_at, updated_at, started_at, completed_at
                 FROM tasks ORDER BY updated_at DESC LIMIT ?2",
                None,
            )
        };

        let mut stmt = db.prepare(query)?;

        let rows = if let Some(ref s) = filter_val {
            stmt.query_map(params![s, limit], row_to_task)?
        } else {
            stmt.query_map(params![limit], row_to_task)?
        };

        let tasks: Vec<Task> = rows.filter_map(|r| r.ok()).collect();
        Ok(tasks)
    }

    /// Get a summary of queue state.
    pub fn summary(&self) -> Result<serde_json::Value> {
        let db = self.db.lock().map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        let mut stmt = db.prepare("SELECT status, COUNT(*) FROM tasks GROUP BY status")?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?;

        let mut counts = serde_json::Map::new();
        for row in rows.flatten() {
            counts.insert(row.0, serde_json::json!(row.1));
        }

        Ok(serde_json::Value::Object(counts))
    }

    /// Get a single task by ID.
    pub fn get(&self, task_id: &str) -> Result<Option<Task>> {
        let db = self.db.lock().map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        let task = db
            .query_row(
                "SELECT id, objective, status, priority, source, plan, result, error,
                        attempts, max_attempts, created_at, updated_at, started_at, completed_at
                 FROM tasks WHERE id = ?1",
                params![task_id],
                row_to_task,
            )
            .optional()?;
        Ok(task)
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn row_to_task(row: &rusqlite::Row) -> rusqlite::Result<Task> {
    Ok(Task {
        id: row.get(0)?,
        objective: row.get(1)?,
        status: parse_status(row.get::<_, String>(2)?.as_str()),
        priority: parse_priority(row.get::<_, String>(3)?.as_str()),
        source: row.get(4)?,
        plan: row.get(5)?,
        result: row.get(6)?,
        error: row.get(7)?,
        attempts: row.get(8)?,
        max_attempts: row.get(9)?,
        created_at: row.get(10)?,
        updated_at: row.get(11)?,
        started_at: row.get(12)?,
        completed_at: row.get(13)?,
    })
}

fn parse_status(s: &str) -> TaskStatus {
    match s {
        "pending" => TaskStatus::Pending,
        "running" => TaskStatus::Running,
        "completed" => TaskStatus::Completed,
        "failed" => TaskStatus::Failed,
        "retrying" => TaskStatus::Retrying,
        "cancelled" => TaskStatus::Cancelled,
        _ => TaskStatus::Pending,
    }
}

fn parse_priority(s: &str) -> TaskPriority {
    match s {
        "low" => TaskPriority::Low,
        "normal" => TaskPriority::Normal,
        "high" => TaskPriority::High,
        "urgent" => TaskPriority::Urgent,
        _ => TaskPriority::Normal,
    }
}

fn status_to_str(s: TaskStatus) -> String {
    match s {
        TaskStatus::Pending => "pending",
        TaskStatus::Running => "running",
        TaskStatus::Completed => "completed",
        TaskStatus::Failed => "failed",
        TaskStatus::Retrying => "retrying",
        TaskStatus::Cancelled => "cancelled",
    }
    .into()
}

// We need rusqlite optional query support
trait OptionalExt<T> {
    fn optional(self) -> Result<Option<T>, rusqlite::Error>;
}
impl<T> OptionalExt<T> for rusqlite::Result<T> {
    fn optional(self) -> Result<Option<T>, rusqlite::Error> {
        match self {
            Ok(val) => Ok(Some(val)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn tmp_queue() -> TaskQueue {
        let dir = PathBuf::from("/tmp/lifeos-test-queue")
            .join(uuid::Uuid::new_v4().to_string());
        TaskQueue::new(&dir).unwrap()
    }

    #[test]
    fn enqueue_and_dequeue() {
        let q = tmp_queue();
        let task = q
            .enqueue(TaskCreate {
                objective: "test task".into(),
                priority: TaskPriority::Normal,
                source: "test".into(),
                max_attempts: 3,
            })
            .unwrap();

        assert_eq!(task.status, TaskStatus::Pending);

        let next = q.dequeue().unwrap().unwrap();
        assert_eq!(next.id, task.id);
    }

    #[test]
    fn mark_running_and_completed() {
        let q = tmp_queue();
        let task = q
            .enqueue(TaskCreate {
                objective: "complete me".into(),
                priority: TaskPriority::Normal,
                source: "test".into(),
                max_attempts: 3,
            })
            .unwrap();

        q.mark_running(&task.id).unwrap();
        let t = q.get(&task.id).unwrap().unwrap();
        assert_eq!(t.status, TaskStatus::Running);
        assert_eq!(t.attempts, 1);

        q.mark_completed(&task.id, "done!").unwrap();
        let t = q.get(&task.id).unwrap().unwrap();
        assert_eq!(t.status, TaskStatus::Completed);
        assert_eq!(t.result.as_deref(), Some("done!"));
    }

    #[test]
    fn retry_then_fail() {
        let q = tmp_queue();
        let task = q
            .enqueue(TaskCreate {
                objective: "retry me".into(),
                priority: TaskPriority::Normal,
                source: "test".into(),
                max_attempts: 2,
            })
            .unwrap();

        q.mark_running(&task.id).unwrap();
        let will_retry = q.mark_failed(&task.id, "error 1").unwrap();
        assert!(will_retry);

        let t = q.get(&task.id).unwrap().unwrap();
        assert_eq!(t.status, TaskStatus::Retrying);

        q.mark_running(&task.id).unwrap();
        let will_retry = q.mark_failed(&task.id, "error 2").unwrap();
        assert!(!will_retry);

        let t = q.get(&task.id).unwrap().unwrap();
        assert_eq!(t.status, TaskStatus::Failed);
    }

    #[test]
    fn priority_ordering() {
        let q = tmp_queue();
        q.enqueue(TaskCreate {
            objective: "low".into(),
            priority: TaskPriority::Low,
            source: "test".into(),
            max_attempts: 1,
        })
        .unwrap();
        q.enqueue(TaskCreate {
            objective: "urgent".into(),
            priority: TaskPriority::Urgent,
            source: "test".into(),
            max_attempts: 1,
        })
        .unwrap();

        let next = q.dequeue().unwrap().unwrap();
        assert_eq!(next.objective, "urgent");
    }

    #[test]
    fn summary_counts() {
        let q = tmp_queue();
        q.enqueue(TaskCreate {
            objective: "a".into(),
            priority: TaskPriority::Normal,
            source: "test".into(),
            max_attempts: 1,
        })
        .unwrap();
        q.enqueue(TaskCreate {
            objective: "b".into(),
            priority: TaskPriority::Normal,
            source: "test".into(),
            max_attempts: 1,
        })
        .unwrap();

        let summary = q.summary().unwrap();
        assert_eq!(summary["pending"], 2);
    }
}
