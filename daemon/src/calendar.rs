//! Calendar integration — Simple event management.
//!
//! Stores events locally in SQLite. Future: sync with CalDAV/Google Calendar.
//! For now, provides local-only event tracking that the supervisor can use.

use anyhow::Result;
use chrono::{Local, Utc};
use log::info;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::Mutex;

use crate::time_context;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CalendarEvent {
    pub id: String,
    pub title: String,
    pub description: String,
    pub start_time: String,
    pub end_time: Option<String>,
    pub reminder_minutes: Option<i32>,
    pub timezone: String,
    pub created_at: String,
}

pub struct CalendarManager {
    db: Mutex<Connection>,
}

impl CalendarManager {
    pub fn new(data_dir: &Path) -> Result<Self> {
        let db_path = data_dir.join("calendar.db");
        std::fs::create_dir_all(data_dir)?;
        let conn = Connection::open(&db_path)?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                start_time TEXT NOT NULL,
                end_time TEXT,
                reminder_minutes INTEGER,
                created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_events_start ON events(start_time);",
        )?;

        // Forward-compatible migrations for OS upgrades.
        Self::run_migrations(&conn)?;

        info!("Calendar manager initialized");
        Ok(Self {
            db: Mutex::new(conn),
        })
    }

    /// Apply forward-compatible schema migrations for OS upgrades.
    fn run_migrations(db: &Connection) -> Result<()> {
        let has_column = |table: &str, col: &str| -> bool {
            db.prepare(&format!(
                "SELECT 1 FROM pragma_table_info('{}') WHERE name = ?1",
                table
            ))
            .and_then(|mut stmt| stmt.exists(params![col]))
            .unwrap_or(false)
        };

        // Migration: add `location` column (added after v0.2).
        if !has_column("events", "location") {
            db.execute_batch("ALTER TABLE events ADD COLUMN location TEXT;")?;
        }
        // Migration: add `recurrence` column for recurring events.
        if !has_column("events", "recurrence") {
            db.execute_batch("ALTER TABLE events ADD COLUMN recurrence TEXT;")?;
        }
        // Migration: add `timezone` column for timezone-aware events (AM.4/AM.6).
        if !has_column("events", "timezone") {
            db.execute_batch("ALTER TABLE events ADD COLUMN timezone TEXT DEFAULT 'UTC';")?;
        }

        Ok(())
    }

    /// Add a new event.
    ///
    /// Times are converted to UTC before storage. The creator's timezone is saved
    /// so the event can be displayed back in local time (AM.4/AM.6).
    pub fn add_event(
        &self,
        title: &str,
        start_time: &str,
        end_time: Option<&str>,
        description: &str,
        reminder_minutes: Option<i32>,
    ) -> Result<CalendarEvent> {
        let id = uuid::Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();

        // Detect user timezone for storage and conversion
        let user_tz = time_context::get_user_timezone();

        // Convert start_time to UTC for consistent storage
        let start_utc = match time_context::local_to_utc(start_time, &user_tz) {
            Ok(dt) => dt.to_rfc3339(),
            Err(_) => start_time.to_string(), // Fallback: store as-is
        };

        // Convert end_time to UTC if present
        let end_utc = end_time.map(|et| {
            time_context::local_to_utc(et, &user_tz)
                .map(|dt| dt.to_rfc3339())
                .unwrap_or_else(|_| et.to_string())
        });

        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute(
            "INSERT INTO events (id, title, description, start_time, end_time, reminder_minutes, timezone, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![id, title, description, start_utc, end_utc, reminder_minutes, user_tz, now],
        )?;

        info!("Event created: {} — {} (tz: {})", id, title, user_tz);

        Ok(CalendarEvent {
            id,
            title: title.to_string(),
            description: description.to_string(),
            start_time: start_utc,
            end_time: end_utc,
            reminder_minutes,
            timezone: user_tz,
            created_at: now,
        })
    }

    /// Get today's events.
    ///
    /// Uses a UTC time range covering the full local "today" in the user's timezone,
    /// so events stored in UTC are correctly matched to the user's local day.
    pub fn today(&self) -> Result<Vec<CalendarEvent>> {
        let user_tz = time_context::get_user_timezone();
        let today_local = Local::now().format("%Y-%m-%d").to_string();

        // Build UTC range for today in the user's timezone
        let (from_utc, to_utc) =
            time_context::date_time_range_to_utc(&today_local, "00:00", "23:59", &user_tz)
                .unwrap_or_else(|_| {
                    // Fallback: use LIKE on today's date
                    (
                        format!("{}T00:00:00+00:00", today_local),
                        format!("{}T23:59:59+00:00", today_local),
                    )
                });

        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;

        let mut stmt = db.prepare(
            "SELECT id, title, description, start_time, end_time, reminder_minutes, \
                    COALESCE(timezone, 'UTC'), created_at
             FROM events WHERE start_time >= ?1 AND start_time <= ?2 ORDER BY start_time",
        )?;

        let events = stmt
            .query_map(params![from_utc, to_utc], |row| {
                Ok(CalendarEvent {
                    id: row.get(0)?,
                    title: row.get(1)?,
                    description: row.get(2)?,
                    start_time: row.get(3)?,
                    end_time: row.get(4)?,
                    reminder_minutes: row.get(5)?,
                    timezone: row.get(6)?,
                    created_at: row.get(7)?,
                })
            })?
            .filter_map(|r| r.ok())
            .collect();

        Ok(events)
    }

    /// Get upcoming events (next N days).
    pub fn upcoming(&self, days: u32) -> Result<Vec<CalendarEvent>> {
        let now = Utc::now().to_rfc3339();
        let future = (Utc::now() + chrono::Duration::days(days as i64)).to_rfc3339();

        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;

        let mut stmt = db.prepare(
            "SELECT id, title, description, start_time, end_time, reminder_minutes, \
                    COALESCE(timezone, 'UTC'), created_at
             FROM events WHERE start_time >= ?1 AND start_time <= ?2 ORDER BY start_time",
        )?;

        let events = stmt
            .query_map(params![now, future], |row| {
                Ok(CalendarEvent {
                    id: row.get(0)?,
                    title: row.get(1)?,
                    description: row.get(2)?,
                    start_time: row.get(3)?,
                    end_time: row.get(4)?,
                    reminder_minutes: row.get(5)?,
                    timezone: row.get(6)?,
                    created_at: row.get(7)?,
                })
            })?
            .filter_map(|r| r.ok())
            .collect();

        Ok(events)
    }

    /// Delete an event.
    pub fn delete(&self, event_id: &str) -> Result<()> {
        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute("DELETE FROM events WHERE id = ?1", params![event_id])?;
        Ok(())
    }

    /// Get events that need reminder now.
    pub fn due_reminders(&self) -> Result<Vec<CalendarEvent>> {
        let now = Local::now();
        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;

        let mut stmt = db.prepare(
            "SELECT id, title, description, start_time, end_time, reminder_minutes, \
                    COALESCE(timezone, 'UTC'), created_at
             FROM events WHERE reminder_minutes IS NOT NULL ORDER BY start_time",
        )?;

        let events: Vec<CalendarEvent> = stmt
            .query_map([], |row| {
                Ok(CalendarEvent {
                    id: row.get(0)?,
                    title: row.get(1)?,
                    description: row.get(2)?,
                    start_time: row.get(3)?,
                    end_time: row.get(4)?,
                    reminder_minutes: row.get(5)?,
                    timezone: row.get(6)?,
                    created_at: row.get(7)?,
                })
            })?
            .filter_map(|r| r.ok())
            .collect();

        // Filter: events where (start_time - reminder_minutes) <= now <= start_time
        let due = events
            .into_iter()
            .filter(|e| {
                if let (Ok(start), Some(mins)) = (
                    chrono::DateTime::parse_from_rfc3339(&e.start_time),
                    e.reminder_minutes,
                ) {
                    let reminder_time = start - chrono::Duration::minutes(mins as i64);
                    let now_fixed = now.fixed_offset();
                    now_fixed >= reminder_time && now_fixed <= start
                } else {
                    false
                }
            })
            .collect();

        Ok(due)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn tmp_cal() -> CalendarManager {
        let dir = PathBuf::from("/tmp/lifeos-test-cal").join(uuid::Uuid::new_v4().to_string());
        CalendarManager::new(&dir).unwrap()
    }

    #[test]
    fn add_and_list_today() {
        let cal = tmp_cal();
        let today = chrono::Local::now().format("%Y-%m-%dT15:00:00").to_string();
        cal.add_event("Test meeting", &today, None, "desc", Some(15))
            .unwrap();
        let events = cal.today().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].title, "Test meeting");
    }

    #[test]
    fn delete_event() {
        let cal = tmp_cal();
        let today = chrono::Local::now().format("%Y-%m-%dT16:00:00").to_string();
        let event = cal.add_event("To delete", &today, None, "", None).unwrap();
        cal.delete(&event.id).unwrap();
        assert!(cal.today().unwrap().is_empty());
    }
}
