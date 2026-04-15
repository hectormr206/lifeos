//! Calendar integration — Simple event management.
//!
//! Stores events locally in SQLite. Future: sync with CalDAV/Google Calendar.
//! For now, provides local-only event tracking that the supervisor can use.
//!
//! # Recurring events — semantics and known limitations
//!
//! The `recurrence_matches` function operates on dates only (`NaiveDate`), not
//! on full datetimes. This has the following implications:
//!
//! * **DST transitions:** Because matching is date-level, daylight-saving
//!   transitions never cause a recurring event's date to be missed. The
//!   *time-of-day* of the original event is stored as UTC in `start_time`;
//!   callers that re-display it in a local timezone must perform their own
//!   UTC→local conversion (see `time_context`). A "weekly Monday 9am" event
//!   created in `Europe/Madrid` in January will still expand to every Monday
//!   after the spring-forward transition; the wall-clock display in the user's
//!   timezone is the responsibility of the rendering layer.
//! * **Monthly on the 29/30/31st:** When the original event is on a day that
//!   does not exist in the target month (e.g. Feb has no 30th/31st), the
//!   matcher falls back to the **last day of that month**. This means a
//!   "monthly on the 31st" event fires on Feb 28 (or Feb 29 in leap years),
//!   Apr 30, etc. To skip rather than clamp, mark those occurrences via
//!   `skip_occurrence`.
//! * **`custom:` weekday list:** Tokens are matched case-sensitively as
//!   exactly two-letter ISO-style abbreviations (`MO,TU,WE,TH,FR,SA,SU`).
//!   Whitespace around tokens is trimmed.
//! * **No COUNT/UNTIL/INTERVAL beyond biweekly:** Recurring events expand
//!   indefinitely from `start_time` forward; there is no end date. This is
//!   intentional for the v0.x local-only calendar and will be revisited when
//!   CalDAV import lands.

use anyhow::Result;
use chrono::{Datelike, Local, NaiveDate, Utc};
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
    pub recurrence: Option<String>,
    pub location: Option<String>,
    pub timezone: String,
    pub created_at: String,
}

pub struct CalendarManager {
    db: Mutex<Connection>,
}

/// Return the last day-of-month (28-31) for the given year/month.
///
/// Used by the `monthly` recurrence matcher to clamp day-of-month overflow
/// (e.g. "monthly on the 31st" → Feb 28 / Feb 29 / Apr 30, etc.).
fn last_day_of_month(year: i32, month: u32) -> u32 {
    // First day of next month minus one day = last day of this month.
    let (next_y, next_m) = if month == 12 {
        (year + 1, 1)
    } else {
        (year, month + 1)
    };
    NaiveDate::from_ymd_opt(next_y, next_m, 1)
        .and_then(|d| d.pred_opt())
        .map(|d| d.day())
        .unwrap_or(28)
}

/// Check whether a recurring event's pattern matches a target date.
///
/// `start_time` is the RFC-3339 (or date-prefix) string stored in the DB.
/// `recurrence` is one of: daily, weekdays, weekly, biweekly, monthly, custom:MO,TU,…
/// `target_date` is "YYYY-MM-DD".
fn recurrence_matches(start_time: &str, recurrence: &str, target_date: &str) -> bool {
    let target = match NaiveDate::parse_from_str(target_date, "%Y-%m-%d") {
        Ok(d) => d,
        Err(_) => return false,
    };

    // Extract the start date from an RFC-3339 or plain date string.
    let start_str = &start_time[..10.min(start_time.len())];
    let start = match NaiveDate::parse_from_str(start_str, "%Y-%m-%d") {
        Ok(d) => d,
        Err(_) => return false,
    };

    // Don't match dates before the event was created.
    if target < start {
        return false;
    }

    match recurrence {
        "daily" => true,
        "weekdays" => {
            let wd = target.weekday();
            wd != chrono::Weekday::Sat && wd != chrono::Weekday::Sun
        }
        "weekly" => target.weekday() == start.weekday(),
        "biweekly" => {
            if target.weekday() != start.weekday() {
                return false;
            }
            let weeks = (target - start).num_weeks();
            weeks % 2 == 0
        }
        "monthly" => {
            // Match the same day-of-month as the start date. If the start day
            // does not exist in the target month (e.g. start=31, target month
            // has 30 days, or Feb), clamp to the last day of the target month.
            let start_day = start.day();
            let last_day_of_target = last_day_of_month(target.year(), target.month());
            let effective_day = start_day.min(last_day_of_target);
            target.day() == effective_day
        }
        other if other.starts_with("custom:") => {
            let days_str = &other["custom:".len()..];
            let target_abbrev = match target.weekday() {
                chrono::Weekday::Mon => "MO",
                chrono::Weekday::Tue => "TU",
                chrono::Weekday::Wed => "WE",
                chrono::Weekday::Thu => "TH",
                chrono::Weekday::Fri => "FR",
                chrono::Weekday::Sat => "SA",
                chrono::Weekday::Sun => "SU",
            };
            days_str.split(',').any(|d| d.trim() == target_abbrev)
        }
        _ => false,
    }
}

