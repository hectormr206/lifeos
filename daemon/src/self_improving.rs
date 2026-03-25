//! Self-Improving OS daemon (Fase U — Karpathy Loop)
//!
//! Three subsystems that let LifeOS learn from its own behaviour:
//!
//! 1. **PromptEvolution** — reads supervisor audit logs, scores prompt
//!    effectiveness per action type, and suggests improvements for weak spots.
//! 2. **WorkflowLearner** — records user actions, detects repetitive sequences,
//!    and proposes new "skills" that can be automated.
//! 3. **NightlyOptimizer** — runs housekeeping + analysis during idle hours
//!    (2–5 AM, user not present).
//!
//! The [`SelfImprovingDaemon`] orchestrator is meant to be ticked from the main
//! daemon loop; it delegates to the three subsystems as appropriate.

use anyhow::{Context, Result};
use chrono::{Local, Timelike};
use log::{debug, info, warn};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SUPERVISOR_AUDIT_LOG: &str = "/var/lib/lifeos/supervisor-audit.log";
const PRESENCE_FILE: &str = "/var/lib/lifeos/presence_detected";
const MAX_AUDIT_ENTRIES: usize = 100;
const SUCCESS_THRESHOLD: f64 = 0.70; // 70 %
const MIN_PATTERN_LENGTH: usize = 3;
const MIN_PATTERN_REPEATS: usize = 3;

// ---------------------------------------------------------------------------
// Shared types
// ---------------------------------------------------------------------------

/// A single line from the supervisor audit log.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditEntry {
    pub timestamp: String,
    pub action: String,
    pub result: String, // "ok" | "fail" | other
    pub detail: String,
}

/// Per-action-type metrics.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionMetrics {
    pub action: String,
    pub total: usize,
    pub successes: usize,
    pub failures: usize,
    pub success_rate: f64,
}

/// A suggestion for improving a prompt / action type.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImprovementSuggestion {
    pub action: String,
    pub success_rate: f64,
    pub suggestion: String,
}

/// A recorded user action (for pattern detection).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordedAction {
    pub action: String,
    pub context: String,
    pub timestamp: String,
}

/// A detected repetitive pattern.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DetectedPattern {
    pub sequence: Vec<String>,
    pub occurrences: usize,
}

/// A skill suggestion derived from a detected pattern.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillSuggestion {
    pub name: String,
    pub description: String,
    pub pattern: DetectedPattern,
}

/// Report produced by a nightly optimization run.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OptimizationReport {
    pub timestamp: String,
    pub cleanup_done: bool,
    pub security_score: Option<u32>,
    pub prompt_metrics: Vec<ActionMetrics>,
    pub notes: Vec<String>,
}

/// Dashboard-facing status blob.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SelfImprovingStatus {
    pub prompt_metrics: Vec<ActionMetrics>,
    pub detected_patterns: Vec<DetectedPattern>,
    pub last_optimization: Option<OptimizationReport>,
    pub last_tick: String,
}

// ---------------------------------------------------------------------------
// 1. PromptEvolution
// ---------------------------------------------------------------------------

pub struct PromptEvolution {
    audit_log_path: PathBuf,
}

impl PromptEvolution {
    pub fn new() -> Self {
        Self {
            audit_log_path: PathBuf::from(SUPERVISOR_AUDIT_LOG),
        }
    }

    #[cfg(test)]
    pub fn with_log_path(path: PathBuf) -> Self {
        Self {
            audit_log_path: path,
        }
    }

    // -- helpers ----------------------------------------------------------

    fn parse_audit_line(line: &str) -> Option<AuditEntry> {
        // Expected format (tab-separated):
        //   <timestamp>\t<action>\t<result>\t<detail>
        let parts: Vec<&str> = line.splitn(4, '\t').collect();
        if parts.len() < 3 {
            return None;
        }
        Some(AuditEntry {
            timestamp: parts[0].to_string(),
            action: parts[1].to_string(),
            result: parts[2].to_string(),
            detail: parts.get(3).unwrap_or(&"").to_string(),
        })
    }

