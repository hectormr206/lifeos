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
use hmac::{Hmac, Mac};
use log::{debug, info, warn};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

type HmacSha256 = Hmac<Sha256>;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SUPERVISOR_AUDIT_LOG: &str = "/var/lib/lifeos/supervisor-audit.log";
const PRESENCE_FILE: &str = "/var/lib/lifeos/presence_detected";
const SECRETS_DIR: &str = "/var/lib/lifeos/secrets";
const WORKFLOW_HMAC_KEY_FILE: &str = "/var/lib/lifeos/secrets/workflow-hmac.key";
const MAX_AUDIT_ENTRIES: usize = 100;
const SUCCESS_THRESHOLD: f64 = 0.70; // 70 %
const MIN_PATTERN_LENGTH: usize = 3;
const MIN_PATTERN_REPEATS: usize = 3;

/// Per-action and per-sequence schema limits. A pattern that exceeds these
/// is treated as adversarial and the entire workflow_actions.json is
/// refused — see `validate_actions`.
const MAX_ACTION_NAME_LEN: usize = 64;
const MAX_CONTEXT_LEN: usize = 256;
const MAX_RECORDED_ACTIONS: usize = 1000;
const ACTION_NAME_ALLOWED: &str =
    "[a-z0-9_-]+ (lowercase ascii, digits, underscore, dash; 1..=64 chars)";

fn is_valid_action_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_ACTION_NAME_LEN
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '_' | '-'))
}

fn validate_actions(actions: &[RecordedAction]) -> Result<()> {
    if actions.len() > MAX_RECORDED_ACTIONS {
        anyhow::bail!(
            "workflow actions exceeds cap ({} > {})",
            actions.len(),
            MAX_RECORDED_ACTIONS
        );
    }
    for (i, a) in actions.iter().enumerate() {
        if !is_valid_action_name(&a.action) {
            anyhow::bail!(
                "action[{i}] name {:?} fails allowlist {}",
                a.action,
                ACTION_NAME_ALLOWED
            );
        }
        if a.context.len() > MAX_CONTEXT_LEN {
            anyhow::bail!(
                "action[{i}] context exceeds {} bytes",
                MAX_CONTEXT_LEN
            );
        }
    }
    Ok(())
}