impl CalendarManager {
    pub fn new(data_dir: &Path) -> Result<Self> {
        let db_path = data_dir.join("calendar.db");
        std::fs::create_dir_all(data_dir)?;
        let conn = Connection::open(&db_path)?;
        crate::sqlite_protection::ensure_sensitive_perms(&db_path);

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

        // Migration: event_exceptions table for skipped recurring occurrences (BD.1).
        db.execute_batch(
            "CREATE TABLE IF NOT EXISTS event_exceptions (
                event_id TEXT NOT NULL,
                exception_date TEXT NOT NULL,
                PRIMARY KEY (event_id, exception_date)
            );",
        )?;

        // Migration: reminder_history table (BD.6).
        db.execute_batch(
            "CREATE TABLE IF NOT EXISTS reminder_history (
                id TEXT PRIMARY KEY,
                event_id TEXT NOT NULL,
                event_title TEXT NOT NULL,
                sent_at TEXT NOT NULL,
                channel TEXT NOT NULL DEFAULT 'telegram',
                delivered INTEGER DEFAULT 1,
                retry_count INTEGER DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_reminder_event ON reminder_history(event_id);
            CREATE INDEX IF NOT EXISTS idx_reminder_sent ON reminder_history(sent_at);",
        )?;

        Ok(())
    }

    // ───────────────────────── Row mapper ─────────────────────────

    /// Standard SELECT column list used by all queries.
    const COLS: &'static str = "id, title, description, start_time, end_time, reminder_minutes, \
         recurrence, location, COALESCE(timezone, 'UTC'), created_at";

    fn row_to_event(row: &rusqlite::Row<'_>) -> rusqlite::Result<CalendarEvent> {
        Ok(CalendarEvent {
            id: row.get(0)?,
            title: row.get(1)?,
            description: row.get(2)?,
            start_time: row.get(3)?,
            end_time: row.get(4)?,
            reminder_minutes: row.get(5)?,
            recurrence: row.get(6)?,
            location: row.get(7)?,
            timezone: row.get(8)?,
            created_at: row.get(9)?,
        })
    }

    // ───────────────────────── Event CRUD ─────────────────────────

    /// Add a new event.
    ///
    /// Times are converted to UTC before storage. The creator's timezone is saved
    /// so the event can be displayed back in local time (AM.4/AM.6).
    #[allow(clippy::too_many_arguments)]
    pub fn add_event(
        &self,
        title: &str,
        start_time: &str,
        end_time: Option<&str>,
        description: &str,
        reminder_minutes: Option<i32>,
        recurrence: Option<&str>,
        location: Option<&str>,
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
            "INSERT INTO events (id, title, description, start_time, end_time, \
             reminder_minutes, recurrence, location, timezone, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                id,
                title,
                description,
                start_utc,
                end_utc,
                reminder_minutes,
                recurrence,
                location,
                user_tz,
                now
            ],
        )?;

        info!("Event created: {} — {} (tz: {})", id, title, user_tz);

        Ok(CalendarEvent {
            id,
            title: title.to_string(),
            description: description.to_string(),
            start_time: start_utc,
            end_time: end_utc,
            reminder_minutes,
            recurrence: recurrence.map(|s| s.to_string()),
            location: location.map(|s| s.to_string()),
            timezone: user_tz,
            created_at: now,
        })
    }

    /// Add a recurring event (convenience wrapper around `add_event`).
    pub fn add_recurring_event(
        &self,
        title: &str,
        start_time: &str,
        recurrence: &str,
        description: &str,
        reminder_minutes: Option<i32>,
        location: Option<&str>,
    ) -> Result<CalendarEvent> {
        self.add_event(
            title,
            start_time,
            None,
            description,
            reminder_minutes,
            Some(recurrence),
            location,
        )
    }

    // ───────────────────────── Recurring helpers ──────────────────

    /// Load all recurring events from the DB and expand those matching `target_date`,
    /// excluding any dates in `event_exceptions`.
    fn recurring_events_for_date(db: &Connection, target_date: &str) -> Result<Vec<CalendarEvent>> {
        let mut stmt = db.prepare(&format!(
            "SELECT {} FROM events WHERE recurrence IS NOT NULL",
            Self::COLS
        ))?;

        let all_recurring: Vec<CalendarEvent> = stmt
            .query_map([], Self::row_to_event)?
            .filter_map(|r| r.ok())
            .collect();

        let mut results = Vec::new();
        for ev in all_recurring {
            let rec = match &ev.recurrence {
                Some(r) => r.clone(),
                None => continue,
            };
            if !recurrence_matches(&ev.start_time, &rec, target_date) {
                continue;
            }
            // Check exceptions
            let excepted: bool = db
                .prepare(
                    "SELECT 1 FROM event_exceptions WHERE event_id = ?1 AND exception_date = ?2",
                )?
                .exists(params![ev.id, target_date])?;
            if excepted {
                continue;
            }
            results.push(ev);
        }
        Ok(results)
    }

    /// Skip a single occurrence of a recurring event on `date` (YYYY-MM-DD).
    pub fn skip_occurrence(&self, event_id: &str, date: &str) -> Result<()> {
        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute(
            "INSERT OR IGNORE INTO event_exceptions (event_id, exception_date) VALUES (?1, ?2)",
            params![event_id, date],
        )?;
        info!("Skipped occurrence: event {} on {}", event_id, date);
        Ok(())
    }

    // ───────────────────────── Queries ────────────────────────────

    /// Get today's events (one-off + matching recurring).
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
                    (
                        format!("{}T00:00:00+00:00", today_local),
                        format!("{}T23:59:59+00:00", today_local),
                    )
                });

        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;

        // One-off events (no recurrence) in today's range
        let mut stmt = db.prepare(&format!(
            "SELECT {} FROM events \
             WHERE start_time >= ?1 AND start_time <= ?2 \
               AND recurrence IS NULL \
             ORDER BY start_time",
            Self::COLS
        ))?;

        let mut events: Vec<CalendarEvent> = stmt
            .query_map(params![from_utc, to_utc], Self::row_to_event)?
            .filter_map(|r| r.ok())
            .collect();

        // Recurring events matching today
        let recurring = Self::recurring_events_for_date(&db, &today_local)?;
        events.extend(recurring);

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

        // One-off events in the date range
        let mut stmt = db.prepare(&format!(
            "SELECT {} FROM events \
             WHERE start_time >= ?1 AND start_time <= ?2 \
               AND recurrence IS NULL \
             ORDER BY start_time",
            Self::COLS
        ))?;

        let mut events: Vec<CalendarEvent> = stmt
            .query_map(params![now, future], Self::row_to_event)?
            .filter_map(|r| r.ok())
            .collect();

        // Expand recurring events for each day in the range
        let today = Local::now().date_naive();
        for d in 0..=days {
            let target = today + chrono::Duration::days(d as i64);
            let date_str = target.format("%Y-%m-%d").to_string();
            let recurring = Self::recurring_events_for_date(&db, &date_str)?;
            for ev in recurring {
                // Avoid duplicates (same id already added from a different day)
                if !events
                    .iter()
                    .any(|e| e.id == ev.id && e.start_time == ev.start_time)
                {
                    events.push(ev);
                }
            }
        }

        Ok(events)
    }

    /// Delete an event.
    pub fn delete(&self, event_id: &str) -> Result<()> {
        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute("DELETE FROM events WHERE id = ?1", params![event_id])?;
        db.execute(
            "DELETE FROM event_exceptions WHERE event_id = ?1",
            params![event_id],
        )?;
        Ok(())
    }

    /// Get events that need reminder now.
    ///
    /// Skips events that already have a reminder_history entry within the last 60
    /// minutes to prevent duplicate sends (BD.6).
    pub fn due_reminders(&self) -> Result<Vec<CalendarEvent>> {
        let now = Local::now();
        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;

        let mut stmt = db.prepare(&format!(
            "SELECT {} FROM events WHERE reminder_minutes IS NOT NULL ORDER BY start_time",
            Self::COLS
        ))?;

        let events: Vec<CalendarEvent> = stmt
            .query_map([], Self::row_to_event)?
            .filter_map(|r| r.ok())
            .collect();

        let one_hour_ago = (Utc::now() - chrono::Duration::minutes(60)).to_rfc3339();

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
                    if !(now_fixed >= reminder_time && now_fixed <= start) {
                        return false;
                    }
                    // Skip if reminder already sent within last 60 minutes (BD.6)
                    let already_sent: bool = db
                        .prepare(
                            "SELECT 1 FROM reminder_history \
                             WHERE event_id = ?1 AND sent_at >= ?2",
                        )
                        .and_then(|mut s| s.exists(params![e.id, one_hour_ago]))
                        .unwrap_or(false);
                    !already_sent
                } else {
                    false
                }
            })
            .collect();

        Ok(due)
    }

    // ───────────────────────── Reminder history (BD.6) ───────────

    /// Record that a reminder was sent for an event.
    pub fn record_reminder(&self, event_id: &str, event_title: &str, channel: &str) -> Result<()> {
        let id = uuid::Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute(
            "INSERT INTO reminder_history (id, event_id, event_title, sent_at, channel, delivered, retry_count)
             VALUES (?1, ?2, ?3, ?4, ?5, 1, 0)",
            params![id, event_id, event_title, now, channel],
        )?;
        info!("Reminder recorded for event {}", event_id);
        Ok(())
    }

    /// Mark the most recent reminder for an event as failed (not delivered) and
    /// increment its retry counter.
    pub fn mark_reminder_failed(&self, event_id: &str) -> Result<()> {
        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        db.execute(
            "UPDATE reminder_history SET delivered = 0, retry_count = retry_count + 1 \
             WHERE id = (SELECT id FROM reminder_history WHERE event_id = ?1 ORDER BY sent_at DESC LIMIT 1)",
            params![event_id],
        )?;
        Ok(())
    }

    /// Return undelivered reminders that still have retries left (< 3 attempts).
    /// Returns (event_id, event_title, channel).
    pub fn pending_retries(&self) -> Result<Vec<(String, String, String)>> {
        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        let mut stmt = db.prepare(
            "SELECT event_id, event_title, channel FROM reminder_history \
             WHERE delivered = 0 AND retry_count < 3",
        )?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// Return reminders sent today: (event_title, sent_at, channel).
    pub fn reminders_today(&self) -> Result<Vec<(String, String, String)>> {
        // sent_at is stored as UTC RFC-3339; build range for today in UTC
        let now_utc = Utc::now();
        let today_start = now_utc.format("%Y-%m-%dT00:00:00").to_string();
        let today_end = now_utc.format("%Y-%m-%dT23:59:59").to_string();
        let db = self
            .db
            .lock()
            .map_err(|e| anyhow::anyhow!("DB lock: {}", e))?;
        let mut stmt = db.prepare(
            "SELECT event_title, sent_at, channel FROM reminder_history \
             WHERE sent_at >= ?1 AND sent_at <= ?2 ORDER BY sent_at",
        )?;
        let rows = stmt
            .query_map(params![today_start, today_end], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
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
        cal.add_event("Test meeting", &today, None, "desc", Some(15), None, None)
            .unwrap();
        let events = cal.today().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].title, "Test meeting");
    }

    #[test]
    fn delete_event() {
        let cal = tmp_cal();
        let today = chrono::Local::now().format("%Y-%m-%dT16:00:00").to_string();
        let event = cal
            .add_event("To delete", &today, None, "", None, None, None)
            .unwrap();
        cal.delete(&event.id).unwrap();
        assert!(cal.today().unwrap().is_empty());
    }

    #[test]
    fn test_recurring_weekly() {
        let cal = tmp_cal();
        // Use today as start so the weekly recurrence matches today's weekday
        let today = chrono::Local::now().format("%Y-%m-%dT09:00:00").to_string();
        let ev = cal
            .add_recurring_event("Weekly standup", &today, "weekly", "team sync", None, None)
            .unwrap();
        assert_eq!(ev.recurrence.as_deref(), Some("weekly"));

        let today_str = chrono::Local::now().format("%Y-%m-%d").to_string();
        assert!(recurrence_matches(&ev.start_time, "weekly", &today_str));

        // Different weekday should NOT match (tomorrow is a different weekday unless
        // it wraps around at week boundary, but +1 day always differs).
        let tomorrow = (chrono::Local::now() + chrono::Duration::days(1))
            .format("%Y-%m-%d")
            .to_string();
        assert!(!recurrence_matches(&ev.start_time, "weekly", &tomorrow));
    }

    #[test]
    fn test_recurring_daily() {
        let cal = tmp_cal();
        let today = chrono::Local::now().format("%Y-%m-%dT08:00:00").to_string();
        let ev = cal
            .add_recurring_event("Daily journal", &today, "daily", "", None, None)
            .unwrap();

        let today_str = chrono::Local::now().format("%Y-%m-%d").to_string();
        assert!(recurrence_matches(&ev.start_time, "daily", &today_str));

        // Should also match tomorrow
        let tomorrow = (chrono::Local::now() + chrono::Duration::days(1))
            .format("%Y-%m-%d")
            .to_string();
        assert!(recurrence_matches(&ev.start_time, "daily", &tomorrow));

        // Verify it appears in today()
        let events = cal.today().unwrap();
        assert!(events.iter().any(|e| e.title == "Daily journal"));
    }

    #[test]
    fn test_skip_occurrence() {
        let cal = tmp_cal();
        let today = chrono::Local::now().format("%Y-%m-%dT10:00:00").to_string();
        let ev = cal
            .add_recurring_event("Skippable", &today, "daily", "", None, None)
            .unwrap();

        // Before skip, event shows up today
        let before = cal.today().unwrap();
        assert!(before.iter().any(|e| e.title == "Skippable"));

        // Skip today
        let today_str = chrono::Local::now().format("%Y-%m-%d").to_string();
        cal.skip_occurrence(&ev.id, &today_str).unwrap();

        // After skip, event should NOT show up today
        let after = cal.today().unwrap();
        assert!(!after.iter().any(|e| e.title == "Skippable"));
    }

    #[test]
    fn test_reminder_history() {
        let cal = tmp_cal();
        let today = chrono::Local::now().format("%Y-%m-%dT14:00:00").to_string();
        let ev = cal
            .add_event("Reminder test", &today, None, "", Some(15), None, None)
            .unwrap();

        cal.record_reminder(&ev.id, "Reminder test", "telegram")
            .unwrap();

        let today_reminders = cal.reminders_today().unwrap();
        assert_eq!(today_reminders.len(), 1);
        assert_eq!(today_reminders[0].0, "Reminder test");
        assert_eq!(today_reminders[0].2, "telegram");
    }

    // ───────────────────────── Recurring edge cases ─────────────────
    //
    // The following tests exercise `recurrence_matches` directly with fixed
    // RFC-3339 / date strings so they are deterministic regardless of when
    // the test suite runs.

    #[test]
    fn last_day_of_month_helper() {
        assert_eq!(last_day_of_month(2024, 1), 31);
        assert_eq!(last_day_of_month(2024, 2), 29); // leap
        assert_eq!(last_day_of_month(2025, 2), 28); // non-leap
        assert_eq!(last_day_of_month(2024, 4), 30);
        assert_eq!(last_day_of_month(2024, 12), 31);
    }

    // ── DST: weekly Monday across EU fall-back (Europe/Madrid, last Sun of Oct)
    #[test]
    fn weekly_monday_across_eu_fall_back_dst() {
        // 2024-10-27 = last Sunday of October (Europe/Madrid CEST→CET).
        // The Mondays bracketing this transition are 2024-10-21 and 2024-10-28.
        // Stored as UTC RFC-3339 (Madrid is UTC+2 in CEST → 09:00 local = 07:00Z).
        let start = "2024-10-21T07:00:00+00:00";
        assert!(recurrence_matches(start, "weekly", "2024-10-21"));
        assert!(recurrence_matches(start, "weekly", "2024-10-28")); // post fall-back
        assert!(recurrence_matches(start, "weekly", "2024-11-04"));
        // Sunday in between is not a Monday → no match.
        assert!(!recurrence_matches(start, "weekly", "2024-10-27"));
    }

    // ── DST: weekly Monday across US fall-back (America/New_York, first Sun of Nov)
    #[test]
    fn weekly_monday_across_us_fall_back_dst() {
        // 2024-11-03 = first Sunday of November (US DST ends).
        // Mondays around it: 2024-10-28, 2024-11-04, 2024-11-11.
        let start = "2024-10-28T13:00:00+00:00"; // 09:00 EDT
        assert!(recurrence_matches(start, "weekly", "2024-10-28"));
        assert!(recurrence_matches(start, "weekly", "2024-11-04"));
        assert!(recurrence_matches(start, "weekly", "2024-11-11"));
    }

    // ── DST: weekly Monday across spring-forward (Europe/Madrid, last Sun of Mar)
    #[test]
    fn weekly_monday_across_spring_forward_dst() {
        // 2024-03-31 = last Sunday of March (CET→CEST).
        // Mondays: 2024-03-25 (CET), 2024-04-01 (CEST), 2024-04-08.
        let start = "2024-03-25T08:00:00+00:00"; // 09:00 CET
        assert!(recurrence_matches(start, "weekly", "2024-03-25"));
        assert!(recurrence_matches(start, "weekly", "2024-04-01"));
        assert!(recurrence_matches(start, "weekly", "2024-04-08"));
    }

    // ── Monthly on the 31st: clamps to last day of shorter months
    #[test]
    fn monthly_31st_clamps_to_last_day_of_month() {
        let start = "2024-01-31T09:00:00+00:00";
        assert!(recurrence_matches(start, "monthly", "2024-01-31"));
        // Feb 2024 (leap year) has 29 days → clamp to Feb 29.
        assert!(recurrence_matches(start, "monthly", "2024-02-29"));
        assert!(!recurrence_matches(start, "monthly", "2024-02-28"));
        // March has 31 days → exact match.
        assert!(recurrence_matches(start, "monthly", "2024-03-31"));
        // April has 30 days → clamp to Apr 30.
        assert!(recurrence_matches(start, "monthly", "2024-04-30"));
        assert!(!recurrence_matches(start, "monthly", "2024-04-29"));
        // 2025 (non-leap): Feb clamps to Feb 28.
        assert!(recurrence_matches(start, "monthly", "2025-02-28"));
    }

    // ── Monthly on the 29th: leap-year edge
    #[test]
    fn monthly_29th_handles_leap_february() {
        let start = "2024-01-29T09:00:00+00:00";
        // 2024 is a leap year → Feb 29 exists, exact match.
        assert!(recurrence_matches(start, "monthly", "2024-02-29"));
        assert!(!recurrence_matches(start, "monthly", "2024-02-28"));
        // 2025 non-leap → Feb has 28 days → clamp to Feb 28.
        assert!(recurrence_matches(start, "monthly", "2025-02-28"));
        // April has 30 days → 29th exists, exact match.
        assert!(recurrence_matches(start, "monthly", "2024-04-29"));
    }

    // ── Monthly: never matches a day before the start date
    #[test]
    fn monthly_does_not_match_before_start() {
        let start = "2024-06-15T09:00:00+00:00";
        assert!(!recurrence_matches(start, "monthly", "2024-05-15"));
        assert!(recurrence_matches(start, "monthly", "2024-06-15"));
        assert!(recurrence_matches(start, "monthly", "2024-07-15"));
    }

    // ── Year boundary: weekly recurring Dec 28 → into January
    #[test]
    fn weekly_crosses_year_boundary() {
        // 2024-12-28 was a Saturday.
        let start = "2024-12-28T09:00:00+00:00";
        assert!(recurrence_matches(start, "weekly", "2024-12-28"));
        assert!(recurrence_matches(start, "weekly", "2025-01-04"));
        assert!(recurrence_matches(start, "weekly", "2025-01-11"));
        // A Sunday/Friday in between is not a Saturday → no match.
        assert!(!recurrence_matches(start, "weekly", "2025-01-03"));
        assert!(!recurrence_matches(start, "weekly", "2025-01-05"));
    }

    // ── Daily across year boundary
    #[test]
    fn daily_crosses_year_boundary() {
        let start = "2024-12-30T09:00:00+00:00";
        assert!(recurrence_matches(start, "daily", "2024-12-31"));
        assert!(recurrence_matches(start, "daily", "2025-01-01"));
        assert!(recurrence_matches(start, "daily", "2025-01-02"));
    }

    // ── Custom: MO,WE,FR
    #[test]
    fn custom_mwf_matches_three_weekdays() {
        // Use a known week. 2024-06-03 = Monday, 2024-06-04 = Tuesday, …
        let start = "2024-06-03T09:00:00+00:00";
        assert!(recurrence_matches(start, "custom:MO,WE,FR", "2024-06-03")); // Mon
        assert!(!recurrence_matches(start, "custom:MO,WE,FR", "2024-06-04")); // Tue
        assert!(recurrence_matches(start, "custom:MO,WE,FR", "2024-06-05")); // Wed
        assert!(!recurrence_matches(start, "custom:MO,WE,FR", "2024-06-06")); // Thu
        assert!(recurrence_matches(start, "custom:MO,WE,FR", "2024-06-07")); // Fri
        assert!(!recurrence_matches(start, "custom:MO,WE,FR", "2024-06-08")); // Sat
        assert!(!recurrence_matches(start, "custom:MO,WE,FR", "2024-06-09")); // Sun
    }

    // ── Custom: tolerates whitespace around tokens
    #[test]
    fn custom_tolerates_whitespace() {
        let start = "2024-06-03T09:00:00+00:00";
        assert!(recurrence_matches(
            start,
            "custom:MO, WE , FR",
            "2024-06-05"
        ));
    }

    // ── Biweekly: skips alternate weeks, no drift over months
    #[test]
    fn biweekly_skips_alternate_weeks() {
        // 2024-01-01 = Monday.
        let start = "2024-01-01T09:00:00+00:00";
        assert!(recurrence_matches(start, "biweekly", "2024-01-01")); // wk 0
        assert!(!recurrence_matches(start, "biweekly", "2024-01-08")); // wk 1
        assert!(recurrence_matches(start, "biweekly", "2024-01-15")); // wk 2
        assert!(!recurrence_matches(start, "biweekly", "2024-01-22")); // wk 3
        assert!(recurrence_matches(start, "biweekly", "2024-01-29")); // wk 4
    }

    #[test]
    fn biweekly_no_drift_over_six_months() {
        // 2024-01-01 = Monday. 26 weeks later = 2024-07-01 (also a Monday, even week).
        let start = "2024-01-01T09:00:00+00:00";
        assert!(recurrence_matches(start, "biweekly", "2024-07-01")); // wk 26
        assert!(!recurrence_matches(start, "biweekly", "2024-07-08")); // wk 27
        assert!(recurrence_matches(start, "biweekly", "2024-07-15")); // wk 28
                                                                      // Wrong weekday should never match even if "week parity" is right.
        assert!(!recurrence_matches(start, "biweekly", "2024-07-02"));
    }

    // ── Weekdays: only Mon-Fri
    #[test]
    fn weekdays_only_match_mon_fri() {
        let start = "2024-06-03T09:00:00+00:00"; // Monday
        assert!(recurrence_matches(start, "weekdays", "2024-06-03"));
        assert!(recurrence_matches(start, "weekdays", "2024-06-07"));
        assert!(!recurrence_matches(start, "weekdays", "2024-06-08")); // Sat
        assert!(!recurrence_matches(start, "weekdays", "2024-06-09")); // Sun
    }

    // ── Skip exception: only the skipped date is suppressed
    #[test]
    fn skip_exception_only_affects_one_date() {
        let cal = tmp_cal();
        // Use today's date so we can call cal.today() to verify skipping.
        let today = chrono::Local::now().format("%Y-%m-%dT07:00:00").to_string();
        let ev = cal
            .add_recurring_event("Daily yoga", &today, "daily", "", None, None)
            .unwrap();

        // Verify the matcher itself agrees both dates would normally match.
        let today_str = chrono::Local::now().format("%Y-%m-%d").to_string();
        let tomorrow_str = (chrono::Local::now() + chrono::Duration::days(1))
            .format("%Y-%m-%d")
            .to_string();
        assert!(recurrence_matches(&ev.start_time, "daily", &today_str));
        assert!(recurrence_matches(&ev.start_time, "daily", &tomorrow_str));

        // Skip TODAY only.
        cal.skip_occurrence(&ev.id, &today_str).unwrap();

        // today() must NOT include the skipped event.
        let today_events = cal.today().unwrap();
        assert!(!today_events.iter().any(|e| e.title == "Daily yoga"));

        // upcoming() should still include it for future days, because the
        // exception was only applied to today's date. We check via the
        // recurring helper directly to avoid coupling to upcoming()'s shape.
        let db = cal.db.lock().unwrap();
        let tomorrow_recurring =
            CalendarManager::recurring_events_for_date(&db, &tomorrow_str).unwrap();
        assert!(tomorrow_recurring.iter().any(|e| e.title == "Daily yoga"));
    }

    #[test]
    fn test_no_duplicate_reminder() {
        let cal = tmp_cal();
        // Create an event that is due for reminder right now
        let soon = (chrono::Local::now() + chrono::Duration::minutes(5))
            .format("%Y-%m-%dT%H:%M:%S")
            .to_string();
        let ev = cal
            .add_event("No dup", &soon, None, "", Some(10), None, None)
            .unwrap();

        // Before recording, it should show up in due_reminders
        let due_before = cal.due_reminders().unwrap();
        let found_before = due_before.iter().any(|e| e.title == "No dup");
        // It should be due (start in 5 min, reminder_minutes=10 → reminder window active)
        assert!(found_before, "Event should be due for reminder");

        // Record that we already sent the reminder
        cal.record_reminder(&ev.id, "No dup", "telegram").unwrap();

        // Now it should NOT show up in due_reminders (sent within last 60 min)
        let due_after = cal.due_reminders().unwrap();
        let found_after = due_after.iter().any(|e| e.title == "No dup");
        assert!(
            !found_after,
            "Event should be suppressed after reminder sent"
        );
    }
}