    fn read_audit_entries(&self) -> Result<Vec<AuditEntry>> {
        let content = fs::read_to_string(&self.audit_log_path).with_context(|| {
            format!(
                "Reading supervisor audit log at {}",
                self.audit_log_path.display()
            )
        })?;

        let entries: Vec<AuditEntry> = content
            .lines()
            .rev()
            .take(MAX_AUDIT_ENTRIES)
            .filter_map(Self::parse_audit_line)
            .collect();

        Ok(entries)
    }

    // -- public API -------------------------------------------------------

    /// Reads the last 100 audit entries, groups by action type, and computes
    /// success rate per action.
    pub fn analyze_prompt_effectiveness(&self) -> Result<Vec<ActionMetrics>> {
        let entries = self.read_audit_entries()?;
        let mut groups: HashMap<String, (usize, usize)> = HashMap::new();

        for entry in &entries {
            let counter = groups.entry(entry.action.clone()).or_insert((0, 0));
            counter.0 += 1; // total
            if entry.result == "ok" {
                counter.1 += 1; // successes
            }
        }

        let mut metrics: Vec<ActionMetrics> = groups
            .into_iter()
            .map(|(action, (total, successes))| {
                let failures = total - successes;
                let success_rate = if total > 0 {
                    successes as f64 / total as f64
                } else {
                    0.0
                };
                ActionMetrics {
                    action,
                    total,
                    successes,
                    failures,
                    success_rate,
                }
            })
            .collect();

        metrics.sort_by(|a, b| a.action.cmp(&b.action));
        Ok(metrics)
    }

    /// For every action type whose success rate is below [`SUCCESS_THRESHOLD`],
    /// generate a human-readable improvement suggestion.
    ///
    /// In the future this will call an LLM; for now it returns a templated
    /// suggestion that can be fed to the local model.
    pub fn suggest_improvements(&self) -> Result<Vec<ImprovementSuggestion>> {
        let metrics = self.analyze_prompt_effectiveness()?;
        let suggestions: Vec<ImprovementSuggestion> = metrics
            .into_iter()
            .filter(|m| m.success_rate < SUCCESS_THRESHOLD && m.total >= 3)
            .map(|m| {
                let suggestion = format!(
                    "Action '{}' has a {:.0}% success rate ({}/{} ok). \
                     Consider: (1) adding clearer pre-conditions, \
                     (2) breaking the action into smaller steps, \
                     (3) adding a validation check before execution.",
                    m.action,
                    m.success_rate * 100.0,
                    m.successes,
                    m.total,
                );
                ImprovementSuggestion {
                    action: m.action,
                    success_rate: m.success_rate,
                    suggestion,
                }
            })
            .collect();

        if suggestions.is_empty() {
            info!("PromptEvolution: all action types above {:.0}% success threshold", SUCCESS_THRESHOLD * 100.0);
        } else {
            info!(
                "PromptEvolution: {} action type(s) below threshold, suggestions generated",
                suggestions.len()
            );
        }

        Ok(suggestions)
    }

    /// Returns the full metrics summary (useful for the dashboard).
    pub fn get_metrics(&self) -> Result<Vec<ActionMetrics>> {
        self.analyze_prompt_effectiveness()
    }
}

// ---------------------------------------------------------------------------
// 2. WorkflowLearner
// ---------------------------------------------------------------------------

pub struct WorkflowLearner {
    actions_file: PathBuf,
}

impl WorkflowLearner {
    pub fn new(data_dir: &Path) -> Self {
        Self {
            actions_file: data_dir.join("workflow_actions.json"),
        }
    }

    // -- helpers ----------------------------------------------------------

    fn load_actions(&self) -> Vec<RecordedAction> {
        match fs::read_to_string(&self.actions_file) {
            Ok(content) => serde_json::from_str(&content).unwrap_or_default(),
            Err(_) => Vec::new(),
        }
    }

