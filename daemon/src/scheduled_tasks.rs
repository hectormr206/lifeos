//! Scheduled tasks — cron-like recurring task execution.
//!
//! Users can schedule tasks that run at specific intervals.
//! Tasks are persisted in SQLite and survive daemon restarts.

use anyhow::Result;
use chrono::{Datelike, Local, NaiveTime};
use log::{info, warn};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::Mutex;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScheduledTask {
    pub id: String,
    pub objective: String,
    pub schedule: Schedule,
    pub enabled: bool,
    pub last_run: Option<String>,
    pub next_run: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Schedule {
    /// Run every N minutes
    Interval { minutes: u32 },
    /// Run daily at a specific time (HH:MM)
    Daily { time: String },
    /// Run on specific weekdays at a time (0=Mon, 6=Sun)
    Weekly { days: Vec<u8>, time: String },
}

#[allow(dead_code)]
pub struct ScheduledTaskManager {
    db: Mutex<Connection>,
}

impl ScheduledTaskManager {
    pub fn new(data_dir: &Path) -> Result<Self> {
        let db_path = data_dir.join("scheduled_tasks.db");
        std::fs::create_dir_all(data_dir)?;
        let conn = Connection::open(&db_path)?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS scheduled_tasks (
                id TEXT PRIMARY KEY,
                objective TEXT NOT NULL,
                schedule_json TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                last_run TEXT,
                next_run TEXT,
                created_at TEXT NOT NULL
            );",
        )?;

        info!("Scheduled tasks manager initialized");
        Ok(Self {
            db: Mutex::new(conn),
        })
    }

    /// Add a new scheduled task.
    pub fn add(&self, objective: &str, schedule: Schedule) -> Result<ScheduledTask> {
        let id = uuid::Uuid::new_v4().to_string();
        let now = Local::now().to_rfc3339();
        let schedule_json = serde_json::to_string(&schedule)?;
        let next_run = compute_next_run(&schedule).map(|t| t.to_rfc3339());

        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute(
            "INSERT INTO scheduled_tasks (id, objective, schedule_json, enabled, next_run, created_at)
             VALUES (?1, ?2, ?3, 1, ?4, ?5)",
            params![id, objective, schedule_json, next_run, now],
        )?;

        info!("Scheduled task created: {} — {}", id, objective);

        Ok(ScheduledTask {
            id,
            objective: objective.to_string(),
            schedule,
            enabled: true,
            last_run: None,
            next_run,
            created_at: now,
        })
    }

    /// List all scheduled tasks.
    pub fn list(&self) -> Result<Vec<ScheduledTask>> {
        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        let mut stmt = db.prepare(
            "SELECT id, objective, schedule_json, enabled, last_run, next_run, created_at
             FROM scheduled_tasks ORDER BY created_at",
        )?;

        let tasks = stmt
            .query_map([], |row| {
                let schedule_json: String = row.get(2)?;
                Ok(ScheduledTask {
                    id: row.get(0)?,
                    objective: row.get(1)?,
                    schedule: serde_json::from_str(&schedule_json)
                        .unwrap_or(Schedule::Interval { minutes: 60 }),
                    enabled: row.get::<_, i32>(3)? != 0,
                    last_run: row.get(4)?,
                    next_run: row.get(5)?,
                    created_at: row.get(6)?,
                })
            })?
            .filter_map(|r| r.ok())
            .collect();

        Ok(tasks)
    }

    /// Get tasks that are due to run now.
    pub fn get_due_tasks(&self) -> Result<Vec<ScheduledTask>> {
        let now = Local::now().to_rfc3339();
        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        let mut stmt = db.prepare(
            "SELECT id, objective, schedule_json, enabled, last_run, next_run, created_at
             FROM scheduled_tasks
             WHERE enabled = 1 AND next_run IS NOT NULL AND next_run <= ?1",
        )?;

        let tasks = stmt
            .query_map(params![now], |row| {
                let schedule_json: String = row.get(2)?;
                Ok(ScheduledTask {
                    id: row.get(0)?,
                    objective: row.get(1)?,
                    schedule: serde_json::from_str(&schedule_json)
                        .unwrap_or(Schedule::Interval { minutes: 60 }),
                    enabled: row.get::<_, i32>(3)? != 0,
                    last_run: row.get(4)?,
                    next_run: row.get(5)?,
                    created_at: row.get(6)?,
                })
            })?
            .filter_map(|r| r.ok())
            .collect();

        Ok(tasks)
    }

    /// Mark a task as executed and compute next run.
    pub fn mark_executed(&self, task_id: &str, schedule: &Schedule) -> Result<()> {
        let now = Local::now().to_rfc3339();
        let next_run = compute_next_run(schedule).map(|t| t.to_rfc3339());

        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute(
            "UPDATE scheduled_tasks SET last_run = ?1, next_run = ?2 WHERE id = ?3",
            params![now, next_run, task_id],
        )?;
        Ok(())
    }

    /// Delete a scheduled task.
    pub fn delete(&self, task_id: &str) -> Result<()> {
        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute(
            "DELETE FROM scheduled_tasks WHERE id = ?1",
            params![task_id],
        )?;
        Ok(())
    }

    /// Enable/disable a task.
    pub fn set_enabled(&self, task_id: &str, enabled: bool) -> Result<()> {
        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute(
            "UPDATE scheduled_tasks SET enabled = ?1 WHERE id = ?2",
            params![enabled as i32, task_id],
        )?;
        Ok(())
    }
}

