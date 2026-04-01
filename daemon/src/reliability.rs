//! Reliability tracking module (Fase W — 95% success rate target).
//!
//! Persists task outcomes in a SQLite database, computes success rates,
//! failure patterns, MTBF, and trend analysis.  Provides recovery suggestions
//! for common error categories.

use chrono::{DateTime, Utc};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/// Record of a single task execution outcome.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskOutcome {
    pub task_id: String,
    pub task_type: String,
    /// Origin channel: "telegram", "scheduled", "autonomous", "api".
    pub source: String,
    pub started_at: DateTime<Utc>,
    pub completed_at: DateTime<Utc>,
    pub success: bool,
    pub error: Option<String>,
    pub retries: u32,
    /// If the task failed, did the rollback succeed?
    pub rollback_clean: bool,
    pub steps_total: u32,
    pub steps_completed: u32,
}

/// A cluster of similar failures.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FailurePattern {
    pub error_signature: String,
    pub count: u32,
    pub last_seen: DateTime<Utc>,
    pub suggested_fix: Option<String>,
}

/// Comprehensive reliability report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReliabilityReport {
    pub total_tasks: u32,
    pub successful: u32,
    pub failed: u32,
    pub success_rate: f64,
    pub mtbf_hours: f64,
    pub top_failures: Vec<FailurePattern>,
    /// "improving", "stable", or "degrading".
    pub trend: String,
    /// True when `success_rate >= 0.95`.
    pub meets_target: bool,
}

// ---------------------------------------------------------------------------
// ReliabilityTracker
// ---------------------------------------------------------------------------

pub struct ReliabilityTracker {
    db: Mutex<Connection>,
    #[allow(dead_code)]
    db_path: PathBuf,
}