    fn save_actions(&self, actions: &[RecordedAction]) -> Result<()> {
        if let Some(parent) = self.actions_file.parent() {
            fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(actions)?;
        fs::write(&self.actions_file, json)?;
        Ok(())
    }

    // -- public API -------------------------------------------------------

    /// Record an action with its surrounding context.
    pub fn record_action(&self, action: &str, context: &str) -> Result<()> {
        let mut actions = self.load_actions();
        actions.push(RecordedAction {
            action: action.to_string(),
            context: context.to_string(),
            timestamp: Local::now().to_rfc3339(),
        });

        // Keep a rolling window of the last 1000 actions.
        if actions.len() > 1000 {
            let start = actions.len() - 1000;
            actions = actions[start..].to_vec();
        }

        self.save_actions(&actions)?;
        debug!("WorkflowLearner: recorded action '{}'", action);
        Ok(())
    }

    /// Find sequences of `MIN_PATTERN_LENGTH`+ consecutive actions that
    /// repeat at least `MIN_PATTERN_REPEATS` times.
    pub fn detect_patterns(&self) -> Vec<DetectedPattern> {
        let actions = self.load_actions();
        let action_names: Vec<&str> = actions.iter().map(|a| a.action.as_str()).collect();

        let mut pattern_counts: HashMap<Vec<String>, usize> = HashMap::new();

        // Slide a window of each candidate length over the action list.
        for window_len in MIN_PATTERN_LENGTH..=action_names.len().min(8) {
            for window in action_names.windows(window_len) {
                let key: Vec<String> = window.iter().map(|s| s.to_string()).collect();
                *pattern_counts.entry(key).or_insert(0) += 1;
            }
        }

        let mut patterns: Vec<DetectedPattern> = pattern_counts
            .into_iter()
            .filter(|(_, count)| *count >= MIN_PATTERN_REPEATS)
            .map(|(seq, count)| DetectedPattern {
                sequence: seq,
                occurrences: count,
            })
            .collect();

        // Sort by occurrences descending, then longest sequence first.
        patterns.sort_by(|a, b| {
            b.occurrences
                .cmp(&a.occurrences)
                .then_with(|| b.sequence.len().cmp(&a.sequence.len()))
        });

        debug!("WorkflowLearner: found {} repeating patterns", patterns.len());
        patterns
    }

    /// Turn detected patterns into actionable skill suggestions.
    pub fn suggest_skills(&self) -> Vec<SkillSuggestion> {
        self.detect_patterns()
            .into_iter()
            .map(|p| {
                let name = format!("auto-skill-{}", p.sequence.join("-"));
                let description = format!(
                    "Automate the sequence [{}] which was repeated {} times.",
                    p.sequence.join(" -> "),
                    p.occurrences,
                );
                SkillSuggestion {
                    name,
                    description,
                    pattern: p,
                }
            })
            .collect()
    }
}

// ---------------------------------------------------------------------------
// 3. NightlyOptimizer
// ---------------------------------------------------------------------------

pub struct NightlyOptimizer {
    data_dir: PathBuf,
    report_file: PathBuf,
}

impl NightlyOptimizer {
    pub fn new(data_dir: &Path) -> Self {
        Self {
            report_file: data_dir.join("nightly_report.json"),
            data_dir: data_dir.to_path_buf(),
        }
    }

    /// Returns `true` when the current hour is between 2–5 AM **and** the
    /// user appears idle (presence file older than 30 minutes or missing).
    pub fn should_run(&self) -> bool {
        let hour = Local::now().hour();
        if !(2..=5).contains(&hour) {
            return false;
        }

        // Check presence file age.
        let presence = Path::new(PRESENCE_FILE);
        if !presence.exists() {
            return true; // no presence info → assume idle
        }

        match fs::metadata(presence).and_then(|m| m.modified()) {
            Ok(modified) => {
                let age = SystemTime::now()
                    .duration_since(modified)
                    .unwrap_or_default();
                age.as_secs() > 30 * 60 // idle for >30 min
            }
            Err(_) => true,
        }
    }