fn compute_next_run(schedule: &Schedule) -> Option<chrono::DateTime<Local>> {
    let now = Local::now();
    match schedule {
        Schedule::Interval { minutes } => Some(now + chrono::Duration::minutes(*minutes as i64)),
        Schedule::Daily { time } => {
            if let Ok(t) = NaiveTime::parse_from_str(time, "%H:%M") {
                let today = now.date_naive().and_time(t);
                let dt = today
                    .and_local_timezone(Local)
                    .single()
                    .unwrap_or(now);
                if dt > now {
                    Some(dt)
                } else {
                    Some(dt + chrono::Duration::days(1))
                }
            } else {
                warn!("Invalid time format: {}", time);
                None
            }
        }
        Schedule::Weekly { days, time } => {
            if days.is_empty() {
                return None;
            }
            if let Ok(t) = NaiveTime::parse_from_str(time, "%H:%M") {
                let today_weekday = now.weekday().num_days_from_monday() as u8;
                // Find next matching day
                for offset in 0..8 {
                    let check_day = (today_weekday + offset) % 7;
                    if days.contains(&check_day) {
                        let candidate = now.date_naive() + chrono::Duration::days(offset as i64);
                        let dt = candidate
                            .and_time(t)
                            .and_local_timezone(Local)
                            .single()
                            .unwrap_or(now);
                        if dt > now {
                            return Some(dt);
                        }
                    }
                }
            }
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn tmp_manager() -> ScheduledTaskManager {
        let dir = PathBuf::from("/tmp/lifeos-test-sched").join(uuid::Uuid::new_v4().to_string());
        ScheduledTaskManager::new(&dir).unwrap()
    }

    #[test]
    fn add_and_list() {
        let mgr = tmp_manager();
        mgr.add("test task", Schedule::Interval { minutes: 30 })
            .unwrap();
        let tasks = mgr.list().unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].objective, "test task");
        assert!(tasks[0].enabled);
    }

    #[test]
    fn delete_task() {
        let mgr = tmp_manager();
        let task = mgr
            .add(
                "to delete",
                Schedule::Daily {
                    time: "09:00".into(),
                },
            )
            .unwrap();
        mgr.delete(&task.id).unwrap();
        assert!(mgr.list().unwrap().is_empty());
    }

    #[test]
    fn disable_enable() {
        let mgr = tmp_manager();
        let task = mgr
            .add("toggleable", Schedule::Interval { minutes: 10 })
            .unwrap();
        mgr.set_enabled(&task.id, false).unwrap();
        let tasks = mgr.list().unwrap();
        assert!(!tasks[0].enabled);
    }
}