impl ReliabilityTracker {
    /// Open (or create) the reliability database at `db_path`.
    pub fn new(db_path: PathBuf) -> Result<Self, String> {
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("Cannot create dir for reliability DB: {e}"))?;
        }

        let conn =
            Connection::open(&db_path).map_err(|e| format!("Cannot open reliability DB: {e}"))?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS task_outcomes (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id          TEXT NOT NULL,
                task_type        TEXT NOT NULL,
                source           TEXT NOT NULL,
                started_at       TEXT NOT NULL,
                completed_at     TEXT NOT NULL,
                success          INTEGER NOT NULL,
                error            TEXT,
                retries          INTEGER NOT NULL DEFAULT 0,
                rollback_clean   INTEGER NOT NULL DEFAULT 1,
                steps_total      INTEGER NOT NULL DEFAULT 0,
                steps_completed  INTEGER NOT NULL DEFAULT 0
            );

            CREATE INDEX IF NOT EXISTS idx_outcomes_completed
                ON task_outcomes(completed_at);
            CREATE INDEX IF NOT EXISTS idx_outcomes_success
                ON task_outcomes(success);",
        )
        .map_err(|e| format!("Failed to initialise reliability tables: {e}"))?;

        // Forward-compatible migrations for OS upgrades.
        Self::run_migrations(&conn)
            .map_err(|e| format!("Failed to run reliability migrations: {e}"))?;

        Ok(Self {
            db: Mutex::new(conn),
            db_path,
        })
    }

    /// Apply forward-compatible schema migrations for OS upgrades.
    fn run_migrations(db: &Connection) -> Result<(), String> {
        let has_column = |table: &str, col: &str| -> bool {
            db.prepare(&format!(
                "SELECT 1 FROM pragma_table_info('{}') WHERE name = ?1",
                table
            ))
            .and_then(|mut stmt| stmt.exists(params![col]))
            .unwrap_or(false)
        };

        // Migration: add `duration_ms` column for performance tracking.
        if !has_column("task_outcomes", "duration_ms") {
            db.execute_batch("ALTER TABLE task_outcomes ADD COLUMN duration_ms INTEGER;")
                .map_err(|e| format!("migration duration_ms: {e}"))?;
        }
        // Migration: add `category` column for failure categorization.
        if !has_column("task_outcomes", "category") {
            db.execute_batch("ALTER TABLE task_outcomes ADD COLUMN category TEXT;")
                .map_err(|e| format!("migration category: {e}"))?;
        }

        Ok(())
    }

    /// Persist a task outcome.
    pub fn record_outcome(&self, outcome: &TaskOutcome) -> Result<(), String> {
        let conn = self.db.lock().map_err(|e| format!("DB lock: {e}"))?;
        conn.execute(
            "INSERT INTO task_outcomes
                (task_id, task_type, source, started_at, completed_at,
                 success, error, retries, rollback_clean, steps_total, steps_completed)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            params![
                outcome.task_id,
                outcome.task_type,
                outcome.source,
                outcome.started_at.to_rfc3339(),
                outcome.completed_at.to_rfc3339(),
                outcome.success as i32,
                outcome.error,
                outcome.retries,
                outcome.rollback_clean as i32,
                outcome.steps_total,
                outcome.steps_completed,
            ],
        )
        .map_err(|e| format!("Failed to record outcome: {e}"))?;
        Ok(())
    }

    /// Return the most recent `limit` task outcomes, newest first.
    pub fn recent_outcomes(&self, limit: u32) -> Result<Vec<TaskOutcome>, String> {
        let conn = self.db.lock().map_err(|e| format!("DB lock: {e}"))?;
        let mut stmt = conn
            .prepare(
                "SELECT task_id, task_type, source, started_at, completed_at,
                        success, error, retries, rollback_clean, steps_total, steps_completed
                 FROM task_outcomes
                 ORDER BY id DESC
                 LIMIT ?1",
            )
            .map_err(|e| format!("Prepare error: {e}"))?;

        let rows = stmt
            .query_map(params![limit], |row| {
                let started_str: String = row.get(3)?;
                let completed_str: String = row.get(4)?;
                let success_int: i32 = row.get(5)?;
                let rollback_int: i32 = row.get(8)?;
                Ok(TaskOutcome {
                    task_id: row.get(0)?,
                    task_type: row.get(1)?,
                    source: row.get(2)?,
                    started_at: DateTime::parse_from_rfc3339(&started_str)
                        .map(|dt| dt.with_timezone(&Utc))
                        .unwrap_or_else(|_| Utc::now()),
                    completed_at: DateTime::parse_from_rfc3339(&completed_str)
                        .map(|dt| dt.with_timezone(&Utc))
                        .unwrap_or_else(|_| Utc::now()),
                    success: success_int != 0,
                    error: row.get(6)?,
                    retries: row.get(7)?,
                    rollback_clean: rollback_int != 0,
                    steps_total: row.get(9)?,
                    steps_completed: row.get(10)?,
                })
            })
            .map_err(|e| format!("Query error: {e}"))?;

        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("Row error: {e}"))
    }

    /// Success percentage of the last `n` tasks (0.0..=1.0).
    pub fn success_rate_last_n(&self, n: u32) -> Result<f64, String> {
        let conn = self.db.lock().map_err(|e| format!("DB lock: {e}"))?;
        let (total, ok): (u32, u32) = conn
            .query_row(
                "SELECT COUNT(*), COALESCE(SUM(success), 0)
                 FROM (SELECT success FROM task_outcomes ORDER BY id DESC LIMIT ?1)",
                params![n],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|e| format!("Query error: {e}"))?;
        if total == 0 {
            return Ok(1.0);
        }
        Ok(ok as f64 / total as f64)
    }

    /// Success percentage of tasks completed in the last `hours` hours.
    pub fn success_rate_period(&self, hours: u64) -> Result<f64, String> {
        let conn = self.db.lock().map_err(|e| format!("DB lock: {e}"))?;
        let cutoff = Utc::now() - chrono::Duration::hours(hours as i64);
        let (total, ok): (u32, u32) = conn
            .query_row(
                "SELECT COUNT(*), COALESCE(SUM(success), 0)
                 FROM task_outcomes
                 WHERE completed_at >= ?1",
                params![cutoff.to_rfc3339()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|e| format!("Query error: {e}"))?;
        if total == 0 {
            return Ok(1.0);
        }
        Ok(ok as f64 / total as f64)
    }

    /// Group failures by normalised error signature and count occurrences.
    pub fn failure_patterns(&self) -> Result<Vec<FailurePattern>, String> {
        let conn = self.db.lock().map_err(|e| format!("DB lock: {e}"))?;
        let mut stmt = conn
            .prepare(
                "SELECT error, COUNT(*) as cnt, MAX(completed_at) as last_seen
                 FROM task_outcomes
                 WHERE success = 0 AND error IS NOT NULL
                 GROUP BY error
                 ORDER BY cnt DESC
                 LIMIT 20",
            )
            .map_err(|e| format!("Prepare error: {e}"))?;

        let rows = stmt
            .query_map([], |row| {
                let raw_error: String = row.get(0)?;
                let count: u32 = row.get(1)?;
                let last_seen_str: String = row.get(2)?;
                Ok((raw_error, count, last_seen_str))
            })
            .map_err(|e| format!("Query error: {e}"))?;

        let mut patterns = Vec::new();
        for row in rows {
            let (raw_error, count, last_seen_str) = row.map_err(|e| format!("Row error: {e}"))?;
            let sig = normalise_error(&raw_error);
            let last_seen = DateTime::parse_from_rfc3339(&last_seen_str)
                .map(|dt| dt.with_timezone(&Utc))
                .unwrap_or_else(|_| Utc::now());
            let suggested_fix = suggest_recovery(&raw_error);
            patterns.push(FailurePattern {
                error_signature: sig,
                count,
                last_seen,
                suggested_fix,
            });
        }
        Ok(patterns)
    }

    /// Average hours between consecutive failures. Returns 0.0 if fewer than 2 failures.
    pub fn mean_time_between_failures(&self) -> Result<f64, String> {
        let conn = self.db.lock().map_err(|e| format!("DB lock: {e}"))?;
        let mut stmt = conn
            .prepare(
                "SELECT completed_at FROM task_outcomes
                 WHERE success = 0
                 ORDER BY completed_at ASC",
            )
            .map_err(|e| format!("Prepare error: {e}"))?;

        let timestamps: Vec<DateTime<Utc>> = stmt
            .query_map([], |row| {
                let s: String = row.get(0)?;
                Ok(s)
            })
            .map_err(|e| format!("Query error: {e}"))?
            .filter_map(|r| r.ok())
            .filter_map(|s| {
                DateTime::parse_from_rfc3339(&s)
                    .ok()
                    .map(|dt| dt.with_timezone(&Utc))
            })
            .collect();

        if timestamps.len() < 2 {
            return Ok(0.0);
        }

        let total_hours: f64 = timestamps
            .windows(2)
            .map(|w| (w[1] - w[0]).num_seconds().max(0) as f64 / 3600.0)
            .sum();

        Ok(total_hours / (timestamps.len() - 1) as f64)
    }

    /// Build a comprehensive reliability report.
    pub fn get_reliability_report(&self) -> Result<ReliabilityReport, String> {
        let conn = self.db.lock().map_err(|e| format!("DB lock: {e}"))?;

        // Totals
        let (total, ok): (u32, u32) = conn
            .query_row(
                "SELECT COUNT(*), COALESCE(SUM(success), 0) FROM task_outcomes",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|e| format!("Query error: {e}"))?;
        let failed = total.saturating_sub(ok);
        let success_rate = if total > 0 {
            ok as f64 / total as f64
        } else {
            1.0
        };

        // Trend — fetch all outcomes ordered by time
        let mut stmt = conn
            .prepare("SELECT success FROM task_outcomes ORDER BY completed_at ASC")
            .map_err(|e| format!("Prepare error: {e}"))?;
        let outcomes: Vec<bool> = stmt
            .query_map([], |row| {
                let v: i32 = row.get(0)?;
                Ok(v != 0)
            })
            .map_err(|e| format!("Query error: {e}"))?
            .filter_map(|r| r.ok())
            .collect();

        let trend = calculate_trend_from_bools(&outcomes);

        // Drop the connection lock before calling methods that re-acquire it
        drop(stmt);
        drop(conn);

        let top_failures = self.failure_patterns()?;
        let mtbf_hours = self.mean_time_between_failures()?;

        Ok(ReliabilityReport {
            total_tasks: total,
            successful: ok,
            failed,
            success_rate,
            mtbf_hours,
            top_failures,
            trend,
            meets_target: success_rate >= 0.95,
        })
    }
}