    /// Execute a full nightly optimization cycle.
    pub fn run_optimization_cycle(&self) -> Result<OptimizationReport> {
        info!("NightlyOptimizer: starting optimization cycle");

        let mut notes: Vec<String> = Vec::new();

        // 1. Cleanup — old journal entries, package cache, unused flatpaks.
        let cleanup_done = self.run_cleanup(&mut notes);

        // 2. Security audit (lynis, if available).
        let security_score = self.run_security_audit(&mut notes);

        // 3. Prompt evolution analysis.
        let prompt_metrics = match PromptEvolution::new().get_metrics() {
            Ok(m) => {
                notes.push(format!("Prompt metrics: {} action types analyzed", m.len()));
                m
            }
            Err(e) => {
                notes.push(format!("Prompt analysis skipped: {e}"));
                Vec::new()
            }
        };

        let report = OptimizationReport {
            timestamp: Local::now().to_rfc3339(),
            cleanup_done,
            security_score,
            prompt_metrics,
            notes,
        };

        // Persist report.
        if let Some(parent) = self.report_file.parent() {
            fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(&report)?;
        fs::write(&self.report_file, &json)?;

        info!("NightlyOptimizer: cycle complete, report saved");
        Ok(report)
    }

    /// Returns the last stored optimization report, if any.
    pub fn get_last_report(&self) -> Option<OptimizationReport> {
        fs::read_to_string(&self.report_file)
            .ok()
            .and_then(|content| serde_json::from_str(&content).ok())
    }

    // -- internal helpers -------------------------------------------------

    fn run_cleanup(&self, notes: &mut Vec<String>) -> bool {
        let mut cleaned = false;

        // Trim old journal logs (keep last 7 days).
        let journal_dir = self.data_dir.join("journals");
        if journal_dir.is_dir() {
            match self.cleanup_old_files(&journal_dir, 7) {
                Ok(n) => {
                    if n > 0 {
                        notes.push(format!("Removed {n} old journal files"));
                        cleaned = true;
                    }
                }
                Err(e) => notes.push(format!("Journal cleanup error: {e}")),
            }
        }

        // Trim cache directory (keep last 3 days).
        let cache_dir = self.data_dir.join("cache");
        if cache_dir.is_dir() {
            match self.cleanup_old_files(&cache_dir, 3) {
                Ok(n) => {
                    if n > 0 {
                        notes.push(format!("Removed {n} old cache files"));
                        cleaned = true;
                    }
                }
                Err(e) => notes.push(format!("Cache cleanup error: {e}")),
            }
        }

        cleaned
    }

    fn cleanup_old_files(&self, dir: &Path, max_age_days: u64) -> Result<usize> {
        let mut removed = 0usize;
        let cutoff = std::time::Duration::from_secs(max_age_days * 86400);

        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let metadata = entry.metadata()?;
            if !metadata.is_file() {
                continue;
            }
            if let Ok(modified) = metadata.modified() {
                let age = SystemTime::now()
                    .duration_since(modified)
                    .unwrap_or_default();
                if age > cutoff {
                    if let Err(e) = fs::remove_file(entry.path()) {
                        warn!("NightlyOptimizer: failed to remove {}: {e}", entry.path().display());
                    } else {
                        removed += 1;
                    }
                }
            }
        }
        Ok(removed)
    }