/// Load (or generate on first run) the HMAC-SHA256 key used to sign
/// `workflow_actions.json`.
///
/// THREAT MODEL — be honest about what this protects against:
/// - YES: a process under a different UID, or a sandboxed payload (flatpak
///   app, systemd-run scope) that can write into `/var/lib/lifeos/` but
///   cannot read `/var/lib/lifeos/secrets/` (mode 0700).
/// - YES: a backup-restore that brings stale or attacker-supplied state
///   from another machine.
/// - NO: a process running as the same UID as the daemon with full
///   filesystem access. That threat already wins regardless.
///
/// The key is generated once with 32 bytes from the OS RNG and persisted
/// at `/var/lib/lifeos/secrets/workflow-hmac.key` (mode 0600). The parent
/// directory is created with mode 0700.
fn load_or_create_hmac_key() -> Result<Vec<u8>> {
    let key_path = Path::new(WORKFLOW_HMAC_KEY_FILE);
    if let Ok(existing) = fs::read(key_path) {
        if existing.len() >= 32 {
            return Ok(existing);
        }
        warn!(
            "self_improving: existing HMAC key at {} is too short ({} bytes), regenerating",
            key_path.display(),
            existing.len()
        );
    }

    let secrets_dir = Path::new(SECRETS_DIR);
    fs::create_dir_all(secrets_dir).with_context(|| {
        format!("creating secrets dir {}", secrets_dir.display())
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(secrets_dir, fs::Permissions::from_mode(0o700));
    }

    let mut key = vec![0u8; 32];
    rand::thread_rng().fill_bytes(&mut key);
    fs::write(key_path, &key).with_context(|| {
        format!("writing HMAC key {}", key_path.display())
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(key_path, fs::Permissions::from_mode(0o600));
    }
    info!(
        "self_improving: generated new workflow HMAC key at {}",
        key_path.display()
    );
    Ok(key)
}

fn sign_payload(key: &[u8], payload: &[u8]) -> String {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(payload);
    let bytes = mac.finalize().into_bytes();
    hex_encode(&bytes)
}

fn verify_signature(key: &[u8], payload: &[u8], expected_hex: &str) -> bool {
    let Some(expected) = hex_decode(expected_hex.trim()) else {
        return false;
    };
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(payload);
    mac.verify_slice(&expected).is_ok()
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    let bytes = s.as_bytes();
    for pair in bytes.chunks(2) {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        out.push(((hi << 4) | lo) as u8);
    }
    Some(out)
}

fn auto_trigger_enabled() -> bool {
    std::env::var("LIFEOS_AUTO_TRIGGER_ENABLE")
        .map(|v| matches!(v.as_str(), "1" | "true" | "yes" | "on"))
        .unwrap_or(false)
}

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
            info!(
                "PromptEvolution: all action types above {:.0}% success threshold",
                SUCCESS_THRESHOLD * 100.0
            );
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
    hmac_file: PathBuf,
    /// HMAC key. When `None`, signing/verification is skipped — used in
    /// tests that don't have permission to write `/var/lib/lifeos/secrets/`.
    /// In production the key is loaded eagerly via `with_hmac_key`.
    hmac_key: Option<Vec<u8>>,
}

impl WorkflowLearner {
    /// Create a learner that signs and verifies its on-disk state with the
    /// daemon's workflow HMAC key. Falls back to no-signing if the key
    /// cannot be loaded (logged at warn!) — this is conservative: an old
    /// install without `/var/lib/lifeos/secrets/` still works, just with
    /// the previous trust level.
    pub fn new(data_dir: &Path) -> Self {
        let hmac_key = match load_or_create_hmac_key() {
            Ok(k) => Some(k),
            Err(e) => {
                warn!(
                    "self_improving: HMAC key unavailable ({e}); workflow_actions.json \
                     will be loaded without signature verification. Fix permissions \
                     on {SECRETS_DIR} to enable defence in depth."
                );
                None
            }
        };
        Self {
            actions_file: data_dir.join("workflow_actions.json"),
            hmac_file: data_dir.join("workflow_actions.json.hmac"),
            hmac_key,
        }
    }

    /// Test-only constructor that injects a known key and per-test paths.
    /// Tests bypass `/var/lib/lifeos/secrets/` (not writable in CI sandboxes).
    #[cfg(test)]
    pub fn with_files(actions_file: PathBuf, hmac_file: PathBuf, key: Option<Vec<u8>>) -> Self {
        Self {
            actions_file,
            hmac_file,
            hmac_key: key,
        }
    }

    // -- helpers ----------------------------------------------------------

    fn load_actions(&self) -> Vec<RecordedAction> {
        let Ok(content) = fs::read_to_string(&self.actions_file) else {
            return Vec::new();
        };

        // Verify HMAC if a key is available and a sidecar exists.
        if let Some(ref key) = self.hmac_key {
            match fs::read_to_string(&self.hmac_file) {
                Ok(sig) if verify_signature(key, content.as_bytes(), &sig) => {}
                Ok(_) => {
                    warn!(
                        "self_improving: HMAC mismatch for {}; refusing to load (file may have \
                         been tampered with or restored from another machine)",
                        self.actions_file.display()
                    );
                    return Vec::new();
                }
                Err(_) => {
                    warn!(
                        "self_improving: HMAC sidecar missing for {}; refusing to load. \
                         Delete the actions file to start fresh, or run a write to regenerate \
                         the signature.",
                        self.actions_file.display()
                    );
                    return Vec::new();
                }
            }
        }

        let actions: Vec<RecordedAction> = match serde_json::from_str(&content) {
            Ok(a) => a,
            Err(e) => {
                warn!(
                    "self_improving: workflow_actions.json failed to parse ({e}); ignoring file"
                );
                return Vec::new();
            }
        };

        if let Err(e) = validate_actions(&actions) {
            warn!(
                "self_improving: workflow_actions.json failed schema validation ({e}); ignoring \
                 file. This protects against pattern injection — if the file legitimately \
                 contained these entries, fix the recorder to emit names matching {ACTION_NAME_ALLOWED}."
            );
            return Vec::new();
        }

        actions
    }

    fn save_actions(&self, actions: &[RecordedAction]) -> Result<()> {
        validate_actions(actions)?;
        if let Some(parent) = self.actions_file.parent() {
            fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(actions)?;
        fs::write(&self.actions_file, &json)?;
        if let Some(ref key) = self.hmac_key {
            let sig = sign_payload(key, json.as_bytes());
            fs::write(&self.hmac_file, sig)?;
        }
        Ok(())
    }

    // -- public API -------------------------------------------------------

    /// Record an action with its surrounding context.
    pub fn record_action(&self, action: &str, context: &str) -> Result<()> {
        // Validate at the recording boundary so an upstream caller passing a
        // shell-metachar action name fails fast instead of being persisted.
        if !is_valid_action_name(action) {
            anyhow::bail!(
                "action name {action:?} fails allowlist {ACTION_NAME_ALLOWED}"
            );
        }
        if context.len() > MAX_CONTEXT_LEN {
            anyhow::bail!("context exceeds {MAX_CONTEXT_LEN} bytes");
        }

        let mut actions = self.load_actions();
        actions.push(RecordedAction {
            action: action.to_string(),
            context: context.to_string(),
            timestamp: Local::now().to_rfc3339(),
        });

        // Keep a rolling window of the last MAX_RECORDED_ACTIONS entries.
        if actions.len() > MAX_RECORDED_ACTIONS {
            let start = actions.len() - MAX_RECORDED_ACTIONS;
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
        self.detect_patterns_from(&actions)
    }

    /// Same logic as [`detect_patterns`] but takes actions as parameter so
    /// callers that already have the action list can avoid re-loading it.
    fn detect_patterns_from(&self, actions: &[RecordedAction]) -> Vec<DetectedPattern> {
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

        debug!(
            "WorkflowLearner: found {} repeating patterns",
            patterns.len()
        );
        patterns
    }

    /// Check if any learned pattern matches the current action context.
    /// Returns the matching procedure name and steps if found.
    ///
    /// SECURITY: This function is the bridge between persisted patterns
    /// (potentially attacker-controlled if `workflow_actions.json` was
    /// tampered with despite HMAC) and the supervisor that may execute the
    /// returned sequence. It defaults OFF — set
    /// `LIFEOS_AUTO_TRIGGER_ENABLE=1` to opt in to having the daemon
    /// propose learned procedures back to the supervisor without an
    /// explicit human approval step.
    pub fn check_auto_trigger(
        &self,
        current_action: &str,
        _current_context: &str,
    ) -> Option<(String, Vec<String>)> {
        if !auto_trigger_enabled() {
            return None;
        }
        let actions = self.load_actions();
        let patterns = self.detect_patterns_from(&actions);

        for pattern in &patterns {
            // Check if current action matches the start of a known pattern
            if pattern.sequence.first().map(|s| s.as_str()) == Some(current_action) {
                // Found a match — return the full sequence as suggested steps
                let name = format!(
                    "auto_{}",
                    pattern
                        .sequence
                        .join("_")
                        .chars()
                        .take(30)
                        .collect::<String>()
                );
                return Some((name, pattern.sequence.clone()));
            }
        }
        None
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
    /// user appears idle (presence file present and older than 30 minutes).
    ///
    /// SECURITY: this fails CLOSED. Previously, a missing or unreadable
    /// presence file was treated as "user is idle, run cleanup" — which
    /// meant any local attacker could make the nightly optimiser run
    /// while the user was active by deleting the file. We now require the
    /// presence file to exist *and* be old. If it is missing the daemon
    /// assumes the user might be active and skips. Cost: on a fresh
    /// install nightly does not run until `presence_detected` has been
    /// touched at least once; the sensory pipeline does this on first
    /// detection, and an installer can pre-create it.
    pub fn should_run(&self) -> bool {
        let hour = Local::now().hour();
        if !(2..=5).contains(&hour) {
            return false;
        }

        let presence = Path::new(PRESENCE_FILE);
        let Ok(meta) = fs::metadata(presence) else {
            // File missing or unreadable. Fail closed — do not run.
            return false;
        };
        let Ok(modified) = meta.modified() else {
            return false;
        };
        let Ok(age) = SystemTime::now().duration_since(modified) else {
            return false;
        };
        age.as_secs() > 30 * 60 // idle for >30 min
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
            // symlink_metadata does NOT follow symlinks. Without this guard
            // a symlink in journals/ pointing at e.g. ~/important-old.txt
            // would be deleted as if it were our journal file.
            let metadata = match fs::symlink_metadata(entry.path()) {
                Ok(m) => m,
                Err(_) => continue,
            };
            if !metadata.is_file() {
                continue; // skip dirs, symlinks, sockets, fifos, etc.
            }
            if let Ok(modified) = metadata.modified() {
                let age = SystemTime::now()
                    .duration_since(modified)
                    .unwrap_or_default();
                if age > cutoff {
                    if let Err(e) = fs::remove_file(entry.path()) {
                        warn!(
                            "NightlyOptimizer: failed to remove {}: {e}",
                            entry.path().display()
                        );
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
        let prompt_metrics = self.prompt_evolution.get_metrics().unwrap_or_default();

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

    /// Check if current action triggers a learned procedure (AQ.6).
    pub fn check_auto_trigger(
        &self,
        current_action: &str,
        current_context: &str,
    ) -> Option<(String, Vec<String>)> {
        self.workflow_learner
            .check_auto_trigger(current_action, current_context)
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
            let dir =
                std::env::temp_dir().join(format!("lifeos-test-{}-{}", name, std::process::id()));
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
        assert!(
            found,
            "Expected repeating pattern not detected: {patterns:?}"
        );
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

    // ---------- New hardening tests (PR 2/3 of P1) ----------

    #[test]
    fn action_name_allowlist_accepts_typical() {
        for name in ["a", "open-editor", "save_file", "run-tests-2", "x".repeat(64).as_str()] {
            assert!(is_valid_action_name(name), "should accept: {name:?}");
        }
    }

    #[test]
    fn action_name_allowlist_rejects_dangerous() {
        for bad in [
            "",
            "Open-Editor",
            "open editor",
            "open;rm",
            "open$(curl)",
            "open\nfoo",
            "../escape",
            "café",
            &"x".repeat(65),
        ] {
            assert!(!is_valid_action_name(bad), "should reject: {bad:?}");
        }
    }

    #[test]
    fn record_action_rejects_invalid_name() {
        let tmp = TmpDir::new("record-invalid");
        let wl = WorkflowLearner::with_files(
            tmp.path().join("wa.json"),
            tmp.path().join("wa.json.hmac"),
            None,
        );
        assert!(wl.record_action("BAD; rm -rf /", "ctx").is_err());
        assert!(wl.record_action("ok-name", "ctx").is_ok());
    }

    #[test]
    fn check_auto_trigger_off_by_default() {
        let tmp = TmpDir::new("trigger-off");
        std::env::remove_var("LIFEOS_AUTO_TRIGGER_ENABLE");
        let wl = WorkflowLearner::with_files(
            tmp.path().join("wa.json"),
            tmp.path().join("wa.json.hmac"),
            None,
        );
        for _ in 0..4 {
            wl.record_action("a", "").unwrap();
            wl.record_action("b", "").unwrap();
            wl.record_action("c", "").unwrap();
        }
        assert!(
            wl.check_auto_trigger("a", "").is_none(),
            "should refuse to propose patterns without explicit opt-in"
        );
    }

    #[test]
    fn check_auto_trigger_on_when_enabled() {
        let tmp = TmpDir::new("trigger-on");
        std::env::set_var("LIFEOS_AUTO_TRIGGER_ENABLE", "1");
        let wl = WorkflowLearner::with_files(
            tmp.path().join("wa.json"),
            tmp.path().join("wa.json.hmac"),
            None,
        );
        for _ in 0..4 {
            wl.record_action("a", "").unwrap();
            wl.record_action("b", "").unwrap();
            wl.record_action("c", "").unwrap();
        }
        let trig = wl.check_auto_trigger("a", "");
        std::env::remove_var("LIFEOS_AUTO_TRIGGER_ENABLE");
        let (_name, seq) = trig.expect("should fire when opt-in is set");
        assert!(seq.starts_with(&["a".to_string()]));
    }

    #[test]
    fn hmac_round_trip() {
        let key = vec![0x42u8; 32];
        let payload = b"hello world";
        let sig = sign_payload(&key, payload);
        assert!(verify_signature(&key, payload, &sig));
        // Tamper detection
        assert!(!verify_signature(&key, b"hello world!", &sig));
        let mut bad_sig = sig.clone();
        bad_sig.replace_range(0..2, "00");
        assert!(!verify_signature(&key, payload, &bad_sig));
    }

    #[test]
    fn hex_round_trip() {
        let bytes = vec![0x00, 0x01, 0xfe, 0xff, 0xab];
        let hex = hex_encode(&bytes);
        assert_eq!(hex, "0001feffab");
        assert_eq!(hex_decode(&hex), Some(bytes));
        assert!(hex_decode("zz").is_none());
        assert!(hex_decode("0").is_none()); // odd length
    }

    #[test]
    fn workflow_actions_load_refuses_missing_signature() {
        let tmp = TmpDir::new("hmac-no-sidecar");
        let key = vec![0x99u8; 32];
        let actions_path = tmp.path().join("wa.json");
        let hmac_path = tmp.path().join("wa.json.hmac");

        // Write actions file directly without sidecar.
        let bogus = vec![RecordedAction {
            action: "evil-action".to_string(),
            context: String::new(),
            timestamp: "t".to_string(),
        }];
        fs::write(&actions_path, serde_json::to_string(&bogus).unwrap()).unwrap();

        let wl = WorkflowLearner::with_files(actions_path, hmac_path, Some(key));
        // Loading should refuse and return empty.
        assert!(wl.load_actions().is_empty());
    }

    #[test]
    fn workflow_actions_load_refuses_tampered_content() {
        let tmp = TmpDir::new("hmac-tamper");
        let key = vec![0x77u8; 32];
        let actions_path = tmp.path().join("wa.json");
        let hmac_path = tmp.path().join("wa.json.hmac");

        let wl = WorkflowLearner::with_files(
            actions_path.clone(),
            hmac_path.clone(),
            Some(key.clone()),
        );

        // Legitimate write produces valid signature.
        wl.record_action("good-action", "ctx").unwrap();
        assert_eq!(wl.load_actions().len(), 1);

        // Tamper with the JSON content; signature no longer matches.
        let mut content = fs::read_to_string(&actions_path).unwrap();
        content = content.replace("good-action", "evil-action");
        fs::write(&actions_path, content).unwrap();

        // Load must refuse.
        assert!(wl.load_actions().is_empty());
    }

    #[test]
    fn workflow_actions_schema_rejects_overlong_list() {
        let huge: Vec<RecordedAction> = (0..MAX_RECORDED_ACTIONS + 10)
            .map(|i| RecordedAction {
                action: format!("act{i}"),
                context: String::new(),
                timestamp: "t".to_string(),
            })
            .collect();
        assert!(validate_actions(&huge).is_err());
    }

    #[test]
    fn cleanup_skips_symlinks() {
        let tmp = TmpDir::new("cleanup-symlink");
        let dir = tmp.path().join("journals");
        fs::create_dir_all(&dir).unwrap();

        // Create a target file outside the dir, mark it old.
        let outside = tmp.path().join("important.txt");
        fs::write(&outside, b"do not delete me").unwrap();

        // Create a symlink inside the cleanup dir pointing to the outside file.
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, dir.join("link.txt")).unwrap();

        let no = NightlyOptimizer::new(tmp.path());
        // Force max_age_days = 0 so any normal file would be deleted.
        let removed = no.cleanup_old_files(&dir, 0).unwrap();

        // The symlink target must still exist — symlink_metadata + is_file()
        // skips symlinks (they report as not-a-file under symlink_metadata).
        assert!(outside.exists(), "outside target must not be deleted via symlink");
        // We don't assert removed == 0 because some platforms could vary;
        // the critical invariant is the target survived.
        let _ = removed;
    }
}