// ---------------------------------------------------------------------------
// Recovery suggestions
// ---------------------------------------------------------------------------

/// Suggest a recovery action based on known error patterns.
pub fn suggest_recovery(error: &str) -> Option<String> {
    let lower = error.to_lowercase();

    if lower.contains("connection refused") {
        Some("Check if the target service is running".into())
    } else if lower.contains("permission denied") {
        Some("Check file permissions or run with appropriate privileges".into())
    } else if lower.contains("out of memory") || lower.contains("oom") {
        Some("Free memory by stopping unused services or reducing LLM context".into())
    } else if lower.contains("timeout") || lower.contains("timed out") {
        Some("Increase timeout or check network connectivity".into())
    } else if lower.contains("compile error") || lower.contains("build failed") {
        Some("Review the error output and fix the code".into())
    } else if lower.contains("git conflict") || lower.contains("merge conflict") {
        Some("Resolve merge conflicts before retrying".into())
    } else if lower.contains("llm") || lower.contains("provider") || lower.contains("api key") {
        Some("Check API keys and provider availability".into())
    } else if lower.contains("disk") || lower.contains("no space") {
        Some("Free disk space or clean up old artifacts".into())
    } else if lower.contains("dns") || lower.contains("resolve") {
        Some("Check DNS configuration and network connectivity".into())
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Trend analysis
// ---------------------------------------------------------------------------

/// Compare success rates of the first and second halves of the outcome list.
/// Returns "improving", "degrading", or "stable".
pub fn calculate_trend(outcomes: &[TaskOutcome]) -> String {
    let bools: Vec<bool> = outcomes.iter().map(|o| o.success).collect();
    calculate_trend_from_bools(&bools)
}

fn calculate_trend_from_bools(outcomes: &[bool]) -> String {
    if outcomes.len() < 4 {
        return "stable".into();
    }
    let mid = outcomes.len() / 2;
    let (first, second) = outcomes.split_at(mid);

    let rate = |slice: &[bool]| -> f64 {
        if slice.is_empty() {
            return 1.0;
        }
        slice.iter().filter(|&&s| s).count() as f64 / slice.len() as f64
    };

    let r1 = rate(first);
    let r2 = rate(second);

    if r2 - r1 > 0.05 {
        "improving".into()
    } else if r1 - r2 > 0.05 {
        "degrading".into()
    } else {
        "stable".into()
    }
}

// ---------------------------------------------------------------------------
// JSON serialisation for dashboard / API
// ---------------------------------------------------------------------------

/// Format a `ReliabilityReport` as JSON for the dashboard.
pub fn reliability_to_json(report: &ReliabilityReport) -> serde_json::Value {
    serde_json::json!({
        "total_tasks": report.total_tasks,
        "successful": report.successful,
        "failed": report.failed,
        "success_rate": format!("{:.1}%", report.success_rate * 100.0),
        "success_rate_raw": report.success_rate,
        "mtbf_hours": format!("{:.1}", report.mtbf_hours),
        "trend": report.trend,
        "meets_target": report.meets_target,
        "target": "95%",
        "top_failures": report.top_failures.iter().map(|f| {
            serde_json::json!({
                "error_signature": f.error_signature,
                "count": f.count,
                "last_seen": f.last_seen.to_rfc3339(),
                "suggested_fix": f.suggested_fix,
            })
        }).collect::<Vec<_>>(),
    })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Normalise an error string into a short signature for grouping.
fn normalise_error(error: &str) -> String {
    let lower = error.to_lowercase();
    if lower.contains("connection refused") {
        "connection_refused".into()
    } else if lower.contains("permission denied") {
        "permission_denied".into()
    } else if lower.contains("out of memory") || lower.contains("oom") {
        "out_of_memory".into()
    } else if lower.contains("timeout") || lower.contains("timed out") {
        "timeout".into()
    } else if lower.contains("compile error") || lower.contains("build failed") {
        "build_failure".into()
    } else if lower.contains("git conflict") || lower.contains("merge conflict") {
        "git_conflict".into()
    } else if lower.contains("llm") || lower.contains("provider") {
        "llm_provider".into()
    } else if lower.contains("no space") || lower.contains("disk full") {
        "disk_full".into()
    } else {
        // Truncate to first 80 chars as a fallback signature
        let sig: String = lower.chars().take(80).collect();
        sig.trim().to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use std::path::PathBuf;

    fn tmp_db() -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("lifeos_reliability_test_{}", uuid::Uuid::new_v4()));
        dir.join("reliability.db")
    }

    fn make_outcome(success: bool, error: Option<&str>) -> TaskOutcome {
        TaskOutcome {
            task_id: uuid::Uuid::new_v4().to_string(),
            task_type: "test".into(),
            source: "api".into(),
            started_at: Utc::now(),
            completed_at: Utc::now(),
            success,
            error: error.map(|s| s.to_string()),
            retries: 0,
            rollback_clean: true,
            steps_total: 3,
            steps_completed: if success { 3 } else { 1 },
        }
    }

    #[test]
    fn test_record_and_success_rate() {
        let db = tmp_db();
        let tracker = ReliabilityTracker::new(db).unwrap();

        // Record 9 successes and 1 failure -> 90%
        for _ in 0..9 {
            tracker.record_outcome(&make_outcome(true, None)).unwrap();
        }
        tracker
            .record_outcome(&make_outcome(false, Some("timeout")))
            .unwrap();

        let rate = tracker.success_rate_last_n(10).unwrap();
        assert!((rate - 0.9).abs() < 0.01, "Expected ~90%, got {rate}");
    }

    #[test]
    fn test_empty_db_returns_full_success() {
        let db = tmp_db();
        let tracker = ReliabilityTracker::new(db).unwrap();
        let rate = tracker.success_rate_last_n(10).unwrap();
        assert!((rate - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_failure_patterns() {
        let db = tmp_db();
        let tracker = ReliabilityTracker::new(db).unwrap();

        tracker
            .record_outcome(&make_outcome(
                false,
                Some("connection refused to service X"),
            ))
            .unwrap();
        tracker
            .record_outcome(&make_outcome(
                false,
                Some("connection refused to service Y"),
            ))
            .unwrap();
        tracker
            .record_outcome(&make_outcome(false, Some("permission denied: /etc/shadow")))
            .unwrap();

        let patterns = tracker.failure_patterns().unwrap();
        assert!(!patterns.is_empty());
    }

    #[test]
    fn test_suggest_recovery() {
        assert!(suggest_recovery("connection refused").is_some());
        assert!(suggest_recovery("permission denied").is_some());
        assert!(suggest_recovery("out of memory").is_some());
        assert!(suggest_recovery("timeout reached").is_some());
        assert!(suggest_recovery("compile error in main.rs").is_some());
        assert!(suggest_recovery("git conflict detected").is_some());
        assert!(suggest_recovery("LLM returned empty").is_some());
        assert!(suggest_recovery("something unknown xyz 42").is_none());
    }

    #[test]
    fn test_calculate_trend() {
        // All success -> stable
        let all_ok: Vec<TaskOutcome> = (0..10).map(|_| make_outcome(true, None)).collect();
        assert_eq!(calculate_trend(&all_ok), "stable");

        // First half bad, second half good -> improving
        let mut improving: Vec<TaskOutcome> = Vec::new();
        for _ in 0..5 {
            improving.push(make_outcome(false, Some("err")));
        }
        for _ in 0..5 {
            improving.push(make_outcome(true, None));
        }
        assert_eq!(calculate_trend(&improving), "improving");

        // First half good, second half bad -> degrading
        let mut degrading: Vec<TaskOutcome> = Vec::new();
        for _ in 0..5 {
            degrading.push(make_outcome(true, None));
        }
        for _ in 0..5 {
            degrading.push(make_outcome(false, Some("err")));
        }
        assert_eq!(calculate_trend(&degrading), "degrading");
    }

    #[test]
    fn test_reliability_report() {
        let db = tmp_db();
        let tracker = ReliabilityTracker::new(db).unwrap();

        for _ in 0..19 {
            tracker.record_outcome(&make_outcome(true, None)).unwrap();
        }
        tracker
            .record_outcome(&make_outcome(false, Some("timeout")))
            .unwrap();

        let report = tracker.get_reliability_report().unwrap();
        assert_eq!(report.total_tasks, 20);
        assert_eq!(report.successful, 19);
        assert_eq!(report.failed, 1);
        assert!(report.success_rate >= 0.95);
        assert!(report.meets_target);
    }

    #[test]
    fn test_reliability_to_json() {
        let report = ReliabilityReport {
            total_tasks: 100,
            successful: 96,
            failed: 4,
            success_rate: 0.96,
            mtbf_hours: 24.5,
            top_failures: vec![],
            trend: "stable".into(),
            meets_target: true,
        };
        let json = reliability_to_json(&report);
        assert_eq!(json["meets_target"], true);
        assert_eq!(json["trend"], "stable");
        assert_eq!(json["target"], "95%");
    }
}
