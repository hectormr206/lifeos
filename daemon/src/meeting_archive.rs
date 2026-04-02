//! Meeting Archive — structured SQLite storage for meeting records.
//!
//! Persists meeting data (transcripts, summaries, action items, screenshots)
//! in a local SQLite database for retrieval, search, and analytics.
//!
//! Wired to: telegram_tools.rs (tools #80-83), meeting_assistant.rs (auto-save),
//! dashboard (API endpoints), main.rs (initialization).

use anyhow::{Context, Result};
use log::{info, warn};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS meetings (
    id TEXT PRIMARY KEY,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    duration_secs INTEGER DEFAULT 0,
    app_name TEXT DEFAULT '',
    meeting_type TEXT DEFAULT 'remote',
    participants TEXT DEFAULT '[]',
    transcript TEXT DEFAULT '',
    diarized_transcript TEXT DEFAULT '',
    summary TEXT DEFAULT '',
    action_items TEXT DEFAULT '[]',
    screenshot_count INTEGER DEFAULT 0,
    screenshot_paths TEXT DEFAULT '[]',
    audio_path TEXT,
    audio_deleted INTEGER DEFAULT 0,
    tags TEXT DEFAULT '[]',
    language TEXT DEFAULT 'es',
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_meetings_started_at ON meetings(started_at);
CREATE INDEX IF NOT EXISTS idx_meetings_meeting_type ON meetings(meeting_type);
"#;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MeetingRecord {
    pub id: String,
    pub started_at: String,
    pub ended_at: Option<String>,
    pub duration_secs: u64,
    pub app_name: String,
    pub meeting_type: String,
    pub participants: Vec<String>,
    pub transcript: String,
    pub diarized_transcript: String,
    pub summary: String,
    pub action_items: Vec<ActionItem>,
    pub screenshot_count: usize,
    pub screenshot_paths: Vec<String>,
    pub audio_path: Option<String>,
    pub audio_deleted: bool,
    pub tags: Vec<String>,
    pub language: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionItem {
    pub who: String,
    pub what: String,
    pub when: Option<String>,
    pub completed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MeetingStats {
    pub total_meetings: usize,
    pub total_hours: f64,
    pub avg_duration_mins: f64,
    pub meetings_this_week: usize,
    pub meetings_this_month: usize,
}

pub struct MeetingArchive {
    db_path: PathBuf,
}

impl MeetingArchive {
    pub fn new(data_dir: &Path) -> Self {
        let db_path = data_dir.join("meeting_archive.db");
        if let Err(e) = Self::init_db(&db_path) {
            warn!("Failed to initialize meeting archive DB: {e}");
        }
        Self { db_path }
    }

    fn init_db(db_path: &Path) -> Result<()> {
        let db = Connection::open(db_path).context("Failed to open meeting archive database")?;
        db.execute_batch(SCHEMA)
            .context("Failed to initialize meeting archive schema")?;
        info!("Meeting archive DB initialized at {}", db_path.display());
        Ok(())
    }

    fn open_db(db_path: &Path) -> Result<Connection> {
        let db = Connection::open(db_path).context("Failed to open meeting archive database")?;
        Ok(db)
    }

    pub async fn save_meeting(&self, meeting: &MeetingRecord) -> Result<()> {
        let db_path = self.db_path.clone();
        let meeting = meeting.clone();
        let now = chrono::Utc::now().to_rfc3339();

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute(
                "INSERT OR REPLACE INTO meetings
                 (id, started_at, ended_at, duration_secs, app_name, meeting_type,
                  participants, transcript, diarized_transcript, summary, action_items,
                  screenshot_count, screenshot_paths, audio_path, audio_deleted, tags,
                  language, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)",
                params![
                    meeting.id,
                    meeting.started_at,
                    meeting.ended_at,
                    meeting.duration_secs as i64,
                    meeting.app_name,
                    meeting.meeting_type,
                    serde_json::to_string(&meeting.participants)?,
                    meeting.transcript,
                    meeting.diarized_transcript,
                    meeting.summary,
                    serde_json::to_string(&meeting.action_items)?,
                    meeting.screenshot_count as i64,
                    serde_json::to_string(&meeting.screenshot_paths)?,
                    meeting.audio_path,
                    meeting.audio_deleted as i32,
                    serde_json::to_string(&meeting.tags)?,
                    meeting.language,
                    now,
                ],
            )?;
            Ok(())
        })
        .await
        .context("spawn_blocking join error")?
    }

    pub async fn get_meeting(&self, id: &str) -> Result<Option<MeetingRecord>> {
        let db_path = self.db_path.clone();
        let id = id.to_string();

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut stmt = db.prepare(
                "SELECT id, started_at, ended_at, duration_secs, app_name, meeting_type,
                        participants, transcript, diarized_transcript, summary, action_items,
                        screenshot_count, screenshot_paths, audio_path, audio_deleted, tags,
                        language
                 FROM meetings WHERE id = ?1",
            )?;

            let mut rows = stmt.query(params![id])?;
            match rows.next()? {
                Some(row) => Ok(Some(Self::row_to_meeting(row)?)),
                None => Ok(None),
            }
        })
        .await
        .context("spawn_blocking join error")?
    }

    pub async fn list_meetings(&self, limit: usize, offset: usize) -> Result<Vec<MeetingRecord>> {
        let db_path = self.db_path.clone();

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut stmt = db.prepare(
                "SELECT id, started_at, ended_at, duration_secs, app_name, meeting_type,
                        participants, transcript, diarized_transcript, summary, action_items,
                        screenshot_count, screenshot_paths, audio_path, audio_deleted, tags,
                        language
                 FROM meetings ORDER BY started_at DESC LIMIT ?1 OFFSET ?2",
            )?;

            let rows = stmt.query_map(params![limit as i64, offset as i64], |row| {
                Ok(Self::row_to_meeting(row))
            })?;

            let mut meetings = Vec::new();
            for row in rows {
                meetings.push(row?.context("Failed to parse meeting row")?);
            }
            Ok(meetings)
        })
        .await
        .context("spawn_blocking join error")?
    }

    pub async fn search_meetings(&self, query: &str, limit: usize) -> Result<Vec<MeetingRecord>> {
        let db_path = self.db_path.clone();
        let pattern = format!("%{query}%");

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut stmt = db.prepare(
                "SELECT id, started_at, ended_at, duration_secs, app_name, meeting_type,
                        participants, transcript, diarized_transcript, summary, action_items,
                        screenshot_count, screenshot_paths, audio_path, audio_deleted, tags,
                        language
                 FROM meetings
                 WHERE transcript LIKE ?1 OR summary LIKE ?1
                 ORDER BY started_at DESC LIMIT ?2",
            )?;

            let rows = stmt.query_map(params![pattern, limit as i64], |row| {
                Ok(Self::row_to_meeting(row))
            })?;

            let mut meetings = Vec::new();
            for row in rows {
                meetings.push(row?.context("Failed to parse meeting row")?);
            }
            Ok(meetings)
        })
        .await
        .context("spawn_blocking join error")?
    }

    pub async fn get_meetings_by_date(&self, date: &str) -> Result<Vec<MeetingRecord>> {
        let db_path = self.db_path.clone();
        let prefix = format!("{date}%");

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut stmt = db.prepare(
                "SELECT id, started_at, ended_at, duration_secs, app_name, meeting_type,
                        participants, transcript, diarized_transcript, summary, action_items,
                        screenshot_count, screenshot_paths, audio_path, audio_deleted, tags,
                        language
                 FROM meetings WHERE started_at LIKE ?1 ORDER BY started_at ASC",
            )?;

            let rows = stmt.query_map(params![prefix], |row| Ok(Self::row_to_meeting(row)))?;

            let mut meetings = Vec::new();
            for row in rows {
                meetings.push(row?.context("Failed to parse meeting row")?);
            }
            Ok(meetings)
        })
        .await
        .context("spawn_blocking join error")?
    }

    pub async fn get_action_items_pending(&self) -> Result<Vec<(String, ActionItem)>> {
        let db_path = self.db_path.clone();
        let cutoff = (chrono::Utc::now() - chrono::Duration::days(30)).to_rfc3339();

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            let mut stmt =
                db.prepare("SELECT id, action_items FROM meetings WHERE started_at >= ?1")?;

            let mut pending = Vec::new();
            let mut rows = stmt.query(params![cutoff])?;
            while let Some(row) = rows.next()? {
                let meeting_id: String = row.get(0)?;
                let items_json: String = row.get(1)?;
                let items: Vec<ActionItem> = serde_json::from_str(&items_json).unwrap_or_default();
                for item in items {
                    if !item.completed {
                        pending.push((meeting_id.clone(), item));
                    }
                }
            }
            Ok(pending)
        })
        .await
        .context("spawn_blocking join error")?
    }

    pub async fn stats(&self) -> Result<MeetingStats> {
        let db_path = self.db_path.clone();

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;

            let total_meetings: usize =
                db.query_row("SELECT COUNT(*) FROM meetings", [], |row| row.get(0))?;

            let total_secs: i64 = db.query_row(
                "SELECT COALESCE(SUM(duration_secs), 0) FROM meetings",
                [],
                |row| row.get(0),
            )?;
            let total_hours = total_secs as f64 / 3600.0;

            let avg_duration_mins = if total_meetings > 0 {
                (total_secs as f64 / total_meetings as f64) / 60.0
            } else {
                0.0
            };

            let week_ago = (chrono::Utc::now() - chrono::Duration::days(7)).to_rfc3339();
            let meetings_this_week: usize = db.query_row(
                "SELECT COUNT(*) FROM meetings WHERE started_at >= ?1",
                params![week_ago],
                |row| row.get(0),
            )?;

            let month_ago = (chrono::Utc::now() - chrono::Duration::days(30)).to_rfc3339();
            let meetings_this_month: usize = db.query_row(
                "SELECT COUNT(*) FROM meetings WHERE started_at >= ?1",
                params![month_ago],
                |row| row.get(0),
            )?;

            Ok(MeetingStats {
                total_meetings,
                total_hours,
                avg_duration_mins,
                meetings_this_week,
                meetings_this_month,
            })
        })
        .await
        .context("spawn_blocking join error")?
    }

    pub async fn delete_meeting(&self, id: &str) -> Result<()> {
        let db_path = self.db_path.clone();
        let id = id.to_string();

        tokio::task::spawn_blocking(move || {
            let db = Self::open_db(&db_path)?;
            db.execute("DELETE FROM meetings WHERE id = ?1", params![id])?;
            Ok(())
        })
        .await
        .context("spawn_blocking join error")?
    }

    fn row_to_meeting(row: &rusqlite::Row) -> Result<MeetingRecord> {
        let participants_json: String = row.get(6)?;
        let action_items_json: String = row.get(10)?;
        let screenshot_paths_json: String = row.get(12)?;
        let tags_json: String = row.get(15)?;
        let audio_deleted_int: i32 = row.get(14)?;

        Ok(MeetingRecord {
            id: row.get(0)?,
            started_at: row.get(1)?,
            ended_at: row.get(2)?,
            duration_secs: row.get::<_, i64>(3)? as u64,
            app_name: row.get(4)?,
            meeting_type: row.get(5)?,
            participants: serde_json::from_str(&participants_json).unwrap_or_default(),
            transcript: row.get(7)?,
            diarized_transcript: row.get(8)?,
            summary: row.get(9)?,
            action_items: serde_json::from_str(&action_items_json).unwrap_or_default(),
            screenshot_count: row.get::<_, i64>(11)? as usize,
            screenshot_paths: serde_json::from_str(&screenshot_paths_json).unwrap_or_default(),
            audio_path: row.get(13)?,
            audio_deleted: audio_deleted_int != 0,
            tags: serde_json::from_str(&tags_json).unwrap_or_default(),
            language: row.get(16)?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(prefix: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("{}-{}", prefix, uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn make_meeting(id: &str, transcript: &str, summary: &str) -> MeetingRecord {
        MeetingRecord {
            id: id.to_string(),
            started_at: "2026-03-15T10:00:00+00:00".to_string(),
            ended_at: Some("2026-03-15T11:00:00+00:00".to_string()),
            duration_secs: 3600,
            app_name: "Zoom".to_string(),
            meeting_type: "remote".to_string(),
            participants: vec!["Alice".to_string(), "Bob".to_string()],
            transcript: transcript.to_string(),
            diarized_transcript: String::new(),
            summary: summary.to_string(),
            action_items: vec![
                ActionItem {
                    who: "Alice".to_string(),
                    what: "Send report".to_string(),
                    when: Some("2026-03-16".to_string()),
                    completed: false,
                },
                ActionItem {
                    who: "Bob".to_string(),
                    what: "Review docs".to_string(),
                    when: None,
                    completed: true,
                },
            ],
            screenshot_count: 2,
            screenshot_paths: vec!["/tmp/s1.png".to_string(), "/tmp/s2.png".to_string()],
            audio_path: Some("/tmp/meeting.opus".to_string()),
            audio_deleted: false,
            tags: vec!["standup".to_string()],
            language: "es".to_string(),
        }
    }

    #[tokio::test]
    async fn test_save_and_retrieve_meeting() {
        let dir = temp_dir("meeting-archive-save");
        let archive = MeetingArchive::new(&dir);

        let meeting = make_meeting("m1", "Hello world", "Weekly sync");
        archive.save_meeting(&meeting).await.unwrap();

        let retrieved = archive.get_meeting("m1").await.unwrap().unwrap();
        assert_eq!(retrieved.id, "m1");
        assert_eq!(retrieved.started_at, meeting.started_at);
        assert_eq!(retrieved.ended_at, meeting.ended_at);
        assert_eq!(retrieved.duration_secs, 3600);
        assert_eq!(retrieved.app_name, "Zoom");
        assert_eq!(retrieved.meeting_type, "remote");
        assert_eq!(retrieved.participants, vec!["Alice", "Bob"]);
        assert_eq!(retrieved.transcript, "Hello world");
        assert_eq!(retrieved.summary, "Weekly sync");
        assert_eq!(retrieved.action_items.len(), 2);
        assert_eq!(retrieved.action_items[0].who, "Alice");
        assert!(!retrieved.action_items[0].completed);
        assert!(retrieved.action_items[1].completed);
        assert_eq!(retrieved.screenshot_count, 2);
        assert_eq!(retrieved.screenshot_paths.len(), 2);
        assert_eq!(retrieved.audio_path.as_deref(), Some("/tmp/meeting.opus"));
        assert!(!retrieved.audio_deleted);
        assert_eq!(retrieved.tags, vec!["standup"]);
        assert_eq!(retrieved.language, "es");

        // Non-existent meeting returns None
        assert!(archive.get_meeting("nonexistent").await.unwrap().is_none());

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_search_meetings() {
        let dir = temp_dir("meeting-archive-search");
        let archive = MeetingArchive::new(&dir);

        let m1 = make_meeting("s1", "Discussed Rust performance", "Rust perf review");
        let m2 = make_meeting("s2", "Budget planning for Q2", "Finance meeting");
        archive.save_meeting(&m1).await.unwrap();
        archive.save_meeting(&m2).await.unwrap();

        let results = archive.search_meetings("Rust", 10).await.unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].id, "s1");

        let results = archive.search_meetings("Budget", 10).await.unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].id, "s2");

        // Search in summary field
        let results = archive.search_meetings("Finance", 10).await.unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].id, "s2");

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_list_meetings_pagination() {
        let dir = temp_dir("meeting-archive-pagination");
        let archive = MeetingArchive::new(&dir);

        for i in 0..5 {
            let mut m = make_meeting(&format!("p{i}"), "content", "summary");
            m.started_at = format!("2026-03-{:02}T10:00:00+00:00", 10 + i);
            archive.save_meeting(&m).await.unwrap();
        }

        let page1 = archive.list_meetings(2, 0).await.unwrap();
        assert_eq!(page1.len(), 2);
        // DESC order: most recent first
        assert_eq!(page1[0].id, "p4");
        assert_eq!(page1[1].id, "p3");

        let page2 = archive.list_meetings(2, 2).await.unwrap();
        assert_eq!(page2.len(), 2);
        assert_eq!(page2[0].id, "p2");
        assert_eq!(page2[1].id, "p1");

        let page3 = archive.list_meetings(2, 4).await.unwrap();
        assert_eq!(page3.len(), 1);
        assert_eq!(page3[0].id, "p0");

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_action_items_pending() {
        let dir = temp_dir("meeting-archive-actions");
        let archive = MeetingArchive::new(&dir);

        let mut m = make_meeting("a1", "content", "summary");
        // Use a recent date so it falls within 30-day window
        m.started_at = chrono::Utc::now().to_rfc3339();
        archive.save_meeting(&m).await.unwrap();

        let pending = archive.get_action_items_pending().await.unwrap();
        // Only 1 pending (Alice's "Send report"); Bob's is completed
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].0, "a1");
        assert_eq!(pending[0].1.who, "Alice");
        assert_eq!(pending[0].1.what, "Send report");
        assert!(!pending[0].1.completed);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn test_meeting_stats() {
        let dir = temp_dir("meeting-archive-stats");
        let archive = MeetingArchive::new(&dir);

        let now = chrono::Utc::now();

        // Meeting 1: recent (today)
        let mut m1 = make_meeting("st1", "a", "b");
        m1.started_at = now.to_rfc3339();
        m1.duration_secs = 1800; // 30 min
        archive.save_meeting(&m1).await.unwrap();

        // Meeting 2: recent (yesterday)
        let mut m2 = make_meeting("st2", "c", "d");
        m2.started_at = (now - chrono::Duration::days(1)).to_rfc3339();
        m2.duration_secs = 3600; // 60 min
        archive.save_meeting(&m2).await.unwrap();

        // Meeting 3: old (60 days ago)
        let mut m3 = make_meeting("st3", "e", "f");
        m3.started_at = (now - chrono::Duration::days(60)).to_rfc3339();
        m3.duration_secs = 7200; // 120 min
        archive.save_meeting(&m3).await.unwrap();

        let stats = archive.stats().await.unwrap();
        assert_eq!(stats.total_meetings, 3);
        // Total: 1800 + 3600 + 7200 = 12600 secs = 3.5 hours
        assert!((stats.total_hours - 3.5).abs() < 0.01);
        // Avg: 12600/3 = 4200 secs = 70 min
        assert!((stats.avg_duration_mins - 70.0).abs() < 0.01);
        assert_eq!(stats.meetings_this_week, 2);
        assert_eq!(stats.meetings_this_month, 2);

        std::fs::remove_dir_all(dir).ok();
    }
}