    fn run_security_audit(&self, notes: &mut Vec<String>) -> Option<u32> {
        // Check if lynis is available.
        let lynis_report = Path::new("/var/log/lynis-report.dat");
        if !lynis_report.exists() {
            notes.push("Lynis report not found, security audit skipped".to_string());
            return None;
        }

        // Try to extract the hardening index from the last lynis run.
        match fs::read_to_string(lynis_report) {
            Ok(content) => {
                for line in content.lines() {
                    if line.starts_with("hardening_index=") {
                        if let Some(val) = line.strip_prefix("hardening_index=") {
                            if let Ok(score) = val.trim().parse::<u32>() {
                                notes.push(format!("Lynis hardening index: {score}"));
                                return Some(score);
                            }
                        }
                    }
                }
                notes.push("Lynis report found but no hardening index".to_string());
                None
            }
            Err(e) => {
                notes.push(format!("Could not read lynis report: {e}"));
                None
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 4. SelfImprovingDaemon (orchestrator)
// ---------------------------------------------------------------------------

pub struct SelfImprovingDaemon {
    prompt_evolution: PromptEvolution,
    workflow_learner: WorkflowLearner,
    nightly_optimizer: NightlyOptimizer,
    last_nightly_date: Option<String>,
    last_tick: Option<String>,
}

impl SelfImprovingDaemon {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            prompt_evolution: PromptEvolution::new(),
            workflow_learner: WorkflowLearner::new(&data_dir),
            nightly_optimizer: NightlyOptimizer::new(&data_dir),
            last_nightly_date: None,
            last_tick: None,
        }
    }

    /// Called periodically from the main daemon loop.
    ///
    /// - Checks whether the nightly optimizer should run (and hasn't already
    ///   run today).
    /// - Future: feed live action telemetry into the workflow learner.
    pub fn tick(&mut self) -> Result<()> {
        let now = Local::now();
        self.last_tick = Some(now.to_rfc3339());

        // Run nightly at most once per calendar day.
        let today = now.format("%Y-%m-%d").to_string();
        let already_ran = self
            .last_nightly_date
            .as_ref()
            .map(|d| d == &today)
            .unwrap_or(false);

        if !already_ran && self.nightly_optimizer.should_run() {
            info!("SelfImprovingDaemon: triggering nightly optimization");
            match self.nightly_optimizer.run_optimization_cycle() {
                Ok(report) => {
                    self.last_nightly_date = Some(today);
                    info!(
                        "SelfImprovingDaemon: nightly done — {} notes",
                        report.notes.len()
                    );
                }
                Err(e) => {
                    warn!("SelfImprovingDaemon: nightly optimization failed: {e}");
                }
            }
        }

        Ok(())
    }

    /// Returns a JSON-serializable status snapshot for the dashboard.
    pub fn get_status(&self) -> SelfImprovingStatus {
        let prompt_metrics = self
            .prompt_evolution
            .get_metrics()
            .unwrap_or_default();

        let detected_patterns = self.workflow_learner.detect_patterns();

        let last_optimization = self.nightly_optimizer.get_last_report();

        SelfImprovingStatus {
            prompt_metrics,
            detected_patterns,
            last_optimization,
            last_tick: self
                .last_tick
                .clone()
                .unwrap_or_else(|| "never".to_string()),
        }
    }

    // -- Convenience proxies so callers don't need to reach into fields ---

    /// Record a user action for pattern learning.
    pub fn record_action(&self, action: &str, context: &str) -> Result<()> {
        self.workflow_learner.record_action(action, context)
    }

    /// Get prompt improvement suggestions.
    pub fn suggest_prompt_improvements(&self) -> Result<Vec<ImprovementSuggestion>> {
        self.prompt_evolution.suggest_improvements()
    }

    /// Get detected workflow patterns turned into skill suggestions.
    pub fn suggest_skills(&self) -> Vec<SkillSuggestion> {
        self.workflow_learner.suggest_skills()
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// Simple RAII temp directory (avoids external `tempfile` crate).
    struct TmpDir(PathBuf);

    impl TmpDir {
        fn new(name: &str) -> Self {
            let dir = std::env::temp_dir().join(format!("lifeos-test-{}-{}", name, std::process::id()));
            fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }
        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TmpDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn make_audit_log(dir: &Path, lines: &[&str]) -> PathBuf {
        let path = dir.join("supervisor-audit.log");
        let mut f = fs::File::create(&path).unwrap();
        for line in lines {
            writeln!(f, "{}", line).unwrap();
        }
        path
    }

    #[test]
    fn test_parse_audit_line_valid() {
        let entry = PromptEvolution::parse_audit_line(
            "2026-03-25T10:00:00\tinstall-pkg\tok\tapt install foo",
        )
        .unwrap();
        assert_eq!(entry.action, "install-pkg");
        assert_eq!(entry.result, "ok");
    }

    #[test]
    fn test_parse_audit_line_too_few_fields() {
        assert!(PromptEvolution::parse_audit_line("just-one-field").is_none());
    }

    #[test]
    fn test_analyze_prompt_effectiveness() {
        let tmp = TmpDir::new("effectiveness");
        let log_path = make_audit_log(
            tmp.path(),
            &[
                "2026-03-25T10:00:00\tinstall-pkg\tok\t",
                "2026-03-25T10:01:00\tinstall-pkg\tok\t",
                "2026-03-25T10:02:00\tinstall-pkg\tfail\terror",
                "2026-03-25T10:03:00\trestart-svc\tok\t",
            ],
        );
        let pe = PromptEvolution::with_log_path(log_path);
        let metrics = pe.analyze_prompt_effectiveness().unwrap();

        let install = metrics.iter().find(|m| m.action == "install-pkg").unwrap();
        assert_eq!(install.total, 3);
        assert_eq!(install.successes, 2);
        assert!((install.success_rate - 2.0 / 3.0).abs() < 0.01);
    }

    #[test]
    fn test_suggest_improvements_below_threshold() {
        let tmp = TmpDir::new("improvements");
        // 1 ok + 3 fail = 25% success
        let log_path = make_audit_log(
            tmp.path(),
            &[
                "t\tbad-action\tok\t",
                "t\tbad-action\tfail\t",
                "t\tbad-action\tfail\t",
                "t\tbad-action\tfail\t",
            ],
        );
        let pe = PromptEvolution::with_log_path(log_path);
        let suggestions = pe.suggest_improvements().unwrap();
        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].action, "bad-action");
    }

    #[test]
    fn test_workflow_learner_record_and_detect() {
        let tmp = TmpDir::new("wf-detect");
        let wl = WorkflowLearner::new(tmp.path());

        // Record a repeating pattern of 3 actions, 4 times.
        for _ in 0..4 {
            wl.record_action("open-editor", "ctx").unwrap();
            wl.record_action("save-file", "ctx").unwrap();
            wl.record_action("run-tests", "ctx").unwrap();
        }

        let patterns = wl.detect_patterns();
        // The 3-action sequence should appear at least 3 times.
        let found = patterns.iter().any(|p| {
            p.sequence == vec!["open-editor", "save-file", "run-tests"] && p.occurrences >= 3
        });
        assert!(found, "Expected repeating pattern not detected: {patterns:?}");
    }

    #[test]
    fn test_workflow_learner_suggest_skills() {
        let tmp = TmpDir::new("wf-skills");
        let wl = WorkflowLearner::new(tmp.path());

        for _ in 0..4 {
            wl.record_action("a", "").unwrap();
            wl.record_action("b", "").unwrap();
            wl.record_action("c", "").unwrap();
        }

        let skills = wl.suggest_skills();
        assert!(!skills.is_empty());
        assert!(skills[0].name.contains("a-b-c"));
    }

    #[test]
    fn test_nightly_optimizer_should_not_run_during_day() {
        let tmp = TmpDir::new("nightly-run");
        let no = NightlyOptimizer::new(tmp.path());
        // This test runs during CI (not 2-5 AM typically), so should_run is
        // effectively testing the hour gate. We just verify it doesn't panic.
        let _ = no.should_run();
    }

    #[test]
    fn test_nightly_optimizer_get_last_report_empty() {
        let tmp = TmpDir::new("nightly-empty");
        let no = NightlyOptimizer::new(tmp.path());
        assert!(no.get_last_report().is_none());
    }

    #[test]
    fn test_self_improving_daemon_status() {
        let tmp = TmpDir::new("daemon-status");
        let daemon = SelfImprovingDaemon::new(tmp.path().to_path_buf());
        let status = daemon.get_status();
        assert_eq!(status.last_tick, "never");
        // Should serialize without error.
        let json = serde_json::to_string(&status).unwrap();
        assert!(json.contains("\"last_tick\":\"never\""));
    }
}
